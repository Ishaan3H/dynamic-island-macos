import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// The island's visual states, smallest to largest.
///
/// There is deliberately no hover state — opening requires an explicit click.
/// `IslandFace` selects *what* an opened island displays; this enum only decides
/// how large it is and why.
enum IslandMode: Equatable {
    /// Idle: a small nub extending the cutout rightward.
    case collapsed
    /// Click-expanded: status header over the full card.
    case expanded
    /// Voice capture, triggered by the global hotkey.
    case listening
    /// A drag is being held over the island.
    case dropTarget
    /// Priority interrupt (incoming call).
    case alert

    var showsStatusHeader: Bool { self == .expanded }
}

/// Physical notch metrics for a display.
///
/// **The notch cannot be drawn into** — there are no pixels behind the camera
/// housing. Everything here exists to place content *below and around* it, in the
/// same black, so the eye reads the result as the notch itself growing. That is
/// the entire trick behind notch-resident apps.
struct NotchMetrics: Equatable {
    let width: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    static func of(_ screen: NSScreen) -> NotchMetrics {
        let inset = screen.safeAreaInsets.top

        if inset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return NotchMetrics(
                width: screen.frame.width - left.width - right.width,
                height: inset,
                hasNotch: true
            )
        }

        // No notch: fall back to the menu bar's height so the same layout maths
        // still works. The island then hangs off the top edge instead of a cutout.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchMetrics(width: 180, height: max(menuBar, 24), hasNotch: false)
    }

    static let fallback = NotchMetrics(width: 180, height: 32, hasNotch: false)
}

enum IslandGeometry {

    // MARK: Idle

    /// Width of the idle nub that sits immediately right of the cutout.
    ///
    /// The island is anchored to the notch's *trailing* edge, not centred on it,
    /// so it fills the empty menu-bar gap between the cutout and the status icons
    /// and reads as the notch simply being wider. Everything here is on real
    /// pixels — unlike the area behind the cutout — so the full height is visible
    /// and no separate "lip" is needed.
    static let idleExtensionWidth: CGFloat = 56

    // MARK: Expanded

    static let expandedWidth: CGFloat = 400
    static let hPadding: CGFloat = 16
    static let bottomPadding: CGFloat = 13

    /// Breathing room so content isn't jammed against the top bezel.
    static let topPadding: CGFloat = 6
    static let headerHeight: CGFloat = 46
    static let tabRowHeight: CGFloat = 30
    static let tabRowTopPadding: CGFloat = 10
    static let tabRowBottomPadding: CGFloat = 8

    static let mediaArtwork: CGFloat = 78
    static let sectionLabelHeight: CGFloat = 16
    static let mirrorHeaderHeight: CGFloat = 24
    static let crumbSlotHeight: CGFloat = 30
    static let sectionSpacing: CGFloat = 6
    static let sectionBottomPadding: CGFloat = 9
    static let stagedListHeight: CGFloat = 100
    static let folderListHeight: CGFloat = 110

    static let voiceContentHeight: CGFloat = 128
    static let dropContentHeight: CGFloat = 168
    static let alertContentHeight: CGFloat = 84

    /// Header + tab row, present on every expanded face.
    static var chromeHeight: CGFloat {
        headerHeight + tabRowTopPadding + tabRowHeight + tabRowBottomPadding
    }

    static var mediaFaceHeight: CGFloat { mediaArtwork }

    static var vaultFaceHeight: CGFloat {
        let staged = sectionLabelHeight + sectionSpacing + stagedListHeight + sectionBottomPadding
        let mirror = sectionBottomPadding + mirrorHeaderHeight + sectionSpacing
            + crumbSlotHeight + sectionSpacing + folderListHeight
        return staged + 1 + mirror
    }

    static func contentHeight(for face: IslandFace) -> CGFloat {
        switch face {
        case .media: return mediaFaceHeight
        case .vault: return vaultFaceHeight
        }
    }

    // MARK: Sizes

    /// Sitting beside the cutout rather than under it means no band has to be
    /// reserved for hidden pixels — every point of these sizes is visible.
    static func size(for mode: IslandMode, face: IslandFace = .media,
                     notch: NotchMetrics = .fallback) -> CGSize {
        switch mode {
        case .collapsed:
            return CGSize(width: idleExtensionWidth, height: notch.height)
        case .expanded:
            return CGSize(width: expandedWidth,
                          height: topPadding + chromeHeight + contentHeight(for: face) + bottomPadding)
        case .listening:
            return CGSize(width: expandedWidth,
                          height: topPadding + voiceContentHeight + bottomPadding)
        case .dropTarget:
            return CGSize(width: expandedWidth,
                          height: topPadding + dropContentHeight + bottomPadding)
        case .alert:
            return CGSize(width: expandedWidth,
                          height: topPadding + alertContentHeight + bottomPadding)
        }
    }

    /// Bottom corner radius. The top corners stay square — they sit at the screen
    /// edge where a radius would only open a gap against the bezel. The idle nub
    /// stays subtle so it doesn't announce itself beside the cutout.
    static func cornerRadius(for mode: IslandMode) -> CGFloat {
        mode == .collapsed ? 10 : 22
    }

    /// Largest state — the panel is permanently this size. See `IslandHostingView`.
    static func canvas(notch: NotchMetrics) -> CGSize {
        let combos: [(IslandMode, IslandFace)] = [
            (.collapsed, .media), (.expanded, .media), (.expanded, .vault),
            (.listening, .media), (.dropTarget, .media), (.alert, .media)
        ]
        let sizes = combos.map { size(for: $0.0, face: $0.1, notch: notch) }
        return CGSize(width: sizes.map(\.width).max() ?? expandedWidth,
                      height: sizes.map(\.height).max() ?? 460)
    }

    /// Left edge of the island: flush against the notch's trailing edge.
    static func leadingEdge(on screen: NSScreen, notch: NotchMetrics) -> CGFloat {
        screen.frame.midX + notch.width / 2
    }

    /// Canvas frame: left edge flush with the notch's right side, top flush with
    /// the screen, so the island grows rightward and downward as an extension of
    /// the cutout. Pulled back if the widest state would run off the display.
    static func canvasFrame(on screen: NSScreen) -> CGRect {
        let notch = NotchMetrics.of(screen)
        let size = canvas(notch: notch)
        let x = min(leadingEdge(on: screen, notch: notch),
                    screen.frame.maxX - size.width)
        return CGRect(
            x: x,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Rect within the canvas that should receive events: pinned to the top-left,
    /// matching the trailing-edge anchor.
    ///
    /// `flipped` matters — `NSHostingView` is flipped (origin top-left) while a
    /// plain `NSView` is not, and getting it backwards puts the hit region at the
    /// opposite end of the canvas from the island.
    static func hitRect(for mode: IslandMode, face: IslandFace, in bounds: CGRect,
                        notch: NotchMetrics, flipped: Bool) -> CGRect {
        let s = size(for: mode, face: face, notch: notch)
        return CGRect(
            x: bounds.minX,
            y: flipped ? bounds.minY : bounds.maxY - s.height,
            width: s.width,
            height: s.height
        )
    }
}
