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
        #expect(DiagnosticsExportState.exporting.message == "正在打包诊断日志")
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
            framesPerSecond: 12,
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
    func healthyStatusRefreshesWhileFailuresOfferRecovery() {
        #expect(ServiceDiagnosticsPrimaryAction.resolve(for: .online) == .refresh)
        #expect(ServiceDiagnosticsPrimaryAction.resolve(for: .checking) == .refresh)
        #expect(ServiceDiagnosticsPrimaryAction.resolve(for: .offline) == .recover)
        #expect(ServiceDiagnosticsPrimaryAction.resolve(for: .runtimeMismatch) == .recover)
        #expect(ServiceDiagnosticsPrimaryAction.resolve(for: .error) == .recover)
    }
}
