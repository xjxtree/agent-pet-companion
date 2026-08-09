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
    var timing: PetStateTiming

    var assetKey: String {
        let durations = timing.frameDurationsMS.map(String.init).joined(separator: ",")
        let repeatCount = timing.playback.entryRepeatCount.map(String.init) ?? ""
        let settleIndex = timing.playback.settleFrameIndex.map(String.init) ?? ""
        let cooldown = timing.playback.cooldownMS?
            .map(String.init)
            .joined(separator: ",") ?? ""
        let components: [String] = [
            pet.id,
            pet.petpackPath,
            pet.coverPath,
            pet.createdAt,
            pet.quality.rawValue,
            stateName,
            durations,
            timing.playback.mode.rawValue,
            repeatCount,
            settleIndex,
            cooldown,
            String(timing.reducedMotionFrameIndex)
        ]
        return components.joined(separator: ":")
    }
}

enum PetFrameSourceKind: String, Sendable {
    case empty
    case eager
}

enum PetFramePipelineError: Error, Equatable {
    case frameCountMismatch(expected: Int, actual: Int)
}

struct PetDecodedFrame: @unchecked Sendable {
    let image: CIImage
    let pixelWidth: Int
    let pixelHeight: Int
    let visibleBounds: CGRect
    let alphaMask: OverlayPetAlphaMask?
    let hitTestIdentity: UUID
    let byteCost: Int

    init(
        image: CIImage,
        pixelWidth: Int,
        pixelHeight: Int,
        visibleBounds: CGRect? = nil,
        alphaMask: OverlayPetAlphaMask? = nil,
        hitTestIdentity: UUID = UUID()
    ) {
        self.image = image
        let resolvedPixelWidth = max(0, pixelWidth)
        let resolvedPixelHeight = max(0, pixelHeight)
        self.pixelWidth = resolvedPixelWidth
        self.pixelHeight = resolvedPixelHeight
        let extent = CGRect(x: 0, y: 0, width: resolvedPixelWidth, height: resolvedPixelHeight)
        self.visibleBounds = visibleBounds.map { $0.intersection(extent) } ?? extent
        self.alphaMask = alphaMask.flatMap { mask in
            mask.pixelWidth == resolvedPixelWidth && mask.pixelHeight == resolvedPixelHeight
                ? mask
                : nil
        }
        self.hitTestIdentity = hitTestIdentity
        let (pixels, pixelOverflow) = resolvedPixelWidth.multipliedReportingOverflow(
            by: resolvedPixelHeight
        )
        let (rgbaBytes, rgbaOverflow) = pixels.multipliedReportingOverflow(by: 4)
        let (totalBytes, totalOverflow) = rgbaBytes.addingReportingOverflow(
            self.alphaMask?.storageByteCount ?? 0
        )
        byteCost = pixelOverflow || rgbaOverflow || totalOverflow ? Int.max : totalBytes
    }

    var extent: CGRect {
        CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
    }
}

struct PetPreparedFrames: @unchecked Sendable {
    let request: PetFrameLoadRequest
    let sourceKind: PetFrameSourceKind
    let sourceFrameCount: Int
    let frameCount: Int
    let timeline: FrameTimeline
    let canvasExtent: CGRect
    let visibleBounds: CGRect
    let fallback: PetDecodedFrame?
    fileprivate let readyFrames: [Int: PetDecodedFrame]
    fileprivate let periodicCooldownSampler: PetFramePipeline.PeriodicCooldownSampler

    var readyFrameCount: Int { readyFrames.count }
    var playbackMode: PetPlaybackMode { request.timing.playback.mode }
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

    fileprivate func samplePeriodicCooldownMS() -> Int {
        let range = periodicCooldownRange
        let sampled = periodicCooldownSampler(range)
        precondition(range.contains(sampled), "periodic cooldown sampler escaped authored bounds")
        return sampled
    }

    fileprivate var periodicCooldownRange: ClosedRange<Int> {
        guard request.timing.playback.mode == .periodic,
              let cooldownMS = request.timing.playback.cooldownMS,
              cooldownMS.count == 2
        else {
            preconditionFailure("periodic playback requires an authored cooldown range")
        }
        return cooldownMS[0]...cooldownMS[1]
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
    typealias PeriodicCooldownSampler = @Sendable (ClosedRange<Int>) -> Int

    private struct CacheKey: Hashable {
        var namespace: String
        var path: String
    }

    private let configuredMemoryBudgetBytes: Int?
    private let catalog: Catalog
    private let decoder: Decoder
    private let periodicCooldownSampler: PeriodicCooldownSampler
    private var activeMemoryBudgetBytes = 1
    private var cache: [CacheKey: PetDecodedFrame] = [:]
    private var lruOrder: [CacheKey] = []
    private var cachedBytes = 0
    private var concurrentDecodes = 0
    private var maximumConcurrentDecodes = 0

    init(
        memoryBudgetBytes: Int? = nil,
        catalog: @escaping Catalog = { pet, stateName in
            PetFrameAssetCatalog(
                frameURLs: PetAssetLocator.frameURLs(for: pet, stateName: stateName),
                coverURL: PetAssetLocator.coverURL(for: pet)
            )
        },
        decoder: @escaping Decoder = { url in PetFramePipeline.decodeImage(at: url) },
        periodicCooldownSampler: @escaping PeriodicCooldownSampler = {
            Int.random(in: $0)
        }
    ) {
        configuredMemoryBudgetBytes = memoryBudgetBytes.map { max(1, $0) }
        self.catalog = catalog
        self.decoder = decoder
        self.periodicCooldownSampler = periodicCooldownSampler
    }

    func prepare(_ request: PetFrameLoadRequest) async throws -> PetPreparedFrames {
        let timeline = FrameTimeline(state: request.timing)
        activeMemoryBudgetBytes = configuredMemoryBudgetBytes
            ?? RendererBudget(
                quality: request.pet.quality,
                frameCount: timeline.frameCount
            )
                .rendererBudgetMB * 1_024 * 1_024
        retainNamespaces([request.assetKey, request.assetKey + ":cover"])
        evictToBudget()

        try Task.checkCancellation()
        let assets = catalog(request.pet, request.stateName)
        guard assets.frameURLs.count == timeline.frameCount else {
            throw PetFramePipelineError.frameCountMismatch(
                expected: timeline.frameCount,
                actual: assets.frameURLs.count
            )
        }
        let fallback = try await decodedFrame(
            at: assets.coverURL,
            namespace: request.assetKey + ":cover"
        )
        let sourceKind: PetFrameSourceKind = assets.frameURLs.isEmpty
            ? .empty
            : .eager

        var frames: [Int: PetDecodedFrame] = [:]
        for index in assets.frameURLs.indices {
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
            sourceFrameCount: assets.frameURLs.count,
            frameCount: timeline.frameCount,
            timeline: timeline,
            canvasExtent: canvasExtent,
            visibleBounds: Self.canvasVisibleBounds(
                frames: frames,
                fallback: fallback,
                canvasExtent: canvasExtent
            ),
            fallback: fallback,
            readyFrames: frames,
            periodicCooldownSampler: periodicCooldownSampler
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
        let alphaAnalysis = alphaAnalysis(of: image)
        return PetDecodedFrame(
            image: CIImage(cgImage: image),
            pixelWidth: image.width,
            pixelHeight: image.height,
            visibleBounds: alphaAnalysis.visibleBounds,
            alphaMask: alphaAnalysis.mask
        )
    }

    nonisolated static func alphaVisibleBounds(of image: CGImage) -> CGRect {
        alphaAnalysis(of: image).visibleBounds
    }

    nonisolated static func alphaHitTestMask(of image: CGImage) -> OverlayPetAlphaMask? {
        alphaAnalysis(of: image).mask
    }

    private struct AlphaAnalysis {
        var visibleBounds: CGRect
        var mask: OverlayPetAlphaMask?
    }

    private nonisolated static func alphaAnalysis(of image: CGImage) -> AlphaAnalysis {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return AlphaAnalysis(visibleBounds: .zero, mask: nil)
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        let analysis = rgba.withUnsafeMutableBytes { buffer -> AlphaAnalysis in
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
                return AlphaAnalysis(
                    visibleBounds: CGRect(x: 0, y: 0, width: width, height: height),
                    mask: nil
                )
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let pixels = buffer.bindMemory(to: UInt8.self)
            guard let maskByteCount = OverlayPetAlphaMask.requiredByteCount(
                pixelWidth: width,
                pixelHeight: height
            ) else {
                return AlphaAnalysis(
                    visibleBounds: CGRect(x: 0, y: 0, width: width, height: height),
                    mask: nil
                )
            }
            var opaqueBits = [UInt8](repeating: 0, count: maskByteCount)
            var minX = width
            var minY = height
            var maxX = -1
            var maxY = -1
            for y in 0..<height {
                let rowStart = y * bytesPerRow
                for x in 0..<width where pixels[rowStart + x * bytesPerPixel + 3]
                    > OverlayPetAlphaMask.interactionAlphaThreshold {
                    let pixelIndex = y * width + x
                    opaqueBits[pixelIndex >> 3] |= UInt8(1 << (pixelIndex & 7))
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            let mask = OverlayPetAlphaMask(
                pixelWidth: width,
                pixelHeight: height,
                opaqueBits: opaqueBits
            )
            guard maxX >= minX, maxY >= minY else {
                return AlphaAnalysis(visibleBounds: .zero, mask: mask)
            }
            let bottomOriginMinY = height - 1 - maxY
            return AlphaAnalysis(
                visibleBounds: CGRect(
                    x: minX,
                    y: bottomOriginMinY,
                    width: maxX - minX + 1,
                    height: maxY - minY + 1
                ),
                mask: mask
            )
        }
        return analysis
    }
}

private struct PeriodicCycleSchedule: Sendable {
    struct Position: Sendable {
        let phaseMS: Double
        let cycleDurationMS: Double
    }

    private var cycleStartMS = 0.0
    private var cooldownMS: Int?
    /// A long process stall must not materialize every random cycle while the
    /// renderer lock is held. Nearby cycles retain exact authored sampling;
    /// beyond this prefix, playback re-anchors at the observed wall clock.
    private static let maximumVariableCycleAdvancesPerLookup = 8

    mutating func reset() {
        cycleStartMS = 0
        cooldownMS = nil
    }

    mutating func position(
        elapsedMS: Double,
        authoredDurationMS: Int,
        cooldownRange: ClosedRange<Int>,
        sampleCooldown: () -> Int
    ) -> Position {
        let authoredDuration = Double(authoredDurationMS)
        let elapsed = max(0, elapsedMS)

        if cooldownRange.lowerBound == cooldownRange.upperBound {
            let fixedCooldown = cooldownRange.lowerBound
            let cycleDuration = authoredDuration + Double(fixedCooldown)
            let completedCycles = floor(elapsed / cycleDuration)
            cycleStartMS = completedCycles * cycleDuration
            cooldownMS = fixedCooldown
            return Position(
                phaseMS: max(0, elapsed - cycleStartMS),
                cycleDurationMS: cycleDuration
            )
        }

        if cooldownMS == nil {
            cooldownMS = sampleCooldown()
        }
        var advances = 0
        while let currentCooldown = cooldownMS {
            let cycleDuration = authoredDuration + Double(currentCooldown)
            let cycleEnd = cycleStartMS + cycleDuration
            guard elapsed >= cycleEnd else {
                return Position(
                    phaseMS: max(0, elapsed - cycleStartMS),
                    cycleDurationMS: cycleDuration
                )
            }
            guard advances < Self.maximumVariableCycleAdvancesPerLookup else {
                // There is no observable value in replaying random choices for
                // cycles that elapsed while rendering was stalled. Establish a
                // fresh current cycle at the wall-clock observation instead.
                let currentCooldown = sampleCooldown()
                cycleStartMS = elapsed
                cooldownMS = currentCooldown
                return Position(
                    phaseMS: 0,
                    cycleDurationMS: authoredDuration + Double(currentCooldown)
                )
            }
            cycleStartMS = cycleEnd
            cooldownMS = sampleCooldown()
            advances += 1
        }
        preconditionFailure("periodic cooldown schedule did not produce a sample")
    }
}

final class PetFrameRenderHandoff: @unchecked Sendable {
    struct Lookup: @unchecked Sendable {
        var frame: PetDecodedFrame?
        var canvasExtent: CGRect
        var shouldPauseAfterDraw: Bool
        var generation: UUID
        var stateEntryID: String

        var frameHitTest: OverlayPetFrameHitTest? {
            guard let frame, let alphaMask = frame.alphaMask else { return nil }
            let resolvedCanvas = canvasExtent.isEmpty ? frame.extent : canvasExtent
            guard !resolvedCanvas.isEmpty else { return nil }
            return OverlayPetFrameHitTest(
                frameID: frame.hitTestIdentity,
                canvasSize: resolvedCanvas.size,
                alphaMask: alphaMask
            )
        }
    }

    private struct State {
        var generation = UUID()
        var prepared: PetPreparedFrames?
        var playback = FramePlaybackState(stateID: "idle", enteredAt: 0)
        var priorFrame: PetDecodedFrame?
        var lastFrame: PetDecodedFrame?
        var holdsTerminalFrame = false
        var periodicSchedule = PeriodicCycleSchedule()
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
            lastFrame: nil,
            holdsTerminalFrame: false
        )
        lock.unlock()
    }

    func restartPlayback(stateID: String, enteredAt: TimeInterval) {
        lock.lock()
        state.playback = FramePlaybackState(stateID: stateID, enteredAt: enteredAt)
        state.lastFrame = nil
        state.holdsTerminalFrame = false
        state.periodicSchedule.reset()
        lock.unlock()
    }

    /// Gives a previously entered finite action a new semantic owner while
    /// forcing the authored terminal pose instead of replaying or retaining
    /// an unrelated intermediate frame.
    func holdTerminalFrame(stateID: String) {
        lock.lock()
        state.playback = FramePlaybackState(
            stateID: stateID,
            enteredAt: state.playback.enteredAt
        )
        state.holdsTerminalFrame = true
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
        state.periodicSchedule.reset()
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
        state.periodicSchedule.reset()
        lock.unlock()
    }

    func lookup(at time: TimeInterval, reducedMotion: Bool) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        guard let prepared = state.prepared else {
            return Lookup(
                frame: state.priorFrame,
                canvasExtent: state.priorFrame?.extent ?? .zero,
                shouldPauseAfterDraw: false,
                generation: state.generation,
                stateEntryID: state.playback.stateID
            )
        }

        let index: Int
        if reducedMotion {
            index = prepared.timeline.reducedMotionFrameIndex
        } else if state.holdsTerminalFrame {
            index = prepared.timeline.settleFrameIndex ?? max(0, prepared.frameCount - 1)
        } else if prepared.timeline.playback.mode == .periodic {
            let elapsedMS = max(0, time - state.playback.enteredAt) * 1_000
            let position = state.periodicSchedule.position(
                elapsedMS: elapsedMS,
                authoredDurationMS: prepared.timeline.totalDurationMS,
                cooldownRange: prepared.periodicCooldownRange,
                sampleCooldown: { prepared.samplePeriodicCooldownMS() }
            )
            index = position.phaseMS < Double(prepared.timeline.totalDurationMS)
                ? prepared.timeline.authoredFrameIndex(elapsedMS: Int(position.phaseMS))
                : prepared.timeline.settleFrameIndex ?? max(0, prepared.frameCount - 1)
        } else {
            index = state.playback.frameIndex(
                at: time,
                timeline: prepared.timeline,
                reducedMotion: false
            )
        }
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
            shouldPauseAfterDraw: exactFrame != nil
                && (reducedMotion
                    || state.holdsTerminalFrame
                    || state.playback.hasCompleted(at: time, timeline: prepared.timeline)),
            generation: state.generation,
            stateEntryID: state.playback.stateID
        )
    }

    /// Returns the next authored frame boundary after `time`. The renderer
    /// schedules a single draw at that boundary instead of running a display
    /// link between changes. Wall-clock phase is recomputed after every wake,
    /// so a stalled process skips missed frames rather than catching them up.
    func nextBoundaryDelay(after time: TimeInterval, reducedMotion: Bool) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard !reducedMotion,
              !state.holdsTerminalFrame,
              let prepared = state.prepared
        else { return nil }

        let timeline = prepared.timeline
        let total = Double(timeline.totalDurationMS)
        guard total > 0 else { return nil }
        let elapsed = max(0, time - state.playback.enteredAt) * 1_000

        func nextAuthoredBoundary(after phase: Double) -> Double {
            Double(
                timeline.cumulativeMS.first(where: { Double($0) > phase })
                    ?? timeline.totalDurationMS
            )
        }

        let delayMS: Double?
        switch timeline.playback.mode {
        case .loop:
            let phase = elapsed.truncatingRemainder(dividingBy: total)
            delayMS = nextAuthoredBoundary(after: phase) - phase
        case .onceThenReturn:
            guard elapsed < total else { return nil }
            delayMS = nextAuthoredBoundary(after: elapsed) - elapsed
        case .periodic:
            let position = state.periodicSchedule.position(
                elapsedMS: elapsed,
                authoredDurationMS: timeline.totalDurationMS,
                cooldownRange: prepared.periodicCooldownRange,
                sampleCooldown: { prepared.samplePeriodicCooldownMS() }
            )
            if position.phaseMS < total {
                delayMS = nextAuthoredBoundary(after: position.phaseMS) - position.phaseMS
            } else {
                delayMS = position.cycleDurationMS - position.phaseMS
            }
        case .burstThenSettle, .burstThenIdle:
            let activeDuration = total
                * Double(max(1, timeline.playback.entryRepeatCount ?? 1))
            guard elapsed < activeDuration else { return nil }
            let completedCycles = floor(elapsed / total)
            let phase = elapsed - completedCycles * total
            let nextAbsoluteBoundary = completedCycles * total
                + nextAuthoredBoundary(after: phase)
            delayMS = min(activeDuration, nextAbsoluteBoundary) - elapsed
        }

        guard let delayMS, delayMS > 0 else { return nil }
        // Wake just after the authored boundary so millisecond quantization in
        // FrameTimeline cannot result in an early duplicate draw.
        return max(0.001, delayMS / 1_000 + 0.0005)
    }
}

private final class PetRenderMetrics: @unchecked Sendable {
    struct Snapshot: Sendable {
        var drawCount: Int
        var measurementSeconds: Double
        var observedDrawsPerSecond: Double
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
            observedDrawsPerSecond: Double(drawCount) / duration,
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
    var frameDurationsMS: [Int]
    var totalDurationMS: Int
    var playbackMode: String
    var entryRepeatCount: Int?
    var settleFrameIndex: Int?
    var cooldownMS: [Int]?
    var periodicCooldownMS: Int?
    var reducedMotionFrameIndex: Int
    var sourceFrameCount: Int
    var active: Bool
    var sourceKind: String
    var frameCount: Int
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
    var observedDrawsPerSecond = 0.0

    init(
        prepared: PetPreparedFrames,
        active: Bool,
        cacheMetrics: PetFrameCacheMetrics
    ) {
        petID = prepared.request.pet.id
        quality = prepared.request.pet.quality.rawValue
        state = prepared.request.stateName
        frameDurationsMS = prepared.timeline.durationsMS
        totalDurationMS = prepared.timeline.totalDurationMS
        playbackMode = prepared.timeline.playback.mode.rawValue
        entryRepeatCount = prepared.timeline.playback.entryRepeatCount
        settleFrameIndex = prepared.timeline.settleFrameIndex
        cooldownMS = prepared.timeline.playback.cooldownMS
        periodicCooldownMS = prepared.timeline.playback.mode == .periodic
            ? prepared.timeline.periodicCooldownMS
            : nil
        reducedMotionFrameIndex = prepared.timeline.reducedMotionFrameIndex
        sourceFrameCount = prepared.sourceFrameCount
        self.active = active
        sourceKind = prepared.sourceKind.rawValue
        frameCount = prepared.frameCount
        canvasWidth = prepared.canvasExtent.width
        canvasHeight = prepared.canvasExtent.height
        estimatedRuntimeCacheMB = Double(prepared.canvasExtent.width)
            * Double(prepared.canvasExtent.height)
            * 4
            * Double(prepared.frameCount)
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
        var payload: [String: Any] = [
            "pet_id": petID,
            "quality": quality,
            "state": state,
            "frame_durations_ms": frameDurationsMS,
            "total_duration_ms": totalDurationMS,
            "playback_mode": playbackMode,
            "reduced_motion_frame_index": reducedMotionFrameIndex,
            "source_frame_count": sourceFrameCount,
            "active": active,
            "source_kind": sourceKind,
            "frame_count": frameCount,
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
            "observed_draws_per_second": observedDrawsPerSecond,
            "decode_pipeline": "actor",
            "draw_reads_disk": false
        ]
        if let entryRepeatCount {
            payload["entry_repeat_count"] = entryRepeatCount
        }
        if let settleFrameIndex {
            payload["settle_frame_index"] = settleFrameIndex
        }
        if let cooldownMS {
            payload["cooldown_ms"] = cooldownMS
        }
        if let periodicCooldownMS {
            payload["periodic_cooldown_ms"] = periodicCooldownMS
        }
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

struct PetPlaybackEntryTransition: Equatable, Sendable {
    var isNewEntry: Bool
    var shouldRestartPlayback: Bool
}

struct PetFramePresentationContext: Equatable, Sendable {
    var renderGeneration: UUID
    var stateEntryID: String
}

struct PetFramePresentationToken: Equatable, Sendable {
    let epoch: UInt64
    let sequence: UInt64
    let context: PetFramePresentationContext
}

enum PetFramePresentationResolution: Equatable, Sendable {
    /// The drawable reached its presentation callback. A nil hit test is a
    /// real presentation result (for example, an all-transparent or
    /// mask-less frame), not an absent callback.
    case presented(OverlayPetFrameHitTest?)
    /// The command buffer did not complete successfully. Because that
    /// drawable was not presented, the previously presented frame (and its
    /// mask) remains authoritative.
    case failed
    /// Metal reported a presented callback without a nonzero on-screen
    /// presentation time, which means the drawable was skipped.
    case skipped

    var hitTest: OverlayPetFrameHitTest? {
        switch self {
        case let .presented(hitTest): hitTest
        case .failed, .skipped: nil
        }
    }
}

enum PetFramePresentationDecision: Equatable, Sendable {
    case rejected
    case acceptedUnchanged
    case publish(OverlayPetFrameHitTest?)
}

struct PetFramePresentationSnapshot: Equatable, Sendable {
    let epoch: UInt64
    let latestAcceptedSequence: UInt64?
    let context: PetFramePresentationContext?
    let hitTest: OverlayPetFrameHitTest?
}

/// Thread-safe ordering gate between MTKView's draw path, Metal's callback
/// queues, and the MainActor-owned overlay model. Tokens are reserved only for
/// the currently activated handoff context. Resolution is deliberately
/// MainActor-only so no callback queue can directly mutate AppStore state.
final class PetFramePresentationCoordinator: @unchecked Sendable {
    private struct State {
        var epoch: UInt64 = 0
        var nextSequence: UInt64 = 0
        var latestAcceptedSequence: UInt64?
        var context: PetFramePresentationContext?
        var hitTest: OverlayPetFrameHitTest?
    }

    private let lock = NSLock()
    private var state = State()

    /// Invalidates every in-flight callback and clears the interaction mask.
    /// The renderer calls this before changing the handoff state, leaving no
    /// interval in which an old lookup can reserve a token for the new epoch.
    @MainActor
    @discardableResult
    func invalidate() -> PetFramePresentationSnapshot {
        withLock { state in
            state.epoch = Self.incrementing(state.epoch)
            state.latestAcceptedSequence = nil
            state.context = nil
            state.hitTest = nil
            return Self.snapshot(of: state)
        }
    }

    /// Activates the exact generation/state pair that draw lookups must
    /// report. Activation owns a fresh epoch even when a decoded generation is
    /// reused for another semantic state entry.
    @MainActor
    @discardableResult
    func activate(
        _ context: PetFramePresentationContext
    ) -> PetFramePresentationSnapshot {
        withLock { state in
            state.epoch = Self.incrementing(state.epoch)
            state.latestAcceptedSequence = nil
            state.context = context
            state.hitTest = nil
            return Self.snapshot(of: state)
        }
    }

    /// Assigns a globally monotonic submission sequence. A lookup produced
    /// before or during reconfiguration cannot reserve against the new epoch
    /// because its handoff context will not match.
    func reserve(
        for observedContext: PetFramePresentationContext
    ) -> PetFramePresentationToken? {
        withLock { state in
            guard state.context == observedContext else { return nil }
            state.nextSequence = Self.incrementing(state.nextSequence)
            return PetFramePresentationToken(
                epoch: state.epoch,
                sequence: state.nextSequence,
                context: observedContext
            )
        }
    }

    /// Accepts only a still-current epoch/context and a newer presentation
    /// sequence. A successfully presented sequence advances even when its
    /// resolved mask is nil or equal to the current mask, preventing a late
    /// older callback from restoring stale interaction geometry.
    @MainActor
    func resolve(
        _ resolution: PetFramePresentationResolution,
        token: PetFramePresentationToken
    ) -> PetFramePresentationDecision {
        withLock { state in
            guard token.epoch == state.epoch,
                  token.context == state.context
            else {
                return .rejected
            }

            // A failed command buffer never presented its drawable. Do not
            // let its higher submission sequence suppress an older callback
            // that did actually present, and do not clear the still-visible
            // prior frame's mask.
            switch resolution {
            case .failed, .skipped:
                return token.sequence > (state.latestAcceptedSequence ?? 0)
                    ? .acceptedUnchanged
                    : .rejected
            case .presented:
                break
            }

            guard token.sequence > (state.latestAcceptedSequence ?? 0) else {
                return .rejected
            }

            state.latestAcceptedSequence = token.sequence
            let resolvedHitTest = resolution.hitTest
            guard resolvedHitTest != state.hitTest else {
                return .acceptedUnchanged
            }
            state.hitTest = resolvedHitTest
            return .publish(resolvedHitTest)
        }
    }

    @MainActor
    var snapshot: PetFramePresentationSnapshot {
        withLock { Self.snapshot(of: $0) }
    }

    @MainActor
    func replayCurrent(
        to handler: @MainActor (OverlayPetFrameHitTest?) -> Void
    ) {
        // Read under the coordinator lock, then invoke outside it so a handler
        // can synchronously trigger layout without re-entering the lock.
        handler(snapshot.hitTest)
    }

    private func withLock<Result>(
        _ body: (inout State) -> Result
    ) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    private static func snapshot(of state: State) -> PetFramePresentationSnapshot {
        PetFramePresentationSnapshot(
            epoch: state.epoch,
            latestAcceptedSequence: state.latestAcceptedSequence,
            context: state.context,
            hitTest: state.hitTest
        )
    }

    private static func incrementing(_ value: UInt64) -> UInt64 {
        precondition(value < .max, "Pet frame presentation counter exhausted")
        return value + 1
    }
}

/// Remembers recently entered finite animations so canonical A/B/A session
/// rotation does not replay A's authored entry action. Looping and periodic
/// states always restart for a genuinely new semantic entry.
struct PetPlaybackEntryHistory: Sendable {
    private let capacity: Int
    private(set) var currentEntryID: String?
    private var enteredFiniteEntryIDs: Set<String> = []
    private var finiteEntryOrder: [String] = []

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    mutating func transition(
        to entryID: String,
        playbackMode: PetPlaybackMode
    ) -> PetPlaybackEntryTransition {
        guard entryID != currentEntryID else {
            return PetPlaybackEntryTransition(
                isNewEntry: false,
                shouldRestartPlayback: false
            )
        }
        currentEntryID = entryID

        guard playbackMode == .burstThenSettle
                || playbackMode == .burstThenIdle
                || playbackMode == .onceThenReturn
        else {
            return PetPlaybackEntryTransition(
                isNewEntry: true,
                shouldRestartPlayback: true
            )
        }
        guard enteredFiniteEntryIDs.insert(entryID).inserted else {
            return PetPlaybackEntryTransition(
                isNewEntry: true,
                shouldRestartPlayback: false
            )
        }

        finiteEntryOrder.append(entryID)
        if finiteEntryOrder.count > capacity {
            let evicted = finiteEntryOrder.removeFirst()
            enteredFiniteEntryIDs.remove(evicted)
        }
        return PetPlaybackEntryTransition(
            isNewEntry: true,
            shouldRestartPlayback: true
        )
    }
}

final class PetMetalFrameRenderer: NSObject, MTKViewDelegate, PetRendererLifecycle, @unchecked Sendable {
    private struct PresentationConfigurationIdentity: Equatable, Sendable {
        var assetKey: String
        var stateEntryID: String
        var active: Bool
        var reduceMotion: Bool
    }

    private struct Configuration: Sendable {
        var pet: PetSummary
        var stateName: String
        var stateEntryID: String
        var active: Bool
        var reduceMotion: Bool

        var timing: PetStateTiming {
            pet.timing(for: stateName)
        }

        var playbackMode: PetPlaybackMode {
            timing.playback.mode
        }

        var timelineIdentity: String {
            [
                assetKey,
                stateEntryID,
            ].joined(separator: ":")
        }

        var assetKey: String {
            PetFrameLoadRequest(
                pet: pet,
                stateName: stateName,
                timing: timing
            ).assetKey
        }

        var presentationIdentity: PresentationConfigurationIdentity {
            PresentationConfigurationIdentity(
                assetKey: assetKey,
                stateEntryID: stateEntryID,
                active: active,
                reduceMotion: reduceMotion
            )
        }
    }

    private let pipeline = PetFramePipeline()
    private let handoff = PetFrameRenderHandoff()
    private let renderMetrics = PetRenderMetrics()
    private let presentationCoordinator = PetFramePresentationCoordinator()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private var currentAssetKey = ""
    private var playbackEntryHistory = PetPlaybackEntryHistory()
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var lastConfiguration: Configuration?
    private var suspended = false
    private var playbackEnteredAt = CACurrentMediaTime()
    private var hasPublishedCurrentEntry = false
    private var visualEnvelopeHandler: ((OverlayPetVisualEnvelope?) -> Void)?
    private var publishedVisualEnvelope: OverlayPetVisualEnvelope?
    private var frameContentHandler: (@MainActor (Bool) -> Void)?
    private var frameContentHandlerGeneration: UInt64 = 0
    private var publishedFrameContent = false
    private var frameHitTestHandler: (@MainActor (OverlayPetFrameHitTest?) -> Void)?
    private var playbackCompletionHandler: (@MainActor (String, PetPlaybackMode) -> Void)?
    private var completedPlaybackEntryID: String?

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
        return view
    }

    @MainActor
    func configure(
        view: MTKView,
        pet: PetSummary,
        stateName: String,
        stateEntryID: String,
        active: Bool,
        reduceMotion: Bool,
        onPlaybackCompleted: @escaping @MainActor (String, PetPlaybackMode) -> Void = { _, _ in },
        onVisualEnvelopeChanged: @escaping (OverlayPetVisualEnvelope?) -> Void,
        onFrameContentChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        onFrameHitTestChanged: @escaping @MainActor (OverlayPetFrameHitTest?) -> Void = { _ in }
    ) {
        let configuration = Configuration(
            pet: pet,
            stateName: stateName,
            stateEntryID: stateEntryID,
            active: active,
            reduceMotion: reduceMotion
        )
        let priorConfiguration = lastConfiguration
        let preservesPlaybackTimeline = priorConfiguration?.timelineIdentity
            == configuration.timelineIdentity
        let previouslyPublishedCurrentEntry = hasPublishedCurrentEntry
        let isPresentationReconfiguration = lastConfiguration?.presentationIdentity
            != configuration.presentationIdentity
        if isPresentationReconfiguration {
            // Invalidate before replacing the handoff state or callback. This
            // prevents both an old Metal callback and the new SwiftUI closure
            // from relabelling a stale frame as the new semantic entry.
            invalidateFramePresentations(notifyHandler: false)
            publishedFrameContent = false
        }
        visualEnvelopeHandler = onVisualEnvelopeChanged
        playbackCompletionHandler = onPlaybackCompleted
        if priorConfiguration?.stateEntryID != configuration.stateEntryID {
            completedPlaybackEntryID = nil
        }
        lastConfiguration = configuration
        setFrameContentHandler(onFrameContentChanged)
        setFrameHitTestHandler(onFrameHitTestChanged)

        guard active else {
            suspended = true
            cancelLoading(releaseFrames: true)
            view.isPaused = true
            return
        }

        let isNewAsset = configuration.assetKey != currentAssetKey
        let playbackTransition = playbackEntryHistory.transition(
            to: configuration.stateEntryID,
            playbackMode: configuration.playbackMode
        )
        guard isNewAsset
                || playbackTransition.isNewEntry
                || suspended
                || isPresentationReconfiguration
        else { return }
        currentAssetKey = configuration.assetKey
        let wasSuspended = suspended
        suspended = false
        if isNewAsset {
            hasPublishedCurrentEntry = false
        }
        if isNewAsset || wasSuspended {
            let holdsPreviouslyEnteredFiniteState = playbackTransition.isNewEntry
                && !playbackTransition.shouldRestartPlayback
            beginLoading(
                configuration,
                in: view,
                resetsPlayback: !holdsPreviouslyEnteredFiniteState
                    && (playbackTransition.shouldRestartPlayback
                        || !previouslyPublishedCurrentEntry
                        || !preservesPlaybackTimeline),
                holdsTerminalFrame: holdsPreviouslyEnteredFiniteState
            )
            return
        }

        if !playbackTransition.isNewEntry {
            activateFramePresentations(
                generation: generation,
                stateEntryID: configuration.stateEntryID
            )
            view.draw()
            scheduleNextDraw(
                in: view,
                configuration: configuration,
                generation: generation
            )
            return
        }

        guard playbackTransition.shouldRestartPlayback else {
            // A previously seen finite action must remain on its settle frame.
            // Give that already-decoded frame the new semantic entry identity
            // and submit it once so the new epoch receives a real presented
            // callback without replaying the animation.
            handoff.holdTerminalFrame(stateID: configuration.stateEntryID)
            activateFramePresentations(
                generation: generation,
                stateEntryID: configuration.stateEntryID
            )
            view.draw()
            return
        }

        // The same visual state may receive many hook events. Restart playback
        // when its semantic entry changes, but keep decoded frames and the
        // visual envelope in place so the pet and bubble do not jump.
        playbackEnteredAt = CACurrentMediaTime()
        handoff.restartPlayback(
            stateID: configuration.stateEntryID,
            enteredAt: playbackEnteredAt
        )
        activateFramePresentations(
            generation: generation,
            stateEntryID: configuration.stateEntryID
        )
        renderMetrics.reset()
        view.draw()
        scheduleNextDraw(
            in: view,
            configuration: configuration,
            generation: generation
        )
    }

    @MainActor
    func suspendPipeline() {
        suspended = true
        invalidateFramePresentations(notifyHandler: true)
        publishFrameContent(false)
        cancelLoading(releaseFrames: true)
    }

    @MainActor
    func dismantlePipeline() {
        suspended = true
        // A successor representable with the same pet/state may already have
        // installed its handler. Invalidate this renderer's callbacks without
        // sending a teardown nil that could clear the successor's mask.
        invalidateFramePresentations(notifyHandler: false)
        cancelLoading(releaseFrames: true)
        frameHitTestHandler = nil
        frameContentHandlerGeneration &+= 1
        frameContentHandler = nil
        playbackCompletionHandler = nil
    }

    @MainActor
    func resumePipeline(in view: MTKView) {
        guard suspended, let configuration = lastConfiguration, configuration.active else { return }
        suspended = false
        beginLoading(
            configuration,
            in: view,
            resetsPlayback: !hasPublishedCurrentEntry,
            holdsTerminalFrame: false
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let commandQueue,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let lookup = handoff.lookup(
            at: CACurrentMediaTime(),
            reducedMotion: lastConfiguration?.reduceMotion ?? false
        )
        let presentationContext = PetFramePresentationContext(
            renderGeneration: lookup.generation,
            stateEntryID: lookup.stateEntryID
        )
        guard let presentationToken = presentationCoordinator.reserve(
            for: presentationContext
        ) else {
            // Reconfiguration may race an already-scheduled draw. Do not submit
            // that mismatched lookup; the newly activated context will request
            // its own draw.
            return
        }

        clear(drawable: drawable, commandBuffer: commandBuffer)
        let presentedFrameHitTest: OverlayPetFrameHitTest?
        let presentedFrameHasContent: Bool
        if let decoded = lookup.frame, let ciContext {
            render(
                decoded.image,
                canvasExtent: lookup.canvasExtent,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                context: ciContext,
                drawableSize: view.drawableSize
            )
            presentedFrameHitTest = lookup.frameHitTest
            presentedFrameHasContent = true
        } else {
            presentedFrameHitTest = nil
            presentedFrameHasContent = false
        }
        let completedPlaybackMode: PetPlaybackMode?
        if lookup.shouldPauseAfterDraw,
           lastConfiguration?.reduceMotion == false,
           let mode = lastConfiguration?.playbackMode,
           mode == .burstThenIdle || mode == .onceThenReturn
        {
            completedPlaybackMode = mode
        } else {
            completedPlaybackMode = nil
        }

        // A successful command-buffer completion only means the GPU work
        // finished. Publish from the drawable's presented callback so pointer
        // geometry follows the frame that actually reached the display.
        // Keep this explicitly Sendable instead of relying on the SDK import.
        // The macOS 15 release SDK does not annotate this callback, so an
        // unannotated closure inherits MainActor here and traps when
        // CoreAnimation invokes it on CAMetalLayerEventListenerQueue.
        drawable.addPresentedHandler { @Sendable [weak self] presentedDrawable in
            self?.enqueueFramePresentationResolution(
                presentedDrawable.presentedTime > 0
                    ? .presented(presentedFrameHitTest)
                    : .skipped,
                presentedFrameHasContent: presentedFrameHasContent,
                completedPlaybackMode: completedPlaybackMode,
                token: presentationToken
            )
        }
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            guard completedBuffer.status != .completed else { return }
            self?.enqueueFramePresentationResolution(
                .failed,
                presentedFrameHasContent: presentedFrameHasContent,
                completedPlaybackMode: nil,
                token: presentationToken
            )
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        renderMetrics.recordDraw(
            drawableTextureAllocatedBytes: drawable.texture.allocatedSize,
            metalDeviceAllocatedBytes: view.device?.currentAllocatedSize ?? 0
        )

    }

    nonisolated private func enqueueFramePresentationResolution(
        _ resolution: PetFramePresentationResolution,
        presentedFrameHasContent: Bool,
        completedPlaybackMode: PetPlaybackMode?,
        token: PetFramePresentationToken
    ) {
        Task { @MainActor [weak self] in
            self?.resolveFramePresentation(
                resolution,
                presentedFrameHasContent: presentedFrameHasContent,
                completedPlaybackMode: completedPlaybackMode,
                token: token
            )
        }
    }

    @MainActor
    private func resolveFramePresentation(
        _ resolution: PetFramePresentationResolution,
        presentedFrameHasContent: Bool,
        completedPlaybackMode: PetPlaybackMode?,
        token: PetFramePresentationToken
    ) {
        let decision = presentationCoordinator.resolve(
            resolution,
            token: token
        )
        guard decision != .rejected else { return }
        if case .presented = resolution {
            publishFrameContent(presentedFrameHasContent)
        }
        if case let .publish(hitTest) = decision {
            frameHitTestHandler?(hitTest)
        }
        if case .presented = resolution,
           let completedPlaybackMode,
           completedPlaybackEntryID != token.context.stateEntryID,
           lastConfiguration?.stateEntryID == token.context.stateEntryID
        {
            completedPlaybackEntryID = token.context.stateEntryID
            playbackCompletionHandler?(
                token.context.stateEntryID,
                completedPlaybackMode
            )
        }
    }

    @MainActor
    private func beginLoading(
        _ configuration: Configuration,
        in view: MTKView,
        resetsPlayback: Bool,
        holdsTerminalFrame: Bool
    ) {
        cancelLoading(releaseFrames: false)
        generation = UUID()
        let loadGeneration = generation
        let request = PetFrameLoadRequest(
            pet: configuration.pet,
            stateName: configuration.stateName,
            timing: configuration.timing
        )
        if resetsPlayback {
            playbackEnteredAt = CACurrentMediaTime()
        }
        handoff.begin(
            generation: loadGeneration,
            stateID: configuration.stateEntryID,
            enteredAt: playbackEnteredAt
        )
        activateFramePresentations(
            generation: loadGeneration,
            stateEntryID: configuration.stateEntryID
        )
        renderMetrics.reset()
        view.isPaused = true

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
                if holdsTerminalFrame {
                    handoff.holdTerminalFrame(stateID: configuration.stateEntryID)
                }
                self.hasPublishedCurrentEntry = true
                self.publishVisualEnvelope(prepared.visualEnvelope)
                self.renderMetrics.reset()

                let cacheMetrics = await pipeline.cacheMetrics()
                let telemetry = PetRendererTelemetry(
                    prepared: prepared,
                    active: configuration.active,
                    cacheMetrics: cacheMetrics
                )
                self.scheduleTelemetry(telemetry)
                view.draw()
                self.scheduleNextDraw(
                    in: view,
                    configuration: configuration,
                    generation: loadGeneration
                )
            } catch is CancellationError {
                // A newer pet/state owns the renderer now.
            } catch {
                // Keep the previous/cover frame if an individual asset cannot decode.
            }
        }
    }

    @MainActor
    private func scheduleNextDraw(
        in view: MTKView,
        configuration: Configuration,
        generation scheduledGeneration: UUID
    ) {
        playbackTask?.cancel()
        guard !suspended,
              configuration.active,
              lastConfiguration?.presentationIdentity == configuration.presentationIdentity,
              generation == scheduledGeneration,
              let delay = handoff.nextBoundaryDelay(
                  after: CACurrentMediaTime(),
                  reducedMotion: configuration.reduceMotion
              )
        else { return }

        playbackTask = Task { @MainActor [weak self, weak view] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, let view,
                  !self.suspended,
                  self.generation == scheduledGeneration,
                  self.lastConfiguration?.presentationIdentity
                    == configuration.presentationIdentity
            else { return }

            view.draw()
            self.scheduleNextDraw(
                in: view,
                configuration: configuration,
                generation: scheduledGeneration
            )
        }
    }

    @MainActor
    private func cancelLoading(releaseFrames: Bool) {
        loadTask?.cancel()
        playbackTask?.cancel()
        telemetryTask?.cancel()
        loadTask = nil
        playbackTask = nil
        telemetryTask = nil
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
                telemetry.observedDrawsPerSecond = measurement.observedDrawsPerSecond
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
    private func setFrameHitTestHandler(
        _ handler: @escaping @MainActor (OverlayPetFrameHitTest?) -> Void
    ) {
        frameHitTestHandler = handler
        // SwiftUI may replace the closure without changing the renderer
        // configuration. Replay only the coordinator's last accepted
        // presentation, never a fresh playback lookup.
        presentationCoordinator.replayCurrent(to: handler)
    }

    @MainActor
    private func setFrameContentHandler(
        _ handler: @escaping @MainActor (Bool) -> Void
    ) {
        frameContentHandler = handler
        frameContentHandlerGeneration &+= 1
        let handlerGeneration = frameContentHandlerGeneration
        // SwiftUI may replace this closure without changing renderer assets.
        // Replay only content that reached a drawable presentation callback,
        // and never write through a representable callback while updateNSView
        // is still on the stack. A newer closure or dismantle invalidates this
        // scheduled replay before it reaches SwiftUI state.
        Task { @MainActor [weak self] in
            guard let self,
                  self.frameContentHandlerGeneration == handlerGeneration
            else { return }
            self.frameContentHandler?(self.publishedFrameContent)
        }
    }

    @MainActor
    private func publishFrameContent(_ hasContent: Bool) {
        guard publishedFrameContent != hasContent else { return }
        publishedFrameContent = hasContent
        frameContentHandler?(hasContent)
    }

    @MainActor
    private func activateFramePresentations(
        generation: UUID,
        stateEntryID: String
    ) {
        presentationCoordinator.activate(PetFramePresentationContext(
            renderGeneration: generation,
            stateEntryID: stateEntryID
        ))
        frameHitTestHandler?(nil)
    }

    @MainActor
    private func invalidateFramePresentations(notifyHandler: Bool) {
        presentationCoordinator.invalidate()
        if notifyHandler {
            frameHitTestHandler?(nil)
        }
    }

    @MainActor
    private func publishVisualEnvelope(_ envelope: OverlayPetVisualEnvelope?) {
        guard envelope != publishedVisualEnvelope else { return }
        publishedVisualEnvelope = envelope
        visualEnvelopeHandler?(envelope)
    }
}
