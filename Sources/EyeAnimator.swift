import AppKit

/// One waypoint in an animation clip: where the pupils ease to, the blink
/// amount, how crossed the eyes are, and how many ~12fps frames to spend
/// easing there / holding.
private struct WP {
    var look: CGVector
    var blink: CGFloat = 0
    var converge: CGFloat = 0
    var move: Int = 6
    var hold: Int = 8
}

private struct ClipDef {
    var steps: [WP]
    var moods: Set<Mood>
}

/// One-shot reactions fired by app events; they interrupt whatever's playing.
enum EyeReaction { case happy, alert, celebrate, wake }

/// Drives the mascot's eyes. Priority each frame:
///   1. a queued reaction (interrupts everything),
///   2. cursor-follow when the mouse is near the icon,
///   3. a sleepy nap when everything's been idle a while,
///   4. otherwise normal mood clips (with a rare easter egg).
/// Clips begin and end at centre so they chain seamlessly.
final class EyeAnimator {
    private(set) var pose = EyePose()

    /// When set, the eyes follow this target (each axis in [-1, 1]).
    var lookTarget: CGVector?
    /// When true, the eyes get sleepy and nap.
    var drowsy = false

    private var active: [WP] = []
    private var step = 0
    private var frame = 0
    private var fromLook = CGVector.zero
    private var fromBlink: CGFloat = 0
    private var fromConverge: CGFloat = 0
    private var lastIndex = -1
    private var forced = false          // active clip is a one-shot reaction
    private var pending: [WP]?          // a queued reaction
    private var followBlink = 0         // blink countdown while cursor-following
    private var recentering = false     // gliding gaze back to centre after follow
    private var reactionKind: EyeReaction?   // reaction currently forced (drives pupil size)
    private var queuedKind: EyeReaction?     // reaction queued via react()

    /// Sleepiness bias from time-of-day + fatigue: 0 = fresh, 1 = worn out (slows the tempo).
    var droop: CGFloat = 0

    /// Queue a one-shot reaction; it interrupts whatever's playing.
    func react(_ r: EyeReaction) { pending = EyeAnimator.reactionSteps(r); queuedKind = r }

    /// True while a reaction is queued — callers use this to avoid clobbering it.
    var hasPendingReaction: Bool { pending != nil }

    /// Advance one frame for the given mood. Returns true if the pose moved.
    func tick(mood: Mood) -> Bool {
        let before = pose

        // 1) A queued reaction interrupts everything.
        if let p = pending {
            active = p; pending = nil; step = 0; frame = 0
            fromLook = pose.look; fromBlink = pose.blink; fromConverge = pose.converge
            forced = true; reactionKind = queuedKind
        }

        // Pupil size eases toward the mood baseline, dilated during happy/alert reactions.
        let pupilTarget = forced ? EyeAnimator.reactionPupil(reactionKind) : EyeAnimator.moodPupil(mood)
        pose.pupil = approach(pose.pupil, pupilTarget, 0.18)

        if forced {
            advance()
            if step >= active.count { forced = false; reactionKind = nil; step = active.count }
            return moved(before)
        }

        // 2) Cursor-follow: ease toward the target instead of playing clips.
        if let t = lookTarget {
            pose.converge = approach(pose.converge, 0, 0.3)
            pose.look = CGVector(dx: approach(pose.look.dx, t.dx, 0.3),
                                 dy: approach(pose.look.dy, t.dy, 0.3))
            if followBlink > 0 {
                followBlink -= 1
                pose.blink = followBlink >= 2 ? min(1, pose.blink + 0.5) : approach(pose.blink, 0, 0.5)
            } else {
                pose.blink = approach(pose.blink, 0, 0.5)
                if Int.random(in: 0 ..< 48) == 0 { followBlink = 4 }   // occasional blink
            }
            recentering = true   // glide back to centre when the mouse leaves
            return moved(before)
        }

        // 3) Just left cursor-follow: glide the gaze straight back to centre, so
        //    it doesn't sweep from the cursor into a clip (an "eye roll").
        if recentering {
            pose.converge = approach(pose.converge, 0, 0.4)
            pose.look = CGVector(dx: approach(pose.look.dx, 0, 0.4),
                                 dy: approach(pose.look.dy, 0, 0.4))
            pose.blink = approach(pose.blink, 0, 0.5)
            if abs(pose.look.dx) < 0.02, abs(pose.look.dy) < 0.02 {
                pose.look = .zero; pose.blink = 0; recentering = false; followBlink = 0
                fromLook = .zero; fromBlink = 0; fromConverge = 0
                step = active.count          // resume clips from centre
            }
            return moved(before)
        }

        // 4) Clip-driven: nap, easter egg, or a normal mood clip.
        if step >= active.count { startClip(mood: mood) }
        advance()
        return moved(before)
    }

    private func advance() {
        guard step < active.count else { return }
        let wp = active[step]
        if frame < wp.move {
            let t = smooth(CGFloat(frame + 1) / CGFloat(max(1, wp.move)))
            pose.look = lerp(fromLook, wp.look, t)
            pose.blink = fromBlink + (wp.blink - fromBlink) * t
            pose.converge = fromConverge + (wp.converge - fromConverge) * t
        } else {
            pose.look = wp.look; pose.blink = wp.blink; pose.converge = wp.converge
        }
        frame += 1
        if frame >= wp.move + wp.hold {
            fromLook = wp.look; fromBlink = wp.blink; fromConverge = wp.converge
            step += 1; frame = 0
        }
    }

    private func startClip(mood: Mood) {
        fromLook = pose.look; fromBlink = pose.blink; fromConverge = pose.converge
        step = 0; frame = 0

        if drowsy {
            active = EyeAnimator.napClips.randomElement() ?? EyeAnimator.napClips[0]
            return
        }
        if mood == .chill, Int.random(in: 0 ..< 110) == 0 {     // genuinely rare, and only when calm
            active = EyeAnimator.eggClips.randomElement() ?? []
            return
        }
        let pool = EyeAnimator.clips.indices.filter { EyeAnimator.clips[$0].moods.contains(mood) }
        var idx = pool.randomElement() ?? 0
        if pool.count > 1 { while idx == lastIndex { idx = pool.randomElement()! } }
        lastIndex = idx

        let tempo = EyeAnimator.tempo(mood) * (1 + droop * 0.5)   // sleepier -> slower
        active = EyeAnimator.clips[idx].steps.map {
            WP(look: $0.look, blink: $0.blink, converge: $0.converge,
               move: max(1, Int((CGFloat($0.move) * tempo).rounded())),
               hold: max(1, Int((CGFloat($0.hold) * tempo).rounded())))
        }
    }

    private func moved(_ before: EyePose) -> Bool {
        abs(pose.look.dx - before.look.dx) + abs(pose.look.dy - before.look.dy)
            + abs(pose.blink - before.blink) + abs(pose.converge - before.converge)
            + abs(pose.pupil - before.pupil) > 0.003
    }

    private func approach(_ a: CGFloat, _ b: CGFloat, _ rate: CGFloat) -> CGFloat { a + (b - a) * rate }
    private func smooth(_ t: CGFloat) -> CGFloat { let c = min(1, max(0, t)); return c * c * (3 - 2 * c) }
    private func lerp(_ a: CGVector, _ b: CGVector, _ t: CGFloat) -> CGVector {
        CGVector(dx: a.dx + (b.dx - a.dx) * t, dy: a.dy + (b.dy - a.dy) * t)
    }

    /// Resting pupil size per mood: relaxed round, wide when alert, pinpricks when stressed.
    private static func moodPupil(_ m: Mood) -> CGFloat {
        switch m {
        case .chill:    return 1.00
        case .alert:    return 1.12
        case .pressure: return 0.90
        case .stressed: return 0.72
        }
    }
    /// Pupils dilate for a happy/celebratory reaction, widen for an alert.
    private static func reactionPupil(_ r: EyeReaction?) -> CGFloat {
        switch r {
        case .happy:     return 1.35
        case .celebrate: return 1.42
        case .alert:     return 1.18
        case .wake:      return 1.10
        case .none:      return 1.00
        }
    }

    private static func tempo(_ m: Mood) -> CGFloat {
        switch m {
        case .chill:    return 1.40
        case .alert:    return 0.85
        case .pressure: return 1.00
        case .stressed: return 0.60
        }
    }

    private static let all: Set<Mood> = [.chill, .alert, .pressure, .stressed]
    private static func wp(_ dx: CGFloat, _ dy: CGFloat, blink: CGFloat = 0, m: Int = 6, h: Int = 8) -> WP {
        WP(look: CGVector(dx: dx, dy: dy), blink: blink, move: m, hold: h)
    }

    // Every normal clip begins from centre and ends back at centre.
    private static let clips: [ClipDef] = [
        ClipDef(steps: [wp(0, 0, blink: 1, m: 2, h: 1), wp(0, 0, blink: 0, m: 3, h: 10)], moods: all),
        ClipDef(steps: [wp(0, 0, blink: 1, m: 2, h: 1), wp(0, 0, blink: 0, m: 2, h: 2),
                        wp(0, 0, blink: 1, m: 2, h: 1), wp(0, 0, blink: 0, m: 3, h: 9)], moods: all),
        ClipDef(steps: [wp(-0.9, 0, m: 6, h: 9), wp(0.9, 0, m: 8, h: 9), wp(0, 0, m: 6, h: 8)], moods: all),
        ClipDef(steps: [wp(0, 0.8, m: 6, h: 9), wp(0, 0, m: 6, h: 8)], moods: all),
        ClipDef(steps: [wp(0, -0.7, m: 6, h: 9), wp(0, 0, m: 6, h: 8)], moods: all),
        ClipDef(steps: [wp(0.85, 0.25, m: 3, h: 6), wp(0, 0, m: 4, h: 9)], moods: all),
        ClipDef(steps: [wp(0, 0.8, m: 4, h: 2), wp(0.8, 0.2, m: 4, h: 2), wp(0, -0.7, m: 4, h: 2),
                        wp(-0.8, 0.2, m: 4, h: 2), wp(0, 0, m: 4, h: 6)], moods: all),

        ClipDef(steps: [wp(-0.5, 0.1, m: 12, h: 16), wp(0, 0, m: 12, h: 12)], moods: [.chill]),
        ClipDef(steps: [wp(0, 0, blink: 1, m: 5, h: 4), wp(0, 0, blink: 0, m: 5, h: 14)], moods: [.chill]),
        ClipDef(steps: [wp(0.9, 0.1, m: 2, h: 3), wp(0, 0, m: 2, h: 2), wp(0.9, 0.1, m: 2, h: 4), wp(0, 0, m: 3, h: 7)], moods: [.alert]),
        ClipDef(steps: [wp(0, 0, m: 2, h: 10), wp(-0.8, 0, m: 2, h: 2), wp(0, 0, m: 3, h: 8)], moods: [.alert, .pressure]),
        ClipDef(steps: [wp(0.7, 0, m: 2, h: 2), wp(0, 0, m: 2, h: 14)], moods: [.pressure]),
        ClipDef(steps: [wp(-0.9, 0, m: 2, h: 2), wp(0.9, 0, m: 2, h: 2), wp(-0.9, 0, m: 2, h: 2),
                        wp(0.9, 0, m: 2, h: 2), wp(0, 0, m: 3, h: 4)], moods: [.stressed]),
        ClipDef(steps: [wp(0, 0, blink: 1, m: 1, h: 1), wp(0, 0, blink: 0, m: 1, h: 1),
                        wp(0, 0, blink: 1, m: 1, h: 1), wp(0, 0, blink: 0, m: 1, h: 1),
                        wp(0, 0, blink: 1, m: 1, h: 1), wp(0, 0, blink: 0, m: 2, h: 6)], moods: [.stressed]),
    ]

    // Sleepy idle behaviors. Droopy and slow; they chain among themselves and
    // are exited by a `.wake` reaction.
    private static let napClips: [[WP]] = [
        [WP(look: CGVector(dx: 0, dy: -0.25), blink: 0.60, move: 14, hold: 24),
         WP(look: CGVector(dx: 0, dy: -0.20), blink: 0.55, move: 10, hold: 20)],
        [WP(look: CGVector(dx: 0, dy: -0.20), blink: 0.55, move: 8, hold: 6),
         WP(look: CGVector(dx: 0, dy: -0.25), blink: 0.92, move: 8, hold: 10),
         WP(look: CGVector(dx: 0, dy: -0.20), blink: 0.55, move: 10, hold: 18)],
        [WP(look: CGVector(dx: 0, dy: -0.25), blink: 0.95, move: 12, hold: 32),
         WP(look: CGVector(dx: 0, dy: -0.20), blink: 0.60, move: 10, hold: 14)],
    ]

    // Rare surprises. All resolve back to centre.
    private static let eggClips: [[WP]] = [
        // crossed eyes
        [WP(look: .zero, converge: 0.9, move: 4, hold: 16), WP(look: .zero, converge: 0, move: 4, hold: 6)],
        // dizzy spiral
        [WP(look: CGVector(dx: 0, dy: 0.8), move: 2, hold: 0), WP(look: CGVector(dx: 0.8, dy: 0), move: 2, hold: 0),
         WP(look: CGVector(dx: 0, dy: -0.8), move: 2, hold: 0), WP(look: CGVector(dx: -0.8, dy: 0), move: 2, hold: 0),
         WP(look: CGVector(dx: 0, dy: 0.8), move: 2, hold: 0), WP(look: CGVector(dx: 0.8, dy: 0), move: 2, hold: 0),
         WP(look: CGVector(dx: 0, dy: -0.8), move: 2, hold: 0), WP(look: CGVector(dx: -0.8, dy: 0), move: 2, hold: 0),
         WP(look: .zero, blink: 1, move: 2, hold: 1), WP(look: .zero, blink: 0, move: 3, hold: 6)],
        // suspicious side-eye
        [WP(look: CGVector(dx: 0.85, dy: -0.1), blink: 0.35, move: 5, hold: 20),
         WP(look: CGVector(dx: 0.85, dy: -0.1), blink: 0, move: 3, hold: 4),
         WP(look: .zero, move: 4, hold: 6)],
        // curious peek up
        [WP(look: CGVector(dx: 0, dy: 0.9), move: 3, hold: 10),
         WP(look: CGVector(dx: 0.35, dy: 0.9), move: 3, hold: 6),
         WP(look: .zero, move: 3, hold: 5)],
    ]

    private static func reactionSteps(_ r: EyeReaction) -> [WP] {
        switch r {
        case .happy:        // pleased squint + quick up-glance
            return [WP(look: CGVector(dx: 0, dy: 0.5), blink: 0.5, move: 2, hold: 4),
                    WP(look: CGVector(dx: 0, dy: 0.5), blink: 0, move: 2, hold: 3),
                    WP(look: .zero, blink: 0, move: 3, hold: 6)]
        case .alert:        // snap to look at you + a quick dart
            return [WP(look: CGVector(dx: 0, dy: -0.12), blink: 0, move: 1, hold: 6),
                    WP(look: CGVector(dx: -0.2, dy: -0.08), blink: 0, move: 2, hold: 2),
                    WP(look: CGVector(dx: 0.2, dy: -0.08), blink: 0, move: 2, hold: 2),
                    WP(look: .zero, blink: 0, move: 2, hold: 6)]
        case .celebrate:    // happy wiggle + double blink
            return [WP(look: CGVector(dx: -0.6, dy: 0.3), move: 2, hold: 2),
                    WP(look: CGVector(dx: 0.6, dy: 0.3), move: 3, hold: 2),
                    WP(look: .zero, blink: 1, move: 2, hold: 1),
                    WP(look: .zero, blink: 0, move: 2, hold: 1),
                    WP(look: .zero, blink: 1, move: 2, hold: 1),
                    WP(look: .zero, blink: 0, move: 3, hold: 5)]
        case .wake:         // pop awake + look around
            return [WP(look: CGVector(dx: 0, dy: -0.1), blink: 1, move: 1, hold: 1),
                    WP(look: .zero, blink: 0, move: 2, hold: 2),
                    WP(look: CGVector(dx: -0.5, dy: 0.2), move: 3, hold: 3),
                    WP(look: CGVector(dx: 0.5, dy: 0.1), move: 3, hold: 3),
                    WP(look: .zero, blink: 0, move: 3, hold: 4)]
        }
    }
}
