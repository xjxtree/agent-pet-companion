import AppKit
import AgentPetCompanionCore
import Foundation
import Testing
@testable import AgentPetCompanion

@Suite(.serialized)
struct InitialAppearanceBootstrapTests {
    @Test
    func windowGateOnlyHoldsWhileAuthoritativeAppearanceIsPending() {
        #expect(!InitialAppearanceWindowGate.shouldRevealWindow(for: .pending))
        #expect(InitialAppearanceWindowGate.shouldRevealWindow(for: .authoritative))
        #expect(InitialAppearanceWindowGate.shouldRevealWindow(for: .unavailable))
        #expect(InitialAppearanceWindowGate.action(
            for: .pending,
            theme: .system,
            hasRevealed: false
        ) == .conceal)
        #expect(InitialAppearanceWindowGate.action(
            for: .authoritative,
            theme: .dark,
            hasRevealed: false
        ) == .reveal(appearanceName: .darkAqua))
        #expect(InitialAppearanceWindowGate.action(
            for: .authoritative,
            theme: .light,
            hasRevealed: false
        ) == .reveal(appearanceName: .aqua))
        #expect(InitialAppearanceWindowGate.action(
            for: .unavailable,
            theme: .dark,
            hasRevealed: false
        ) == .reveal(appearanceName: nil))
        #expect(InitialAppearanceWindowGate.action(
            for: .pending,
            theme: .dark,
            hasRevealed: true
        ) == .noChange)
    }

    @MainActor
    @Test
    func healthyBootstrapAppliesVersionedBehaviorBeforePublishingReadiness() async throws {
        let probe = InitialAppearanceProbe()
        let darkBehavior = BehaviorSettings(appearanceTheme: .dark)
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                fetchInitialBehavior: { _ in
                    probe.events.append("behavior.get")
                    return try Self.versionedBehaviorPayload(darkBehavior, revision: "7")
                },
                refreshSnapshot: { _ in },
                onReady: { store in
                    probe.events.append("onReady")
                    probe.readinessObservedByOnReady = store.initialAppearanceReadiness
                }
            ),
            applicationAppearanceApplier: { theme in
                guard let store = probe.store else { return }
                probe.events.append("appearance.apply")
                probe.appearanceObservation = AppearanceApplicationObservation(
                    theme: theme,
                    behavior: store.behavior,
                    revision: store.behaviorRevision,
                    readiness: store.initialAppearanceReadiness
                )
            },
            overlayPresenter: { _, _ in probe.overlayPresentations += 1 }
        )
        probe.store = store

        await store.bootstrapIfNeeded()

        #expect(probe.events == ["behavior.get", "appearance.apply", "onReady"])
        #expect(probe.appearanceObservation == AppearanceApplicationObservation(
            theme: .dark,
            behavior: darkBehavior,
            revision: "7",
            readiness: .pending
        ))
        #expect(probe.readinessObservedByOnReady == .authoritative)
        #expect(store.initialAppearanceReadiness == .authoritative)
        #expect(probe.overlayPresentations == 0)
    }

    @MainActor
    @Test
    func behaviorFetchFailureKeepsTheGateThroughSnapshotAttemptThenFallsBack() async {
        let probe = InitialAppearanceProbe()
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                fetchInitialBehavior: { _ in throw InitialAppearanceTestError.unavailable },
                refreshSnapshot: { _ in },
                onReady: { store in
                    probe.readinessObservedByOnReady = store.initialAppearanceReadiness
                }
            ),
            applicationAppearanceApplier: { _ in probe.appearanceApplications += 1 },
            overlayPresenter: { _, _ in probe.overlayPresentations += 1 }
        )

        await store.bootstrapIfNeeded()

        #expect(store.initialAppearanceReadiness == .unavailable)
        #expect(probe.readinessObservedByOnReady == .pending)
        #expect(probe.appearanceApplications == 0)
        #expect(probe.overlayPresentations == 0)
    }

    @MainActor
    @Test
    func behaviorFetchFailureReleasesTheWindowBeforeAStalledReadyPipelineCompletes() async {
        let gate = InitialAppearanceReadyGate()
        let fallback = InitialAppearanceFallbackProbe()
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                fetchInitialBehavior: { _ in throw InitialAppearanceTestError.unavailable },
                refreshSnapshot: { _ in },
                onReady: { _ in await gate.waitForRelease() }
            ),
            initialAppearanceFallbackSleeper: { delay in
                await fallback.record(delay)
            }
        )

        let bootstrap = Task { @MainActor in
            await store.bootstrapIfNeeded()
        }
        await gate.waitUntilStarted()

        let deadline = ContinuousClock.now + .seconds(1)
        while store.initialAppearanceReadiness == .pending,
              ContinuousClock.now < deadline
        {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.initialAppearanceReadiness == .unavailable)
        #expect(await fallback.delays() == [AppStore.initialAppearanceFallbackDelay])
        #expect(AppStore.initialAppearanceFallbackDelay <= .seconds(1))
        await gate.release()
        await bootstrap.value
    }

    @MainActor
    @Test
    func appearanceFallbackStartsBeforePetCoreStartupCompletes() async {
        let startupGate = InitialAppearanceReadyGate()
        let fallback = InitialAppearanceFallbackProbe()
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: {
                    await startupGate.waitForRelease()
                    return .alreadyHealthy
                },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            initialAppearanceFallbackSleeper: { delay in
                await fallback.record(delay)
            }
        )

        let bootstrap = Task { @MainActor in
            await store.bootstrapIfNeeded()
        }
        await startupGate.waitUntilStarted()
        for _ in 0 ..< 20 where store.initialAppearanceReadiness == .pending {
            await Task.yield()
        }

        #expect(store.initialAppearanceReadiness == .unavailable)
        #expect(await fallback.delays() == [AppStore.initialAppearanceFallbackDelay])

        await startupGate.release()
        await bootstrap.value
    }

    @MainActor
    @Test
    func managedRuntimeUpgradeUsesTheBrandedBlockingStateFromBootstrapStart() async {
        let startupGate = InitialAppearanceReadyGate()
        let defaults = UserDefaults(
            suiteName: "InitialAppearanceBootstrapTests.\(UUID().uuidString)"
        )!
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: {
                    await startupGate.waitForRelease()
                    return .alreadyHealthy
                },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            productConvergenceNoticePreferences: ProductConvergenceNoticePreferences(
                defaults: defaults
            ),
            productConvergenceManifest: Self.releaseManifest(),
            productConvergenceUpgradeEvidence: { _ in true }
        )

        let bootstrap = Task { @MainActor in
            await store.bootstrapIfNeeded()
        }
        await startupGate.waitUntilStarted()

        #expect(store.appUpdateConvergenceState == .updating)
        #expect(store.shouldBlockForAppUpdateConvergence)

        await startupGate.release()
        await bootstrap.value
    }

    @MainActor
    @Test
    func concurrentSnapshotCannotPresentOverlayUntilInitialReadyPipelineFinishes() async throws {
        let seedGate = InitialAppearanceReadyGate()
        let probe = InitialAppearanceProbe()
        let behavior = BehaviorSettings(appearanceTheme: .dark)
        let snapshot = try Self.stateSnapshotPayload(
            behavior: behavior,
            behaviorRevision: "7",
            pets: []
        )
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                fetchInitialBehavior: { _ in
                    try Self.versionedBehaviorPayload(behavior, revision: "7")
                },
                refreshSnapshot: { store in
                    try store.applyStateSnapshot(snapshot)
                },
                onReady: { store in
                    await seedGate.waitForRelease()
                    _ = await store.refresh()
                }
            ),
            overlayPresenter: { _, _ in probe.overlayPresentations += 1 }
        )

        let bootstrap = Task { @MainActor in
            await store.bootstrapIfNeeded()
        }
        await seedGate.waitUntilStarted()

        #expect(await store.refresh())
        #expect(store.hasLoadedStateSnapshot)
        #expect(probe.overlayPresentations == 0)

        await seedGate.release()
        await bootstrap.value
        #expect(probe.overlayPresentations == 1)
    }

    @MainActor
    @Test
    func delayedInitialBehaviorCannotOverwriteAnAuthoritativeConcurrentSnapshot() async throws {
        let behaviorGate = InitialAppearanceReadyGate()
        let probe = InitialAppearanceProbe()
        let prefetchedBehavior = BehaviorSettings(appearanceTheme: .dark)
        let snapshotBehavior = BehaviorSettings(appearanceTheme: .light)
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                fetchInitialBehavior: { _ in
                    await behaviorGate.waitForRelease()
                    return try Self.versionedBehaviorPayload(prefetchedBehavior, revision: "7")
                },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            overlayPresenter: { _, _ in probe.overlayPresentations += 1 }
        )

        let bootstrap = Task { @MainActor in
            await store.bootstrapIfNeeded()
        }
        await behaviorGate.waitUntilStarted()
        try store.applyStateSnapshot(Self.stateSnapshotPayload(
            behavior: snapshotBehavior,
            behaviorRevision: "8",
            pets: []
        ))

        #expect(store.behavior == snapshotBehavior)
        #expect(store.behaviorRevision == "8")
        #expect(store.initialAppearanceReadiness == .authoritative)

        await behaviorGate.release()
        await bootstrap.value

        #expect(store.behavior == snapshotBehavior)
        #expect(store.behaviorRevision == "8")
        #expect(probe.overlayPresentations == 1)
    }

    @MainActor
    @Test
    func userRecoveryAfterInitialFailureRunsTheFullBootstrapPipeline() async throws {
        let startup = InitialBootstrapRaceProbe()
        let pipeline = InitialBootstrapPipelineProbe()
        let behaviorPayload = try Self.versionedBehaviorPayload(
            BehaviorSettings(appearanceTheme: .dark),
            revision: "7"
        )
        let snapshotPayload = try Self.stateSnapshotPayload(
            behavior: BehaviorSettings(appearanceTheme: .dark),
            behaviorRevision: "7",
            pets: []
        )
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { await startup.ensureRunning() },
                recover: { await startup.recover() },
                fetchInitialBehavior: { _ in
                    pipeline.events.append("behavior.get")
                    return behaviorPayload
                },
                refreshSnapshot: { store in
                    pipeline.events.append("snapshot")
                    try store.applyStateSnapshot(snapshotPayload)
                },
                onReady: { store in
                    pipeline.events.append("seed")
                    _ = await store.refresh()
                }
            ),
            overlayPresenter: { _, _ in pipeline.events.append("overlay") }
        )

        await store.bootstrapIfNeeded()
        #expect(await store.recoverServiceConnection())
        await store.bootstrapIfNeeded()

        let counts = await startup.counts()
        #expect(counts.ensure == 1)
        #expect(counts.recover == 1)
        #expect(pipeline.events == ["behavior.get", "seed", "snapshot", "overlay"])
    }

    @MainActor
    @Test
    func userRecoveryJoinsAnAutomaticInitialBootstrapAndRunsTheFullPipelineOnce() async throws {
        let startup = InitialBootstrapRaceProbe()
        let pipeline = InitialBootstrapPipelineProbe()
        let behaviorPayload = try Self.versionedBehaviorPayload(
            BehaviorSettings(appearanceTheme: .dark),
            revision: "7"
        )
        let snapshotPayload = try Self.stateSnapshotPayload(
            behavior: BehaviorSettings(appearanceTheme: .dark),
            behaviorRevision: "7",
            pets: []
        )
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { await startup.ensureRunning() },
                recover: { await startup.recover() },
                fetchInitialBehavior: { _ in
                    pipeline.events.append("behavior.get")
                    return behaviorPayload
                },
                refreshSnapshot: { store in
                    pipeline.events.append("snapshot")
                    try store.applyStateSnapshot(snapshotPayload)
                },
                onReady: { store in
                    pipeline.events.append("seed")
                    _ = await store.refresh()
                }
            ),
            overlayPresenter: { _, _ in pipeline.events.append("overlay") }
        )

        await store.bootstrapIfNeeded()

        let automaticRetry = Task { @MainActor in
            await store.bootstrapIfNeeded()
        }
        await startup.waitUntilSecondEnsureStarted()
        let userRecovery = Task { @MainActor in
            await store.recoverServiceConnection()
        }
        try? await Task.sleep(for: .milliseconds(20))
        await startup.releaseSecondEnsure()

        await automaticRetry.value
        #expect(await userRecovery.value)
        await store.bootstrapIfNeeded()

        let counts = await startup.counts()
        #expect(counts.ensure == 2)
        #expect(counts.recover == 0)
        #expect(pipeline.events == ["behavior.get", "seed", "snapshot", "overlay"])
    }

    @MainActor
    @Test
    func petCoreStartupFailureAlsoReleasesTheWindowGateToFallbackAppearance() async {
        let probe = InitialAppearanceProbe()
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .failed(reason: "offline") },
                recover: { .failed(reason: "offline") },
                fetchInitialBehavior: { _ in
                    probe.initialBehaviorRequests += 1
                    return [:]
                },
                refreshSnapshot: { _ in },
                onReady: { _ in probe.readyCallbacks += 1 }
            ),
            applicationAppearanceApplier: { _ in probe.appearanceApplications += 1 },
            overlayPresenter: { _, _ in probe.overlayPresentations += 1 }
        )

        await store.bootstrapIfNeeded()

        #expect(store.initialAppearanceReadiness == .unavailable)
        #expect(probe.initialBehaviorRequests == 0)
        #expect(probe.readyCallbacks == 0)
        #expect(probe.appearanceApplications == 0)
        #expect(probe.overlayPresentations == 0)
    }

    @MainActor
    @Test
    func bootstrapDoesNotBecomeReadyUntilAnAuthoritativeSnapshotLoads() async throws {
        let probe = InitialAppearanceProbe()
        let snapshot = try Self.stateSnapshotPayload(
            behavior: BehaviorSettings(appearanceTheme: .system),
            behaviorRevision: "1",
            pets: []
        )
        var readyAttempts = 0
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { store in
                    readyAttempts += 1
                    if readyAttempts == 2 {
                        try? store.applyStateSnapshot(snapshot)
                    }
                },
                requiresAuthoritativeSnapshotOnReady: true
            ),
            overlayPresenter: { _, _ in probe.overlayPresentations += 1 }
        )

        await store.bootstrapIfNeeded()

        #expect(readyAttempts == 1)
        #expect(!store.hasLoadedStateSnapshot)
        #expect(store.petCoreOperationalState == .offline)
        #expect(store.serviceStatusText == "PetCore 状态同步失败")
        #expect(probe.overlayPresentations == 0)

        #expect(await store.recoverServiceConnection())
        #expect(readyAttempts == 2)
        #expect(store.hasLoadedStateSnapshot)
        #expect(store.petCoreOperationalState == .online)
        #expect(probe.overlayPresentations == 1)
    }

    @MainActor
    @Test
    func completeSnapshotFinallyArbitratesAppearanceAndOnlyThenPresentsOverlay() async throws {
        let probe = InitialAppearanceProbe()
        let prefetchedBehavior = BehaviorSettings(appearanceTheme: .dark)
        let snapshotBehavior = BehaviorSettings(appearanceTheme: .light)
        let pet = PetSummary(
            id: "pet_snapshot",
            name: "Snapshot Pet",
            style: "semi-realistic",
            quality: .high,
            renderSize: RenderSize(width: 384, height: 416),
            petpackPath: "/tmp/pet_snapshot.petpack",
            coverPath: "/tmp/cover.png",
            active: true,
            createdAt: "2026-07-21T00:00:00Z"
        )
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                fetchInitialBehavior: { _ in
                    try Self.versionedBehaviorPayload(prefetchedBehavior, revision: "7")
                },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            applicationAppearanceApplier: { theme in
                guard let store = probe.store else { return }
                probe.appearanceApplications += 1
                probe.appearanceObservation = AppearanceApplicationObservation(
                    theme: theme,
                    behavior: store.behavior,
                    revision: store.behaviorRevision,
                    readiness: store.initialAppearanceReadiness
                )
            },
            overlayPresenter: { _, store in
                probe.overlayPresentations += 1
                probe.overlayObservation = OverlayPresentationObservation(
                    hasLoadedStateSnapshot: store.hasLoadedStateSnapshot,
                    behavior: store.behavior,
                    revision: store.behaviorRevision,
                    petIDs: store.pets.map(\.id)
                )
            }
        )
        probe.store = store
        await store.bootstrapIfNeeded()

        #expect(probe.overlayPresentations == 0)

        try store.applyStateSnapshot(Self.stateSnapshotPayload(
            behavior: snapshotBehavior,
            behaviorRevision: "8",
            pets: [pet]
        ))

        #expect(store.initialAppearanceReadiness == .authoritative)
        #expect(store.hasLoadedStateSnapshot)
        #expect(store.behavior == snapshotBehavior)
        #expect(store.behaviorRevision == "8")
        #expect(probe.appearanceApplications == 2)
        #expect(probe.appearanceObservation == AppearanceApplicationObservation(
            theme: .light,
            behavior: snapshotBehavior,
            revision: "8",
            readiness: .authoritative
        ))
        #expect(probe.overlayPresentations == 1)
        #expect(probe.overlayObservation == OverlayPresentationObservation(
            hasLoadedStateSnapshot: true,
            behavior: snapshotBehavior,
            revision: "8",
            petIDs: [pet.id]
        ))

        try store.applyStateSnapshot(Self.stateSnapshotPayload(
            behavior: snapshotBehavior,
            behaviorRevision: "8",
            pets: [pet]
        ))
        #expect(probe.overlayPresentations == 1)
    }

    private static func versionedBehaviorPayload(
        _ behavior: BehaviorSettings,
        revision: String
    ) throws -> [String: Any] {
        [
            "behavior": try jsonObject(behavior),
            "revision": revision,
        ]
    }

    private static func stateSnapshotPayload(
        behavior: BehaviorSettings,
        behaviorRevision: String,
        pets: [PetSummary]
    ) throws -> [String: Any] {
        [
            "revision": "state-\(behaviorRevision)",
            "behavior": try jsonObject(behavior),
            "behavior_revision": behaviorRevision,
            "pets": try jsonArray(pets),
            "events": [],
            "connections": [],
        ]
    }

    private static func releaseManifest() -> RuntimeReleaseManifest {
        RuntimeReleaseManifest(
            schemaVersion: RuntimeReleaseManifest.schemaVersion,
            releaseChannel: "release",
            appVersion: "0.3.0",
            appBuild: "1",
            buildID: "build-new",
            petCoreRPCProtocol: PetCoreRuntimeContract.requiredRPCProtocol,
            petCoreBuildID: "build-new",
            petCoreCLIBuildID: "build-new",
            minimumDatabaseSchemaVersion: 1,
            maximumDatabaseSchemaVersion: 6,
            agentEventSchemaVersion: "apc.agent-event.v1",
            petpackSchemaVersion: "apc.petpack.v1",
            petpackReadVersions: ["apc.petpack.v1"],
            petpackWriteVersion: "apc.petpack.v1",
            connectorContracts: RuntimeConnectorContracts(
                codex: "codex-hooks.v1",
                claudeCode: "claude-hooks.v1",
                pi: "pi-extension.v1",
                opencode: "opencode-plugin.v1"
            )
        )
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func jsonArray<T: Encodable>(_ value: T) throws -> [Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [Any])
    }
}

@MainActor
private final class InitialAppearanceProbe {
    weak var store: AppStore?
    var events: [String] = []
    var appearanceObservation: AppearanceApplicationObservation?
    var overlayObservation: OverlayPresentationObservation?
    var readinessObservedByOnReady: InitialAppearanceReadiness?
    var appearanceApplications = 0
    var overlayPresentations = 0
    var initialBehaviorRequests = 0
    var readyCallbacks = 0
}

private struct AppearanceApplicationObservation: Equatable {
    let theme: AppearanceTheme
    let behavior: BehaviorSettings
    let revision: String
    let readiness: InitialAppearanceReadiness
}

private struct OverlayPresentationObservation: Equatable {
    let hasLoadedStateSnapshot: Bool
    let behavior: BehaviorSettings
    let revision: String
    let petIDs: [String]
}

private enum InitialAppearanceTestError: Error {
    case unavailable
}

private actor InitialAppearanceReadyGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor InitialAppearanceFallbackProbe {
    private var recordedDelays: [Duration] = []

    func record(_ delay: Duration) {
        recordedDelays.append(delay)
    }

    func delays() -> [Duration] {
        recordedDelays
    }
}

private actor InitialBootstrapRaceProbe {
    private var ensureAttempts = 0
    private var recoveryAttempts = 0
    private var secondEnsureStarted = false
    private var secondEnsureReleased = false
    private var secondEnsureStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondEnsureReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func ensureRunning() async -> ServiceStartResult {
        ensureAttempts += 1
        guard ensureAttempts > 1 else {
            return .failed(reason: "initial startup failed")
        }
        secondEnsureStarted = true
        let waiters = secondEnsureStartWaiters
        secondEnsureStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !secondEnsureReleased else { return .started }
        await withCheckedContinuation { continuation in
            secondEnsureReleaseWaiters.append(continuation)
        }
        return .started
    }

    func recover() -> ServiceStartResult {
        recoveryAttempts += 1
        return .started
    }

    func waitUntilSecondEnsureStarted() async {
        guard !secondEnsureStarted else { return }
        await withCheckedContinuation { continuation in
            secondEnsureStartWaiters.append(continuation)
        }
    }

    func releaseSecondEnsure() {
        secondEnsureReleased = true
        let waiters = secondEnsureReleaseWaiters
        secondEnsureReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func counts() -> (ensure: Int, recover: Int) {
        (ensureAttempts, recoveryAttempts)
    }
}

@MainActor
private final class InitialBootstrapPipelineProbe {
    var events: [String] = []
}
