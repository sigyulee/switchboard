import SwiftUI

struct SettingsSurface<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let width: CGFloat
    var maximumHeight: CGFloat = 680
    @ViewBuilder var content: Content

    private var adaptiveWidth: CGFloat {
        let systemScale: CGFloat = dynamicTypeSize.isAccessibilitySize ? 1.15 : 1
        return min(800, width * systemScale)
    }

    var body: some View {
        ScrollView {
            content.padding(24)
        }
        .frame(width: adaptiveWidth)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}
