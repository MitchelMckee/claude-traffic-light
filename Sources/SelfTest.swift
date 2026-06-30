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

    // Eye-pose sheet (animation tuning): the new personality poses.
    strip([
        (.systemGreen,  EyePose(look: CGVector(dx: 0.9, dy: 0)), .chill),                  // cursor-follow glance
        (.systemGreen,  EyePose(look: CGVector(dx: 0, dy: -0.25), blink: 0.6), .chill),    // sleepy droop (nap)
        (.systemGreen,  EyePose(look: CGVector(dx: 0, dy: 0.5), blink: 0.5), .chill),      // happy squint
        (.systemRed,    EyePose(converge: 0.9), .pressure),                                // crossed eyes (egg)
        (.systemYellow, EyePose(look: CGVector(dx: 0.85, dy: -0.1), blink: 0.35), .alert), // suspicious side-eye
        (.systemGreen,  EyePose(blink: 1.0), .chill),                                      // blink closed
    ], "poses")

    // Multi-shell dot strip (3 working -> body red, stressed).
    let states: [EffectiveState] = [.permission, .working, .working, .working, .finished, .idle]
    let sorted = states.sorted { $0.urgency < $1.urgency }
    save(statusImage(body: .working, states: sorted, height: H, mood: .stressed), "dot-strip")
}

/// Render a 1024px app-icon master (turned into AppIcon.icns by make-icon.sh):
/// a green squircle with the mascot's eyes, composed for the macOS icon grid.
func renderAppIcon(toPath path: String) {
    let S: CGFloat = 1024
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current
    ctx?.imageInterpolation = .high

    // Squircle background inset with a margin (Big Sur icon grid: corner ≈ 22.37%).
    let margin = S * 0.085
    let rect = NSRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)

    ctx?.saveGraphicsState()
    squircle.addClip()
    let top = NSColor(srgbRed: 1.00, green: 0.86, blue: 0.25, alpha: 1)
    let bottom = NSColor(srgbRed: 0.96, green: 0.72, blue: 0.05, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
    ctx?.restoreGraphicsState()

    // Two white oval eyes with dark pupils, slightly above centre, looking a
    // touch down. A soft shadow under each gives a little depth.
    let eyeW = S * 0.215, eyeH = S * 0.315, gap = S * 0.052
    let cy = S * 0.535
    for cx in [S / 2 - gap / 2 - eyeW / 2, S / 2 + gap / 2 + eyeW / 2] {
        let eyeRect = NSRect(x: cx - eyeW / 2, y: cy - eyeH / 2, width: eyeW, height: eyeH)
        ctx?.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.20)
        sh.shadowBlurRadius = S * 0.022
        sh.shadowOffset = NSSize(width: 0, height: -S * 0.014)
        sh.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: eyeRect).fill()
        ctx?.restoreGraphicsState()

        let pupilW = eyeW * 0.54, pupilH = eyeW * 0.54 * (eyeH / eyeW)
        let offY = -0.16 * (eyeH - pupilH) / 2
        NSColor(white: 0.13, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - pupilW / 2, y: cy + offY - pupilH / 2, width: pupilW, height: pupilH)).fill()
    }

    img.unlockFocus()
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
