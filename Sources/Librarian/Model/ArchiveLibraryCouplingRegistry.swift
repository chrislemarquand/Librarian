import Foundation

struct ArchiveLibraryCouplingEntry: Codable, Equatable {
    let libraryFingerprint: String
    let archiveID: String?
    let archiveBookmarkBase64: String
    let archiveRootPathHint: String?
    let libraryPathHint: String?
    let updatedAt: Date
}

enum ArchiveLibraryCouplingRegistry {
    private static let defaultsKey = "com.librarian.app.archiveLibraryCouplings.v1"

    static func coupling(for libraryFingerprint: String) -> ArchiveLibraryCouplingEntry? {
        loadStore().entries[libraryFingerprint]
    }

    static func upsert(
        libraryFingerprint: String,
        archiveRootURL: URL,
        archiveID: String?,
        libraryPathHint: String?
    ) {
        guard let bookmarkData = try? archiveRootURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            AppLog.shared.error("Failed to create archive bookmark for coupling registry")
            return
        }

        var store = loadStore()
        store.entries[libraryFingerprint] = ArchiveLibraryCouplingEntry(
            libraryFingerprint: libraryFingerprint,
            archiveID: archiveID,
            archiveBookmarkBase64: bookmarkData.base64EncodedString(),
            archiveRootPathHint: archiveRootURL.path,
            libraryPathHint: libraryPathHint,
            updatedAt: Date()
        )
        saveStore(store)
    }

    static func resolveArchiveRootURL(for libraryFingerprint: String) -> URL? {
        guard let coupling = coupling(for: libraryFingerprint),
              let bookmarkData = Data(base64Encoded: coupling.archiveBookmarkBase64)
        else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale {
            upsert(
                libraryFingerprint: coupling.libraryFingerprint,
                archiveRootURL: url,
                archiveID: coupling.archiveID,
                libraryPathHint: coupling.libraryPathHint
            )
        }
        return url
    }

    // MARK: - Store

    private struct Store: Codable {
        var entries: [String: ArchiveLibraryCouplingEntry]
    }

    private static func loadStore() -> Store {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return Store(entries: [:])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Store.self, from: data)) ?? Store(entries: [:])
    }

    private static func saveStore(_ store: Store) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(store) else {
            AppLog.shared.error("Failed to encode archive coupling registry")
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
