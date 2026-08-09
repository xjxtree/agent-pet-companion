import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Product convergence")
@MainActor
struct ProductConvergenceTests {
    @Test
    func freshInstallConvergesQuietlyOnlyAfterEveryTargetVerifies() async throws {
        let manifest = runtimeManifest(buildID: "build-new", releaseChannel: "release")
        let report = completeReport()
        let receipt = convergenceReceipt(manifest: manifest, report: report)
        var methods: [String] = []
        var snapshotRefreshes = 0
        let store = makeStore(
            manifest: manifest,
            request: { method, _, _ in
                methods.append(method)
                return try response(
                    for: method,
                    existingReceipt: nil,
                    report: report,
                    updatedReceipt: receipt
                )
            },
            refreshSnapshot: {
                snapshotRefreshes += 1
            }
        )

        let task = try #require(store.scheduleProductConvergence(
            bundledPetsReady: true
        ))
        await task.value

        #expect(store.appUpdateConvergenceState == .idle)
        #expect(store.canStartNewGenerationWork)
        #expect(methods == [
            "product.convergence.get",
            "product.convergence.preflight",
            "connections.refresh_installed",
            "product.convergence.update",
        ])
        #expect(snapshotRefreshes == 1)
    }

    @Test
    func existingCurrentReceiptSkipsAllMutationAndStaysQuiet() async throws {
        let manifest = runtimeManifest(buildID: "build-current", releaseChannel: "release")
        let report = completeReport()
        let receipt = convergenceReceipt(manifest: manifest, report: report)
        var methods: [String] = []
        let store = makeStore(
            manifest: manifest,
            request: { method, _, _ in
                methods.append(method)
                guard method == "product.convergence.get" else {
                    throw ProductConvergenceTestError.unexpectedMethod(method)
                }
                return try jsonObject(receipt)
            }
        )

        let task = try #require(store.scheduleProductConvergence())
        await task.value

        #expect(methods == ["product.convergence.get"])
        #expect(store.appUpdateConvergenceState == .idle)
    }

    @Test
    func upgradedBuildPublishesSuccessOnlyAfterTheNewReceipt() async throws {
        let oldManifest = runtimeManifest(buildID: "build-old", appVersion: "0.2.0")
        let newManifest = runtimeManifest(
            buildID: "build-new",
            appVersion: "0.3.0",
            releaseChannel: "release"
        )
        let report = completeReport()
        let oldReceipt = convergenceReceipt(manifest: oldManifest, report: report)
        let newReceipt = convergenceReceipt(manifest: newManifest, report: report)
        let store = makeStore(
            manifest: newManifest,
            request: { method, _, _ in
                try response(
                    for: method,
                    existingReceipt: oldReceipt,
                    report: report,
                    updatedReceipt: newReceipt
                )
            }
        )

        let task = try #require(store.scheduleProductConvergence())
        await task.value

        #expect(store.appUpdateConvergenceState == .completed(version: "0.3.0"))
    }

    @Test
    func legacyInstalledRuntimeWithoutAReceiptStillGetsUpgradeConfirmation() async throws {
        let manifest = runtimeManifest(
            buildID: "build-new",
            appVersion: "0.3.0",
            releaseChannel: "release"
        )
        let report = completeReport()
        let receipt = convergenceReceipt(manifest: manifest, report: report)
        let store = makeStore(
            manifest: manifest,
            request: { method, _, _ in
                try response(
                    for: method,
                    existingReceipt: nil,
                    report: report,
                    updatedReceipt: receipt
                )
            },
            upgradeEvidence: { _ in true }
        )

        let task = try #require(store.scheduleProductConvergence())
        await task.value

        #expect(store.appUpdateConvergenceState == .completed(version: "0.3.0"))
    }

    @Test
    func missingBundledPetsNeverWritesOrClaimsAConvergenceReceipt() async throws {
        let manifest = runtimeManifest(buildID: "build-new", releaseChannel: "release")
        var requestCount = 0
        let store = makeStore(
            manifest: manifest,
            request: { method, _, _ in
                requestCount += 1
                throw ProductConvergenceTestError.unexpectedMethod(method)
            }
        )

        let task = try #require(store.scheduleProductConvergence(
            bundledPetsReady: false
        ))
        await task.value

        #expect(requestCount == 0)
        #expect(store.appUpdateConvergenceState == .needsAttention(.bundledPets))
        #expect(!store.canStartNewGenerationWork)
    }

    @Test
    func partialConnectorResultIsIsolatedAndRetryCanFinish() async throws {
        let manifest = runtimeManifest(buildID: "build-new", releaseChannel: "release")
        let complete = completeReport()
        let incomplete = incompleteCodexReport()
        let receipt = convergenceReceipt(manifest: manifest, report: complete)
        var attempt = 0
        var updateCalls = 0
        let store = makeStore(
            manifest: manifest,
            request: { method, _, _ in
                switch method {
                case "product.convergence.get":
                    return NSNull()
                case "product.convergence.preflight":
                    return try jsonObject(safePreflight)
                case "connections.refresh_installed":
                    attempt += 1
                    return try jsonObject(attempt == 1 ? incomplete : complete)
                case "product.convergence.update":
                    updateCalls += 1
                    return try jsonObject(receipt)
                default:
                    throw ProductConvergenceTestError.unexpectedMethod(method)
                }
            }
        )

        let first = try #require(store.scheduleProductConvergence())
        await first.value
        #expect(
            store.appUpdateConvergenceState
                == .needsAttention(.connectors([codexConflictIssue]))
        )
        #expect(!store.canStartNewGenerationWork)
        #expect(updateCalls == 0)

        let retry = try #require(store.scheduleProductConvergence(force: true))
        await retry.value
        #expect(store.appUpdateConvergenceState == .idle)
        #expect(updateCalls == 1)
    }

    @Test
    func connectorAttentionNamesTheFailureAndTheRecoverySteps() {
        let issues = incompleteCodexReport().attentionIssues
        #expect(issues == [codexConflictIssue])

        let attention = AppUpdateConvergenceAttention.connectors(issues)
        let chinese = AppUpdateConvergenceAttentionPresentation.resolve(
            attention,
            locale: "zh-Hans"
        )
        #expect(chinese.title == "Codex 连接需要处理")
        #expect(chinese.detail.contains("不属于本 App"))
        #expect(chinese.detail.contains("全部检查"))

        let english = AppUpdateConvergenceAttentionPresentation.resolve(
            attention,
            locale: "en"
        )
        #expect(english.title == "Action Required for Codex")
        #expect(english.detail.contains("left them untouched"))
        #expect(english.detail.contains("Check All"))
    }

    @Test
    func nonConnectorAttentionProvidesAConcreteRecoveryPath() {
        let bundled = AppUpdateConvergenceAttentionPresentation.resolve(
            .bundledPets,
            locale: "en"
        )
        #expect(bundled.title == "Bundled Pet Files Are Missing")
        #expect(bundled.detail.contains("official release"))
        #expect(bundled.detail.contains("replace the App"))

        let service = AppUpdateConvergenceAttentionPresentation.resolve(
            .service,
            locale: "zh-Hans"
        )
        #expect(service.title == "无法验证本地服务")
        #expect(service.detail.contains("恢复服务"))
        #expect(service.detail.contains("重新检查"))
    }

    @Test
    func successfulManualRuntimeCheckPersistsAuthoritativeConvergence() async throws {
        let manifest = runtimeManifest(buildID: "build-new", releaseChannel: "release")
        let incomplete = incompleteCodexReport()
        let complete = completeReport()
        let receipt = convergenceReceipt(manifest: manifest, report: complete)
        let checkedStatus = healthyManagedCodexStatus()
        var methods: [String] = []
        var refreshCount = 0
        let store = makeStore(
            manifest: manifest,
            sleeper: { _ in await Task.yield() },
            initialPetStudioCodexAvailability: .available,
            request: { method, _, _ in
                methods.append(method)
                switch method {
                case "product.convergence.get":
                    return NSNull()
                case "product.convergence.preflight":
                    return try jsonObject(safePreflight)
                case "connections.refresh_installed":
                    refreshCount += 1
                    return try jsonObject(refreshCount == 1 ? incomplete : complete)
                case "connections.check":
                    return try jsonObject(checkedStatus)
                case "product.convergence.update":
                    return try jsonObject(receipt)
                default:
                    throw ProductConvergenceTestError.unexpectedMethod(method)
                }
            }
        )

        let convergence = try #require(store.scheduleProductConvergence())
        await convergence.value
        #expect(
            store.appUpdateConvergenceState
                == .needsAttention(.connectors([codexConflictIssue]))
        )
        #expect(!store.canStartNewGenerationWork)
        store.updateGenerationDescription("A complete mechanical otter pet brief")
        #expect(
            store.generationStartBlockingDetail
                == APCLocalization.text(.appUpdateConvergenceMakerBlocked)
        )
        #expect(
            store.generationStartPresentationDetail
                == APCLocalization.text(.appUpdateConvergenceMakerBlocked)
        )

        store.checkConnection(.codex)
        for _ in 0..<1_000 where store.connectionOperationState.isRunning {
            await Task.yield()
        }
        for _ in 0..<2_000 where
            !methods.contains("product.convergence.update")
                || store.appUpdateConvergenceState != .idle
                || !store.canStartNewGenerationWork
        {
            await Task.yield()
        }

        #expect(!store.connectionOperationState.isRunning)
        #expect(store.appUpdateConvergenceState == .idle)
        #expect(store.canStartNewGenerationWork)
        #expect(store.canStartGeneration)
        #expect(store.generationStartBlockingDetail == nil)
        #expect(
            store.generationStartPresentationDetail
                == APCLocalization.text(.studioWelcomeDetail)
        )
        #expect(methods.contains("product.convergence.update"))
        #expect(refreshCount == 2)
    }

    @Test
    func manualRecoveryRequiresAnExactVerifiedRuntimeStatus() {
        let healthy = healthyManagedCodexStatus()
        #expect(ProductConvergenceConnectionRecoveryPolicy.resolvesAttention(healthy))

        var light = healthy
        light.checkMode = .light
        #expect(!ProductConvergenceConnectionRecoveryPolicy.resolvesAttention(light))

        var unverified = healthy
        unverified.verification.status = .unverified
        #expect(!ProductConvergenceConnectionRecoveryPolicy.resolvesAttention(unverified))

        var incomplete = healthy
        incomplete.items[1].status = .needsFix
        #expect(!ProductConvergenceConnectionRecoveryPolicy.resolvesAttention(incomplete))
    }

    @Test
    func managedStaticConnectorRequiresMatchingReleaseWithoutCodexDigests() {
        let current = managedStaticResult(
            source: .pi,
            expectedVersion: "0.3.0",
            activeVersion: "0.3.0"
        )
        let mismatched = managedStaticResult(
            source: .pi,
            expectedVersion: "0.3.0",
            activeVersion: "0.2.0"
        )
        let missing = managedStaticResult(
            source: .pi,
            expectedVersion: "0.3.0",
            activeVersion: nil
        )
        let codexDigest = ProductConnectorRefreshResult(
            source: .pi,
            status: .current,
            managed: true,
            refreshed: true,
            ok: true,
            verified: true,
            expectedVersion: "0.3.0",
            activeVersion: "0.3.0",
            expectedSkillsSHA256: nil,
            activeSkillsSHA256: nil,
            expectedContentSHA256: String(repeating: "a", count: 64),
            managedSourceContentSHA256: nil,
            activeContentSHA256: nil,
            detail: "current",
            error: nil
        )

        #expect(current.isExactlyConverged)
        #expect(!mismatched.isExactlyConverged)
        #expect(!missing.isExactlyConverged)
        #expect(!codexDigest.isExactlyConverged)
    }

    @Test
    func finalSnapshotFailureNeverClaimsTheNewVersionIsReady() async throws {
        let manifest = runtimeManifest(
            buildID: "build-new",
            appVersion: "0.3.0",
            releaseChannel: "release"
        )
        let report = completeReport()
        let receipt = convergenceReceipt(manifest: manifest, report: report)
        var updateCalls = 0
        let store = makeStore(
            manifest: manifest,
            request: { method, _, _ in
                if method == "product.convergence.update" {
                    updateCalls += 1
                }
                return try response(
                    for: method,
                    existingReceipt: nil,
                    report: report,
                    updatedReceipt: receipt
                )
            },
            refreshSnapshot: {
                throw ProductConvergenceTestError.snapshotUnavailable
            },
            upgradeEvidence: { _ in true }
        )

        let task = try #require(store.scheduleProductConvergence())
        await task.value

        #expect(updateCalls == 1)
        #expect(store.appUpdateConvergenceState == .needsAttention(.service))
        #expect(!store.canStartNewGenerationWork)
    }

    @Test
    func slowConvergenceShowsProgressAndBlocksAppHandoff() async throws {
        let manifest = runtimeManifest(buildID: "build-new", releaseChannel: "release")
        let report = completeReport()
        let receipt = convergenceReceipt(manifest: manifest, report: report)
        let gate = ProductConvergenceRequestGate()
        let store = makeStore(
            manifest: manifest,
            sleeper: { _ in
                try await Task.sleep(for: .milliseconds(10))
            },
            request: { method, _, _ in
                if method == "connections.refresh_installed" {
                    await gate.wait()
                }
                return try response(
                    for: method,
                    existingReceipt: nil,
                    report: report,
                    updatedReceipt: receipt
                )
            }
        )

        let task = try #require(store.scheduleProductConvergence())
        await gate.waitUntilBlocked()
        for _ in 0..<200 where store.appUpdateConvergenceState != .updating {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.appUpdateConvergenceState == .updating)
        #expect(!store.isSafeForAppUpdateHandoff)
        #expect(!store.canStartNewGenerationWork)

        await gate.open()
        await task.value
        #expect(store.appUpdateConvergenceState == .idle)
        #expect(store.isSafeForAppUpdateHandoff)
    }

    @Test
    func retryOwnsTheWholeSeedAndVerificationWindow() async throws {
        let manifest = runtimeManifest(buildID: "build-new")
        let report = completeReport()
        let receipt = convergenceReceipt(manifest: manifest, report: report)
        let gate = ProductConvergenceRequestGate()
        let store = makeStore(
            manifest: manifest,
            request: { method, _, _ in
                try response(
                    for: method,
                    existingReceipt: nil,
                    report: report,
                    updatedReceipt: receipt
                )
            },
            bundledPetSeeder: {
                await gate.wait()
                return true
            }
        )

        store.retryProductConvergence()
        await gate.waitUntilBlocked()

        #expect(!store.isSafeForAppUpdateHandoff)
        #expect(!store.canStartNewGenerationWork)

        await gate.open()
        for _ in 0..<200 where store.appUpdateConvergenceState != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.appUpdateConvergenceState == .idle)
        #expect(store.isSafeForAppUpdateHandoff)
    }

    @Test
    func userConnectionOperationsCannotRaceTheConvergenceRefresh() async throws {
        let manifest = runtimeManifest(buildID: "build-new")
        let report = completeReport()
        let receipt = convergenceReceipt(manifest: manifest, report: report)
        let gate = ProductConvergenceRequestGate()
        var userCheckCalls = 0
        let store = makeStore(
            manifest: manifest,
            request: { method, _, _ in
                if method == "connections.refresh_installed" {
                    await gate.wait()
                } else if method == "connections.check" {
                    userCheckCalls += 1
                }
                return try response(
                    for: method,
                    existingReceipt: nil,
                    report: report,
                    updatedReceipt: receipt
                )
            }
        )

        let task = try #require(store.scheduleProductConvergence())
        await gate.waitUntilBlocked()
        #expect(!store.canStartConnectionOperation)

        store.checkConnection(.codex)
        await Task.yield()
        #expect(userCheckCalls == 0)

        await gate.open()
        await task.value
        #expect(store.canStartConnectionOperation)
    }

    @Test
    func receiptAcceptsRustFractionalRFC3339AndRejectsIncompleteSummary() {
        let manifest = runtimeManifest(buildID: "build-new")
        let report = completeReport()
        let valid = convergenceReceipt(manifest: manifest, report: report)
        #expect(valid.exactlyMatches(manifest: manifest, report: report))

        let invalid = ProductConvergenceReceipt(
            schemaVersion: ProductConvergenceReceipt.schemaVersion,
            buildID: manifest.buildID,
            appVersion: manifest.appVersion,
            completedAt: "2026-07-24T12:00:00.123456Z",
            connectorReportSummary: ProductConvergenceReceiptSummary(
                totalSources: 4,
                managedSources: 1,
                verifiedSources: 0,
                skippedSources: 3,
                reportSHA256: String(repeating: "c", count: 64),
                codexSkillsSHA256: String(repeating: "a", count: 64),
                codexContentSHA256: String(repeating: "b", count: 64)
            )
        )
        #expect(!invalid.exactlyMatches(manifest: manifest, report: report))
    }

    private func makeStore(
        manifest: RuntimeReleaseManifest,
        sleeper: @escaping AppStore.ProductConvergenceSleeper = { _ in
            try await Task.sleep(for: .seconds(60))
        },
        initialPetStudioCodexAvailability: PetStudioCodexAvailability = .checking,
        request: @escaping AppStore.PetCoreRequestOverride,
        refreshSnapshot: @escaping @MainActor () async throws -> Void = {},
        bundledPetSeeder: @escaping AppStore.BundledPetSeeder = { true },
        upgradeEvidence: @escaping AppStore.ProductConvergenceUpgradeEvidence = {
            _ in false
        }
    ) -> AppStore {
        let defaults = UserDefaults(
            suiteName: "ProductConvergenceTests.\(UUID().uuidString)"
        )!
        return AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in try await refreshSnapshot() },
                onReady: { _ in }
            ),
            bundledPetSeeder: bundledPetSeeder,
            petCoreRequestOverride: request,
            initialPetStudioCodexAvailability: initialPetStudioCodexAvailability,
            productConvergenceSleeper: sleeper,
            productConvergenceNoticePreferences: ProductConvergenceNoticePreferences(
                defaults: defaults
            ),
            productConvergenceManifest: manifest,
            productConvergenceUpgradeEvidence: upgradeEvidence
        )
    }

    private func response(
        for method: String,
        existingReceipt: ProductConvergenceReceipt?,
        report: ProductConnectorRefreshReport,
        updatedReceipt: ProductConvergenceReceipt
    ) throws -> Any {
        switch method {
        case "product.convergence.get":
            if let existingReceipt {
                return try jsonObject(existingReceipt)
            }
            return NSNull()
        case "product.convergence.preflight":
            return try jsonObject(safePreflight)
        case "connections.refresh_installed":
            return try jsonObject(report)
        case "product.convergence.update":
            return try jsonObject(updatedReceipt)
        default:
            throw ProductConvergenceTestError.unexpectedMethod(method)
        }
    }

    private var safePreflight: ProductConvergencePreflight {
        ProductConvergencePreflight(
            safe: true,
            activeGeneration: false,
            connectionOperationActive: false
        )
    }

    private var codexConflictIssue: ProductConnectorConvergenceIssue {
        ProductConnectorConvergenceIssue(
            source: .codex,
            reason: .managedPathConflict
        )
    }

    private func completeReport() -> ProductConnectorRefreshReport {
        ProductConnectorRefreshReport(
            ok: true,
            results: AgentSource.allCases.map { source in
                if source == .codex {
                    return ProductConnectorRefreshResult(
                        source: source,
                        status: .updated,
                        managed: true,
                        refreshed: true,
                        ok: true,
                        verified: true,
                        expectedVersion: "0.3.0",
                        activeVersion: "0.3.0",
                        expectedSkillsSHA256: String(repeating: "a", count: 64),
                        activeSkillsSHA256: String(repeating: "a", count: 64),
                        expectedContentSHA256: String(repeating: "b", count: 64),
                        managedSourceContentSHA256: String(repeating: "b", count: 64),
                        activeContentSHA256: String(repeating: "b", count: 64),
                        detail: "updated",
                        error: nil
                    )
                }
                return ProductConnectorRefreshResult(
                    source: source,
                    status: .skippedNotManaged,
                    managed: false,
                    refreshed: false,
                    ok: true,
                    verified: false,
                    expectedVersion: nil,
                    activeVersion: nil,
                    expectedSkillsSHA256: nil,
                    activeSkillsSHA256: nil,
                    expectedContentSHA256: nil,
                    managedSourceContentSHA256: nil,
                    activeContentSHA256: nil,
                    detail: "not managed",
                    error: nil
                )
            }
        )
    }

    private func managedStaticResult(
        source: AgentSource,
        expectedVersion: String?,
        activeVersion: String?
    ) -> ProductConnectorRefreshResult {
        ProductConnectorRefreshResult(
            source: source,
            status: .current,
            managed: true,
            refreshed: true,
            ok: true,
            verified: true,
            expectedVersion: expectedVersion,
            activeVersion: activeVersion,
            expectedSkillsSHA256: nil,
            activeSkillsSHA256: nil,
            expectedContentSHA256: nil,
            managedSourceContentSHA256: nil,
            activeContentSHA256: nil,
            detail: "current",
            error: nil
        )
    }

    private func incompleteCodexReport() -> ProductConnectorRefreshReport {
        var results = completeReport().results
        results[0] = ProductConnectorRefreshResult(
            source: .codex,
            status: .conflict,
            managed: true,
            refreshed: false,
            ok: false,
            verified: false,
            expectedVersion: "0.3.0",
            activeVersion: "0.2.0",
            expectedSkillsSHA256: String(repeating: "a", count: 64),
            activeSkillsSHA256: nil,
            expectedContentSHA256: String(repeating: "b", count: 64),
            managedSourceContentSHA256: nil,
            activeContentSHA256: nil,
            detail: "conflict",
            error: "conflict"
        )
        return ProductConnectorRefreshReport(ok: false, results: results)
    }

    private func healthyManagedCodexStatus() -> AgentConnectionStatus {
        AgentConnectionStatus(
            source: .codex,
            items: ["Plugin", "Studio", "Maker"].map {
                ConnectionCheckItem(
                    code: .managedConnector,
                    name: $0,
                    status: .ok,
                    detail: "v0.5.3 · 正常"
                )
            },
            installPaths: ["/managed/codex"],
            connectorInstalled: true,
            checkMode: .runtime,
            checkedAt: "2026-08-07T12:00:00Z",
            verification: AgentVerification(
                status: .verified,
                title: "Codex",
                detail: "verified"
            ),
            capabilities: AgentConnectorCapabilities(
                contractVersion: "codex-hooks.v0.5.3",
                subscribedEvents: [],
                mappedInformation: [],
                privacyExclusions: [],
                repairableConnectorIssue: false,
                canRepairManagedConnector: true,
                managedPathConflict: false,
                canUninstallManagedConnector: true
            )
        )
    }

    private func convergenceReceipt(
        manifest: RuntimeReleaseManifest,
        report: ProductConnectorRefreshReport
    ) -> ProductConvergenceReceipt {
        let codex = report.results.first(where: { $0.source == .codex })
        return ProductConvergenceReceipt(
            schemaVersion: ProductConvergenceReceipt.schemaVersion,
            buildID: manifest.buildID,
            appVersion: manifest.appVersion,
            completedAt: "2026-07-24T12:00:00.123456Z",
            connectorReportSummary: ProductConvergenceReceiptSummary(
                totalSources: UInt(report.results.count),
                managedSources: UInt(report.results.filter(\.managed).count),
                verifiedSources: UInt(report.results.filter(\.verified).count),
                skippedSources: UInt(report.results.filter {
                    !$0.managed && $0.status == .skippedNotManaged
                }.count),
                reportSHA256: String(repeating: "c", count: 64),
                codexSkillsSHA256: codex?.managed == true
                    ? codex?.activeSkillsSHA256
                    : nil,
                codexContentSHA256: codex?.managed == true
                    ? codex?.activeContentSHA256
                    : nil
            )
        )
    }

    private func runtimeManifest(
        buildID: String,
        appVersion: String = "0.3.0",
        releaseChannel: String = "develop"
    ) -> RuntimeReleaseManifest {
        RuntimeReleaseManifest(
            schemaVersion: RuntimeReleaseManifest.schemaVersion,
            releaseChannel: releaseChannel,
            appVersion: appVersion,
            appBuild: "1",
            buildID: buildID,
            petCoreRPCProtocol: PetCoreRuntimeContract.requiredRPCProtocol,
            petCoreBuildID: buildID,
            petCoreCLIBuildID: buildID,
            minimumDatabaseSchemaVersion: 1,
            maximumDatabaseSchemaVersion: 6,
            agentEventSchemaVersion: "apc.agent-event.v1",
            petpackSchemaVersion: "apc.petpack.v3",
            petpackReadVersions: ["apc.petpack.v3"],
            petpackWriteVersion: "apc.petpack.v3",
            connectorContracts: RuntimeConnectorContracts(
                codex: "codex-hooks.v1",
                claudeCode: "claude-hooks.v1",
                pi: "pi-extension.v1",
                opencode: "opencode-plugin.v1"
            )
        )
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}

private enum ProductConvergenceTestError: Error {
    case unexpectedMethod(String)
    case snapshotUnavailable
}

private actor ProductConvergenceRequestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard continuations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
