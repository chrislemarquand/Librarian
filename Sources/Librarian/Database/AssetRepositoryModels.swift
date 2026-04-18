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
    var isCloudShared: Bool
    var isWhatsApp: Bool
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
    let photoTitle: String?
    let photoDescription: String?
    let photoKeywords: String?
    let dateAddedToLibrary: Date?
    let place: String?
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
    let saliencyScore: Double?
    let featurePrintData: Data?
}

struct NearDuplicateClusterAssignment {
    let localIdentifier: String
    let clusterID: String
}

struct StoredFeaturePrint {
    let localIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let featurePrintData: Data
}

struct ArchivedItem: Codable, FetchableRecord, PersistableRecord {
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

struct PhotoLibraryHashCandidate {
    let localIdentifier: String
    let fileSizeBytes: Int?
    let creationDate: Date?
    let contentHashSHA256: String?
}

enum ArchiveFingerprintState: String {
    case verified
    case indeterminate
    case missing
}

struct ArchiveFileFingerprint: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "archive_file_fingerprint"

    var relativePath: String
    var sha256: String?
    var fileSizeBytes: Int64
    var fileModificationDate: Date
    var captureDate: Date?
    var firstSeenAt: Date
    var lastVerifiedAt: Date
    var isCanonical: Bool
    var canonicalRelativePath: String?
    var ingestSource: String
    var state: String
}

struct ArchiveDuplicateEvent: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "archive_duplicate_event"

    var id: String
    var incomingRelativePath: String
    var canonicalRelativePath: String?
    var incomingSHA256: String?
    var reason: String
    var flow: String
    var createdAt: Date
}
