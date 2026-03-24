import Foundation
import GRDB

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
                    WHERE a.isScreenshot = 1
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

    func markWhatsAppFromAlbum(identifiers: [String]) throws {
        guard !identifiers.isEmpty else { return }
        let chunkSize = 500
        var offset = 0
        while offset < identifiers.count {
            let chunk = Array(identifiers[offset ..< min(offset + chunkSize, identifiers.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            try db.write { db in
                try db.execute(
                    sql: "UPDATE asset SET isWhatsApp = 1 WHERE localIdentifier IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
            }
            offset += chunkSize
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

    func recoverStaleArchiveExports(errorMessage: String) throws -> Int {
        // If the app crashes after marking candidates as exported but before delete-step
        // completion, those rows can get stuck in an "exported" limbo and disappear from
        // both All Photos and Set Aside. Recover both transitional states.
        let staleIdentifiers = try fetchArchiveCandidateIdentifiers(statuses: [.exporting, .exported])
        guard !staleIdentifiers.isEmpty else { return 0 }
        try markArchiveCandidatesFailed(identifiers: staleIdentifiers, error: errorMessage)
        return staleIdentifiers.count
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
                    WHERE a.nearDuplicateClusterID IS NOT NULL
                      AND a.nearDuplicateClusterID IN (
                        SELECT nearDuplicateClusterID
                        FROM asset_active
                        WHERE nearDuplicateClusterID IS NOT NULL
                        GROUP BY nearDuplicateClusterID
                        HAVING COUNT(*) > 1
                      )
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
                    WHERE a.overallScore IS NOT NULL
                      AND a.overallScore < 0.3
                      AND a.isFavorite = 0
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
                    ORDER BY a.creationDate DESC, a.localIdentifier DESC
                    LIMIT ? OFFSET ?
                """,
                arguments: [minimumDocumentOCRCharacters, limit, offset]
            )
            return try request.fetchAll(db)
        }
    }

    func fetchWhatsAppForGrid(limit: Int, offset: Int = 0) throws -> [IndexedAsset] {
        try db.read { db in
            let request = SQLRequest<IndexedAsset>(
                sql: """
                    SELECT a.*
                    FROM asset_active a
                    WHERE a.isWhatsApp = 1
                    ORDER BY a.creationDate DESC, a.localIdentifier DESC
                    LIMIT ? OFFSET ?
                """,
                arguments: [limit, offset]
            )
            return try request.fetchAll(db)
        }
    }

    func countForSidebarKind(_ kind: SidebarItem.Kind) throws -> Int {
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        return try db.read { db in try Self.countForSidebarKind(kind, recentCutoff: recentCutoff, minOCR: minimumDocumentOCRCharacters, db: db) }
    }

    func countForSidebarKind(_ kind: SidebarItem.Kind) async throws -> Int {
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        let minOCR = minimumDocumentOCRCharacters
        return try await db.read { db in try Self.countForSidebarKind(kind, recentCutoff: recentCutoff, minOCR: minOCR, db: db) }
    }

    func sidebarBadgeCounts(for kinds: [SidebarItem.Kind]) async throws -> [SidebarItem.Kind: Int] {
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        let minOCR = minimumDocumentOCRCharacters
        return try await db.read { db in
            var counts: [SidebarItem.Kind: Int] = [:]
            counts.reserveCapacity(kinds.count)
            for kind in kinds {
                counts[kind] = try Self.countForSidebarKind(kind, recentCutoff: recentCutoff, minOCR: minOCR, db: db)
            }
            return counts
        }
    }

    private static func countForSidebarKind(_ kind: SidebarItem.Kind, recentCutoff: Date, minOCR: Int, db: GRDB.Database) throws -> Int {
        switch kind {
        case .allPhotos:
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_active") ?? 0
        case .recents:
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_active WHERE creationDate IS NOT NULL AND creationDate >= ?", arguments: [recentCutoff]) ?? 0
        case .favourites:
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_active WHERE isFavorite = 1") ?? 0
        case .screenshots:
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM asset_active WHERE isScreenshot = 1
            """) ?? 0
        case .duplicates:
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM asset_active a
                WHERE a.nearDuplicateClusterID IS NOT NULL
                  AND a.nearDuplicateClusterID IN (
                    SELECT nearDuplicateClusterID
                    FROM asset_active
                    WHERE nearDuplicateClusterID IS NOT NULL
                    GROUP BY nearDuplicateClusterID
                    HAVING COUNT(*) > 1
                  )
            """) ?? 0
        case .lowQuality:
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM asset_active
                WHERE overallScore IS NOT NULL AND overallScore < 0.3 AND isFavorite = 0
            """) ?? 0
        case .receiptsAndDocuments:
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM asset_active a
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
            """, arguments: [minOCR]) ?? 0
        case .whatsapp:
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM asset_active WHERE isWhatsApp = 1
            """) ?? 0
        case .setAsideForArchive:
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM archive_candidate
                WHERE status IN ('pending', 'exporting', 'failed')
            """) ?? 0
        case .archived:
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM archived_item") ?? 0
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

    // MARK: - Archive exact dedupe helpers

    func fetchArchiveCanonicalPath(sha256: String) throws -> String? {
        try db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT relativePath
                    FROM archive_file_fingerprint
                    WHERE sha256 = ?
                      AND isCanonical = 1
                    LIMIT 1
                """,
                arguments: [sha256]
            )
            return row?["relativePath"] as String?
        }
    }

    func upsertArchiveFingerprints(_ fingerprints: [ArchiveFileFingerprint]) throws {
        guard !fingerprints.isEmpty else { return }
        let batchSize = 500
        var offset = 0
        while offset < fingerprints.count {
            let batch = Array(fingerprints[offset ..< min(offset + batchSize, fingerprints.count)])
            try db.write { db in
                for fingerprint in batch {
                    try fingerprint.upsert(db)
                }
            }
            offset += batchSize
        }
    }

    func deleteArchiveFingerprints(relativePaths: [String]) throws {
        guard !relativePaths.isEmpty else { return }
        try db.write { db in
            try db.execute(
                sql: """
                    DELETE FROM archive_file_fingerprint
                    WHERE relativePath IN (\(relativePaths.map { _ in "?" }.joined(separator: ",")))
                """,
                arguments: StatementArguments(relativePaths)
            )
        }
    }

    func saveArchiveDuplicateEvents(_ events: [ArchiveDuplicateEvent]) throws {
        guard !events.isEmpty else { return }
        let batchSize = 500
        var offset = 0
        while offset < events.count {
            let batch = Array(events[offset ..< min(offset + batchSize, events.count)])
            try db.write { db in
                for event in batch {
                    try event.insert(db)
                }
            }
            offset += batchSize
        }
    }

    func countArchiveDuplicateEvents(reason: String? = nil, since: Date? = nil) throws -> Int {
        try db.read { db in
            var clauses: [String] = []
            var arguments = StatementArguments()
            if let reason, !reason.isEmpty {
                clauses.append("reason = ?")
                arguments += [reason]
            }
            if let since {
                clauses.append("createdAt >= ?")
                arguments += [since]
            }

            let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM archive_duplicate_event
                    \(whereClause)
                """,
                arguments: arguments
            ) ?? 0
        }
    }

    @discardableResult
    func claimCanonicalArchiveFingerprint(
        sha256: String,
        candidateRelativePath: String
    ) throws -> String {
        try db.write { db in
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT relativePath
                    FROM archive_file_fingerprint
                    WHERE sha256 = ?
                      AND isCanonical = 1
                    LIMIT 1
                """,
                arguments: [sha256]
            ), let canonicalRelativePath: String = row["relativePath"] {
                return canonicalRelativePath
            }

            try db.execute(
                sql: """
                    UPDATE archive_file_fingerprint
                    SET isCanonical = CASE WHEN relativePath = ? THEN 1 ELSE 0 END,
                        canonicalRelativePath = CASE WHEN relativePath = ? THEN NULL ELSE ? END
                    WHERE sha256 = ?
                """,
                arguments: [candidateRelativePath, candidateRelativePath, candidateRelativePath, sha256]
            )
            return candidateRelativePath
        }
    }

    // MARK: - Archive Import helpers

    /// Returns a set of creation-date strings ("yyyy-MM-dd HH:mm:ss" in local timezone)
    /// for all non-deleted assets. Used for PhotoKit deduplication during archive import.
    /// creationDate is always indexed from PHAsset metadata and requires no analysis pass.
    struct AnalysisFields {
        let overallScore: Double?
        let aiCaption: String?
        let namedPersonCount: Int?
        let detectedPersonCount: Int?
        let visionOcrText: String?
    }

    func fetchAnalysisFields(localIdentifier: String) throws -> AnalysisFields? {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT overallScore, aiCaption, namedPersonCount, detectedPersonCount, visionOcrText
                FROM asset WHERE localIdentifier = ? LIMIT 1
            """, arguments: [localIdentifier]) else { return nil }
            return AnalysisFields(
                overallScore: row["overallScore"],
                aiCaption: row["aiCaption"],
                namedPersonCount: row["namedPersonCount"],
                detectedPersonCount: row["detectedPersonCount"],
                visionOcrText: row["visionOcrText"]
            )
        }
    }

    func fetchFileSizeBytes(localIdentifier: String) throws -> Int? {
        try db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT fileSizeBytes FROM asset WHERE localIdentifier = ? LIMIT 1",
                arguments: [localIdentifier]
            )
            return row?["fileSizeBytes"] as? Int
        }
    }

    struct FileSizeStats {
        let knownBytes: Int64
        let unknownCount: Int
    }

    func fetchFileSizeStats(localIdentifiers: [String]) throws -> FileSizeStats {
        guard !localIdentifiers.isEmpty else {
            return FileSizeStats(knownBytes: 0, unknownCount: 0)
        }
        return try db.read { db in
            let placeholders = localIdentifiers.map { _ in "?" }.joined(separator: ",")
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        COALESCE(SUM(CASE WHEN fileSizeBytes IS NOT NULL THEN fileSizeBytes ELSE 0 END), 0) AS knownBytes,
                        COALESCE(SUM(CASE WHEN fileSizeBytes IS NULL THEN 1 ELSE 0 END), 0) AS unknownCount
                    FROM asset
                    WHERE localIdentifier IN (\(placeholders))
                """,
                arguments: StatementArguments(localIdentifiers)
            )
            return FileSizeStats(
                knownBytes: row?["knownBytes"] ?? 0,
                unknownCount: row?["unknownCount"] ?? 0
            )
        }
    }

    func fetchAssetDateSecondIndex() throws -> Set<String> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // Local timezone so it matches how EXIF timestamps are parsed (no tz in EXIF strings).

        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT creationDate
                FROM asset
                WHERE isDeletedFromPhotos = 0
                  AND creationDate IS NOT NULL
            """)
            var index = Set<String>()
            index.reserveCapacity(rows.count)
            for row in rows {
                guard let date: Date = row["creationDate"] else { continue }
                index.insert(formatter.string(from: date))
            }
            return index
        }
    }

    func fetchPhotoLibraryContentHash(localIdentifier: String) throws -> String? {
        try db.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT contentHashSHA256
                    FROM asset
                    WHERE localIdentifier = ?
                    LIMIT 1
                """,
                arguments: [localIdentifier]
            )
            return row?["contentHashSHA256"] as String?
        }
    }

    func updatePhotoLibraryContentHash(localIdentifier: String, hashHex: String?) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE asset
                    SET contentHashSHA256 = ?
                    WHERE localIdentifier = ?
                """,
                arguments: [hashHex, localIdentifier]
            )
        }
    }

    /// Prefilter candidates for exact dedupe checks. Uses cheap key matching against
    /// indexed PhotoKit metadata before any expensive byte hashing.
    /// - Parameters:
    ///   - fileSizeBytes: Incoming file size, if known.
    ///   - creationDate: Incoming best-effort capture date, if known.
    ///   - maxResults: Safety cap to avoid unbounded scans from weak prefilters.
    func fetchPhotoLibraryHashCandidates(
        fileSizeBytes: Int?,
        creationDate: Date?,
        maxResults: Int = 500
    ) throws -> [PhotoLibraryHashCandidate] {
        guard fileSizeBytes != nil || creationDate != nil else { return [] }

        var clauses: [String] = [
            "isDeletedFromPhotos = 0",
            "mediaType = 1"
        ]
        var arguments = StatementArguments()

        if let fileSizeBytes {
            clauses.append("fileSizeBytes = ?")
            arguments += [fileSizeBytes]
        }
        if let creationDate {
            // Keep this strict for deterministic candidate narrowing.
            clauses.append("creationDate = ?")
            arguments += [creationDate]
        }

        let whereClause = clauses.joined(separator: " AND ")
        arguments += [maxResults]

        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT localIdentifier, fileSizeBytes, creationDate, contentHashSHA256
                    FROM asset
                    WHERE \(whereClause)
                    ORDER BY creationDate DESC, localIdentifier DESC
                    LIMIT ?
                """,
                arguments: arguments
            )

            return rows.compactMap { row in
                guard let localIdentifier: String = row["localIdentifier"] else { return nil }
                return PhotoLibraryHashCandidate(
                    localIdentifier: localIdentifier,
                    fileSizeBytes: row["fileSizeBytes"],
                    creationDate: row["creationDate"],
                    contentHashSHA256: row["contentHashSHA256"]
                )
            }
        }
    }

    func saveArchiveImportRun(
        id: String,
        startedAt: Date,
        summary: ArchiveImportRunSummary,
        archiveRootPath: String,
        sourcePaths: [String]
    ) throws {
        let sourcePathsJSON = (try? JSONEncoder().encode(sourcePaths))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let failureDetailsJSON: String? = summary.failures.isEmpty ? nil : {
            let details = summary.failures.map { ["path": $0.path, "reason": $0.reason] }
            return (try? JSONEncoder().encode(details)).flatMap { String(data: $0, encoding: .utf8) }
        }()
        let discovered = summary.imported + summary.skippedDuplicateInSource + summary.skippedExistsInPhotoKit + summary.skippedExistsInArchive + summary.failed
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO archive_import_run
                        (id, startedAt, completedAt, archiveRootPath, sourcePathsJSON,
                         discovered, imported, skippedDuplicateInSource, skippedExistsInPhotoKit, skippedExistsInArchive,
                         failed, failureDetailsJSON)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id,
                    startedAt,
                    summary.completedAt,
                    archiveRootPath,
                    sourcePathsJSON,
                    discovered,
                    summary.imported,
                    summary.skippedDuplicateInSource,
                    summary.skippedExistsInPhotoKit,
                    summary.skippedExistsInArchive,
                    summary.failed,
                    failureDetailsJSON
                ]
            )
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

    func countVisionAnalysisCandidates(includePreviouslyAnalysed: Bool) throws -> Int {
        try db.read { db in
            if includePreviouslyAnalysed {
                return try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM asset_active a
                        WHERE a.hasLocalOriginal = 1
                    """
                ) ?? 0
            } else {
                return try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM asset_active a
                        WHERE a.hasLocalOriginal = 1
                          AND a.visionAnalysedAt IS NULL
                    """
                ) ?? 0
            }
        }
    }

    func analysisHasRunBefore() throws -> Bool {
        try db.read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM asset_active a
                    WHERE a.visionAnalysedAt IS NOT NULL
                    LIMIT 1
                """
            ) ?? 0
            return count > 0
        }
    }

    func lastAnalysedDate() throws -> Date? {
        try db.read { db in
            try Date.fetchOne(
                db,
                sql: """
                    SELECT MAX(d) FROM (
                        SELECT MAX(analysedAt) AS d FROM asset_active WHERE analysedAt IS NOT NULL
                        UNION ALL
                        SELECT MAX(visionAnalysedAt) AS d FROM asset_active WHERE visionAnalysedAt IS NOT NULL
                    )
                """
            )
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
                                visionSaliencyScore = ?,
                                visionFeaturePrint = ?,
                                visionAnalysedAt = ?
                            WHERE localIdentifier = ?
                        """,
                        arguments: [
                            result.ocrText,
                            result.saliencyScore,
                            result.featurePrintData,
                            analysedAt,
                            result.localIdentifier
                        ]
                    )
                }
            }
            offset += batchSize
        }
    }

    func clearNearDuplicateClusters(for localIdentifiers: [String]) async throws {
        guard !localIdentifiers.isEmpty else { return }
        let batchSize = 500
        var offset = 0
        while offset < localIdentifiers.count {
            let batch = Array(localIdentifiers[offset ..< min(offset + batchSize, localIdentifiers.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            try await db.write { db in
                try db.execute(
                    sql: "UPDATE asset SET nearDuplicateClusterID = NULL WHERE localIdentifier IN (\(placeholders))",
                    arguments: StatementArguments(batch)
                )
            }
            offset += batchSize
        }
    }

    func clearAllNearDuplicateClusters() async throws {
        try await db.write { db in
            try db.execute(
                sql: "UPDATE asset SET nearDuplicateClusterID = NULL WHERE nearDuplicateClusterID IS NOT NULL"
            )
        }
    }

    func fetchAllFeaturePrints() throws -> [StoredFeaturePrint] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.localIdentifier, a.creationDate, a.pixelWidth, a.pixelHeight, a.visionFeaturePrint
                FROM asset_active a
                WHERE a.visionFeaturePrint IS NOT NULL
                ORDER BY a.creationDate ASC, a.localIdentifier ASC
            """)
            return rows.compactMap { row -> StoredFeaturePrint? in
                guard let data = row["visionFeaturePrint"] as? Data else { return nil }
                return StoredFeaturePrint(
                    localIdentifier: row["localIdentifier"],
                    creationDate: row["creationDate"],
                    pixelWidth: row["pixelWidth"],
                    pixelHeight: row["pixelHeight"],
                    featurePrintData: data
                )
            }
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
