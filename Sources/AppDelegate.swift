import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = StateStore()
    private let menu = NSMenu()

    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    private var animTimer: Timer?
    private let eyes = EyeAnimator()
    private var displayBody: EffectiveState = .idle
    private var displayMood: Mood = .chill
    private var displayStates: [EffectiveState] = []

    private let updates = UpdateChecker()
    private var update: (version: String, url: URL)?
    private var updateTimer: Timer?

    private var lastStatusSig = ""
    private var currentSessions: [SessionState] = []

    // Per-session "already alerted" markers, keyed by the updatedAt of the
    // episode we alerted on, so a new turn re-arms the alert.
    private var alertedAt: [String: Double] = [:]
    private let alertDwell: TimeInterval = 0    // fire the instant a turn finishes (raise to debounce quick turns)
    private var notifReady = false              // UNUserNotificationCenter authorized -> show the mascot face

    private let defaults = UserDefaults.standard

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        for key in ["alertOnPermission", "alertOnFinished"] where defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
        }

        store.ensureDir()
        setUpNotifications()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.image = mascotImage(color: EffectiveState.idle.color, height: kMenubarHeight)
        statusItem.button?.imagePosition = .imageLeft   // image (mascot+dots), then any "+N" title
        statusItem.button?.toolTip = "Claude Code traffic light"

        watcher = DirectoryWatcher(path: store.dir) { [weak self] in self?.refresh() }

        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)   // keep ticking even while the menu is open
        timer = t

        // Animate the mascot's eyes (~12 fps; only redraws while something moves).
        let anim = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.eyes.tick(mood: self.displayMood) { self.renderStatusBar(force: false) }
        }
        RunLoop.main.add(anim, forMode: .common)
        animTimer = anim

        // Check for a newer release on launch, then every 6 hours.
        checkForUpdates()
        let upd = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdates() }
        RunLoop.main.add(upd, forMode: .common)
        updateTimer = upd

        refresh()
        ensureHooksInstalled()
    }

    // MARK: first-launch setup (for DMG / Homebrew installs)

    /// If the Claude hooks aren't wired yet (e.g. a fresh DMG/brew install),
    /// run the bundled setup-hooks.sh once. A from-source `./install.sh` user
    /// already has them, so this no-ops for them.
    private func ensureHooksInstalled() {
        let hookDst = ("~/.claude/hooks/cc-hook.sh" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: hookDst) { return }
        guard let script = Bundle.main.path(forResource: "setup-hooks", ofType: "sh") else { return }

        if !commandExists("jq") {
            postBanner(title: "Claude Traffic Light needs jq",
                       body: "Run  brew install jq  then relaunch the app.")
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script]
            p.environment = AppDelegate.augmentedEnv()
            try? p.run()
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async {
                self?.postBanner(
                    title: ok ? "Claude Traffic Light is ready" : "Setup didn't finish",
                    body: ok ? "Hooks installed — start a new Claude Code session to see it light up."
                             : "Couldn't wire the Claude hooks. See the README to set up manually.")
            }
        }
    }

    private func commandExists(_ cmd: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "command -v \(cmd)"]
        p.environment = AppDelegate.augmentedEnv()
        p.standardOutput = nil
        p.standardError = nil
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    /// GUI apps launched from Finder get a minimal PATH, so add the usual
    /// Homebrew / system locations where jq etc. live.
    static func augmentedEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
        return env
    }

    private var alertOnPermission: Bool { defaults.bool(forKey: "alertOnPermission") }
    private var alertOnFinished: Bool { defaults.bool(forKey: "alertOnFinished") }

    // MARK: state -> icon + alerts (runs on every tick / fs change)

    private func refresh() {
        let now = Date().timeIntervalSince1970
        let sessions = store.loadSessions(now: now)
        currentSessions = sessions

        displayStates = sessions.map { store.effective($0, now: now) }.sorted { $0.urgency < $1.urgency }
        let vibe = store.vibe(sessions, now: now)
        displayBody = vibe.color
        displayMood = vibe.mood
        let overflow = max(0, displayStates.count - kMaxStatusDots)
        statusItem.button?.title = overflow > 0 ? " +\(overflow)" : ""

        renderStatusBar(force: true)
        handleAlerts(sessions: sessions, now: now)
        // NOTE: never rebuild `menu` while it's open — mutating an open NSMenu
        // (removeAllItems + re-add) leaves a stuck blank gap. The menu is rebuilt
        // fresh each time it opens via menuNeedsUpdate(_:), which is enough.
    }

    /// Redraw the menu-bar icon for the current state + eye pose; skips the work
    /// when nothing changed, so the 12 fps animation tick stays cheap.
    private func renderStatusBar(force: Bool) {
        let p = eyes.pose
        let poseKey = "\(Int(p.look.dx * 18))/\(Int(p.look.dy * 18))/\(Int(p.blink * 18))"
        let sig = displayBody.colorKey + "#\(displayMood)#"
                + displayStates.map { $0.colorKey }.joined(separator: ",") + "#" + poseKey
        if !force && sig == lastStatusSig { return }
        lastStatusSig = sig
        statusItem.button?.image = statusImage(body: displayBody, states: displayStates,
                                               height: kMenubarHeight, pose: p, mood: displayMood)
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

    // MARK: notifications

    /// Ask once for notification permission. When granted we post via
    /// UNUserNotificationCenter so the banner uses OUR icon (the mascot) and
    /// can show his current-mood face; otherwise we fall back to osascript.
    private func setUpNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // UNUC requires a bundle id
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.notifReady = granted }
        }
    }

    // Show banners even though we're a background (accessory) app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    private func notify(session s: SessionState, permission: Bool) {
        // Instant in-process ping, regardless of which banner path we use.
        NSSound(named: NSSound.Name("Glass"))?.play()
        let title = permission ? "Claude needs your input" : "Claude finished — your turn"
        let body = s.label.isEmpty ? "A session is waiting." : s.label
        if notifReady {
            postOwnNotification(title: title, body: body)
        } else {
            postBanner(title: title, body: body)
        }
    }

    /// Post via UNUserNotificationCenter — uses the app icon (the mascot) and
    /// attaches a snapshot of his current face/mood.
    private func postOwnNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil                       // we already played the sound instantly
        if let url = renderFaceAttachment(),
           let att = try? UNNotificationAttachment(identifier: "face", url: url) {
            content.attachments = [att]
        }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Render the mascot's current face to a temp PNG for the notification.
    private func renderFaceAttachment() -> URL? {
        let img = mascotImage(color: displayBody.color, height: 256,
                              pose: EyePose(look: CGVector(dx: 0, dy: -0.08)), mood: displayMood)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cc-face-\(UUID().uuidString).png")
        do { try png.write(to: url); return url } catch { return nil }
    }

    /// Fallback macOS banner via osascript (works unsigned; attributed to Script Editor).
    private func postBanner(title: String, body: String) {
        // Escape (don't strip) for the AppleScript string literal: backslash
        // first, then quote — keeps odd text intact and injection-safe.
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

    // MARK: updates

    private func checkForUpdates() {
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        updates.check(currentVersion: current) { [weak self] result in
            DispatchQueue.main.async { self?.update = result }
        }
    }

    @objc private func openUpdate() {
        if let url = update?.url { NSWorkspace.shared.open(url) }
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

        if let u = update {
            let item = NSMenuItem(title: "↑  Update available — v\(u.version)",
                                  action: #selector(openUpdate), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

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
