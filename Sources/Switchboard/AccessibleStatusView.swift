import SwiftUI

enum AccessibleStatusKind: CaseIterable {
    case ready, inactive, progress, warning, error

    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .inactive: "minus.circle"
        case .progress: "ellipsis.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .ready: .green
        case .inactive: .secondary
        case .progress: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }
}

struct AccessibleStatusLabel: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.colorSchemeContrast) private var contrast
    let text: String
    let kind: AccessibleStatusKind

    var body: some View {
        Label {
            Text(text).font(typography.caption.weight(.medium))
        } icon: {
            Image(systemName: kind.symbolName)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)
        }
        .foregroundStyle(contrast == .increased ? .primary : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

enum AudioCaptureAccessibilityState: Equatable {
    case receiving, quiet, paused, disconnected, unavailable, failed
}

struct AudioCaptureAccessibilityPresentation: Equatable {
    let state: AudioCaptureAccessibilityState

    init(ready: Bool, level: Float, paused: Bool, disconnected: Bool, failed: Bool) {
        if failed {
            state = .failed
        } else if disconnected {
            state = .disconnected
        } else if paused {
            state = .paused
        } else if !ready {
            state = .unavailable
        } else if level > 0.001 {
            state = .receiving
        } else {
            state = .quiet
        }
    }

    var kind: AccessibleStatusKind {
        switch state {
        case .receiving: .ready
        case .quiet: .inactive
        case .paused: .warning
        case .disconnected, .failed: .error
        case .unavailable: .warning
        }
    }
}
