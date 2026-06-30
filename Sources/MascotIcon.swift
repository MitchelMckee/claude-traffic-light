import AppKit

/// Menu-bar icon height — fill the whole bar so the mascot is as big as macOS allows.
let kMenubarHeight: CGFloat = NSStatusBar.system.thickness

/// Up to this many per-shell dots are drawn; the rest become a "+N" title.
let kMaxStatusDots = 6

/// Where the mascot is looking, and whether he's mid-blink.
struct EyePose {
    var look: CGVector = .zero   // pupil offset; each axis in [-1, 1], +dy = up
    var blink: CGFloat = 0       // 0 = open, 1 = closed
    static let neutral = EyePose()
}

/// The ONLY expressive tool: how tall the eyes are (1 = round, <1 squished
/// flat, >1 stretched tall). Everything else is off-limits — the face is just
/// two circles, each with a circle inside.
private func eyeHeightFactor(_ mood: Mood) -> CGFloat {
    switch mood {
    case .alert:    return 1.70   // tall — wide awake
    case .chill:    return 1.00   // round — relaxed
    case .pressure: return 0.58   // squished — strained
    case .stressed: return 0.30   // flat — drained
    }
}

/// Draws the mascot: a colored blob with two eyes (each a circle containing a
/// circle). Mood only changes the eyes' height. A `mascot-mask.png` override,
/// if present, is used instead.
func mascotImage(color: NSColor, height: CGFloat = 22,
                 pose: EyePose = .neutral, mood: Mood = .chill) -> NSImage {
    if let mask = loadMascotMask() {
        return tinted(mask, color: color, height: height)
    }
    return drawMascot(color: color, height: height, pose: pose, mood: mood)
}

private func drawMascot(color: NSColor, height: CGFloat, pose: EyePose, mood: Mood) -> NSImage {
    let size = NSSize(width: height, height: height)
    let img = NSImage(size: size)
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = height * 0.035
    let rect = NSRect(x: inset, y: inset, width: height - inset * 2, height: height - inset * 2)

    // Body: a soft rounded blob, filling most of the icon.
    let radius = rect.width * 0.42
    let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    color.setFill()
    body.fill()
    NSColor.black.withAlphaComponent(0.28).setStroke()
    body.lineWidth = max(0.75, height * 0.04)
    body.stroke()

    // Two big eyes that dominate the face. Mood squishes their height; that's
    // the whole repertoire.
    let eyeW = rect.width * 0.41
    let gap  = rect.width * 0.08
    let cy   = rect.minY + rect.height * 0.50
    let hf   = eyeHeightFactor(mood)
    drawEye(cx: rect.midX - gap / 2 - eyeW / 2, cy: cy, eyeW: eyeW, hf: hf, pose: pose)
    drawEye(cx: rect.midX + gap / 2 + eyeW / 2, cy: cy, eyeW: eyeW, hf: hf, pose: pose)

    img.unlockFocus()
    img.isTemplate = false
    return img
}

private func drawEye(cx: CGFloat, cy: CGFloat, eyeW: CGFloat, hf: CGFloat, pose: EyePose) {
    let open = max(0, 1 - pose.blink)                  // blink is just a hard squish
    let eyeH = max(eyeW * 0.05, eyeW * hf * open)

    // Eye (a circle, squished to an ellipse).
    let eyeRect = NSRect(x: cx - eyeW / 2, y: cy - eyeH / 2, width: eyeW, height: eyeH)
    let eye = NSBezierPath(ovalIn: eyeRect)
    NSColor.white.setFill()
    eye.fill()
    NSColor.black.withAlphaComponent(0.30).setStroke()   // thin edge so white reads on any body color
    eye.lineWidth = max(0.5, eyeW * 0.05)
    eye.stroke()

    // Pupil (a circle inside, squished with the eye, moved by the glance).
    let pupilW = eyeW * 0.55
    let pupilH = pupilW * (eyeH / eyeW)
    let maxOffX = max(0, (eyeW - pupilW) / 2 * 0.82)
    let maxOffY = max(0, (eyeH - pupilH) / 2 * 0.82)
    let px = cx + pose.look.dx * maxOffX
    let py = cy + pose.look.dy * maxOffY
    NSColor(white: 0.13, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: px - pupilW / 2, y: py - pupilH / 2, width: pupilW, height: pupilH)).fill()
}

/// The status-bar image: the mascot (body tinted by `body`, expressing `mood`)
/// followed by one small dot per shell, sorted most-urgent first.
func statusImage(body: EffectiveState, states: [EffectiveState],
                 height: CGFloat = kMenubarHeight, pose: EyePose = .neutral, mood: Mood = .chill) -> NSImage {
    let mascot = mascotImage(color: body.color, height: height, pose: pose, mood: mood)
    guard states.count >= 2 else { return mascot }

    let dotD     = (height * 0.38).rounded()
    let dotGap   = max(1, (dotD * 0.40).rounded())
    let groupGap = max(2, (dotD * 0.95).rounded())
    let lead     = (height * 0.22).rounded()

    let shown = Array(states.prefix(kMaxStatusDots))

    func gapBefore(_ i: Int, _ key: inout String?) -> CGFloat {
        defer { key = shown[i].colorKey }
        guard i > 0 else { return 0 }
        return key == shown[i].colorKey ? dotGap : groupGap
    }

    var dotsW: CGFloat = 0
    var k: String? = nil
    for i in shown.indices { dotsW += gapBefore(i, &k) + dotD }
    let mascotW = mascot.size.width

    let img = NSImage(size: NSSize(width: ceil(mascotW + lead + dotsW), height: height))
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    mascot.draw(in: NSRect(x: 0, y: 0, width: mascotW, height: height))

    var x = mascotW + lead
    let dotY = ((height - dotD) / 2).rounded()
    k = nil
    for i in shown.indices {
        x += gapBefore(i, &k)
        let r = NSRect(x: x, y: dotY, width: dotD, height: dotD)
        shown[i].color.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25)); ring.lineWidth = 0.5; ring.stroke()
        x += dotD
    }

    img.unlockFocus()
    img.isTemplate = false
    return img
}

private func tinted(_ mask: NSImage, color: NSColor, height: CGFloat) -> NSImage {
    let size = NSSize(width: height, height: height)
    let img = NSImage(size: size)
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    let rect = NSRect(origin: .zero, size: size)
    mask.draw(in: rect)
    color.set()
    rect.fill(using: .sourceAtop)
    img.unlockFocus()
    img.isTemplate = false
    return img
}

private func loadMascotMask() -> NSImage? {
    let fm = FileManager.default
    let candidates = [
        ("~/.claude/menubar-state/mascot-mask.png" as NSString).expandingTildeInPath,
        Bundle.main.bundlePath + "/Contents/Resources/mascot-mask.png",
    ]
    for path in candidates where fm.fileExists(atPath: path) {
        if let img = NSImage(contentsOfFile: path) { return img }
    }
    return nil
}
