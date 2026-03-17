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

    func fetchAll() throws -> [IndexedAsset] {
        try db.read { db in
            try IndexedAsset.fetchAll(db)
        }
    }

    func fetchForGrid(limit: Int) throws -> [IndexedAsset] {
        try db.read { db in
            try IndexedAsset
                .filter(Column("isDeletedFromPhotos") == false)
                .order(Column("creationDate").desc, Column("localIdentifier").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func fetchFavouritesForGrid(limit: Int) throws -> [IndexedAsset] {
        try db.read { db in
            try IndexedAsset
                .filter(Column("isDeletedFromPhotos") == false)
                .filter(Column("isFavorite") == true)
                .order(Column("creationDate").desc, Column("localIdentifier").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func fetchRecentsForGrid(since date: Date, limit: Int) throws -> [IndexedAsset] {
        try db.read { db in
            try IndexedAsset
                .filter(Column("isDeletedFromPhotos") == false)
                .filter(Column("creationDate") != nil)
                .filter(Column("creationDate") >= date)
                .order(Column("creationDate").desc, Column("localIdentifier").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func fetchScreenshotsForReview(limit: Int) throws -> [IndexedAsset] {
        try db.read { db in
            let request = SQLRequest<IndexedAsset>(
                sql: """
                    SELECT a.*
                    FROM asset a
                    LEFT JOIN screenshot_review sr
                    ON sr.assetLocalIdentifier = a.localIdentifier
                    WHERE a.isDeletedFromPhotos = 0
                      AND a.isScreenshot = 1
                      AND (sr.decision IS NULL OR sr.decision = ?)
                    ORDER BY a.creationDate DESC, a.localIdentifier DESC
                    LIMIT ?
                """,
                arguments: [ScreenshotReviewDecision.none.rawValue, limit]
            )
            return try request.fetchAll(db)
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
}
