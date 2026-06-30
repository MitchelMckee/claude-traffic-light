import AppKit

/// One waypoint in an animation clip: where the pupils ease to, the blink
/// amount, and how many ~12fps frames to spend easing there / holding.
private struct WP {
    var look: CGVector
    var blink: CGFloat = 0
    var move: Int = 6
    var hold: Int = 8
}

private struct ClipDef {
    var steps: [WP]
    var moods: Set<Mood>
}

/// Drives the mascot's eyes by playing short "clips" — sequences of glances
/// and blinks. Each clip starts from centre and ENDS at centre, so clips chain
/// seamlessly. A fresh clip is chosen at random (no immediate repeat) from the
/// pool eligible for the current mood (≥5 per mood), and timing is scaled by a
/// per-mood tempo so each state feels distinct.
final class EyeAnimator {
    private(set) var pose = EyePose()

    private var active: [WP] = []
    private var step = 0
    private var frame = 0
    private var fromLook = CGVector.zero
    private var fromBlink: CGFloat = 0
    private var lastIndex = -1

    /// Advance one frame for the given mood. Returns true if the pose moved.
    func tick(mood: Mood) -> Bool {
        let before = pose
        if step >= active.count { startClip(mood: mood) }

        let wp = active[step]
        if frame < wp.move {
            let t = smooth(CGFloat(frame + 1) / CGFloat(max(1, wp.move)))
            pose.look = lerp(fromLook, wp.look, t)
            pose.blink = fromBlink + (wp.blink - fromBlink) * t
        } else {
            pose.look = wp.look
            pose.blink = wp.blink
        }

        frame += 1
        if frame >= wp.move + wp.hold {
            fromLook = wp.look
            fromBlink = wp.blink
            step += 1
            frame = 0
        }

        return abs(pose.look.dx - before.look.dx) + abs(pose.look.dy - before.look.dy)
             + abs(pose.blink - before.blink) > 0.003
    }

    private func startClip(mood: Mood) {
        let pool = EyeAnimator.clips.indices.filter { EyeAnimator.clips[$0].moods.contains(mood) }
        var idx = pool.randomElement() ?? 0
        if pool.count > 1 { while idx == lastIndex { idx = pool.randomElement()! } }
        lastIndex = idx

        let tempo = EyeAnimator.tempo(mood)
        active = EyeAnimator.clips[idx].steps.map {
            WP(look: $0.look, blink: $0.blink,
               move: max(1, Int((CGFloat($0.move) * tempo).rounded())),
               hold: max(1, Int((CGFloat($0.hold) * tempo).rounded())))
        }
        step = 0
        frame = 0
        fromLook = pose.look     // current pose is centre (clips end there) -> seamless
        fromBlink = pose.blink
    }

    private func smooth(_ t: CGFloat) -> CGFloat { let c = min(1, max(0, t)); return c * c * (3 - 2 * c) }
    private func lerp(_ a: CGVector, _ b: CGVector, _ t: CGFloat) -> CGVector {
        CGVector(dx: a.dx + (b.dx - a.dx) * t, dy: a.dy + (b.dy - a.dy) * t)
    }

    private static func tempo(_ m: Mood) -> CGFloat {
        switch m {
        case .chill:    return 1.40   // slow & lazy
        case .alert:    return 0.85   // snappy
        case .pressure: return 1.00
        case .stressed: return 0.60   // fast & jittery
        }
    }

    private static let all: Set<Mood> = [.chill, .alert, .pressure, .stressed]
    private static func wp(_ dx: CGFloat, _ dy: CGFloat, blink: CGFloat = 0, m: Int = 6, h: Int = 8) -> WP {
        WP(look: CGVector(dx: dx, dy: dy), blink: blink, move: m, hold: h)
    }

    /// Every clip begins from centre and ends back at centre (look 0, blink 0).
    private static let clips: [ClipDef] = [
        // --- universal (≥5 per mood on their own) ---
        ClipDef(steps: [wp(0, 0, blink: 1, m: 2, h: 1), wp(0, 0, blink: 0, m: 3, h: 10)], moods: all),                                  // single blink
        ClipDef(steps: [wp(0, 0, blink: 1, m: 2, h: 1), wp(0, 0, blink: 0, m: 2, h: 2),
                        wp(0, 0, blink: 1, m: 2, h: 1), wp(0, 0, blink: 0, m: 3, h: 9)], moods: all),                                    // double blink
        ClipDef(steps: [wp(-0.9, 0, m: 6, h: 9), wp(0.9, 0, m: 8, h: 9), wp(0, 0, m: 6, h: 8)], moods: all),                            // look left, right, centre
        ClipDef(steps: [wp(0, 0.8, m: 6, h: 9), wp(0, 0, m: 6, h: 8)], moods: all),                                                     // glance up
        ClipDef(steps: [wp(0, -0.7, m: 6, h: 9), wp(0, 0, m: 6, h: 8)], moods: all),                                                    // glance down
        ClipDef(steps: [wp(0.85, 0.25, m: 3, h: 6), wp(0, 0, m: 4, h: 9)], moods: all),                                                 // quick side glance
        ClipDef(steps: [wp(0, 0.8, m: 4, h: 2), wp(0.8, 0.2, m: 4, h: 2), wp(0, -0.7, m: 4, h: 2),
                        wp(-0.8, 0.2, m: 4, h: 2), wp(0, 0, m: 4, h: 6)], moods: all),                                                   // roll around

        // --- mood-flavoured extras ---
        ClipDef(steps: [wp(-0.5, 0.1, m: 12, h: 16), wp(0, 0, m: 12, h: 12)], moods: [.chill]),                                         // slow lazy drift
        ClipDef(steps: [wp(0, 0, blink: 1, m: 5, h: 4), wp(0, 0, blink: 0, m: 5, h: 14)], moods: [.chill]),                             // slow sleepy blink
        ClipDef(steps: [wp(0.9, 0.1, m: 2, h: 3), wp(0, 0, m: 2, h: 2), wp(0.9, 0.1, m: 2, h: 4), wp(0, 0, m: 3, h: 7)], moods: [.alert]), // double-take
        ClipDef(steps: [wp(0, 0, m: 2, h: 10), wp(-0.8, 0, m: 2, h: 2), wp(0, 0, m: 3, h: 8)], moods: [.alert, .pressure]),             // lock forward, sharp dart, back
        ClipDef(steps: [wp(0.7, 0, m: 2, h: 2), wp(0, 0, m: 2, h: 14)], moods: [.pressure]),                                            // tense dart then locked stare
        ClipDef(steps: [wp(-0.9, 0, m: 2, h: 2), wp(0.9, 0, m: 2, h: 2), wp(-0.9, 0, m: 2, h: 2),
                        wp(0.9, 0, m: 2, h: 2), wp(0, 0, m: 3, h: 4)], moods: [.stressed]),                                             // panic side-to-side
        ClipDef(steps: [wp(0, 0, blink: 1, m: 1, h: 1), wp(0, 0, blink: 0, m: 1, h: 1),
                        wp(0, 0, blink: 1, m: 1, h: 1), wp(0, 0, blink: 0, m: 1, h: 1),
                        wp(0, 0, blink: 1, m: 1, h: 1), wp(0, 0, blink: 0, m: 2, h: 6)], moods: [.stressed]),                            // rapid blinks
    ]
}
