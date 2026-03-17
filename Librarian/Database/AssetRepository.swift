import Foundation
import GRDB

// MARK: - IndexedAsset (GRDB record)

struct IndexedAsset: Codable, FetchableRecord, PersistableRecord {
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

// MARK: - AssetRepository

final class AssetRepository {

    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Read

    func count() throws -> Int {
        try db.read { db in
            try IndexedAsset.fetchCount(db)
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

    func fetchForGrid(limit: Int) throws -> [IndexedAsset] {
        try fetchActiveAssets(whereClause: nil, arguments: StatementArguments(), limit: limit)
    }

    func fetchFavouritesForGrid(limit: Int) throws -> [IndexedAsset] {
        try fetchActiveAssets(whereClause: "a.isFavorite = 1", arguments: StatementArguments(), limit: limit)
    }

    func fetchRecentsForGrid(since date: Date, limit: Int) throws -> [IndexedAsset] {
        try fetchActiveAssets(
            whereClause: "a.creationDate IS NOT NULL AND a.creationDate >= ?",
            arguments: StatementArguments([date]),
            limit: limit
        )
    }

    func fetchScreenshotsForReview(limit: Int) throws -> [IndexedAsset] {
        try db.read { db in
            let request = SQLRequest<IndexedAsset>(
                sql: """
                    SELECT a.*
                    FROM asset_active a
                    LEFT JOIN screenshot_review sr
                    ON sr.assetLocalIdentifier = a.localIdentifier
                    WHERE a.isScreenshot = 1
                      AND (sr.decision IS NULL OR sr.decision = ?)
                    ORDER BY a.creationDate DESC, a.localIdentifier DESC
                    LIMIT ?
                """,
                arguments: [ScreenshotReviewDecision.none.rawValue, limit]
            )
            return try request.fetchAll(db)
        }
    }

    func fetchArchiveCandidatesForGrid(limit: Int) throws -> [IndexedAsset] {
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
                """,
                arguments: [
                    ArchiveCandidateStatus.pending.rawValue,
                    ArchiveCandidateStatus.exporting.rawValue,
                    ArchiveCandidateStatus.failed.rawValue,
                    limit
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
    func upsert(_ assets: [IndexedAsset]) throws {
        try db.write { db in
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

    private func fetchActiveAssets(whereClause: String?, arguments: StatementArguments, limit: Int) throws -> [IndexedAsset] {
        try db.read { db in
            var sql = """
                SELECT a.*
                FROM asset_active a
            """
            if let whereClause, !whereClause.isEmpty {
                sql += "\nWHERE \(whereClause)"
            }
            sql += "\nORDER BY a.creationDate DESC, a.localIdentifier DESC\nLIMIT ?"
            var finalArguments = arguments
            finalArguments += [limit]
            let request = SQLRequest<IndexedAsset>(sql: sql, arguments: finalArguments)
            return try request.fetchAll(db)
        }
    }
}
