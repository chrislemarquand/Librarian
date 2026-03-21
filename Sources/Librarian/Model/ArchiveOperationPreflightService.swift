import Foundation

struct ArchiveOperationPreflightResult {
    let estimatedBytesToWrite: Int64
    let requiredFreeBytes: Int64
    let availableFreeBytes: Int64?
}

enum ArchiveOperationPreflightService {
    private static let unknownPhotoBytesFallback: Int64 = 8 * 1024 * 1024
    private static let minimumReserveBytes: Int64 = 512 * 1024 * 1024
    private static let safetyMultiplier: Double = 1.2

    static func estimateExportWriteBytes(
        fileSizeStats: AssetRepository.FileSizeStats
    ) -> Int64 {
        let fallbackBytes = Int64(fileSizeStats.unknownCount) * unknownPhotoBytesFallback
        return max(0, fileSizeStats.knownBytes + fallbackBytes)
    }

    static func estimateImportWriteBytes(candidateURLs: [URL], fileManager: FileManager = .default) -> Int64 {
        var bytes: Int64 = 0
        for url in candidateURLs {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bytes += Int64(size)
        }
        return max(0, bytes)
    }

    static func checkWritableAndFreeSpace(
        at rootURL: URL,
        estimatedWriteBytes: Int64,
        minimumReserveBytes: Int64? = nil
    ) throws -> ArchiveOperationPreflightResult {
        let availability = ArchiveSettings.archiveRootAvailability(for: rootURL)
        guard availability == .available else {
            throw NSError(domain: "\(AppBrand.identifierPrefix).archivePreflight", code: 1, userInfo: [
                NSLocalizedDescriptionKey: availability.userVisibleDescription
            ])
        }

        let requiredScaled = Int64((Double(estimatedWriteBytes) * safetyMultiplier).rounded(.up))
        let reserveFloor = minimumReserveBytes ?? Self.minimumReserveBytes
        let required = max(requiredScaled, reserveFloor)
        let available = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
            .map { Int64($0) }

        if let available, available < required {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let requiredText = formatter.string(fromByteCount: required)
            let availableText = formatter.string(fromByteCount: available)
            throw NSError(domain: "\(AppBrand.identifierPrefix).archivePreflight", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Not enough free space for this operation. Need at least \(requiredText); available \(availableText)."
            ])
        }

        return ArchiveOperationPreflightResult(
            estimatedBytesToWrite: estimatedWriteBytes,
            requiredFreeBytes: required,
            availableFreeBytes: available
        )
    }
}
