import Testing
import Foundation
@testable import Librarian

@Test func osxPhotosRunnerReturnsMissingWhenBundledExecutableIsUnavailable() {
    let runner = OsxPhotosRunner(
        resolveBundledOsxPhotosExecutableOverride: {
            throw NSError(domain: "test", code: 1)
        }
    )

    let result = runner.run(arguments: ["query", "--json"], includeExifToolEnvironment: false)
    #expect(result.exitCode == 1)
    #expect(result.outputText == "Required export components are missing.")
    #expect(result.executableURL.path == "/usr/bin/false")
    #expect(result.usedExternalFallback == false)
}

@Test func osxPhotosRunnerFailsFastWhenBundledExifToolIsMissing() {
    var didInvokeProcess = false
    let runner = OsxPhotosRunner(
        resolveBundledOsxPhotosExecutableOverride: {
            URL(fileURLWithPath: "/tmp/fake-osxphotos")
        },
        resolveBundledExifToolExecutableOverride: {
            throw NSError(domain: "test", code: 2)
        },
        runProcessOverride: { _, _, _, _ in
            didInvokeProcess = true
            return (0, "")
        }
    )

    let result = runner.run(arguments: ["export", "/tmp/out"], includeExifToolEnvironment: true)
    #expect(result.exitCode == 1)
    #expect(result.outputText == "Bundled exiftool is missing.")
    #expect(result.executableURL.path == "/usr/bin/false")
    #expect(result.usedExternalFallback == false)
    #expect(didInvokeProcess == false)
}

@Test func osxPhotosRunnerDoesNotFallbackExternallyOnPyInstallerSemaphoreError() {
    let bundledURL = URL(fileURLWithPath: "/tmp/fake-osxphotos")
    let runner = OsxPhotosRunner(
        resolveBundledOsxPhotosExecutableOverride: { bundledURL },
        runProcessOverride: { _, _, _, _ in
            (7, "failed to initialize sync semaphore")
        }
    )

    let result = runner.run(arguments: ["query", "--json"], includeExifToolEnvironment: false)
    #expect(result.exitCode == 1)
    #expect(result.executableURL == bundledURL)
    #expect(result.usedExternalFallback == false)
    #expect(result.outputText.contains("Bundled osxphotos failed to initialize"))
}
