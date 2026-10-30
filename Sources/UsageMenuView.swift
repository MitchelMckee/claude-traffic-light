import AppKit

/// The dropdown's "Account usage" panel: one labeled progress bar per rate-limit
/// window (the 5-hour session limit and the 7-day weekly limit), each colored by
/// how close it is to the cap, plus a freshness caption that makes the
/// "only refreshes while Claude is running" caveat concrete.
final class UsageMenuView: NSView {
    private let usage: AccountUsage
    private let now: Double

    private static let panelWidth: CGFloat = 300
    private let padX: CGFloat = 20
    private let rowH: CGFloat = 34

    init(usage: AccountUsage, now: Double) {
        self.usage = usage
        self.now = now
        let rows = [usage.fiveHour, usage.sevenDay].compactMap { $0 }.count
        let height = CGFloat(rows) * 34 + 26   // window rows + freshness footer + padding
        super.init(frame: NSRect(x: 0, y: 0, width: UsageMenuView.panelWidth, height: height))
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }   // lay out top-down

    override func draw(_ dirtyRect: NSRect) {
        var y: CGFloat = 6
        drawWindow(label: "5-hour session", window: usage.fiveHour, y: &y)
        drawWindow(label: "Weekly (7-day)", window: usage.sevenDay, y: &y)

        let foot = "\(freshnessPhrase(usage.updatedAt, now: now))  ·  refreshes while Claude runs"
        draw(foot, at: NSPoint(x: padX, y: y + 2),
             font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
    }

    private func drawWindow(label: String, window: UsageWindow?, y: inout CGFloat) {
        guard let w = window else { return }
        let pct = max(0, min(100, w.usedPercentage))
        let heat = usageColor(pct)
        let width = UsageMenuView.panelWidth

        // Top line: label on the left, "NN% · resets in …" on the right.
        draw(label, at: NSPoint(x: padX, y: y),
             font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)

        let right = NSMutableAttributedString()
        right.append(NSAttributedString(string: "\(Int(pct.rounded()))%", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: heat]))
        right.append(NSAttributedString(string: "   \(resetPhrase(w.resetsAt, now: now))", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        right.draw(at: NSPoint(x: width - padX - right.size().width, y: y + 1))

        // Track, then the filled portion in the heat color.
        let barY = y + 20, barW = width - padX * 2
        let track = NSBezierPath(roundedRect: NSRect(x: padX, y: barY, width: barW, height: 6),
                                 xRadius: 3, yRadius: 3)
        NSColor.quaternaryLabelColor.setFill(); track.fill()
        let fillW = max(6, barW * CGFloat(pct / 100))
        let fill = NSBezierPath(roundedRect: NSRect(x: padX, y: barY, width: fillW, height: 6),
                                xRadius: 3, yRadius: 3)
        heat.setFill(); fill.fill()

        y += rowH
    }

    private func draw(_ s: String, at p: NSPoint, font: NSFont, color: NSColor) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: p)
    }
}

/// Heat ramp for a usage percentage: green while there's headroom, amber as it
/// tightens, red once you're close to being locked out.
func usageColor(_ pct: Double) -> NSColor {
    switch pct {
    case ..<60:                       return .systemGreen
    case ..<Double(kUsageHotPercent): return .systemOrange
    default:                          return .systemRed
    }
}
