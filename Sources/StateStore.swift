import Foundation
import Darwin

/// How long a state lingers before the app treats it as idle (red).
struct DecayConfig {
    /// finished (your turn) -> idle. Short: a glance window after a turn ends.
    var finished: TimeInterval = 5 * 60
    /// working -> idle, but ONLY for sessions with an unknown pid (pid <= 0).
    /// A working session with a live `claude` pid never decays, so an
    /// arbitrarily long single tool call (build/test/install) stays green.
    var working: TimeInterval = 10 * 60
    /// permission prompt -> idle. Deliberately long so an abandoned prompt
    /// lingers visibly, but doesn't stay yellow forever.
    var permission: TimeInterval = 30 * 60
}

/// Reads the state directory, prunes dead sessions, and computes colors.
final class StateStore {
    let dir: String
    var config = DecayConfig()

    /// Files not updated in this long are garbage-collected even if their pid
    /// still looks alive — covers crashes that left a pid=0 record or a
    /// recycled pid, which the liveness check alone can't catch.
    let orphanTTL: TimeInterval = 24 * 3600

    init() {
        if let override = ProcessInfo.processInfo.environment["CC_MENUBAR_STATE_DIR"], !override.isEmpty {
            dir = (override as NSString).expandingTildeInPath
        } else {
            dir = ("~/.claude/menubar-state" as NSString).expandingTildeInPath
        }
    }

    func ensureDir() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// Load every live session. Files whose pid is dead, or that are far older
    /// than orphanTTL, are deleted.
    func loadSessions(now: Double = Date().timeIntervalSince1970) -> [SessionState] {
        let fm = FileManager.default
        ensureDir()
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [SessionState] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let s = try? JSONDecoder().decode(SessionState.self, from: data) else { continue }
            let deadPid = s.pid > 0 && !isAlive(pid: s.pid)
            let orphaned = (now - s.updatedAt) > orphanTTL
            if deadPid || orphaned {
                try? fm.removeItem(atPath: path)   // crashed/abandoned without SessionEnd
                continue
            }
            out.append(s)
        }
        return out
    }

    /// Side-effect-free liveness probe. signal 0 is never delivered; it only
    /// runs the existence/permission check. EPERM means the process exists but
    /// is owned by someone else (still "alive").
    func isAlive(pid: Int) -> Bool {
        if pid <= 0 { return true }   // unknown pid -> never prune on this basis
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Apply decay to a raw state to get what should be shown right now.
    func effective(_ s: SessionState, now: Double = Date().timeIntervalSince1970) -> EffectiveState {
        let age = now - s.updatedAt
        switch s.state {
        case .idle:       return .idle
        // Working only decays when we don't have a live pid to vouch for it;
        // with a live claude pid it stays green through long tool calls.
        case .working:    return (s.pid <= 0 && age > config.working) ? .idle : .working
        case .finished:   return age > config.finished   ? .idle : .finished
        case .permission: return age > config.permission ? .idle : .permission
        }
    }

    /// Aggregate color for the menubar icon, most urgent first:
    /// a blocking prompt (yellow) > anything working (red) > ready (green).
    func aggregate(_ sessions: [SessionState],
                   now: Double = Date().timeIntervalSince1970) -> EffectiveState {
        let effs = sessions.map { effective($0, now: now) }
        if effs.contains(where: { if case .permission = $0 { return true }; return false }) { return .permission }
        if effs.contains(where: { if case .working    = $0 { return true }; return false }) { return .working }
        if effs.contains(where: { if case .finished   = $0 { return true }; return false }) { return .finished }
        return .idle
    }

    /// The mascot's body color + mood. Body color follows the state the *most*
    /// shells are in (ties resolve toward the more urgent). Mood reflects how
    /// hard the mascot is being worked.
    func vibe(_ sessions: [SessionState], now: Double = Date().timeIntervalSince1970) -> (color: EffectiveState, mood: Mood) {
        var working = 0, permission = 0, ready = 0
        for s in sessions {
            switch effective(s, now: now) {
            case .working:         working += 1
            case .permission:      permission += 1
            case .finished, .idle: ready += 1
            }
        }

        let maxc = max(working, max(permission, ready))
        let color: EffectiveState
        if maxc == 0               { color = .idle }
        else if permission == maxc { color = .permission }   // tie-break toward urgent
        else if working == maxc    { color = .working }
        else                       { color = .idle }

        let mood: Mood
        if working >= 2          { mood = .stressed }
        else if working == 1     { mood = .pressure }
        else if permission >= 1  { mood = .alert }
        else                     { mood = .chill }

        return (color, mood)
    }
}
