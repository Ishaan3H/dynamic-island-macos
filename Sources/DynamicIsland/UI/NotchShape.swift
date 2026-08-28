import SwiftUI

/// The island's outline, shaped to continue the notch rather than sit beside it.
///
/// Three things have to be true for the join to disappear:
///
/// 1. **The top edge is square.** It sits flush against the top bezel, where a
///    radius would only open a lit gap.
/// 2. **The leading edge is square and tucked *under* the cutout.** The notch's
///    own bottom-right corner is rounded; a square edge meeting it at exactly the
///    cutout boundary leaves a visible step. Overlapping into the cutout — where
///    there are no pixels to disturb — covers that corner so the two shapes read
///    as one.
/// 3. **The bottom corners match the notch's radius.** The cutout's lower corners
///    are rounded, so a hard 90° corner on the island announces itself instantly.
struct NotchShape: Shape {
    var bottomLeading: CGFloat
    var bottomTrailing: CGFloat

    init(bottomLeading: CGFloat, bottomTrailing: CGFloat) {
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
    }

    /// Both radii animate together as the island resizes.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomLeading, bottomTrailing) }
        set {
            bottomLeading = newValue.first
            bottomTrailing = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let maxR = min(rect.width, rect.height) / 2
        let bl = min(max(bottomLeading, 0), maxR)
        let br = min(max(bottomTrailing, 0), maxR)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        // Down the trailing edge into the bottom-right corner.
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - br, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
        }

        // Across the bottom into the bottom-left corner.
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - bl),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
        }

        path.closeSubpath()
        return path
    }
}
