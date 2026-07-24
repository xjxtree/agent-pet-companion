import AgentPetCompanionCore
import Darwin
import Foundation

struct RuntimeConnectorContracts: Codable, Equatable, Sendable {
    let codex: String
    let claudeCode: String
    let pi: String
    let opencode: String

    enum CodingKeys: String, CodingKey {
        case codex
        case claudeCode = "claude_code"
        case pi
        case opencode
    }

    var allArePresent: Bool {
        [codex, claudeCode, pi, opencode].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct RuntimeReleaseManifest: Codable, Equatable, Sendable {
    static let schemaVersion = "apc.runtime-manifest.v1"

    let schemaVersion: String
    let releaseChannel: String
    let appVersion: String
    let appBuild: String
    let buildID: String
    let petCoreRPCProtocol: String
    let petCoreBuildID: String
    let petCoreCLIBuildID: String
    let minimumDatabaseSchemaVersion: UInt32
    let maximumDatabaseSchemaVersion: UInt32
    let agentEventSchemaVersion: String
    let petpackSchemaVersion: String
    let petpackReadVersions: [String]
    let petpackWriteVersion: String
    let connectorContracts: RuntimeConnectorContracts

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case releaseChannel = "release_channel"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case buildID = "build_id"
        case petCoreRPCProtocol = "petcore_rpc_protocol"
        case petCoreBuildID = "petcore_build_id"
        case petCoreCLIBuildID = "petcore_cli_build_id"
        case minimumDatabaseSchemaVersion = "minimum_database_schema_version"
        case maximumDatabaseSchemaVersion = "maximum_database_schema_version"
        case agentEventSchemaVersion = "agent_event_schema_version"
        case petpackSchemaVersion = "petpack_schema_version"
        case petpackReadVersions = "petpack_read_versions"
        case petpackWriteVersion = "petpack_write_version"
        case connectorContracts = "connector_contracts"
    }

    static func read(from url: URL) throws -> RuntimeReleaseManifest {
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try manifest.validateForApp()
        return manifest
    }

    static func decodeHealthValue(_ value: Any?) -> RuntimeReleaseManifest? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let manifest = try? JSONDecoder().decode(Self.self, from: data),
              (try? manifest.validateForApp()) != nil
        else { return nil }
        return manifest
    }

    func validateForApp() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw RuntimeManifestError.invalid("运行时清单协议不受支持")
        }
        guard matchesSafeBuildID(buildID),
              buildID == petCoreBuildID,
              buildID == petCoreCLIBuildID
        else {
            throw RuntimeManifestError.invalid("App、PetCore 与 CLI 构建标识不一致")
        }
        guard petCoreRPCProtocol == PetCoreRuntimeContract.requiredRPCProtocol else {
            throw RuntimeManifestError.invalid("PetCore RPC 协议不兼容")
        }
        guard matchesNonempty(appVersion), matchesNonempty(appBuild),
              matchesNonempty(agentEventSchemaVersion), matchesNonempty(petpackSchemaVersion),
              matchesNonempty(petpackWriteVersion), !petpackReadVersions.isEmpty,
              connectorContracts.allArePresent
        else {
            throw RuntimeManifestError.invalid("运行时清单缺少版本信息")
        }
        guard releaseChannel == "develop" || releaseChannel == "release" else {
            throw RuntimeManifestError.invalid("运行时清单发布通道无效")
        }
        guard minimumDatabaseSchemaVersion <= maximumDatabaseSchemaVersion else {
            throw RuntimeManifestError.invalid("数据库兼容范围无效")
        }
        guard petpackSchemaVersion == petpackWriteVersion,
              petpackReadVersions.contains(petpackWriteVersion),
              petpackReadVersions.allSatisfy(matchesNonempty)
        else {
            throw RuntimeManifestError.invalid("Petpack 读写版本范围无效")
        }
    }

    private func matchesSafeBuildID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._+-]{1,128}$", options: .regularExpression) != nil
    }

    private func matchesNonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension RuntimeReleaseManifest {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        releaseChannel = try container.decode(String.self, forKey: .releaseChannel)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        appBuild = try container.decode(String.self, forKey: .appBuild)
        buildID = try container.decode(String.self, forKey: .buildID)
        petCoreRPCProtocol = try container.decode(String.self, forKey: .petCoreRPCProtocol)
        petCoreBuildID = try container.decode(String.self, forKey: .petCoreBuildID)
        petCoreCLIBuildID = try container.decode(String.self, forKey: .petCoreCLIBuildID)
        minimumDatabaseSchemaVersion = try container.decode(
            UInt32.self,
            forKey: .minimumDatabaseSchemaVersion
        )
        maximumDatabaseSchemaVersion = try container.decode(
            UInt32.self,
            forKey: .maximumDatabaseSchemaVersion
        )
        agentEventSchemaVersion = try container.decode(
            String.self,
            forKey: .agentEventSchemaVersion
        )
        petpackSchemaVersion = try container.decode(String.self, forKey: .petpackSchemaVersion)
        // These fields were introduced without changing the v1 runtime-manifest
        // identifier. Reconstruct the old single-version contract so a new App
        // can still inspect and roll back to an installed v1 last-known-good.
        petpackReadVersions = try container.decodeIfPresent(
            [String].self,
            forKey: .petpackReadVersions
        ) ?? [petpackSchemaVersion]
        petpackWriteVersion = try container.decodeIfPresent(
            String.self,
            forKey: .petpackWriteVersion
        ) ?? petpackSchemaVersion
        connectorContracts = try container.decode(
            RuntimeConnectorContracts.self,
            forKey: .connectorContracts
        )
    }
}

enum RuntimeManifestError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

struct InstalledPetCoreRuntime: Codable, Equatable, Sendable {
    let buildID: String

    enum CodingKeys: String, CodingKey {
        case buildID = "build_id"
    }
}

enum PetCoreRuntimeUpgradeEvidence {
    static func hasManagedUpdateContext(
        currentBuildID: String,
        homeURL: URL = appSupportHomeURL()
    ) -> Bool {
        guard currentBuildID.range(
            of: "^[A-Za-z0-9._+-]{1,128}$",
            options: .regularExpression
        ) != nil else { return false }
        let runtimeRoot = homeURL.appendingPathComponent("runtime", isDirectory: true)
        guard let installedBuildID = readPointer(
            at: runtimeRoot.appendingPathComponent("current.json")
        )?.buildID else { return false }
        if installedBuildID != currentBuildID {
            return true
        }
        guard let previousBuildID = readPointer(
            at: runtimeRoot.appendingPathComponent("last-known-good.json")
        )?.buildID else { return false }
        return previousBuildID != currentBuildID
    }

    static func hasPriorManagedBuild(
        currentBuildID: String,
        homeURL: URL = appSupportHomeURL()
    ) -> Bool {
        guard currentBuildID.range(
            of: "^[A-Za-z0-9._+-]{1,128}$",
            options: .regularExpression
        ) != nil else { return false }
        let runtimeRoot = homeURL.appendingPathComponent("runtime", isDirectory: true)
        guard readPointer(
            at: runtimeRoot.appendingPathComponent("current.json")
        )?.buildID == currentBuildID,
        let previous = readPointer(
            at: runtimeRoot.appendingPathComponent("last-known-good.json")
        )?.buildID
        else { return false }
        return previous != currentBuildID
    }

    private static func appSupportHomeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["APC_HOME"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("AgentPetCompanion", isDirectory: true)
    }

    private static func readPointer(at url: URL) -> InstalledPetCoreRuntime? {
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0,
              pathStatus.st_mode & S_IFMT == S_IFREG,
              pathStatus.st_uid == getuid(),
              pathStatus.st_nlink == 1,
              pathStatus.st_size > 0,
              pathStatus.st_size <= 4_096
        else { return nil }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino,
              openedStatus.st_size == pathStatus.st_size
        else { return nil }
        var data = Data(count: Int(openedStatus.st_size))
        let count = data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            var total = 0
            while total < bytes.count {
                let readCount = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: total),
                    bytes.count - total
                )
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else { break }
                total += readCount
            }
            return total
        }
        guard count == data.count,
              let pointer = try? JSONDecoder().decode(
                InstalledPetCoreRuntime.self,
                from: data
              ),
              pointer.buildID.range(
                of: "^[A-Za-z0-9._+-]{1,128}$",
                options: .regularExpression
              ) != nil
        else { return nil }
        return pointer
    }
}

struct PreparedPetCoreRuntime: Sendable {
    let executableURL: URL
    let cliURL: URL
    let manifestURL: URL?
    let manifest: RuntimeReleaseManifest?
    let previous: InstalledPetCoreRuntime?

    var buildID: String? { manifest?.buildID }
    var isManaged: Bool { manifest != nil && manifestURL != nil }
}

actor PetCoreRuntimeStore {
    private let homeURL: URL
    private let fileManager: FileManager
    private var recordedBuildIDs: Set<String> = []

    init(homeURL: URL, fileManager: FileManager = .default) {
        self.homeURL = homeURL
        self.fileManager = fileManager
    }

    func prepareCandidate(
        sourceExecutableURL: URL,
        sourceCLIURL: URL,
        sourceManifestURL: URL?
    ) async throws -> PreparedPetCoreRuntime {
        guard let sourceManifestURL else {
            return PreparedPetCoreRuntime(
                executableURL: sourceExecutableURL,
                cliURL: sourceCLIURL,
                manifestURL: nil,
                manifest: nil,
                previous: nil
            )
        }

        let manifest = try RuntimeReleaseManifest.read(from: sourceManifestURL)
        let versionsURL = runtimeRootURL.appendingPathComponent("versions", isDirectory: true)
        try fileManager.createDirectory(at: versionsURL, withIntermediateDirectories: true)
        let candidateURL = versionsURL.appendingPathComponent(manifest.buildID, isDirectory: true)
        if !fileManager.fileExists(atPath: candidateURL.path) {
            try stageRuntime(
                sourceExecutableURL: sourceExecutableURL,
                sourceCLIURL: sourceCLIURL,
                sourceManifestURL: sourceManifestURL,
                candidateURL: candidateURL
            )
        }

        let candidate = try installedRuntime(buildID: manifest.buildID)
        guard candidate.manifest == manifest else {
            throw RuntimeManifestError.invalid("已暂存运行时与 App 清单不一致")
        }
        try await preflight(candidate)

        let current = try readPointer(at: currentPointerURL)
        let lastKnownGood = try readPointer(at: lastKnownGoodPointerURL)
        let previous = [current, lastKnownGood]
            .compactMap { $0 }
            .first { $0.buildID != manifest.buildID && (try? installedRuntime(buildID: $0.buildID)) != nil }

        return PreparedPetCoreRuntime(
            executableURL: candidate.executableURL,
            cliURL: candidate.cliURL,
            manifestURL: candidate.manifestURL,
            manifest: candidate.manifest,
            previous: previous
        )
    }

    func commitHealthy(_ candidate: PreparedPetCoreRuntime) throws {
        guard let buildID = candidate.buildID, candidate.isManaged else { return }
        if recordedBuildIDs.contains(buildID) {
            try replaceCurrentRuntimeLink(buildID: buildID)
            return
        }
        let current = try readPointer(at: currentPointerURL)
        if let current, current.buildID != buildID,
           (try? installedRuntime(buildID: current.buildID)) != nil
        {
            try writePointer(current, to: lastKnownGoodPointerURL)
        }
        try writePointer(InstalledPetCoreRuntime(buildID: buildID), to: currentPointerURL)
        try replaceCurrentRuntimeLink(buildID: buildID)
        recordedBuildIDs.insert(buildID)
    }

    func resolve(_ installation: InstalledPetCoreRuntime) throws -> PreparedPetCoreRuntime {
        let runtime = try installedRuntime(buildID: installation.buildID)
        return PreparedPetCoreRuntime(
            executableURL: runtime.executableURL,
            cliURL: runtime.cliURL,
            manifestURL: runtime.manifestURL,
            manifest: runtime.manifest,
            previous: nil
        )
    }

    private struct ManagedRuntime {
        let executableURL: URL
        let cliURL: URL
        let manifestURL: URL
        let manifest: RuntimeReleaseManifest
    }

    private var runtimeRootURL: URL {
        homeURL.appendingPathComponent("runtime", isDirectory: true)
    }

    private var currentPointerURL: URL {
        runtimeRootURL.appendingPathComponent("current.json")
    }

    private var lastKnownGoodPointerURL: URL {
        runtimeRootURL.appendingPathComponent("last-known-good.json")
    }

    private var currentRuntimeURL: URL {
        runtimeRootURL.appendingPathComponent("current", isDirectory: true)
    }

    private func installedRuntime(buildID: String) throws -> ManagedRuntime {
        guard buildID.range(of: "^[A-Za-z0-9._+-]{1,128}$", options: .regularExpression) != nil else {
            throw RuntimeManifestError.invalid("运行时指针包含无效构建标识")
        }
        let directory = runtimeRootURL
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(buildID, isDirectory: true)
        let executableURL = directory.appendingPathComponent("petcore")
        let cliURL = directory.appendingPathComponent("petcore-cli")
        let manifestURL = directory.appendingPathComponent("runtime-manifest.json")
        guard fileManager.isExecutableFile(atPath: executableURL.path),
              fileManager.isExecutableFile(atPath: cliURL.path),
              fileManager.fileExists(atPath: manifestURL.path)
        else {
            throw RuntimeManifestError.invalid("暂存运行时不完整")
        }
        let manifest = try RuntimeReleaseManifest.read(from: manifestURL)
        guard manifest.buildID == buildID else {
            throw RuntimeManifestError.invalid("运行时目录与清单构建标识不一致")
        }
        return ManagedRuntime(
            executableURL: executableURL,
            cliURL: cliURL,
            manifestURL: manifestURL,
            manifest: manifest
        )
    }

    private func stageRuntime(
        sourceExecutableURL: URL,
        sourceCLIURL: URL,
        sourceManifestURL: URL,
        candidateURL: URL
    ) throws {
        let stagingRoot = runtimeRootURL.appendingPathComponent("staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let stagingURL = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging { try? fileManager.removeItem(at: stagingURL) }
        }
        let executableURL = stagingURL.appendingPathComponent("petcore")
        let cliURL = stagingURL.appendingPathComponent("petcore-cli")
        let manifestURL = stagingURL.appendingPathComponent("runtime-manifest.json")
        try fileManager.copyItem(at: sourceExecutableURL, to: executableURL)
        try fileManager.copyItem(at: sourceCLIURL, to: cliURL)
        try fileManager.copyItem(at: sourceManifestURL, to: manifestURL)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cliURL.path)
        try fileManager.moveItem(at: stagingURL, to: candidateURL)
        shouldRemoveStaging = false
    }

    private func preflight(_ runtime: ManagedRuntime) async throws {
        let result = try await BoundedProcessRunner.run(
            executableURL: runtime.executableURL,
            arguments: [
                "preflight",
                "--home", homeURL.path,
                "--manifest", runtime.manifestURL.path
            ],
            timeout: .seconds(5),
            outputLimit: 16 * 1_024
        )
        guard result.termination == .exited(status: 0) else {
            let detail = String(data: result.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RuntimeManifestError.invalid(
                detail?.isEmpty == false ? "候选 PetCore 预检失败：\(detail!)" : "候选 PetCore 预检失败"
            )
        }
    }

    private func readPointer(at url: URL) throws -> InstalledPetCoreRuntime? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(InstalledPetCoreRuntime.self, from: Data(contentsOf: url))
    }

    private func writePointer(_ pointer: InstalledPetCoreRuntime, to url: URL) throws {
        try fileManager.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pointer)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func replaceCurrentRuntimeLink(buildID: String) throws {
        try fileManager.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        let temporaryURL = runtimeRootURL.appendingPathComponent(".current-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(
            atPath: temporaryURL.path,
            withDestinationPath: "versions/\(buildID)"
        )
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary { try? fileManager.removeItem(at: temporaryURL) }
        }
        let result = temporaryURL.path.withCString { source in
            currentRuntimeURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        shouldRemoveTemporary = false
    }
}
