import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
MainActor.assumeIsolated {
    app.delegate = delegate
}

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
