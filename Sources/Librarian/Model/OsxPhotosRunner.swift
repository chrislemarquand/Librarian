import Foundation

struct OsxPhotosRunResult {
    let exitCode: Int32
    let outputText: String
    let executableURL: URL
    let usedExternalFallback: Bool
}

protocol OsxPhotosRunnerProtocol {
    func run(
        arguments: [String],
        captureStdoutToFile outputURL: URL?,
        includeExifToolEnvironment: Bool
    ) -> OsxPhotosRunResult
}

struct OsxPhotosRunner: OsxPhotosRunnerProtocol {
    private let resolveBundledOsxPhotosExecutableOverride: (() throws -> URL)?
    private let resolveBundledExifToolExecutableOverride: (() throws -> URL)?
    private let runProcessOverride: ((URL, [String], [String: String]?, URL?) -> (exitCode: Int32, outputText: String))?

    init(
        resolveBundledOsxPhotosExecutableOverride: (() throws -> URL)? = nil,
        resolveBundledExifToolExecutableOverride: (() throws -> URL)? = nil,
        runProcessOverride: ((URL, [String], [String: String]?, URL?) -> (exitCode: Int32, outputText: String))? = nil
    ) {
        self.resolveBundledOsxPhotosExecutableOverride = resolveBundledOsxPhotosExecutableOverride
        self.resolveBundledExifToolExecutableOverride = resolveBundledExifToolExecutableOverride
        self.runProcessOverride = runProcessOverride
    }

    func run(
        arguments: [String],
        captureStdoutToFile outputURL: URL? = nil,
        includeExifToolEnvironment: Bool
    ) -> OsxPhotosRunResult {
        let bundledExifTool: URL?
        if includeExifToolEnvironment {
            guard let resolvedExifTool = try? resolveBundledExifToolExecutableForRun() else {
                return OsxPhotosRunResult(
                    exitCode: 1,
                    outputText: "Bundled exiftool is missing.",
                    executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                    usedExternalFallback: false
                )
            }
            bundledExifTool = resolvedExifTool
        } else {
            bundledExifTool = nil
        }
        let processEnvironment = makeOsxPhotosEnvironment(exiftoolExecutableURL: bundledExifTool)

        if let bundledExecutable = try? resolveBundledOsxPhotosExecutableForRun() {
            var bundledResult = runProcessForRun(
                executableURL: bundledExecutable,
                arguments: arguments,
                environment: processEnvironment,
                captureStdoutToFile: outputURL
            )
            if bundledResult.exitCode != 0, isPyInstallerSemaphoreError(outputText: bundledResult.outputText) {
                let suffix = bundledResult.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = suffix.isEmpty
                    ? "Bundled osxphotos failed to initialize."
                    : "Bundled osxphotos failed to initialize: \(suffix)"
                bundledResult = (1, message)
            }
            return OsxPhotosRunResult(
                exitCode: bundledResult.exitCode,
                outputText: bundledResult.outputText,
                executableURL: bundledExecutable,
                usedExternalFallback: false
            )
        }

        return OsxPhotosRunResult(
            exitCode: 1,
            outputText: "Required export components are missing.",
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            usedExternalFallback: false
        )
    }

    private func resolveBundledOsxPhotosExecutableForRun() throws -> URL {
        if let override = resolveBundledOsxPhotosExecutableOverride {
            return try override()
        }
        return try resolveBundledOsxPhotosExecutable()
    }

    private func resolveBundledExifToolExecutableForRun() throws -> URL {
        if let override = resolveBundledExifToolExecutableOverride {
            return try override()
        }
        return try resolveBundledExifToolExecutable()
    }

    private func runProcessForRun(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        captureStdoutToFile outputURL: URL?
    ) -> (exitCode: Int32, outputText: String) {
        if let override = runProcessOverride {
            return override(executableURL, arguments, environment, outputURL)
        }
        return runProcess(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            captureStdoutToFile: outputURL
        )
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        captureStdoutToFile outputURL: URL?
    ) -> (exitCode: Int32, outputText: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let fileManager = FileManager.default
        let stderrURL = fileManager.temporaryDirectory
            .appendingPathComponent("librarian-osxphotos-\(UUID().uuidString).stderr.log", isDirectory: false)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stderrHandle: FileHandle
        do {
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            return (1, "Failed to create osxphotos stderr capture file.")
        }

        var stdoutHandle: FileHandle?
        if let outputURL {
            fileManager.createFile(atPath: outputURL.path, contents: nil)
            do {
                stdoutHandle = try FileHandle(forWritingTo: outputURL)
            } catch {
                try? stderrHandle.close()
                try? fileManager.removeItem(at: stderrURL)
                return (1, "Failed to create osxphotos output capture file.")
            }
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
        } else {
            process.standardOutput = stderrHandle
            process.standardError = stderrHandle
        }

        do {
            try process.run()
        } catch {
            try? stdoutHandle?.close()
            try? stderrHandle.close()
            try? fileManager.removeItem(at: stderrURL)
            return (1, "Failed to launch bundled osxphotos executable.")
        }
        process.waitUntilExit()
        try? stdoutHandle?.close()
        try? stderrHandle.close()

        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
        try? fileManager.removeItem(at: stderrURL)
        let outputText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, outputText)
    }

    private func isPyInstallerSemaphoreError(outputText: String) -> Bool {
        let lower = outputText.lowercased()
        return lower.contains("failed to initialize sync semaphore")
            || (lower.contains("pyi-") && lower.contains("semctl") && lower.contains("operation not permitted"))
    }

    private func resolveBundledOsxPhotosExecutable() throws -> URL {
        let fm = FileManager.default
        let bundle = Bundle.main

        var candidates: [URL] = []
        if let auxiliary = bundle.url(forAuxiliaryExecutable: "osxphotos") {
            candidates.append(auxiliary)
        }
        if let resourceRoot = bundle.resourceURL {
            candidates.append(resourceRoot.appendingPathComponent("Tools/osxphotos", isDirectory: false))
            candidates.append(resourceRoot.appendingPathComponent("osxphotos", isDirectory: false))
        }

        for url in candidates {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Required export components are missing."
        ])
    }

    private func resolveBundledExifToolExecutable() throws -> URL {
        let fm = FileManager.default
        let bundle = Bundle.main

        var candidates: [URL] = []
        if let resourceRoot = bundle.resourceURL {
            candidates.append(resourceRoot.appendingPathComponent("Tools/exiftool.bundle/bin/exiftool", isDirectory: false))
            candidates.append(resourceRoot.appendingPathComponent("exiftool.bundle/bin/exiftool", isDirectory: false))
            candidates.append(resourceRoot.appendingPathComponent("Tools/exiftool/bin/exiftool", isDirectory: false))
            candidates.append(resourceRoot.appendingPathComponent("exiftool/bin/exiftool", isDirectory: false))
        }

        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }

        throw NSError(domain: "\(AppBrand.identifierPrefix).archive", code: 6, userInfo: [
            NSLocalizedDescriptionKey: "Bundled exiftool executable not found in app resources."
        ])
    }

    private func makeOsxPhotosEnvironment(exiftoolExecutableURL: URL?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        guard let exiftoolExecutableURL else {
            return environment
        }

        environment["EXIFTOOL_PATH"] = exiftoolExecutableURL.path

        // Bundled exiftool is a Perl script that expects Image::ExifTool modules
        // under a sibling "lib" folder.
        let bundledLibPath = exiftoolExecutableURL
            .deletingLastPathComponent()
            .appendingPathComponent("lib", isDirectory: true)
            .path
        if FileManager.default.fileExists(atPath: bundledLibPath) {
            let existing = environment["PERL5LIB"] ?? ""
            environment["PERL5LIB"] = existing.isEmpty ? bundledLibPath : "\(bundledLibPath):\(existing)"
        }

        return environment
    }

}

enum OsxPhotosLibraryResolver {
    static func preferredLibraryPath() -> String? {
        let fileManager = FileManager.default

        if let archiveRoot = ArchiveSettings.restoreArchiveRootURL(),
           let config = ArchiveSettings.controlConfig(for: archiveRoot),
           let pathHint = config.lastKnownPhotoLibraryPath,
           !pathHint.isEmpty,
           fileManager.fileExists(atPath: pathHint) {
            return URL(fileURLWithPath: pathHint).standardizedFileURL.path
        }

        guard let picturesURL = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first,
              let contents = try? fileManager.contentsOfDirectory(
                at: picturesURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else {
            return nil
        }

        return contents
            .first(where: { $0.pathExtension == "photoslibrary" })?
            .standardizedFileURL
            .path
    }
}
