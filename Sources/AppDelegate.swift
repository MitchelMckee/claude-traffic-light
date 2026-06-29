import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = StateStore()
    private let menu = NSMenu()

    private var watcher: DirectoryWatcher?
    private var timer: Timer?

    private var lastStatusSig = ""
    private var currentSessions: [SessionState] = []

    // Per-session "already alerted" markers, keyed by the updatedAt of the
    // episode we alerted on, so a new turn re-arms the alert.
    private var alertedAt: [String: Double] = [:]
    private let alertDwell: TimeInterval = 0    // fire the instant a turn finishes (raise to debounce quick turns)

    private let defaults = UserDefaults.standard

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        for key in ["alertOnPermission", "alertOnFinished"] where defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
        }

        store.ensureDir()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.image = mascotImage(color: EffectiveState.idle.color)
        statusItem.button?.imagePosition = .imageLeft   // image (mascot+dots), then any "+N" title
        statusItem.button?.toolTip = "Claude Code traffic light"

        watcher = DirectoryWatcher(path: store.dir) { [weak self] in self?.refresh() }

        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)   // keep ticking even while the menu is open
        timer = t

        refresh()
    }

    private var alertOnPermission: Bool { defaults.bool(forKey: "alertOnPermission") }
    private var alertOnFinished: Bool { defaults.bool(forKey: "alertOnFinished") }

    // MARK: state -> icon + alerts (runs on every tick / fs change)

    private func refresh() {
        let now = Date().timeIntervalSince1970
        let sessions = store.loadSessions(now: now)
        currentSessions = sessions

        let states = sessions.map { store.effective($0, now: now) }.sorted { $0.urgency < $1.urgency }
        let agg = store.aggregate(sessions, now: now)
        let overflow = max(0, states.count - kMaxStatusDots)
        let sig = agg.colorKey + "#" + states.map { $0.colorKey }.joined(separator: ",")
        if sig != lastStatusSig {
            statusItem.button?.image = statusImage(aggregate: agg, states: states)
            statusItem.button?.title = overflow > 0 ? " +\(overflow)" : ""
            lastStatusSig = sig
        }

        handleAlerts(sessions: sessions, now: now)
        // NOTE: never rebuild `menu` while it's open — mutating an open NSMenu
        // (removeAllItems + re-add) leaves a stuck blank gap. The menu is rebuilt
        // fresh each time it opens via menuNeedsUpdate(_:), which is enough.
    }

    private func handleAlerts(sessions: [SessionState], now: Double) {
        guard alertOnPermission || alertOnFinished else { alertedAt.removeAll(); return }
        var live = Set<String>()
        for s in sessions {
            live.insert(s.sessionId)
            let eff = store.effective(s, now: now)

            var due = false
            var isPermission = false
            switch eff {
            case .permission:
                if alertOnPermission { due = true; isPermission = true }
            case .finished:
                if alertOnFinished && (now - s.updatedAt) >= alertDwell { due = true }
            default:
                break
            }

            if due && alertedAt[s.sessionId] != s.updatedAt {
                alertedAt[s.sessionId] = s.updatedAt
                notify(session: s, permission: isPermission)
            }
            if !eff.needsAttention { alertedAt[s.sessionId] = nil } // episode ended -> re-arm
        }
        for key in alertedAt.keys where !live.contains(key) { alertedAt[key] = nil }
    }

    private func notify(session s: SessionState, permission: Bool) {
        // Play the sound in-process so the ping is instant, even if the banner
        // (a spawned osascript) takes a moment to appear.
        NSSound(named: NSSound.Name("Glass"))?.play()

        let title = permission ? "Claude needs your input" : "Claude finished — your turn"
        let body = s.label.isEmpty ? "A session is waiting." : s.label
        // Escape (don't strip) for the AppleScript string literal: backslash
        // first, then quote — keeps odd folder names intact and injection-safe.
        let esc: (String) -> String = {
            $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
            p.waitUntilExit()
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let now = Date().timeIntervalSince1970
        let sessions = store.loadSessions(now: now)
        currentSessions = sessions
        populate(menu, sessions: sessions, now: now)
    }

    private func populate(_ menu: NSMenu, sessions: [SessionState], now: Double) {
        menu.removeAllItems()

        var nWait = 0, nWork = 0, nReady = 0
        for s in sessions {
            switch store.effective(s, now: now) {
            case .permission:      nWait += 1
            case .working:         nWork += 1
            case .finished, .idle: nReady += 1
            }
        }
        var parts: [String] = []
        if nWait > 0  { parts.append("\(nWait) needs you") }
        if nWork > 0  { parts.append("\(nWork) working") }
        if nReady > 0 { parts.append("\(nReady) ready") }
        let header = NSMenuItem(title: parts.isEmpty ? "Claude" : "Claude   ·   " + parts.joined(separator: "   ·   "),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if sessions.isEmpty {
            let none = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let labels = displayLabels(for: sessions)
            for s in sessions.sorted(by: { sortRank($0, now) != sortRank($1, now)
                                            ? sortRank($0, now) < sortRank($1, now)
                                            : (labels[$0.sessionId] ?? "") < (labels[$1.sessionId] ?? "") }) {
                let eff = store.effective(s, now: now)
                let name = labels[s.sessionId] ?? s.label
                let menuFont = NSFont.menuFont(ofSize: 0)
                let title = NSMutableAttributedString(string: "\(eff.dot)  \(name)", attributes: [.font: menuFont])
                title.append(NSAttributedString(string: "    \(eff.menuStatus)",
                    attributes: [.font: menuFont, .foregroundColor: NSColor.secondaryLabelColor]))
                let item = NSMenuItem(title: "", action: #selector(focusSession(_:)), keyEquivalent: "")
                item.attributedTitle = title
                item.target = self
                item.representedObject = s.sessionId
                item.toolTip = "\(s.cwd)\n\(s.reason) — click to focus"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let permItem = NSMenuItem(title: "Alert on permission prompts",
                                  action: #selector(toggleAlertPermission), keyEquivalent: "")
        permItem.target = self
        permItem.state = alertOnPermission ? .on : .off
        menu.addItem(permItem)

        let finItem = NSMenuItem(title: "Alert when a turn finishes",
                                 action: #selector(toggleAlertFinished), keyEquivalent: "")
        finItem.target = self
        finItem.state = alertOnFinished ? .on : .off
        menu.addItem(finItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    /// Project folder name per session, disambiguated with the parent folder
    /// when two sessions share the same leaf name (e.g. "web (acme)").
    private func displayLabels(for sessions: [SessionState]) -> [String: String] {
        var counts: [String: Int] = [:]
        for s in sessions { counts[s.label, default: 0] += 1 }
        var out: [String: String] = [:]
        for s in sessions {
            if (counts[s.label] ?? 0) > 1 {
                let parent = (s.cwd as NSString).deletingLastPathComponent
                let parentName = (parent as NSString).lastPathComponent
                out[s.sessionId] = parentName.isEmpty ? s.label : "\(s.label) (\(parentName))"
            } else {
                out[s.sessionId] = s.label
            }
        }
        return out
    }

    private func sortRank(_ s: SessionState, _ now: Double) -> Int {
        switch store.effective(s, now: now) {
        case .permission: return 0
        case .finished:   return 1
        case .working:    return 2
        case .idle:       return 3
        }
    }

    // MARK: actions

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let s = currentSessions.first(where: { $0.sessionId == id }) else { return }
        DispatchQueue.global(qos: .userInitiated).async { TerminalFocus.focus(s) }
    }

    @objc private func toggleAlertPermission() {
        defaults.set(!alertOnPermission, forKey: "alertOnPermission")
        refresh()
    }

    @objc private func toggleAlertFinished() {
        defaults.set(!alertOnFinished, forKey: "alertOnFinished")
        refresh()
    }

}
