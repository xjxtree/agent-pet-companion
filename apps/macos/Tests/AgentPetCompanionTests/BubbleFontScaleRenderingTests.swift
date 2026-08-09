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
    @Test
    func standaloneTerminalStatesPaintTheirSemanticSymbols() throws {
        let cases: [(AgentEventKind, ClosedHue)] = [
            (.waiting, .orange),
            (.done, .green),
            (.failed, .red),
        ]
        for (eventType, hue) in cases {
            let bitmap = try standaloneStatusBitmap(eventType: eventType)
            #expect(semanticPixelCount(in: bitmap, hue: hue) > 3)
            try writeCaptureIfRequested(
                bitmap,
                name: "standalone-status-\(eventType.rawValue)"
            )
        }
    }

    @MainActor
    @Test
    func productionRowsReserveTheirMaximumMessageHeightBeforeAndAfterReplies() {
        let messageStates = [
            (message: "", status: ""),
            (message: "", status: "Thinking"),
            (message: "One line", status: "Thinking"),
            (
                message: String(repeating: "Bounded two-line session detail ", count: 8),
                status: "Running"
            ),
        ]

        for fontScale in BubbleFontScale.allCases {
            for presentation in [
                SessionBubbleRowPresentation.detailed,
                .standaloneSummary,
            ] {
                let presentationName = switch presentation {
                case .detailed: "detailed"
                case .standaloneSummary: "standalone"
                }
                let heights = messageStates.map {
                    productionRowFittingHeight(
                        messageText: $0.message,
                        statusText: $0.status,
                        presentation: presentation,
                        fontScale: fontScale
                    )
                }
                #expect(heights.dropFirst().allSatisfy {
                    abs($0 - heights[0]) < 0.5
                }, "\(presentationName) \(fontScale.rawValue): \(heights)")
            }
        }
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

    @MainActor
    private func standaloneStatusBitmap(
        eventType: AgentEventKind
    ) throws -> NSBitmapImageRep {
        let session = OverlaySessionContent(
            id: "status-\(eventType.rawValue)",
            source: .codex,
            sessionID: "status-\(eventType.rawValue)",
            eventType: eventType,
            sessionTitle: "Session state",
            messageText: "Latest message",
            statusText: eventType.rawValue
        )
        let size = CGSize(
            width: OverlayGeometry.bubbleWidth,
            height: OverlayGeometry.resolvedBubbleSize(
                in: CGSize(width: 1512, height: 934),
                content: OverlayBubbleContent(
                    id: "status-card-\(eventType.rawValue)",
                    source: .codex,
                    agentName: "Codex",
                    sessions: [session],
                    isStandaloneSessionCard: true
                )
            ).height
        )
        // NSGlassEffectView depends on a live WindowServer backdrop and is not
        // a valid offscreen bitmap oracle. Render the exact production row on
        // an opaque test backdrop; BubbleGlassRenderingTests separately verify
        // that the native glass surface owns this foreground in production.
        let root = ZStack {
            Color(white: 0.12)
            SessionBubbleRow(
                session: session,
                action: {},
                presentation: .standaloneSummary,
                agentName: "Codex"
            )
            .padding(.horizontal, OverlayGeometry.bubbleLeadingPadding)
            .padding(.vertical, OverlayGeometry.bubbleVerticalPadding)
        }
        .environment(\.overlayBubbleFontScale, BubbleFontScale.standard)
        .environment(\.colorScheme, ColorScheme.dark)
        .frame(width: size.width, height: size.height)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    @MainActor
    private func productionRowFittingHeight(
        messageText: String,
        statusText: String,
        presentation: SessionBubbleRowPresentation,
        fontScale: BubbleFontScale
    ) -> CGFloat {
        let session = OverlaySessionContent(
            id: "fixed-height",
            source: .codex,
            sessionID: "fixed-height",
            eventType: .thinking,
            sessionTitle: "Investigate bubble",
            messageText: messageText,
            statusText: statusText
        )
        let root = SessionBubbleRow(
            session: session,
            action: {},
            presentation: presentation,
            agentName: "Codex"
        )
        .environment(\.overlayBubbleFontScale, fontScale)
        .frame(width: OverlayGeometry.bubbleWidth - (
            OverlayGeometry.bubbleLeadingPadding
                + OverlayGeometry.bubbleTrailingPadding
        ))
        let hostingView = NSHostingView(rootView: root)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.height
    }

    private enum ClosedHue {
        case orange
        case green
        case red
    }

    private func semanticPixelCount(
        in bitmap: NSBitmapImageRep,
        hue expectedHue: ClosedHue
    ) -> Int {
        var count = 0
        for x in 0 ..< bitmap.pixelsWide {
            for y in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                color.getHue(
                    &hue,
                    saturation: &saturation,
                    brightness: &brightness,
                    alpha: &alpha
                )
                guard saturation > 0.28, brightness > 0.32, alpha > 0.4 else { continue }
                let matches = switch expectedHue {
                case .orange: (0.035 ... 0.16).contains(hue)
                case .green: (0.20 ... 0.48).contains(hue)
                case .red: hue < 0.035 || hue > 0.96
                }
                if matches { count += 1 }
            }
        }
        return count
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
