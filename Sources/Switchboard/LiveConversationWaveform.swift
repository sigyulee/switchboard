import SwiftUI

struct LiveConversationWaveform: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    let caller: [Float]
    let agent: [Float]
    let callerState: AudioCaptureAccessibilityPresentation
    let agentState: AudioCaptureAccessibilityPresentation
    var callerName: String? = nil
    var agentName: String? = nil

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            row(
                strings(.waveformCaller), application: callerName, samples: caller, color: .teal,
                presentation: callerState)
            row(
                "Agent", application: agentName, samples: agent, color: .blue,
                presentation: agentState)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings(.waveformLive))
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        [
            rowSummary(strings(.waveformCaller), application: callerName, presentation: callerState),
            rowSummary("Agent", application: agentName, presentation: agentState),
        ].joined(separator: "; ")
    }

    private func rowSummary(
        _ title: String, application: String?, presentation: AudioCaptureAccessibilityPresentation
    ) -> String {
        [title, application, stateText(presentation.state)].compactMap { $0 }.joined(separator: ", ")
    }

    private func stateText(_ state: AudioCaptureAccessibilityState) -> String {
        switch state {
        case .receiving: strings(.accessibilityAudioReceiving)
        case .quiet: strings(.accessibilityAudioQuiet)
        case .paused: strings(.accessibilityAudioPaused)
        case .disconnected: strings(.accessibilityAudioDisconnected)
        case .unavailable: strings(.accessibilityAudioUnavailable)
        case .failed: strings(.accessibilityAudioFailed)
        }
    }

    private func row(
        _ title: String, application: String?, samples: [Float], color: Color,
        presentation: AudioCaptureAccessibilityPresentation
    ) -> some View {
        let status = stateText(presentation.state)
        return GridRow {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(typography.caption.weight(.medium))
                if let application {
                    Text(application).font(typography.caption).lineLimit(2).help(application)
                }
                AccessibleStatusLabel(text: status, kind: presentation.kind)
            }.frame(maxWidth: 180, alignment: .leading)
            Canvas { context, size in
                let center = size.height / 2
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: center))
                baseline.addLine(to: CGPoint(x: size.width, y: center))
                context.stroke(baseline, with: .color(color.opacity(0.16)), lineWidth: 1)
                guard !samples.isEmpty else { return }
                let step = size.width / CGFloat(samples.count)
                for (index, sample) in samples.enumerated() where sample > 0 {
                    let amplitude = min(1, sqrt(CGFloat(sample)) * 2.2)
                    let height = max(2, amplitude * (size.height - 2))
                    let rect = CGRect(
                        x: CGFloat(index) * step, y: center - height / 2,
                        width: max(1, step * 0.58), height: height)
                    let opacity = 0.3 + 0.7 * Double(index + 1) / Double(samples.count)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: step / 2),
                        with: .color(color.opacity(opacity)))
                }
            }.frame(minWidth: 100, idealWidth: 180, maxWidth: .infinity).frame(height: 24)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [title, application, status].compactMap { $0 }.joined(separator: ", "))
    }
}
