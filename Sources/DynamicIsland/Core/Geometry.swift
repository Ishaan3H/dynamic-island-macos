import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// Which corner of the island stays put as it grows.
///
/// The island used to be permanently top-right, so the pill's top-right corner
/// was the fixed point and everything grew down-left. Once it can live anywhere,
/// that stops working: an island near the left edge must grow *right* or its
/// expanded form runs off the screen. The anchor follows the island's position —
/// nearest corner wins — so it always opens into the screen, never off it.
struct IslandAnchor: Equatable {
    enum Horizontal { case leading, trailing }
    enum Vertical { case top, bottom }

    var horizontal: Horizontal = .trailing
    var vertical: Vertical = .top

    var alignment: Alignment {
        switch (vertical, horizontal) {
        case (.top, .trailing):    return .topTrailing
        case (.top, .leading):     return .topLeading
        case (.bottom, .trailing): return .bottomTrailing
        case (.bottom, .leading):  return .bottomLeading
        }
    }
}

/// The island's visual states, smallest to largest.
///
/// There is deliberately no hover state. Merely moving the pointer near the
/// island never changes what it shows — opening it requires an explicit click.
/// `IslandFace` selects *what* the opened island displays; this enum is only
/// concerned with how large it is and why.
enum IslandMode: Equatable {
    /// Idle pill.
    case collapsed
    /// Click-expanded: status header over the full card.
    case expanded
    /// Transient enlarged drop zone while a drag is held over the island.
    case dropTarget
    /// Priority interrupt (incoming call).
    case alert

    var showsStatusHeader: Bool { self == .expanded }
}

enum IslandGeometry {
    /// Distance from the right edge of the display. The island is deliberately
    /// off-center: anchored to the right boundary, not the notch.
    static let rightInset: CGFloat = 14
    /// Distance below the top of the visible frame (i.e. under the menu bar).
    static let topInset: CGFloat = 6

    /// Internal padding for the collapsed pill. Sized so the content sits on a
    /// consistent optical margin rather than crowding the rounded ends — the
    /// horizontal inset clears the corner arc at r = height/2.
    static let collapsedHPadding: CGFloat = 16
    static let expandedHPadding: CGFloat = 16
    static let expandedVPadding: CGFloat = 13

    static let expandedWidth: CGFloat = 384

    // MARK: Expanded layout
    //
    // The expanded island is sized to its content, per face — a media card has no
    // business reserving room for a folder tree it isn't showing. These constants
    // are the single source for both the view layout and the height arithmetic
    // below, so the two cannot drift out of sync: change one and the window
    // follows.

    static let headerHeight: CGFloat = 46
    static let tabRowHeight: CGFloat = 30          // tallest control in the row
    static let tabRowTopPadding: CGFloat = 10
    static let tabRowBottomPadding: CGFloat = 8

    static let mediaArtwork: CGFloat = 78
    static let sectionLabelHeight: CGFloat = 16
    static let mirrorHeaderHeight: CGFloat = 24    // contains a 22 pt icon button
    /// Fixed slot holding either the destination crumb or the new-folder field.
    /// One slot for both keeps the island's height stable while naming a folder.
    static let crumbSlotHeight: CGFloat = 30
    static let sectionSpacing: CGFloat = 6
    static let sectionBottomPadding: CGFloat = 9
    static let stagedListHeight: CGFloat = 100
    static let folderListHeight: CGFloat = 110

    /// Header + tab row: present on every expanded face.
    static var chromeHeight: CGFloat {
        headerHeight + tabRowTopPadding + tabRowHeight + tabRowBottomPadding
    }

    /// `MediaCard` is exactly as tall as its artwork.
    static var mediaFaceHeight: CGFloat { mediaArtwork }

    static var vaultFaceHeight: CGFloat {
        let staged = sectionLabelHeight + sectionSpacing + stagedListHeight + sectionBottomPadding
        let mirror = sectionBottomPadding + mirrorHeaderHeight + sectionSpacing
            + crumbSlotHeight + sectionSpacing + folderListHeight
        return staged + 1 + mirror        // +1 for the divider
    }

    static func contentHeight(for face: IslandFace) -> CGFloat {
        switch face {
        case .media: return mediaFaceHeight
        case .vault: return vaultFaceHeight
        }
    }

    static func size(for mode: IslandMode, face: IslandFace = .media) -> CGSize {
        switch mode {
        // Broader and taller than a bare text row needs: at 44pt the transport
        // glyphs and the 26pt artwork thumbnail both sit on real margins.
        case .collapsed:
            return CGSize(width: 260, height: 44)
        case .expanded:
            return CGSize(
                width: expandedWidth,
                height: chromeHeight + contentHeight(for: face) + expandedVPadding
            )
        case .dropTarget:
            return CGSize(width: expandedWidth, height: 200)
        case .alert:
            return CGSize(width: expandedWidth, height: 96)
        }
    }

    static func cornerRadius(for mode: IslandMode) -> CGFloat {
        switch mode {
        case .collapsed:  return 22   // exactly half the height → true pill
        case .alert:      return 26
        case .dropTarget: return 28
        default:          return 30
        }
    }

    /// Largest state — the panel is permanently this size. See `IslandHostingView`.
    static var canvas: CGSize {
        let combos: [(IslandMode, IslandFace)] = [
            (.collapsed, .media), (.expanded, .media), (.expanded, .vault),
            (.dropTarget, .media), (.alert, .media)
        ]
        let sizes = combos.map { size(for: $0.0, face: $0.1) }
        return CGSize(
            width: sizes.map(\.width).max() ?? expandedWidth,
            height: sizes.map(\.height).max() ?? 420
        )
    }

    // MARK: - Placement
    //
    // Positions are expressed as the *collapsed pill's* frame origin in AppKit
    // global coordinates (bottom-left origin). The pill is what the user sees and
    // grabs; the canvas is derived from it. Storing the canvas origin instead
    // would make the saved position meaningless the moment the anchor flips.

    /// Where the island sits by default: tucked into the top-right corner.
    static func defaultPillOrigin(on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let pill = size(for: .collapsed)
        return CGPoint(
            x: visible.maxX - rightInset - pill.width,
            y: visible.maxY - topInset - pill.height
        )
    }

    /// Nearest-corner anchor for a given pill position.
    static func anchor(forPillOrigin origin: CGPoint, on screen: NSScreen) -> IslandAnchor {
        let visible = screen.visibleFrame
        let pill = size(for: .collapsed)
        return IslandAnchor(
            horizontal: (origin.x + pill.width / 2) > visible.midX ? .trailing : .leading,
            vertical: (origin.y + pill.height / 2) > visible.midY ? .top : .bottom
        )
    }

    /// The (fixed-size) canvas frame that puts the pill exactly at `pillOrigin`.
    static func canvasFrame(pillOrigin: CGPoint, anchor: IslandAnchor) -> CGRect {
        let pill = size(for: .collapsed)
        let c = canvas
        return CGRect(
            x: anchor.horizontal == .trailing ? pillOrigin.x + pill.width - c.width : pillOrigin.x,
            y: anchor.vertical == .top ? pillOrigin.y + pill.height - c.height : pillOrigin.y,
            width: c.width,
            height: c.height
        )
    }

    /// Keeps just the pill on screen. Used *during* a drag: the canvas is
    /// invisible while the island is closed, so letting it hang off the edge
    /// mid-gesture is free — and it avoids having to flip the anchor while the
    /// user is still dragging, which would jump the pill as alignment changed.
    static func clampPill(_ origin: CGPoint, to screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let pill = size(for: .collapsed)
        return CGPoint(
            x: min(max(origin.x, visible.minX), visible.maxX - pill.width),
            y: min(max(origin.y, visible.minY), visible.maxY - pill.height)
        )
    }

    /// Nudges the pill so the whole canvas — i.e. the largest expanded state —
    /// stays on screen. Because the anchor already points into the screen, this
    /// still lets the pill sit flush against any edge.
    static func clampPillOrigin(_ origin: CGPoint, anchor: IslandAnchor, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let frame = canvasFrame(pillOrigin: origin, anchor: anchor)
        var dx: CGFloat = 0
        var dy: CGFloat = 0

        if frame.minX < visible.minX { dx = visible.minX - frame.minX }
        if frame.maxX > visible.maxX { dx = visible.maxX - frame.maxX }
        if frame.minY < visible.minY { dy = visible.minY - frame.minY }
        if frame.maxY > visible.maxY { dy = visible.maxY - frame.maxY }

        return CGPoint(x: origin.x + dx, y: origin.y + dy)
    }

    /// Rect within the canvas that should receive events, for the current state.
    ///
    /// `flipped` matters: `NSHostingView` is flipped (origin top-left) while a
    /// plain `NSView` is not, and getting it backwards puts the hit region at the
    /// opposite end of the canvas from the pill.
    static func hitRect(
        for mode: IslandMode,
        face: IslandFace,
        in bounds: CGRect,
        anchor: IslandAnchor,
        flipped: Bool,
        slop: CGFloat
    ) -> CGRect {
        let s = size(for: mode, face: face)
        let x = anchor.horizontal == .trailing ? bounds.maxX - s.width : bounds.minX
        let atTop = anchor.vertical == .top
        let y = (atTop == flipped) ? bounds.minY : bounds.maxY - s.height

        return CGRect(
            x: x - slop,
            y: y - slop,
            width: s.width + slop * 2,
            height: s.height + slop * 2
        )
    }
}
