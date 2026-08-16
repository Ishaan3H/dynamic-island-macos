import SwiftUI

/// Voice assistant panel: ⌃⌥Space → listen → act → report.
struct VoiceView: View {
    @EnvironmentObject private var model: IslandModel
    @EnvironmentObject private var voice: VoiceAssistant

    var body: some View {
        VStack(spacing: 0) {
            IslandTopPadding()

            VStack(spacing: 9) {
                header

                switch voice.phase {
                case .listening:
                    listening
                case .thinking:
                    row(icon: "circle.dotted", tint: Theme.secondary,
                        title: "Working…", subtitle: nil)
                case .success(let headline, let detail):
                    row(icon: "checkmark.circle.fill", tint: Theme.accent,
                        title: headline, subtitle: detail)
                case .failure(let message):
                    failure(message)
                case .idle:
                    EmptyView()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, IslandGeometry.hPadding)
            .padding(.bottom, IslandGeometry.bottomPadding)
            .frame(height: IslandGeometry.voiceContentHeight, alignment: .top)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "mic.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(voice.phase == .listening ? Theme.accent : Theme.tertiary)

            Text(headline)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Theme.tertiary)
                .kerning(0.6)

            Spacer(minLength: 0)

            IslandIconButton(systemName: "xmark", size: 9, diameter: 20, tint: Theme.tertiary) {
                voice.dismiss()
            }
        }
        .padding(.top, 8)
    }

    private var headline: String {
        switch voice.phase {
        case .listening: return "LISTENING"
        case .thinking:  return "THINKING"
        case .success:   return "DONE"
        case .failure:   return "DIDN’T WORK"
        case .idle:      return "VOICE"
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 8) {
            VoiceWaveform(level: voice.level)

            Text(voice.transcript.isEmpty
                 ? "“setup design review at 6pm to 7:30pm”"
                 : voice.transcript)
                .font(.system(size: 12, weight: voice.transcript.isEmpty ? .regular : .medium))
                .foregroundStyle(voice.transcript.isEmpty ? Theme.tertiary : Theme.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(nil, value: voice.transcript)
        }
    }

    private func row(icon: String, tint: Color, title: String, subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            row(icon: "exclamationmark.triangle.fill", tint: Theme.warning,
                title: message, subtitle: nil)

            // Only a denied permission is fixable from here, so only then offer it.
            if message.localizedCaseInsensitiveContains("denied") {
                Button {
                    VoiceAssistant.openPrivacySettings(
                        message.localizedCaseInsensitiveContains("calendar")
                            ? "Privacy_Calendars"
                            : "Privacy_Microphone"
                    )
                } label: {
                    Text("Open Privacy Settings")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Level-reactive bars. Driven by mic RMS, with a per-bar phase offset so it reads
/// as a waveform rather than a single pulsing block.
struct VoiceWaveform: View {
    let level: Double
    private let bars = 24

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { index in
                Capsule()
                    .fill(Theme.accent.opacity(0.55 + 0.45 * weight(index)))
                    .frame(width: 2.5, height: height(index))
            }
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    /// Centre bars react most, edges least — a simple bell across the row.
    private func weight(_ index: Int) -> Double {
        let mid = Double(bars - 1) / 2
        let distance = abs(Double(index) - mid) / mid
        return max(0, 1 - distance * distance)
    }

    private func height(_ index: Int) -> CGFloat {
        let base = 3.0
        let reactive = 23.0 * level * weight(index)
        return CGFloat(base + reactive)
    }
}
