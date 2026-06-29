import AppKit

/// Draws the little "Claude bot" mascot tinted by the given color, sized for
/// the menubar. Drawn in code so there is no asset to ship and the tint is
/// exact. If `~/.claude/menubar-state/mascot-mask.png` (or a `mascot-mask.png`
/// next to the executable) exists, it is used as an alpha mask instead, so you
/// can drop in your own silhouette and have it recolored by state.
func mascotImage(color: NSColor, height: CGFloat = 18) -> NSImage {
    if let mask = loadMascotMask() {
        return tinted(mask, color: color, height: height)
    }
    return drawMascot(color: color, height: height)
}

/// Up to this many per-shell dots are drawn; the rest become a "+N" title.
let kMaxStatusDots = 6

/// The status-bar image: the mascot (tinted by the aggregate state) followed by
/// one small dot per shell, sorted most-urgent first and grouped by color so you
/// can count each state at a glance. With a single shell it's just the mascot.
/// Overflow past `kMaxStatusDots` is shown as a "+N" button title (drawn by
/// AppKit so it adapts to a light/dark menubar), not baked into this image.
///
/// `states` must already be sorted by urgency; `aggregate` tints the mascot.
func statusImage(aggregate: EffectiveState, states: [EffectiveState], height: CGFloat = 18) -> NSImage {
    let mascot = mascotImage(color: aggregate.color, height: height)
    guard states.count >= 2 else { return mascot }

    let dotD     = (height * 0.40).rounded()
    let dotGap   = max(1, (dotD * 0.40).rounded())   // gap within a color group
    let groupGap = max(2, (dotD * 0.95).rounded())   // wider gap between color groups
    let lead     = (height * 0.24).rounded()         // gap between mascot and first dot

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
        let rect = NSRect(x: x, y: dotY, width: dotD, height: dotD)
        shown[i].color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25)); ring.lineWidth = 0.5; ring.stroke()
        x += dotD
    }

    img.unlockFocus()
    img.isTemplate = false
    return img
}

private func drawMascot(color: NSColor, height: CGFloat) -> NSImage {
    let size = NSSize(width: height, height: height)
    let img = NSImage(size: size)
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = height * 0.12
    let rect = NSRect(x: inset, y: inset, width: height - inset * 2, height: height - inset * 2)

    // Rounded "squircle" body.
    let radius = rect.width * 0.34
    let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    color.setFill()
    body.fill()

    // Thin outline so it reads on both light and dark menubars.
    NSColor.black.withAlphaComponent(0.30).setStroke()
    body.lineWidth = max(0.75, height * 0.05)
    body.stroke()

    // Two eyes -> reads as a friendly little guy at a glance.
    let eyeW = rect.width * 0.17
    let eyeH = rect.height * 0.24
    let eyeY = rect.minY + rect.height * 0.44
    let leftX = rect.minX + rect.width * 0.26
    let rightX = rect.minX + rect.width * 0.57
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: leftX, y: eyeY, width: eyeW, height: eyeH)).fill()
    NSBezierPath(ovalIn: NSRect(x: rightX, y: eyeY, width: eyeW, height: eyeH)).fill()
    NSColor.black.withAlphaComponent(0.55).setFill()
    let pupilW = eyeW * 0.5, pupilH = eyeH * 0.5
    NSBezierPath(ovalIn: NSRect(x: leftX + eyeW * 0.28, y: eyeY + eyeH * 0.2, width: pupilW, height: pupilH)).fill()
    NSBezierPath(ovalIn: NSRect(x: rightX + eyeW * 0.28, y: eyeY + eyeH * 0.2, width: pupilW, height: pupilH)).fill()

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
