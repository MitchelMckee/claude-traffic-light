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

    // Hero: the three mascot states side by side (red = working, yellow = needs
    // you, green = ready).
    let trio: [EffectiveState] = [.working, .permission, .idle]
    let gap = H * 0.4
    let hero = NSImage(size: NSSize(width: CGFloat(trio.count) * H + CGFloat(trio.count - 1) * gap, height: H))
    hero.lockFocus()
    var x: CGFloat = 0
    for st in trio { mascotImage(color: st.color, height: H).draw(in: NSRect(x: x, y: 0, width: H, height: H)); x += H + gap }
    hero.unlockFocus()
    save(hero, "mascot-states")

    // A multi-shell dot strip.
    let states: [EffectiveState] = [.permission, .working, .working, .working, .finished, .idle]
    let sorted = states.sorted { $0.urgency < $1.urgency }
    save(statusImage(aggregate: sorted.first ?? .idle, states: sorted, height: H), "dot-strip")
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
