import SwiftUI

/// A small owl that perches on the media card.
///
/// Deliberately drawn from primitives rather than shipped as an asset: it stays
/// crisp at any scale, adds nothing to the bundle, and can react to state — the
/// eyes and posture are bound to playback rather than being a fixed animation.
///
/// It is only ever built inside `MediaCard`, which only exists on the expanded
/// island's media face, so it is invisible until you open the notch and land on
/// the Spotify page.
struct OwlView: View {
    var isPlaying: Bool
    var side: CGFloat = 46

    @State private var blinking = false
    @State private var bobbing = false
    @State private var swaying = false

    // Flourish: a hop with a couple of wingbeats, every 6–7 seconds.
    @State private var hop: CGFloat = 0
    @State private var crouching = false
    @State private var wingSpread: Double = 0
    @State private var eyesWide = false

    /// Awake and bobbing to the music, or asleep with eyes shut.
    private var isAwake: Bool { isPlaying }

    var body: some View {
        ZStack {
            tufts
            body_
            wings
            face
            feet
        }
        .frame(width: side, height: side)
        // Squash on the crouch, stretch slightly at the top of the hop — the
        // anticipation is what stops it reading as a sprite being teleported.
        .scaleEffect(x: crouching ? 1.08 : 1, y: crouching ? 0.88 : 1, anchor: .bottom)
        .offset(y: (bobbing ? -2.5 : 1.5) + hop)
        .rotationEffect(.degrees(swaying ? 3.5 : -3.5), anchor: .bottom)
        .onAppear { startAmbient() }
        .onChange(of: isPlaying) { _, _ in startAmbient() }
        // `.task` is cancelled automatically when the view goes away, so these
        // loops stop the moment the island collapses. A detached timer would keep
        // firing against a dead view and stack a fresh loop on every reappearance.
        .task(id: isPlaying) { await blinkLoop() }
        .task { await flourishLoop() }
    }

    // MARK: Parts

    private var body_: some View {
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [Self.plumageLight, Self.plumage],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(width: side * 0.78, height: side * 0.82)
            .offset(y: side * 0.06)
    }

    /// Ear tufts, angled outward so the silhouette reads as an owl immediately.
    private var tufts: some View {
        HStack(spacing: side * 0.30) {
            tuft.rotationEffect(.degrees(-18))
            tuft.rotationEffect(.degrees(18))
        }
        .offset(y: -side * 0.34)
    }

    private var tuft: some View {
        Triangle()
            .fill(Self.plumage)
            .frame(width: side * 0.20, height: side * 0.26)
    }

    private var wings: some View {
        // Idle tilt from the bob, plus up to 58° of spread during a wingbeat.
        let beat = wingSpread * 58
        return HStack {
            wing.rotationEffect(.degrees((bobbing ? -6 : 0) - beat), anchor: .top)
            Spacer(minLength: 0)
            wing.scaleEffect(x: -1)
                .rotationEffect(.degrees((bobbing ? 6 : 0) + beat), anchor: .top)
        }
        .frame(width: side * 0.80)
        .offset(y: side * 0.10 - CGFloat(wingSpread) * side * 0.06)
    }

    private var wing: some View {
        Ellipse()
            .fill(Self.plumageDark)
            .frame(width: side * 0.22, height: side * 0.46)
    }

    private var face: some View {
        VStack(spacing: side * 0.02) {
            HStack(spacing: side * 0.06) {
                eye
                eye
            }
            beak
        }
        .offset(y: -side * 0.04)
    }

    private var eye: some View {
        ZStack {
            Circle()
                .fill(Self.face)
                .frame(width: side * 0.30, height: side * 0.30)
                .scaleEffect(eyesWide ? 1.22 : 1)

            // Closed eyes are drawn as a squashed pupil rather than a separate
            // shape, so blinking and sleeping are the same transform.
            Capsule()
                .fill(Self.pupil)
                .frame(width: side * 0.15, height: side * 0.15)
                // `eyesWide` wins over sleeping: the flourish is the owl stirring,
                // so it snaps its eyes open even when paused.
                .scaleEffect(y: (!eyesWide && (blinking || !isAwake)) ? 0.12 : 1, anchor: .center)
                .scaleEffect(eyesWide ? 1.25 : 1)
                .overlay(
                    Circle()
                        .fill(.white.opacity(0.9))
                        .frame(width: side * 0.045, height: side * 0.045)
                        .offset(x: side * 0.035, y: -side * 0.035)
                        .opacity((!eyesWide && (blinking || !isAwake)) ? 0 : 1)
                )
        }
    }

    private var beak: some View {
        Triangle()
            .rotation(.degrees(180))
            .fill(Self.beak)
            .frame(width: side * 0.13, height: side * 0.11)
    }

    private var feet: some View {
        HStack(spacing: side * 0.16) {
            foot
            foot
        }
        .offset(y: side * 0.44)
    }

    private var foot: some View {
        Capsule()
            .fill(Self.beak)
            .frame(width: side * 0.09, height: side * 0.06)
    }

    // MARK: Animation

    /// Continuous background motion. A completely static owl looks like a bug.
    private func startAmbient() {
        withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
            swaying = true
        }
        if isAwake {
            withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) {
                bobbing = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { bobbing = false }
        }
    }

    /// Blinks at an irregular interval — a metronomic blink reads as mechanical.
    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.2...5.0)))
            guard !Task.isCancelled, isAwake else { continue }
            withAnimation(.easeInOut(duration: 0.09)) { blinking = true }
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeInOut(duration: 0.11)) { blinking = false }
        }
    }

    /// The flourish: crouch, hop, two wingbeats, land — roughly every 6–7s.
    ///
    /// Runs whether or not music is playing. Asleep, it reads as the owl briefly
    /// stirring, which is more characterful than freezing until playback starts.
    private func flourishLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 6.0...7.0)))
            guard !Task.isCancelled else { return }
            await flourish()
        }
    }

    private func flourish() async {
        // 1. Anticipation — dip and snap the eyes open.
        withAnimation(.easeOut(duration: 0.10)) {
            crouching = true
            eyesWide = true
        }
        try? await Task.sleep(for: .milliseconds(100))

        // 2. Leap, wings thrown out.
        withAnimation(.spring(response: 0.24, dampingFraction: 0.52)) {
            crouching = false
            hop = -side * 0.20
            wingSpread = 1
        }
        try? await Task.sleep(for: .milliseconds(200))

        // 3–4. Two beats. Down hard, up again.
        withAnimation(.easeInOut(duration: 0.11)) { wingSpread = 0.12 }
        try? await Task.sleep(for: .milliseconds(115))
        withAnimation(.easeInOut(duration: 0.11)) { wingSpread = 0.85 }
        try? await Task.sleep(for: .milliseconds(125))

        // 5. Land, wings folded, with a little settle.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
            hop = 0
            wingSpread = 0
        }
        try? await Task.sleep(for: .milliseconds(260))

        // 6. Back to whatever the eyes were doing before.
        withAnimation(.easeOut(duration: 0.20)) { eyesWide = false }
    }

    // MARK: Palette — warm tones, legible against the island's pure black.

    private static let plumageLight = Color(red: 0.72, green: 0.53, blue: 0.33)
    private static let plumage      = Color(red: 0.55, green: 0.38, blue: 0.22)
    private static let plumageDark  = Color(red: 0.41, green: 0.28, blue: 0.16)
    private static let face         = Color(red: 0.94, green: 0.88, blue: 0.78)
    private static let pupil        = Color(red: 0.10, green: 0.08, blue: 0.07)
    private static let beak         = Color(red: 0.95, green: 0.70, blue: 0.25)
}

/// Simple upward triangle, used for the ear tufts and beak.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
