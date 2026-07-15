import AppKit
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
    func loadedServiceUsesForceKickstartSoStaleBinaryIsReplaced() {
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

        #expect(invocations.flatMap(\.arguments).contains("-k"))
        #expect(plans[0].invocations.map(\.arguments) == [
            ["bootout", "gui/501/dev.agentpet.petcore"],
            ["bootstrap", "gui/501", "/tmp/dev.agentpet.petcore.plist"]
        ])
        #expect(plans[2].invocations.map(\.arguments) == [
            ["kickstart", "-k", "gui/501/dev.agentpet.petcore"]
        ])
    }

    @Test
    func isolatedDirectModeNeverBootsOutTheGlobalLaunchAgent() {
        #expect(!PetCoreLaunchControlPolicy.shouldBootoutGlobalLaunchAgent(
            launchAgentDisabled: true
        ))
        #expect(PetCoreLaunchControlPolicy.shouldBootoutGlobalLaunchAgent(
            launchAgentDisabled: false
        ))
    }

    @Test
    func healthRequiresCurrentRPCProtocolAndBuildIdentity() {
        #expect(PetCoreRuntimeContract.acceptsHealth([
            "ok": true,
            "rpc_protocol": "apc.petcore-rpc.v2",
            "build_id": "build-a"
        ], expectedBuildID: "build-a"))
        #expect(!PetCoreRuntimeContract.acceptsHealth([
            "ok": true,
            "rpc_protocol": "apc.petcore-rpc.v2",
            "build_id": "build-old"
        ], expectedBuildID: "build-a"))
        #expect(!PetCoreRuntimeContract.acceptsHealth([
            "ok": true,
            "version": "0.1.0"
        ], expectedBuildID: "build-a"))
        #expect(!PetCoreRuntimeContract.acceptsHealth([
            "ok": false,
            "rpc_protocol": "apc.petcore-rpc.v2",
            "build_id": "build-a"
        ], expectedBuildID: "build-a"))

        #expect(PetCoreRuntimeContract.incompatibleInstanceID([
            "ok": true,
            "rpc_protocol": "apc.petcore-rpc.v2",
            "build_id": "build-old",
            "instance_id": "instance-old"
        ], expectedBuildID: "build-a") == "instance-old")
    }

    @Test
    func productionPetStudioRequiresExternalImageSource() {
        #expect(PetCoreRuntimeContract.requiredGenerationEnvironment == [
            "APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK": "0",
            "APC_REQUIRE_SKILL_FULL_SOURCE": "1",
            "APC_REQUIRE_EXTERNAL_SKILL_SOURCE": "1"
        ])
    }

    @Test
    func healthyRuntimePublishesStableConnectorCLIPath() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let version = home
            .appendingPathComponent("runtime/versions/build-a", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        let executable = version.appendingPathComponent("petcore")
        let cli = version.appendingPathComponent("petcore-cli")
        let manifestURL = version.appendingPathComponent("runtime-manifest.json")
        try Data().write(to: executable)
        try Data().write(to: cli)
        try Data().write(to: manifestURL)
        let store = PetCoreRuntimeStore(homeURL: home)
        let manifest = runtimeManifest(buildID: "build-a")

        try await store.commitHealthy(PreparedPetCoreRuntime(
            executableURL: executable,
            cliURL: cli,
            manifestURL: manifestURL,
            manifest: manifest,
            previous: nil
        ))

        let current = home.appendingPathComponent("runtime/current")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == "versions/build-a")
        #expect(
            current.appendingPathComponent("petcore-cli").resolvingSymlinksInPath()
                == cli.resolvingSymlinksInPath()
        )
    }

    @Test
    func healthRequiresTheCompleteRuntimeReleaseManifest() throws {
        let manifest = runtimeManifest(buildID: "build-a")
        let manifestObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any]
        )
        let health: [String: Any] = [
            "ok": true,
            "rpc_protocol": "apc.petcore-rpc.v2",
            "build_id": "build-a",
            "runtime_manifest": manifestObject
        ]
        #expect(PetCoreRuntimeContract.acceptsHealth(
            health,
            expectedBuildID: "build-a",
            expectedManifest: manifest
        ))

        let stale = runtimeManifest(buildID: "build-a", codexContract: "codex-hooks.v0")
        #expect(!PetCoreRuntimeContract.acceptsHealth(
            health,
            expectedBuildID: "build-a",
            expectedManifest: stale
        ))
    }

    @Test
    func runtimeManifestRejectsInconsistentPetpackReadWriteCompatibility() throws {
        let missingWrite = runtimeManifest(
            buildID: "build-a",
            petpackReadVersions: ["apc.petpack.v1"],
            petpackWriteVersion: "apc.petpack.v2"
        )
        #expect(throws: RuntimeManifestError.self) {
            try missingWrite.validateForApp()
        }

        let legacyMismatch = runtimeManifest(
            buildID: "build-a",
            petpackSchemaVersion: "apc.petpack.v2",
            petpackReadVersions: ["apc.petpack.v1"],
            petpackWriteVersion: "apc.petpack.v1"
        )
        #expect(throws: RuntimeManifestError.self) {
            try legacyMismatch.validateForApp()
        }
    }

    @Test
    func legacyV1RuntimeManifestReconstructsPetpackReadWriteRange() throws {
        let manifest = runtimeManifest(buildID: "build-a")
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest))
                as? [String: Any]
        )
        object.removeValue(forKey: "petpack_read_versions")
        object.removeValue(forKey: "petpack_write_version")

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RuntimeReleaseManifest.self, from: data)
        try decoded.validateForApp()
        #expect(decoded.petpackReadVersions == ["apc.petpack.v1"])
        #expect(decoded.petpackWriteVersion == "apc.petpack.v1")
        #expect(decoded == manifest)
    }

    @Test
    func agentIconCandidatesPreferOfficialBrandAssets() throws {
        let codex = AgentIconCandidates.candidates(
            for: .codex,
            discoveredAppPaths: ["/Applications/ChatGPT Beta.app"]
        )
        #expect(codex.first == .resource(
            "/Applications/ChatGPT Beta.app/Contents/Resources/icon-codex-dark-color.png"
        ))
        #expect(codex.contains(.appBundle("/Applications/ChatGPT.app")))

        let pi = AgentIconCandidates.candidates(for: .pi)
        #expect(pi.first == .bundledResource("PiBadge.svg"))

        for source in AgentSource.allCases {
            let candidates = AgentIconCandidates.candidates(for: source)
            #expect(!candidates.isEmpty)
            #expect(Set(candidates.map { "\($0.kind):\($0.path)" }).count == candidates.count)
        }
    }

    @Test
    func appInstanceLockRejectsSecondOwnerAndAllowsHandoff() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let first = AppInstanceLock(homeURL: home)
        let second = AppInstanceLock(homeURL: home)

        #expect(try first.acquire())
        #expect(!(try second.acquire()))
        first.release()
        #expect(try second.acquire())
    }

    @MainActor
    @Test
    func installedBuildIdentityDetectsBundleReplacement() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["APCBuildID": "build-new"],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: bundle) }

        let installed = AppUpdateHandoffCoordinator.installedBuildID(at: bundle)
        #expect(installed == "build-new")
        #expect(AppUpdateHandoffCoordinator.buildChanged(
            launchedBuildID: "build-old",
            installedBuildID: installed
        ))
        #expect(!AppUpdateHandoffCoordinator.buildChanged(
            launchedBuildID: "build-new",
            installedBuildID: installed
        ))
    }

    @Test
    func appActivationRequestRoundTripsThroughNotificationPayload() throws {
        let request = try #require(AppActivationRequest(
            bundlePath: "/Applications/Agent Pet Companion.app",
            buildID: "build-new"
        ))

        #expect(AppActivationRequest(userInfo: request.userInfo) == request)
        #expect(AppActivationRequest(bundlePath: "   ", buildID: "build-new") == nil)
        #expect(AppActivationRequest(bundlePath: request.bundlePath, buildID: "\n") == nil)
    }

    @MainActor
    @Test
    func requestedBuildHandoffRequiresValidatedDifferentAppBuild() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "APCBuildID": "build-new",
                "CFBundleIdentifier": "dev.agentpet.companion"
            ],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: bundle) }

        #expect(AppUpdateHandoffCoordinator.shouldHandoff(
            launchedBuildID: "build-old",
            requestedBuildID: "build-new",
            requestedBundleURL: bundle,
            expectedBundleIdentifier: "dev.agentpet.companion"
        ))
        #expect(!AppUpdateHandoffCoordinator.shouldHandoff(
            launchedBuildID: "build-new",
            requestedBuildID: "build-new",
            requestedBundleURL: bundle,
            expectedBundleIdentifier: "dev.agentpet.companion"
        ))
        #expect(!AppUpdateHandoffCoordinator.shouldHandoff(
            launchedBuildID: "build-old",
            requestedBuildID: "forged-build",
            requestedBundleURL: bundle,
            expectedBundleIdentifier: "dev.agentpet.companion"
        ))
        #expect(!AppUpdateHandoffCoordinator.shouldHandoff(
            launchedBuildID: "build-old",
            requestedBuildID: "build-new",
            requestedBundleURL: bundle,
            expectedBundleIdentifier: "dev.agentpet.another-app"
        ))
    }

    @MainActor
    @Test
    func mainWindowDetectionIsStableAcrossDynamicTitlesAndExcludesPanels() {
        #expect(AppStore.isMainWindowCandidate(
            isPanel: false,
            level: .normal,
            styleMask: [.titled, .closable, .resizable]
        ))
        #expect(!AppStore.isMainWindowCandidate(
            isPanel: true,
            level: .normal,
            styleMask: [.titled, .nonactivatingPanel]
        ))
        #expect(!AppStore.isMainWindowCandidate(
            isPanel: false,
            level: .floating,
            styleMask: [.titled]
        ))
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

    private func runtimeManifest(
        buildID: String,
        codexContract: String = "codex-hooks.v1",
        petpackSchemaVersion: String = "apc.petpack.v1",
        petpackReadVersions: [String] = ["apc.petpack.v1"],
        petpackWriteVersion: String = "apc.petpack.v1"
    ) -> RuntimeReleaseManifest {
        RuntimeReleaseManifest(
            schemaVersion: RuntimeReleaseManifest.schemaVersion,
            releaseChannel: "develop",
            appVersion: "0.1.0",
            appBuild: "1",
            buildID: buildID,
            petCoreRPCProtocol: PetCoreRuntimeContract.requiredRPCProtocol,
            petCoreBuildID: buildID,
            petCoreCLIBuildID: buildID,
            minimumDatabaseSchemaVersion: 1,
            maximumDatabaseSchemaVersion: 1,
            agentEventSchemaVersion: "apc.agent-event.v1",
            petpackSchemaVersion: petpackSchemaVersion,
            petpackReadVersions: petpackReadVersions,
            petpackWriteVersion: petpackWriteVersion,
            connectorContracts: RuntimeConnectorContracts(
                codex: codexContract,
                claudeCode: "claude-hooks.v1",
                pi: "pi-extension.v1",
                opencode: "opencode-plugin.v1"
            )
        )
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
