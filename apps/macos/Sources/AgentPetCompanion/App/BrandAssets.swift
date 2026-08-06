import AppKit
import SwiftUI

@MainActor
enum APCBrandAssets {
    static let markResourceName = "AgentPetCompanionMark.png"
    static let statusItemMarkPointSize: CGFloat = 24

    static let markImage: NSImage = {
        let resourceURL = APCResourceBundle.resourceURL(markResourceName)
        guard let image = NSImage(contentsOf: resourceURL) else {
            assertionFailure("Missing Agent Pet Companion brand mark at \(resourceURL.path)")
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        image.isTemplate = false
        return image
    }()

    /// `MenuBarExtra` consults the label image's intrinsic AppKit point size
    /// before SwiftUI applies view-level frames. Passing the 1024 px source
    /// image directly therefore creates a roughly 1024 pt status item even
    /// when its drawing is visually scaled down. Keep a point-sized copy for
    /// the status bar so both layout and rendering use the compact dimensions.
    static let statusItemMarkImage: NSImage = {
        guard let image = markImage.copy() as? NSImage else { return markImage }
        image.size = NSSize(
            width: statusItemMarkPointSize,
            height: statusItemMarkPointSize
        )
        image.isTemplate = false
        return image
    }()

    static func applyApplicationIcon() {
        NSApplication.shared.applicationIconImage = markImage
    }
}

struct APCBrandMark: View {
    var size: CGFloat
    var accessibilityLabel = "Agent Pet Companion"

    var body: some View {
        Image(nsImage: APCBrandAssets.markImage)
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel(Text(accessibilityLabel))
    }
}
