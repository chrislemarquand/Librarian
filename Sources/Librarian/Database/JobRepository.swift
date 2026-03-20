import Foundation
import GRDB

// MARK: - Job (GRDB record)

struct Job: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "job"

    enum JobType: String, Codable {
        case initialIndex
        case incrementalSync
        case thumbnailWarmup
        case iCloudDownload
        case ocrAnalysis
        case duplicateAnalysis
        case contextClustering
        case archiveExport
        case archiveVerification
        case photosDeletion
        case archiveRootMigration
        case visionAnalysis
        case nearDuplicateClustering
        case archiveImport
    }

    enum JobState: String, Codable {
        case pending
        case running
        case completed
        case failed
        case cancelled
    }

    var id: String
    var type: String
    var state: String
    var progress: Double
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var payloadJSON: String?
    var errorText: String?
}

// MARK: - JobRepository

final class JobRepository: @unchecked Sendable {

    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Create

    func create(type: Job.JobType) async throws -> Job {
        let job = Job(
            id: UUID().uuidString,
            type: type.rawValue,
            state: Job.JobState.pending.rawValue,
            progress: 0,
            createdAt: Date(),
            startedAt: nil,
            finishedAt: nil,
            payloadJSON: nil,
            errorText: nil
        )
        try await db.write { db in try job.insert(db) }
        return job
    }

    // MARK: - Update

    func markRunning(_ job: Job) async throws {
        var copy = job
        copy.state = Job.JobState.running.rawValue
        copy.startedAt = Date()
        let updated = copy
        try await db.write { db in try updated.update(db) }
    }

    func updateProgress(_ job: Job, progress: Double) throws {
        var updated = job
        updated.progress = progress
        try db.write { db in try updated.update(db) }
    }

    func markCompleted(_ job: Job) async throws {
        var copy = job
        copy.state = Job.JobState.completed.rawValue
        copy.progress = 1.0
        copy.finishedAt = Date()
        let updated = copy
        try await db.write { db in try updated.update(db) }
    }

    func markFailed(_ job: Job, error: String) async throws {
        var copy = job
        copy.state = Job.JobState.failed.rawValue
        copy.finishedAt = Date()
        copy.errorText = error
        let updated = copy
        try await db.write { db in try updated.update(db) }
    }

    // MARK: - Query

    func fetchRunning(type: Job.JobType) throws -> Job? {
        try db.read { db in
            try Job.filter(
                Column("type") == type.rawValue &&
                Column("state") == Job.JobState.running.rawValue
            ).fetchOne(db)
        }
    }
}
