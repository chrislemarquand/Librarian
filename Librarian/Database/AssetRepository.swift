import Foundation
import GRDB

// MARK: - IndexedAsset (GRDB record)

struct IndexedAsset: Codable, FetchableRecord, @preconcurrency PersistableRecord {
    static let databaseTableName = "asset"

    var localIdentifier: String
    var creationDate: Date?
    var modificationDate: Date?
    var mediaType: Int
    var mediaSubtypes: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double
    var isFavorite: Bool
    var isHidden: Bool
    var isScreenshot: Bool
    var isCloudOnly: Bool
    var hasLocalThumbnail: Bool
    var hasLocalOriginal: Bool
    var iCloudDownloadState: String
    var analysisVersion: Int
    var lastSeenInLibraryAt: Date?
    var isDeletedFromPhotos: Bool
}

enum ScreenshotReviewDecision: String {
    case none
    case keep
    case archiveCandidate
}

enum ArchiveCandidateStatus: String {
    case pending
    case exporting
    case exported
    case deleted
    case failed
}

struct ArchiveCandidateInfo {
    let status: ArchiveCandidateStatus
    let lastError: String?
    let queuedAt: Date
    let exportedAt: Date?
    let deletedAt: Date?
    let archivePath: String?
}

struct AssetAnalysisResult {
    let uuid: String
    let overallScore: Double?
    let fileSizeBytes: Int?
    let hasNamedPerson: Bool
    let namedPersonCount: Int
    let detectedPersonCount: Int
    let labelsJSON: String?
    let fingerprint: String?
    let aiCaption: String?
}

struct VisionAnalysisCandidate {
    let localIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
}

struct VisionAnalysisWriteResult {
    let localIdentifier: String
    let ocrText: String?
    let barcodeDetected: Bool
}

struct NearDuplicateClusterAssignment {
    let localIdentifier: String
    let clusterID: String
}

struct ArchivedItem: Codable, FetchableRecord, @preconcurrency PersistableRecord {
    static let databaseTableName = "archived_item"

    var relativePath: String
    var absolutePath: String
    var filename: String
    var fileExtension: String
    var fileSizeBytes: Int64
    var fileModificationDate: Date
    var captureDate: Date?
    var sortDate: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var thumbnailRelativePath: String
    var lastIndexedAt: Date
}

struct ArchivedItemSignature {
    let relativePath: String
    let fileSizeBytes: Int64
    let fileModificationDate: Date
}

// MARK: - AssetRepository

final class AssetRepository: @unchecked Sendable {

    private let db: DatabaseQueue
    private let minimumDocumentOCRCharacters = 120

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Read

    func count() throws -> Int {
        try db.read { db in
            try IndexedAsset.fetchCount(db)
        }
    }

    func countArchivedItems() throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM archived_item") ?? 0
        }
    }

    func fetchDeletedAssetIdentifiers() throws -> [String] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT localIdentifier
                    FROM asset
                    WHERE isDeletedFromPhotos = 1
                """
            )
            return rows.compactMap { row in row["localIdentifier"] as String? }
        }
    }

    func fetchAll() throws -> [IndexedAsset] {
        try db.read { db in
            try IndexedAsset.fetchAll(db)
        }
    }

    func fetchForGrid(limit: Int, offset: Int = 0) throws -> [IndexedAsset] {
        try fetchActiveAssets(whereClause: nil, arguments: StatementArguments(), limit: limit, offset: offset)
    }

    func fetchArchivedForGrid(limit: Int, offset: Int = 0) throws -> [ArchivedItem] {
        try db.read { db in
            let request = SQLRequest<ArchivedItem>(
                sql: """
                    SELECT *
                    FROM archived_item
                    ORDER BY sortDate DESC, relativePath ASC
                    LIMIT ? OFFSET ?
                """,
                arguments: [limit, offset]
            )
            return try request.fetchAll(db)
        }
    }

    func fetchFavouritesForGrid(limit: Int, offset: Int = 0) throws -> [IndexedAsset] {
        try fetchActiveAssets(whereClause: "a.isFavorite = 1", arguments: StatementArguments(), limit: limit, offset: offset)
    }

    func fetchRecentsForGrid(since date: Date, limit: Int, offset: Int = 0) throws -> [IndexedAsset] {
        try fetchActiveAssets(
            whereClause: "a.creationDate IS NOT NULL AND a.creationDate >= ?",
            arguments: StatementArguments([date]),
            limit: limit,
            offset: offset
        )
    }

    func fetchScreenshotsForReview(limit: Int, offset: Int = 0) throws -> [IndexedAsset] {
        try db.read { db in
            let request = SQLRequest<IndexedAsset>(
                sql: """
                    SELECT a.*
                    FROM asset_active a
                    LEFT JOIN queue_keep_decision qk
                        ON qk.assetLocalIdentifier = a.localIdentifier AND qk.queueKind = 'screenshots'
                    WHERE a.isScreenshot = 1
                      AND qk.assetLocalIdentifier IS NULL
                    ORDER BY a.creationDate DESC, a.localIdentifier DESC
                    LIMIT ? OFFSET ?
                """,
                arguments: [limit, offset]
            )
            return try request.fetchAll(db)
        }
    }

    func fetchArchiveCandidatesForGrid(limit: Int, offset: Int = 0) throws -> [IndexedAsset] {
        try db.read { db in
            let request = SQLRequest<IndexedAsset>(
                sql: """
                    SELECT a.*
                    FROM asset a
                    JOIN archive_candidate ac
                    ON ac.assetLocalIdentifier = a.localIdentifier
                    WHERE a.isDeletedFromPhotos = 0
                      AND ac.status IN (?, ?, ?)
                    ORDER BY ac.queuedAt DESC, a.creationDate DESC, a.localIdentifier DESC
                    LIMIT ?
                    OFFSET ?
                """,
                arguments: [
                    ArchiveCandidateStatus.pending.rawValue,
                    ArchiveCandidateStatus.exporting.rawValue,
                    ArchiveCandidateStatus.failed.rawValue,
                    limit,
                    offset
                ]
            )
            return try request.fetchAll(db)
        }
    }

    func fetchArchiveCandidateIdentifiers(statuses: [ArchiveCandidateStatus]) throws -> [String] {
        guard !statuses.isEmpty else { return [] }
        return try db.read { db in
            let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
            let arguments = StatementArguments(statuses.map(\.rawValue))
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT assetLocalIdentifier
                    FROM archive_candidate
                    WHERE status IN (\(placeholders))
                    ORDER BY queuedAt ASC
                """,
                arguments: arguments
            )
            return rows.compactMap { row in row["assetLocalIdentifier"] as String? }
        }
    }

    func fetchArchiveCandidateInfo(localIdentifier: String) throws -> ArchiveCandidateInfo? {
        try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT status, lastError, queuedAt, exportedAt, deletedAt, archivePath
                    FROM archive_candidate
                    WHERE assetLocalIdentifier = ?
                    LIMIT 1
                """,
                arguments: [localIdentifier]
            ) else {
                return nil
            }
            guard
                let rawStatus: String = row["status"],
                let status = ArchiveCandidateStatus(rawValue: rawStatus),
                let queuedAt: Date = row["queuedAt"]
            else {
                return nil
            }
            return ArchiveCandidateInfo(
                status: status,
                lastError: row["lastError"],
                queuedAt: queuedAt,
                exportedAt: row["exportedAt"],
                deletedAt: row["deletedAt"],
                archivePath: row["archivePath"]
            )
        }
    }

    func countArchiveCandidates(statuses: [ArchiveCandidateStatus]) throws -> Int {
        guard !statuses.isEmpty else { return 0 }
        return try db.read { db in
            let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
            let arguments = StatementArguments(statuses.map(\.rawValue))
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM archive_candidate
                    WHERE status IN (\(placeholders))
                """,
                arguments: arguments
            ) ?? 0
        }
    }

    // MARK: - Write

    /// Upsert a batch of assets. Called from background during indexing.
    func upsert(_ assets: [IndexedAsset]) async throws {
        try await db.write { db in
            for asset in assets {
                try asset.upsert(db)
            }
        }
    }

    /// Mark assets no longer seen in the library.
    func markDeleted(identifiers: [String], at date: Date) throws {
        guard !identifiers.isEmpty else { return }
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE asset
                    SET isDeletedFromPhotos = 1
                    WHERE localIdentifier IN (\(identifiers.map { _ in "?" }.joined(separator: ",")))
                """,
                arguments: StatementArguments(identifiers)
            )
        }
    }

    func setScreenshotDecision(identifiers: [String], decision: ScreenshotReviewDecision, at date: Date = Date()) throws {
        guard !identifiers.isEmpty else { return }
        try db.write { db in
            for identifier in identifiers {
                try db.execute(
                    sql: """
                        INSERT INTO screenshot_review (assetLocalIdentifier, decision, decidedAt)
                        VALUES (?, ?, ?)
                        ON CONFLICT(assetLocalIdentifier) DO UPDATE SET
                            decision = excluded.decision,
                            decidedAt = excluded.decidedAt
                    """,
                    arguments: [identifier, decision.rawValue, date]
                )
            }
        }
    }

    func queueForArchive(identifiers: [String], at date: Date = Date()) throws {
        guard !identifiers.isEmpty else { return }
        try db.write { db in
            for identifier in identifiers {
                try db.execute(
                    sql: """
                        INSERT INTO archive_candidate (assetLocalIdentifier, status, queuedAt, lastError)
                        VALUES (?, ?, ?, NULL)
                        ON CONFLICT(assetLocalIdentifier) DO UPDATE SET
                            status = excluded.status,
                            queuedAt = excluded.queuedAt,
                            lastError = NULL
                    """,
                    arguments: [identifier, ArchiveCandidateStatus.pending.rawValue, date]
                )
            }
        }
    }

    func removeFromArchiveQueue(identifiers: [String]) throws {
        guard !identifiers.isEmpty else { return }
        try db.write { db in
            let placeholders = identifiers.map { _ in "?" }.joined(separator: ",")
            let arguments = StatementArguments(identifiers)
            try db.execute(
                sql: """
                    DELETE FROM archive_candidate
                    WHERE assetLocalIdentifier IN (\(placeholders))
                """,
                arguments: arguments
            )
        }
    }

    func markArchiveCandidatesExporting(identifiers: [String]) throws {
        try updateArchiveCandidateStatus(identifiers: identifiers, status: .exporting)
    }

    func markArchiveCandidatesExported(identifiers: [String], archivePath: String, at date: Date = Date()) throws {
        guard !identifiers.isEmpty else { return }
        try db.write { db in
            let placeholders = identifiers.map { _ in "?" }.joined(separator: ",")
            var arguments = StatementArguments()
            arguments += [ArchiveCandidateStatus.exported.rawValue]
            arguments += [date]
            arguments += [archivePath]
            for identifier in identifiers {
                arguments += [identifier]
            }
            try db.execute(
                sql: """
                    UPDATE archive_candidate
                    SET status = ?,
                        exportedAt = ?,
                        archivePath = ?,
                        lastError = NULL
                    WHERE assetLocalIdentifier IN (\(placeholders))
                """,
                arguments: arguments
            )
        }
    }

    func markArchiveCandidatesDeleted(identifiers: [String], at date: Date = Date()) throws {
        guard !identifiers.isEmpty else { return }
        try db.write { db in
            let placeholders = identifiers.map { _ in "?" }.joined(separator: ",")
            var arguments = StatementArguments()
            arguments += [ArchiveCandidateStatus.deleted.rawValue]
            arguments += [date]
            for identifier in identifiers {
                arguments += [identifier]
            }
            try db.execute(
                sql: """
                    UPDATE archive_candidate
                    SET status = ?,
                        deletedAt = ?,
                        lastError = NULL
                    WHERE assetLocalIdentifier IN (\(placeholders))
                """,
                arguments: arguments
            )
        }
    }

    func markArchiveCandidatesFailed(identifiers: [String], error: String) throws {
        guard !identifiers.isEmpty else { return }
        try db.write { db in
            let placeholders = identifiers.map { _ in "?" }.joined(separator: ",")
            var arguments = StatementArguments()
            arguments += [ArchiveCandidateStatus.failed.rawValue]
            arguments += [error]
            for identifier in identifiers {
                arguments += [identifier]
            }
            try db.execute(
                sql: """
                    UPDATE archive_candidate
                    SET status = ?,
                        lastError = ?
                    WHERE assetLocalIdentifier IN (\(placeholders))
                """,
                arguments: arguments
            )
        }
    }

    private func updateArchiveCandidateStatus(identifiers: [String], status: ArchiveCandidateStatus) throws {
        guard !identifiers.isEmpty else { return }
        try db.write { db in
            let placeholders = identifiers.map { _ in "?" }.joined(separator: ",")
            var arguments = StatementArguments()
            arguments += [status.rawValue]
            for identifier in identifiers {
                arguments += [identifier]
            }
            try db.execute(
                sql: """
                    UPDATE archive_candidate
                    SET status = ?
                    WHERE assetLocalIdentifier IN (\(placeholders))
                """,
                arguments: arguments
            )
        }
    }

    func fetchDuplicatesForGrid(limit: Int, offset: Int = 0) throws -> [IndexedAsset] {
        try db.read { db in
            let request = SQLRequest<IndexedAsset>(
                sql: """
                    SELECT a.*
                    FROM asset_active a
                    LEFT JOIN queue_keep_decision qk
                        ON qk.assetLocalIdentifier = a.localIdentifier AND qk.queueKind = 'duplicates'
                    WHERE (
                        (
                            a.fingerprint IS NOT NULL
                            AND a.fingerprint IN (
                                SELECT fingerprint
                                FROM asset
                                WHERE isDeletedFromPhotos = 0
                                  AND fingerprint IS NOT NULL
                                GROUP BY fingerprint
                                HAVING COUNT(*) > 1
                            )
                        )
                        OR (
                            a.nearDuplicateClusterID IS NOT NULL
                            AND a.nearDuplicateClusterID IN (
                                SELECT nearDuplicateClusterID
                                FROM asset
                                WHERE isDeletedFromPhotos = 0
                                  AND nearDuplicateClusterID IS NOT NULL
                                GROUP BY nearDuplicateClusterID
                                HAVING COUNT(*) > 1
                            )
                        )
                    )
                      AND qk.assetLocalIdentifier IS NULL
                    ORDER BY a.creationDate DESC, a.localIdentifier DESC
                    LIMIT ? OFFSET ?
                """,
                arguments: [limit, offset]
            )
            return try request.fetchAll(db)
        }
    }

    func fetchLowQualityForGrid(limit: Int, offset: Int = 0) throws -> [IndexedAsset] {
        try db.read { db in
            let request = SQLRequest<IndexedAsset>(
                sql: """
                    SELECT a.*
                    FROM asset_active a
                    LEFT JOIN queue_keep_decision qk
                        ON qk.assetLocalIdentifier = a.localIdentifier AND qk.queueKind = 'lowQuality'
                    WHERE a.overallScore IS NOT NULL
                      AND a.overallScore < 0.3
                      AND a.isFavorite = 0
                      AND qk.assetLocalIdentifier IS NULL
                    ORDER BY a.creationDate DESC, a.localIdentifier DESC
                    LIMIT ? OFFSET ?
                """,
                arguments: [limit, offset]
            )
            return try request.fetchAll(db)
        }
    }

    func fetchReceiptsAndDocumentsForGrid(limit: Int, offset: Int = 0) throws -> [IndexedAsset] {
        try db.read { db in
            let request = SQLRequest<IndexedAsset>(
                sql: """
                    SELECT a.*
                    FROM asset_active a
                    LEFT JOIN queue_keep_decision qk
                        ON qk.assetLocalIdentifier = a.localIdentifier AND qk.queueKind = 'receiptsAndDocuments'
                    WHERE (
                        a.visionOcrText IS NOT NULL
                        AND LENGTH(TRIM(a.visionOcrText)) >= ?
                        AND (
                            (a.labelsJSON IS NOT NULL AND a.labelsJSON LIKE '%"document"%')
                            OR LOWER(a.visionOcrText) LIKE '%invoice%'
                            OR LOWER(a.visionOcrText) LIKE '%statement%'
                            OR LOWER(a.visionOcrText) LIKE '%policy%'
                            OR LOWER(a.visionOcrText) LIKE '%account%'
                            OR LOWER(a.visionOcrText) LIKE '%contract%'
                            OR LOWER(a.visionOcrText) LIKE '%application%'
                            OR LOWER(a.visionOcrText) LIKE '%certificate%'
                        )
                    )
                      AND qk.assetLocalIdentifier IS NULL
                    ORDER BY a.creationDate DESC, a.localIdentifier DESC
                    LIMIT ? OFFSET ?
                """,
                arguments: [minimumDocumentOCRCharacters, limit, offset]
            )
            return try request.fetchAll(db)
        }
    }

    func countForSidebarKind(_ kind: SidebarItem.Kind) throws -> Int {
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        return try db.read { db in
            switch kind {
            case .allPhotos:
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_active") ?? 0
            case .recents:
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_active WHERE creationDate IS NOT NULL AND creationDate >= ?", arguments: [recentCutoff]) ?? 0
            case .favourites:
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_active WHERE isFavorite = 1") ?? 0
            case .screenshots:
                return try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM asset_active a
                    LEFT JOIN queue_keep_decision qk
                        ON qk.assetLocalIdentifier = a.localIdentifier AND qk.queueKind = 'screenshots'
                    WHERE a.isScreenshot = 1 AND qk.assetLocalIdentifier IS NULL
                """) ?? 0
            case .duplicates:
                return try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM asset_active a
                    LEFT JOIN queue_keep_decision qk
                        ON qk.assetLocalIdentifier = a.localIdentifier AND qk.queueKind = 'duplicates'
                    WHERE (
                        (
                            a.fingerprint IS NOT NULL
                            AND a.fingerprint IN (
                                SELECT fingerprint
                                FROM asset
                                WHERE isDeletedFromPhotos = 0
                                  AND fingerprint IS NOT NULL
                                GROUP BY fingerprint
                                HAVING COUNT(*) > 1
                            )
                        )
                        OR (
                            a.nearDuplicateClusterID IS NOT NULL
                            AND a.nearDuplicateClusterID IN (
                                SELECT nearDuplicateClusterID
                                FROM asset
                                WHERE isDeletedFromPhotos = 0
                                  AND nearDuplicateClusterID IS NOT NULL
                                GROUP BY nearDuplicateClusterID
                                HAVING COUNT(*) > 1
                            )
                        )
                    )
                      AND qk.assetLocalIdentifier IS NULL
                """) ?? 0
            case .lowQuality:
                return try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM asset_active a
                    LEFT JOIN queue_keep_decision qk
                        ON qk.assetLocalIdentifier = a.localIdentifier AND qk.queueKind = 'lowQuality'
                    WHERE a.overallScore IS NOT NULL AND a.overallScore < 0.3 AND a.isFavorite = 0
                      AND qk.assetLocalIdentifier IS NULL
                """) ?? 0
            case .receiptsAndDocuments:
                return try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM asset_active a
                    LEFT JOIN queue_keep_decision qk
                        ON qk.assetLocalIdentifier = a.localIdentifier AND qk.queueKind = 'receiptsAndDocuments'
                    WHERE (
                        a.visionOcrText IS NOT NULL
                        AND LENGTH(TRIM(a.visionOcrText)) >= ?
                        AND (
                            (a.labelsJSON IS NOT NULL AND a.labelsJSON LIKE '%"document"%')
                            OR LOWER(a.visionOcrText) LIKE '%invoice%'
                            OR LOWER(a.visionOcrText) LIKE '%statement%'
                            OR LOWER(a.visionOcrText) LIKE '%policy%'
                            OR LOWER(a.visionOcrText) LIKE '%account%'
                            OR LOWER(a.visionOcrText) LIKE '%contract%'
                            OR LOWER(a.visionOcrText) LIKE '%application%'
                            OR LOWER(a.visionOcrText) LIKE '%certificate%'
                        )
                    )
                      AND qk.assetLocalIdentifier IS NULL
                """, arguments: [minimumDocumentOCRCharacters]) ?? 0
            case .setAsideForArchive:
                return try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM archive_candidate
                    WHERE status IN ('pending', 'exporting', 'failed')
                """) ?? 0
            case .archived:
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM archived_item") ?? 0
            case .indexing, .log:
                return 0
            }
        }
    }

    func fetchArchivedSignatures() throws -> [String: ArchivedItemSignature] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT relativePath, fileSizeBytes, fileModificationDate
                    FROM archived_item
                """
            )
            var signatures: [String: ArchivedItemSignature] = [:]
            signatures.reserveCapacity(rows.count)
            for row in rows {
                guard
                    let relativePath: String = row["relativePath"],
                    let fileModificationDate: Date = row["fileModificationDate"]
                else {
                    continue
                }
                let fileSizeBytes: Int64 = row["fileSizeBytes"] ?? 0
                signatures[relativePath] = ArchivedItemSignature(
                    relativePath: relativePath,
                    fileSizeBytes: fileSizeBytes,
                    fileModificationDate: fileModificationDate
                )
            }
            return signatures
        }
    }

    func upsertArchivedItems(_ items: [ArchivedItem]) throws {
        guard !items.isEmpty else { return }
        let batchSize = 500
        var offset = 0
        while offset < items.count {
            let batch = Array(items[offset ..< min(offset + batchSize, items.count)])
            try db.write { db in
                for item in batch {
                    try item.upsert(db)
                }
            }
            offset += batchSize
        }
    }

    func deleteArchivedItems(relativePaths: [String]) throws {
        guard !relativePaths.isEmpty else { return }
        try db.write { db in
            try db.execute(
                sql: """
                    DELETE FROM archived_item
                    WHERE relativePath IN (\(relativePaths.map { _ in "?" }.joined(separator: ",")))
                """,
                arguments: StatementArguments(relativePaths)
            )
        }
    }

    func keepAssetsInQueue(_ identifiers: [String], queueKind: String, at date: Date = Date()) throws {
        guard !identifiers.isEmpty else { return }
        try db.write { db in
            for identifier in identifiers {
                try db.execute(
                    sql: """
                        INSERT INTO queue_keep_decision (assetLocalIdentifier, queueKind, decidedAt)
                        VALUES (?, ?, ?)
                        ON CONFLICT(assetLocalIdentifier, queueKind) DO UPDATE SET decidedAt = excluded.decidedAt
                    """,
                    arguments: [identifier, queueKind, date]
                )
            }
        }
    }

    func clearKeepDecisions(for queueKind: String) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM queue_keep_decision WHERE queueKind = ?",
                arguments: [queueKind]
            )
        }
    }

    func countKeepDecisions(for queueKind: String) throws -> Int {
        try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM queue_keep_decision WHERE queueKind = ?",
                arguments: [queueKind]
            ) ?? 0
        }
    }

    func upsertAnalysisData(_ results: [AssetAnalysisResult], analysedAt: Date) async throws {
        let batchSize = 500
        var offset = 0
        while offset < results.count {
            let batch = Array(results[offset ..< min(offset + batchSize, results.count)])
            try await db.write { db in
                for result in batch {
                    try db.execute(
                        sql: """
                            UPDATE asset
                            SET overallScore = ?,
                                fileSizeBytes = ?,
                                hasNamedPerson = ?,
                                namedPersonCount = ?,
                                detectedPersonCount = ?,
                                labelsJSON = ?,
                                fingerprint = ?,
                                aiCaption = ?,
                                analysedAt = ?
                            WHERE localIdentifier LIKE ? || '/%'
                        """,
                        arguments: [
                            result.overallScore,
                            result.fileSizeBytes,
                            result.hasNamedPerson,
                            result.namedPersonCount,
                            result.detectedPersonCount,
                            result.labelsJSON,
                            result.fingerprint,
                            result.aiCaption,
                            analysedAt,
                            result.uuid
                        ]
                    )
                }
            }
            offset += batchSize
        }
    }

    func fetchVisionAnalysisCandidates(limit: Int, includePreviouslyAnalysed: Bool) throws -> [VisionAnalysisCandidate] {
        try db.read { db in
            let sql: String
            if includePreviouslyAnalysed {
                sql = """
                    SELECT a.localIdentifier, a.creationDate, a.pixelWidth, a.pixelHeight
                    FROM asset_active a
                    WHERE a.hasLocalOriginal = 1
                    ORDER BY a.creationDate DESC, a.localIdentifier DESC
                    LIMIT ?
                """
            } else {
                sql = """
                    SELECT a.localIdentifier, a.creationDate, a.pixelWidth, a.pixelHeight
                    FROM asset_active a
                    WHERE a.hasLocalOriginal = 1
                      AND a.visionAnalysedAt IS NULL
                    ORDER BY a.creationDate DESC, a.localIdentifier DESC
                    LIMIT ?
                """
            }

            let rows = try Row.fetchAll(db, sql: sql, arguments: [limit])
            return rows.compactMap { row in
                guard let localIdentifier: String = row["localIdentifier"] else { return nil }
                return VisionAnalysisCandidate(
                    localIdentifier: localIdentifier,
                    creationDate: row["creationDate"],
                    pixelWidth: row["pixelWidth"] ?? 0,
                    pixelHeight: row["pixelHeight"] ?? 0
                )
            }
        }
    }

    func upsertVisionAnalysisData(_ results: [VisionAnalysisWriteResult], analysedAt: Date) async throws {
        guard !results.isEmpty else { return }
        let batchSize = 500
        var offset = 0
        while offset < results.count {
            let batch = Array(results[offset ..< min(offset + batchSize, results.count)])
            try await db.write { db in
                for result in batch {
                    try db.execute(
                        sql: """
                            UPDATE asset
                            SET visionOcrText = ?,
                                visionBarcodeDetected = ?,
                                nearDuplicateClusterID = NULL,
                                visionAnalysedAt = ?
                            WHERE localIdentifier = ?
                        """,
                        arguments: [
                            result.ocrText,
                            result.barcodeDetected,
                            analysedAt,
                            result.localIdentifier
                        ]
                    )
                }
            }
            offset += batchSize
        }
    }

    func assignNearDuplicateClusters(_ assignments: [NearDuplicateClusterAssignment]) async throws {
        guard !assignments.isEmpty else { return }
        let batchSize = 500
        var offset = 0
        while offset < assignments.count {
            let batch = Array(assignments[offset ..< min(offset + batchSize, assignments.count)])
            try await db.write { db in
                for assignment in batch {
                    try db.execute(
                        sql: """
                            UPDATE asset
                            SET nearDuplicateClusterID = ?
                            WHERE localIdentifier = ?
                        """,
                        arguments: [
                            assignment.clusterID,
                            assignment.localIdentifier
                        ]
                    )
                }
            }
            offset += batchSize
        }
    }

    private func fetchActiveAssets(whereClause: String?, arguments: StatementArguments, limit: Int, offset: Int) throws -> [IndexedAsset] {
        try db.read { db in
            var sql = """
                SELECT a.*
                FROM asset_active a
            """
            if let whereClause, !whereClause.isEmpty {
                sql += "\nWHERE \(whereClause)"
            }
            sql += "\nORDER BY a.creationDate DESC, a.localIdentifier DESC\nLIMIT ?\nOFFSET ?"
            var finalArguments = arguments
            finalArguments += [limit]
            finalArguments += [offset]
            let request = SQLRequest<IndexedAsset>(sql: sql, arguments: finalArguments)
            return try request.fetchAll(db)
        }
    }
}
