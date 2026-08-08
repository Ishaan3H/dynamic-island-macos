import SwiftUI
import UniformTypeIdentifiers

/// The island shell. Sizes itself from `IslandGeometry`, anchors to the
/// top-trailing corner of the (fixed-size) panel canvas, and swaps its contents
/// based on `model.mode`.
///
/// **Rendering strategy.** Two things keep this cheap to animate:
///
/// 1. The panel never resizes — see `IslandHostingView`. SwiftUI owns the whole
///    transition, with no competing AppKit window-frame animation and no risk of
///    cancelling an in-flight drag by resizing out from under the cursor.
/// 2. The drop shadow is cast by a bare `RoundedRectangle` *behind* the content,
///    not by the content itself. Shadowing a composited subtree forces SwiftUI to
///    rasterise it every frame to derive the blur's alpha mask; shadowing a plain
///    filled shape lets Core Animation use a `shadowPath` and stay on the GPU.
///
/// This view reads only `model.mode`, so service updates never invalidate the
/// shell — they invalidate the leaf that displays them.
struct IslandRootView: View {

    @EnvironmentObject private var model: IslandModel

    private static let acceptedTypes: [UTType] = [
        .fileURL, .image, .png, .tiff, .pdf, .plainText, .utf8PlainText, .url, .text
    ]

    var body: some View {
        let mode = model.mode
        // Size depends on the face too: the expanded island fits its content, so
        // the media card doesn't reserve room for a folder tree it isn't showing.
        let size = IslandGeometry.size(for: mode, face: model.face)
        let shape = RoundedRectangle(
            cornerRadius: IslandGeometry.cornerRadius(for: mode),
            style: .continuous
        )

        content
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
            .background {
                shape
                    .fill(Theme.shell)
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 7)
            }
            .overlay {
                // While open the island keeps its content during a drag rather
                // than morphing into a drop zone, so the border carries the
                // "you can drop here" signal instead.
                shape.strokeBorder(
                    model.isDropTargeted && mode == .expanded ? Theme.accent : Theme.hairline,
                    lineWidth: model.isDropTargeted && mode == .expanded ? 1.5 : 0.5
                )
            }
            .overlay(alignment: .bottom) { toast }
            .contentShape(shape)
            .onTapGesture { model.handleTap(.body) }
            // No `.animation(_:value:)` here on purpose: `recomputeMode()` already
            // wraps the mode change in `withAnimation` with the correct directional
            // spring. A modifier here would animate the same property twice.
            .onDrop(
                of: Self.acceptedTypes,
                isTargeted: Binding(
                    get: { model.isDropTargeted },
                    set: { model.setDropTargeted($0) }
                )
            ) { providers in
                model.handleDrop(providers: providers)
            }
            // Pin to whichever canvas corner the island is anchored to, so it
            // always grows into the screen rather than off the edge.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.anchor.alignment)
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .collapsed:  CollapsedView().transition(.islandContent)
        case .expanded:   ExpandedView().transition(.islandContent)
        case .dropTarget: DropTargetView().transition(.islandContent)
        case .alert:      AlertView().transition(.islandContent)
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let message = model.toast, model.mode != .collapsed {
            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.72)))
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Makes a region a grab handle for repositioning the island.
///
/// `minimumDistance` is what keeps this from swallowing clicks: below the
/// threshold SwiftUI resolves the gesture as a tap and the island opens; past it,
/// the island moves instead.
struct IslandMoveGesture: ViewModifier {
    @EnvironmentObject private var model: IslandModel

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { model.move(translation: $0.translation, finished: false) }
                .onEnded { model.move(translation: $0.translation, finished: true) }
        )
    }
}

extension View {
    func islandMovable() -> some View { modifier(IslandMoveGesture()) }
}

// MARK: - Collapsed

/// The idle pill: a glanceable status strip.
///
/// Observes the three services it actually reads, so a filesystem event or a
/// scrubber tick cannot invalidate it.
struct CollapsedView: View {
    @EnvironmentObject private var spotify: SpotifyService
    @EnvironmentObject private var deviceActivity: DeviceActivityMonitor
    @EnvironmentObject private var vault: VaultStore

    var body: some View {
        HStack(spacing: 10) {
            leading

            Spacer(minLength: 4)

            if deviceActivity.cameraActive {
                Circle()
                    .fill(Theme.recording)
                    .frame(width: 7, height: 7)
                    .shadow(color: Theme.recording.opacity(0.8), radius: 3)
            }

            if !vault.items.isEmpty {
                Text("\(vault.items.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primary)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Circle().fill(Theme.fillStrong))
            }

            if let track = spotify.current {
                EqualizerBars(isAnimating: track.isPlaying)
            }
        }
        .padding(.horizontal, IslandGeometry.collapsedHPadding)
        .frame(height: IslandGeometry.size(for: .collapsed).height)
        // The whole pill is the grab handle when closed — there's no content
        // underneath it to compete for the drag.
        .islandMovable()
    }

    @ViewBuilder
    private var leading: some View {
        if let track = spotify.current {
            HStack(spacing: 9) {
                Artwork(image: spotify.artwork, size: 26, radius: 7)
                Text(track.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "tray.full")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Text("Island")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}

// MARK: - Composed states

/// Click-expanded: status header over the full card.
struct ExpandedView: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            StatusHeaderView()

            HStack(spacing: 6) {
                FaceTabs()
                Spacer(minLength: 0)
                if model.face == .media {
                    TransportControls()
                } else {
                    MirrorRootButton()
                }
            }
            .frame(height: IslandGeometry.tabRowHeight)
            .padding(.horizontal, IslandGeometry.expandedHPadding)
            .padding(.top, IslandGeometry.tabRowTopPadding)
            .padding(.bottom, IslandGeometry.tabRowBottomPadding)

            // No trailing Spacer: the window is sized to exactly this content, so
            // anything that expands to fill would just re-introduce the dead space.
            Group {
                switch model.face {
                case .media: MediaCard(artworkSize: IslandGeometry.mediaArtwork)
                case .vault: VaultBody()
                }
            }
            .padding(.horizontal, IslandGeometry.expandedHPadding)
            .padding(.bottom, IslandGeometry.expandedVPadding)
        }
    }
}

/// Album art with a graceful placeholder.
struct Artwork: View {
    let image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.fill)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
