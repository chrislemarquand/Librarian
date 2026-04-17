import Foundation
import GRDB

/// Reads an osxphotos `.osxphotos_export.db` export database.
///
/// This type is self-contained — it opens its own read-only GRDB queue
/// and does not interact with the app's primary database.
struct OsxPhotosExportDatabase {

    struct ExportRecord {
        /// Relative file path within the backup folder, e.g. "2023/06/30/IMG_6173.HEIC".
        let relativePath: String
        /// Bare PhotoKit UUID (without the `/L0/001` suffix) as written by osxphotos, if recorded.
        let uuid: String?
        /// Hash of the exported file as written by osxphotos, if present.
        let digest: String?
        /// Size in bytes of the original asset in the Photos library, if present.
        let srcSize: Int?
    }

    let url: URL

    /// Returns the URL of `.osxphotos_export.db` inside `backupFolder`, or nil if absent.
    static func locate(in backupFolder: URL) -> URL? {
        let candidate = backupFolder.appendingPathComponent(".osxphotos_export.db")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Streams `export_data` via cursor and builds a lowercased-filepath → bare-UUID map.
    ///
    /// Uses a cursor rather than `fetchAll` to avoid holding two full copies of the table
    /// in memory simultaneously (intermediate `[Row]` array + mapped result array).
    /// Where a filepath appears more than once (multiple export runs), the last UUID wins.
    func loadPathToUUIDMap() throws -> [String: String] {
        let queue = try makeReadOnlyQueue()
        return try queue.read { db in
            var map: [String: String] = [:]
            let cursor = try Row.fetchCursor(db, sql: "SELECT filepath, uuid FROM export_data WHERE uuid IS NOT NULL")
            while let row = try cursor.next() {
                guard let filepath: String = row["filepath"],
                      let uuid: String = row["uuid"] else { continue }
                // Normalise to bare UUID: strip any "/L0/..." suffix the DB may already contain.
                // osxphotos behaviour varies — some versions store the full PhotoKit localIdentifier,
                // others store only the bare UUID. The coordinator always appends "/L0/001", so we
                // must guarantee the stored value is always bare.
                let bareUUID = uuid.components(separatedBy: "/").first ?? uuid
                map[filepath.lowercased()] = bareUUID
            }
            return map
        }
    }

    /// Loads all rows from `export_data`. Throws if the database cannot be opened.
    func loadRecords() throws -> [ExportRecord] {
        let queue = try makeReadOnlyQueue()
        return try queue.read { db in
            var records: [ExportRecord] = []
            let cursor = try Row.fetchCursor(db, sql: "SELECT filepath, uuid, digest, src_size FROM export_data")
            while let row = try cursor.next() {
                records.append(ExportRecord(
                    relativePath: row["filepath"] ?? "",
                    uuid: row["uuid"],
                    digest: row["digest"],
                    srcSize: row["src_size"]
                ))
            }
            return records
        }
    }

    /// Returns the set of all non-nil UUIDs recorded in `export_data`.
    func allUUIDs() throws -> Set<String> {
        let queue = try makeReadOnlyQueue()
        return try queue.read { db in
            var uuids = Set<String>()
            let cursor = try Row.fetchCursor(db, sql: "SELECT uuid FROM export_data WHERE uuid IS NOT NULL")
            while let row = try cursor.next() {
                if let uuid: String = row["uuid"] { uuids.insert(uuid) }
            }
            return uuids
        }
    }

    // MARK: - Private

    private func makeReadOnlyQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: url.path, configuration: config)
    }
}
