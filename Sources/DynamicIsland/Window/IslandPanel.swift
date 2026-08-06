import AppKit
import SwiftUI

/// Borderless, non-activating, always-on-top panel that hosts the island.
///
/// `.nonactivatingPanel` is what lets the user click transport controls or type a
/// folder name without the frontmost app losing focus. `canBecomeKey` is still
/// `true` so the text field can take keystrokes when it genuinely needs them;
/// `becomesKeyOnlyIfNeeded` keeps that from happening on incidental clicks.
final class IslandPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        // Transparency: the panel is a clear canvas; the pill is drawn by SwiftUI.
        isOpaque = false
        backgroundColor = .clear

        // AppKit's window shadow is derived from the content's alpha channel and
        // is recomputed whenever that changes — i.e. on every animation frame of a
        // resizing pill. The island draws its own path-based shadow instead.
        hasShadow = false

        // Above the menu bar, visible on every Space, and present over full-screen apps.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // We drive every transition ourselves.
        animationBehavior = .none
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

/// Hosting view providing hit-test passthrough, which AppKit will not do for a
/// transparent overlay.
///
/// The panel is permanently sized to the largest island state so the pill can
/// animate without resizing the window (window resizes fight SwiftUI's animation
/// and cancel in-flight drags). Everything outside the currently drawn pill must
/// therefore be click-through, or we'd blanket a 384×486 dead zone over the
/// corner of the user's screen.
///
/// There is deliberately **no tracking area**. The island opens on click only, so
/// there is no hover state to observe — and without one, the app receives no
/// mouse-moved traffic at all while it sits idle.
final class IslandHostingView<Content: View>: NSHostingView<Content> {

    /// Rect, in this view's coordinates, that should receive events.
    var interactiveRect: () -> CGRect = { .zero }

    private var cachedRect: CGRect = .zero

    required init(rootView: Content) {
        super.init(rootView: rootView)

        // Explicit layer backing with a redraw policy that does not invalidate on
        // bounds changes — the pill's size animates constantly, and re-rasterising
        // the canvas each frame is exactly what we're avoiding.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.needsDisplayOnBoundsChange = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinate space; `cachedRect` is in
        // this view's, which is flipped. See `currentPillRect()`.
        let local = convert(point, from: superview)
        guard cachedRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// Essential, not incidental. By default AppKit swallows the first click into
    /// a non-key window to bring it forward, delivering nothing to the view. This
    /// panel never activates the app, so *every* click is a first click — without
    /// this the island could never be opened at all.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Called when the island changes size so the hit region follows it.
    func refreshInteractiveRegion() {
        cachedRect = interactiveRect()
    }

    override func layout() {
        super.layout()
        // Keeps the hit region correct if the canvas bounds change for any reason
        // the controller didn't drive (display reconfiguration, mainly). Reads the
        // controller's *lagged* mode, so this can't defeat the shrink delay.
        refreshInteractiveRegion()
    }
}
