import Foundation
import GRDB

final class DatabaseManager: @unchecked Sendable {

    private(set) var db: DatabaseQueue!
    private(set) var assetRepository: AssetRepository!
    private(set) var jobRepository: JobRepository!

    // MARK: - Open

    func open() throws {
        let url = try databaseURL()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { _ in } // Silence GRDB trace in production; swap in os_log later
        }
        db = try DatabaseQueue(path: url.path, configuration: config)
        try applyMigrations()
        assetRepository = AssetRepository(db: db)
        jobRepository = JobRepository(db: db)
    }

    // MARK: - Location

    private static let legacyContainerName = "com.librarian.app"
    private static let containerName = "com.chrislemarquand.Librarian"

    private func databaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let newDir = appSupport.appendingPathComponent(Self.containerName, isDirectory: true)
        let legacyDir = appSupport.appendingPathComponent(Self.legacyContainerName, isDirectory: true)

        // One-time migration from the old bundle identifier's Application Support folder.
        if !FileManager.default.fileExists(atPath: newDir.path),
           FileManager.default.fileExists(atPath: legacyDir.path) {
            try FileManager.default.moveItem(at: legacyDir, to: newDir)
        }

        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        return newDir.appendingPathComponent("librarian.sqlite")
    }

    // MARK: - Migrations

    private func applyMigrations() throws {
        var migrator = DatabaseMigrator()
        LibrarianMigrations.register(in: &migrator)
        try migrator.migrate(db)
    }
}
