import AppKit

/// Raw state as written by the hook script.
enum RawState: String, Codable {
    case working      // green
    case permission   // yellow — blocked on a permission/confirmation prompt
    case finished     // yellow — turn finished, your move
    case idle         // red    — registered but not doing anything
}

/// One Claude Code session, decoded from a state file.
struct SessionState: Codable {
    let sessionId: String
    let cwd: String
    let label: String
    let state: RawState
    let reason: String
    let pid: Int
    let terminalProgram: String
    let termSessionId: String
    let itermSessionId: String
    let tmuxPane: String
    let windowTitle: String
    let updatedAt: Double   // epoch seconds
}

/// What the app actually displays after applying time-based decay.
enum EffectiveState {
    case working      // green
    case permission   // yellow (urgent)
    case finished     // yellow (soft)
    case idle         // red

    var color: NSColor {
        switch self {
        case .working:    return NSColor.systemRed      // busy — don't interrupt
        case .permission: return NSColor.systemYellow   // blocked on a prompt — needs a keypress
        case .finished:   return NSColor.systemGreen    // done — ready for your next message
        case .idle:       return NSColor.systemGreen    // ready / free
        }
    }

    /// Coarse bucket used to avoid redundant icon redraws.
    var colorKey: String {
        switch self {
        case .working:               return "red"
        case .permission:            return "yellow"
        case .finished, .idle:       return "green"
        }
    }

    /// Yellow = a prompt is blocking, waiting for you to approve / press enter.
    var isWaiting: Bool {
        if case .permission = self { return true }
        return false
    }

    /// States that can raise an alert (and whose alert marker should persist
    /// across ticks): a blocking prompt, or a just-finished turn.
    var needsAttention: Bool {
        switch self {
        case .permission, .finished: return true
        default:                     return false
        }
    }

    var dot: String {
        switch self {
        case .working:         return "🔴"
        case .permission:      return "🟡"
        case .finished, .idle: return "🟢"
        }
    }

    /// Short status shown (dimmed) after the project name in the menu.
    var menuStatus: String {
        switch self {
        case .permission: return "needs you"
        case .working:    return "working"
        case .finished:   return "done"
        case .idle:       return "idle"
        }
    }

    /// Sort/priority order: a blocking prompt first, then working, then ready.
    var urgency: Int {
        switch self {
        case .permission: return 0
        case .working:    return 1
        case .finished:   return 2
        case .idle:       return 3
        }
    }
}
