import SwiftUI
import UniformTypeIdentifiers

/// The island shell, living in the notch.
///
/// **Layout.** The canvas is centred on the notch and flush with the top of the
/// screen. Every expanded state reserves `notch.height` of clearance at the top,
/// because that band sits behind the camera cutout where there are no pixels to
/// draw on. Content starts below it.
///
/// **Rendering.** The panel never resizes — see `IslandHostingView`. SwiftUI owns
/// the whole transition, so no AppKit frame animation competes with it and no
/// in-flight drag gets cancelled by a resize. The drop shadow is cast by a bare
/// shape *behind* the content rather than by the content itself: shadowing a
/// composited subtree forces a re-rasterise every frame to derive the blur mask,
/// while shadowing a plain filled shape stays on the GPU.
struct IslandRootView: View {

    @EnvironmentObject private var model: IslandModel

    private static let acceptedTypes: [UTType] = [
        .fileURL, .image, .png, .tiff, .pdf, .plainText, .utf8PlainText, .url, .text
    ]

    var body: some View {
        let mode = model.mode
        let notch = model.notch
        let size = IslandGeometry.size(for: mode, face: model.face, notch: notch)
        let shape = NotchShape(
            bottomLeading: IslandGeometry.bottomLeadingRadius(for: mode),
            bottomTrailing: IslandGeometry.bottomTrailingRadius(for: mode)
        )
        let isIdle = mode == .collapsed

        content
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
            .background {
                // No shadow while idle: a halo around the nub separates it from the
                // notch, which is the opposite of what it is trying to do.
                shape
                    .fill(Theme.shell)
                    .shadow(color: .black.opacity(isIdle ? 0 : 0.4), radius: isIdle ? 0 : 14,
                            y: isIdle ? 0 : 6)
            }
            .overlay {
                // Likewise no hairline while idle — a lit outline traced around the
                // nub is exactly the seam this is meant to hide.
                if !isIdle {
                    shape.stroke(
                        model.isDropTargeted && mode == .expanded ? Theme.accent : Theme.hairline,
                        lineWidth: model.isDropTargeted && mode == .expanded ? 1.5 : 0.5
                    )
                }
            }
            .overlay(alignment: .bottom) { toast }
            .contentShape(shape)
            .onTapGesture { model.handleTap(.body) }
            // No `.animation(_:value:)` here on purpose: `recomputeMode()` already
            // wraps the change in `withAnimation` with the correct directional
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
            // Flush against the notch's trailing edge, pinned to the screen top.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .collapsed:  IdleLipView().transition(.opacity)
        case .expanded:   ExpandedView().transition(.islandContent)
        case .listening:  VoiceView().transition(.islandContent)
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

/// Top breathing room, so content doesn't sit against the bezel.
struct IslandTopPadding: View {
    var body: some View {
        Color.clear.frame(height: IslandGeometry.topPadding)
    }
}

// MARK: - Idle

/// The idle state: a featureless black nub extending the cutout rightward.
///
/// Deliberately empty. Anything drawn here — a status dot, a level meter — is a
/// coloured mark floating in what is meant to read as part of the hardware, and
/// immediately gives away that the notch is being impersonated. Live indicators
/// live in the expanded status header instead, where there is a panel to sit on.
struct IdleLipView: View {
    var body: some View {
        Color.clear
    }
}

// MARK: - Expanded

/// Click-expanded: status header over the full card.
struct ExpandedView: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            IslandTopPadding()

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
            .padding(.horizontal, IslandGeometry.hPadding)
            .padding(.top, IslandGeometry.tabRowTopPadding)
            .padding(.bottom, IslandGeometry.tabRowBottomPadding)

            // No trailing Spacer: the window is sized to exactly this content, so
            // anything that expands to fill would re-introduce the dead space.
            Group {
                switch model.face {
                case .media: MediaCard(artworkSize: IslandGeometry.mediaArtwork)
                case .vault: VaultBody()
                }
            }
            .padding(.horizontal, IslandGeometry.hPadding)
            .padding(.bottom, IslandGeometry.bottomPadding)
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
