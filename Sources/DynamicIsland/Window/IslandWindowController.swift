import AppKit
import Combine
import SwiftUI

/// Owns the panel, places it wherever the user has dragged the island, and keeps
/// the hit-test region in sync with the island's current size and anchor.
///
/// Position is stored as the *collapsed pill's* origin — the thing the user sees
/// and grabs — with the canvas frame derived from it. Storing the canvas origin
/// instead would make the saved position meaningless the moment the anchor flips.
final class IslandWindowController {

    private(set) var panel: IslandPanel!
    private var hostingView: IslandHostingView<AnyView>!
    private let model: IslandModel
    private var cancellables = Set<AnyCancellable>()

    /// The panel never resizes; it is permanently the size of the largest state.
    /// See `IslandHostingView` for why.
    static var canvasSize: CGSize { IslandGeometry.canvas }

    /// Mode the hit region currently reflects. Lags `model.mode` while shrinking —
    /// see `apply(mode:)`.
    private var interactiveMode: IslandMode = .collapsed
    private var shrinkWork: DispatchWorkItem?

    /// Collapsed pill's frame origin, AppKit global coordinates.
    private var pillOrigin: CGPoint = .zero
    /// Screen-space mouse position and pill origin at the start of a reposition
    /// drag. See `move(by:finished:)` for why both are needed.
    private var dragStartMouse: CGPoint?
    private var dragStartPill: CGPoint?

    private var currentScreen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(pillOrigin) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    init(model: IslandModel) {
        self.model = model
        buildPanel()
        observeModel()
        observeScreenChanges()
    }

    // MARK: - Construction

    private func buildPanel() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        pillOrigin = Config.shared.pillOrigin ?? IslandGeometry.defaultPillOrigin(on: screen)
        model.anchor = IslandGeometry.anchor(forPillOrigin: pillOrigin, on: screen)
        // A saved position can be off-screen after a display change or an
        // external monitor being unplugged; pull it back into view.
        pillOrigin = IslandGeometry.clampPillOrigin(pillOrigin, anchor: model.anchor, on: screen)
        let frame = IslandGeometry.canvasFrame(pillOrigin: pillOrigin, anchor: model.anchor)

        panel = IslandPanel(contentRect: frame)

        let root = AnyView(
            IslandRootView()
                .environmentObject(model)
                .environmentObject(model.spotify)
                .environmentObject(model.vault)
                .environmentObject(model.mirror)
                .environmentObject(model.deviceActivity)
                .environmentObject(model.calls)
                .environmentObject(model.status)
        )

        hostingView = IslandHostingView(rootView: root)
        hostingView.interactiveRect = { [weak self] in self?.currentPillRect() ?? .zero }
        model.moveHandler = { [weak self] translation, finished in
            self?.move(by: translation, finished: finished)
        }

        panel.contentView = hostingView
        panel.orderFrontRegardless()
        hostingView.refreshInteractiveRegion()
        Log.debug("panel at \(NSStringFromRect(frame)) on screen \(NSStringFromRect(screen.frame))")
    }

    /// The pill is anchored to the top-trailing corner of the canvas.
    ///
    /// Which y that is depends on the view's orientation, and getting it wrong is
    /// invisible until you test it: `NSHostingView` is **flipped** (origin
    /// top-left), unlike a plain `NSView`. Computing `bounds.maxY - height` here —
    /// correct for unflipped AppKit — put the hit region at the *bottom* of the
    /// 486 pt canvas, hundreds of points below the pill, so clicks on the island
    /// missed entirely while an invisible strip underneath it caught them.
    private func currentPillRect() -> CGRect {
        guard let view = hostingView else { return .zero }
        // A few points of slop around the collapsed pill make it easier to hit and
        // give drags somewhere to land before the island opens.
        return IslandGeometry.hitRect(
            for: interactiveMode,
            face: model.face,
            in: view.bounds,
            anchor: model.anchor,
            flipped: view.isFlipped,
            slop: interactiveMode == .collapsed ? 6 : 0
        )
    }

    // MARK: - Repositioning

    /// Moves the island to follow the pointer.
    ///
    /// The offset comes from `NSEvent.mouseLocation` — screen space — and
    /// deliberately **not** from the gesture's own `translation`. SwiftUI measures
    /// translation relative to the view, and this function moves that view; the
    /// two form a feedback loop where each frame's window move cancels part of the
    /// next frame's reported translation, and the island travels at roughly half
    /// the speed of the cursor.
    ///
    /// `translation` is still used once, to recover the true gesture origin: the
    /// first callback only arrives after `minimumDistance`, and at that instant
    /// nothing has moved yet, so it is still accurate.
    private func move(by translation: CGSize, finished: Bool) {
        let mouse = NSEvent.mouseLocation

        if dragStartMouse == nil {
            // AppKit y grows upward, SwiftUI translation grows downward.
            dragStartMouse = CGPoint(x: mouse.x - translation.width, y: mouse.y + translation.height)
            dragStartPill = pillOrigin
        }
        guard let startMouse = dragStartMouse, let startPill = dragStartPill else { return }

        var next = CGPoint(
            x: startPill.x + (mouse.x - startMouse.x),
            y: startPill.y + (mouse.y - startMouse.y)
        )
        let screen = NSScreen.screens.first { $0.frame.contains(next) } ?? currentScreen

        // Only the pill is constrained mid-drag. Clamping the whole canvas here
        // would stop the island well short of the bottom-left corner, because the
        // anchor still points the old way until the gesture ends.
        next = IslandGeometry.clampPill(next, to: screen)
        pillOrigin = next
        panel.setFrameOrigin(
            IslandGeometry.canvasFrame(pillOrigin: next, anchor: model.anchor).origin)

        guard finished else { return }
        dragStartMouse = nil
        dragStartPill = nil
        settlePosition()
        Config.shared.savePillOrigin(pillOrigin)
        Log.debug("island moved to \(NSStringFromPoint(pillOrigin)) anchor=\(model.anchor)")
    }

    /// Re-picks the growth corner and pulls the canvas fully on screen.
    ///
    /// Re-anchoring moves nothing visible while collapsed — the pill's own frame
    /// is the invariant, and only the invisible canvas shifts around it. While
    /// expanded it *would* jump the open card across the pill, so the flip is
    /// deferred until the island next closes.
    private func settlePosition() {
        let screen = currentScreen

        if model.mode == .collapsed {
            let next = IslandGeometry.anchor(forPillOrigin: pillOrigin, on: screen)
            if next != model.anchor { model.anchor = next }
        }

        pillOrigin = IslandGeometry.clampPillOrigin(pillOrigin, anchor: model.anchor, on: screen)
        panel.setFrame(
            IslandGeometry.canvasFrame(pillOrigin: pillOrigin, anchor: model.anchor), display: true)
        hostingView.refreshInteractiveRegion()
    }

    /// Returns the island to the default top-right corner.
    func resetPosition() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        pillOrigin = IslandGeometry.defaultPillOrigin(on: screen)
        model.anchor = IslandGeometry.anchor(forPillOrigin: pillOrigin, on: screen)
        Config.shared.savePillOrigin(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                IslandGeometry.canvasFrame(pillOrigin: pillOrigin, anchor: model.anchor),
                display: true)
        } completionHandler: { [weak self] in
            self?.hostingView.refreshInteractiveRegion()
        }
    }

    // MARK: - Observation

    private func observeModel() {
        model.$mode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.apply(mode: mode)
                // An anchor flip deferred during expansion lands here.
                if mode == .collapsed { self?.settlePosition() }
            }
            .store(in: &cancellables)

        // Switching face resizes the expanded island, so the hit region has to
        // follow even though the mode is unchanged.
        model.$face
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.apply(mode: self.model.mode, force: true)
            }
            .store(in: &cancellables)
    }

    /// Grow the hit region immediately, shrink it only once the spring has settled.
    ///
    /// If it shrank on the leading edge, the pointer would fall outside the
    /// tracking area while the pill was still visually large underneath it — which
    /// reads as the island collapsing out from under the cursor.
    private func apply(mode: IslandMode, force: Bool = false) {
        shrinkWork?.cancel()

        let current = IslandGeometry.size(for: interactiveMode, face: model.face)
        let next = IslandGeometry.size(for: mode, face: model.face)
        let isGrowing = next.width * next.height >= current.width * current.height

        if isGrowing || force {
            interactiveMode = mode
            hostingView.refreshInteractiveRegion()
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.interactiveMode = mode
                self?.hostingView.refreshInteractiveRegion()
            }
            shrinkWork = work
            // Slightly longer than the collapse spring's settling time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: work)
        }
    }

    private func observeScreenChanges() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
    }

    /// Re-applies the current position after a display change, pulling the island
    /// back on screen if the arrangement shrank underneath it.
    func reposition() {
        settlePosition()
    }
}
