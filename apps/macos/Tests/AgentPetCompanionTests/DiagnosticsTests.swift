import Darwin
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct DiagnosticsTests {
    @Test
    func jsonLinesUseTheStableSchemaAndRedactSensitiveMetadata() throws {
        let root = temporaryDirectory("schema")
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = AppDiagnostics(homeURL: root, enabled: true)

        logger.log(
            .info,
            category: "test",
            event: "safe_event",
            metadata: [
                "build_id": .string("build-123"),
                "password": .string("do-not-export"),
                "source_path": .string("/Users/example/private.txt"),
                "workspace": .string("cwd=/private/Client Secret/project"),
                "contact": .string("private.person@example.com"),
                "host": .string("alice-mac.local"),
                "user": .string("alice"),
                "ip": .string("192.168.1.42"),
                "peer_host": .string("mac01.corp.example.com"),
                "client_ip": .string("fe80::aede:48ff:fe00:1122"),
                "endpoint": .string("192.168.1.42:53782"),
                "remote_endpoint": .string("[2001:db8::1]:443"),
                "opaque_value": .string(String(repeating: "a", count: 64)),
                "uuid_value": .string("018f6f71-8067-7802-a4ee-e71333bb1429")
            ]
        )

        let logURL = try #require(logger.logURL)
        let data = try Data(contentsOf: logURL)
        let line = try #require(data.split(separator: 0x0A).first)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        )
        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect(object["schema_version"] as? String == AppDiagnostics.schemaVersion)
        #expect(object["process"] as? String == "app")
        #expect(object["event"] as? String == "safe_event")
        #expect(object["run_id"] == nil)
        #expect(metadata["build_id"] as? String == "build-123")
        #expect(metadata["password"] as? String == "<redacted>")
        #expect(metadata["source_path"] as? String == "<redacted>")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("do-not-export"))
        #expect(!text.contains("Client Secret"))
        #expect(!text.contains("private.person@example.com"))
        #expect(!text.contains("018f6f71-8067-7802-a4ee-e71333bb1429"))
        #expect(!text.contains("alice-mac.local"))
        #expect(!text.contains("192.168.1.42"))
        #expect(!text.contains("mac01.corp.example.com"))
        #expect(!text.contains("fe80::aede:48ff:fe00:1122"))
        #expect(!text.contains("192.168.1.42:53782"))
        #expect(!text.contains("2001:db8::1"))
    }

    @Test
    func throttleBookkeepingRemainsBounded() {
        let root = temporaryDirectory("throttle-bound")
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = AppDiagnostics(homeURL: root, enabled: true)

        for index in 0 ..< 256 {
            logger.log(
                .warning,
                category: "throttle",
                event: "bounded",
                throttleKey: "key-\(index)",
                minimumInterval: 60
            )
        }

        #expect(logger.trackedThrottleKeyCount <= 128)
    }

    @Test
    func logRotationKeepsOnlyTheConfiguredBackups() throws {
        let root = temporaryDirectory("rotation")
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = AppDiagnostics(
            homeURL: root,
            enabled: true,
            maximumFileBytes: 1_024,
            backupCount: 4
        )

        for index in 0 ..< 80 {
            logger.log(
                .info,
                category: "rotation",
                event: "record",
                metadata: [
                    "index": .integer(Int64(index)),
                    "payload": .string(String(repeating: "x", count: 180))
                ]
            )
        }

        let logsURL = root.appendingPathComponent("logs", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: logsURL.path)
        #expect(names.contains("app.jsonl"))
        #expect(
            names.filter {
                $0 != "app.jsonl" && $0.hasPrefix("app.") && $0.hasSuffix(".jsonl")
            }.count <= 4
        )
        #expect(!names.contains("app.5.jsonl"))
        for name in names where name.hasSuffix(".jsonl") {
            let data = try Data(contentsOf: logsURL.appendingPathComponent(name))
            for line in data.split(separator: 0x0A) {
                #expect((try? JSONSerialization.jsonObject(with: Data(line))) != nil)
            }
        }
    }

    @Test
    func failedRotationStopsFileWritesInsteadOfGrowingPastTheLimit() throws {
        let root = temporaryDirectory("rotation-fail-closed")
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = AppDiagnostics(
            homeURL: root,
            enabled: true,
            maximumFileBytes: 1_024,
            backupCount: 4
        )
        let logURL = try #require(logger.logURL)
        try writePrivate(Data(repeating: 0x78, count: 1_000), to: logURL)
        let blockingBackup = logURL.deletingLastPathComponent()
            .appendingPathComponent("app.4.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: blockingBackup, withIntermediateDirectories: false)
        #expect(chmod(blockingBackup.path, 0o700) == 0)

        logger.log(
            .info,
            category: "rotation",
            event: "must_not_append",
            metadata: ["payload": .string(String(repeating: "x", count: 180))]
        )

        #expect((try Data(contentsOf: logURL)).count == 1_000)
    }

    @Test
    func currentLogRotatesAfterFourteenDaysEvenWhenItWasRecentlyModified() throws {
        let root = temporaryDirectory("age-rotation")
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date()
        let first = AppDiagnostics(
            homeURL: root,
            enabled: true,
            now: { startedAt }
        )
        first.log(.info, category: "age", event: "first_launch")

        let future = startedAt.addingTimeInterval(15 * 86_400)
        let second = AppDiagnostics(
            homeURL: root,
            enabled: true,
            now: { future }
        )
        second.log(.info, category: "age", event: "future_launch")

        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let backup = logs.appendingPathComponent("app.1.jsonl")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("first_launch"))
        #expect(
            try String(contentsOf: logs.appendingPathComponent("app.jsonl"), encoding: .utf8)
                .contains("future_launch")
        )
    }

    @Test
    func expiredBackupIsRemovedAndStoragePermissionsStayPrivate() throws {
        let root = temporaryDirectory("retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let logsURL = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o755) == 0)
        #expect(chmod(logsURL.path, 0o755) == 0)
        let expired = logsURL.appendingPathComponent("app.1.jsonl")
        try Data("old\n".utf8).write(to: expired)
        #expect(chmod(expired.path, 0o644) == 0)
        try setLifecycleDate(Date(timeIntervalSinceNow: -15 * 86_400), at: expired)

        let logger = AppDiagnostics(homeURL: root, enabled: true, retentionDays: 14)
        logger.log(.info, category: "test", event: "permissions")

        #expect(!FileManager.default.fileExists(atPath: expired.path))
        let logURL = try #require(logger.logURL)
        #expect(posixPermissions(at: root) == 0o700)
        #expect(posixPermissions(at: logsURL) == 0o700)
        #expect(posixPermissions(at: logURL) == 0o600)
    }

    @Test
    func symlinkedLogsDirectoryFailsClosed() throws {
        let root = temporaryDirectory("logs-symlink")
        let outside = temporaryDirectory("logs-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o700) == 0)
        #expect(chmod(outside.path, 0o700) == 0)
        #expect(symlink(outside.path, root.appendingPathComponent("logs").path) == 0)

        let logger = AppDiagnostics(homeURL: root, enabled: true)
        logger.log(.error, category: "security", event: "must_not_escape")

        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("app.jsonl").path))
    }

    @Test
    func legacyDirectLogRotatesAndLegacyLaunchdLogsStayBounded() throws {
        let home = temporaryDirectory("legacy")
        defer { try? FileManager.default.removeItem(at: home) }
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        #expect(chmod(home.path, 0o700) == 0)
        #expect(chmod(logs.path, 0o700) == 0)
        let direct = logs.appendingPathComponent("petcore-launch.log")
        try writePrivate(Data(repeating: 0x78, count: 1_024 * 1_024 + 1), to: direct)
        let obsolete = logs.appendingPathComponent("petcore.launchd.err.log")
        try writePrivate(Data("obsolete".utf8), to: obsolete)
        try setLifecycleDate(Date(timeIntervalSinceNow: -15 * 86_400), at: obsolete)
        let oversized = logs.appendingPathComponent("petcore.launchd.out.log")
        var oversizedData = Data()
        while oversizedData.count <= 1_024 * 1_024 {
            oversizedData.append(Data("old launch output line\n".utf8))
        }
        oversizedData.append(Data("latest launch failure\n".utf8))
        try writePrivate(oversizedData, to: oversized)

        try AppLegacyLogMaintenance.maintain(logsURL: logs)

        #expect((try Data(contentsOf: direct)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: logs.appendingPathComponent("petcore-launch.1.log").path))
        #expect((try Data(contentsOf: obsolete)).isEmpty)
        let boundedLaunchdOutput = try Data(contentsOf: oversized)
        #expect(boundedLaunchdOutput.count <= 1_024 * 1_024)
        #expect(String(decoding: boundedLaunchdOutput, as: UTF8.self).contains("latest launch failure"))
        #expect(posixPermissions(at: obsolete) == 0o600)
        #expect(posixPermissions(at: oversized) == 0o600)
        #expect(posixPermissions(at: direct) == 0o600)
    }

    @Test
    func legacyDirectLogAgeUsesCreationBeforeFreshModification() {
        let referenceDate = Date()
        #expect(AppDiagnosticRetentionPolicy.isExpired(
            creationDate: referenceDate.addingTimeInterval(-15 * 86_400),
            modificationDate: referenceDate,
            referenceDate: referenceDate,
            retentionInterval: 14 * 86_400
        ))
        #expect(!AppDiagnosticRetentionPolicy.isExpired(
            creationDate: nil,
            modificationDate: referenceDate,
            referenceDate: referenceDate,
            retentionInterval: 14 * 86_400
        ))
    }

    @Test
    func legacySecureAppendRejectsReplacedAndHardLinkedFiles() throws {
        let home = temporaryDirectory("legacy-secure-append")
        let outside = temporaryDirectory("legacy-secure-outside")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try AppLegacyLogMaintenance.maintain(logsURL: logs)
        let direct = logs.appendingPathComponent("petcore-launch.log")
        try AppLegacyLogMaintenance.appendSecurely(Data("safe\n".utf8), to: direct)
        #expect(try String(contentsOf: direct, encoding: .utf8) == "safe\n")

        try FileManager.default.removeItem(at: direct)
        let outsideFile = outside.appendingPathComponent("outside.log")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try writePrivate(Data(), to: outsideFile)
        #expect(symlink(outsideFile.path, direct.path) == 0)
        #expect(throws: AppDiagnosticArchiveError.self) {
            try AppLegacyLogMaintenance.openSecureAppendHandle(at: direct)
        }
        try FileManager.default.removeItem(at: direct)
        #expect(link(outsideFile.path, direct.path) == 0)
        #expect(throws: AppDiagnosticArchiveError.self) {
            try AppLegacyLogMaintenance.openSecureAppendHandle(at: direct)
        }
    }

    @Test
    func structuredExportSanitizerDropsIdentifiersAndInvalidLines() throws {
        let input = Data("""
        {"schema_version":"apc.diagnostic-log.v1","timestamp":"2026-07-20T00:00:00Z","run_id":"launch-secret","process":"app","level":"info","category":"rpc","event":"failed","metadata":{"build_id":"public-build","session_id":"private-session","message_content":"private-message","workspace":"cwd=/private/Client Secret/project","contact":"private.person@example.com","host":"alice-mac.local","user":"alice","ip":"192.168.1.42","peer_host":"mac01.corp.example.com","client_ip":"fe80::aede:48ff:fe00:1122","correlation":"018f6f71-8067-7802-a4ee-e71333bb1429","opaque_value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","count":2}}
        not-json

        """.utf8)

        let output = AppDiagnosticRedactor.sanitizeStructuredLog(input)
        let string = String(decoding: output, as: UTF8.self)
        #expect(!string.contains("launch-secret"))
        #expect(!string.contains("private-session"))
        #expect(!string.contains("private-message"))
        #expect(!string.contains("Client Secret"))
        #expect(!string.contains("private.person@example.com"))
        #expect(!string.contains("018f6f71-8067-7802-a4ee-e71333bb1429"))
        #expect(!string.contains("alice-mac.local"))
        #expect(!string.contains("192.168.1.42"))
        #expect(!string.contains("mac01.corp.example.com"))
        #expect(!string.contains("fe80::aede:48ff:fe00:1122"))
        #expect(!string.contains("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        #expect(!string.contains("not-json"))
        #expect(string.contains("public-build"))
        #expect(output.split(separator: 0x0A).count == 1)
    }

    @Test
    func structuredExportSanitizerBoundsNestedContainersAndRejectsMalformedRecords() throws {
        var nested: Any = ["value": "deep-public-sentinel"]
        for _ in 0 ..< 8 { nested = ["nested": nested] }
        let wide = Dictionary(uniqueKeysWithValues: (0 ..< 200).map { ("field_\($0)", $0) })
        let record: [String: Any] = [
            "schema_version": AppDiagnostics.schemaVersion,
            "timestamp": "2026-07-20T00:00:00Z",
            "process": "app",
            "level": "info",
            "category": "test",
            "event": "bounded",
            "metadata": [
                "nested": nested,
                "array": Array(0 ..< 100),
                "wide": wide
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(0x0A)
        data.append(Data(#"{"schema_version":"apc.diagnostic-log.v1","timestamp":"alice","process":"app","level":"info","category":"192.168.1.42","event":"alice-mac.local","metadata":{}}"#.utf8))
        data.append(0x0A)

        let output = AppDiagnosticRedactor.sanitizeStructuredLog(data)
        #expect(output.split(separator: 0x0A).count == 1)
        #expect(!String(decoding: output, as: UTF8.self).contains("deep-public-sentinel"))
        let line = try #require(output.split(separator: 0x0A).first)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        )
        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect((metadata["array"] as? [Any])?.count == 64)
        #expect((metadata["wide"] as? [String: Any])?.count == 128)
    }

    @MainActor
    @Test
    func environmentAndRPCParametersUseOnlyTheSanitizedSchema() throws {
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
        let environment = AppDiagnosticEnvironment.capture(store: store)
        let object = try environment.jsonObject()
        let parameters = try AppStore.diagnosticsExportParameters(environment: environment)
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(object["schema_version"] as? String == AppDiagnosticEnvironment.schemaVersion)
        #expect(parameters.keys.sorted() == ["app_environment"])
        #expect(!text.contains("session_id"))
        #expect(!text.contains("\"title\""))
        #expect(!text.contains("\"detail\""))
        #expect(!text.contains("\"content\""))
        #expect(!text.contains("\"path\""))
        #expect(!text.contains("\"name\""))
        #expect(AppDiagnosticEnvironment.sanitizedRuntimeToken("1.2.3") == "1.2.3")
        #expect(AppDiagnosticEnvironment.sanitizedRuntimeToken("/private/Client Project") == nil)
        #expect(AppDiagnosticEnvironment.sanitizedPetState("working") == "working")
        #expect(AppDiagnosticEnvironment.sanitizedPetState("/private/Client Project") == nil)
    }

    @MainActor
    @Test
    func diagnosticsUsesTheLongRunningRPCBudgetAndStableArchiveName() {
        #expect(PetCoreClient.defaultTimeout(for: "diagnostics.export") == .seconds(120))
        #expect(
            AppStore.defaultDiagnosticsArchiveName(date: Date(timeIntervalSince1970: 0))
                == "AgentPetCompanion-Diagnostics-19700101-000000.zip"
        )
    }

    @Test
    func temporaryArchiveValidationRejectsOutsideFilesAndHardLinks() throws {
        let root = temporaryDirectory("archive-security")
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = AppDiagnosticPaths.diagnosticExportsURL(homeURL: root)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o700) == 0)
        #expect(chmod(exports.path, 0o700) == 0)
        let valid = exports.appendingPathComponent("valid.zip")
        try minimalZIPData().write(to: valid)
        #expect(chmod(valid.path, 0o600) == 0)
        #expect(
            try AppDiagnosticArchiveSecurity.validateTemporaryArchive(valid, homeURL: root) == valid
        )

        let outside = root.appendingPathComponent("outside.zip")
        try minimalZIPData().write(to: outside)
        #expect(chmod(outside.path, 0o600) == 0)
        #expect(throws: AppDiagnosticArchiveError.self) {
            try AppDiagnosticArchiveSecurity.validateTemporaryArchive(outside, homeURL: root)
        }

        let hardLinkSource = exports.appendingPathComponent("hard-source.zip")
        let hardLink = exports.appendingPathComponent("hard-link.zip")
        try minimalZIPData().write(to: hardLinkSource)
        #expect(chmod(hardLinkSource.path, 0o600) == 0)
        #expect(link(hardLinkSource.path, hardLink.path) == 0)
        #expect(throws: AppDiagnosticArchiveError.self) {
            try AppDiagnosticArchiveSecurity.validateTemporaryArchive(hardLink, homeURL: root)
        }
    }

    @Test
    func installingArchiveCorrectsAnExistingDestinationToPrivatePermissions() async throws {
        let home = temporaryDirectory("archive-install-home")
        let destinationRoot = temporaryDirectory("archive-install-destination")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let exports = AppDiagnosticPaths.diagnosticExportsURL(homeURL: home)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        #expect(chmod(home.path, 0o700) == 0)
        #expect(chmod(exports.path, 0o700) == 0)
        let source = exports.appendingPathComponent("source.zip")
        try writePrivate(minimalZIPData(), to: source)
        let destination = destinationRoot.appendingPathComponent("diagnostics.zip")
        try Data("old".utf8).write(to: destination)
        #expect(chmod(destination.path, 0o644) == 0)

        try await AppDiagnosticArchiveSecurity.install(source, at: destination)

        #expect(try Data(contentsOf: destination) == minimalZIPData())
        #expect(posixPermissions(at: destination) == 0o600)
    }

    @Test
    func loggerStartupCleansOnlyExpiredAllowlistedArtifactsAndBoundsCompletedArchives() throws {
        let home = temporaryDirectory("artifact-cleanup")
        defer { try? FileManager.default.removeItem(at: home) }
        let exports = AppDiagnosticPaths.diagnosticExportsURL(homeURL: home)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        #expect(chmod(home.path, 0o700) == 0)
        #expect(chmod(exports.path, 0o700) == 0)
        let referenceDate = Date()
        let freshArchiveNames = [
            "AgentPetCompanion-Diagnostics-20260720T120000Z.zip",
            "AgentPetCompanion-Diagnostics-20260720T120001Z.zip",
            "AgentPetCompanion-Diagnostics-20260720T120002Z.zip",
            "offline-123E4567-E89B-42D3-A456-426614174000.zip"
        ]
        for (index, name) in freshArchiveNames.enumerated() {
            let url = exports.appendingPathComponent(name)
            try minimalZIPData().write(to: url)
            #expect(chmod(url.path, 0o600) == 0)
            try setLifecycleDate(referenceDate.addingTimeInterval(-Double(index) * 60), at: url)
        }
        let staleArchive = exports.appendingPathComponent(
            "AgentPetCompanion-Diagnostics-20260718T120000Z.zip"
        )
        try minimalZIPData().write(to: staleArchive)
        #expect(chmod(staleArchive.path, 0o600) == 0)
        try setLifecycleDate(referenceDate.addingTimeInterval(-2 * 86_400), at: staleArchive)

        let freshStaging = exports.appendingPathComponent(
            ".staging-123E4567-E89B-42D3-A456-426614174000",
            isDirectory: true
        )
        let staleStaging = exports.appendingPathComponent(
            ".staging-223E4567-E89B-42D3-A456-426614174000",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: freshStaging, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: staleStaging, withIntermediateDirectories: false)
        #expect(chmod(freshStaging.path, 0o700) == 0)
        #expect(chmod(staleStaging.path, 0o700) == 0)
        try setLifecycleDate(referenceDate, at: freshStaging)
        try setLifecycleDate(referenceDate.addingTimeInterval(-2 * 86_400), at: staleStaging)

        let freshTemporary = exports.appendingPathComponent(".diagnostic-export-active123")
        let staleTemporary = exports.appendingPathComponent(".diagnostic-export-stale123")
        try writePrivate(Data("active".utf8), to: freshTemporary)
        try writePrivate(Data("stale".utf8), to: staleTemporary)
        try setLifecycleDate(referenceDate, at: freshTemporary)
        try setLifecycleDate(referenceDate.addingTimeInterval(-2 * 86_400), at: staleTemporary)
        let unrelated = exports.appendingPathComponent("user-important.zip")
        try writePrivate(minimalZIPData(), to: unrelated)
        try setLifecycleDate(referenceDate.addingTimeInterval(-30 * 86_400), at: unrelated)

        _ = AppDiagnostics(homeURL: home, enabled: true, now: { referenceDate })

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: exports.path))
        #expect(freshArchiveNames.filter(remaining.contains).count == 3)
        #expect(!remaining.contains(staleArchive.lastPathComponent))
        #expect(remaining.contains(freshStaging.lastPathComponent))
        #expect(!remaining.contains(staleStaging.lastPathComponent))
        #expect(remaining.contains(freshTemporary.lastPathComponent))
        #expect(!remaining.contains(staleTemporary.lastPathComponent))
        #expect(remaining.contains(unrelated.lastPathComponent))
    }

    @MainActor
    @Test
    func offlineExporterCreatesAFixedSanitizedAllowlistedZip() async throws {
        let home = temporaryDirectory("offline-home")
        let extraction = temporaryDirectory("offline-extraction")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: extraction)
        }
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        #expect(chmod(home.path, 0o700) == 0)
        #expect(chmod(logs.path, 0o700) == 0)
        let structured = """
        {"schema_version":"apc.diagnostic-log.v1","timestamp":"2026-07-20T00:00:00Z","process":"app","level":"info","category":"test","event":"sample","metadata":{"build_id":"build-safe","session_id":"session-secret","workspace":"path=/Volumes/Secret Project/private.file","contact":"private.person@example.com"}}
        not-json

        """
        try writePrivate(Data(structured.utf8), to: logs.appendingPathComponent("app.jsonl"))
        try writePrivate(
            Data("Authorization: Bearer top-secret-value\nerror cwd=/Volumes/Client Project/Repo/file\nhostname=alice-mac.local user=alice ip=192.168.1.42\npeer_host=mac01.corp.example.com client_ip=fe80::aede:48ff:fe00:1122\n".utf8),
            to: logs.appendingPathComponent("petcore-launch.log")
        )
        try writePrivate(
            Data(structured.utf8),
            to: logs.appendingPathComponent("app-evil.jsonl")
        )
        let expiredPetCore = logs.appendingPathComponent("petcore.jsonl")
        try writePrivate(Data(structured.utf8), to: expiredPetCore)
        try setLifecycleDate(Date(timeIntervalSinceNow: -15 * 86_400), at: expiredPetCore)
        try writePrivate(
            Data("invalid-json-only\n".utf8),
            to: logs.appendingPathComponent("petcore.1.jsonl")
        )
        let unsafePetCore = logs.appendingPathComponent("petcore.4.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafePetCore, withIntermediateDirectories: false)
        #expect(chmod(unsafePetCore.path, 0o700) == 0)
        var boundaryLegacy = Data("Authorization: Bearer ".utf8)
        boundaryLegacy.append(Data(repeating: 0x73, count: 2 * 1_024 * 1_024 + 256))
        boundaryLegacy.append(Data("\nlatest safe launch line\n".utf8))
        try writePrivate(
            boundaryLegacy,
            to: logs.appendingPathComponent("petcore.launchd.err.log")
        )
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
        let environment = AppDiagnosticEnvironment.capture(store: store)
        let archive = try await AppDiagnosticOfflineExporter.makeArchive(
            environment: environment,
            homeURL: home
        )
        defer { try? FileManager.default.removeItem(at: archive) }

        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, extraction.path],
            timeout: .seconds(10)
        )
        #expect(result.termination == .exited(status: 0))
        let bundle = extraction.appendingPathComponent("AgentPetCompanion-Diagnostics", isDirectory: true)
        let exportedLogs = bundle.appendingPathComponent("logs", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("environment.json").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("README.txt").path))
        #expect(FileManager.default.fileExists(atPath: exportedLogs.appendingPathComponent("app.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: exportedLogs.appendingPathComponent("app-evil.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: exportedLogs.appendingPathComponent("petcore.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: expiredPetCore.path))

        let appLog = try String(
            contentsOf: exportedLogs.appendingPathComponent("app.jsonl"),
            encoding: .utf8
        )
        let legacyLog = try String(
            contentsOf: exportedLogs.appendingPathComponent("petcore-launch.log"),
            encoding: .utf8
        )
        let boundaryLegacyLog = try String(
            contentsOf: exportedLogs.appendingPathComponent("petcore.launchd.err.log"),
            encoding: .utf8
        )
        #expect(appLog.contains("build-safe"))
        #expect(!appLog.contains("session-secret"))
        #expect(!appLog.contains("Secret Project"))
        #expect(!appLog.contains("private.person@example.com"))
        #expect(!legacyLog.contains("top-secret-value"))
        #expect(!legacyLog.contains("Client Project"))
        #expect(!legacyLog.contains("alice-mac.local"))
        #expect(!legacyLog.contains("192.168.1.42"))
        #expect(!legacyLog.contains("mac01.corp.example.com"))
        #expect(!legacyLog.contains("fe80::aede:48ff:fe00:1122"))
        #expect(legacyLog.contains("<redacted>"))
        #expect(legacyLog.contains("<redacted-path>"))
        #expect(boundaryLegacyLog == "latest safe launch line\n")

        let environmentData = try Data(contentsOf: bundle.appendingPathComponent("environment.json"))
        let environmentObject = try #require(
            JSONSerialization.jsonObject(with: environmentData) as? [String: Any]
        )
        #expect(environmentObject["schema_version"] as? String == "apc.diagnostic-environment.v1")

        let manifestData = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
        let manifest = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        #expect(manifest["schema_version"] as? String == "apc.diagnostics-bundle.v1")
        #expect(manifest["privacy_profile"] as? String == "apc.diagnostic-redaction.v1")
        #expect(manifest["log_schema_version"] as? String == AppDiagnostics.schemaVersion)
        #expect(manifest["log_current_max_bytes"] as? Int == 2 * 1_024 * 1_024)
        #expect(manifest["log_backup_count"] as? Int == 4)
        #expect(manifest["log_retention_days"] as? Int == 14)
        let files = try #require(manifest["files"] as? [[String: Any]])
        let names = Set(files.compactMap { $0["name"] as? String })
        #expect(names.contains("environment.json"))
        #expect(names.contains("README.txt"))
        #expect(!names.contains("manifest.json"))
        #expect(names.contains("logs/app.jsonl"))
        #expect(names.contains("logs/petcore-launch.log"))
        for file in files {
            #expect(file["source_bytes"] is Int)
            #expect(file["included_bytes"] is Int)
            #expect(file["truncated"] is Bool)
            #expect((file["sha256"] as? String)?.count == 64)
        }
        let appManifest = try #require(files.first { $0["name"] as? String == "logs/app.jsonl" })
        #expect(appManifest["truncated"] as? Bool == true)
        let boundaryManifest = try #require(
            files.first { $0["name"] as? String == "logs/petcore.launchd.err.log" }
        )
        #expect(boundaryManifest["truncated"] as? Bool == true)
        let omitted = try #require(manifest["omitted_files"] as? [[String: Any]])
        let omissionReasons: [String: String] = Dictionary(
            uniqueKeysWithValues: omitted.compactMap { entry -> (String, String)? in
            guard let name = entry["name"] as? String,
                  let reason = entry["reason"] as? String
            else { return nil }
            return (name, reason)
        })
        #expect(omissionReasons["petcore.jsonl"] == "expired")
        #expect(omissionReasons["petcore.1.jsonl"] == "invalid_json")
        #expect(omissionReasons["petcore.4.jsonl"] == "unsafe_file")
    }

    private func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "apc-diagnostics-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func posixPermissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        #expect(chmod(url.path, 0o600) == 0)
    }

    private func setLifecycleDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func minimalZIPData() -> Data {
        Data([0x50, 0x4B, 0x03, 0x04])
            + Data(repeating: 0, count: 30)
            + Data([0x50, 0x4B, 0x05, 0x06])
            + Data(repeating: 0, count: 18)
    }
}
