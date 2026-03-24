import Foundation
import CryptoKit

struct ArchiveDedupeDecision {
    enum Outcome {
        case keep
        case suppressDuplicate(canonicalRelativePath: String)
        case keepIndeterminate(reason: String)
    }

    let relativePath: String
    let outcome: Outcome
}

struct ArchiveDedupeBatchSummary {
    let total: Int
    let kept: Int
    let suppressedDuplicates: Int
    let indeterminate: Int
}

/// Phase-1 exact dedupe service:
/// - fingerprints incoming files
/// - claims one canonical item per SHA-256
/// - records duplicate/indeterminate events for audit
final class ArchiveDedupeService: @unchecked Sendable {
    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func evaluateFiles(
        archiveTreeRoot: URL,
        fileURLs: [URL],
        ingestSource: String,
        flow: String,
        now: Date = Date()
    ) throws -> (decisions: [ArchiveDedupeDecision], summary: ArchiveDedupeBatchSummary) {
        guard !fileURLs.isEmpty else {
            return (
                decisions: [],
                summary: ArchiveDedupeBatchSummary(total: 0, kept: 0, suppressedDuplicates: 0, indeterminate: 0)
            )
        }

        let fingerprints = try fileURLs.map { fileURL in
            try makeFingerprint(
                archiveTreeRoot: archiveTreeRoot,
                fileURL: fileURL,
                ingestSource: ingestSource,
                now: now
            )
        }
        try database.assetRepository.upsertArchiveFingerprints(fingerprints)

        var decisions: [ArchiveDedupeDecision] = []
        decisions.reserveCapacity(fingerprints.count)
        var events: [ArchiveDuplicateEvent] = []
        events.reserveCapacity(fingerprints.count)

        for fingerprint in fingerprints {
            if fingerprint.state != ArchiveFingerprintState.verified.rawValue || fingerprint.sha256 == nil {
                decisions.append(
                    ArchiveDedupeDecision(
                        relativePath: fingerprint.relativePath,
                        outcome: .keepIndeterminate(reason: "hash_unavailable")
                    )
                )
                events.append(
                    ArchiveDuplicateEvent(
                        id: UUID().uuidString,
                        incomingRelativePath: fingerprint.relativePath,
                        canonicalRelativePath: nil,
                        incomingSHA256: fingerprint.sha256,
                        reason: "indeterminate_kept",
                        flow: flow,
                        createdAt: now
                    )
                )
                continue
            }

            let incomingHash = fingerprint.sha256 ?? ""
            let canonical = try database.assetRepository.claimCanonicalArchiveFingerprint(
                sha256: incomingHash,
                candidateRelativePath: fingerprint.relativePath
            )
            if canonical == fingerprint.relativePath {
                decisions.append(ArchiveDedupeDecision(relativePath: fingerprint.relativePath, outcome: .keep))
            } else {
                decisions.append(
                    ArchiveDedupeDecision(
                        relativePath: fingerprint.relativePath,
                        outcome: .suppressDuplicate(canonicalRelativePath: canonical)
                    )
                )
                events.append(
                    ArchiveDuplicateEvent(
                        id: UUID().uuidString,
                        incomingRelativePath: fingerprint.relativePath,
                        canonicalRelativePath: canonical,
                        incomingSHA256: incomingHash,
                        reason: "exact_match",
                        flow: flow,
                        createdAt: now
                    )
                )
            }
        }

        if !events.isEmpty {
            try database.assetRepository.saveArchiveDuplicateEvents(events)
        }

        let summary = ArchiveDedupeBatchSummary(
            total: decisions.count,
            kept: decisions.filter { if case .keep = $0.outcome { return true } else { return false } }.count,
            suppressedDuplicates: decisions.filter { if case .suppressDuplicate = $0.outcome { return true } else { return false } }.count,
            indeterminate: decisions.filter { if case .keepIndeterminate = $0.outcome { return true } else { return false } }.count
        )
        return (decisions, summary)
    }

    private func makeFingerprint(
        archiveTreeRoot: URL,
        fileURL: URL,
        ingestSource: String,
        now: Date
    ) throws -> ArchiveFileFingerprint {
        let relativePath = try relativePath(from: archiveTreeRoot, to: fileURL)
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSizeBytes = Int64(values.fileSize ?? 0)
        let fileModDate = values.contentModificationDate ?? now

        let hashResult = computeSHA256OrIndeterminate(for: fileURL)
        return ArchiveFileFingerprint(
            relativePath: relativePath,
            sha256: hashResult.hash,
            fileSizeBytes: fileSizeBytes,
            fileModificationDate: fileModDate,
            captureDate: nil,
            firstSeenAt: now,
            lastVerifiedAt: now,
            isCanonical: false,
            canonicalRelativePath: nil,
            ingestSource: ingestSource,
            state: hashResult.state.rawValue
        )
    }

    private func computeSHA256OrIndeterminate(for fileURL: URL) -> (hash: String?, state: ArchiveFingerprintState) {
        do {
            return (hash: try sha256Hex(ofFileAt: fileURL), state: .verified)
        } catch {
            return (hash: nil, state: .indeterminate)
        }
    }

    private func relativePath(from root: URL, to child: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath + "/") else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archiveDedupe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not compute relative path for \(childPath)"
            ])
        }
        return String(childPath.dropFirst(rootPath.count + 1))
    }

    private func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02hhx", $0) }.joined()
    }
}
