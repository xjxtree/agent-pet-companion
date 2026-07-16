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
        expectedManifest: RuntimeReleaseManifest? = requiredManifest
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
        return true
    }

    static func incompatibleInstanceID(
        _ result: Any,
        expectedBuildID: String? = requiredBuildID,
        expectedManifest: RuntimeReleaseManifest? = requiredManifest
    ) -> String? {
        guard !acceptsHealth(
                  result,
                  expectedBuildID: expectedBuildID,
                  expectedManifest: expectedManifest
              ),
              let health = result as? [String: Any],
              health["ok"] as? Bool == true,
              let instanceID = health["instance_id"] as? String,
              !instanceID.isEmpty
        else { return nil }
        return instanceID
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
                    if PetCoreRuntimeContract.acceptsHealth(result) {
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
        await refreshInstalledConnectorReferences(using: candidate)
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
            await refreshInstalledConnectorReferences(using: candidate)
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

    private func refreshInstalledConnectorReferences(using runtime: PreparedPetCoreRuntime) async {
        guard runtime.isManaged else { return }
        _ = try? await BoundedProcessRunner.run(
            executableURL: runtime.cliURL,
            arguments: ["connections", "refresh-installed"],
            timeout: .seconds(10),
            outputLimit: 16 * 1_024
        )
    }

    private func performLaunchAgentStart(_ candidate: PreparedPetCoreRuntime) async throws {
        let paths = try prepareRuntimePaths()
        guard let launchAgentsURL = launchAgentsDirectoryURL() else {
            throw PetCoreServiceLauncherError.message("无法定位用户 LaunchAgents 目录")
        }
        try FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        let plistURL = launchAgentsURL.appendingPathComponent("\(launchAgentLabel).plist")
        let data = try launchAgentPropertyList(candidate: candidate, logsURL: paths.logsURL)
        try data.write(to: plistURL, options: .atomic)
        try await execute([
            PetCoreLaunchctlInvocation(
                arguments: ["bootstrap", launchDomain(), plistURL.path],
                allowsFailure: false
            )
        ])
    }

    private func performDirectStart(_ candidate: PreparedPetCoreRuntime) async throws {
        let paths = try prepareRuntimePaths()
        if let process, process.isRunning {
            process.terminate()
            self.process = nil
        }
        try? FileManager.default.removeItem(at: paths.readyURL)
        logHandle = try FileHandle(forWritingTo: paths.logURL)
        try logHandle?.seekToEnd()

        let process = Process()
        process.executableURL = candidate.executableURL
        process.arguments = ["serve", "--home", homeURL.path, "--ready-file", paths.readyURL.path]
        process.environment = serviceEnvironment(for: candidate)
        process.standardOutput = logHandle
        process.standardError = logHandle
        let logURL = paths.logURL
        process.terminationHandler = { process in
            let message = "petcore exited with status \(process.terminationStatus)\n"
            guard let data = message.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: logURL)
            else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
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
                expectedManifest: candidate.manifest
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
        let logsURL: URL
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
            try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            return RuntimePaths(logsURL: logsURL, readyURL: readyURL, logURL: logURL)
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
        candidate: PreparedPetCoreRuntime,
        logsURL: URL
    ) throws -> Data {
        let stdoutURL = logsURL.appendingPathComponent("petcore.launchd.out.log")
        let stderrURL = logsURL.appendingPathComponent("petcore.launchd.err.log")
        var environmentVariables = serviceEnvironment(for: candidate)
        environmentVariables["PATH"] = launchAgentPathEnvironment()
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
            "StandardOutPath": stdoutURL.path,
            "StandardErrorPath": stderrURL.path,
            "EnvironmentVariables": environmentVariables
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func serviceEnvironment(for candidate: PreparedPetCoreRuntime) -> [String: String] {
        var environment = PetCoreRuntimeContract.requiredGenerationEnvironment.merging([
            "APC_HOME": homeURL.path,
            "RUST_LOG": "info",
            "PATH": launchAgentPathEnvironment()
        ]) { _, serviceValue in serviceValue }
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

    private func launchAgentPathEnvironment() -> String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let additions = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/.cargo/bin",
            NSHomeDirectory() + "/.bun/bin",
            NSHomeDirectory() + "/bin"
        ]

        var seen = Set<String>()
        var parts: [String] = []
        for path in current.split(separator: ":").map(String.init) + additions {
            guard !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            parts.append(path)
        }
        return parts.joined(separator: ":")
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
