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
    private static let photosDefaultBookmarkSource = "photos-default-library-bookmark-v1"
    private static let picturesDirectoryHeuristicSource = "pictures-directory-heuristic-v1"
    private static let photosDefaultsDomain = "com.apple.Photos"
    private static let photosDefaultLibraryBookmarkKey = "IPXDefaultLibraryURLBookmark"

    static func currentFingerprint(fileManager: FileManager = .default) throws -> PhotoLibraryFingerprint {
        guard let resolved = findPhotosLibraryURL(fileManager: fileManager) else {
            throw PhotoLibraryFingerprintError.noLibraryURLFound
        }
        let fingerprintInput = buildFingerprintInput(for: resolved.url)
        guard !fingerprintInput.isEmpty else {
            throw PhotoLibraryFingerprintError.fingerprintInputUnavailable
        }
        return PhotoLibraryFingerprint(
            fingerprint: "sha256:\(sha256Hex(fingerprintInput))",
            source: resolved.source,
            pathHint: resolved.url.path
        )
    }

    private static func findPhotosLibraryURL(fileManager: FileManager) -> (url: URL, source: String)? {
        if let defaultURL = defaultPhotosLibraryURLFromPreferences() {
            return (defaultURL, photosDefaultBookmarkSource)
        }

        guard let picturesURL = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first,
              let contents = try? fileManager.contentsOfDirectory(
                at: picturesURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return nil
        }
        guard let heuristicURL = contents.first(where: { $0.pathExtension == "photoslibrary" }) else {
            return nil
        }
        return (heuristicURL.standardizedFileURL, picturesDirectoryHeuristicSource)
    }

    // Candidate plist paths in preference order. Photos.app is sandboxed on macOS
    // so its prefs live in the container; the non-container path is a fallback for
    // older OS versions or edge cases.
    private static var preferencesPlistCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(
                "Library/Containers/com.apple.Photos/Data/Library/Preferences/com.apple.Photos.plist"
            ),
            home.appendingPathComponent("Library/Preferences/com.apple.Photos.plist"),
        ]
    }

    private static func defaultPhotosLibraryURLFromPreferences() -> URL? {
        // Read the plist file directly from disk on every call to bypass the
        // CFPreferences / UserDefaults in-process cache, which does not reliably
        // reflect writes made by Photos.app after our process started.
        for plistURL in preferencesPlistCandidates {
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = plist as? [String: Any],
                  let bookmarkData = dict[photosDefaultLibraryBookmarkKey] as? Data
            else { continue }

            var isStale = false
            guard let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }

            let standardized = resolvedURL.standardizedFileURL
            guard standardized.pathExtension == "photoslibrary" else { continue }
            return standardized
        }
        return nil
    }

    private static func buildFingerprintInput(for libraryURL: URL) -> String {
        let standardizedPath = libraryURL.standardizedFileURL.path
        let keys: Set<URLResourceKey> = [
            .creationDateKey,
            .fileResourceIdentifierKey,
            .volumeIdentifierKey
        ]
        let values = try? libraryURL.resourceValues(forKeys: keys)
        let creation = values?.creationDate?.timeIntervalSince1970.description ?? ""
        let fileID = values?.fileResourceIdentifier.map { String(describing: $0) } ?? ""
        let volumeID = values?.volumeIdentifier.map { String(describing: $0) } ?? ""
        return [
            "path:\(standardizedPath)",
            "creation:\(creation)",
            "fileID:\(fileID)",
            "volumeID:\(volumeID)"
        ].joined(separator: "\n")
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
