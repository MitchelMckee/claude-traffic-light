import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = StateStore()
    private lazy var usageStore = UsageStore(stateDir: store.dir)
    private let menu = NSMenu()

    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    private var animTimer: Timer?
    private let eyes = EyeAnimator()
    private var displayBody: EffectiveState = .idle
    private var displayMood: Mood = .chill
    private var displayStates: [EffectiveState] = []

    private var lastActivityAt = Date().timeIntervalSince1970
    private let napAfter: TimeInterval = 120     // everything calm this long -> sleepy
    private var prevKind: [String: Int] = [:]    // sessionId -> state kind, for event reactions
    private var celebrated = false               // the "all clear" reaction fired once
    private var cursorEngaged = false            // hysteresis for cursor-follow proximity
    private var alertsArmed = false              // suppress notification re-dings on launch
    private var fatigue: CGFloat = 0             // builds under load, recovers when calm
    private var droopBias: CGFloat = 0           // time-of-day + fatigue sleepiness (0-1)

    private var displayColor: NSColor = EffectiveState.idle.color
    private var fadeFrom: NSColor = EffectiveState.idle.color
    private var fadeT: CGFloat = 1               // 1 = settled on the target color
    private var prevColorKey = ""                // empty -> first refresh snaps (no fade)
    private let fadeStep: CGFloat = 0.25         // ~0.33s body cross-fade at 12 fps

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
    private var scheduledResetAt: Double = 0    // 5-hour reset we've already queued a warning for

    private let defaults = UserDefaults.standard

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        for key in ["alertOnPermission", "alertOnFinished", "showDots", "playSound", "showUsage", "warnBeforeReset"] where defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
        }
        if defaults.object(forKey: "soundVolume") == nil { defaults.set(1.0, forKey: "soundVolume") }

        store.ensureDir()
        setUpNotifications()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.image = mascotImage(color: EffectiveState.idle.color, height: kMenubarHeight,
                                               eyes: !boringMode)
        statusItem.button?.imagePosition = .imageLeft   // image (mascot+dots), then any "+N" title
        statusItem.button?.toolTip = "Claude Code traffic light"

        watcher = DirectoryWatcher(path: store.dir) { [weak self] in self?.refresh() }

        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)   // keep ticking even while the menu is open
        timer = t

        // Animate the mascot's eyes (~12 fps; only redraws while something moves).
        let anim = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.boringMode {
                // No eyes to animate; just finish any in-flight body-color fade.
                if self.advanceColorFade() { self.renderStatusBar(force: false) }
                return
            }
            let target = self.cursorTarget()
            self.eyes.lookTarget = target
            if target != nil { self.lastActivityAt = Date().timeIntervalSince1970 }  // engaging keeps it awake
            let effNap = self.napAfter * (1 - Double(self.droopBias) * 0.5)          // sleepier -> naps sooner
            let nap = target == nil && self.displayMood == .chill
                && Date().timeIntervalSince1970 - self.lastActivityAt > effNap
            if nap != self.eyes.drowsy {
                self.eyes.drowsy = nap
                // a queued event reaction already wakes it; don't overwrite that with .wake
                if !nap && !self.eyes.hasPendingReaction { self.eyes.react(.wake) }
            }
            let eyesMoved = self.eyes.tick(mood: self.displayMood)
            let fading = self.advanceColorFade()
            if eyesMoved || fading { self.renderStatusBar(force: false) }
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

        // Already wired up: refresh just the hook script when the bundled copy
        // changed (e.g. an app update fixed a bug), without re-touching settings.json —
        // unless an event this version depends on isn't registered yet, in which case
        // fall through and re-run the (idempotent, settings-backed-up) setup script.
        if FileManager.default.fileExists(atPath: hookDst) {
            refreshBundledScript(resource: "cc-hook", dst: hookDst)
            // The statusLine reader (account-usage) ships alongside; keep it fresh too.
            let statusDst = ("~/.claude/hooks/cc-statusline.sh" as NSString).expandingTildeInPath
            refreshBundledScript(resource: "cc-statusline", dst: statusDst)
            // PermissionRequest fires the moment an approval dialog appears; without
            // it, yellow waits on the (much slower) Notification event. The statusLine
            // command is what feeds account usage — re-run setup if either is missing.
            if hookWired(event: "PermissionRequest") && statusLineWired() { return }
        }

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

    /// Overwrite an installed hook script with the bundled copy when they differ
    /// (e.g. an app update fixed a bug), preserving its executable bit.
    private func refreshBundledScript(resource: String, dst: String) {
        guard let src = Bundle.main.path(forResource: resource, ofType: "sh"),
              !filesEqual(src, dst),
              let data = try? Data(contentsOf: URL(fileURLWithPath: src)) else { return }
        try? data.write(to: URL(fileURLWithPath: dst))
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst)
    }

    /// True when settings.json's statusLine command is ours (cc-statusline.sh) —
    /// the hook that feeds account usage. A user's own custom statusLine reads
    /// as "not wired" so setup leaves it untouched.
    private func statusLineWired() -> Bool {
        let path = ("~/.claude/settings.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sl = root["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return false }
        return cmd.contains("cc-statusline.sh")
    }

    /// True when ~/.claude/settings.json already routes `event` to cc-hook.sh.
    private func hookWired(event: String) -> Bool {
        let path = ("~/.claude/settings.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]] else { return false }
        return entries.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                (($0["command"] as? String) ?? "").contains("cc-hook.sh")
            }
        }
    }

    private func filesEqual(_ a: String, _ b: String) -> Bool {
        let fm = FileManager.default
        guard let da = fm.contents(atPath: a), let db = fm.contents(atPath: b) else { return false }
        return da == db
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
    private var showDots: Bool { defaults.bool(forKey: "showDots") }
    private var playSound: Bool { defaults.bool(forKey: "playSound") }
    private var warnBeforeReset: Bool { defaults.bool(forKey: "warnBeforeReset") }
    private var showUsage: Bool { defaults.bool(forKey: "showUsage") }
    private var soundVolume: Float { defaults.float(forKey: "soundVolume") }
    private var boringMode: Bool { defaults.bool(forKey: "boringMode") }

    // MARK: state -> icon + alerts (runs on every tick / fs change)

    private func refresh() {
        let now = Date().timeIntervalSince1970
        let sessions = store.loadSessions(now: now)
        currentSessions = sessions

        displayStates = sessions.map { store.effective($0, now: now) }.sorted { $0.urgency < $1.urgency }
        let vibe = store.vibe(sessions, now: now)
        displayBody = vibe.color
        displayMood = vibe.mood
        if prevColorKey.isEmpty {
            displayColor = displayBody.color; fadeT = 1            // first paint: no fade
        } else if displayBody.colorKey != prevColorKey {
            fadeFrom = displayColor; fadeT = 0                     // fade from what's shown now
        }
        prevColorKey = displayBody.colorKey
        reactToTransitions(sessions: sessions, now: now)

        // Time-of-day + fatigue -> sleepiness (droopier eyes, slower, naps sooner).
        let hour = Calendar.current.component(.hour, from: Date())
        let night: CGFloat = (hour >= 22 || hour < 6) ? 0.5 : (hour >= 20 || hour < 7) ? 0.25 : 0
        switch displayMood {
        case .stressed: fatigue = min(1, fatigue + 0.0020)
        case .pressure: fatigue = min(1, fatigue + 0.0010)
        default:        fatigue = max(0, fatigue - 0.0030)
        }
        droopBias = min(1, night + fatigue * 0.55)
        eyes.droop = droopBias

        updateStatusTitle()

        renderStatusBar(force: true)
        handleAlerts(sessions: sessions, now: now)
        scheduleResetWarning(now: now)
        // NOTE: never rebuild `menu` while it's open — mutating an open NSMenu
        // (removeAllItems + re-add) leaves a stuck blank gap. The menu is rebuilt
        // fresh each time it opens via menuNeedsUpdate(_:), which is enough.
    }

    // MARK: personality

    /// A look vector toward the mouse when it's near the menu-bar icon, else nil.
    private func cursorTarget() -> CGVector? {
        guard let win = statusItem.button?.window else { cursorEngaged = false; return nil }
        let icon = CGPoint(x: win.frame.midX, y: win.frame.midY)
        let m = NSEvent.mouseLocation                     // screen coords, bottom-left origin
        let dx = m.x - icon.x, dy = m.y - icon.y
        let threshold: CGFloat = cursorEngaged ? 290 : 230   // hysteresis: no flapping at the boundary
        guard hypot(dx, dy) < threshold else { cursorEngaged = false; return nil }
        cursorEngaged = true
        let scale: CGFloat = 150
        return CGVector(dx: max(-1, min(1, dx / scale)), dy: max(-1, min(1, dy / scale)))
    }

    private func kindCode(_ e: EffectiveState) -> Int {
        switch e {
        case .working:    return 1
        case .permission: return 2
        case .finished:   return 3
        case .idle:       return 0
        }
    }

    /// Fire one-shot eye reactions on state changes, and keep `lastActivityAt`
    /// fresh so the mascot only naps when truly nothing is happening.
    private func reactToTransitions(sessions: [SessionState], now: Double) {
        var newKind: [String: Int] = [:]
        var newPermission = false, newFinished = false
        for s in sessions {
            let k = kindCode(store.effective(s, now: now))
            newKind[s.sessionId] = k
            let old = prevKind[s.sessionId]
            if old != k {
                lastActivityAt = now
                if k == 2, old != nil { newPermission = true }  // -> needs you (not a pre-existing one at launch)
                if k == 3, old != nil { newFinished = true }    // -> turn finished
            }
        }
        if Set(newKind.keys) != Set(prevKind.keys) { lastActivityAt = now }   // a session came/went

        let allReady = !sessions.isEmpty && newKind.values.allSatisfy { $0 == 0 || $0 == 3 }
        let hadWork = prevKind.values.contains { $0 == 1 || $0 == 2 }
        let celebrateNow = allReady && hadWork && !celebrated
        if !allReady { celebrated = false }

        if newPermission      { eyes.react(.alert) }            // "hey, look at me"
        else if celebrateNow  { eyes.react(.celebrate); celebrated = true }
        else if newFinished   { eyes.react(.happy) }

        prevKind = newKind
    }

    /// Advance the body-color cross-fade; returns true while still fading.
    private func advanceColorFade() -> Bool {
        guard fadeT < 1 else { return false }
        fadeT = min(1, fadeT + fadeStep)
        displayColor = blend(fadeFrom, displayBody.color, fadeT)
        return true
    }

    private func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let from = a.usingColorSpace(.sRGB) ?? a
        let to = b.usingColorSpace(.sRGB) ?? b
        return from.blended(withFraction: t, of: to) ?? to
    }

    /// Redraw the menu-bar icon for the current state + eye pose; skips the work
    /// when nothing changed, so the 12 fps animation tick stays cheap.
    private func renderStatusBar(force: Bool) {
        var p = eyes.pose
        p.blink = max(p.blink, droopBias * 0.45)         // time-of-day + fatigue droop
        let states = showDots ? displayStates : []      // dots off -> just the eyes
        // A mask override or boring mode ignores pose/mood, so keep them out of
        // the dedup key then — the eye animation must not force needless re-tints.
        let faceless = hasMascotMask() || boringMode
        // Whites drift is small (≤ ~0.28 of pupil travel), so it gets a finer
        // quantum than the other channels or its catch-up frames would dedup away.
        let poseKey = faceless ? (boringMode ? "boring" : "mask")
            : "\(Int(p.look.dx * 18))/\(Int(p.look.dy * 18))/\(Int(p.blink * 18))/\(Int(p.converge * 18))/\(Int(p.pupil * 18))"
            + "/\(Int(p.whiteL.dx * 64))/\(Int(p.whiteL.dy * 64))/\(Int(p.whiteR.dx * 64))/\(Int(p.whiteR.dy * 64))"
        let moodKey = faceless ? "" : "\(displayMood)"
        let sig = displayBody.colorKey + "#\(moodKey)#dots:\(showDots)#fade:\(Int(fadeT * 50))#"
                + states.map { $0.colorKey }.joined(separator: ",") + "#" + poseKey
        if !force && sig == lastStatusSig { return }
        lastStatusSig = sig
        statusItem.button?.image = statusImage(body: displayBody, states: states,
                                               height: kMenubarHeight, pose: p, mood: displayMood,
                                               bodyColor: displayColor, eyes: !boringMode)
    }

    /// The text riding after the mascot: the account-usage percentage (red once
    /// it's near the limit) and, if more shells are open than fit as dots, the
    /// "+N" overflow. Empty attributed title clears it.
    private func updateStatusTitle() {
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        if showUsage, let pct = usageStore.load()?.peakPercent {
            let hot = pct >= kUsageHotPercent
            title.append(NSAttributedString(string: " \(pct)%", attributes: [
                .font: font, .foregroundColor: hot ? NSColor.systemRed : NSColor.labelColor]))
        }
        let overflow = showDots ? max(0, displayStates.count - kMaxStatusDots) : 0
        if overflow > 0 {
            title.append(NSAttributedString(string: " +\(overflow)", attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        statusItem.button?.attributedTitle = title
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
                if alertsArmed { notify(session: s, permission: isPermission) }  // first pass: seed without re-dinging
            }
            if !eff.needsAttention { alertedAt[s.sessionId] = nil } // episode ended -> re-arm
        }
        for key in alertedAt.keys where !live.contains(key) { alertedAt[key] = nil }
        alertsArmed = true   // only ding for episodes that begin while we're running
    }

    // MARK: notifications

    /// Ask once for notification permission. With a valid signature + a unique
    /// bundle id, macOS shows the prompt; once granted, UNUserNotificationCenter
    /// notifications carry the app icon (the eyes). Falls back to osascript if denied.
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
        // Distinct sounds: a deeper "hey" for a blocking prompt, a soft chime when done.
        if playSound, let snd = NSSound(named: NSSound.Name(permission ? "Submarine" : "Glass")) {
            snd.volume = soundVolume
            snd.play()
        }
        let title = permission ? "Claude needs your input" : "Claude finished — your turn"
        let body = s.label.isEmpty ? "A session is waiting." : s.label
        if notifReady {
            postOwnNotification(title: title, body: body, permission: permission)
        } else {
            postBanner(title: title, body: body)
        }
    }

    private let kResetWarningId = "five-hour-reset-warning"

    /// Queue a banner for 30 min before the 5-hour window resets. Scheduled
    /// ahead of time so it fires even when no session is running to refresh
    /// usage; a fixed identifier means a new reset time replaces the old one.
    private func scheduleResetWarning(now: Double) {
        guard warnBeforeReset else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [kResetWarningId])
            scheduledResetAt = 0   // re-enabling re-queues the warning
            return
        }
        guard notifReady, let reset = usageStore.load()?.fiveHour?.resetsAt,
              reset != scheduledResetAt else { return }
        scheduledResetAt = reset
        let fireIn = reset - 30 * 60 - now
        guard fireIn > 0 else { return }   // already inside the last 30 min
        let content = UNMutableNotificationContent()
        content.title = "5-hour limit resets in 30 minutes"
        content.body = "Your Claude session window refreshes soon."
        content.sound = playSound ? .default : nil
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: kResetWarningId, content: content, trigger: trigger))
    }

    /// Post via UNUserNotificationCenter — the banner icon is always the app
    /// icon (macOS won't tint banners), so the state color rides along as an
    /// attached mascot image: yellow for a blocking prompt, green for a
    /// finished turn.
    private func postOwnNotification(title: String, body: String, permission: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil                       // we already played the sound instantly
        if let att = mascotAttachment(permission: permission) { content.attachments = [att] }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// A state-colored mascot PNG for the notification thumbnail. The system
    /// moves the file into its own attachment store on delivery, so a fresh
    /// temp file per notification is correct (no cleanup needed on success).
    private func mascotAttachment(permission: Bool) -> UNNotificationAttachment? {
        let state: EffectiveState = permission ? .permission : .finished
        let img = mascotImage(color: state.color, height: 256,
                              mood: permission ? .alert : .chill)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-notif-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return try UNNotificationAttachment(identifier: "state", url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Fallback macOS banner via osascript (used only if the user denies the
    /// notification permission; attributed to Script Editor).
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
        addUsageSection(to: menu, now: now)

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

        let soundItem = NSMenuItem(title: "Play a sound", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = playSound ? .on : .off
        menu.addItem(soundItem)

        let volumeItem = NSMenuItem()
        volumeItem.view = makeVolumeSliderView()
        menu.addItem(volumeItem)

        let dotsItem = NSMenuItem(title: "Show per-shell dots", action: #selector(toggleDots), keyEquivalent: "")
        dotsItem.target = self
        dotsItem.state = showDots ? .on : .off
        menu.addItem(dotsItem)

        let usageItem = NSMenuItem(title: "Show account usage", action: #selector(toggleUsage), keyEquivalent: "")
        usageItem.target = self
        usageItem.state = showUsage ? .on : .off
        usageItem.toolTip = "Show how much of your 5-hour and weekly limits you've used"
        menu.addItem(usageItem)

        let resetItem = NSMenuItem(title: "Warn 30 min before 5-hour reset", action: #selector(toggleResetWarning), keyEquivalent: "")
        resetItem.target = self
        resetItem.state = warnBeforeReset ? .on : .off
        resetItem.toolTip = "Notify you half an hour before your 5-hour usage limit resets"
        menu.addItem(resetItem)

        let boringItem = NSMenuItem(title: "Boring mode", action: #selector(toggleBoring), keyEquivalent: "")
        boringItem.target = self
        boringItem.state = boringMode ? .on : .off
        boringItem.toolTip = "No eyes, no animation — just a colored light"
        menu.addItem(boringItem)

        let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = openAtLogin ? .on : .off
        loginItem.toolTip = "Start automatically when you log in"
        menu.addItem(loginItem)

        menu.addItem(.separator())
        if let u = update {
            let item = NSMenuItem(title: "Update available — v\(u.version)",
                                  action: #selector(openUpdate), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Update")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    /// The "Account usage" panel: a header plus the two-bar usage view, shown
    /// only when we have a snapshot to render. Adds its own trailing separator
    /// so it groups cleanly without leaving a double rule when there's no data.
    private func addUsageSection(to menu: NSMenu, now: Double) {
        guard showUsage, let usage = usageStore.load(), usage.mostConstrained != nil else { return }
        let header = NSMenuItem(title: "Account usage", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let item = NSMenuItem()
        item.view = UsageMenuView(usage: usage, now: now)
        menu.addItem(item)
        menu.addItem(.separator())
    }

    /// Speaker-to-speaker volume slider, shown as a menu row under "Play a sound".
    /// Custom-view items don't close the menu, so you can drag to taste; releasing
    /// the knob plays the chime at the new level as a preview.
    private func makeVolumeSliderView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 22))

        let quiet = NSImageView(frame: NSRect(x: 22, y: 4, width: 14, height: 14))
        quiet.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Quiet")
        quiet.contentTintColor = .secondaryLabelColor
        container.addSubview(quiet)

        let slider = NSSlider(value: Double(soundVolume), minValue: 0, maxValue: 1,
                              target: self, action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: 42, y: 1, width: 168, height: 20)
        slider.controlSize = .small
        slider.isEnabled = playSound
        slider.toolTip = "Notification sound volume"
        container.addSubview(slider)

        let loud = NSImageView(frame: NSRect(x: 216, y: 4, width: 16, height: 14))
        loud.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Loud")
        loud.contentTintColor = .secondaryLabelColor
        container.addSubview(loud)

        return container
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

    @objc private func toggleDots() {
        defaults.set(!showDots, forKey: "showDots")
        refresh()
    }

    @objc private func toggleSound() {
        defaults.set(!playSound, forKey: "playSound")
        refresh()
    }

    @objc private func toggleUsage() {
        defaults.set(!showUsage, forKey: "showUsage")
        refresh()
    }

    @objc private func toggleResetWarning() {
        defaults.set(!warnBeforeReset, forKey: "warnBeforeReset")
        refresh()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        defaults.set(sender.floatValue, forKey: "soundVolume")
        // Preview only on release — continuous playback while dragging is grating.
        if NSApp.currentEvent?.type == .leftMouseUp, playSound,
           let snd = NSSound(named: "Glass") {
            snd.volume = sender.floatValue
            snd.play()
        }
    }

    @objc private func toggleBoring() {
        defaults.set(!boringMode, forKey: "boringMode")
        if !boringMode { eyes.react(.wake) }   // eyes pop back awake when leaving boring mode
        refresh()
    }

    // MARK: open at login

    /// The same LaunchAgent that ./autostart.sh installs — managing one file
    /// keeps the menu toggle and the script in agreement.
    private var loginAgentPlist: String {
        ("~/Library/LaunchAgents/com.mitchelmckee.claude-traffic-light.plist" as NSString).expandingTildeInPath
    }

    private var openAtLogin: Bool { FileManager.default.fileExists(atPath: loginAgentPlist) }

    @objc private func toggleOpenAtLogin() {
        let fm = FileManager.default
        if openAtLogin {
            // Just remove the file: launchd only reads ~/Library/LaunchAgents at
            // login, and booting the label out now could kill this very process
            // if launchd started it.
            try? fm.removeItem(atPath: loginAgentPlist)
        } else {
            guard let bin = Bundle.main.executablePath else { return }
            let agent: [String: Any] = [
                "Label": "com.mitchelmckee.claude-traffic-light",
                "ProgramArguments": [bin],
                "RunAtLoad": true,
                "KeepAlive": false,               // Quit from the menu sticks until next login
                "ProcessType": "Interactive",
            ]
            let dir = (loginAgentPlist as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0) {
                try? data.write(to: URL(fileURLWithPath: loginAgentPlist))
            }
        }
    }

}
