import AppKit
import SwiftUI
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

/// Measured row heights alone cannot prove the bubble actually draws larger
/// glyphs, so render the real production session row at both tiers off screen
/// and compare painted text pixels.
@Suite("Bubble font scale rendering")
struct BubbleFontScaleRenderingTests {
    @MainActor
    @Test
    func largerTierPaintsMoreTextPixelsInTheProductionSessionRow() throws {
        let standardInk = try textPixelCount(fontScale: .standard)
        let largeInk = try textPixelCount(fontScale: .large)

        #expect(standardInk > 0)
        // Same string, same row width: only a larger typeface can cover
        // materially more pixels.
        #expect(Double(largeInk) > Double(standardInk) * 1.1)
    }

    @MainActor
    private func textPixelCount(fontScale: BubbleFontScale) throws -> Int {
        let session = OverlaySessionContent(
            id: "render-session",
            source: .codex,
            sessionID: "render-session",
            eventType: .tool,
            sessionTitle: "Refactor overlay geometry",
            messageText: "Running the bundled contract validation",
            statusText: "Running"
        )
        let content = OverlayBubbleContent(
            id: "render-agent-codex",
            source: .codex,
            agentName: "Codex",
            sessions: [session]
        )
        let size = CGSize(
            width: OverlayGeometry.bubbleWidth,
            height: OverlayGeometry.resolvedBubbleSize(
                in: CGSize(width: 1512, height: 934),
                content: content,
                fontScale: fontScale
            ).height
        )
        // An opaque backdrop stands in for the bubble's glass surface so the
        // measurement compares composited glyph coverage rather than premul-
        // tiplied alpha, and so a written capture is directly viewable.
        let root = ZStack {
            Color(white: 0.12)
            SessionBubbleRow(session: session, action: {})
        }
        .environment(\.overlayBubbleFontScale, fontScale)
        .environment(\.colorScheme, .dark)
        .frame(width: size.width, height: size.height)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        try writeCaptureIfRequested(bitmap, name: "session-row-\(fontScale.rawValue)")

        // Over a dark backdrop the row fill stays dim, so bright pixels are
        // glyph coverage.
        var painted = 0
        for x in 0 ..< bitmap.pixelsWide {
            for y in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap
                    .colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                if color.brightnessComponent > 0.6 {
                    painted += 1
                }
            }
        }
        return painted
    }

    private func writeCaptureIfRequested(
        _ bitmap: NSBitmapImageRep,
        name: String
    ) throws {
        guard let directory = ProcessInfo.processInfo.environment[
            "APC_CAPTURE_BUBBLE_FONT_SCALE_DIR"
        ] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(name).png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
