import SwiftUI

enum Theme {
    /// Near-black, faintly translucent — the real island reads as a hole punched
    /// in the display, so the shell stays dark regardless of system appearance.
    static let shell = Color(nsColor: NSColor(calibratedWhite: 0.045, alpha: 0.97))
    static let hairline = Color.white.opacity(0.085)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.34)
    static let fill = Color.white.opacity(0.08)
    static let fillStrong = Color.white.opacity(0.14)
    static let accent = Color(red: 0.13, green: 0.83, blue: 0.44)
    static let alert = Color(red: 1.0, green: 0.31, blue: 0.29)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let recording = Color(red: 1.0, green: 0.23, blue: 0.19)
}

/// Small circular glyph button used throughout the island.
struct IslandIconButton: View {
    let systemName: String
    var size: CGFloat = 13
    var diameter: CGFloat = 28
    var tint: Color = Theme.primary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(hovering ? Theme.fillStrong : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Three-bar level meter shown while audio is playing.
struct EqualizerBars: View {
    var color: Color = Theme.accent
    var isAnimating: Bool

    @State private var phase = false

    private let heights: [CGFloat] = [7, 12, 9]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: height)
                    .scaleEffect(y: phase ? 0.45 : 1.0, anchor: .center)
                    .animation(
                        isAnimating
                            ? .easeInOut(duration: 0.42 + Double(index) * 0.11)
                                .repeatForever(autoreverses: true)
                            : .default,
                        value: phase
                    )
            }
        }
        .frame(height: 14)
        .opacity(isAnimating ? 1 : 0.35)
        .onAppear { phase = isAnimating }
        .onChange(of: isAnimating) { _, newValue in phase = newValue }
    }
}

/// Thin progress line with a draggable-looking cap.
struct ProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule()
                    .fill(Theme.primary.opacity(0.85))
                    .frame(width: max(2, geo.size.width * progress))
            }
        }
        .frame(height: 3)
    }
}

extension TimeInterval {
    var clockString: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
