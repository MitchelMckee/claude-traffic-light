import AppKit

// `--selftest` prints the computed aggregate + per-session effective states as
// text and exits, so the core logic can be verified without the GUI.
if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    renderStatusSamples(toDir: CommandLine.arguments[i + 1])
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--appicon"), i + 1 < CommandLine.arguments.count {
    renderAppIcon(toPath: CommandLine.arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menubar only: no Dock icon, no windows
app.run()
