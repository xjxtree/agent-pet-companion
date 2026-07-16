import AppKit
import SwiftUI
import Testing
@testable import AgentPetCompanion

#if compiler(>=6.2)
@Suite
@MainActor
struct BubbleGlassRenderingTests {
    /// The configuration-only tests protect the selected glass style, but the
    /// original regression happened later in AppKit's compositor: the glass
    /// rendered while its SwiftUI foreground disappeared. Exercise the real
    /// NSGlassEffectView hierarchy off screen and require the foreground to
    /// change rendered pixels compared with an otherwise identical empty
    /// clear-glass surface.
    @Test @MainActor
    @available(macOS 26.0, *)
    func nativeClearGlassCompositesHostedForegroundAboveItsOpticalLayer() throws {
        let size = CGSize(width: 320, height: 112)
        let foreground = makeGlassView(
            rootView: AnyView(
                Text("Codex session is running")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .fixedSize()
                    .frame(width: size.width, height: size.height)
            ),
            size: size
        )
        let empty = makeGlassView(
            rootView: AnyView(
                Color.clear
                    .frame(width: size.width, height: size.height)
            ),
            size: size
        )

        let hostedForegroundPixels = try renderedRGBA(of: foreground.foregroundView)
        let hostedEmptyPixels = try renderedRGBA(of: empty.foregroundView)
        let foregroundPixels = try renderedRGBA(of: foreground)
        let emptyPixels = try renderedRGBA(of: empty)
        #expect(foregroundPixels.count == emptyPixels.count)

        func changedPixelCount(_ lhsPixels: [RGBA], _ rhsPixels: [RGBA]) -> Int {
            zip(lhsPixels, rhsPixels).reduce(into: 0) { count, pair in
                let (lhs, rhs) = pair
                let channelDifference = abs(Int(lhs.r) - Int(rhs.r))
                    + abs(Int(lhs.g) - Int(rhs.g))
                    + abs(Int(lhs.b) - Int(rhs.b))
                    + abs(Int(lhs.a) - Int(rhs.a))
                if channelDifference >= 20 {
                    count += 1
                }
            }
        }

        let hostedChangedPixels = changedPixelCount(hostedForegroundPixels, hostedEmptyPixels)
        let compositedChangedPixels = changedPixelCount(foregroundPixels, emptyPixels)

        // A 28 pt sentence covers thousands of antialiased pixels. Keep the
        // floor deliberately low so font rasterizer changes do not make this
        // a snapshot test while a completely obscured foreground still fails.
        #expect(hostedChangedPixels >= 250)
        #expect(compositedChangedPixels >= 250)
    }

    @available(macOS 26.0, *)
    private func makeGlassView(rootView: AnyView, size: CGSize) -> APCNativeBubbleGlassView {
        let contentView = APCNativeBubbleGlassConfiguration.makeHostingView(rootView: rootView)
        let glassView = APCNativeBubbleGlassConfiguration.makeView(
            contentView: contentView,
            cornerRadius: 18
        )
        glassView.frame = NSRect(origin: .zero, size: size)
        glassView.layoutSubtreeIfNeeded()
        return glassView
    }

    private func renderedRGBA(of view: NSView) throws -> [RGBA] {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw BubbleGlassRenderingFailure.bitmapAllocationFailed
        }
        view.cacheDisplay(in: view.bounds, to: representation)

        var pixels: [RGBA] = []
        pixels.reserveCapacity(representation.pixelsWide * representation.pixelsHigh)
        for y in 0 ..< representation.pixelsHigh {
            for x in 0 ..< representation.pixelsWide {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    throw BubbleGlassRenderingFailure.pixelConversionFailed
                }
                pixels.append(RGBA(
                    r: UInt8((color.redComponent * 255).rounded()),
                    g: UInt8((color.greenComponent * 255).rounded()),
                    b: UInt8((color.blueComponent * 255).rounded()),
                    a: UInt8((color.alphaComponent * 255).rounded())
                ))
            }
        }
        return pixels
    }
}

private struct RGBA {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8
}

private enum BubbleGlassRenderingFailure: Error {
    case bitmapAllocationFailed
    case pixelConversionFailed
}
#endif
