import AgentPetCompanionCore
import Darwin
import Foundation
import OSLog

enum RuntimeManifestRequirement: Equatable, Sendable {
    case missingAllowed
    case required(RuntimeReleaseManifest)
    case invalid(String)

    var manifest: RuntimeReleaseManifest? {
        guard case let .required(manifest) = self else { return nil }
        return manifest
    }
}

enum PetCoreRuntimeContract {
    static let requiredRPCProtocol = "apc.petcore-rpc.v2"
    static let requiredGenerationEnvironment = [
        "APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK": "0",
        "APC_REQUIRE_SKILL_FULL_SOURCE": "1",
        "APC_REQUIRE_EXTERNAL_SKILL_SOURCE": "1"
    ]
    static let requiredManifestURL: URL? = {
        let bundleManifestURL = Bundle.main.resourceURL?
            .appendingPathComponent("runtime-manifest.json")
        return requiredManifestLocation(
            overridePath: ProcessInfo.processInfo.environment["APC_RUNTIME_MANIFEST_PATH"],
            bundleURL: Bundle.main.bundleURL,
            bundleResourceURL: Bundle.main.resourceURL,
            isPackagedApp: Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app")
                == .orderedSame,
            bundleManifestExists: bundleManifestURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
        )
    }()
    static let requiredManifestRequirement = manifestRequirement(at: requiredManifestURL)
    static var requiredManifest: RuntimeReleaseManifest? {
        requiredManifestRequirement.manifest
    }
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
        manifestValidationProfile: RuntimeManifestValidationProfile = .strictV3,
        manifestRequirement: RuntimeManifestRequirement? = nil,
        expectedConnectorEnvironment: [String: String]? = nil
    ) -> Bool {
        guard let health = result as? [String: Any] else { return false }
        guard health["ok"] as? Bool == true,
              health["rpc_protocol"] as? String == requiredRPCProtocol
        else { return false }
        if let expectedBuildID, health["build_id"] as? String != expectedBuildID {
            return false
        }
        let resolvedManifestRequirement = manifestRequirement
            ?? expectedManifest.map(RuntimeManifestRequirement.required)
            ?? requiredManifestRequirement
        switch resolvedManifestRequirement {
        case .missingAllowed:
            break
        case .invalid:
            return false
        case let .required(expectedManifest):
            guard RuntimeReleaseManifest.decodeHealthValue(
                    health["runtime_manifest"],
                    validationProfile: manifestValidationProfile
                  )
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
        manifestValidationProfile: RuntimeManifestValidationProfile = .strictV3,
        manifestRequirement: RuntimeManifestRequirement? = nil,
        expectedConnectorEnvironment: [String: String]? = nil
    ) -> String? {
        guard !acceptsHealth(
                  result,
                  expectedBuildID: expectedBuildID,
                  expectedManifest: expectedManifest,
                  manifestValidationProfile: manifestValidationProfile,
                  manifestRequirement: manifestRequirement,
                  expectedConnectorEnvironment: expectedConnectorEnvironment
              ),
              let health = result as? [String: Any],
              health["ok"] as? Bool == true,
              let instanceID = health["instance_id"] as? String,
              !instanceID.isEmpty
        else { return nil }
        return instanceID
    }

    static func manifestRequirement(at url: URL?) -> RuntimeManifestRequirement {
        guard let url else {
            // Source/test startup without a packaged manifest is the sole
            // explicitly unmanaged stage. A supplied path is always required.
            return .missingAllowed
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .invalid("未找到 App 运行时清单")
        }
        do {
            return .required(try RuntimeReleaseManifest.read(from: url))
        } catch {
            return .invalid(
                "App 运行时清单无效或缺少 V2 必需字段：\(error.localizedDescription)"
            )
        }
    }

    static func requiredManifestLocation(
        overridePath: String?,
        bundleURL: URL,
        bundleResourceURL: URL?,
        isPackagedApp: Bool,
        bundleManifestExists: Bool
    ) -> URL? {
        if let override = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        if isPackagedApp {
            // A packaged App always owns this resource contract. Returning
            // the expected path even when packaging omitted the file makes
            // requirement resolution fail closed instead of becoming nil.
            return bundleURL.appendingPathComponent(
                "Contents/Resources/runtime-manifest.json"
            )
        }
        guard bundleManifestExists else { return nil }
        return bundleResourceURL?.appendingPathComponent("runtime-manifest.json")
    }

    static func validateManifestForStartup(
        _ requirement: RuntimeManifestRequirement = requiredManifestRequirement
    ) throws {
        guard case let .invalid(message) = requirement else { return }
        throw RuntimeManifestError.invalid(message)
    }
}

enum PetCoreServiceEnvironmentPolicy {
    static let connectorPathKeys = [
        "APC_AGENT_CONFIG_HOME",
        "CODEX_HOME",
        "CLAUDE_CONFIG_DIR",
        "PI_CODING_AGENT_DIR",
        "DSH_HOME",
        "OPENCODE_CONFIG_DIR",
        "OPENCODE_CONFIG",
        "XDG_CONFIG_HOME",
        "APC_CODEX_CLI_PATH",
        "APC_CLAUDE_CLI_PATH",
        "APC_PI_CLI_PATH",
        "APC_OPENCODE_CLI_PATH",
        "APC_DSH_CLI_PATH"
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
        case snapshotRequired
        case legacyConnectionStateNeedsProbe
        case unknown
    }

    static func assess(preflightValue: Any) -> Assessment {
        guard let preflight = preflightValue as? [String: Any],
              let convergenceSafe = preflight["safe"] as? Bool,
              let activeGeneration = preflight["active_generation"] as? Bool,
              let connectionOperation = preflight["connection_operation_active"] as? Bool,
              convergenceSafe == (!activeGeneration && !connectionOperation)
        else { return .unknown }

        guard let replacementValue = preflight["runtime_replacement_safe"] else {
            return convergenceSafe ? .safe : .snapshotRequired
        }
        guard let replacementSafe = replacementValue as? Bool else {
            return .unknown
        }

        let expectedReplacementSafe: Bool
        if activeGeneration {
            guard let status = preflight["active_generation_status"] as? String else {
                return .unknown
            }
            switch status {
            case "pending", "running":
                expectedReplacementSafe = false
            case "waiting_for_user":
                expectedReplacementSafe = !connectionOperation
            case "failed":
                // Older PetCore builds projected recoverable failures as
                // active and incorrectly reported replacement_safe=false.
                // Recheck their authoritative snapshot instead of deadlocking
                // the update that is needed to resume the durable job.
                if !replacementSafe, !connectionOperation {
                    return .snapshotRequired
                }
                expectedReplacementSafe = !connectionOperation
            default:
                return .unknown
            }
        } else {
            let status = preflight["active_generation_status"]
            guard status == nil || status is NSNull else { return .unknown }
            expectedReplacementSafe = !connectionOperation
        }

        guard replacementSafe == expectedReplacementSafe else {
            return .unknown
        }
        return replacementSafe ? .safe : .protectedWork
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
            case "waiting_for_user", "failed":
                // Waiting input and recoverable failure are durable PetCore
                // states. Replacing the runtime lets the new App restore the
                // prompt or continuation; deferring here would deadlock
                // because no active worker can make either state progress.
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
        guard let error = error as? PetCoreClientError,
              let message = error.rpcMessage,
              message.contains("another Agent connection operation is already running")
        else { return .unknown }
        return .protectedWork
    }

    static func shouldFallbackToSnapshotAfterPreflightError(_ error: Error) -> Bool {
        guard let error = error as? PetCoreClientError else {
            return false
        }
        if error.rpcCode == -32601 {
            return true
        }
        return error.rpcCode == nil
            && error.rpcMessage
                == "method not found: product.convergence.preflight"
    }

    static func shouldDeferAfterSafetyProbeError(_ error: Error) -> Bool {
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

enum PetCoreRollbackCheckpointOperation: String, Sendable {
    case create
    case restore
    case discard
    case status
}

struct PetCoreRollbackCheckpointStatus: Decodable, Equatable, Sendable {
    static let schemaVersion = "apc.runtime-rollback-checkpoint.v1"

    enum Phase: String, Decodable, Equatable, Sendable {
        case creating
        case ready
        case restored
    }

    let schemaVersion: String
    let present: Bool
    let phase: Phase?
    let sourceBuildID: String?
    let candidateBuildID: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case present
        case phase
        case sourceBuildID = "source_build_id"
        case candidateBuildID = "candidate_build_id"
    }

    static func decodeClosed(_ data: Data) -> PetCoreRollbackCheckpointStatus? {
        guard data.count <= 4 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)),
              let status = try? JSONDecoder().decode(Self.self, from: data),
              status.schemaVersion == schemaVersion
        else { return nil }

        if status.present {
            guard status.phase != nil,
                  let sourceBuildID = status.sourceBuildID,
                  let candidateBuildID = status.candidateBuildID,
                  isSafeBuildID(sourceBuildID),
                  isSafeBuildID(candidateBuildID)
            else { return nil }
        } else {
            guard status.phase == nil,
                  status.sourceBuildID == nil,
                  status.candidateBuildID == nil
            else { return nil }
        }
        return status
    }

    func isReadyRecovery(sourceBuildID: String, candidateBuildID: String) -> Bool {
        present
            && phase == .ready
            && self.sourceBuildID == sourceBuildID
            && self.candidateBuildID == candidateBuildID
    }

    private static func isSafeBuildID(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9._+-]{1,128}$",
            options: .regularExpression
        ) != nil
    }
}

enum PetCoreRollbackCheckpointCommand {
    static func arguments(
        operation: PetCoreRollbackCheckpointOperation,
        homeURL: URL,
        sourceBuildID: String? = nil,
        candidateBuildID: String? = nil
    ) throws -> [String] {
        var arguments = [
            "rollback-checkpoint", operation.rawValue,
            "--home", homeURL.path
        ]
        if operation == .create {
            guard let sourceBuildID, !sourceBuildID.isEmpty,
                  let candidateBuildID, !candidateBuildID.isEmpty
            else {
                throw PetCoreServiceLauncherError.message(
                    "创建 PetCore 回滚检查点时缺少运行时构建标识"
                )
            }
            arguments.append(contentsOf: [
                "--source-build-id", sourceBuildID,
                "--candidate-build-id", candidateBuildID
            ])
        }
        return arguments
    }

    static func run(
        operation: PetCoreRollbackCheckpointOperation,
        executableURL: URL,
        homeURL: URL,
        sourceBuildID: String? = nil,
        candidateBuildID: String? = nil
    ) async throws {
        let result = try await BoundedProcessRunner.run(
            executableURL: executableURL,
            arguments: try arguments(
                operation: operation,
                homeURL: homeURL,
                sourceBuildID: sourceBuildID,
                candidateBuildID: candidateBuildID
            ),
            timeout: .seconds(30),
            outputLimit: 64 * 1_024
        )
        guard result.termination == .exited(status: 0) else {
            let detail = String(data: result.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PetCoreServiceLauncherError.message(
                detail?.isEmpty == false
                    ? "PetCore 回滚检查点 \(operation.rawValue) 失败：\(detail!)"
                    : "PetCore 回滚检查点 \(operation.rawValue) 失败"
            )
        }
    }

    static func status(
        executableURL: URL,
        homeURL: URL
    ) async -> PetCoreRollbackCheckpointStatus? {
        do {
            let result = try await BoundedProcessRunner.run(
                executableURL: executableURL,
                arguments: try arguments(operation: .status, homeURL: homeURL),
                timeout: .seconds(2),
                outputLimit: 8 * 1_024
            )
            guard result.termination == .exited(status: 0) else { return nil }
            return PetCoreRollbackCheckpointStatus.decodeClosed(result.standardOutput)
        } catch {
            return nil
        }
    }
}

enum PetCoreRuntimeUpgradeTransactionError: LocalizedError {
    case recovered(original: String)
    case recoveryFailed(original: String, recovery: String)

    var errorDescription: String? {
        switch self {
        case let .recovered(original):
            "PetCore 更新失败，已恢复上一个可用版本：\(original)"
        case let .recoveryFailed(original, recovery):
            "PetCore 更新失败且回滚未完成：\(original)；回滚：\(recovery)"
        }
    }
}

enum PetCoreRuntimeUpgradeTransaction {
    typealias AsyncStep = () async throws -> Void
    typealias CleanupFailureRecorder = (Error) async -> Void

    static func run(
        isolation: isolated (any Actor)? = #isolation,
        rollbackAvailable: Bool,
        stopPriorRuntime: AsyncStep,
        revalidateCandidate: AsyncStep,
        createCheckpoint: AsyncStep,
        launchCandidate: AsyncStep,
        verifyCandidateHealth: AsyncStep,
        commitCandidate: AsyncStep,
        stopCandidateRuntime: AsyncStep,
        restoreCheckpoint: AsyncStep,
        launchRollback: AsyncStep,
        discardCheckpoint: AsyncStep,
        recordCleanupFailure: CleanupFailureRecorder
    ) async throws {
        var priorRuntimeStopped = false
        var checkpointCreateAttempted = false
        var checkpointCreated = false
        var candidateMayBeRunning = false

        do {
            try await stopPriorRuntime()
            priorRuntimeStopped = true

            if rollbackAvailable {
                // create also reconciles a ready checkpoint left by a crashed
                // candidate. It must run before preflight so a partially migrated
                // database cannot prevent restoration of rollback authority.
                checkpointCreateAttempted = true
                try await createCheckpoint()
                checkpointCreated = true
            }

            // The sole candidate preflight runs after the old owner exits and,
            // when rollback exists, after crash recovery has restored the source
            // snapshot. It remains read-only before candidate initialization.
            try await revalidateCandidate()

            // A launch operation can fail after partially starting a process or
            // installing a launchd job, so cleanup owns it from this point onward.
            candidateMayBeRunning = true
            try await launchCandidate()
            try await verifyCandidateHealth()
            try await commitCandidate()
        } catch {
            let originalError = error
            let original = originalError.localizedDescription

            if candidateMayBeRunning {
                do {
                    try await stopCandidateRuntime()
                } catch {
                    throw PetCoreRuntimeUpgradeTransactionError.recoveryFailed(
                        original: original,
                        recovery: "无法确认候选 PetCore 已完全停止：\(error.localizedDescription)"
                    )
                }
            }

            guard priorRuntimeStopped, rollbackAvailable else {
                throw originalError
            }

            // create can fail while reconciling a crash-left Ready checkpoint.
            // Until it succeeds, the live database may still be partially migrated;
            // starting a historical runtime against that unknown state is unsafe.
            if checkpointCreateAttempted, !checkpointCreated {
                throw PetCoreRuntimeUpgradeTransactionError.recoveryFailed(
                    original: original,
                    recovery: "未能建立可验证的数据恢复点，已停止启动历史版本"
                )
            }

            if checkpointCreated {
                do {
                    try await restoreCheckpoint()
                } catch {
                    throw PetCoreRuntimeUpgradeTransactionError.recoveryFailed(
                        original: original,
                        recovery: "恢复数据检查点失败：\(error.localizedDescription)"
                    )
                }
            }

            do {
                try await launchRollback()
            } catch {
                throw PetCoreRuntimeUpgradeTransactionError.recoveryFailed(
                    original: original,
                    recovery: error.localizedDescription
                )
            }

            if checkpointCreated {
                await discardBestEffort(
                    discardCheckpoint,
                    recordFailure: recordCleanupFailure
                )
            }
            throw PetCoreRuntimeUpgradeTransactionError.recovered(original: original)
        }

        // commitCandidate is the irreversible success boundary. A stale private
        // checkpoint is safe to overwrite on the next update, so cleanup failure
        // must never restore an old database after the new runtime was committed.
        if checkpointCreated {
            await discardBestEffort(
                discardCheckpoint,
                recordFailure: recordCleanupFailure
            )
        }
    }

    private static func discardBestEffort(
        isolation: isolated (any Actor)? = #isolation,
        _ discardCheckpoint: AsyncStep,
        recordFailure: CleanupFailureRecorder
    ) async {
        do {
            try await discardCheckpoint()
        } catch {
            await recordFailure(error)
        }
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
    private static let logger = Logger(
        subsystem: "dev.agentpet.companion",
        category: "petcore-runtime-upgrade"
    )
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
        try PetCoreRuntimeContract.validateManifestForStartup()
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
        let previous = allowsRollback ? candidate.previous : nil
        try await PetCoreRuntimeUpgradeTransaction.run(
            rollbackAvailable: previous != nil,
            stopPriorRuntime: {
                try await self.stopActiveRuntimeCompletely()
            },
            revalidateCandidate: {
                guard allowsRollback else { return }
                try await self.runtimeStore.revalidateCandidate(candidate)
            },
            createCheckpoint: {
                try await PetCoreRollbackCheckpointCommand.run(
                    operation: .create,
                    executableURL: candidate.executableURL,
                    homeURL: self.homeURL,
                    sourceBuildID: previous?.buildID,
                    candidateBuildID: candidate.buildID
                )
            },
            launchCandidate: {
                switch mode {
                case .launchAgent:
                    try await self.performLaunchAgentStart(candidate)
                case .direct:
                    try await self.performDirectStart(candidate)
                }
            },
            verifyCandidateHealth: {
                guard await self.waitForHealth(candidate) else {
                    throw PetCoreServiceLauncherError.message(
                        "候选 PetCore 启动后未通过版本与健康检查"
                    )
                }
            },
            commitCandidate: {
                try await self.runtimeStore.commitHealthy(candidate)
            },
            stopCandidateRuntime: {
                try await self.stopActiveRuntimeCompletely()
            },
            restoreCheckpoint: {
                try await PetCoreRollbackCheckpointCommand.run(
                    operation: .restore,
                    executableURL: candidate.executableURL,
                    homeURL: self.homeURL
                )
            },
            launchRollback: {
                guard let previous else {
                    throw PetCoreServiceLauncherError.message("缺少可回滚的 PetCore 运行时")
                }
                let rollback = try await self.runtimeStore.resolve(previous)
                try await self.start(rollback, mode: mode, allowsRollback: false)
            },
            discardCheckpoint: {
                try await PetCoreRollbackCheckpointCommand.run(
                    operation: .discard,
                    executableURL: candidate.executableURL,
                    homeURL: self.homeURL
                )
            },
            recordCleanupFailure: { error in
                Self.logger.error(
                    "PetCore rollback checkpoint cleanup failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        )
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
        let initialAssessment: PetCoreRuntimeReplacementSafetyPolicy.Assessment
        do {
            initialAssessment = try await runtimeReplacementSafetyAssessment(client: client)
        } catch {
            guard PetCoreRuntimeReplacementSafetyPolicy
                .shouldDeferAfterSafetyProbeError(error)
            else {
                // No process accepted the Unix-domain connection. A stale or
                // absent socket cannot own active work, so replacement may
                // continue through the bounded transaction.
                return
            }
            if await hasReadyRollbackRecovery(candidate) {
                return
            }
            throw ServiceStartupDeferredError(
                reason: "暂时无法确认当前任务状态，稍后会自动重试本地服务更新"
            )
        }

        let assessment: PetCoreRuntimeReplacementSafetyPolicy.Assessment
        if initialAssessment == .legacyConnectionStateNeedsProbe {
            assessment = await legacyConnectionOperationsAssessment(client: client)
        } else {
            assessment = initialAssessment
        }
        switch assessment {
        case .safe:
            return
        case .protectedWork:
            throw ServiceStartupDeferredError(
                reason: "正在等待当前任务完成，再继续更新本地服务"
            )
        case .snapshotRequired, .legacyConnectionStateNeedsProbe, .unknown:
            if await hasReadyRollbackRecovery(candidate) {
                return
            }
            throw ServiceStartupDeferredError(
                reason: "暂时无法确认当前任务状态，稍后会自动重试本地服务更新"
            )
        }
    }

    private func hasReadyRollbackRecovery(_ candidate: PreparedPetCoreRuntime) async -> Bool {
        guard let sourceBuildID = candidate.previous?.buildID,
              let candidateBuildID = candidate.buildID,
              let status = await PetCoreRollbackCheckpointCommand.status(
                  executableURL: candidate.executableURL,
                  homeURL: homeURL
              )
        else { return false }
        return status.isReadyRecovery(
            sourceBuildID: sourceBuildID,
            candidateBuildID: candidateBuildID
        )
    }

    private func runtimeReplacementSafetyAssessment(
        client: PetCoreClient
    ) async throws -> PetCoreRuntimeReplacementSafetyPolicy.Assessment {
        do {
            let response = try await client.requestData(
                method: "product.convergence.preflight",
                timeout: .milliseconds(500)
            )
            let preflight = try PetCoreClient.decodeResult(from: response)
            let assessment = PetCoreRuntimeReplacementSafetyPolicy.assess(
                preflightValue: preflight
            )
            if assessment != .snapshotRequired {
                return assessment
            }
        } catch {
            guard PetCoreRuntimeReplacementSafetyPolicy
                .shouldFallbackToSnapshotAfterPreflightError(error)
            else {
                throw error
            }
        }

        let response = try await client.requestData(
            method: "state.snapshot",
            timeout: .milliseconds(500)
        )
        let snapshot = try PetCoreClient.decodeResult(from: response)
        return PetCoreRuntimeReplacementSafetyPolicy.assess(
            snapshotValue: snapshot
        )
    }

    private func legacyConnectionOperationsAssessment(
        client: PetCoreClient
    ) async -> PetCoreRuntimeReplacementSafetyPolicy.Assessment {
        do {
            let params = try JSONSerialization.data(
                withJSONObject: ["source": "codex"]
            )
            let response = try await client.requestData(
                method: "connections.test",
                paramsJSONData: params,
                timeout: .seconds(2)
            )
            _ = try PetCoreClient.decodeResult(from: response)
            return .safe
        } catch {
            return PetCoreRuntimeReplacementSafetyPolicy
                .assessLegacyConnectionProbeError(error)
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

    private func stopActiveRuntimeCompletely() async throws {
        // A loaded KeepAlive job would immediately respawn the binary after shutdown.
        // Explicit direct/isolated validation mode never touches the user's global job.
        if PetCoreLaunchControlPolicy.shouldBootoutGlobalLaunchAgent(
            launchAgentDisabled: launchAgentDisabled
        ) {
            _ = await runLaunchctl(["bootout", launchDomainAndLabel()])
            guard !(await isLaunchAgentLoaded()) else {
                throw PetCoreServiceLauncherError.message(
                    "无法确认 PetCore LaunchAgent 已完全停止"
                )
            }
        }

        await shutdownActiveRuntime()
        try await stopTrackedDirectProcess()
        guard await waitForPriorRuntimeExit() else {
            throw PetCoreServiceLauncherError.message("无法确认 PetCore 进程已完全退出")
        }
    }

    private func stopTrackedDirectProcess() async throws {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            for _ in 0 ..< 50 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        if process.isRunning {
            let result = Darwin.kill(process.processIdentifier, SIGKILL)
            guard result == 0 || errno == ESRCH else {
                throw PetCoreServiceLauncherError.message(
                    "无法终止 PetCore 直接运行进程"
                )
            }
            for _ in 0 ..< 25 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard !process.isRunning else {
            throw PetCoreServiceLauncherError.message(
                "无法确认 PetCore 直接运行进程已完全停止"
            )
        }
        self.process = nil
        try? logHandle?.close()
        logHandle = nil
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
                manifestValidationProfile: candidate.manifestValidationProfile,
                expectedConnectorEnvironment: PetCoreServiceEnvironmentPolicy
                    .serviceIdentityEnvironment()
            ) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func waitForPriorRuntimeExit() async -> Bool {
        let client = PetCoreClient(socketPath: socketPath)
        for _ in 0 ..< 25 {
            guard let response = try? await client.requestData(
                method: "petcore.health",
                timeout: .milliseconds(100)
            ), (try? PetCoreClient.decodeResult(from: response)) != nil
            else { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
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
