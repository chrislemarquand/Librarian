import AppKit
import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class UpdateService: NSObject {
#if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController?
    private let notConfiguredMessage: String?

    override init() {
        if Self.hasValidSparkleConfiguration() {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            notConfiguredMessage = nil
        } else {
            updaterController = nil
            notConfiguredMessage = "Update checks are not configured for this build."
        }
        super.init()
    }

    func performBackgroundCheck() {
        updaterController?.updater.checkForUpdatesInBackground()
    }

    @objc
    func checkForUpdates(_ sender: Any?) {
        if let updaterController {
            updaterController.checkForUpdates(sender)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update checks are unavailable"
        alert.informativeText = notConfiguredMessage ?? "This build does not include a working update configuration."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func hasValidSparkleConfiguration() -> Bool {
        let bundle = Bundle.main

        guard
            let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let feedURL = URL(string: feed),
            ["http", "https"].contains(feedURL.scheme?.lowercased())
        else {
            return false
        }

        guard let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }

        let trimmed = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.contains("$(") { return false }
        return true
    }
#else
    func performBackgroundCheck() {}

    @objc
    func checkForUpdates(_ sender: Any?) {
        _ = sender
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update checks are unavailable"
        alert.informativeText = "This build does not include Sparkle."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
#endif
}
