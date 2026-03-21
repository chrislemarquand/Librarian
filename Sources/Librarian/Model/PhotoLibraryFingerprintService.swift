import Foundation
import CryptoKit

struct PhotoLibraryFingerprint: Equatable {
    let fingerprint: String
    let source: String
    let pathHint: String?
}

enum PhotoLibraryFingerprintError: LocalizedError {
    case noLibraryURLFound
    case fingerprintInputUnavailable

    var errorDescription: String? {
        switch self {
        case .noLibraryURLFound:
            return "Could not locate the active Photos library."
        case .fingerprintInputUnavailable:
            return "Could not derive a stable fingerprint for the active Photos library."
        }
    }
}

enum PhotoLibraryFingerprintService {
    private static let sourceName = "pictures-directory-heuristic-v1"

    static func currentFingerprint(fileManager: FileManager = .default) throws -> PhotoLibraryFingerprint {
        guard let libraryURL = findPhotosLibraryURL(fileManager: fileManager) else {
            throw PhotoLibraryFingerprintError.noLibraryURLFound
        }
        let fingerprintInput = buildFingerprintInput(for: libraryURL)
        guard !fingerprintInput.isEmpty else {
            throw PhotoLibraryFingerprintError.fingerprintInputUnavailable
        }
        return PhotoLibraryFingerprint(
            fingerprint: "sha256:\(sha256Hex(fingerprintInput))",
            source: sourceName,
            pathHint: libraryURL.path
        )
    }

    private static func findPhotosLibraryURL(fileManager: FileManager) -> URL? {
        guard let picturesURL = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first,
              let contents = try? fileManager.contentsOfDirectory(
                at: picturesURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return nil
        }
        return contents.first { $0.pathExtension == "photoslibrary" }
    }

    private static func buildFingerprintInput(for libraryURL: URL) -> String {
        let standardizedPath = libraryURL.standardizedFileURL.path
        let keys: Set<URLResourceKey> = [
            .creationDateKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .volumeIdentifierKey
        ]
        let values = try? libraryURL.resourceValues(forKeys: keys)
        let creation = values?.creationDate?.timeIntervalSince1970.description ?? ""
        let modified = values?.contentModificationDate?.timeIntervalSince1970.description ?? ""
        let fileID = values?.fileResourceIdentifier.map { String(describing: $0) } ?? ""
        let volumeID = values?.volumeIdentifier.map { String(describing: $0) } ?? ""
        return [
            "path:\(standardizedPath)",
            "creation:\(creation)",
            "modified:\(modified)",
            "fileID:\(fileID)",
            "volumeID:\(volumeID)"
        ].joined(separator: "\n")
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
