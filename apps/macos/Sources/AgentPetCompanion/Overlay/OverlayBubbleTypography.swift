import AgentPetCompanionCore
import AppKit
import Foundation
import SwiftUI

/// The single place bubble text sizes are resolved.
///
/// Every role keeps the macOS text style it was authored with and is multiplied
/// by the selected tier, so switching tiers changes only the absolute size —
/// the size relationships between agent name, session title, detail lines, and
/// badges stay exactly as designed. Rendering and AppKit measurement read the
/// same values, so a taller row is measured before the panel is sized rather
/// than discovered as clipped text.
enum OverlayBubbleTypography {
    static func pointSize(
        _ style: NSFont.TextStyle,
        scale: BubbleFontScale
    ) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style).pointSize * CGFloat(scale.multiplier)
    }

    static func font(
        _ style: NSFont.TextStyle,
        weight: Font.Weight,
        scale: BubbleFontScale
    ) -> Font {
        .system(size: pointSize(style, scale: scale), weight: weight)
    }

    static func measurementFont(
        _ style: NSFont.TextStyle,
        scale: BubbleFontScale
    ) -> NSFont {
        NSFont.systemFont(ofSize: pointSize(style, scale: scale))
    }

    /// Scales a control box that exists only to hold bubble text or a glyph
    /// sized from it. Padding, gaps, corner radii, and the bubble width are
    /// deliberately not scaled: the tier changes type size, not the layout
    /// language of the bubble.
    static func scaledControlMetric(
        _ value: CGFloat,
        scale: BubbleFontScale
    ) -> CGFloat {
        (value * CGFloat(scale.multiplier)).rounded(.up)
    }
}

private struct OverlayBubbleFontScaleKey: EnvironmentKey {
    static let defaultValue: BubbleFontScale = .standard
}

extension EnvironmentValues {
    /// Read by every bubble subview so the selected tier does not have to be
    /// threaded through each row, badge, and control initializer.
    var overlayBubbleFontScale: BubbleFontScale {
        get { self[OverlayBubbleFontScaleKey.self] }
        set { self[OverlayBubbleFontScaleKey.self] = newValue }
    }
}
