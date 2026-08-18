import AppKit
import Darwin
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
                "APC_AGENT_CONFIG_HOME": "/tmp/agent-config-home",
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
        #expect(environment["APC_AGENT_CONFIG_HOME"] == "/tmp/agent-config-home")
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
    func healthyCommitPrunesSupersededManagedRuntimesAndKeepsTheRollbackPair() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let current = runtimeManifest(buildID: "build-current")
        let priorLKG = runtimeManifest(buildID: "build-prior-lkg")
        let orphan = runtimeManifest(buildID: "build-orphan")
        let candidate = runtimeManifest(buildID: "build-candidate")
        for manifest in [current, priorLKG, orphan, candidate] {
            try installManagedRuntime(
                manifest,
                homeURL: home,
                fileManager: fileManager
            )
        }

        let runtimeRoot = home.appendingPathComponent("runtime", isDirectory: true)
        try writeRuntimePointer(
            .init(buildID: current.buildID),
            to: runtimeRoot.appendingPathComponent("current.json")
        )
        try writeRuntimePointer(
            .init(buildID: priorLKG.buildID),
            to: runtimeRoot.appendingPathComponent("last-known-good.json")
        )

        let candidateDirectory = runtimeRoot
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(candidate.buildID, isDirectory: true)
        let store = PetCoreRuntimeStore(homeURL: home)
        try await store.commitHealthy(PreparedPetCoreRuntime(
            executableURL: candidateDirectory.appendingPathComponent("petcore"),
            cliURL: candidateDirectory.appendingPathComponent("petcore-cli"),
            manifestURL: candidateDirectory.appendingPathComponent("runtime-manifest.json"),
            manifest: candidate,
            previous: .init(buildID: current.buildID)
        ))

        let versions = runtimeRoot.appendingPathComponent("versions", isDirectory: true)
        #expect(fileManager.fileExists(atPath: versions.appendingPathComponent(candidate.buildID).path))
        #expect(fileManager.fileExists(atPath: versions.appendingPathComponent(current.buildID).path))
        #expect(!fileManager.fileExists(atPath: versions.appendingPathComponent(priorLKG.buildID).path))
        #expect(!fileManager.fileExists(atPath: versions.appendingPathComponent(orphan.buildID).path))
        #expect(
            try JSONDecoder().decode(
                InstalledPetCoreRuntime.self,
                from: Data(contentsOf: runtimeRoot.appendingPathComponent("current.json"))
            ).buildID == candidate.buildID
        )
        #expect(
            try JSONDecoder().decode(
                InstalledPetCoreRuntime.self,
                from: Data(contentsOf: runtimeRoot.appendingPathComponent("last-known-good.json"))
            ).buildID == current.buildID
        )
    }

    @Test
    func runtimePruningKeepsCheckpointReferencesAndUnrecognizedEntries() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let current = runtimeManifest(buildID: "build-current")
        let lkg = runtimeManifest(buildID: "build-lkg")
        let checkpointCandidate = runtimeManifest(buildID: "build-checkpoint")
        let orphan = runtimeManifest(buildID: "build-orphan")
        for manifest in [current, lkg, checkpointCandidate, orphan] {
            try installManagedRuntime(
                manifest,
                homeURL: home,
                fileManager: fileManager
            )
        }

        let runtimeRoot = home.appendingPathComponent("runtime", isDirectory: true)
        try writeRuntimePointer(
            .init(buildID: current.buildID),
            to: runtimeRoot.appendingPathComponent("current.json")
        )
        try writeRuntimePointer(
            .init(buildID: lkg.buildID),
            to: runtimeRoot.appendingPathComponent("last-known-good.json")
        )
        let foreign = runtimeRoot
            .appendingPathComponent("versions/build-foreign", isDirectory: true)
        try fileManager.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("user-owned".utf8).write(to: foreign.appendingPathComponent("notes.txt"))

        let checkpoint = runtimeRoot.appendingPathComponent(
            "rollback-checkpoint",
            isDirectory: true
        )
        try fileManager.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        let checkpointState: [String: Any] = [
            "schema_version": "apc.runtime-rollback-checkpoint.v1",
            "phase": "ready",
            "source_build_id": current.buildID,
            "candidate_build_id": checkpointCandidate.buildID,
            "database_was_present": true,
            "database_sha256": String(repeating: "a", count: 64),
        ]
        try JSONSerialization.data(withJSONObject: checkpointState).write(
            to: checkpoint.appendingPathComponent("state.json")
        )

        let currentDirectory = runtimeRoot
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(current.buildID, isDirectory: true)
        let store = PetCoreRuntimeStore(homeURL: home)
        try await store.commitHealthy(PreparedPetCoreRuntime(
            executableURL: currentDirectory.appendingPathComponent("petcore"),
            cliURL: currentDirectory.appendingPathComponent("petcore-cli"),
            manifestURL: currentDirectory.appendingPathComponent("runtime-manifest.json"),
            manifest: current,
            previous: nil
        ))

        let versions = runtimeRoot.appendingPathComponent("versions", isDirectory: true)
        #expect(fileManager.fileExists(atPath: versions.appendingPathComponent(current.buildID).path))
        #expect(fileManager.fileExists(atPath: versions.appendingPathComponent(lkg.buildID).path))
        #expect(
            fileManager.fileExists(
                atPath: versions.appendingPathComponent(checkpointCandidate.buildID).path
            )
        )
        #expect(!fileManager.fileExists(atPath: versions.appendingPathComponent(orphan.buildID).path))
        #expect(fileManager.fileExists(atPath: foreign.appendingPathComponent("notes.txt").path))
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
    func existingInvalidRuntimeManifestFailsClosedWhileExplicitAbsenceRemainsAllowed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest = runtimeManifest(buildID: "build-a")
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest))
                as? [String: Any]
        )
        object.removeValue(forKey: "petpack_write_version")
        let manifestURL = directory.appendingPathComponent("runtime-manifest.json")
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)

        let invalid = PetCoreRuntimeContract.manifestRequirement(at: manifestURL)
        guard case let .invalid(message) = invalid else {
            Issue.record("existing invalid manifest must not become an absent manifest")
            return
        }
        #expect(message.contains("App 运行时清单无效"))
        #expect(!PetCoreRuntimeContract.acceptsHealth(
            [
                "ok": true,
                "rpc_protocol": "apc.petcore-rpc.v2",
                "build_id": "build-a",
            ],
            expectedBuildID: "build-a",
            manifestRequirement: invalid
        ))
        do {
            try PetCoreRuntimeContract.validateManifestForStartup(invalid)
            Issue.record("invalid manifest must fail startup")
        } catch {
            #expect(error.localizedDescription.contains("App 运行时清单无效"))
        }

        let missingAllowed = PetCoreRuntimeContract.manifestRequirement(at: nil)
        #expect(missingAllowed == .missingAllowed)
        #expect(throws: Never.self) {
            try PetCoreRuntimeContract.validateManifestForStartup(missingAllowed)
        }

        let packagedBundle = directory.appendingPathComponent(
            "AgentPetCompanion.app",
            isDirectory: true
        )
        let packagedMissingURL = PetCoreRuntimeContract.requiredManifestLocation(
            overridePath: nil,
            bundleURL: packagedBundle,
            bundleResourceURL: nil,
            isPackagedApp: true,
            bundleManifestExists: false
        )
        #expect(packagedMissingURL == packagedBundle.appendingPathComponent(
            "Contents/Resources/runtime-manifest.json"
        ))
        guard case .invalid = PetCoreRuntimeContract.manifestRequirement(
            at: packagedMissingURL
        ) else {
            Issue.record("a packaged App must require its manifest even when the file is missing")
            return
        }

        #expect(PetCoreRuntimeContract.requiredManifestLocation(
            overridePath: nil,
            bundleURL: directory,
            bundleResourceURL: directory,
            isPackagedApp: false,
            bundleManifestExists: false
        ) == nil)
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
            petpackReadVersions: ["apc.petpack.v2"],
            petpackWriteVersion: "apc.petpack.v3"
        )
        #expect(throws: RuntimeManifestError.self) {
            try missingWrite.validateForApp()
        }

        let legacyMismatch = runtimeManifest(
            buildID: "build-a",
            petpackSchemaVersion: "apc.petpack.v2",
            petpackReadVersions: ["apc.petpack.v2"],
            petpackWriteVersion: "apc.petpack.v2"
        )
        #expect(throws: RuntimeManifestError.self) {
            try legacyMismatch.validateForApp()
        }

        let legacyReadCompatibility = runtimeManifest(
            buildID: "build-a",
            petpackReadVersions: ["apc.petpack.v3", "apc.petpack.v2"]
        )
        #expect(throws: RuntimeManifestError.self) {
            try legacyReadCompatibility.validateForApp()
        }
    }

    @Test
    func runtimeManifestRejectsMissingPetpackReadWriteFields() throws {
        let manifest = runtimeManifest(buildID: "build-a")
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest))
                as? [String: Any]
        )
        for key in [
            "petpack_schema_version",
            "petpack_read_versions",
            "petpack_write_version",
        ] {
            var missingField = object
            missingField.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: missingField)
            #expect(throws: DecodingError.self, "missing \(key)") {
                try JSONDecoder().decode(RuntimeReleaseManifest.self, from: data)
            }
        }
    }

    @Test
    func runtimeManifestRejectsUnknownTopLevelAndConnectorFields() throws {
        let manifest = runtimeManifest(buildID: "build-a")
        let encoded = try JSONEncoder().encode(manifest)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var unknownTopLevel = object
        unknownTopLevel["future_contract"] = true
        var unknownConnector = object
        var connectors = try #require(
            unknownConnector["connector_contracts"] as? [String: Any]
        )
        connectors["future_agent"] = "future.v1"
        unknownConnector["connector_contracts"] = connectors

        for (index, value) in [unknownTopLevel, unknownConnector].enumerated() {
            let url = directory.appendingPathComponent("unknown-\(index).json")
            try JSONSerialization.data(withJSONObject: value).write(to: url)
            #expect(throws: RuntimeManifestError.self) {
                try RuntimeReleaseManifest.read(from: url)
            }
        }

        #expect(!PetCoreRuntimeContract.acceptsHealth(
            [
                "ok": true,
                "rpc_protocol": "apc.petcore-rpc.v2",
                "build_id": "build-a",
                "runtime_manifest": unknownConnector,
            ],
            expectedBuildID: "build-a",
            expectedManifest: manifest
        ))
    }

    @Test
    func runtimeManifestRejectsPureV1PetpackContract() throws {
        let legacy = runtimeManifest(
            buildID: "build-a",
            petpackSchemaVersion: "apc.petpack.v1",
            petpackReadVersions: ["apc.petpack.v1"],
            petpackWriteVersion: "apc.petpack.v1"
        )

        #expect(throws: RuntimeManifestError.self) {
            try legacy.validateForApp()
        }
    }

    @Test
    func publishedV1RollbackProfileIsExactAndNeverBecomesCandidatePolicy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let manifestURL = directory.appendingPathComponent("runtime-manifest.json")
        let publishedManifests = [
            publishedV1RuntimeManifest(
                appVersion: "0.1.0",
                appBuild: "1",
                buildID: "0.1.0.1.910f8bfd1130",
                maximumDatabaseSchemaVersion: 5
            ),
            publishedV1RuntimeManifest(
                appVersion: "0.1.1",
                appBuild: "3",
                buildID: "0.1.1.3.7e074dfec8e56742e00bffe02d1ec5de23d0a09c",
                maximumDatabaseSchemaVersion: 6
            ),
            publishedV021RuntimeManifest(),
        ]
        for manifest in publishedManifests {
            try JSONEncoder().encode(manifest).write(to: manifestURL)
            #expect(throws: RuntimeManifestError.self) {
                try RuntimeReleaseManifest.read(from: manifestURL)
            }
            #expect(
                try RuntimeReleaseManifest.read(
                    from: manifestURL,
                    validationProfile: .publishedV1Rollback
                ) == manifest
            )
        }

        let manifest = publishedV021RuntimeManifest()
        var forged = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(manifest)
            ) as? [String: Any]
        )
        let forgedBuildID = "0.2.1.5.0000000000000000000000000000000000000000"
        forged["build_id"] = forgedBuildID
        forged["petcore_build_id"] = forgedBuildID
        forged["petcore_cli_build_id"] = forgedBuildID
        try JSONSerialization.data(withJSONObject: forged).write(to: manifestURL)
        #expect(throws: RuntimeManifestError.self) {
            try RuntimeReleaseManifest.read(
                from: manifestURL,
                validationProfile: .publishedV1Rollback
            )
        }

        var wrongAppBuild = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(manifest)
            ) as? [String: Any]
        )
        wrongAppBuild["app_build"] = "1"
        try JSONSerialization.data(withJSONObject: wrongAppBuild).write(to: manifestURL)
        #expect(throws: RuntimeManifestError.self) {
            try RuntimeReleaseManifest.read(
                from: manifestURL,
                validationProfile: .publishedV1Rollback
            )
        }
    }

    @Test
    func stagedV3CandidateSelectsPublishedV1CurrentAndLKGForRollback() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let publishedV1 = publishedV021RuntimeManifest()
        try installManagedRuntime(
            publishedV1,
            homeURL: home,
            fileManager: fileManager
        )
        let runtimeRoot = home.appendingPathComponent("runtime", isDirectory: true)
        try writeRuntimePointer(
            .init(buildID: publishedV1.buildID),
            to: runtimeRoot.appendingPathComponent("current.json")
        )

        let source = home.appendingPathComponent("candidate-source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceExecutable = source.appendingPathComponent("petcore")
        let sourceCLI = source.appendingPathComponent("petcore-cli")
        try fileManager.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: sourceExecutable
        )
        try fileManager.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: sourceCLI
        )
        let strictV3 = runtimeManifest(buildID: "build-new")
        let sourceManifest = source.appendingPathComponent("runtime-manifest.json")
        try JSONEncoder().encode(strictV3).write(to: sourceManifest)
        let sourceAttestation = source.appendingPathComponent("interaction-attestation.json")
        let sourceAttestationData = Data("build-bound-attestation".utf8)
        try sourceAttestationData.write(to: sourceAttestation)

        let store = PetCoreRuntimeStore(homeURL: home)
        let fromCurrent = try await store.prepareCandidate(
            sourceExecutableURL: sourceExecutable,
            sourceCLIURL: sourceCLI,
            sourceManifestURL: sourceManifest
        )
        #expect(fromCurrent.manifestValidationProfile == .strictV3)
        #expect(fromCurrent.previous?.buildID == publishedV1.buildID)
        #expect(
            try Data(contentsOf: home.appendingPathComponent(
                "runtime/versions/build-new/interaction-attestation.json"
            )) == sourceAttestationData
        )

        let rollback = try await store.resolve(
            try #require(fromCurrent.previous)
        )
        #expect(rollback.manifest == publishedV1)
        #expect(
            rollback.manifestValidationProfile == .publishedV1Rollback
        )

        let publishedHealth: [String: Any] = [
            "ok": true,
            "rpc_protocol": PetCoreRuntimeContract.requiredRPCProtocol,
            "build_id": publishedV1.buildID,
            "runtime_manifest": try #require(
                try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(publishedV1)
                ) as? [String: Any]
            ),
        ]
        #expect(!PetCoreRuntimeContract.acceptsHealth(
            publishedHealth,
            expectedBuildID: publishedV1.buildID,
            expectedManifest: publishedV1
        ))
        #expect(PetCoreRuntimeContract.acceptsHealth(
            publishedHealth,
            expectedBuildID: publishedV1.buildID,
            expectedManifest: publishedV1,
            manifestValidationProfile: rollback.manifestValidationProfile
        ))

        try writeRuntimePointer(
            .init(buildID: strictV3.buildID),
            to: runtimeRoot.appendingPathComponent("current.json")
        )
        try writeRuntimePointer(
            .init(buildID: publishedV1.buildID),
            to: runtimeRoot.appendingPathComponent("last-known-good.json")
        )
        let fromLKG = try await store.prepareCandidate(
            sourceExecutableURL: sourceExecutable,
            sourceCLIURL: sourceCLI,
            sourceManifestURL: sourceManifest
        )
        #expect(fromLKG.previous == nil)

        try fileManager.removeItem(
            at: runtimeRoot.appendingPathComponent("current.json")
        )
        let fromLKGWithoutCurrent = try await store.prepareCandidate(
            sourceExecutableURL: sourceExecutable,
            sourceCLIURL: sourceCLI,
            sourceManifestURL: sourceManifest
        )
        #expect(fromLKGWithoutCurrent.previous?.buildID == publishedV1.buildID)
    }

    @Test
    func rollbackCheckpointCommandBindsTheSourceAndCandidateBuilds() async throws {
        let home = URL(fileURLWithPath: "/tmp/apc-checkpoint-test", isDirectory: true)
        #expect(try PetCoreRollbackCheckpointCommand.arguments(
            operation: .create,
            homeURL: home,
            sourceBuildID: "build-previous",
            candidateBuildID: "build-candidate"
        ) == [
            "rollback-checkpoint", "create",
            "--home", home.path,
            "--source-build-id", "build-previous",
            "--candidate-build-id", "build-candidate",
        ])
        #expect(try PetCoreRollbackCheckpointCommand.arguments(
            operation: .restore,
            homeURL: home
        ) == ["rollback-checkpoint", "restore", "--home", home.path])
        #expect(try PetCoreRollbackCheckpointCommand.arguments(
            operation: .status,
            homeURL: home
        ) == ["rollback-checkpoint", "status", "--home", home.path])
        #expect(throws: (any Error).self) {
            try PetCoreRollbackCheckpointCommand.arguments(
                operation: .create,
                homeURL: home
            )
        }

        try await PetCoreRollbackCheckpointCommand.run(
            operation: .create,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            homeURL: home,
            sourceBuildID: "build-previous",
            candidateBuildID: "build-candidate"
        )
        do {
            try await PetCoreRollbackCheckpointCommand.run(
                operation: .discard,
                executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                homeURL: home
            )
            Issue.record("a nonzero checkpoint command must fail")
        } catch {
            #expect(error.localizedDescription.contains("discard 失败"))
        }
    }

    @Test
    func rollbackCheckpointStatusIsClosedAndBypassesOnlyExactReadyRecovery() throws {
        let readyData = try JSONSerialization.data(withJSONObject: [
            "schema_version": PetCoreRollbackCheckpointStatus.schemaVersion,
            "present": true,
            "phase": "ready",
            "source_build_id": "build-previous",
            "candidate_build_id": "build-candidate",
        ])
        let ready = try #require(
            PetCoreRollbackCheckpointStatus.decodeClosed(readyData)
        )
        #expect(ready.isReadyRecovery(
            sourceBuildID: "build-previous",
            candidateBuildID: "build-candidate"
        ))
        #expect(!ready.isReadyRecovery(
            sourceBuildID: "build-foreign",
            candidateBuildID: "build-candidate"
        ))

        let restoredData = try JSONSerialization.data(withJSONObject: [
            "schema_version": PetCoreRollbackCheckpointStatus.schemaVersion,
            "present": true,
            "phase": "restored",
            "source_build_id": "build-previous",
            "candidate_build_id": "build-candidate",
        ])
        let restored = try #require(
            PetCoreRollbackCheckpointStatus.decodeClosed(restoredData)
        )
        #expect(!restored.isReadyRecovery(
            sourceBuildID: "build-previous",
            candidateBuildID: "build-candidate"
        ))

        var unknown = try #require(
            try JSONSerialization.jsonObject(with: readyData) as? [String: Any]
        )
        unknown["unexpected"] = true
        #expect(PetCoreRollbackCheckpointStatus.decodeClosed(
            try JSONSerialization.data(withJSONObject: unknown)
        ) == nil)

        var missing = try #require(
            try JSONSerialization.jsonObject(with: readyData) as? [String: Any]
        )
        missing.removeValue(forKey: "candidate_build_id")
        #expect(PetCoreRollbackCheckpointStatus.decodeClosed(
            try JSONSerialization.data(withJSONObject: missing)
        ) == nil)

        let malformedAbsent = try JSONSerialization.data(withJSONObject: [
            "schema_version": PetCoreRollbackCheckpointStatus.schemaVersion,
            "present": false,
            "phase": "ready",
            "source_build_id": NSNull(),
            "candidate_build_id": NSNull(),
        ])
        #expect(PetCoreRollbackCheckpointStatus.decodeClosed(malformedAbsent) == nil)
    }

    @Test
    func runtimeUpgradeCheckpointWrapsOnlyTheUncommittedCandidateWindow() async throws {
        let probe = RuntimeUpgradeTransactionProbe()

        try await PetCoreRuntimeUpgradeTransaction.run(
            rollbackAvailable: true,
            stopPriorRuntime: { try await probe.record("stop_prior") },
            revalidateCandidate: { try await probe.record("revalidate") },
            createCheckpoint: { try await probe.record("create") },
            launchCandidate: { try await probe.record("launch_candidate") },
            verifyCandidateHealth: { try await probe.record("candidate_health") },
            commitCandidate: { try await probe.record("commit") },
            stopCandidateRuntime: { try await probe.record("stop_candidate") },
            restoreCheckpoint: { try await probe.record("restore") },
            launchRollback: { try await probe.record("launch_rollback") },
            discardCheckpoint: { try await probe.record("discard") },
            recordCleanupFailure: { _ in
                try? await probe.record("cleanup_failure")
            }
        )

        #expect(await probe.snapshot() == [
            "stop_prior",
            "create",
            "revalidate",
            "launch_candidate",
            "candidate_health",
            "commit",
            "discard",
        ])
    }

    @Test
    func candidateFailureStopsThenRestoresBeforeHistoricalRuntimeStarts() async {
        let probe = RuntimeUpgradeTransactionProbe()

        do {
            try await PetCoreRuntimeUpgradeTransaction.run(
                rollbackAvailable: true,
                stopPriorRuntime: { try await probe.record("stop_prior") },
                revalidateCandidate: { try await probe.record("revalidate") },
                createCheckpoint: { try await probe.record("create") },
                launchCandidate: { try await probe.record("launch_candidate") },
                verifyCandidateHealth: {
                    try await probe.record("candidate_health", failure: "health failed")
                },
                commitCandidate: { try await probe.record("commit") },
                stopCandidateRuntime: { try await probe.record("stop_candidate") },
                restoreCheckpoint: { try await probe.record("restore") },
                launchRollback: { try await probe.record("launch_rollback") },
                discardCheckpoint: { try await probe.record("discard") },
                recordCleanupFailure: { _ in
                    try? await probe.record("cleanup_failure")
                }
            )
            Issue.record("candidate failure must surface after rollback")
        } catch {
            #expect(error.localizedDescription.hasPrefix(
                "PetCore 更新失败，已恢复上一个可用版本"
            ))
        }

        #expect(await probe.snapshot() == [
            "stop_prior",
            "create",
            "revalidate",
            "launch_candidate",
            "candidate_health",
            "stop_candidate",
            "restore",
            "launch_rollback",
            "discard",
        ])
    }

    @Test
    func restoreFailureFailsClosedWithoutStartingTheHistoricalRuntime() async {
        let probe = RuntimeUpgradeTransactionProbe()

        do {
            try await PetCoreRuntimeUpgradeTransaction.run(
                rollbackAvailable: true,
                stopPriorRuntime: { try await probe.record("stop_prior") },
                revalidateCandidate: { try await probe.record("revalidate") },
                createCheckpoint: { try await probe.record("create") },
                launchCandidate: { try await probe.record("launch_candidate") },
                verifyCandidateHealth: {
                    try await probe.record("candidate_health", failure: "health failed")
                },
                commitCandidate: { try await probe.record("commit") },
                stopCandidateRuntime: { try await probe.record("stop_candidate") },
                restoreCheckpoint: {
                    try await probe.record("restore", failure: "restore failed")
                },
                launchRollback: { try await probe.record("launch_rollback") },
                discardCheckpoint: { try await probe.record("discard") },
                recordCleanupFailure: { _ in
                    try? await probe.record("cleanup_failure")
                }
            )
            Issue.record("restore failure must fail closed")
        } catch {
            #expect(error.localizedDescription.contains("回滚未完成"))
            #expect(error.localizedDescription.contains("恢复数据检查点失败"))
        }

        #expect(await probe.snapshot() == [
            "stop_prior",
            "create",
            "revalidate",
            "launch_candidate",
            "candidate_health",
            "stop_candidate",
            "restore",
        ])
    }

    @Test
    func staleReadyCheckpointCreateFailureNeverStartsHistoricalRuntime() async {
        let probe = RuntimeUpgradeTransactionProbe()
        try? await probe.record("stale_ready_with_candidate_mutated_database")

        do {
            try await PetCoreRuntimeUpgradeTransaction.run(
                rollbackAvailable: true,
                stopPriorRuntime: { try await probe.record("stop_prior") },
                revalidateCandidate: { try await probe.record("revalidate") },
                createCheckpoint: {
                    try await probe.record(
                        "reconcile_stale_ready_with_corrupt_digest",
                        failure: "checkpoint digest mismatch"
                    )
                },
                launchCandidate: { try await probe.record("launch_candidate") },
                verifyCandidateHealth: { try await probe.record("candidate_health") },
                commitCandidate: { try await probe.record("commit") },
                stopCandidateRuntime: { try await probe.record("stop_candidate") },
                restoreCheckpoint: { try await probe.record("restore") },
                launchRollback: { try await probe.record("launch_rollback") },
                discardCheckpoint: { try await probe.record("discard") },
                recordCleanupFailure: { _ in
                    try? await probe.record("cleanup_failure")
                }
            )
            Issue.record("an unverified stale checkpoint must fail closed")
        } catch {
            #expect(error.localizedDescription.contains("回滚未完成"))
            #expect(error.localizedDescription.contains("已停止启动历史版本"))
        }

        #expect(await probe.snapshot() == [
            "stale_ready_with_candidate_mutated_database",
            "stop_prior",
            "reconcile_stale_ready_with_corrupt_digest",
        ])
    }

    @Test
    func postCommitDiscardFailureNeverRollsBackTheHealthyCandidate() async throws {
        let probe = RuntimeUpgradeTransactionProbe()

        try await PetCoreRuntimeUpgradeTransaction.run(
            rollbackAvailable: true,
            stopPriorRuntime: { try await probe.record("stop_prior") },
            revalidateCandidate: { try await probe.record("revalidate") },
            createCheckpoint: { try await probe.record("create") },
            launchCandidate: { try await probe.record("launch_candidate") },
            verifyCandidateHealth: { try await probe.record("candidate_health") },
            commitCandidate: { try await probe.record("commit") },
            stopCandidateRuntime: { try await probe.record("stop_candidate") },
            restoreCheckpoint: { try await probe.record("restore") },
            launchRollback: { try await probe.record("launch_rollback") },
            discardCheckpoint: {
                try await probe.record("discard", failure: "discard failed")
            },
            recordCleanupFailure: { _ in
                try? await probe.record("cleanup_failure")
            }
        )

        #expect(await probe.snapshot() == [
            "stop_prior",
            "create",
            "revalidate",
            "launch_candidate",
            "candidate_health",
            "commit",
            "discard",
            "cleanup_failure",
        ])
    }

    @Test
    func checkpointRecoveryPrecedesThePostStopWaitingJobPreflight() async {
        let probe = RuntimeUpgradeTransactionProbe()
        try? await probe.record("candidate_staged")
        try? await probe.record("v1_waiting_job_inserted")

        do {
            try await PetCoreRuntimeUpgradeTransaction.run(
                rollbackAvailable: true,
                stopPriorRuntime: { try await probe.record("stop_prior") },
                revalidateCandidate: {
                    try await probe.record("second_preflight", failure: "waiting job detected")
                },
                createCheckpoint: { try await probe.record("create") },
                launchCandidate: { try await probe.record("launch_candidate") },
                verifyCandidateHealth: { try await probe.record("candidate_health") },
                commitCandidate: { try await probe.record("commit") },
                stopCandidateRuntime: { try await probe.record("stop_candidate") },
                restoreCheckpoint: { try await probe.record("restore") },
                launchRollback: { try await probe.record("launch_rollback") },
                discardCheckpoint: { try await probe.record("discard") },
                recordCleanupFailure: { _ in
                    try? await probe.record("cleanup_failure")
                }
            )
            Issue.record("the second preflight must reject newly inserted work")
        } catch {
            #expect(error.localizedDescription.contains("已恢复上一个可用版本"))
        }

        #expect(await probe.snapshot() == [
            "candidate_staged",
            "v1_waiting_job_inserted",
            "stop_prior",
            "create",
            "second_preflight",
            "restore",
            "launch_rollback",
            "discard",
        ])
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

    @Test
    func runtimeReplacementDistinguishesProtectedRecoverableAndUnknownWork() {
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(preflightValue: [
            "safe": true,
            "active_generation": false,
            "connection_operation_active": false
        ]) == .safe)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(preflightValue: [
            "safe": false,
            "active_generation": true,
            "connection_operation_active": false
        ]) == .snapshotRequired)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(preflightValue: [
            "safe": false,
            "active_generation": true,
            "active_generation_status": "waiting_for_user",
            "connection_operation_active": false,
            "runtime_replacement_safe": true
        ]) == .safe)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(preflightValue: [
            "safe": false,
            "active_generation": true,
            "active_generation_status": "failed",
            "connection_operation_active": false,
            "runtime_replacement_safe": true
        ]) == .safe)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(preflightValue: [
            "safe": false,
            "active_generation": true,
            "active_generation_status": "failed",
            "connection_operation_active": false,
            "runtime_replacement_safe": false
        ]) == .snapshotRequired)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(preflightValue: [
            "safe": false,
            "active_generation": true,
            "active_generation_status": "running",
            "connection_operation_active": false,
            "runtime_replacement_safe": false
        ]) == .protectedWork)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(preflightValue: [
            "safe": true,
            "active_generation": true,
            "active_generation_status": "running",
            "connection_operation_active": false,
            "runtime_replacement_safe": false
        ]) == .unknown)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(snapshotValue: [
            "active_generation": ["job_id": "job-1", "status": "running"]
        ]) == .protectedWork)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(snapshotValue: [
            "active_generation": ["job_id": "job-1", "status": "pending"]
        ]) == .protectedWork)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(snapshotValue: [
            "active_generation": ["job_id": "job-1", "status": "waiting_for_user"]
        ]) == .legacyConnectionStateNeedsProbe)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(snapshotValue: [
            "active_generation": ["job_id": "job-1", "status": "waiting_for_user"],
            "connection_operation_active": false
        ]) == .safe)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(snapshotValue: [
            "active_generation": ["job_id": "job-1", "status": "failed"],
            "connection_operation_active": false
        ]) == .safe)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(snapshotValue: [
            "active_generation": NSNull(),
            "connection_operation_active": true
        ]) == .protectedWork)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(snapshotValue: [
            "active_generation": NSNull(),
            "connection_operation_active": false
        ]) == .safe)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(snapshotValue: [
            "active_generation": NSNull()
        ]) == .legacyConnectionStateNeedsProbe)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(snapshotValue: [:]) == .unknown)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assess(
            snapshotValue: "invalid"
        ) == .unknown)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assessLegacyConnectionProbeError(
            PetCoreClientError.rpcError(
                "another Agent connection operation is already running; wait for it to finish"
            )
        ) == .protectedWork)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.assessLegacyConnectionProbeError(
            PetCoreClientError.rpcError("unknown method connections.test")
        ) == .unknown)
        #expect(PetCoreRuntimeReplacementSafetyPolicy.shouldFallbackToSnapshotAfterPreflightError(
            PetCoreClientError.rpcErrorResponse(
                code: -32601,
                message: "method not found: product.convergence.preflight"
            )
        ))
        #expect(PetCoreRuntimeReplacementSafetyPolicy.shouldFallbackToSnapshotAfterPreflightError(
            PetCoreClientError.rpcError(
                "method not found: product.convergence.preflight"
            )
        ))
        #expect(!PetCoreRuntimeReplacementSafetyPolicy.shouldFallbackToSnapshotAfterPreflightError(
            PetCoreClientError.rpcErrorResponse(
                code: -32603,
                message: "method not found: product.convergence.preflight"
            )
        ))
        #expect(!PetCoreRuntimeReplacementSafetyPolicy.shouldFallbackToSnapshotAfterPreflightError(
            PetCoreClientError.rpcError(
                "invalid request: unknown method product.convergence.preflight"
            )
        ))
        #expect(PetCoreRuntimeReplacementSafetyPolicy.shouldDeferAfterSafetyProbeError(
            PetCoreTransportError.timedOut
        ))
        #expect(!PetCoreRuntimeReplacementSafetyPolicy.shouldDeferAfterSafetyProbeError(
            PetCoreTransportError.systemCall(operation: "connect", code: ECONNREFUSED)
        ))
    }

    @Test
    func v011MethodNotFoundFrameFallsBackAcrossTheVersionJump() throws {
        let response = Data(
            """
            {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found: product.convergence.preflight"}}

            """.utf8
        )
        do {
            _ = try PetCoreClient.decodeResult(from: response)
            Issue.record("The v0.1.1 method-not-found frame must be an RPC error")
        } catch {
            #expect(
                PetCoreRuntimeReplacementSafetyPolicy
                    .shouldFallbackToSnapshotAfterPreflightError(error)
            )
        }
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
        #expect(AppUpdateHandoffCoordinator.manualInstallationRequest(
            launchedBuildID: "build-old",
            requestedBuildID: "build-new",
            requestedBundleURL: bundle,
            expectedBundleIdentifier: "dev.agentpet.companion"
        ) == nil)

        let releasePlist = try PropertyListSerialization.data(
            fromPropertyList: [
                "APCBuildID": "build-new",
                "APCReleaseChannel": "release",
                "CFBundleIdentifier": "dev.agentpet.companion",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "1"
            ],
            format: .xml,
            options: 0
        )
        try releasePlist.write(to: contents.appendingPathComponent("Info.plist"))
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONEncoder().encode(
            runtimeManifest(buildID: "build-new", releaseChannel: "release")
        ).write(to: resources.appendingPathComponent("runtime-manifest.json"))

        #expect(!AppUpdateHandoffCoordinator.shouldHandoff(
            launchedBuildID: "build-old",
            requestedBuildID: "build-new",
            requestedBundleURL: bundle,
            expectedBundleIdentifier: "dev.agentpet.companion"
        ))
        #expect(AppUpdateHandoffCoordinator.shouldHandoff(
            launchedBuildID: "build-old",
            requestedBuildID: "build-new",
            requestedBundleURL: bundle,
            expectedBundleIdentifier: "dev.agentpet.companion",
            canonicalBundleURL: bundle
        ))
        #expect(AppUpdateHandoffCoordinator.isStillValidHandoffTarget(
            bundleURL: bundle,
            expectedBuildID: "build-new",
            expectedVersion: "0.1.0",
            expectedBundleIdentifier: "dev.agentpet.companion",
            requiresRelease: true,
            canonicalBundleURL: bundle
        ))
        let manualInstallation = try #require(
            AppUpdateHandoffCoordinator.manualInstallationRequest(
                launchedBuildID: "build-old",
                requestedBuildID: "build-new",
                requestedBundleURL: bundle,
                expectedBundleIdentifier: "dev.agentpet.companion"
            )
        )
        #expect(manualInstallation.origin == .secondaryDownloadedBuild)
        #expect(manualInstallation.candidateBundleURL == bundle.standardizedFileURL)
        #expect(!AppUpdateHandoffCoordinator.shouldHandoff(
            launchedBuildID: "build-new",
            requestedBuildID: "build-new",
            requestedBundleURL: bundle,
            expectedBundleIdentifier: "dev.agentpet.companion",
            canonicalBundleURL: bundle
        ))
        #expect(!AppUpdateHandoffCoordinator.shouldHandoff(
            launchedBuildID: "build-old",
            requestedBuildID: "forged-build",
            requestedBundleURL: bundle,
            expectedBundleIdentifier: "dev.agentpet.companion",
            canonicalBundleURL: bundle
        ))
        #expect(!AppUpdateHandoffCoordinator.shouldHandoff(
            launchedBuildID: "build-old",
            requestedBuildID: "build-new",
            requestedBundleURL: bundle,
            expectedBundleIdentifier: "dev.agentpet.another-app",
            canonicalBundleURL: bundle
        ))

        try Data("{}".utf8).write(
            to: resources.appendingPathComponent("runtime-manifest.json")
        )
        #expect(!AppUpdateHandoffCoordinator.isStillValidHandoffTarget(
            bundleURL: bundle,
            expectedBuildID: "build-new",
            expectedVersion: "0.1.0",
            expectedBundleIdentifier: "dev.agentpet.companion",
            requiresRelease: true,
            canonicalBundleURL: bundle
        ))
        let invalidRelease = try #require(
            AppUpdateHandoffCoordinator.invalidReleaseBundleRequest(
                requestedBuildID: "build-new",
                requestedBundleURL: bundle,
                expectedBundleIdentifier: "dev.agentpet.companion"
            )
        )
        #expect(invalidRelease.origin == .invalidReleaseBundle)
    }

    @MainActor
    @Test
    func copiedCanonicalReleaseCanTakeOverTheSameNoncanonicalBuild() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloaded = root.appendingPathComponent("Downloaded.app", isDirectory: true)
        let canonical = root.appendingPathComponent("Applications.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for bundle in [downloaded, canonical] {
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            let resources = contents.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(
                at: resources,
                withIntermediateDirectories: true
            )
            let plist = try PropertyListSerialization.data(
                fromPropertyList: [
                    "APCBuildID": "build-new",
                    "APCReleaseChannel": "release",
                    "CFBundleIdentifier": "dev.agentpet.companion",
                    "CFBundleShortVersionString": "0.1.0",
                    "CFBundleVersion": "1"
                ],
                format: .xml,
                options: 0
            )
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            try JSONEncoder().encode(
                runtimeManifest(buildID: "build-new", releaseChannel: "release")
            ).write(to: resources.appendingPathComponent("runtime-manifest.json"))
        }

        #expect(AppUpdateHandoffCoordinator.shouldHandoff(
            launchedBuildID: "build-new",
            requestedBuildID: "build-new",
            requestedBundleURL: canonical,
            expectedBundleIdentifier: "dev.agentpet.companion",
            launchedBundleURL: downloaded,
            canonicalBundleURL: canonical
        ))
        #expect(!AppUpdateHandoffCoordinator.shouldHandoff(
            launchedBuildID: "build-new",
            requestedBuildID: "build-new",
            requestedBundleURL: downloaded,
            expectedBundleIdentifier: "dev.agentpet.companion",
            launchedBundleURL: canonical,
            canonicalBundleURL: canonical
        ))
    }

    @Test
    func primaryReleaseLaunchFailsClosedForMissingOrMismatchedManifest() {
        let outside = URL(fileURLWithPath: "/tmp/AgentPetCompanion.app")
        let canonical = AppInstallationPolicy.canonicalBundleURL
        let valid = runtimeManifest(buildID: "build-new", releaseChannel: "release")

        let outsideRequest = AppInstallationPolicy.primaryLaunchRequest(
            bundleURL: outside,
            manifest: valid,
            infoBundleIdentifier: "dev.agentpet.companion",
            infoReleaseChannel: "release",
            infoBuildID: "build-new",
            infoVersion: "0.1.0",
            infoBuild: "1"
        )
        #expect(outsideRequest?.origin == .launchedOutsideApplications)

        let missingManifest = AppInstallationPolicy.primaryLaunchRequest(
            bundleURL: outside,
            manifest: nil,
            infoBundleIdentifier: "dev.agentpet.companion",
            infoReleaseChannel: "release",
            infoBuildID: "build-new",
            infoVersion: "0.1.0",
            infoBuild: "1"
        )
        #expect(missingManifest?.origin == .invalidReleaseBundle)

        let mismatchedIdentity = AppInstallationPolicy.primaryLaunchRequest(
            bundleURL: canonical,
            manifest: valid,
            infoBundleIdentifier: "dev.agentpet.companion",
            infoReleaseChannel: "release",
            infoBuildID: "forged",
            infoVersion: "0.1.0",
            infoBuild: "1"
        )
        #expect(mismatchedIdentity?.origin == .invalidReleaseBundle)

        let canonicalValid = AppInstallationPolicy.primaryLaunchRequest(
            bundleURL: canonical,
            manifest: valid,
            infoBundleIdentifier: "dev.agentpet.companion",
            infoReleaseChannel: "release",
            infoBuildID: "build-new",
            infoVersion: "0.1.0",
            infoBuild: "1"
        )
        #expect(canonicalValid == nil)

        let wrongBundle = AppInstallationPolicy.primaryLaunchRequest(
            bundleURL: canonical,
            manifest: valid,
            infoBundleIdentifier: "dev.agentpet.fake",
            infoReleaseChannel: "release",
            infoBuildID: "build-new",
            infoVersion: "0.1.0",
            infoBuild: "1"
        )
        #expect(wrongBundle?.origin == .invalidReleaseBundle)
    }

    @Test
    func installationPolicyReadsOnlyTheBundleLocalManifestAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent(
            "AgentPetCompanion.app",
            isDirectory: true
        )
        let resources = bundle.appendingPathComponent(
            "Contents/Resources",
            isDirectory: true
        )
        let symlink = root.appendingPathComponent(
            "LinkedAgentPetCompanion.app",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        let manifest = runtimeManifest(
            buildID: "bundle-local",
            releaseChannel: "release"
        )
        try JSONEncoder().encode(manifest).write(
            to: resources.appendingPathComponent("runtime-manifest.json")
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: bundle
        )

        #expect(
            AppInstallationPolicy.bundleLocalManifest(bundleURL: bundle)
                == manifest
        )
        #expect(AppInstallationPolicy.isCanonicalBundle(
            bundle,
            canonicalBundleURL: bundle
        ))
        #expect(!AppInstallationPolicy.isCanonicalBundle(
            symlink,
            canonicalBundleURL: symlink
        ))
    }

    @Test
    func managedRuntimePointersDistinguishUpgradeFromFreshInstallation() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtime = home.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let currentURL = runtime.appendingPathComponent("current.json")
        let previousURL = runtime.appendingPathComponent("last-known-good.json")
        try JSONEncoder().encode(
            InstalledPetCoreRuntime(buildID: "build-new")
        ).write(to: currentURL)

        #expect(!PetCoreRuntimeUpgradeEvidence.hasPriorManagedBuild(
            currentBuildID: "build-new",
            homeURL: home
        ))
        #expect(!PetCoreRuntimeUpgradeEvidence.hasManagedUpdateContext(
            currentBuildID: "build-new",
            homeURL: home
        ))
        #expect(PetCoreRuntimeUpgradeEvidence.hasManagedUpdateContext(
            currentBuildID: "build-next",
            homeURL: home
        ))

        try JSONEncoder().encode(
            InstalledPetCoreRuntime(buildID: "build-old")
        ).write(to: previousURL)
        #expect(PetCoreRuntimeUpgradeEvidence.hasPriorManagedBuild(
            currentBuildID: "build-new",
            homeURL: home
        ))
        #expect(PetCoreRuntimeUpgradeEvidence.hasManagedUpdateContext(
            currentBuildID: "build-new",
            homeURL: home
        ))
        #expect(!PetCoreRuntimeUpgradeEvidence.hasPriorManagedBuild(
            currentBuildID: "another-build",
            homeURL: home
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
    func deferredNestedRecoveryRetriesThroughTheFullBootstrapPipeline() async {
        let probe = AppStoreBootstrapProbe(results: [
            .deferred(reason: "正在等待当前宠物制作完成"),
            .started,
        ])
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { await probe.nextResult() },
                refreshSnapshot: { _ in },
                onReady: { _ in await probe.recordReady() }
            )
        )

        #expect(!(await store.recoverServiceConnection()))
        #expect(store.appUpdateConvergenceState == .waitingForActiveWork)
        #expect(store.petCoreOperationalState == .checking)

        #expect(await store.recoverServiceConnection())
        let snapshot = await probe.snapshot()
        #expect(snapshot.attempts == 2)
        #expect(snapshot.readyCount == 1)
        #expect(store.appUpdateConvergenceState == .updating)
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
        releaseChannel: String = "develop",
        codexContract: String = "codex-hooks.v1",
        petpackSchemaVersion: String = "apc.petpack.v3",
        petpackReadVersions: [String] = ["apc.petpack.v3"],
        petpackWriteVersion: String = "apc.petpack.v3"
    ) -> RuntimeReleaseManifest {
        RuntimeReleaseManifest(
            schemaVersion: RuntimeReleaseManifest.schemaVersion,
            releaseChannel: releaseChannel,
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
                opencode: "opencode-plugin.v1",
                dsh: "dsh-plugin.v1"
            )
        )
    }

    private func publishedV021RuntimeManifest() -> RuntimeReleaseManifest {
        publishedV1RuntimeManifest(
            appVersion: "0.2.1",
            appBuild: "5",
            buildID: "0.2.1.5.ce1c8cdd9d080dc2f2a7d13e20829f90dc3c82cd",
            maximumDatabaseSchemaVersion: 6
        )
    }

    private func publishedV1RuntimeManifest(
        appVersion: String,
        appBuild: String,
        buildID: String,
        maximumDatabaseSchemaVersion: UInt32
    ) -> RuntimeReleaseManifest {
        RuntimeReleaseManifest(
            schemaVersion: RuntimeReleaseManifest.schemaVersion,
            releaseChannel: "release",
            appVersion: appVersion,
            appBuild: appBuild,
            buildID: buildID,
            petCoreRPCProtocol: PetCoreRuntimeContract.requiredRPCProtocol,
            petCoreBuildID: buildID,
            petCoreCLIBuildID: buildID,
            minimumDatabaseSchemaVersion: 0,
            maximumDatabaseSchemaVersion: maximumDatabaseSchemaVersion,
            agentEventSchemaVersion: "apc.agent-event.v1",
            petpackSchemaVersion: "apc.petpack.v1",
            petpackReadVersions: ["apc.petpack.v1"],
            petpackWriteVersion: "apc.petpack.v1",
            connectorContracts: RuntimeConnectorContracts(
                codex: "codex-hooks-2026-07-17-schema-v6",
                claudeCode: "claude-hooks-2026-07-17-activity-v5",
                pi: "pi-extension-0.80.10-activity-v7",
                opencode: "opencode-v1.18.0-activity-v8",
                dsh: "dsh-v0.1.0-rc.6-events-v1"
            )
        )
    }

    private func installManagedRuntime(
        _ manifest: RuntimeReleaseManifest,
        homeURL: URL,
        fileManager: FileManager
    ) throws {
        let directory = homeURL
            .appendingPathComponent("runtime/versions", isDirectory: true)
            .appendingPathComponent(manifest.buildID, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: directory.appendingPathComponent("petcore")
        )
        try fileManager.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: directory.appendingPathComponent("petcore-cli")
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent("runtime-manifest.json")
        )
        try Data("test-attestation".utf8).write(
            to: directory.appendingPathComponent("interaction-attestation.json")
        )
    }

    private func writeRuntimePointer(
        _ pointer: InstalledPetCoreRuntime,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(pointer).write(to: url)
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

private actor RuntimeUpgradeTransactionProbe {
    private var events: [String] = []

    func record(_ event: String, failure: String? = nil) throws {
        events.append(event)
        if let failure {
            throw RuntimeUpgradeTransactionProbeError.failed(failure)
        }
    }

    func snapshot() -> [String] { events }
}

private enum RuntimeUpgradeTransactionProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): message
        }
    }
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
