import Foundation

public enum ServiceStartResult: Equatable, Sendable {
    case alreadyHealthy
    case started
    case failed(reason: String)
}

public actor PetCoreServiceStartupCoordinator {
    public typealias HealthCheck = @Sendable () async -> Bool
    public typealias ServiceRunner = @Sendable () async throws -> Void
    public typealias Sleeper = @Sendable (Duration) async -> Void

    private struct Dependencies: Sendable {
        let healthCheck: HealthCheck
        let launchctlRunner: ServiceRunner
        let directRunner: ServiceRunner
        let healthCheckAttempts: Int
        let sleep: Sleeper
    }

    private let dependencies: Dependencies
    private var startupSequence: UInt64 = 0
    private var startup: (id: UInt64, task: Task<ServiceStartResult, Never>)?

    public init(
        healthCheck: @escaping HealthCheck,
        launchctlRunner: @escaping ServiceRunner,
        directRunner: @escaping ServiceRunner,
        healthCheckAttempts: Int,
        sleep: @escaping Sleeper
    ) {
        dependencies = Dependencies(
            healthCheck: healthCheck,
            launchctlRunner: launchctlRunner,
            directRunner: directRunner,
            healthCheckAttempts: max(1, healthCheckAttempts),
            sleep: sleep
        )
    }

    public func ensureRunning() async -> ServiceStartResult {
        if let startup {
            return await startup.task.value
        }

        startupSequence &+= 1
        let id = startupSequence
        let dependencies = dependencies
        let task = Task<ServiceStartResult, Never> {
            await Self.startService(using: dependencies)
        }
        startup = (id, task)
        let result = await task.value
        if startup?.id == id {
            startup = nil
        }
        return result
    }

    private static func startService(using dependencies: Dependencies) async -> ServiceStartResult {
        if await dependencies.healthCheck() {
            return .alreadyHealthy
        }

        do {
            try await dependencies.launchctlRunner()
            if await waitForHealth(using: dependencies) {
                return .started
            }
            return .failed(reason: "LaunchAgent 已启动，但 PetCore 未在限定时间内就绪")
        } catch {
            let launchAgentError = error.localizedDescription
            do {
                try await dependencies.directRunner()
                if await waitForHealth(using: dependencies) {
                    return .started
                }
                return .failed(reason: "PetCore 直接启动后未在限定时间内就绪；LaunchAgent：\(launchAgentError)")
            } catch {
                return .failed(
                    reason: "PetCore 启动失败：\(error.localizedDescription)；LaunchAgent：\(launchAgentError)"
                )
            }
        }
    }

    private static func waitForHealth(using dependencies: Dependencies) async -> Bool {
        for attempt in 0 ..< dependencies.healthCheckAttempts {
            if await dependencies.healthCheck() {
                return true
            }
            if attempt + 1 < dependencies.healthCheckAttempts {
                await dependencies.sleep(.milliseconds(50))
            }
        }
        return false
    }
}

public struct ServiceBootstrapRetryPolicy: Equatable, Sendable {
    public var maximumAttempts: Int
    public var initialDelay: Duration
    public var maximumDelay: Duration

    public init(maximumAttempts: Int, initialDelay: Duration, maximumDelay: Duration) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialDelay = max(.zero, initialDelay)
        self.maximumDelay = max(self.initialDelay, maximumDelay)
    }

    public static let `default` = ServiceBootstrapRetryPolicy(
        maximumAttempts: 5,
        initialDelay: .milliseconds(100),
        maximumDelay: .milliseconds(800)
    )
}

public actor PetCoreAppBootstrapCoordinator {
    public typealias EnsureRunning = @Sendable () async -> ServiceStartResult
    public typealias Sleeper = @Sendable (Duration) async -> Void

    private struct Dependencies: Sendable {
        let ensureRunning: EnsureRunning
        let policy: ServiceBootstrapRetryPolicy
        let sleep: Sleeper
    }

    private let dependencies: Dependencies
    private var completedResult: ServiceStartResult?
    private var sequence: UInt64 = 0
    private var active: (id: UInt64, task: Task<ServiceStartResult, Never>)?

    public init(
        ensureRunning: @escaping EnsureRunning,
        policy: ServiceBootstrapRetryPolicy = .default,
        sleep: @escaping Sleeper = { duration in try? await Task.sleep(for: duration) }
    ) {
        dependencies = Dependencies(ensureRunning: ensureRunning, policy: policy, sleep: sleep)
    }

    public func ensureRunning() async -> ServiceStartResult {
        if let completedResult {
            return completedResult
        }
        return await startOrJoinAttemptCycle()
    }

    public func recover() async -> ServiceStartResult {
        if let active {
            return await active.task.value
        }
        completedResult = nil
        return await startOrJoinAttemptCycle()
    }

    private func startOrJoinAttemptCycle() async -> ServiceStartResult {
        if let active {
            return await active.task.value
        }
        sequence &+= 1
        let id = sequence
        let dependencies = dependencies
        let task = Task<ServiceStartResult, Never> {
            await Self.runAttemptCycle(using: dependencies)
        }
        active = (id, task)
        let result = await task.value
        if active?.id == id {
            active = nil
            switch result {
            case .alreadyHealthy, .started:
                completedResult = result
            case .failed:
                completedResult = nil
            }
        }
        return result
    }

    private static func runAttemptCycle(using dependencies: Dependencies) async -> ServiceStartResult {
        var delay = dependencies.policy.initialDelay
        var lastResult: ServiceStartResult = .failed(reason: "PetCore 启动失败")
        for attempt in 0 ..< dependencies.policy.maximumAttempts {
            let result = await dependencies.ensureRunning()
            switch result {
            case .alreadyHealthy, .started:
                return result
            case .failed:
                lastResult = result
            }

            if attempt + 1 < dependencies.policy.maximumAttempts {
                await dependencies.sleep(delay)
                delay = min(delay * 2, dependencies.policy.maximumDelay)
            }
        }
        return lastResult
    }
}
