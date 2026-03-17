import Foundation
import GRDB

final class DatabaseManager {

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

    private func databaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("com.librarian.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("librarian.sqlite")
    }

    // MARK: - Migrations

    private func applyMigrations() throws {
        var migrator = DatabaseMigrator()
        LibrarianMigrations.register(in: &migrator)
        try migrator.migrate(db)
    }
}
