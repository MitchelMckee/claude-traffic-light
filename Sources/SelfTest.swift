import AppKit

/// Renders the status-bar image for a few shell mixes to PNGs (at a large size
/// for inspection), so the dot strip can be checked without the live menubar.
func renderStatusSamples(toDir dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let H: CGFloat = 96

    func save(_ img: NSImage, _ name: String) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("wrote \(name).png  (\(Int(img.size.width))x\(Int(img.size.height)))")
    }

    func strip(_ items: [(NSColor, EyePose, Mood)], _ name: String, gap: CGFloat = H * 0.4) {
        let img = NSImage(size: NSSize(width: CGFloat(items.count) * H + CGFloat(items.count - 1) * gap, height: H))
        img.lockFocus()
        var x: CGFloat = 0
        for (c, p, m) in items {
            mascotImage(color: c, height: H, pose: p, mood: m).draw(in: NSRect(x: x, y: 0, width: H, height: H))
            x += H + gap
        }
        img.unlockFocus()
        save(img, name)
    }

    // Hero: three states, each with its mood + a glance.
    strip([
        (.systemRed,    EyePose(look: CGVector(dx: -0.7, dy: 0.1)), .pressure),
        (.systemYellow, EyePose(look: CGVector(dx: 0,    dy: 0.4)), .alert),
        (.systemGreen,  EyePose(look: CGVector(dx: 0.7,  dy: 0.1)), .chill),
    ], "mascot-states")

    // Mood sheet: chill · alert · under pressure · stressed.
    strip([
        (.systemGreen,  EyePose(), .chill),
        (.systemYellow, EyePose(), .alert),
        (.systemRed,    EyePose(), .pressure),
        (.systemRed,    EyePose(), .stressed),
    ], "moods")

    // Eye-pose sheet (animation tuning).
    strip([
        (.systemGreen, EyePose(look: CGVector(dx: -0.9, dy: 0)), .chill),
        (.systemGreen, EyePose(), .chill),
        (.systemGreen, EyePose(look: CGVector(dx: 0.9, dy: 0)), .chill),
        (.systemGreen, EyePose(look: CGVector(dx: 0, dy: 0.7)), .chill),
        (.systemGreen, EyePose(blink: 0.55), .chill),
        (.systemGreen, EyePose(blink: 1.0), .chill),
    ], "poses")

    // Multi-shell dot strip (3 working -> body red, stressed).
    let states: [EffectiveState] = [.permission, .working, .working, .working, .finished, .idle]
    let sorted = states.sorted { $0.urgency < $1.urgency }
    save(statusImage(body: .working, states: sorted, height: H, mood: .stressed), "dot-strip")
}

/// Render a 1024px mascot PNG to use as the app-icon master (turned into
/// AppIcon.icns by make-icon.sh).
func renderAppIcon(toPath path: String) {
    let pose = EyePose(look: CGVector(dx: 0, dy: -0.28))     // tall eyes glancing down
    let img = mascotImage(color: NSColor.systemGreen, height: 1024, pose: pose, mood: .alert)
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote app icon master: \(path)")
}

/// Headless check of the read -> decay -> aggregate pipeline. Prints what the
/// menubar would show for the current contents of the state directory.
func runSelfTest() {
    let store = StateStore()
    let now = Date().timeIntervalSince1970
    let sessions = store.loadSessions()

    print("state dir: \(store.dir)")
    print("sessions : \(sessions.count)")
    for s in sessions {
        let eff = store.effective(s, now: now)
        let age = Int(now - s.updatedAt)
        print(String(format: "  %@  %-16@  raw=%-10@ eff=%-10@ pid=%d age=%ds  [%@]",
                     eff.dot, s.label as NSString, s.state.rawValue as NSString,
                     "\(eff)" as NSString, s.pid, age, s.terminalProgram as NSString))
    }
    let agg = store.aggregate(sessions, now: now)
    print("aggregate icon: \(agg.colorKey)  -> \(agg)")
}
