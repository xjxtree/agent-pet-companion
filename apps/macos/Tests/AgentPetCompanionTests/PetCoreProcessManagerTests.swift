import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct PetCoreProcessManagerTests {
    @Test
    func healthyServiceSkipsEveryStartupRunner() async {
        let probe = ProcessManagerProbe(healthResponses: [true])
        let manager = makeManager(probe: probe)

        let result = await manager.ensureRunning()
        #expect(result == .alreadyHealthy)
        let counts = await probe.counts()
        #expect(counts.launchctl == 0)
        #expect(counts.direct == 0)
    }

    @Test
    func missingServiceBootstrapsOnce() async {
        let probe = ProcessManagerProbe(healthResponses: [false, true])
        let manager = makeManager(probe: probe)

        let result = await manager.ensureRunning()
        #expect(result == .started)
        let counts = await probe.counts()
        #expect(counts.launchctl == 1)
    }

    @Test
    func concurrentProcessManagerCallsCoalesce() async {
        let probe = ProcessManagerProbe(
            healthResponses: [false, true],
            launchDelay: .milliseconds(100)
        )
        let manager = makeManager(probe: probe)

        async let first = manager.ensureRunning()
        async let second = manager.ensureRunning()
        let results = await [first, second]
        #expect(results == [.started, .started])
        let counts = await probe.counts()
        #expect(counts.launchctl == 1)
    }

    @Test
    func launchPlanNeverUsesForceKickstart() {
        let plans = [true, false].flatMap { configurationChanged in
            [true, false].map { isLoaded in
                PetCoreLaunchAgentPlan.make(
                    configurationChanged: configurationChanged,
                    isLoaded: isLoaded,
                    domain: "gui/501",
                    label: "dev.agentpet.petcore",
                    propertyListPath: "/tmp/dev.agentpet.petcore.plist"
                )
            }
        }
        let invocations = plans.flatMap(\.invocations)

        #expect(!invocations.flatMap(\.arguments).contains("-k"))
        #expect(plans[0].invocations.map(\.arguments) == [
            ["bootout", "gui/501/dev.agentpet.petcore"],
            ["bootstrap", "gui/501", "/tmp/dev.agentpet.petcore.plist"]
        ])
    }

    @MainActor
    @Test
    func appStoreBootstrapUsesInjectedRetrySeamAndCompletesOnce() async {
        let probe = AppStoreBootstrapProbe(results: [
            .failed(reason: "transient"),
            .started
        ])
        let coordinator = PetCoreAppBootstrapCoordinator(
            ensureRunning: { await probe.nextResult() },
            policy: ServiceBootstrapRetryPolicy(
                maximumAttempts: 3,
                initialDelay: .milliseconds(1),
                maximumDelay: .milliseconds(2)
            ),
            sleep: { duration in await probe.recordSleep(duration) }
        )
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { await coordinator.ensureRunning() },
                recover: { await coordinator.recover() },
                refreshSnapshot: { _ in },
                onReady: { _ in await probe.recordReady() }
            )
        )

        let first = Task { @MainActor in await store.bootstrapIfNeeded() }
        let second = Task { @MainActor in await store.bootstrapIfNeeded() }
        await first.value
        await second.value

        let snapshot = await probe.snapshot()
        #expect(snapshot.attempts == 2)
        #expect(snapshot.readyCount == 1)
        #expect(store.serviceStatusText == "本地服务运行中")
    }

    @MainActor
    @Test
    func appStoreTransportFailureRecoversAndRefreshesSnapshot() async {
        let probe = AppStoreRecoveryProbe(failFirstSnapshot: true)
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .started },
                recover: { await probe.recover() },
                refreshSnapshot: { _ in try await probe.refreshSnapshot() },
                onReady: { _ in }
            )
        )

        await store.refresh()

        let snapshot = await probe.snapshot()
        #expect(snapshot.recoveryAttempts == 1)
        #expect(snapshot.snapshotAttempts == 2)
        #expect(store.serviceStatusText == "本地服务运行中")
    }

    @MainActor
    @Test
    func concurrentAppStoreRecoveryCallsCoalesce() async {
        let probe = AppStoreRecoveryProbe(
            failFirstSnapshot: false,
            recoveryDelay: .milliseconds(100)
        )
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .started },
                recover: { await probe.recover() },
                refreshSnapshot: { _ in try await probe.refreshSnapshot() },
                onReady: { _ in }
            )
        )

        let first = Task { @MainActor in await store.recoverServiceConnection() }
        let second = Task { @MainActor in await store.recoverServiceConnection() }
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult)
        #expect(secondResult)
        let snapshot = await probe.snapshot()
        #expect(snapshot.recoveryAttempts == 1)
        #expect(snapshot.snapshotAttempts == 1)
    }

    private func makeManager(probe: ProcessManagerProbe) -> PetCoreProcessManager {
        PetCoreProcessManager(
            healthCheck: { await probe.healthCheck() },
            launchctlRunner: { try await probe.runLaunchctl() },
            directRunner: { try await probe.runDirect() },
            healthCheckAttempts: 1,
            sleep: { _ in }
        )
    }
}

private actor ProcessManagerProbe {
    private var healthResponses: [Bool]
    private let launchDelay: Duration
    private var launchctlRuns = 0
    private var directRuns = 0

    init(healthResponses: [Bool], launchDelay: Duration = .zero) {
        self.healthResponses = healthResponses
        self.launchDelay = launchDelay
    }

    func healthCheck() -> Bool {
        if healthResponses.count > 1 { return healthResponses.removeFirst() }
        return healthResponses.first ?? false
    }

    func runLaunchctl() async throws {
        launchctlRuns += 1
        if launchDelay > .zero { try await Task.sleep(for: launchDelay) }
    }

    func runDirect() async throws { directRuns += 1 }

    func counts() -> (launchctl: Int, direct: Int) { (launchctlRuns, directRuns) }
}

private actor AppStoreBootstrapProbe {
    private var results: [ServiceStartResult]
    private var attempts = 0
    private var readyCount = 0
    private var delays: [Duration] = []

    init(results: [ServiceStartResult]) { self.results = results }

    func nextResult() -> ServiceStartResult {
        attempts += 1
        if results.count > 1 { return results.removeFirst() }
        return results.first ?? .failed(reason: "no result")
    }

    func recordSleep(_ duration: Duration) { delays.append(duration) }
    func recordReady() { readyCount += 1 }

    func snapshot() -> (attempts: Int, readyCount: Int, delays: [Duration]) {
        (attempts, readyCount, delays)
    }
}

private actor AppStoreRecoveryProbe {
    private let failFirstSnapshot: Bool
    private let recoveryDelay: Duration
    private var recoveryAttempts = 0
    private var snapshotAttempts = 0

    init(failFirstSnapshot: Bool, recoveryDelay: Duration = .zero) {
        self.failFirstSnapshot = failFirstSnapshot
        self.recoveryDelay = recoveryDelay
    }

    func recover() async -> ServiceStartResult {
        recoveryAttempts += 1
        if recoveryDelay > .zero {
            try? await Task.sleep(for: recoveryDelay)
        }
        return .started
    }

    func refreshSnapshot() throws {
        snapshotAttempts += 1
        if failFirstSnapshot, snapshotAttempts == 1 {
            throw AppStoreRecoveryTestError.disconnected
        }
    }

    func snapshot() -> (recoveryAttempts: Int, snapshotAttempts: Int) {
        (recoveryAttempts, snapshotAttempts)
    }
}

private enum AppStoreRecoveryTestError: Error {
    case disconnected
}
