import AgentPetCompanionCore
import Darwin
import Foundation

enum PetCoreRuntimeContract {
    static let requiredRPCProtocol = "apc.petcore-rpc.v2"
    static let requiredGenerationEnvironment = [
        "APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK": "0",
        "APC_REQUIRE_SKILL_FULL_SOURCE": "1",
        "APC_REQUIRE_EXTERNAL_SKILL_SOURCE": "1"
    ]
    static let requiredManifestURL: URL? = {
        if let override = ProcessInfo.processInfo.environment["APC_RUNTIME_MANIFEST_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        let url = Bundle.main.resourceURL?.appendingPathComponent("runtime-manifest.json")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }()
    static let requiredManifest: RuntimeReleaseManifest? = {
        guard let requiredManifestURL else { return nil }
        return try? RuntimeReleaseManifest.read(from: requiredManifestURL)
    }()
    static let requiredBuildID: String? = {
        if let override = ProcessInfo.processInfo.environment["APC_BUILD_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return override
        }
        if let manifest = requiredManifest {
            return manifest.buildID
        }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "APCBuildID") as? String {
            let value = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }()

    static func acceptsHealth(
        _ result: Any,
        expectedBuildID: String? = requiredBuildID,
        expectedManifest: RuntimeReleaseManifest? = requiredManifest,
        expectedConnectorEnvironment: [String: String]? = nil
    ) -> Bool {
        guard let health = result as? [String: Any] else { return false }
        guard health["ok"] as? Bool == true,
              health["rpc_protocol"] as? String == requiredRPCProtocol
        else { return false }
        if let expectedBuildID, health["build_id"] as? String != expectedBuildID {
            return false
        }
        if let expectedManifest {
            guard RuntimeReleaseManifest.decodeHealthValue(health["runtime_manifest"])
                    == expectedManifest
            else { return false }
        }
        if let expectedConnectorEnvironment {
            guard let rawEnvironment = health["connector_environment"] as? [String: Any]
            else { return false }
            let connectorEnvironment = rawEnvironment.compactMapValues { $0 as? String }
            guard connectorEnvironment.count == rawEnvironment.count,
                  connectorEnvironment == expectedConnectorEnvironment
            else { return false }
        }
        return true
    }

    static func incompatibleInstanceID(
        _ result: Any,
        expectedBuildID: String? = requiredBuildID,
        expectedManifest: RuntimeReleaseManifest? = requiredManifest,
        expectedConnectorEnvironment: [String: String]? = nil
    ) -> String? {
        guard !acceptsHealth(
                  result,
                  expectedBuildID: expectedBuildID,
                  expectedManifest: expectedManifest,
                  expectedConnectorEnvironment: expectedConnectorEnvironment
              ),
              let health = result as? [String: Any],
              health["ok"] as? Bool == true,
              let instanceID = health["instance_id"] as? String,
              !instanceID.isEmpty
        else { return nil }
        return instanceID
    }
}

enum PetCoreServiceEnvironmentPolicy {
    static let connectorPathKeys = [
        "CODEX_HOME",
        "CLAUDE_CONFIG_DIR",
        "PI_CODING_AGENT_DIR",
        "OPENCODE_CONFIG_DIR",
        "OPENCODE_CONFIG",
        "XDG_CONFIG_HOME",
        "APC_CODEX_CLI_PATH",
        "APC_CLAUDE_CLI_PATH",
        "APC_PI_CLI_PATH",
        "APC_OPENCODE_CLI_PATH"
    ]

    static func userPathEnvironment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        let normalizedHome = URL(
            fileURLWithPath: userHome,
            isDirectory: true
        ).standardizedFileURL.path
        var result = ["HOME": normalizedHome]
        for key in connectorPathKeys {
            guard let raw = processEnvironment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty
            else { continue }
            let expanded: String
            if raw == "~" {
                expanded = normalizedHome
            } else if raw.hasPrefix("~/") {
                expanded = URL(fileURLWithPath: normalizedHome, isDirectory: true)
                    .appendingPathComponent(String(raw.dropFirst(2)))
                    .path
            } else {
                expanded = raw
            }
            guard (expanded as NSString).isAbsolutePath else { continue }
            result[key] = URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return result
    }

    static func defaultExecutableSearchPaths(
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> [String] {
        var paths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            userHome + "/.local/bin",
            userHome + "/.cargo/bin",
            userHome + "/.bun/bin",
            userHome + "/.opencode/bin",
            userHome + "/.volta/bin",
            userHome + "/.asdf/shims",
            userHome + "/.local/share/mise/shims",
            userHome + "/.fnm/current/bin",
            userHome + "/.nvm/current/bin",
            userHome + "/.nodenv/shims",
            userHome + "/.npm-global/bin",
            userHome + "/.local/share/pnpm",
            userHome + "/Library/pnpm",
            userHome + "/.yarn/bin",
            userHome + "/bin"
        ]
        paths.append(contentsOf: versionManagerBinPaths(
            root: userHome + "/.nvm/versions/node",
            suffix: "bin",
            fileManager: fileManager
        ))
        paths.append(contentsOf: versionManagerBinPaths(
            root: userHome + "/.local/share/fnm/node-versions",
            suffix: "installation/bin",
            fileManager: fileManager
        ))
        return paths
    }

    static func executableSearchPath(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> String {
        let current = (processEnvironment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidates = current + defaultExecutableSearchPaths(
            userHome: userHome,
            fileManager: fileManager
        )
        var seen = Set<String>()
        var paths: [String] = []
        for candidate in candidates {
            guard (candidate as NSString).isAbsolutePath else { continue }
            let normalized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { continue }
            paths.append(normalized)
        }
        return paths.joined(separator: ":")
    }

    static func serviceIdentityEnvironment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> [String: String] {
        var environment = userPathEnvironment(
            processEnvironment: processEnvironment,
            userHome: userHome
        )
        environment["PATH"] = executableSearchPath(
            processEnvironment: processEnvironment,
            userHome: userHome,
            fileManager: fileManager
        )
        return environment
    }

    private static func versionManagerBinPaths(
        root: String,
        suffix: String,
        fileManager: FileManager
    ) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else {
            return []
        }
        let candidates = entries.sorted().compactMap { entry -> String? in
            let candidate = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(entry, isDirectory: true)
                .appendingPathComponent(suffix, isDirectory: true)
                .standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }
            return candidate
        }
        return Array(candidates.prefix(32))
    }
}

struct PetCoreLaunchctlInvocation: Equatable, Sendable {
    let arguments: [String]
    let allowsFailure: Bool
}

struct PetCoreLaunchAgentPlan: Equatable, Sendable {
    let beforePropertyListWrite: [PetCoreLaunchctlInvocation]
    let afterPropertyListWrite: [PetCoreLaunchctlInvocation]

    var invocations: [PetCoreLaunchctlInvocation] {
        beforePropertyListWrite + afterPropertyListWrite
    }

    static func make(
        configurationChanged: Bool,
        isLoaded: Bool,
        domain: String,
        label: String,
        propertyListPath: String
    ) -> PetCoreLaunchAgentPlan {
        let domainAndLabel = "\(domain)/\(label)"
        if configurationChanged {
            return PetCoreLaunchAgentPlan(
                beforePropertyListWrite: [
                    PetCoreLaunchctlInvocation(
                        arguments: ["bootout", domainAndLabel],
                        allowsFailure: true
                    )
                ],
                afterPropertyListWrite: [
                    PetCoreLaunchctlInvocation(
                        arguments: ["bootstrap", domain, propertyListPath],
                        allowsFailure: false
                    )
                ]
            )
        }
        if !isLoaded {
            return PetCoreLaunchAgentPlan(
                beforePropertyListWrite: [],
                afterPropertyListWrite: [
                    PetCoreLaunchctlInvocation(
                        arguments: ["bootstrap", domain, propertyListPath],
                        allowsFailure: false
                    )
                ]
            )
        }
        return PetCoreLaunchAgentPlan(
            beforePropertyListWrite: [],
            afterPropertyListWrite: [
                PetCoreLaunchctlInvocation(
                    arguments: ["kickstart", "-k", domainAndLabel],
                    allowsFailure: false
                )
            ]
        )
    }
}

enum PetCoreLaunchControlPolicy {
    static func shouldBootoutGlobalLaunchAgent(launchAgentDisabled: Bool) -> Bool {
        !launchAgentDisabled
    }
}

enum PetCoreLaunchAgentMigrationPolicy {
    static func requiresLegacyOutputMigration(
        launchAgentDisabled: Bool,
        hasInstalledPropertyList: Bool,
        standardOutPath: String?,
        standardErrorPath: String?
    ) -> Bool {
        guard !launchAgentDisabled, hasInstalledPropertyList else { return false }
        return standardOutPath != "/dev/null" || standardErrorPath != "/dev/null"
    }
}

enum PetCoreRuntimeReplacementSafetyPolicy {
    enum Assessment: Equatable {
        case safe
        case protectedWork
        case legacyConnectionStateNeedsProbe
        case unknown
    }

    static func assess(snapshotValue: Any) -> Assessment {
        guard let snapshot = snapshotValue as? [String: Any],
              let activeGeneration = snapshot["active_generation"]
        else { return .unknown }

        let generationProtected: Bool
        if activeGeneration is NSNull {
            generationProtected = false
        } else if let generation = activeGeneration as? [String: Any],
                  let status = generation["status"] as? String
        {
            switch status {
            case "pending", "running":
                generationProtected = true
            case "waiting_for_user":
                // Waiting input is durable PetCore state. Replacing the runtime
                // lets the new App restore the prompt; deferring here would
                // deadlock because no UI is connected to answer it.
                generationProtected = false
            default:
                return .unknown
            }
        } else {
            return .unknown
        }

        if generationProtected {
            return .protectedWork
        }
        guard let connectionOperation = snapshot["connection_operation_active"]
        else {
            // Released v0.1.x runtimes already serialized connection
            // operations, but did not project that gate into state.snapshot.
            // Never silently treat the missing field as idle: the launcher
            // performs a compatible gated diagnostic probe before shutdown.
            return .legacyConnectionStateNeedsProbe
        }
        guard let connectionOperation = connectionOperation as? Bool else {
            return .unknown
        }
        return connectionOperation ? .protectedWork : .safe
    }

    static func assessLegacyConnectionProbeError(_ error: Error) -> Assessment {
        guard case let PetCoreClientError.rpcError(message) = error,
              message.contains("another Agent connection operation is already running")
        else { return .unknown }
        return .protectedWork
    }

    static func shouldDeferAfterSnapshotError(_ error: Error) -> Bool {
        guard let transportError = error as? PetCoreTransportError,
              case let .systemCall(operation, code) = transportError,
              operation == "connect",
              code == ENOENT || code == ECONNREFUSED
        else {
            // Timeouts, malformed responses, RPC errors, and failures after a
            // successful connect mean a prior runtime may still own work.
            return true
        }
        return false
    }
}

actor PetCoreProcessManager {
    typealias HealthCheck = PetCoreServiceStartupCoordinator.HealthCheck
    typealias ServiceRunner = PetCoreServiceStartupCoordinator.ServiceRunner
    typealias Sleeper = PetCoreServiceStartupCoordinator.Sleeper

    private let coordinator: PetCoreServiceStartupCoordinator

    init() {
        let homeURL = Self.appSupportHomeURL()
        let socketPath = homeURL
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("petcore.sock")
            .path
        let client = PetCoreClient(socketPath: socketPath)
        let launcher = PetCoreServiceLauncher(homeURL: homeURL)
        coordinator = PetCoreServiceStartupCoordinator(
            healthCheck: {
                do {
                    let response = try await client.requestData(
                        method: "petcore.health",
                        timeout: .milliseconds(200)
                    )
                    let result = try PetCoreClient.decodeResult(from: response)
                    if PetCoreRuntimeContract.acceptsHealth(
                        result,
                        expectedConnectorEnvironment: PetCoreServiceEnvironmentPolicy
                            .serviceIdentityEnvironment()
                    ) {
                        if await launcher.requiresLegacyLaunchOutputMigration() {
                            return false
                        }
                        try? await launcher.recordHealthyCurrentRuntime()
                        return true
                    }
                    return false
                } catch {
                    return false
                }
            },
            launchctlRunner: {
                try await launcher.startUsingLaunchAgent()
            },
            directRunner: {
                try await launcher.startDirectly()
            },
            healthCheckAttempts: 10,
            sleep: { duration in
                try? await Task.sleep(for: duration)
            }
        )
    }

    init(
        healthCheck: @escaping HealthCheck,
        launchctlRunner: @escaping ServiceRunner,
        directRunner: @escaping ServiceRunner,
        healthCheckAttempts: Int,
        sleep: @escaping Sleeper
    ) {
        coordinator = PetCoreServiceStartupCoordinator(
            healthCheck: healthCheck,
            launchctlRunner: launchctlRunner,
            directRunner: directRunner,
            healthCheckAttempts: healthCheckAttempts,
            sleep: sleep
        )
    }

    func ensureRunning() async -> ServiceStartResult {
        await coordinator.ensureRunning()
    }

    private static func appSupportHomeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["APC_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("AgentPetCompanion", isDirectory: true)
    }

}

private actor PetCoreServiceLauncher {
    private let launchAgentLabel = "dev.agentpet.petcore"
    private let homeURL: URL
    private let runtimeStore: PetCoreRuntimeStore
    private var process: Process?
    private var logHandle: FileHandle?

    init(homeURL: URL) {
        self.homeURL = homeURL
        runtimeStore = PetCoreRuntimeStore(homeURL: homeURL)
    }

    func recordHealthyCurrentRuntime() async throws {
        let candidate = try await prepareCandidate()
        try await runtimeStore.commitHealthy(candidate)
    }

    func requiresLegacyLaunchOutputMigration() -> Bool {
        guard !launchAgentDisabled, let launchAgentsURL = launchAgentsDirectoryURL() else {
            return false
        }
        let propertyListURL = launchAgentsURL.appendingPathComponent("\(launchAgentLabel).plist")
        var status = stat()
        guard lstat(propertyListURL.path, &status) == 0 else {
            return false
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_size > 0,
              status.st_size <= 1_024 * 1_024,
              let data = securePropertyListData(
                  at: propertyListURL,
                  expectedStatus: status
              ),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else {
            // An installed but unreadable or unsafe property list must not be accepted as
            // migrated. The existing restart path will replace it atomically or surface a
            // bounded startup failure instead of silently keeping unbounded launchd output.
            return true
        }
        return PetCoreLaunchAgentMigrationPolicy.requiresLegacyOutputMigration(
            launchAgentDisabled: false,
            hasInstalledPropertyList: true,
            standardOutPath: propertyList["StandardOutPath"] as? String,
            standardErrorPath: propertyList["StandardErrorPath"] as? String
        )
    }

    private func securePropertyListData(at url: URL, expectedStatus: stat) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_dev == expectedStatus.st_dev,
              openedStatus.st_ino == expectedStatus.st_ino,
              openedStatus.st_mode & S_IFMT == S_IFREG,
              openedStatus.st_uid == getuid(),
              openedStatus.st_nlink == 1,
              openedStatus.st_size == expectedStatus.st_size
        else { return nil }
        var data = Data(count: Int(openedStatus.st_size))
        let bytesRead = data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            var total = 0
            while total < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: total),
                    bytes.count - total
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                total += count
            }
            return total
        }
        return bytesRead == data.count ? data : nil
    }

    func startUsingLaunchAgent() async throws {
        guard !launchAgentDisabled else {
            throw PetCoreServiceLauncherError.message("LaunchAgent 已由 APC_DISABLE_LAUNCH_AGENT 禁用")
        }
        let candidate = try await prepareCandidate()
        try await start(candidate, mode: .launchAgent, allowsRollback: true)
    }

    func startDirectly() async throws {
        let candidate = try await prepareCandidate()
        try await start(candidate, mode: .direct, allowsRollback: true)
    }

    private enum LaunchMode {
        case launchAgent
        case direct
    }

    private func prepareCandidate() async throws -> PreparedPetCoreRuntime {
        guard let executable = locatePetCore() else {
            throw PetCoreServiceLauncherError.message("未找到 petcore 可执行文件")
        }
        guard let cli = locatePetCoreCLI() else {
            throw PetCoreServiceLauncherError.message("未找到 petcore-cli 可执行文件")
        }
        return try await runtimeStore.prepareCandidate(
            sourceExecutableURL: URL(fileURLWithPath: executable),
            sourceCLIURL: URL(fileURLWithPath: cli),
            sourceManifestURL: PetCoreRuntimeContract.requiredManifestURL
        )
    }

    private func start(
        _ candidate: PreparedPetCoreRuntime,
        mode: LaunchMode,
        allowsRollback: Bool
    ) async throws {
        // A protected deferral is not a candidate failure and must never enter
        // the rollback transaction below. The prior runtime remains untouched.
        try await deferRuntimeReplacementWhileProtectedWorkIsActive(candidate)
        do {
            // A loaded KeepAlive job would immediately respawn the old binary after shutdown.
            // Explicit direct/isolated validation mode must never touch the user's global
            // launchd job; normal launch-agent and direct fallback flows still own it.
            if PetCoreLaunchControlPolicy.shouldBootoutGlobalLaunchAgent(
                launchAgentDisabled: launchAgentDisabled
            ) {
                _ = await runLaunchctl(["bootout", launchDomainAndLabel()])
            }
            await shutdownActiveRuntime()
            await waitForPriorRuntimeExit()
            switch mode {
            case .launchAgent:
                try await performLaunchAgentStart(candidate)
            case .direct:
                try await performDirectStart(candidate)
            }
            guard await waitForHealth(candidate) else {
                throw PetCoreServiceLauncherError.message("候选 PetCore 启动后未通过版本与健康检查")
            }
            try await runtimeStore.commitHealthy(candidate)
        } catch {
            guard allowsRollback, let previous = candidate.previous else { throw error }
            let original = error.localizedDescription
            do {
                let rollback = try await runtimeStore.resolve(previous)
                try await start(rollback, mode: mode, allowsRollback: false)
                throw PetCoreServiceLauncherError.message(
                    "PetCore 更新失败，已恢复上一个可用版本：\(original)"
                )
            } catch let rollbackError as PetCoreServiceLauncherError {
                if rollbackError.localizedDescription.hasPrefix("PetCore 更新失败，已恢复") {
                    throw rollbackError
                }
                throw PetCoreServiceLauncherError.message(
                    "PetCore 更新失败且回滚未完成：\(original)；回滚：\(rollbackError.localizedDescription)"
                )
            } catch {
                throw PetCoreServiceLauncherError.message(
                    "PetCore 更新失败且回滚未完成：\(original)；回滚：\(error.localizedDescription)"
                )
            }
        }
    }

    private func deferRuntimeReplacementWhileProtectedWorkIsActive(
        _ candidate: PreparedPetCoreRuntime
    ) async throws {
        guard candidate.isManaged else { return }
        let socketPath = homeURL
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("petcore.sock")
            .path
        let client = PetCoreClient(socketPath: socketPath)
        do {
            let response = try await client.requestData(
                method: "state.snapshot",
                timeout: .milliseconds(500)
            )
            let snapshot = try PetCoreClient.decodeResult(from: response)
            switch PetCoreRuntimeReplacementSafetyPolicy.assess(
                snapshotValue: snapshot
            ) {
            case .safe:
                return
            case .protectedWork:
                throw ServiceStartupDeferredError(
                    reason: "正在等待当前任务完成，再继续更新本地服务"
                )
            case .legacyConnectionStateNeedsProbe:
                try await requireLegacyConnectionOperationsAreIdle(client: client)
            case .unknown:
                throw ServiceStartupDeferredError(
                    reason: "暂时无法确认当前任务状态，稍后会自动重试本地服务更新"
                )
            }
        } catch let deferred as ServiceStartupDeferredError {
            throw deferred
        } catch {
            guard PetCoreRuntimeReplacementSafetyPolicy
                .shouldDeferAfterSnapshotError(error)
            else {
                // No process accepted the Unix-domain connection. A stale or
                // absent socket cannot own active work, so replacement may
                // continue through the bounded transaction.
                return
            }
            throw ServiceStartupDeferredError(
                reason: "暂时无法确认当前任务状态，稍后会自动重试本地服务更新"
            )
        }
    }

    private func requireLegacyConnectionOperationsAreIdle(
        client: PetCoreClient
    ) async throws {
        let params = try JSONSerialization.data(
            withJSONObject: ["source": "codex"]
        )
        do {
            let response = try await client.requestData(
                method: "connections.test",
                paramsJSONData: params,
                timeout: .seconds(2)
            )
            _ = try PetCoreClient.decodeResult(from: response)
        } catch {
            switch PetCoreRuntimeReplacementSafetyPolicy
                .assessLegacyConnectionProbeError(error)
            {
            case .protectedWork:
                throw ServiceStartupDeferredError(
                    reason: "正在等待当前 Agent 连接操作完成，再继续更新本地服务"
                )
            case .safe, .legacyConnectionStateNeedsProbe, .unknown:
                throw ServiceStartupDeferredError(
                    reason: "暂时无法确认旧版服务的连接操作状态，稍后会自动重试更新"
                )
            }
        }
    }

    private func performLaunchAgentStart(_ candidate: PreparedPetCoreRuntime) async throws {
        _ = try prepareRuntimePaths()
        guard let launchAgentsURL = launchAgentsDirectoryURL() else {
            throw PetCoreServiceLauncherError.message("无法定位用户 LaunchAgents 目录")
        }
        try FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        let plistURL = launchAgentsURL.appendingPathComponent("\(launchAgentLabel).plist")
        let data = try launchAgentPropertyList(candidate: candidate)
        try data.write(to: plistURL, options: .atomic)
        try await execute([
            PetCoreLaunchctlInvocation(
                arguments: ["bootstrap", launchDomain(), plistURL.path],
                allowsFailure: false
            )
        ])
    }

    private func performDirectStart(_ candidate: PreparedPetCoreRuntime) async throws {
        if let process, process.isRunning {
            process.terminate()
            self.process = nil
        }
        try? logHandle?.close()
        logHandle = nil
        let paths = try prepareRuntimePaths()
        try? FileManager.default.removeItem(at: paths.readyURL)
        logHandle = try AppLegacyLogMaintenance.openSecureAppendHandle(at: paths.logURL)

        let process = Process()
        process.executableURL = candidate.executableURL
        process.arguments = ["serve", "--home", homeURL.path, "--ready-file", paths.readyURL.path]
        process.environment = serviceEnvironment(for: candidate)
        process.standardOutput = logHandle
        process.standardError = logHandle
        let logURL = paths.logURL
        process.terminationHandler = { process in
            let message = "petcore exited with status \(process.terminationStatus)\n"
            guard let data = message.data(using: .utf8) else { return }
            try? AppLegacyLogMaintenance.appendSecurely(data, to: logURL)
        }
        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
            throw PetCoreServiceLauncherError.message("启动 petcore 失败：\(error.localizedDescription)")
        }
    }

    private func shutdownActiveRuntime() async {
        let client = PetCoreClient(socketPath: socketPath)
        guard let healthResponse = try? await client.requestData(
            method: "petcore.health",
            timeout: .milliseconds(200)
        ), let health = try? PetCoreClient.decodeResult(from: healthResponse),
        let value = health as? [String: Any],
        let instanceID = value["instance_id"] as? String,
        let params = try? JSONSerialization.data(withJSONObject: ["expected_instance_id": instanceID])
        else { return }
        guard let shutdownResponse = try? await client.requestData(
            method: "petcore.shutdown",
            paramsJSONData: params,
            timeout: .milliseconds(500)
        ) else { return }
        _ = try? PetCoreClient.decodeResult(from: shutdownResponse)
    }

    private func waitForHealth(_ candidate: PreparedPetCoreRuntime) async -> Bool {
        let client = PetCoreClient(socketPath: socketPath)
        for _ in 0 ..< 60 {
            if let response = try? await client.requestData(
                method: "petcore.health",
                timeout: .milliseconds(150)
            ), let result = try? PetCoreClient.decodeResult(from: response),
            PetCoreRuntimeContract.acceptsHealth(
                result,
                expectedBuildID: candidate.buildID,
                expectedManifest: candidate.manifest,
                expectedConnectorEnvironment: PetCoreServiceEnvironmentPolicy
                    .serviceIdentityEnvironment()
            ) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func waitForPriorRuntimeExit() async {
        let client = PetCoreClient(socketPath: socketPath)
        for _ in 0 ..< 25 {
            guard let response = try? await client.requestData(
                method: "petcore.health",
                timeout: .milliseconds(100)
            ), (try? PetCoreClient.decodeResult(from: response)) != nil
            else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private var socketPath: String {
        homeURL
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("petcore.sock")
            .path
    }

    private struct RuntimePaths {
        let readyURL: URL
        let logURL: URL
    }

    private func prepareRuntimePaths() throws -> RuntimePaths {
        let runURL = homeURL.appendingPathComponent("run", isDirectory: true)
        let logsURL = homeURL.appendingPathComponent("logs", isDirectory: true)
        let readyURL = runURL.appendingPathComponent("petcore.ready")
        let logURL = logsURL.appendingPathComponent("petcore-launch.log")
        do {
            try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
            try AppLegacyLogMaintenance.maintain(logsURL: logsURL)
            return RuntimePaths(readyURL: readyURL, logURL: logURL)
        } catch {
            throw PetCoreServiceLauncherError.message(
                "准备 petcore 运行目录失败：\(error.localizedDescription)"
            )
        }
    }

    private func locatePetCore() -> String? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("bin/petcore")
            .path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("../../target/debug/petcore").standardized.path,
            cwd.appendingPathComponent("target/debug/petcore").standardized.path
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func locatePetCoreCLI() -> String? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("bin/petcore-cli")
            .path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("../../target/debug/petcore-cli").standardized.path,
            cwd.appendingPathComponent("target/debug/petcore-cli").standardized.path
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var launchAgentDisabled: Bool {
        switch ProcessInfo.processInfo.environment["APC_DISABLE_LAUNCH_AGENT"]?.lowercased() {
        case "1", "true", "yes": true
        default: false
        }
    }

    private func launchAgentPropertyList(
        candidate: PreparedPetCoreRuntime
    ) throws -> Data {
        let environmentVariables = serviceEnvironment(for: candidate)
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [
                candidate.executableURL.path,
                "serve",
                "--home",
                homeURL.path
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            // PetCore owns its bounded structured log files. launchd output is
            // only a bootstrap sink and must never bypass that retention policy.
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
            "EnvironmentVariables": environmentVariables
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func serviceEnvironment(for candidate: PreparedPetCoreRuntime) -> [String: String] {
        var environment = PetCoreRuntimeContract.requiredGenerationEnvironment.merging([
            "APC_HOME": homeURL.path,
            "RUST_LOG": "info"
        ]) { _, serviceValue in serviceValue }
        environment.merge(PetCoreServiceEnvironmentPolicy.serviceIdentityEnvironment()) {
            _, userPathValue in userPathValue
        }
        if let buildID = candidate.buildID {
            environment["APC_EXPECTED_BUILD_ID"] = buildID
        }
        if let manifestURL = candidate.manifestURL {
            environment["APC_EXPECTED_RUNTIME_MANIFEST"] = manifestURL.path
        }
        return environment
    }

    private func launchAgentsDirectoryURL() -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private func isLaunchAgentLoaded() async -> Bool {
        await runLaunchctl(["print", launchDomainAndLabel()])
    }

    private func execute(_ invocations: [PetCoreLaunchctlInvocation]) async throws {
        for invocation in invocations {
            let succeeded = await runLaunchctl(invocation.arguments)
            if !succeeded, !invocation.allowsFailure {
                throw PetCoreServiceLauncherError.message(
                    "PetCore LaunchAgent 命令失败：\(invocation.arguments.joined(separator: " "))"
                )
            }
        }
    }

    private func launchDomain() -> String {
        "gui/\(getuid())"
    }

    private func launchDomainAndLabel() -> String {
        "\(launchDomain())/\(launchAgentLabel)"
    }

    private func runLaunchctl(_ arguments: [String]) async -> Bool {
        do {
            let result = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: arguments,
                timeout: .seconds(2),
                outputLimit: 64 * 1_024
            )
            return result.termination == .exited(status: 0)
        } catch {
            return false
        }
    }

}

private enum PetCoreServiceLauncherError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}
