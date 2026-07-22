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
    func legacyLaunchAgentOutputMigratesExactlyUntilBothSinksAreDevNull() {
        #expect(!PetCoreLaunchAgentMigrationPolicy.requiresLegacyOutputMigration(
            launchAgentDisabled: true,
            hasInstalledPropertyList: true,
            standardOutPath: "/tmp/petcore.out.log",
            standardErrorPath: "/tmp/petcore.err.log"
        ))
        #expect(!PetCoreLaunchAgentMigrationPolicy.requiresLegacyOutputMigration(
            launchAgentDisabled: false,
            hasInstalledPropertyList: false,
            standardOutPath: nil,
            standardErrorPath: nil
        ))
        #expect(PetCoreLaunchAgentMigrationPolicy.requiresLegacyOutputMigration(
            launchAgentDisabled: false,
            hasInstalledPropertyList: true,
            standardOutPath: "/tmp/petcore.out.log",
            standardErrorPath: "/dev/null"
        ))
        #expect(PetCoreLaunchAgentMigrationPolicy.requiresLegacyOutputMigration(
            launchAgentDisabled: false,
            hasInstalledPropertyList: true,
            standardOutPath: "/dev/null",
            standardErrorPath: nil
        ))
        #expect(!PetCoreLaunchAgentMigrationPolicy.requiresLegacyOutputMigration(
            launchAgentDisabled: false,
            hasInstalledPropertyList: true,
            standardOutPath: "/dev/null",
            standardErrorPath: "/dev/null"
        ))
    }

    @Test
    func serviceFailureReasonsCollapseIntoAClosedDiagnosticCodeSet() {
        let cases: [(String, PetCoreServiceFailureCode)] = [
            ("未找到 petcore 可执行文件", .petCoreBinaryMissing),
            ("未找到 petcore-cli 可执行文件", .cliMissing),
            ("LaunchAgent 已由 APC_DISABLE_LAUNCH_AGENT 禁用", .launchAgentDisabled),
            ("准备 petcore 运行目录失败：private path", .runtimePathsFailed),
            ("PetCore LaunchAgent 命令失败：private command", .launchctlFailed),
            ("候选 PetCore 启动后未通过版本与健康检查", .candidateHealthFailed),
            ("候选 PetCore 预检失败：数据库版本不兼容", .candidateHealthFailed),
            ("PetCore 直接启动后未在限定时间内就绪；LaunchAgent：private", .directLaunchFailed),
            ("PetCore 更新失败且回滚未完成：private", .updateRollbackFailed),
            ("arbitrary user or system detail /Users/private", .unknown)
        ]
        for (reason, expected) in cases {
            #expect(PetCoreServiceFailureClassifier.classify(reason) == expected)
        }
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
    func healthRejectsACompatibleDaemonRunningWithDifferentConnectorRoots() {
        let health: [String: Any] = [
            "ok": true,
            "rpc_protocol": "apc.petcore-rpc.v2",
            "build_id": "build-a",
            "connector_environment": [
                "HOME": "/Users/tester",
                "PI_CODING_AGENT_DIR": "/tmp/pi-a",
                "PATH": "/usr/bin:/bin"
            ]
        ]
        #expect(PetCoreRuntimeContract.acceptsHealth(
            health,
            expectedBuildID: "build-a",
            expectedConnectorEnvironment: [
                "HOME": "/Users/tester",
                "PI_CODING_AGENT_DIR": "/tmp/pi-a",
                "PATH": "/usr/bin:/bin"
            ]
        ))
        #expect(!PetCoreRuntimeContract.acceptsHealth(
            health,
            expectedBuildID: "build-a",
            expectedConnectorEnvironment: [
                "HOME": "/Users/tester",
                "PI_CODING_AGENT_DIR": "/tmp/pi-b",
                "PATH": "/usr/bin:/bin"
            ]
        ))
        #expect(!PetCoreRuntimeContract.acceptsHealth(
            health,
            expectedBuildID: "build-a",
            expectedConnectorEnvironment: [
                "HOME": "/Users/tester",
                "PI_CODING_AGENT_DIR": "/tmp/pi-a",
                "PATH": "/custom/bin:/usr/bin:/bin"
            ]
        ))
        var healthWithInstance = health
        healthWithInstance["instance_id"] = "environment-mismatch"
        #expect(PetCoreRuntimeContract.incompatibleInstanceID(
            healthWithInstance,
            expectedBuildID: "build-a",
            expectedConnectorEnvironment: [
                "HOME": "/Users/tester",
                "PI_CODING_AGENT_DIR": "/tmp/pi-a",
                "PATH": "/custom/bin:/usr/bin:/bin"
            ]
        ) == "environment-mismatch")
        #expect(!PetCoreRuntimeContract.acceptsHealth(
            [
                "ok": true,
                "rpc_protocol": "apc.petcore-rpc.v2",
                "build_id": "build-a"
            ],
            expectedBuildID: "build-a",
            expectedConnectorEnvironment: ["HOME": "/Users/tester"]
        ))
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
    func petCoreServiceEnvironmentAlwaysCarriesHomeAndOnlyAbsoluteConnectorPaths() {
        let environment = PetCoreServiceEnvironmentPolicy.userPathEnvironment(
            processEnvironment: [
                "CODEX_HOME": "~/codex-home",
                "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
                "PI_CODING_AGENT_DIR": "relative/pi",
                "OPENCODE_CONFIG_DIR": "/tmp/opencode-config",
                "OPENCODE_CONFIG": "  ",
                "XDG_CONFIG_HOME": "/tmp/xdg",
                "APC_PI_CLI_PATH": "/tmp/bin/pi",
                "APC_OPENCODE_CLI_PATH": "relative/opencode"
            ],
            userHome: "/Users/tester"
        )

        #expect(environment["HOME"] == "/Users/tester")
        #expect(environment["CODEX_HOME"] == "/Users/tester/codex-home")
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/claude-config")
        #expect(environment["OPENCODE_CONFIG_DIR"] == "/tmp/opencode-config")
        #expect(environment["XDG_CONFIG_HOME"] == "/tmp/xdg")
        #expect(environment["APC_PI_CLI_PATH"] == "/tmp/bin/pi")
        #expect(environment["APC_OPENCODE_CLI_PATH"] == nil)
        #expect(environment["PI_CODING_AGENT_DIR"] == nil)
        #expect(environment["OPENCODE_CONFIG"] == nil)
        #expect(Set(environment.keys).isSubset(of: Set(
            PetCoreServiceEnvironmentPolicy.connectorPathKeys + ["HOME"]
        )))
        #expect(PetCoreServiceEnvironmentPolicy.defaultExecutableSearchPaths(
            userHome: "/Users/tester"
        ).contains("/Users/tester/.opencode/bin"))
    }

    @Test
    func serviceIdentitySanitizesPathAndFindsCommonNodeVersionManagers() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let nvm = home.appendingPathComponent(".nvm/versions/node/v22.0.0/bin", isDirectory: true)
        let fnm = home.appendingPathComponent(
            ".local/share/fnm/node-versions/v20.0.0/installation/bin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: nvm, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fnm, withIntermediateDirectories: true)

        let identity = PetCoreServiceEnvironmentPolicy.serviceIdentityEnvironment(
            processEnvironment: [
                "PATH": "relative/bin:/custom/bin:/custom/bin",
                "APC_CLAUDE_CLI_PATH": "/custom/bin/claude"
            ],
            userHome: home.path
        )
        let paths = identity["PATH"]?.split(separator: ":").map(String.init) ?? []

        #expect(identity["HOME"] == home.path)
        #expect(identity["APC_CLAUDE_CLI_PATH"] == "/custom/bin/claude")
        #expect(!paths.contains("relative/bin"))
        #expect(paths.filter { $0 == "/custom/bin" }.count == 1)
        #expect(paths.contains(home.appendingPathComponent(".volta/bin").path))
        #expect(paths.contains(home.appendingPathComponent(".asdf/shims").path))
        #expect(paths.contains(home.appendingPathComponent(".local/share/mise/shims").path))
        #expect(paths.contains(nvm.path))
        #expect(paths.contains(fnm.path))
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
    func runtimeInfoUsesTheVerifiedPetCoreHealthAndManifest() throws {
        let manifest = runtimeManifest(buildID: "build-a")
        let manifestObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any]
        )
        let info = try #require(PetCoreRuntimeInfo.running(
            healthValue: [
                "ok": true,
                "version": "0.1.7",
                "rpc_protocol": "apc.petcore-rpc.v2",
                "build_id": "build-a",
                "instance_id": "instance-a",
                "runtime_manifest": manifestObject
            ],
            expectedManifest: manifest
        ))

        #expect(info.phase == .running)
        #expect(info.version == "0.1.7")
        #expect(info.appBuild == "1")
        #expect(info.buildID == "build-a")
        #expect(info.rpcProtocol == "apc.petcore-rpc.v2")
        #expect(info.releaseChannel == "develop")
        #expect(info.databaseSchemaRange == "1")
        #expect(info.instanceID == "instance-a")
        #expect(info.errorMessage == nil)
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
        let controlCenter = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        controlCenter.identifier = AppStore.controlCenterWindowIdentifier
        controlCenter.title = "Pet Library"
        #expect(AppStore.isMainWindowCandidate(controlCenter))
        controlCenter.title = "Service & Diagnostics"
        #expect(AppStore.isMainWindowCandidate(controlCenter))

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = AppStore.controlCenterWindowIdentifier
        #expect(!AppStore.isMainWindowCandidate(panel))

        let unrelatedWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        unrelatedWindow.identifier = NSUserInterfaceItemIdentifier("about")
        #expect(!AppStore.isMainWindowCandidate(unrelatedWindow))
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
        #expect(store.petCoreOperationalState == .online)
    }

    @MainActor
    @Test
    func appStoreKeepsThePetCoreStartupErrorVisible() async {
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .failed(reason: "候选 PetCore 预检失败：数据库版本不兼容") },
                recover: { .failed(reason: "仍然不兼容") },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )

        await store.bootstrapIfNeeded()

        #expect(store.serviceStatusText == "PetCore 启动失败")
        #expect(store.petCoreRuntimeInfo.phase == .failed)
        #expect(store.petCoreOperationalState == .runtimeMismatch)
        #expect(store.lastServiceFailureCode == .candidateHealthFailed)
        #expect(
            store.petCoreRuntimeInfo.errorMessage
                == "候选 PetCore 预检失败：数据库版本不兼容"
        )
    }

    @MainActor
    @Test
    func successfulRecoveryClearsTheLastServiceFailureCode() async {
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .failed(reason: "未找到 petcore 可执行文件") },
                recover: { .started },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )

        #expect(store.petCoreOperationalState == .checking)
        await store.bootstrapIfNeeded()
        #expect(store.lastServiceFailureCode == .petCoreBinaryMissing)
        #expect(store.petCoreOperationalState == .offline)
        #expect(await store.recoverServiceConnection())
        #expect(store.lastServiceFailureCode == .none)
        #expect(store.petCoreOperationalState == .online)
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

    @MainActor
    @Test
    func appStorePublishesRecoveringBeforeTheAsyncRecoveryCompletes() async {
        let gate = AppStoreRecoveryGate()
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .started },
                recover: { await gate.recover() },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )

        let recovery = Task { @MainActor in await store.recoverServiceConnection() }
        await gate.waitUntilStarted()
        #expect(store.petCoreOperationalState == .recovering)

        await gate.release()
        #expect(await recovery.value)
        #expect(store.petCoreOperationalState == .online)
    }

    @MainActor
    @Test
    func transportFailurePublishesOfflineWithoutParsingItsMessage() async {
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .started },
                recover: { .started },
                refreshSnapshot: { _ in throw AppStoreRecoveryTestError.disconnected },
                onReady: { _ in }
            )
        )

        #expect(!(await store.refresh()))
        #expect(store.petCoreOperationalState == .offline)
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

private actor AppStoreRecoveryGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func recover() async -> ServiceStartResult {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return .started
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum AppStoreRecoveryTestError: Error {
    case disconnected
}
