import SwiftUI

/// Animation physics for the island.
///
/// Every curve here is a damped harmonic oscillator: `mẍ + cẋ + kx = 0`. SwiftUI
/// parameterises it as `response` and `dampingFraction` rather than `k` and `c`,
/// which is the more useful pair for tuning:
///
///   response  = 2π / ω₀        (natural period, seconds — "how fast")
///   ω₀        = √(k/m)          (natural frequency, rad/s)
///   ζ         = c / (2√(km))    (damping fraction — "how bouncy")
///
/// ζ < 1 is underdamped and overshoots; ζ = 1 is critically damped and settles in
/// the shortest time without overshoot; ζ > 1 crawls in. Peak overshoot for a step
/// input is `exp(-πζ / √(1-ζ²))`, which is what the per-curve comments below cite.
///
/// The asymmetry is the point. iOS's Dynamic Island opens with a visible overshoot
/// — it reads as the panel having mass — and closes almost without one, because a
/// wobble on the way out looks like a bug rather than physicality.
enum IslandSpring {

    /// Opening. ω₀ ≈ 15.0 rad/s, ζ = 0.68 → ~5.4% overshoot, one soft bounce.
    static let expand = Animation.spring(response: 0.42, dampingFraction: 0.68)

    /// Closing. ω₀ ≈ 20.9 rad/s, ζ = 0.90 → ~0.2% overshoot, visually none.
    /// Faster than the open so dismissal feels immediate.
    static let collapse = Animation.spring(response: 0.30, dampingFraction: 0.90)

    /// Moving between two already-open states (media ⇄ vault). ζ = 0.80 → ~1.5%.
    static let morph = Animation.spring(response: 0.36, dampingFraction: 0.80)

    /// Priority interrupts snap in harder — they need to grab attention.
    static let alert = Animation.spring(response: 0.34, dampingFraction: 0.62)

    /// Content crossfade. Deliberately shorter than the shape change and eased,
    /// not sprung: text that overshoots its own frame looks like a glitch. The
    /// shape settles first, the content lands into it.
    static let content = Animation.easeOut(duration: 0.20)

    /// Picks the curve for a given transition. Centralised so the physics can be
    /// reasoned about in one place instead of being guessed at each call site.
    static func transition(from old: IslandMode, to new: IslandMode) -> Animation {
        if new == .alert { return alert }

        let oldArea = IslandGeometry.size(for: old).area
        let newArea = IslandGeometry.size(for: new).area

        if old == .collapsed && new != .collapsed { return expand }
        if new == .collapsed { return collapse }
        return newArea > oldArea ? expand : morph
    }
}

private extension CGSize {
    var area: CGFloat { width * height }
}

extension AnyTransition {
    /// Content swap: fade + a small scale from the top edge, so inner content
    /// appears to grow out of the pill rather than cross-dissolve in place.
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
            removal: .opacity
        )
    }
}
