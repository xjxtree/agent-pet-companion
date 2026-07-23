import AgentPetCompanionCore
import Foundation
import Testing
@testable import AgentPetCompanion

@Suite
struct ServiceDiagnosticsTests {
    @Test
    func diagnosticPackageScopeMatchesTheFourteenDayRetentionContract() {
        #expect(
            APCLocalization.text(.diagnosticsMetadataBounded14Days, locale: "en")
                == "Bounded logs, up to 14 days"
        )
        #expect(
            APCLocalization.text(.diagnosticsMetadataBounded14Days, locale: "zh-Hans")
                == "有界日志，最长 14 天"
        )
    }

    @Test
    func exportStateDoesNotInferStatusFromLocalizedGlobalText() {
        #expect(DiagnosticsExportState.idle.message == nil)
        #expect(
            DiagnosticsExportState.exporting.message
                == APCLocalization.text(.diagnosticsExportingMessage)
        )
        #expect(DiagnosticsExportState.succeeded("archive.zip").message == "archive.zip")
        #expect(DiagnosticsExportState.failed("retry").message == "retry")
    }

    @Test
    func diagnosticArchiveMustBeReadyBeforeThePrimaryActionCanSaveIt() {
        let archive = PreparedDiagnosticsArchive(
            stagedURL: URL(fileURLWithPath: "/private/tmp/diagnostics.zip"),
            suggestedFileName: "AgentPetCompanion-Diagnostics.zip"
        )

        #expect(DiagnosticsExportState.idle.primaryAction == .prepare)
        #expect(DiagnosticsExportState.exporting.primaryAction == nil)
        #expect(DiagnosticsExportState.ready(archive).primaryAction == .save)
        #expect(DiagnosticsExportState.saving(archive).primaryAction == nil)
        #expect(DiagnosticsExportState.saveFailed(archive, "retry").primaryAction == .save)
        #expect(
            DiagnosticsExportState.ready(archive).displayMessage(locale: "en")
                == "Diagnostic Archive · Ready"
        )
    }

    @Test(arguments: [
        (PetCoreOperationalState.recovering, "恢复中", "正在等待本地 RPC 端点恢复"),
        (PetCoreOperationalState.offline, "离线", "本地 RPC 端点已离线"),
        (PetCoreOperationalState.runtimeMismatch, "不匹配", "RPC 协议或数据库兼容性与当前 App 不匹配"),
        (PetCoreOperationalState.error, "异常", "PetCore 当前不可连接")
    ])
    func serviceRowsExposeOperationalStateInTextAndDetail(
        state: PetCoreOperationalState,
        expectedStatus: String,
        expectedRPCDetail: String
    ) throws {
        let presentation = ServiceDiagnosticsPresentation(
            operationalState: state,
            runtimeInfo: .initial(manifest: nil),
            recentEventSummary: nil,
            desktopPetEnabled: true,
            desktopPetVisible: true,
            activePetName: "Bytebud 字节芽",
            framesPerSecond: 10,
            localeIdentifier: "zh-Hans"
        )

        let rpc = try #require(presentation.row(.localRPC))
        #expect(rpc.status == expectedStatus)
        #expect(rpc.detail == expectedRPCDetail)
        #expect(try #require(presentation.row(.eventChannel)).status == expectedStatus)
    }

    @Test
    func toolbarDistinguishesEveryOperationalFailureClassInBothLocales() {
        let runtime = PetCoreRuntimeInfo.initial(manifest: nil)

        #expect(ServiceDiagnosticsPresentation.toolbar(
            operationalState: .recovering,
            runtimeInfo: runtime,
            localeIdentifier: "en"
        ).title == "Recovering service")
        #expect(ServiceDiagnosticsPresentation.toolbar(
            operationalState: .offline,
            runtimeInfo: runtime,
            localeIdentifier: "zh-Hans"
        ).title == "服务离线")
        #expect(ServiceDiagnosticsPresentation.toolbar(
            operationalState: .runtimeMismatch,
            runtimeInfo: runtime,
            localeIdentifier: "en"
        ).title == "Compatibility issue")
        #expect(ServiceDiagnosticsPresentation.toolbar(
            operationalState: .error,
            runtimeInfo: runtime,
            localeIdentifier: "zh-Hans"
        ).title == "服务异常")
    }

    @Test
    func failureCodesMapToStableOperationalStates() {
        #expect(PetCoreOperationalState.failure(for: .candidateHealthFailed) == .runtimeMismatch)
        #expect(PetCoreOperationalState.failure(for: .petCoreBinaryMissing) == .offline)
        #expect(PetCoreOperationalState.failure(for: .directLaunchFailed) == .offline)
        #expect(PetCoreOperationalState.failure(for: .runtimePathsFailed) == .error)
        #expect(PetCoreOperationalState.failure(for: .unknown) == .error)
    }

    @Test
    func aggregateStatusOffersOneTruthfulContextualAction() {
        #expect(ServiceDiagnosticsPrimaryAction.resolve(for: .online) == .refresh)
        #expect(ServiceDiagnosticsPrimaryAction.resolve(for: .checking) == .unavailable)
        #expect(ServiceDiagnosticsPrimaryAction.resolve(for: .recovering) == .unavailable)
        #expect(ServiceDiagnosticsPrimaryAction.resolve(for: .offline) == .recover)
        #expect(ServiceDiagnosticsPrimaryAction.resolve(for: .runtimeMismatch) == .recover)
        #expect(ServiceDiagnosticsPrimaryAction.resolve(for: .error) == .retry)
    }

    @Test(arguments: [
        (PetCoreOperationalState.online, ServiceDiagnosticsHealthState.healthy, "Service healthy", "The desktop pet can receive Agent updates normally.", ServiceDiagnosticsPrimaryAction.refresh),
        (PetCoreOperationalState.checking, ServiceDiagnosticsHealthState.checking, "Checking service", "Checking the services needed by the desktop pet.", ServiceDiagnosticsPrimaryAction.unavailable),
        (PetCoreOperationalState.recovering, ServiceDiagnosticsHealthState.checking, "Recovering service", "Restoring the services needed by the desktop pet.", ServiceDiagnosticsPrimaryAction.unavailable),
        (PetCoreOperationalState.offline, ServiceDiagnosticsHealthState.needsRecovery, "Service offline", "The desktop pet cannot receive Agent updates. Recover the service to continue.", ServiceDiagnosticsPrimaryAction.recover),
        (PetCoreOperationalState.runtimeMismatch, ServiceDiagnosticsHealthState.needsRecovery, "Compatibility issue", "The App and its local service need compatible versions before Agent updates can resume.", ServiceDiagnosticsPrimaryAction.recover),
        (PetCoreOperationalState.error, ServiceDiagnosticsHealthState.unavailable, "Service issue", "The local service could not be reached. Retry the connection.", ServiceDiagnosticsPrimaryAction.retry),
    ])
    func aggregatePresentationCoversEveryOperationalState(
        state: PetCoreOperationalState,
        health: ServiceDiagnosticsHealthState,
        title: String,
        summary: String,
        action: ServiceDiagnosticsPrimaryAction
    ) {
        let presentation = ServiceDiagnosticsAggregatePresentation(
            operationalState: state,
            localeIdentifier: "en"
        )

        #expect(presentation.health == health)
        #expect(presentation.status.title == title)
        #expect(presentation.summary == summary)
        #expect(presentation.primaryAction?.action ?? .unavailable == action)
    }

    @Test
    func exportStateRemainsIndependentFromServiceRecoveryState() {
        let service = ServiceDiagnosticsAggregatePresentation(
            operationalState: .offline,
            localeIdentifier: "en"
        )
        let archive = PreparedDiagnosticsArchive(
            stagedURL: URL(fileURLWithPath: "/private/tmp/diagnostics.zip"),
            suggestedFileName: "AgentPetCompanion-Diagnostics.zip"
        )

        #expect(service.primaryAction?.action == .recover)
        #expect(DiagnosticsExportState.ready(archive).primaryAction == .save)
        #expect(DiagnosticsExportState.failed("retry").primaryAction == .prepare)
    }
}
