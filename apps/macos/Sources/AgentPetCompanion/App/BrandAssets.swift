import AppKit
import SwiftUI

@MainActor
enum APCBrandAssets {
    static let markResourceName = "AgentPetCompanionMark.png"

    static let markImage: NSImage = {
        let resourceURL = APCResourceBundle.resourceURL(markResourceName)
        guard let image = NSImage(contentsOf: resourceURL) else {
            assertionFailure("Missing Agent Pet Companion brand mark at \(resourceURL.path)")
            return NSImage(size: NSSize(width: 1, height: 1))
        }
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
