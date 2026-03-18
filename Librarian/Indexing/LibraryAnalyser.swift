import Foundation

struct AnalysisProgressUpdate {
    enum Phase {
        case querying
        case importing(completed: Int, total: Int)
    }
    let phase: Phase

    var statusText: String {
        switch phase {
        case .querying:
            return "Running osxphotos query…"
        case .importing(let completed, let total):
            return "Importing \(completed.formatted()) / \(total.formatted())…"
        }
    }
}

struct LibraryAnalyser {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func run() -> AsyncThrowingStream<AnalysisProgressUpdate, Error> {
        AsyncThrowingStream<AnalysisProgressUpdate, Error> { continuation in
            Task.detached(priority: .utility) {
                do {
                    continuation.yield(AnalysisProgressUpdate(phase: .querying))

                    let jsonData = try runOsxPhotosQuery()

                    let records: [OsxPhotosQueryRecord]
                    do {
                        records = try JSONDecoder().decode([OsxPhotosQueryRecord].self, from: jsonData)
                    } catch let error as DecodingError {
                        let detail: String
                        switch error {
                        case .typeMismatch(let type, let ctx):
                            detail = "typeMismatch(\(type)) at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
                        case .keyNotFound(let key, let ctx):
                            detail = "keyNotFound(\(key.stringValue)) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
                        case .valueNotFound(let type, let ctx):
                            detail = "valueNotFound(\(type)) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
                        case .dataCorrupted(let ctx):
                            detail = "dataCorrupted at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
                        @unknown default:
                            detail = error.localizedDescription
                        }
                        throw NSError(domain: "com.librarian.app.analysis", code: 6, userInfo: [
                            NSLocalizedDescriptionKey: "JSON decode failed: \(detail)"
                        ])
                    }

                    let analysedAt = Date()
                    let encoder = JSONEncoder() // used to serialise labels array to JSON string
                    let results: [AssetAnalysisResult] = records.map { record in
                        let labels = record.l ?? []
                        let labelsJSON: String? = labels.isEmpty
                            ? nil
                            : (try? String(data: encoder.encode(labels), encoding: .utf8)) ?? nil
                        let persons = record.p ?? []
                        return AssetAnalysisResult(
                            uuid: record.u,
                            overallScore: record.s,
                            fileSizeBytes: record.z,
                            hasNamedPerson: !persons.isEmpty,
                            namedPersonCount: persons.count,
                            detectedPersonCount: 0,
                            labelsJSON: labelsJSON,
                            fingerprint: record.f,
                            aiCaption: record.c
                        )
                    }

                    let total = results.count
                    let batchSize = 500
                    var offset = 0
                    while offset < results.count {
                        let batch = Array(results[offset ..< min(offset + batchSize, results.count)])
                        try await self.database.assetRepository.upsertAnalysisData(batch, analysedAt: analysedAt)
                        offset += batchSize
                        continuation.yield(AnalysisProgressUpdate(phase: .importing(completed: offset, total: total)))
                    }

                    Task { @MainActor in AppLog.shared.info("Library analysis complete: \(records.count) records imported.") }
                    continuation.finish()
                } catch {
                    Task { @MainActor in AppLog.shared.error("Library analysis error: \(error)") }
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - osxphotos subprocess

nonisolated private func runOsxPhotosQuery() throws -> Data {
    let fm = FileManager.default
    let token = UUID().uuidString
    let fullJSONURL = fm.temporaryDirectory.appendingPathComponent("librarian-full-\(token).json")
    let compactJSONURL = fm.temporaryDirectory.appendingPathComponent("librarian-compact-\(token).json")
    let scriptURL = fm.temporaryDirectory.appendingPathComponent("librarian-extract-\(token).py")

    defer {
        try? fm.removeItem(at: fullJSONURL)
        try? fm.removeItem(at: compactJSONURL)
        try? fm.removeItem(at: scriptURL)
    }

    // Step 1: run osxphotos query --json and write full output to a temp file.
    fm.createFile(atPath: fullJSONURL.path, contents: nil)
    let outputHandle = try FileHandle(forWritingTo: fullJSONURL)
    let osxProcess = Process()
    osxProcess.executableURL = try resolveBundledOsxPhotosExecutableForAnalysis()
    osxProcess.arguments = ["query", "--json"]
    osxProcess.standardOutput = outputHandle
    try osxProcess.run()
    osxProcess.waitUntilExit()
    try? outputHandle.close()

    guard osxProcess.terminationStatus == 0 else {
        throw NSError(domain: "com.librarian.app.analysis", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "osxphotos query exited with code \(osxProcess.terminationStatus)."
        ])
    }

    // Step 2: use Python to extract only the 7 fields we need, producing compact JSON.
    // Python handles the 230MB output reliably; we then parse the small result in Swift.
    let script = """
import json, sys
data = json.load(open(sys.argv[1]))
out = []
for x in data:
    sc = x.get("score") or {}
    out.append({
        "u": x.get("uuid", ""),
        "s": sc.get("overall"),
        "z": x.get("original_filesize"),
        "p": [n for n in (x.get("persons") or []) if n != "_UNKNOWN_"],
        "l": x.get("labels_normalized") or [],
        "f": x.get("fingerprint"),
        "c": x.get("ai_caption")
    })
with open(sys.argv[2], "w") as f:
    json.dump(out, f)
"""
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)

    let pyProcess = Process()
    pyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    pyProcess.arguments = [scriptURL.path, fullJSONURL.path, compactJSONURL.path]
    try pyProcess.run()
    pyProcess.waitUntilExit()

    guard pyProcess.terminationStatus == 0 else {
        throw NSError(domain: "com.librarian.app.analysis", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Python extraction step failed with code \(pyProcess.terminationStatus)."
        ])
    }

    let compactData = (try? Data(contentsOf: compactJSONURL)) ?? Data()
    guard !compactData.isEmpty else {
        throw NSError(domain: "com.librarian.app.analysis", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Python extraction produced no output."
        ])
    }

    return compactData
}

nonisolated private func resolveBundledOsxPhotosExecutableForAnalysis() throws -> URL {
    let fm = FileManager.default
    let bundle = Bundle.main
    var candidates: [URL] = []
    if let auxiliary = bundle.url(forAuxiliaryExecutable: "osxphotos") {
        candidates.append(auxiliary)
    }
    if let resourceRoot = bundle.resourceURL {
        candidates.append(resourceRoot.appendingPathComponent("Tools/osxphotos"))
        candidates.append(resourceRoot.appendingPathComponent("osxphotos"))
    }
    for url in candidates {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
        if fm.isExecutableFile(atPath: url.path) { return url }
    }
    throw NSError(domain: "com.librarian.app.analysis", code: 5, userInfo: [
        NSLocalizedDescriptionKey: "Bundled osxphotos executable not found in app resources."
    ])
}

// MARK: - Decodable record

// Compact record produced by the Python extraction step.
// Single-letter keys to minimise output size.
private struct OsxPhotosQueryRecord: Decodable {
    let u: String   // uuid
    let s: Double?  // score.overall
    let z: Int?     // original_filesize
    let p: [String]? // persons (pre-filtered, no _UNKNOWN_)
    let l: [String]? // labels_normalized
    let f: String?  // fingerprint
    let c: String?  // ai_caption
}
