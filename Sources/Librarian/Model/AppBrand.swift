import Foundation

enum AppBrand {
    private static let fallbackDisplayName = "Librarian"

    static var displayName: String {
        let bundle = Bundle.main
        if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return display
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return fallbackDisplayName
    }

    static var identifierPrefix: String {
        let cleaned = displayName.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return cleaned.isEmpty ? fallbackDisplayName : cleaned
    }
}
