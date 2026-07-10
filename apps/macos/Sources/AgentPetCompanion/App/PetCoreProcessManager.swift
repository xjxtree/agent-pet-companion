import AgentPetCompanionCore
import Darwin
import Foundation

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
                    arguments: ["kickstart", domainAndLabel],
                    allowsFailure: false
                )
            ]
        )
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
                    _ = try await client.request(
                        method: "petcore.health",
                        timeout: .milliseconds(200)
                    )
                    return true
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
    private var process: Process?
    private var logHandle: FileHandle?

    init(homeURL: URL) {
        self.homeURL = homeURL
    }

    func startUsingLaunchAgent() async throws {
        guard !launchAgentDisabled else {
            throw PetCoreServiceLauncherError.message("LaunchAgent 已由 APC_DISABLE_LAUNCH_AGENT 禁用")
        }
        let paths = try prepareRuntimePaths()
        guard let executable = locatePetCore() else {
            throw PetCoreServiceLauncherError.message("未找到 petcore 可执行文件")
        }
        guard let launchAgentsURL = launchAgentsDirectoryURL() else {
            throw PetCoreServiceLauncherError.message("无法定位用户 LaunchAgents 目录")
        }

        try FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        let plistURL = launchAgentsURL.appendingPathComponent("\(launchAgentLabel).plist")
        let data = try launchAgentPropertyList(
            executable: executable,
            logsURL: paths.logsURL
        )
        let previous = try? Data(contentsOf: plistURL)
        let configurationChanged = previous != data
        let isLoaded = configurationChanged ? false : await isLaunchAgentLoaded()
        let plan = PetCoreLaunchAgentPlan.make(
            configurationChanged: configurationChanged,
            isLoaded: isLoaded,
            domain: launchDomain(),
            label: launchAgentLabel,
            propertyListPath: plistURL.path
        )
        try await execute(plan.beforePropertyListWrite)
        if configurationChanged {
            try data.write(to: plistURL, options: .atomic)
        }
        try await execute(plan.afterPropertyListWrite)
    }

    func startDirectly() throws {
        let paths = try prepareRuntimePaths()
        if let process, process.isRunning {
            return
        }
        guard let executable = locatePetCore() else {
            throw PetCoreServiceLauncherError.message("未找到 petcore 可执行文件")
        }

        try? FileManager.default.removeItem(at: paths.readyURL)
        logHandle = try FileHandle(forWritingTo: paths.logURL)
        try logHandle?.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["serve", "--ready-file", paths.readyURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["APC_HOME"] = homeURL.path
        environment["RUST_LOG"] = "info"
        environment["APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK"] = "0"
        environment["APC_REQUIRE_SKILL_FULL_SOURCE"] = "1"
        process.environment = environment
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

    private var launchAgentDisabled: Bool {
        switch ProcessInfo.processInfo.environment["APC_DISABLE_LAUNCH_AGENT"]?.lowercased() {
        case "1", "true", "yes": true
        default: false
        }
    }

    private func launchAgentPropertyList(executable: String, logsURL: URL) throws -> Data {
        let stdoutURL = logsURL.appendingPathComponent("petcore.launchd.out.log")
        let stderrURL = logsURL.appendingPathComponent("petcore.launchd.err.log")
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [
                executable,
                "serve",
                "--home",
                homeURL.path
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": stdoutURL.path,
            "StandardErrorPath": stderrURL.path,
            "EnvironmentVariables": [
                "APC_HOME": homeURL.path,
                "RUST_LOG": "info",
                "APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK": "0",
                "APC_REQUIRE_SKILL_FULL_SOURCE": "1",
                "PATH": launchAgentPathEnvironment()
            ]
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
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
