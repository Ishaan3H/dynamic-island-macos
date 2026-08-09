import AppKit
import Combine
import SwiftUI

/// Owns the panel, parks it over the notch, and keeps the hit-test region in sync
/// with the island's current size.
///
/// The island is permanently centred on the notch — there is no drag-to-reposition
/// and no anchor to flip, which removed a good deal of machinery. The canvas is
/// horizontally centred on `screen.frame.midX` and flush with the top of the
/// screen, so the island appears to descend out of the cutout.
final class IslandWindowController {

    private(set) var panel: IslandPanel!
    private var hostingView: IslandHostingView<AnyView>!
    private let model: IslandModel
    private var cancellables = Set<AnyCancellable>()

    /// Mode the hit region currently reflects. Lags `model.mode` while shrinking —
    /// see `apply(mode:)`.
    private var interactiveMode: IslandMode = .collapsed
    private var shrinkWork: DispatchWorkItem?

    private var screen: NSScreen {
        NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
    }

    init(model: IslandModel) {
        self.model = model
        buildPanel()
        observeModel()
        observeScreenChanges()
    }

    // MARK: - Construction

    private func buildPanel() {
        let screen = self.screen
        let notch = NotchMetrics.of(screen)
        model.notch = notch

        let frame = IslandGeometry.canvasFrame(on: screen)
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
                .environmentObject(model.voice)
        )

        hostingView = IslandHostingView(rootView: root)
        hostingView.interactiveRect = { [weak self] in self?.currentIslandRect() ?? .zero }

        panel.contentView = hostingView
        panel.orderFrontRegardless()
        hostingView.refreshInteractiveRegion()

        Log.debug("""
        panel at \(NSStringFromRect(frame)) — notch \(notch.hasNotch ? "present" : "absent") \
        \(notch.width)x\(notch.height)pt on screen \(NSStringFromRect(screen.frame))
        """)
    }

    /// The island is centred horizontally and pinned to the top of the canvas.
    ///
    /// `isFlipped` matters: `NSHostingView` is flipped (origin top-left), unlike a
    /// plain `NSView`. Getting it backwards puts the hit region at the bottom of
    /// the canvas — which once made the island completely unclickable while an
    /// invisible strip below it swallowed every hit.
    private func currentIslandRect() -> CGRect {
        guard let view = hostingView else { return .zero }
        return IslandGeometry.hitRect(
            for: interactiveMode,
            face: model.face,
            in: view.bounds,
            notch: model.notch,
            flipped: view.isFlipped
        )
    }

    // MARK: - Observation

    private func observeModel() {
        model.$mode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in self?.apply(mode: mode) }
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
    private func apply(mode: IslandMode, force: Bool = false) {
        shrinkWork?.cancel()

        let current = IslandGeometry.size(for: interactiveMode, face: model.face, notch: model.notch)
        let next = IslandGeometry.size(for: mode, face: model.face, notch: model.notch)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: work)
        }
    }

    private func observeScreenChanges() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
    }

    /// Re-derives notch metrics and reparks the panel. Docking to an external
    /// display changes both the notch (there may not be one) and the centre line.
    func reposition() {
        let screen = self.screen
        model.notch = NotchMetrics.of(screen)
        panel.setFrame(IslandGeometry.canvasFrame(on: screen), display: true)
        hostingView.refreshInteractiveRegion()
        Log.debug("repositioned onto \(screen.localizedName), notch \(model.notch.width)x\(model.notch.height)")
    }
}
