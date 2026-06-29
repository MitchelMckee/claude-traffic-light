import Foundation

/// Best-effort "bring this session's terminal to the front" on menu click.
///
/// Precision varies by terminal:
///   - iTerm2 / Apple Terminal: targeted, via their scripting / window title.
///   - tmux: selects the pane regardless of the outer emulator.
///   - Ghostty: no focus IPC or AppleScript dictionary exists (verified on
///     1.3.0), so we activate the app and best-effort raise the window whose
///     title contains the project label. Exact-tab focus is not possible yet.
enum TerminalFocus {
    static func focus(_ s: SessionState) {
        switch s.terminalProgram.lowercased() {
        case "ghostty":        focusGhostty(s)
        case "iterm.app":      focusITerm(s)
        case "apple_terminal": focusAppleTerminal(s)
        case "vscode":         activate("Visual Studio Code")
        case "wezterm":        activate("WezTerm")
        case "":               break
        default:               activate(s.terminalProgram)
        }
        if !s.tmuxPane.isEmpty {
            let pane = s.tmuxPane
            _ = run("/usr/bin/env", ["tmux", "select-window", "-t", pane])
            _ = run("/usr/bin/env", ["tmux", "select-pane", "-t", pane])
        }
    }

    // MARK: - per-terminal strategies

    private static func focusGhostty(_ s: SessionState) {
        let label = sanitize(s.label)
        let script = """
        tell application id "com.mitchellh.ghostty" to activate
        delay 0.05
        tell application "System Events"
          tell process "Ghostty"
            try
              set ws to (every window whose title contains "\(label)")
              if (count of ws) > 0 then perform action "AXRaise" of (item 1 of ws)
            end try
          end tell
        end tell
        """
        if !runOSA(script) { activate("Ghostty") }
    }

    private static func focusITerm(_ s: SessionState) {
        let sid = sanitize(s.itermSessionId)
        guard !sid.isEmpty else { activate("iTerm"); return }
        let script = """
        tell application "iTerm2"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with ss in sessions of t
                if (id of ss) is "\(sid)" then
                  select w
                  tell t to select
                  select ss
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
        if !runOSA(script) { activate("iTerm") }
    }

    private static func focusAppleTerminal(_ s: SessionState) {
        let label = sanitize(s.label)
        let script = """
        tell application "Terminal" to activate
        delay 0.05
        tell application "System Events"
          tell process "Terminal"
            try
              set ws to (every window whose title contains "\(label)")
              if (count of ws) > 0 then perform action "AXRaise" of (item 1 of ws)
            end try
          end tell
        end tell
        """
        if !runOSA(script) { activate("Terminal") }
    }

    // MARK: - helpers

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "")
         .replacingOccurrences(of: "\"", with: "")
    }

    private static func activate(_ app: String) {
        _ = run("/usr/bin/osascript", ["-e", "tell application \"\(sanitize(app))\" to activate"])
    }

    @discardableResult
    private static func runOSA(_ src: String) -> Bool {
        run("/usr/bin/osascript", ["-e", src])
    }

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }
}
