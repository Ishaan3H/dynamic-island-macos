import SwiftUI

/// Artwork, metadata, and scrubber. Observes `SpotifyService` alone, so the 1 Hz
/// position tick redraws this card and nothing outside it.
struct MediaCard: View {
    @EnvironmentObject private var spotify: SpotifyService
    var artworkSize: CGFloat = 56

    var body: some View {
        if let track = spotify.current {
            HStack(alignment: .top, spacing: 12) {
                Artwork(image: spotify.artwork, size: artworkSize, radius: artworkSize * 0.18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)

                    if artworkSize > 70 {
                        Text(track.album)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    ProgressLine(progress: track.progress)

                    HStack {
                        Text(track.position.clockString)
                        Spacer()
                        Text(track.duration.clockString)
                    }
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.tertiary)
                    .monospacedDigit()
                }
                .frame(height: artworkSize)
            }
            .overlay(alignment: .top) { automationBanner }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        HStack(spacing: 12) {
            Artwork(image: nil, size: artworkSize, radius: artworkSize * 0.18)
            VStack(alignment: .leading, spacing: 3) {
                Text(spotify.isRunning ? "Nothing playing" : "Spotify isn’t running")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text(spotify.isRunning ? "Press play in Spotify" : "Launch Spotify to see playback")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(height: artworkSize)
    }

    /// Surfaced only when an Apple Event actually came back denied, so it never
    /// nags a user whose permissions are fine.
    @ViewBuilder
    private var automationBanner: some View {
        if spotify.automationDenied {
            Button {
                SpotifyService.openAutomationSettings()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                    Text("Allow Automation for Spotify")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Transport row. Buttons consume their own clicks, so pressing play never also
/// triggers the island's tap-to-expand.
struct TransportControls: View {
    @EnvironmentObject private var spotify: SpotifyService

    var body: some View {
        HStack(spacing: 2) {
            IslandIconButton(systemName: "backward.end.fill", size: 12, diameter: 28) {
                spotify.previousTrack()
            }
            IslandIconButton(
                systemName: (spotify.current?.isPlaying ?? false) ? "pause.fill" : "play.fill",
                size: 14, diameter: 30
            ) {
                spotify.togglePlayPause()
            }
            IslandIconButton(systemName: "forward.end.fill", size: 12, diameter: 28) {
                spotify.nextTrack()
            }
        }
        .disabled(spotify.current == nil)
        .opacity(spotify.current == nil ? 0.35 : 1)
    }
}

/// Media / Vault switcher.
struct FaceTabs: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        HStack(spacing: 3) {
            tab(icon: "waveform", face: .media)
            tab(icon: "tray.full", face: .vault)
        }
    }

    private func tab(icon: String, face: IslandFace) -> some View {
        let isSelected = model.face == face
        return Button {
            model.show(face: face)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.primary : Theme.tertiary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Theme.fill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Drop target

/// Shown while a drag hovers the island.
struct DropTargetView: View {
    var body: some View {
        VStack(spacing: 0) {
            IslandTopPadding()
            zone
        }
    }

    private var zone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    Theme.accent.opacity(0.75),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.accent.opacity(0.08))
                )

            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Drop to stage")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text("Text, images, and files")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, IslandGeometry.hPadding)
        .padding(.bottom, IslandGeometry.bottomPadding)
    }
}

// MARK: - Alert

/// Priority interrupt: incoming or active call.
struct AlertView: View {
    @EnvironmentObject private var calls: CallMonitor

    var body: some View {
        VStack(spacing: 0) {
            IslandTopPadding()
            banner
        }
    }

    private var banner: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(call?.displayName ?? "Call")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            IslandIconButton(systemName: "xmark", size: 11, diameter: 28, tint: Theme.secondary) {
                calls.clear()
            }
        }
        .padding(.horizontal, IslandGeometry.hPadding)
        .frame(height: IslandGeometry.alertContentHeight)
    }

    private var call: CallEvent? { calls.activeCall }
    private var tint: Color { call?.phase == .incoming ? Theme.accent : Theme.alert }

    private var icon: String {
        call?.phase == .incoming ? "phone.fill" : "phone.connected"
    }

    private var subtitle: String {
        guard let call else { return "" }
        return call.phase == .incoming ? "Incoming · \(call.source)" : "In call · \(call.source)"
    }
}
