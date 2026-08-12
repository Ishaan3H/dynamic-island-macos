import SwiftUI

/// Status strip shown at the top of the click-expanded island.
///
/// Clicking it collapses the island — the header doubles as the dismiss
/// affordance, which is why the chevron sits at its trailing edge.
struct StatusHeaderView: View {
    // Only what this view actually reads. An `@EnvironmentObject` is a
    // subscription, not a reference — declaring one that goes unused would
    // redraw the header on every scrubber tick and every filesystem event.
    // The live dots live in `ActivityIndicators`, which observes its own.
    @EnvironmentObject private var model: IslandModel
    @EnvironmentObject private var status: SystemStatusService

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Text(status.time)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.primary)
                .monospacedDigit()

            ActivityIndicators()

            Spacer(minLength: 4)

            WiFiBars(state: status.network)

            if let battery = status.battery {
                BatteryBadge(battery: battery)
            }

            Image(systemName: "chevron.compact.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? Theme.secondary : Theme.tertiary)
                .frame(width: 18)
        }
        .padding(.horizontal, IslandGeometry.hPadding)
        .frame(height: 46)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.handleTap(.header) }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
                .padding(.horizontal, IslandGeometry.hPadding)
        }
    }
}

/// Compact live-status dots: recording, microphone, playback, staged count.
struct ActivityIndicators: View {
    @EnvironmentObject private var deviceActivity: DeviceActivityMonitor
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var spotify: SpotifyService
    @EnvironmentObject private var calls: CallMonitor

    var body: some View {
        HStack(spacing: 5) {
            if deviceActivity.cameraActive {
                dot(color: Theme.recording, symbol: "record.circle")
            }
            if deviceActivity.microphoneActive {
                dot(color: Theme.warning, symbol: "mic.fill")
            }
            if calls.activeCall != nil {
                dot(color: Theme.accent, symbol: "phone.fill")
            }
            if spotify.current?.isPlaying == true {
                dot(color: Theme.accent, symbol: "waveform")
            }
            if !vault.items.isEmpty {
                Text("\(vault.items.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Theme.fill))
            }
        }
    }

    private func dot(color: Color, symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(Circle().fill(color.opacity(0.16)))
    }
}

/// Three ascending bars, filled to signal quality.
struct WiFiBars: View {
    let state: NetworkState

    var body: some View {
        HStack(spacing: 4) {
            if state.isOnline {
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(1...3, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                            .fill(level <= state.bars ? Theme.primary : Theme.tertiary.opacity(0.45))
                            .frame(width: 2.5, height: 3.5 + CGFloat(level) * 2.6)
                    }
                }
                .frame(height: 12, alignment: .bottom)
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.alert)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        guard state.isOnline else { return "Offline" }
        if state.isWired { return "Wired connection" }
        // SSID needs Location authorisation; without it we still have signal.
        let name = state.ssid ?? "Wi-Fi"
        if let rssi = state.rssi { return "\(name) · \(rssi) dBm" }
        return name
    }
}

struct BatteryBadge: View {
    let battery: BatteryState

    var body: some View {
        HStack(spacing: 3.5) {
            Image(systemName: battery.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
            Text("\(battery.percent)%")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.primary)
                .monospacedDigit()
        }
        .help(detail)
    }

    private var tint: Color {
        if battery.isCharging || battery.isPlugged { return Theme.accent }
        if battery.percent <= 10 { return Theme.alert }
        if battery.percent <= 20 { return Theme.warning }
        return Theme.primary
    }

    private var detail: String {
        if battery.isCharging { return "Charging" }
        if battery.isPlugged { return "Plugged in" }
        guard let minutes = battery.minutesRemaining else { return "On battery" }
        return "\(minutes / 60)h \(minutes % 60)m remaining"
    }
}
