import AgentPetCompanionCore
import AppKit
import CoreImage
import Testing
@testable import AgentPetCompanion

@Suite
struct PetFramePipelineTests {
    @Test
    func testDrawLookupNeverReadsDisk() async throws {
        let probe = FrameDecoderProbe()
        let pipeline = makePipeline(probe: probe, frameCount: 3)
        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let readsAfterPrepare = probe.decodeCount

        for index in 0..<20 {
            _ = prepared.readyFrame(at: index % 3)
        }

        #expect(probe.decodeCount == readsAfterPrepare)
    }

    @MainActor
    @Test
    func testDecodeWorkIsNotMainActor() async throws {
        let probe = FrameDecoderProbe()
        let pipeline = makePipeline(probe: probe, frameCount: 2)

        _ = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))

        #expect(!probe.didDecodeOnMainThread)
    }

    @Test
    func testLRURespectsByteBudget() async throws {
        let probe = FrameDecoderProbe(pixelWidth: 2, pixelHeight: 2)
        let pipeline = makePipeline(
            probe: probe,
            frameCount: 6,
            memoryBudgetBytes: 32
        )

        _ = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let metrics = await pipeline.cacheMetrics()

        #expect(metrics.byteCount <= 32)
        #expect(metrics.frameCount <= 2)
        #expect(metrics.maximumConcurrentDecodes <= 1)
    }

    @Test
    func testOriginalQualityKeepsRingWindow() async throws {
        let probe = FrameDecoderProbe()
        let pipeline = makePipeline(
            probe: probe,
            frameCount: 30,
            originalWindowSize: 7
        )

        let prepared = try await pipeline.prepare(request(quality: .original, stateName: "tool"))
        let advanced = try await pipeline.prefetch(prepared, around: 12)

        #expect(prepared.sourceKind == .ring)
        #expect(prepared.readyFrameCount <= 7)
        #expect(advanced.readyFrameCount <= 7)
        #expect(advanced.readyFrame(at: 12) != nil)
    }

    @Test
    func testPreparedFramesExposeStableUnionOfVisibleActionBounds() async throws {
        let urls = (0..<2).map { URL(fileURLWithPath: "/virtual/visible-\($0).png") }
        let pipeline = PetFramePipeline(
            memoryBudgetBytes: 1_024 * 1_024,
            catalog: { _, _ in PetFrameAssetCatalog(frameURLs: urls, coverURL: nil) },
            decoder: { url in
                let index = url.deletingPathExtension().lastPathComponent.hasSuffix("1") ? 1 : 0
                let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 120))
                return PetDecodedFrame(
                    image: image,
                    pixelWidth: 100,
                    pixelHeight: 120,
                    visibleBounds: index == 0
                        ? CGRect(x: 10, y: 15, width: 70, height: 80)
                        : CGRect(x: 20, y: 5, width: 65, height: 110)
                )
            }
        )

        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))

        #expect(prepared.visualEnvelope == OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 100, height: 120),
            visibleBounds: CGRect(x: 10, y: 5, width: 75, height: 110)
        ))
    }

    @Test
    func testAlphaVisibleBoundsFindsOnlyOpaquePixels() throws {
        let width = 8
        let height = 10
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        let image = rgba.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 2, y: 3, width: 4, height: 5))
            return context.makeImage()
        }
        let decoded = try #require(image)

        #expect(PetFramePipeline.alphaVisibleBounds(of: decoded) == CGRect(
            x: 2,
            y: 3,
            width: 4,
            height: 5
        ))
    }

    @Test
    func testPreparingAnotherStateDropsStaleDecodedNamespaces() async throws {
        let probe = FrameDecoderProbe(pixelWidth: 2, pixelHeight: 2)
        let pipeline = makePipeline(
            probe: probe,
            frameCount: 3,
            memoryBudgetBytes: 1_024
        )

        _ = try await pipeline.prepare(request(quality: .standard, stateName: "idle"))
        let firstMetrics = await pipeline.cacheMetrics()
        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let secondMetrics = await pipeline.cacheMetrics()

        #expect(firstMetrics.frameCount == 3)
        #expect(secondMetrics.frameCount == 3)
        #expect(secondMetrics.byteCount == prepared.estimatedReadyBytes)
    }

    @Test
    func testTelemetryIncludesTrackedDecodedCacheMetrics() async throws {
        let probe = FrameDecoderProbe(pixelWidth: 4, pixelHeight: 5)
        let pipeline = makePipeline(probe: probe, frameCount: 2)
        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let cacheMetrics = await pipeline.cacheMetrics()

        let telemetry = PetRendererTelemetry(
            prepared: prepared,
            fpsProfile: .standard,
            active: true,
            cacheMetrics: cacheMetrics
        )

        #expect(telemetry.readyDecodedBytes == 160)
        #expect(telemetry.readyDecodedFrameCount == 2)
        #expect(telemetry.pipelineCacheBytes == 160)
        #expect(telemetry.pipelineCacheFrameCount == 2)
    }

    @MainActor
    @Test
    func testPointerTrackingHasNoHighFrequencyTimer() {
        let monitor = OverlayPointerEventMonitor()

        #expect(!monitor.usesPolling)
        #expect(OverlayPointerEventMonitor.eventMask.contains(.mouseMoved))
        #expect(!monitor.isRunning)
    }

    private func makePipeline(
        probe: FrameDecoderProbe,
        frameCount: Int,
        memoryBudgetBytes: Int = 1_024 * 1_024,
        originalWindowSize: Int = 7
    ) -> PetFramePipeline {
        let urls = (0..<frameCount).map { URL(fileURLWithPath: "/virtual/frame-\($0).png") }
        return PetFramePipeline(
            memoryBudgetBytes: memoryBudgetBytes,
            originalWindowSize: originalWindowSize,
            catalog: { _, _ in PetFrameAssetCatalog(frameURLs: urls, coverURL: nil) },
            decoder: { url in probe.decode(url) }
        )
    }

    private func request(quality: QualityLevel, stateName: String) -> PetFrameLoadRequest {
        PetFrameLoadRequest(
            pet: PetSummary(
                id: "pet_test",
                name: "Test",
                style: "pixel",
                quality: quality,
                renderSize: quality.renderSize,
                petpackPath: "/virtual/test.petpack",
                coverPath: "",
                active: true,
                createdAt: "2026-07-10T00:00:00Z"
            ),
            stateName: stateName,
            fps: 12,
            loops: stateName != "start" && stateName != "done"
        )
    }
}

private final class FrameDecoderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let pixelWidth: Int
    private let pixelHeight: Int
    private var _decodeCount = 0
    private var _didDecodeOnMainThread = false

    init(pixelWidth: Int = 2, pixelHeight: Int = 2) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _decodeCount
    }

    var didDecodeOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _didDecodeOnMainThread
    }

    func decode(_ url: URL) -> PetDecodedFrame? {
        lock.lock()
        _decodeCount += 1
        _didDecodeOnMainThread = _didDecodeOnMainThread || Thread.isMainThread
        lock.unlock()

        let image = CIImage(color: .white).cropped(to: CGRect(
            x: 0,
            y: 0,
            width: pixelWidth,
            height: pixelHeight
        ))
        return PetDecodedFrame(image: image, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}
