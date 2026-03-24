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
            return "Analysing library…"
        case .importing:
            return "Analysing library…"
        case .visionAnalysing(let completed, let total):
            return "Analysing photos \(completed.formatted()) / \(total.formatted())…"
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
    let saliencyScore: Double?
    let featurePrint: VNFeaturePrintObservation?
    let featurePrintData: Data?
}

private struct FeaturePrintEntry {
    let localIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let featurePrint: VNFeaturePrintObservation
}

private nonisolated func runVisionAnalysisStage(
    database: DatabaseManager,
    visionBatchLimit: Int,
    continuation: AsyncThrowingStream<AnalysisProgressUpdate, Error>.Continuation
) async throws {
    let totalCandidates = try database.assetRepository.countVisionAnalysisCandidates(
        includePreviouslyAnalysed: false
    )
    guard totalCandidates > 0 else { return }

    continuation.yield(
        AnalysisProgressUpdate(phase: .visionAnalysing(completed: 0, total: totalCandidates))
    )

    var analysed: [VisionCandidateResult] = []
    analysed.reserveCapacity(min(totalCandidates, visionBatchLimit))
    let imageManager = PHImageManager.default()
    let progressInterval = 25
    var failedCount = 0
    var attemptedCount = 0

    while !Task.isCancelled {
        let candidates = try database.assetRepository.fetchVisionAnalysisCandidates(
            limit: visionBatchLimit,
            includePreviouslyAnalysed: false
        )
        guard !candidates.isEmpty else { break }

        var batchAnalysed: [VisionCandidateResult] = []
        batchAnalysed.reserveCapacity(candidates.count)

        for candidate in candidates {
            if Task.isCancelled { break }
            autoreleasepool {
                if let result = analyseVisionCandidate(candidate, imageManager: imageManager) {
                    batchAnalysed.append(result)
                } else {
                    failedCount += 1
                }
            }
            attemptedCount += 1
            if attemptedCount % progressInterval == 0 || attemptedCount >= totalCandidates {
                continuation.yield(
                    AnalysisProgressUpdate(
                        phase: .visionAnalysing(completed: min(attemptedCount, totalCandidates), total: totalCandidates)
                    )
                )
            }
        }

        let analysedAt = Date()
        let writeResults = batchAnalysed.map {
            VisionAnalysisWriteResult(
                localIdentifier: $0.localIdentifier,
                ocrText: $0.ocrText,
                saliencyScore: $0.saliencyScore,
                featurePrintData: $0.featurePrintData
            )
        }
        try await database.assetRepository.upsertVisionAnalysisData(writeResults, analysedAt: analysedAt)
        analysed.append(contentsOf: batchAnalysed)

        if attemptedCount >= totalCandidates {
            break
        }
    }

    var clusterAssignments: [NearDuplicateClusterAssignment] = []
    var deserialiseFailures = 0
    if !Task.isCancelled {
        // Load ALL stored feature prints so clustering spans the full library,
        // not just the assets analysed in this pass.
        let storedPrints = try database.assetRepository.fetchAllFeaturePrints()
        let allEntries: [FeaturePrintEntry] = storedPrints.compactMap { stored in
            guard let observation = deserialiseFeaturePrint(from: stored.featurePrintData) else {
                deserialiseFailures += 1
                return nil
            }
            return FeaturePrintEntry(
                localIdentifier: stored.localIdentifier,
                creationDate: stored.creationDate,
                pixelWidth: stored.pixelWidth,
                pixelHeight: stored.pixelHeight,
                featurePrint: observation
            )
        }
        // Build fresh assignments before clearing so a bug here preserves the old data.
        clusterAssignments = buildNearDuplicateAssignments(entries: allEntries)
        try await database.assetRepository.clearAllNearDuplicateClusters()
        try await database.assetRepository.assignNearDuplicateClusters(clusterAssignments)
    }

    Task { @MainActor in
        let saliencyCount = analysed.reduce(into: 0) { partialResult, row in
            if row.saliencyScore != nil {
                partialResult += 1
            }
        }
        AppLog.shared.info(
            "Vision analysis scan summary: candidates=\(totalCandidates), attempted=\(attemptedCount), successful=\(analysed.count), failed=\(failedCount), saliency=\(saliencyCount), cancelled=\(Task.isCancelled)"
        )
        if analysed.isEmpty {
            AppLog.shared.error("Vision analysis produced 0 successful results from \(totalCandidates) candidates.")
        }
        AppLog.shared.info(
            "Vision analysis complete: \(analysed.count) assets scanned, \(Set(clusterAssignments.map(\.clusterID)).count) near-duplicate clusters, \(deserialiseFailures) feature print deserialise failures. Cancelled=\(Task.isCancelled)"
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

    let featurePrintRequest = VNGenerateImageFeaturePrintRequest()

    let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
    do {
        try handler.perform([textRequest, featurePrintRequest])
    } catch {
        return nil
    }

    let recognizedText = (textRequest.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let cappedText = String(recognizedText.prefix(4000))
    let ocrText = cappedText.isEmpty ? nil : cappedText
    let featurePrint = (featurePrintRequest.results?.first as? VNFeaturePrintObservation)

    return VisionCandidateResult(
        localIdentifier: candidate.localIdentifier,
        creationDate: candidate.creationDate,
        pixelWidth: candidate.pixelWidth,
        pixelHeight: candidate.pixelHeight,
        ocrText: ocrText,
        saliencyScore: nil,
        featurePrint: featurePrint,
        featurePrintData: featurePrint.flatMap { serialiseFeaturePrint($0) }
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

private nonisolated func serialiseFeaturePrint(_ observation: VNFeaturePrintObservation) -> Data? {
    try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
}

private nonisolated func deserialiseFeaturePrint(from data: Data) -> VNFeaturePrintObservation? {
    try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
}

private nonisolated func buildNearDuplicateAssignments(entries: [FeaturePrintEntry]) -> [NearDuplicateClusterAssignment] {
    guard entries.count > 1 else { return [] }

    let sorted = entries.sorted {
        let lhs = $0.creationDate ?? .distantPast
        let rhs = $1.creationDate ?? .distantPast
        if lhs == rhs { return $0.localIdentifier < $1.localIdentifier }
        return lhs < rhs
    }
    let maxTimeDelta: TimeInterval = 6
    let distanceThreshold: Float = 1.0
    var neighbours: [Set<Int>] = Array(repeating: [], count: sorted.count)

    for i in 0..<sorted.count {
        let leftPrint = sorted[i].featurePrint
        let leftDate = sorted[i].creationDate ?? .distantPast
        var j = i + 1
        while j < sorted.count {
            let rightDate = sorted[j].creationDate ?? .distantPast
            if rightDate.timeIntervalSince(leftDate) > maxTimeDelta {
                break
            }
            let rightPrint = sorted[j].featurePrint
            if !areComparableDimensions(lhs: sorted[i], rhs: sorted[j]) {
                j += 1
                continue
            }
            var distance: Float = 0
            if (try? leftPrint.computeDistance(&distance, to: rightPrint)) != nil, distance <= distanceThreshold {
                neighbours[i].insert(j)
                neighbours[j].insert(i)
            }
            j += 1
        }
    }

    var visited = Array(repeating: false, count: sorted.count)
    var components: [[Int]] = []
    components.reserveCapacity(sorted.count / 2)

    for start in 0..<sorted.count where !visited[start] {
        guard !neighbours[start].isEmpty else {
            visited[start] = true
            continue
        }

        var stack: [Int] = [start]
        visited[start] = true
        var component: [Int] = []
        while let current = stack.popLast() {
            component.append(current)
            for next in neighbours[current] where !visited[next] {
                visited[next] = true
                stack.append(next)
            }
        }
        if component.count > 1 {
            components.append(component.sorted())
        }
    }

    var assignments: [NearDuplicateClusterAssignment] = []
    for component in components {
        // Split connected components into clique-like groups so chain links
        // (A~B and B~C) do not force A and C into the same duplicate group.
        var refinedGroups: [[Int]] = []
        for candidate in component {
            var inserted = false
            for index in refinedGroups.indices {
                let group = refinedGroups[index]
                let isCompatible = group.allSatisfy { member in
                    neighbours[candidate].contains(member)
                }
                if isCompatible {
                    refinedGroups[index].append(candidate)
                    inserted = true
                    break
                }
            }
            if !inserted {
                refinedGroups.append([candidate])
            }
        }

        for group in refinedGroups where group.count > 1 {
            let clusterID = UUID().uuidString
            for memberIndex in group {
                assignments.append(
                    NearDuplicateClusterAssignment(
                        localIdentifier: sorted[memberIndex].localIdentifier,
                        clusterID: clusterID
                    )
                )
            }
        }
    }
    return assignments
}

private nonisolated func areComparableDimensions(lhs: FeaturePrintEntry, rhs: FeaturePrintEntry) -> Bool {
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

    var arguments: [String] = ["query", "--json"]
    if let libraryPath = OsxPhotosLibraryResolver.preferredLibraryPath() {
        arguments.append(contentsOf: ["--library", libraryPath])
    }

    // Step 1: run osxphotos query and write full output to a temp file.
    let runResult = OsxPhotosRunner().run(
        arguments: arguments,
        captureStdoutToFile: fullJSONURL,
        includeExifToolEnvironment: false
    )
    let renderedArgs = arguments.map { arg -> String in
        if arg.contains(where: { $0.isWhitespace }) {
            return "\"\(arg)\""
        }
        return arg
    }.joined(separator: " ")
    let commandText = "osxphotos \(renderedArgs)"
    Task { @MainActor in
        AppLog.shared.info("osxphotos query command: \(commandText)")
        AppLog.shared.info("osxphotos query executable: \(runResult.executableURL.path)")
        AppLog.shared.info("osxphotos query used external fallback: \(runResult.usedExternalFallback)")
        AppLog.shared.info("osxphotos query exit code: \(runResult.exitCode)")
        if !runResult.outputText.isEmpty {
            AppLog.shared.infoMultiline(prefix: "osxphotos query output", text: runResult.outputText)
        }
    }
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
