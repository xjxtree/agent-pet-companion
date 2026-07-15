import AgentPetCompanionCore
import AppKit
import CoreImage
import Foundation
import ImageIO
import MetalKit
import QuartzCore

struct PetFrameAssetCatalog: Sendable {
    var frameURLs: [URL]
    var coverURL: URL?
}

struct PetFrameLoadRequest: Sendable {
    var pet: PetSummary
    var stateName: String
    var fps: Int
    var loops: Bool

    var assetKey: String {
        [
            pet.id,
            pet.petpackPath,
            pet.coverPath,
            pet.createdAt,
            pet.quality.rawValue,
            stateName,
            String(fps),
            loops ? "loop" : "once"
        ].joined(separator: ":")
    }
}

enum PetFrameSourceKind: String, Sendable {
    case empty
    case eager
    case ring
}

struct PetDecodedFrame: @unchecked Sendable {
    let image: CIImage
    let pixelWidth: Int
    let pixelHeight: Int
    let visibleBounds: CGRect
    let byteCost: Int

    init(
        image: CIImage,
        pixelWidth: Int,
        pixelHeight: Int,
        visibleBounds: CGRect? = nil
    ) {
        self.image = image
        self.pixelWidth = max(0, pixelWidth)
        self.pixelHeight = max(0, pixelHeight)
        let extent = CGRect(x: 0, y: 0, width: self.pixelWidth, height: self.pixelHeight)
        self.visibleBounds = visibleBounds.map { $0.intersection(extent) } ?? extent
        let (pixels, pixelOverflow) = self.pixelWidth.multipliedReportingOverflow(by: self.pixelHeight)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        byteCost = pixelOverflow || byteOverflow ? Int.max : bytes
    }

    var extent: CGRect {
        CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
    }
}

struct PetPreparedFrames: @unchecked Sendable {
    let request: PetFrameLoadRequest
    let sourceKind: PetFrameSourceKind
    let frameCount: Int
    let cacheFrameLimit: Int
    let canvasExtent: CGRect
    let visibleBounds: CGRect
    let fallback: PetDecodedFrame?
    fileprivate let frameURLs: [URL]
    fileprivate let readyFrames: [Int: PetDecodedFrame]

    var readyFrameCount: Int { readyFrames.count }
    var loops: Bool { request.loops }
    var visualEnvelope: OverlayPetVisualEnvelope? {
        guard !canvasExtent.isEmpty, !visibleBounds.isEmpty else { return nil }
        return OverlayPetVisualEnvelope(
            canvasSize: canvasExtent.size,
            visibleBounds: visibleBounds
        )
    }

    func readyFrame(at index: Int) -> PetDecodedFrame? {
        readyFrames[index]
    }

    var estimatedReadyBytes: Int {
        readyFrames.values.reduce(0) { partial, frame in
            let (sum, overflow) = partial.addingReportingOverflow(frame.byteCost)
            return overflow ? Int.max : sum
        }
    }
}

struct PetFrameCacheMetrics: Equatable, Sendable {
    var byteCount: Int
    var frameCount: Int
    var maximumConcurrentDecodes: Int
}

actor PetFramePipeline {
    typealias Catalog = @Sendable (PetSummary, String) -> PetFrameAssetCatalog
    typealias Decoder = @Sendable (URL) -> PetDecodedFrame?

    private struct CacheKey: Hashable {
        var namespace: String
        var path: String
    }

    private let configuredMemoryBudgetBytes: Int?
    private let originalWindowSize: Int
    private let catalog: Catalog
    private let decoder: Decoder
    private var activeMemoryBudgetBytes = 1
    private var cache: [CacheKey: PetDecodedFrame] = [:]
    private var lruOrder: [CacheKey] = []
    private var cachedBytes = 0
    private var concurrentDecodes = 0
    private var maximumConcurrentDecodes = 0

    init(
        memoryBudgetBytes: Int? = nil,
        originalWindowSize: Int = 7,
        catalog: @escaping Catalog = { pet, stateName in
            PetFrameAssetCatalog(
                frameURLs: PetAssetLocator.frameURLs(for: pet, stateName: stateName),
                coverURL: PetAssetLocator.coverURL(for: pet)
            )
        },
        decoder: @escaping Decoder = { url in PetFramePipeline.decodeImage(at: url) }
    ) {
        configuredMemoryBudgetBytes = memoryBudgetBytes.map { max(1, $0) }
        self.originalWindowSize = max(1, originalWindowSize)
        self.catalog = catalog
        self.decoder = decoder
    }

    func prepare(_ request: PetFrameLoadRequest) async throws -> PetPreparedFrames {
        activeMemoryBudgetBytes = configuredMemoryBudgetBytes
            ?? RendererBudget(quality: request.pet.quality, fpsProfile: request.fps >= 20 ? .smooth : .standard)
                .rendererBudgetMB * 1_024 * 1_024
        retainNamespaces([request.assetKey, request.assetKey + ":cover"])
        evictToBudget()

        try Task.checkCancellation()
        let assets = catalog(request.pet, request.stateName)
        let fallback = try await decodedFrame(
            at: assets.coverURL,
            namespace: request.assetKey + ":cover"
        )
        let sourceKind: PetFrameSourceKind = assets.frameURLs.isEmpty
            ? .empty
            : request.pet.quality == .original ? .ring : .eager
        let cacheLimit = sourceKind == .ring
            ? min(assets.frameURLs.count, max(originalWindowSize, request.fps >= 20 ? 9 : 7))
            : assets.frameURLs.count
        let indices = sourceKind == .ring
            ? Self.ringIndices(
                around: 0,
                frameCount: assets.frameURLs.count,
                limit: cacheLimit,
                loops: request.loops
            )
            : Array(assets.frameURLs.indices)

        var frames: [Int: PetDecodedFrame] = [:]
        for index in indices {
            try Task.checkCancellation()
            if let frame = try await decodedFrame(
                at: assets.frameURLs[index],
                namespace: request.assetKey
            ) {
                frames[index] = frame
            }
            await Task.yield()
        }

        let canvasExtent = Self.canvasExtent(frames: frames, fallback: fallback)
        return PetPreparedFrames(
            request: request,
            sourceKind: sourceKind,
            frameCount: assets.frameURLs.count,
            cacheFrameLimit: cacheLimit,
            canvasExtent: canvasExtent,
            visibleBounds: Self.canvasVisibleBounds(
                frames: frames,
                fallback: fallback,
                canvasExtent: canvasExtent
            ),
            fallback: fallback,
            frameURLs: assets.frameURLs,
            readyFrames: frames
        )
    }

    func prefetch(_ prepared: PetPreparedFrames, around index: Int) async throws -> PetPreparedFrames {
        guard prepared.sourceKind == .ring, prepared.frameCount > 0 else { return prepared }
        let indices = Self.ringIndices(
            around: index,
            frameCount: prepared.frameCount,
            limit: prepared.cacheFrameLimit,
            loops: prepared.loops
        )
        var frames: [Int: PetDecodedFrame] = [:]

        for candidate in indices {
            try Task.checkCancellation()
            if let existing = prepared.readyFrames[candidate] {
                frames[candidate] = existing
            } else if let frame = try await decodedFrame(
                at: prepared.frameURLs[candidate],
                namespace: prepared.request.assetKey
            ) {
                frames[candidate] = frame
            }
            await Task.yield()
        }

        let canvasExtent = Self.canvasExtent(frames: frames, fallback: prepared.fallback)
        let visibleBounds = prepared.visibleBounds.union(Self.canvasVisibleBounds(
            frames: frames,
            fallback: prepared.fallback,
            canvasExtent: canvasExtent
        ))
        return PetPreparedFrames(
            request: prepared.request,
            sourceKind: prepared.sourceKind,
            frameCount: prepared.frameCount,
            cacheFrameLimit: prepared.cacheFrameLimit,
            canvasExtent: canvasExtent,
            visibleBounds: visibleBounds,
            fallback: prepared.fallback,
            frameURLs: prepared.frameURLs,
            readyFrames: frames
        )
    }

    func cacheMetrics() -> PetFrameCacheMetrics {
        PetFrameCacheMetrics(
            byteCount: cachedBytes,
            frameCount: cache.count,
            maximumConcurrentDecodes: maximumConcurrentDecodes
        )
    }

    private func decodedFrame(at url: URL?, namespace: String) async throws -> PetDecodedFrame? {
        guard let url else { return nil }
        try Task.checkCancellation()
        let key = CacheKey(namespace: namespace, path: url.standardizedFileURL.path)
        if let cached = cache[key] {
            touch(key)
            return cached
        }

        concurrentDecodes += 1
        maximumConcurrentDecodes = max(maximumConcurrentDecodes, concurrentDecodes)
        let frame = decoder(url)
        concurrentDecodes -= 1
        try Task.checkCancellation()
        guard let frame else { return nil }

        cache[key] = frame
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
        let (nextBytes, overflow) = cachedBytes.addingReportingOverflow(frame.byteCost)
        cachedBytes = overflow ? Int.max : nextBytes
        evictToBudget()
        return frame
    }

    private func touch(_ key: CacheKey) {
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
    }

    private func retainNamespaces(_ namespaces: Set<String>) {
        let staleKeys = cache.keys.filter { !namespaces.contains($0.namespace) }
        guard !staleKeys.isEmpty else { return }
        let staleSet = Set(staleKeys)
        for key in staleKeys {
            if let removed = cache.removeValue(forKey: key) {
                cachedBytes = max(0, cachedBytes - removed.byteCost)
            }
        }
        lruOrder.removeAll { staleSet.contains($0) }
    }

    private func evictToBudget() {
        while cachedBytes > activeMemoryBudgetBytes, let oldest = lruOrder.first {
            lruOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                cachedBytes = max(0, cachedBytes - removed.byteCost)
            }
        }
    }

    private static func ringIndices(
        around center: Int,
        frameCount: Int,
        limit: Int,
        loops: Bool
    ) -> [Int] {
        guard frameCount > 0, limit > 0 else { return [] }
        let count = min(frameCount, limit)
        if loops {
            let normalized = (center % frameCount + frameCount) % frameCount
            return (0..<count).map { (normalized + $0) % frameCount }
        }

        let normalized = min(max(0, center), frameCount - 1)
        let start = min(normalized, max(0, frameCount - count))
        return Array(start..<(start + count))
    }

    private static func canvasExtent(
        frames: [Int: PetDecodedFrame],
        fallback: PetDecodedFrame?
    ) -> CGRect {
        let maxWidth = frames.values.map(\.pixelWidth).max() ?? fallback?.pixelWidth ?? 0
        let maxHeight = frames.values.map(\.pixelHeight).max() ?? fallback?.pixelHeight ?? 0
        return CGRect(x: 0, y: 0, width: maxWidth, height: maxHeight)
    }

    private static func canvasVisibleBounds(
        frames: [Int: PetDecodedFrame],
        fallback: PetDecodedFrame?,
        canvasExtent: CGRect
    ) -> CGRect {
        guard !canvasExtent.isEmpty else { return .zero }
        let decodedFrames = frames.values.isEmpty
            ? fallback.map { [$0] } ?? []
            : Array(frames.values)
        return decodedFrames.reduce(CGRect.null) { result, frame in
            guard !frame.visibleBounds.isEmpty else { return result }
            let centeredBounds = frame.visibleBounds.offsetBy(
                dx: max(0, (canvasExtent.width - CGFloat(frame.pixelWidth)) / 2),
                dy: 0
            )
            return result.union(centeredBounds)
        }
    }

    private nonisolated static func decodeImage(at url: URL) -> PetDecodedFrame? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
            let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        else {
            return nil
        }
        return PetDecodedFrame(
            image: CIImage(cgImage: image),
            pixelWidth: image.width,
            pixelHeight: image.height,
            visibleBounds: alphaVisibleBounds(of: image)
        )
    }

    nonisolated static func alphaVisibleBounds(of image: CGImage) -> CGRect {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return .zero }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bounds = rgba.withUnsafeMutableBytes { buffer -> CGRect in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return CGRect(x: 0, y: 0, width: width, height: height)
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let pixels = buffer.bindMemory(to: UInt8.self)
            var minX = width
            var minY = height
            var maxX = -1
            var maxY = -1
            for y in 0..<height {
                let rowStart = y * bytesPerRow
                for x in 0..<width where pixels[rowStart + x * bytesPerPixel + 3] > 2 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return .zero }
            let bottomOriginMinY = height - 1 - maxY
            return CGRect(
                x: minX,
                y: bottomOriginMinY,
                width: maxX - minX + 1,
                height: maxY - minY + 1
            )
        }
        return bounds
    }
}

final class PetFrameRenderHandoff: @unchecked Sendable {
    struct Lookup: @unchecked Sendable {
        var frame: PetDecodedFrame?
        var canvasExtent: CGRect
        var missingRingIndex: Int?
        var shouldPauseAfterDraw: Bool
        var generation: UUID
    }

    private struct State {
        var generation = UUID()
        var prepared: PetPreparedFrames?
        var playback = FramePlaybackState(stateID: "idle", enteredAt: 0)
        var priorFrame: PetDecodedFrame?
        var lastFrame: PetDecodedFrame?
    }

    private let lock = NSLock()
    private var state = State()

    func begin(generation: UUID, stateID: String, enteredAt: TimeInterval) {
        lock.lock()
        let prior = state.lastFrame
            ?? state.prepared?.fallback
            ?? state.prepared?.readyFrames.min(by: { $0.key < $1.key })?.value
            ?? state.priorFrame
        state = State(
            generation: generation,
            prepared: nil,
            playback: FramePlaybackState(stateID: stateID, enteredAt: enteredAt),
            priorFrame: prior,
            lastFrame: nil
        )
        lock.unlock()
    }

    @discardableResult
    func publish(
        _ prepared: PetPreparedFrames,
        generation: UUID,
        resetPlaybackAt time: TimeInterval? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation else { return false }
        state.prepared = prepared
        if let time {
            state.playback = FramePlaybackState(
                stateID: state.playback.stateID,
                enteredAt: time
            )
        }
        return true
    }

    func clear() {
        lock.lock()
        state.prepared = nil
        state.priorFrame = nil
        state.lastFrame = nil
        lock.unlock()
    }

    func prepared(generation: UUID) -> PetPreparedFrames? {
        lock.lock()
        defer { lock.unlock() }
        guard state.generation == generation else { return nil }
        return state.prepared
    }

    func lookup(at time: TimeInterval) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        guard let prepared = state.prepared else {
            return Lookup(
                frame: state.priorFrame,
                canvasExtent: state.priorFrame?.extent ?? .zero,
                missingRingIndex: nil,
                shouldPauseAfterDraw: false,
                generation: state.generation
            )
        }

        let scheduler = FrameScheduler(
            fps: prepared.request.fps,
            frameCount: prepared.frameCount,
            loops: prepared.loops
        )
        let index = state.playback.frameIndex(at: time, scheduler: scheduler)
        let exactFrame = prepared.readyFrame(at: index)
        let frame = exactFrame
            ?? state.lastFrame
            ?? prepared.fallback
            ?? state.priorFrame
            ?? prepared.readyFrames.min(by: { $0.key < $1.key })?.value
        if let exactFrame {
            state.lastFrame = exactFrame
        }
        return Lookup(
            frame: frame,
            canvasExtent: prepared.canvasExtent,
            missingRingIndex: prepared.sourceKind == .ring && exactFrame == nil ? index : nil,
            shouldPauseAfterDraw: exactFrame != nil
                && state.playback.hasCompleted(at: time, scheduler: scheduler),
            generation: state.generation
        )
    }
}

private final class PetRenderMetrics: @unchecked Sendable {
    struct Snapshot: Sendable {
        var drawCount: Int
        var measurementSeconds: Double
        var observedFramesPerSecond: Double
        var peakDrawableTextureAllocatedBytes: Int
        var peakMetalDeviceAllocatedBytes: Int
    }

    private let lock = NSLock()
    private var startedAt = CACurrentMediaTime()
    private var drawCount = 0
    private var peakDrawableTextureAllocatedBytes = 0
    private var peakMetalDeviceAllocatedBytes = 0

    func reset(at time: TimeInterval = CACurrentMediaTime()) {
        lock.lock()
        startedAt = time
        drawCount = 0
        peakDrawableTextureAllocatedBytes = 0
        peakMetalDeviceAllocatedBytes = 0
        lock.unlock()
    }

    func recordDraw(drawableTextureAllocatedBytes: Int, metalDeviceAllocatedBytes: Int) {
        lock.lock()
        drawCount += 1
        peakDrawableTextureAllocatedBytes = max(
            peakDrawableTextureAllocatedBytes,
            drawableTextureAllocatedBytes
        )
        peakMetalDeviceAllocatedBytes = max(
            peakMetalDeviceAllocatedBytes,
            metalDeviceAllocatedBytes
        )
        lock.unlock()
    }

    func snapshot(at time: TimeInterval = CACurrentMediaTime()) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let duration = max(0.001, time - startedAt)
        return Snapshot(
            drawCount: drawCount,
            measurementSeconds: duration,
            observedFramesPerSecond: Double(drawCount) / duration,
            peakDrawableTextureAllocatedBytes: peakDrawableTextureAllocatedBytes,
            peakMetalDeviceAllocatedBytes: peakMetalDeviceAllocatedBytes
        )
    }
}

struct PetRendererTelemetry: Sendable {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["APC_RENDERER_TELEMETRY_PATH"]?.isEmpty == false
    }

    var petID: String
    var quality: String
    var state: String
    var fpsProfile: String
    var fps: Int
    var active: Bool
    var sourceKind: String
    var frameCount: Int
    var runtimeCacheFrameLimit: Int
    var canvasWidth: Double
    var canvasHeight: Double
    var estimatedRuntimeCacheMB: Double
    var readyDecodedBytes: Int
    var readyDecodedFrameCount: Int
    var pipelineCacheBytes: Int
    var pipelineCacheFrameCount: Int
    var peakDrawableTextureAllocatedBytes = 0
    var peakMetalDeviceAllocatedBytes = 0
    var actualDrawCount = 0
    var measurementSeconds = 0.0
    var observedFramesPerSecond = 0.0

    init(
        prepared: PetPreparedFrames,
        fpsProfile: FpsProfile,
        active: Bool,
        cacheMetrics: PetFrameCacheMetrics
    ) {
        petID = prepared.request.pet.id
        quality = prepared.request.pet.quality.rawValue
        state = prepared.request.stateName
        self.fpsProfile = fpsProfile.rawValue
        fps = prepared.request.fps
        self.active = active
        sourceKind = prepared.sourceKind.rawValue
        frameCount = prepared.frameCount
        runtimeCacheFrameLimit = prepared.cacheFrameLimit
        canvasWidth = prepared.canvasExtent.width
        canvasHeight = prepared.canvasExtent.height
        estimatedRuntimeCacheMB = Double(prepared.canvasExtent.width)
            * Double(prepared.canvasExtent.height)
            * 4
            * Double(prepared.cacheFrameLimit)
            / 1_024
            / 1_024
        readyDecodedBytes = prepared.estimatedReadyBytes
        readyDecodedFrameCount = prepared.readyFrameCount
        pipelineCacheBytes = cacheMetrics.byteCount
        pipelineCacheFrameCount = cacheMetrics.frameCount
    }

    func writeIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["APC_RENDERER_TELEMETRY_PATH"],
              !path.isEmpty else { return }
        let payload: [String: Any] = [
            "pet_id": petID,
            "quality": quality,
            "state": state,
            "fps_profile": fpsProfile,
            "fps": fps,
            "active": active,
            "source_kind": sourceKind,
            "frame_count": frameCount,
            "runtime_cache_frame_limit": runtimeCacheFrameLimit,
            "canvas_width": canvasWidth,
            "canvas_height": canvasHeight,
            "estimated_runtime_cache_mb": estimatedRuntimeCacheMB,
            "ready_decoded_bytes": readyDecodedBytes,
            "ready_decoded_frame_count": readyDecodedFrameCount,
            "pipeline_cache_bytes": pipelineCacheBytes,
            "pipeline_cache_frame_count": pipelineCacheFrameCount,
            "peak_drawable_texture_allocated_bytes": peakDrawableTextureAllocatedBytes,
            "peak_metal_device_allocated_bytes": peakMetalDeviceAllocatedBytes,
            "actual_draw_count": actualDrawCount,
            "measurement_seconds": measurementSeconds,
            "observed_fps": observedFramesPerSecond,
            "decode_pipeline": "actor",
            "draw_reads_disk": false
        ]
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            // Validation telemetry must never affect rendering.
        }
    }
}

@MainActor
protocol PetRendererLifecycle: AnyObject {
    func suspendPipeline()
    func resumePipeline(in view: MTKView)
}

private final class PetFramePrefetchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequest: String?

    func begin(generation: UUID, index: Int) -> Bool {
        let request = "\(generation.uuidString):\(index)"
        lock.lock()
        defer { lock.unlock() }
        guard activeRequest != request else { return false }
        activeRequest = request
        return true
    }

    func finish(generation: UUID, index: Int) {
        let request = "\(generation.uuidString):\(index)"
        lock.lock()
        if activeRequest == request {
            activeRequest = nil
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        activeRequest = nil
        lock.unlock()
    }
}

final class PetMetalFrameRenderer: NSObject, MTKViewDelegate, PetRendererLifecycle, @unchecked Sendable {
    private struct Configuration: Sendable {
        var pet: PetSummary
        var stateName: String
        var stateEntryID: String
        var fpsProfile: FpsProfile
        var active: Bool

        var assetKey: String {
            [
                pet.id,
                pet.petpackPath,
                pet.coverPath,
                pet.createdAt,
                pet.quality.rawValue,
                stateName,
                stateEntryID,
                fpsProfile.rawValue
            ].joined(separator: ":")
        }
    }

    private let pipeline = PetFramePipeline()
    private let handoff = PetFrameRenderHandoff()
    private let prefetchGate = PetFramePrefetchGate()
    private let renderMetrics = PetRenderMetrics()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private var currentAssetKey = ""
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var lastConfiguration: Configuration?
    private var suspended = false
    private var playbackEnteredAt = CACurrentMediaTime()
    private var hasPublishedCurrentEntry = false
    private var visualEnvelopeHandler: ((OverlayPetVisualEnvelope?) -> Void)?
    private var publishedVisualEnvelope: OverlayPetVisualEnvelope?

    @MainActor
    func makeView() -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        if let device {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }

        let view = MTKView(frame: .zero, device: device)
        view.delegate = self
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = true
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.preferredFramesPerSecond = FpsProfile.standard.fps
        return view
    }

    @MainActor
    func configure(
        view: MTKView,
        pet: PetSummary,
        stateName: String,
        stateEntryID: String,
        fpsProfile: FpsProfile,
        active: Bool,
        onVisualEnvelopeChanged: @escaping (OverlayPetVisualEnvelope?) -> Void
    ) {
        let configuration = Configuration(
            pet: pet,
            stateName: stateName,
            stateEntryID: stateEntryID,
            fpsProfile: fpsProfile,
            active: active
        )
        visualEnvelopeHandler = onVisualEnvelopeChanged
        lastConfiguration = configuration
        view.preferredFramesPerSecond = fpsProfile.fps

        guard active else {
            suspended = true
            cancelLoading(releaseFrames: true)
            view.isPaused = true
            return
        }

        let isNewEntry = configuration.assetKey != currentAssetKey
        guard isNewEntry || suspended else { return }
        currentAssetKey = configuration.assetKey
        suspended = false
        if isNewEntry {
            hasPublishedCurrentEntry = false
            publishedVisualEnvelope = nil
            visualEnvelopeHandler?(nil)
        }
        beginLoading(
            configuration,
            in: view,
            resetsPlayback: isNewEntry || !hasPublishedCurrentEntry
        )
    }

    @MainActor
    func suspendPipeline() {
        suspended = true
        cancelLoading(releaseFrames: true)
    }

    @MainActor
    func resumePipeline(in view: MTKView) {
        guard suspended, let configuration = lastConfiguration, configuration.active else { return }
        suspended = false
        beginLoading(
            configuration,
            in: view,
            resetsPlayback: !hasPublishedCurrentEntry
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let commandQueue,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        clear(drawable: drawable, commandBuffer: commandBuffer)
        let lookup = handoff.lookup(at: CACurrentMediaTime())

        if let decoded = lookup.frame, let ciContext {
            render(
                decoded.image,
                canvasExtent: lookup.canvasExtent,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                context: ciContext,
                drawableSize: view.drawableSize
            )
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        renderMetrics.recordDraw(
            drawableTextureAllocatedBytes: drawable.texture.allocatedSize,
            metalDeviceAllocatedBytes: view.device?.currentAllocatedSize ?? 0
        )

        if let missingIndex = lookup.missingRingIndex {
            requestPrefetch(index: missingIndex, generation: lookup.generation, in: view)
        }
        if lookup.shouldPauseAfterDraw {
            view.isPaused = true
        }
    }

    @MainActor
    private func beginLoading(
        _ configuration: Configuration,
        in view: MTKView,
        resetsPlayback: Bool
    ) {
        cancelLoading(releaseFrames: false)
        generation = UUID()
        let loadGeneration = generation
        let loops = configuration.stateName != "start" && configuration.stateName != "done"
        let request = PetFrameLoadRequest(
            pet: configuration.pet,
            stateName: configuration.stateName,
            fps: configuration.fpsProfile.fps,
            loops: loops
        )
        if resetsPlayback {
            playbackEnteredAt = CACurrentMediaTime()
        }
        handoff.begin(
            generation: loadGeneration,
            stateID: configuration.stateEntryID,
            enteredAt: playbackEnteredAt
        )
        renderMetrics.reset()
        view.isPaused = false

        loadTask = Task { [weak self, pipeline, handoff] in
            do {
                let prepared = try await pipeline.prepare(request)
                try Task.checkCancellation()
                guard let self, self.generation == loadGeneration, !self.suspended else { return }
                let playbackResetTime = resetsPlayback ? CACurrentMediaTime() : nil
                guard handoff.publish(
                    prepared,
                    generation: loadGeneration,
                    resetPlaybackAt: playbackResetTime
                ) else { return }
                if let playbackResetTime {
                    self.playbackEnteredAt = playbackResetTime
                }
                self.hasPublishedCurrentEntry = true
                self.publishVisualEnvelope(prepared.visualEnvelope)
                self.renderMetrics.reset()

                let cacheMetrics = await pipeline.cacheMetrics()
                let telemetry = PetRendererTelemetry(
                    prepared: prepared,
                    fpsProfile: configuration.fpsProfile,
                    active: configuration.active,
                    cacheMetrics: cacheMetrics
                )
                self.scheduleTelemetry(telemetry)
                view.isPaused = !configuration.active || prepared.frameCount <= 1
                view.draw()
            } catch is CancellationError {
                // A newer pet/state owns the renderer now.
            } catch {
                // Keep the previous/cover frame if an individual asset cannot decode.
            }
        }
    }

    private func requestPrefetch(index: Int, generation: UUID, in view: MTKView) {
        guard prefetchGate.begin(generation: generation, index: index) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let prepared = handoff.prepared(generation: generation), !suspended else {
                prefetchGate.finish(generation: generation, index: index)
                return
            }
            prefetchTask?.cancel()
            prefetchTask = Task { [weak self, pipeline, handoff, prefetchGate] in
                defer { prefetchGate.finish(generation: generation, index: index) }
                do {
                    let advanced = try await pipeline.prefetch(prepared, around: index)
                    try Task.checkCancellation()
                    guard let self, self.generation == generation, !self.suspended else { return }
                    guard handoff.publish(advanced, generation: generation) else { return }
                    self.publishVisualEnvelope(advanced.visualEnvelope)
                    view.draw()
                } catch {
                    // Cancellation or a corrupt frame simply leaves the prior frame visible.
                }
            }
        }
    }

    @MainActor
    private func cancelLoading(releaseFrames: Bool) {
        loadTask?.cancel()
        prefetchTask?.cancel()
        telemetryTask?.cancel()
        loadTask = nil
        prefetchTask = nil
        telemetryTask = nil
        prefetchGate.reset()
        if releaseFrames {
            handoff.clear()
        }
    }

    @MainActor
    private func scheduleTelemetry(_ base: PetRendererTelemetry) {
        telemetryTask?.cancel()
        guard PetRendererTelemetry.isRequested else { return }
        let renderMetrics = renderMetrics
        telemetryTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                let measurement = renderMetrics.snapshot()
                var telemetry = base
                telemetry.actualDrawCount = measurement.drawCount
                telemetry.measurementSeconds = measurement.measurementSeconds
                telemetry.observedFramesPerSecond = measurement.observedFramesPerSecond
                telemetry.peakDrawableTextureAllocatedBytes = measurement.peakDrawableTextureAllocatedBytes
                telemetry.peakMetalDeviceAllocatedBytes = measurement.peakMetalDeviceAllocatedBytes
                telemetry.writeIfRequested()
                if measurement.measurementSeconds >= 60 {
                    return
                }
            }
        }
    }

    private func render(
        _ image: CIImage,
        canvasExtent: CGRect,
        to texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        context: CIContext,
        drawableSize: CGSize
    ) {
        let bounds = CGRect(origin: .zero, size: drawableSize)
        let imageExtent = image.extent
        let canvas = canvasExtent.isEmpty ? imageExtent : canvasExtent
        guard drawableSize.width > 0,
              drawableSize.height > 0,
              imageExtent.width > 0,
              imageExtent.height > 0,
              canvas.width > 0,
              canvas.height > 0 else { return }

        let scale = min(drawableSize.width / canvas.width, drawableSize.height / canvas.height)
        let fittedSize = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        let fittedOrigin = CGPoint(
            x: (drawableSize.width - fittedSize.width) / 2,
            y: (drawableSize.height - fittedSize.height) / 2
        )
        let imageOriginInCanvas = CGPoint(
            x: max(0, (canvas.width - imageExtent.width) / 2),
            y: 0
        )
        let fittedImage = image
            .transformed(by: CGAffineTransform(translationX: -imageExtent.minX, y: -imageExtent.minY))
            .transformed(by: CGAffineTransform(translationX: imageOriginInCanvas.x, y: imageOriginInCanvas.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: fittedOrigin.x, y: fittedOrigin.y))
        context.render(
            fittedImage,
            to: texture,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: colorSpace
        )
    }

    private func clear(drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        descriptor.colorAttachments[0].storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
    }

    @MainActor
    private func publishVisualEnvelope(_ envelope: OverlayPetVisualEnvelope?) {
        guard envelope != publishedVisualEnvelope else { return }
        publishedVisualEnvelope = envelope
        visualEnvelopeHandler?(envelope)
    }
}
