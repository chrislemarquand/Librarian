import Testing
import GRDB
import Foundation
@testable import Librarian

func makeMigratedDatabaseQueue() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    LibrarianMigrations.register(in: &migrator)
    try migrator.migrate(dbQueue)
    return dbQueue
}

func withArchiveDefaultsBackup(_ operation: () throws -> Void) rethrows {
    let defaults = UserDefaults.standard
    let bookmarkBackup = defaults.object(forKey: ArchiveSettings.bookmarkKey)
    let archiveIDBackup = defaults.object(forKey: ArchiveSettings.archiveIDKey)
    defer {
        if let bookmarkBackup {
            defaults.set(bookmarkBackup, forKey: ArchiveSettings.bookmarkKey)
        } else {
            defaults.removeObject(forKey: ArchiveSettings.bookmarkKey)
        }
        if let archiveIDBackup {
            defaults.set(archiveIDBackup, forKey: ArchiveSettings.archiveIDKey)
        } else {
            defaults.removeObject(forKey: ArchiveSettings.archiveIDKey)
        }
    }
    try operation()
}

@MainActor
func withArchiveDefaultsBackupAsync(_ operation: () async throws -> Void) async rethrows {
    let defaults = UserDefaults.standard
    let bookmarkBackup = defaults.object(forKey: ArchiveSettings.bookmarkKey)
    let archiveIDBackup = defaults.object(forKey: ArchiveSettings.archiveIDKey)
    defer {
        if let bookmarkBackup {
            defaults.set(bookmarkBackup, forKey: ArchiveSettings.bookmarkKey)
        } else {
            defaults.removeObject(forKey: ArchiveSettings.bookmarkKey)
        }
        if let archiveIDBackup {
            defaults.set(archiveIDBackup, forKey: ArchiveSettings.archiveIDKey)
        } else {
            defaults.removeObject(forKey: ArchiveSettings.archiveIDKey)
        }
    }
    try await operation()
}
