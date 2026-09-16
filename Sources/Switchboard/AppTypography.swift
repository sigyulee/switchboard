import AppKit
import SwiftUI

struct AppTypography {
    var title: Font { Font.title.weight(.semibold) }
    var panelTitle: Font { Font.title2.weight(.semibold) }
    var section: Font { Font.headline.weight(.semibold) }
    var row: Font { Font.body.weight(.medium) }
    var body: Font { .body }
    var caption: Font { .callout }
    var controlSide: CGFloat {
        max(44, ceil(NSFont.preferredFont(forTextStyle: .title2).pointSize + 14))
    }
}

private struct AppTypographyKey: EnvironmentKey {
    static let defaultValue = AppTypography()
}

extension EnvironmentValues {
    var appTypography: AppTypography {
        get { self[AppTypographyKey.self] }
        set { self[AppTypographyKey.self] = newValue }
    }
}
