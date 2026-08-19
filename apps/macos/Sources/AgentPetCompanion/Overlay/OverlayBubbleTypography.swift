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
    /// Standalone cards render the title and retained Agent body as one inline
    /// summary. Capping the title at two thirds of that line keeps enough room
    /// for a reply or narrative activity to remain visible on the first line.
    static let standaloneSessionTitleLineFraction: CGFloat = 2.0 / 3.0

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

    static func standaloneSessionTitle(
        _ title: String,
        availableLineWidth: CGFloat,
        scale: BubbleFontScale
    ) -> String {
        guard availableLineWidth.isFinite, availableLineWidth > 0 else {
            return title
        }
        let maximumWidth = availableLineWidth * standaloneSessionTitleLineFraction
        let font = NSFont.systemFont(
            ofSize: pointSize(.callout, scale: scale),
            weight: .semibold
        )
        guard measuredTextWidth(title, font: font) > maximumWidth else {
            return title
        }

        let ellipsis = "…"
        guard measuredTextWidth(ellipsis, font: font) <= maximumWidth else {
            return ""
        }
        let characters = Array(title)
        var lowerBound = 0
        var upperBound = characters.count
        while lowerBound < upperBound {
            let candidateCount = (lowerBound + upperBound + 1) / 2
            let candidate = String(characters.prefix(candidateCount)) + ellipsis
            if measuredTextWidth(candidate, font: font) <= maximumWidth {
                lowerBound = candidateCount
            } else {
                upperBound = candidateCount - 1
            }
        }
        return String(characters.prefix(lowerBound)) + ellipsis
    }

    static func measuredTextWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
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
