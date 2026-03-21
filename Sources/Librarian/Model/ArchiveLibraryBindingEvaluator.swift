import Foundation

enum ArchiveLibraryBindingState: String, Equatable {
    case match
    case mismatch
    case unbound
    case unknown
}

struct ArchiveLibraryBindingEvaluation: Equatable {
    let state: ArchiveLibraryBindingState
    let archiveID: String?
    let expectedFingerprint: String?
    let currentFingerprint: String?
    let bindingMode: ArchiveSettings.ArchiveControlConfig.PhotoLibraryBinding.BindingMode?
    let boundLibraryPathHint: String?
    let currentLibraryPathHint: String?
    let didPersistMatchTimestamp: Bool
    let reason: String?
}

enum ArchiveLibraryBindingEvaluator {
    typealias FingerprintProvider = () throws -> PhotoLibraryFingerprint

    static func evaluate(
        rootURL: URL,
        currentFingerprintProvider: FingerprintProvider = { try ArchiveSettings.currentPhotoLibraryFingerprint() },
        persistMatchTimestamp: Bool = false,
        now: Date = Date()
    ) -> ArchiveLibraryBindingEvaluation {
        guard let config = ArchiveSettings.controlConfig(for: rootURL) else {
            return ArchiveLibraryBindingEvaluation(
                state: .unknown,
                archiveID: nil,
                expectedFingerprint: nil,
                currentFingerprint: nil,
                bindingMode: nil,
                boundLibraryPathHint: nil,
                currentLibraryPathHint: nil,
                didPersistMatchTimestamp: false,
                reason: "missing_archive_config"
            )
        }

        let currentFingerprint: PhotoLibraryFingerprint?
        do {
            currentFingerprint = try currentFingerprintProvider()
        } catch {
            currentFingerprint = nil
        }

        guard let binding = config.photoLibraryBinding else {
            return ArchiveLibraryBindingEvaluation(
                state: .unbound,
                archiveID: config.archiveID,
                expectedFingerprint: nil,
                currentFingerprint: currentFingerprint?.fingerprint,
                bindingMode: nil,
                boundLibraryPathHint: nil,
                currentLibraryPathHint: currentFingerprint?.pathHint,
                didPersistMatchTimestamp: false,
                reason: nil
            )
        }

        guard let currentFingerprint else {
            return ArchiveLibraryBindingEvaluation(
                state: .unknown,
                archiveID: config.archiveID,
                expectedFingerprint: binding.libraryFingerprint,
                currentFingerprint: nil,
                bindingMode: binding.bindingMode,
                boundLibraryPathHint: binding.libraryPathHint,
                currentLibraryPathHint: nil,
                didPersistMatchTimestamp: false,
                reason: "current_library_fingerprint_unavailable"
            )
        }

        if binding.libraryFingerprint == currentFingerprint.fingerprint {
            var didPersist = false
            if persistMatchTimestamp {
                didPersist = ArchiveSettings.updateControlConfig(at: rootURL) { control in
                    guard var existingBinding = control.photoLibraryBinding else { return }
                    existingBinding.lastSeenMatchAt = now
                    control.photoLibraryBinding = existingBinding
                }
            }
            return ArchiveLibraryBindingEvaluation(
                state: .match,
                archiveID: config.archiveID,
                expectedFingerprint: binding.libraryFingerprint,
                currentFingerprint: currentFingerprint.fingerprint,
                bindingMode: binding.bindingMode,
                boundLibraryPathHint: binding.libraryPathHint,
                currentLibraryPathHint: currentFingerprint.pathHint,
                didPersistMatchTimestamp: didPersist,
                reason: nil
            )
        }

        return ArchiveLibraryBindingEvaluation(
            state: .mismatch,
            archiveID: config.archiveID,
            expectedFingerprint: binding.libraryFingerprint,
            currentFingerprint: currentFingerprint.fingerprint,
            bindingMode: binding.bindingMode,
            boundLibraryPathHint: binding.libraryPathHint,
            currentLibraryPathHint: currentFingerprint.pathHint,
            didPersistMatchTimestamp: false,
            reason: nil
        )
    }
}
