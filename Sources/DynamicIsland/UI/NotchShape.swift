import SwiftUI

/// The island's outline: square at the top, rounded along the bottom.
///
/// A uniformly rounded rectangle is wrong here. The top edge sits flush against
/// the top of the screen behind the camera cutout, so rounding it would round
/// nothing visible while opening a hairline gap where the shape meets the bezel.
/// Only the bottom corners are ever seen.
struct NotchShape: Shape {
    var bottomRadius: CGFloat

    /// Lets the radius animate alongside a size change instead of snapping.
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, min(rect.width, rect.height) / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

/// Small concave wedges that blend the island's shoulders into the cutout, so the
/// join reads as one continuous piece of hardware rather than a panel stuck under
/// the notch. Purely cosmetic; drawn only when the island is wider than the notch.
struct NotchShoulders: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var radius: CGFloat = 9

    var body: some View {
        HStack(spacing: notchWidth) {
            wedge(mirrored: false)
            wedge(mirrored: true)
        }
        .frame(height: notchHeight, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private func wedge(mirrored: Bool) -> some View {
        ConcaveCorner()
            .fill(Theme.shell)
            .frame(width: radius, height: radius)
            .scaleEffect(x: mirrored ? -1 : 1, y: 1, anchor: .center)
            .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

/// A square with one corner scooped out by a quarter circle.
private struct ConcaveCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
