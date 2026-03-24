import Foundation
import ImageIO

struct ArchiveOrganizationResult {
    let scannedCount: Int
    let movedCount: Int
    let alreadyOrganizedCount: Int
    let collisionCount: Int
}

final class ArchiveOrganizer: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]

    func scanUnorganizedCount(in archiveTreeRoot: URL) throws -> Int {
        try withArchiveAccess(root: archiveTreeRoot) { root in
            guard try archiveTreeExists(root) else { return 0 }
            var count = 0
            try enumerateRegularFiles(in: root) { fileURL, relativeComponents, _ in
                let parentComponents = Array(relativeComponents.dropLast())
                if !isOrganizedPath(parentComponents) {
                    count += 1
                }
            }
            return count
        }
    }

    func organizeArchiveTree(in archiveTreeRoot: URL) throws -> ArchiveOrganizationResult {
        try withArchiveAccess(root: archiveTreeRoot) { root in
            guard try archiveTreeExists(root) else {
                return ArchiveOrganizationResult(scannedCount: 0, movedCount: 0, alreadyOrganizedCount: 0, collisionCount: 0)
            }

            var scannedCount = 0
            var candidates: [(url: URL, fallbackDate: Date)] = []
            try enumerateRegularFiles(in: root) { fileURL, relativeComponents, resourceValues in
                scannedCount += 1
                let parentComponents = Array(relativeComponents.dropLast())
                guard !isOrganizedPath(parentComponents) else { return }
                let fallbackDate = resourceValues.contentModificationDate ?? Date()
                candidates.append((fileURL, fallbackDate))
            }

            var movedCount = 0
            var collisionCount = 0

            for candidate in candidates {
                let sourceURL = candidate.url
                let targetDate = readCaptureDateIfAvailable(from: sourceURL) ?? candidate.fallbackDate
                let datePath = datePathComponents(for: targetDate)

                var destinationDirectory = root
                for component in destinationPathComponents(for: datePath) {
                    destinationDirectory.appendPathComponent(component, isDirectory: true)
                }
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

                let destinationURL = uniqueDestinationURL(in: destinationDirectory, fileName: sourceURL.lastPathComponent)
                if destinationURL.lastPathComponent != sourceURL.lastPathComponent {
                    collisionCount += 1
                }

                if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
                    continue
                }
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                movedCount += 1
            }
            removeEmptyDirectories(in: root)

            return ArchiveOrganizationResult(
                scannedCount: scannedCount,
                movedCount: movedCount,
                alreadyOrganizedCount: scannedCount - candidates.count,
                collisionCount: collisionCount
            )
        }
    }

    private func withArchiveAccess<T>(root: URL, operation: (URL) throws -> T) throws -> T {
        let didAccess = root.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                root.stopAccessingSecurityScopedResource()
            }
        }
        return try operation(root)
    }

    private func archiveTreeExists(_ root: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func enumerateRegularFiles(
        in root: URL,
        visitor: (URL, [String], URLResourceValues) throws -> Void
    ) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return
        }

        let rootComponents = root.standardizedFileURL.pathComponents
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasPrefix(".") {
                continue
            }
            let standardized = fileURL.standardizedFileURL
            let fileComponents = standardized.pathComponents
            guard fileComponents.count > rootComponents.count else { continue }
            guard Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { continue }

            let relativeComponents = Array(fileComponents.dropFirst(rootComponents.count))
            guard !relativeComponents.isEmpty else { continue }
            guard relativeComponents.first != ".librarian-thumbnails" else { continue }
            guard relativeComponents.first != "Already in Photo Library" else { continue }
            guard relativeComponents.first != "Needs Review" else { continue }

            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            try visitor(fileURL, relativeComponents, values)
        }
    }

    private func isOrganizedDatePath(_ components: [String]) -> Bool {
        guard components.count >= 3 else { return false }
        let year = components[components.count - 3]
        let month = components[components.count - 2]
        let day = components[components.count - 1]
        return isYear(year) && isMonth(month) && isDay(day)
    }

    private func isOrganizedPath(_ components: [String]) -> Bool {
        components.count == 3 && isOrganizedDatePath(components)
    }

    private func destinationPathComponents(for datePath: [String]) -> [String] {
        datePath
    }

    private func isYear(_ value: String) -> Bool {
        guard value.count == 4, let intValue = Int(value) else { return false }
        return intValue >= 1900 && intValue <= 3000
    }

    private func isMonth(_ value: String) -> Bool {
        guard value.count == 2, let intValue = Int(value) else { return false }
        return intValue >= 1 && intValue <= 12
    }

    private func isDay(_ value: String) -> Bool {
        guard value.count == 2, let intValue = Int(value) else { return false }
        return intValue >= 1 && intValue <= 31
    }

    private func datePathComponents(for date: Date) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", components.year ?? 1970)
        let month = String(format: "%02d", components.month ?? 1)
        let day = String(format: "%02d", components.day ?? 1)
        return [year, month, day]
    }

    private func uniqueDestinationURL(in directory: URL, fileName: String) -> URL {
        var candidate = directory.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let ext = (fileName as NSString).pathExtension
        let baseName = (fileName as NSString).deletingPathExtension
        var counter = 2
        while true {
            let suffix = "-\(counter)"
            let nextName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(nextName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private func removeEmptyDirectories(in root: URL) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent != ".librarian-thumbnails" else { continue }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                directories.append(url)
            }
        }

        directories.sort { $0.pathComponents.count > $1.pathComponents.count }
        for directory in directories {
            if directory.standardizedFileURL == root.standardizedFileURL {
                continue
            }
            if isDirectoryEmpty(directory) {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private func isDirectoryEmpty(_ url: URL) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return contents.isEmpty
    }

    private func readCaptureDateIfAvailable(from fileURL: URL) -> Date? {
        let lowerExtension = fileURL.pathExtension.lowercased()
        guard imageExtensions.contains(lowerExtension) else { return nil }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let date = parseExifDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String) {
                return date
            }
            if let date = parseExifDate(exif[kCGImagePropertyExifDateTimeDigitized] as? String) {
                return date
            }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            return parseExifDate(tiff[kCGImagePropertyTIFFDateTime] as? String)
        }
        return nil
    }

    private func parseExifDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}
