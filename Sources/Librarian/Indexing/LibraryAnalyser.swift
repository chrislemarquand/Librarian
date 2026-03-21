import Foundation
import Photos
import Vision
import CoreImage

struct AnalysisProgressUpdate {
    enum Phase {
        case querying
        case importing(completed: Int, total: Int)
        case visionAnalysing(completed: Int, total: Int)
    }
    let phase: Phase

    var statusText: String {
        switch phase {
        case .querying:
            return "Running osxphotos query…"
        case .importing(let completed, let total):
            return "Importing \(completed.formatted()) / \(total.formatted())…"
        case .visionAnalysing(let completed, let total):
            return "Vision analysis \(completed.formatted()) / \(total.formatted())…"
        }
    }
}

struct LibraryAnalyser {

    private let database: DatabaseManager
    private let visionBatchLimit = 3_000

    init(database: DatabaseManager) {
        self.database = database
    }

    nonisolated func run() -> AsyncThrowingStream<AnalysisProgressUpdate, Error> {
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
                        throw NSError(domain: "\(AppBrand.identifierPrefix).analysis", code: 6, userInfo: [
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
                        continuation.yield(AnalysisProgressUpdate(phase: .importing(completed: min(offset, total), total: total)))
                    }

                    try await runVisionAnalysisStage(
                        database: self.database,
                        visionBatchLimit: self.visionBatchLimit,
                        continuation: continuation
                    )

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

// MARK: - Vision stage

private struct VisionCandidateResult {
    let localIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let ocrText: String?
    let barcodeDetected: Bool
    let featurePrint: VNFeaturePrintObservation?
}

private nonisolated func runVisionAnalysisStage(
    database: DatabaseManager,
    visionBatchLimit: Int,
    continuation: AsyncThrowingStream<AnalysisProgressUpdate, Error>.Continuation
) async throws {
    let candidates = try database.assetRepository.fetchVisionAnalysisCandidates(
        limit: visionBatchLimit,
        includePreviouslyAnalysed: true
    )
    guard !candidates.isEmpty else { return }

    continuation.yield(
        AnalysisProgressUpdate(phase: .visionAnalysing(completed: 0, total: candidates.count))
    )

    var analysed: [VisionCandidateResult] = []
    analysed.reserveCapacity(candidates.count)
    let imageManager = PHImageManager.default()
    let progressInterval = 25

    for (index, candidate) in candidates.enumerated() {
        if Task.isCancelled { break }
        autoreleasepool {
            if let result = analyseVisionCandidate(candidate, imageManager: imageManager) {
                analysed.append(result)
            }
        }
        let completed = index + 1
        if completed % progressInterval == 0 || completed == candidates.count {
            continuation.yield(
                AnalysisProgressUpdate(
                    phase: .visionAnalysing(completed: completed, total: candidates.count)
                )
            )
        }
    }

    let analysedAt = Date()
    let writeResults = analysed.map {
        VisionAnalysisWriteResult(
            localIdentifier: $0.localIdentifier,
            ocrText: $0.ocrText,
            barcodeDetected: $0.barcodeDetected
        )
    }
    try await database.assetRepository.upsertVisionAnalysisData(writeResults, analysedAt: analysedAt)

    let clusterAssignments = buildNearDuplicateAssignments(results: analysed)
    try await database.assetRepository.assignNearDuplicateClusters(clusterAssignments)

    Task { @MainActor in
        AppLog.shared.info(
            "Vision analysis complete: \(analysed.count) assets scanned, \(Set(clusterAssignments.map(\.clusterID)).count) near-duplicate clusters."
        )
    }
}

private nonisolated func analyseVisionCandidate(_ candidate: VisionAnalysisCandidate, imageManager: PHImageManager) -> VisionCandidateResult? {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.localIdentifier], options: nil).firstObject else {
        return nil
    }
    guard let ciImage = requestCIImage(for: asset, imageManager: imageManager) else {
        return nil
    }

    let textRequest = VNRecognizeTextRequest()
    textRequest.recognitionLevel = .fast
    textRequest.usesLanguageCorrection = false

    let barcodeRequest = VNDetectBarcodesRequest()
    let featurePrintRequest = VNGenerateImageFeaturePrintRequest()

    let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
    do {
        try handler.perform([textRequest, barcodeRequest, featurePrintRequest])
    } catch {
        return nil
    }

    let recognizedText = (textRequest.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let cappedText = String(recognizedText.prefix(4000))
    let ocrText = cappedText.isEmpty ? nil : cappedText
    let barcodeDetected = !(barcodeRequest.results ?? []).isEmpty
    let featurePrint = (featurePrintRequest.results?.first as? VNFeaturePrintObservation)

    return VisionCandidateResult(
        localIdentifier: candidate.localIdentifier,
        creationDate: candidate.creationDate,
        pixelWidth: candidate.pixelWidth,
        pixelHeight: candidate.pixelHeight,
        ocrText: ocrText,
        barcodeDetected: barcodeDetected,
        featurePrint: featurePrint
    )
}

private nonisolated func requestCIImage(for asset: PHAsset, imageManager: PHImageManager) -> CIImage? {
    let options = PHImageRequestOptions()
    options.version = .current
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .none
    options.isNetworkAccessAllowed = false
    options.isSynchronous = true

    var resultData: Data?
    var requestFailed = false

    imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
        let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
        if cancelled || info?[PHImageErrorKey] != nil {
            requestFailed = true
        } else {
            resultData = data
        }
    }

    if requestFailed { return nil }
    guard let resultData else { return nil }
    return CIImage(data: resultData)
}

private nonisolated func buildNearDuplicateAssignments(results: [VisionCandidateResult]) -> [NearDuplicateClusterAssignment] {
    let withFeature = results.filter { $0.featurePrint != nil }
    guard withFeature.count > 1 else { return [] }

    let sorted = withFeature.sorted {
        let lhs = $0.creationDate ?? .distantPast
        let rhs = $1.creationDate ?? .distantPast
        if lhs == rhs { return $0.localIdentifier < $1.localIdentifier }
        return lhs < rhs
    }
    let unionFind = UnionFind(count: sorted.count)
    let maxTimeDelta: TimeInterval = 10
    let distanceThreshold: Float = 6.5

    for i in 0..<sorted.count {
        guard let leftPrint = sorted[i].featurePrint else { continue }
        let leftDate = sorted[i].creationDate ?? .distantPast
        var j = i + 1
        while j < sorted.count {
            let rightDate = sorted[j].creationDate ?? .distantPast
            if rightDate.timeIntervalSince(leftDate) > maxTimeDelta {
                break
            }
            guard let rightPrint = sorted[j].featurePrint else {
                j += 1
                continue
            }
            if !areComparableDimensions(lhs: sorted[i], rhs: sorted[j]) {
                j += 1
                continue
            }
            var distance: Float = 0
            if (try? leftPrint.computeDistance(&distance, to: rightPrint)) != nil, distance <= distanceThreshold {
                unionFind.union(i, j)
            }
            j += 1
        }
    }

    var groups: [Int: [Int]] = [:]
    for index in 0..<sorted.count {
        groups[unionFind.find(index), default: []].append(index)
    }

    var assignments: [NearDuplicateClusterAssignment] = []
    for members in groups.values where members.count > 1 {
        let clusterID = UUID().uuidString
        for memberIndex in members {
            assignments.append(
                NearDuplicateClusterAssignment(
                    localIdentifier: sorted[memberIndex].localIdentifier,
                    clusterID: clusterID
                )
            )
        }
    }
    return assignments
}

private nonisolated func areComparableDimensions(lhs: VisionCandidateResult, rhs: VisionCandidateResult) -> Bool {
    let lw = max(lhs.pixelWidth, 1)
    let lh = max(lhs.pixelHeight, 1)
    let rw = max(rhs.pixelWidth, 1)
    let rh = max(rhs.pixelHeight, 1)

    let leftAspect = Double(lw) / Double(lh)
    let rightAspect = Double(rw) / Double(rh)
    let aspectRatioDelta = abs(leftAspect - rightAspect) / max(leftAspect, rightAspect)
    if aspectRatioDelta > 0.2 { return false }

    let leftPixels = Double(lw * lh)
    let rightPixels = Double(rw * rh)
    let areaRatio = max(leftPixels, rightPixels) / max(min(leftPixels, rightPixels), 1)
    return areaRatio <= 1.8
}

private final class UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        self.parent = Array(0..<count)
        self.rank = Array(repeating: 0, count: count)
    }

    func find(_ x: Int) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x])
        }
        return parent[x]
    }

    func union(_ a: Int, _ b: Int) {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return }

        if rank[rootA] < rank[rootB] {
            parent[rootA] = rootB
        } else if rank[rootA] > rank[rootB] {
            parent[rootB] = rootA
        } else {
            parent[rootB] = rootA
            rank[rootA] += 1
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
    let runResult = OsxPhotosRunner().run(
        arguments: ["query", "--json"],
        captureStdoutToFile: fullJSONURL,
        includeExifToolEnvironment: false
    )
    guard runResult.exitCode == 0 else {
        let detail = runResult.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail.isEmpty
            ? "The library scan process ended unexpectedly (code \(runResult.exitCode))."
            : "The library scan process failed: \(detail)"
        throw NSError(domain: "\(AppBrand.identifierPrefix).analysis", code: 3, userInfo: [
            NSLocalizedDescriptionKey: message
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
        throw NSError(domain: "\(AppBrand.identifierPrefix).analysis", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Python extraction step failed with code \(pyProcess.terminationStatus)."
        ])
    }

    let compactData = (try? Data(contentsOf: compactJSONURL)) ?? Data()
    guard !compactData.isEmpty else {
        throw NSError(domain: "\(AppBrand.identifierPrefix).analysis", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Python extraction produced no output."
        ])
    }

    return compactData
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
