import AppKit
import SwiftUI

struct SplitActionButton: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let systemImage: String
    let menuLabel: String
    var menuValue: String? = nil
    let action: () -> Void
    let options: [SplitMenuOption]
    private var height: CGFloat { max(44, typography.controlSide) }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(typography.body.weight(.medium))
                    .padding(.leading, 16).padding(.trailing, 14)
                    .frame(minHeight: height)
                    .contentShape(Rectangle())
            }.buttonStyle(SplitSegmentStyle())
            SplitMenu(
                label: menuLabel, value: menuValue, side: height,
                pointSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                options: options
            )
            .frame(width: height, height: height)
        }
        .buttonBorderShape(.roundedRectangle(radius: 0))
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.quaternary),
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(
                .primary.opacity(contrast == .increased ? 0.3 : 0),
                lineWidth: contrast == .increased ? 2 : 0)
        )
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
    }
}

private struct SplitSegmentStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? .primary : .secondary)
            .background(
                Color.primary.opacity(enabled ? configuration.isPressed ? 0.14 : hovering ? 0.06 : 0 : 0),
                in: Rectangle()
            )
            .onHover { hovering = $0 }
    }
}
