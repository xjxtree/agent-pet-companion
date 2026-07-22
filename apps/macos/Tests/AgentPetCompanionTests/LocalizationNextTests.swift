import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("UI Next localization")
struct LocalizationNextTests {
    @Test
    func preferredLanguageResolutionSupportsEnglishAndSimplifiedChinese() {
        #expect(APCLocalization.resolvedInterfaceLocaleIdentifier(
            preferredLanguages: ["zh-Hans-SG", "en-US"]
        ) == "zh-Hans")
        #expect(APCLocalization.resolvedInterfaceLocaleIdentifier(
            preferredLanguages: ["zh-CN"]
        ) == "zh-Hans")
        #expect(APCLocalization.resolvedInterfaceLocaleIdentifier(
            preferredLanguages: ["en-GB", "zh-Hans"]
        ) == "en")
        #expect(APCLocalization.resolvedInterfaceLocaleIdentifier(
            preferredLanguages: ["fr-FR"]
        ) == "en")
        #expect(APCLocalization.resolvedInterfaceLocaleIdentifier(
            preferredLanguages: []
        ) == "en")
    }

    @Test
    func explicitLocalePathLocalizesStaticAndFormattedCopy() {
        #expect(APCLocalization.text(.navigationLibrary, locale: "en-US") == "Pet Library")
        #expect(APCLocalization.text(.navigationLibrary, locale: "zh-Hans-CN") == "宠物库")
        #expect(APCLocalization.format(
            .libraryDeleteActionFormat,
            locale: "en",
            "Bytebud"
        ) == "Delete Bytebud")
        #expect(APCLocalization.format(
            .libraryDeleteActionFormat,
            locale: "zh-Hans",
            "Bytebud"
        ) == "删除 Bytebud")
        #expect(APCLocalization.text(.appActionFocusPetSessions, locale: "en")
            == "Focus Pet Sessions")
        #expect(APCLocalization.text(.appActionFocusPetSessions, locale: "zh-Hans")
            == "聚焦桌宠会话")
        #expect(APCLocalization.text(.appActionFocusPetResize, locale: "en")
            == "Focus Pet Resize Handle")
    }

    @Test
    func scopedFixtureLocaleDrivesTheSameImplicitLocalizationPathAsProductionViews() {
        let english = APCLocalizationFixtureScope.withLocale("en") {
            (
                APCLocalization.interfaceLocaleIdentifier,
                APCLocalization.text(.navigationLibrary),
                APCLocalization.format(.libraryDeleteActionFormat, "Bytebud")
            )
        }
        let chinese = APCLocalizationFixtureScope.withLocale("zh-Hans") {
            (
                APCLocalization.interfaceLocaleIdentifier,
                APCLocalization.text(.navigationLibrary),
                APCLocalization.format(.libraryDeleteActionFormat, "Bytebud")
            )
        }

        #expect(english.0 == "en")
        #expect(english.1 == "Pet Library")
        #expect(english.2 == "Delete Bytebud")
        #expect(chinese.0 == "zh-Hans")
        #expect(chinese.1 == "宠物库")
        #expect(chinese.2 == "删除 Bytebud")
        #expect(english.1 != chinese.1)
    }

    @Test
    func scopedFixtureLocaleIsNestedAndTaskLocalWithoutLeakingToTheCaller() async {
        let systemLocale = APCLocalization.interfaceLocaleIdentifier
        let values = await APCLocalizationFixtureScope.withLocale("en-US") {
            let outerBefore = APCLocalization.interfaceLocaleIdentifier
            let inner = await APCLocalizationFixtureScope.withLocale("zh-CN") {
                await Task.yield()
                return APCLocalization.interfaceLocaleIdentifier
            }
            return (outerBefore, inner, APCLocalization.interfaceLocaleIdentifier)
        }

        #expect(values.0 == "en")
        #expect(values.1 == "zh-Hans")
        #expect(values.2 == "en")
        #expect(APCLocalization.interfaceLocaleIdentifier == systemLocale)
    }

    @Test
    func typedPresentationLocalizesLabelsWithoutTranslatingProtocolNames() {
        #expect(APCLocalizedPresentation.eventTitle(.tool, locale: "en") == "Using a tool")
        #expect(APCLocalizedPresentation.eventTitle(.tool, locale: "zh-Hans") == "执行工具")
        #expect(APCLocalizedPresentation.styleTitle(.semiRealistic, locale: "en") == "Semi-realistic")
        #expect(APCLocalizedPresentation.qualityTitle(.high, locale: "zh-Hans") == "高清")

        let contract = APCLocalization.text(.studioOutputContractDetail, locale: "en")
        for protocolState in ["idle", "start", "tool", "waiting", "review", "done", "failed"] {
            #expect(contract.contains(protocolState))
        }
    }

    @Test
    func diagnosticsPresentationHasExplicitEnglishAndChinesePaths() throws {
        var runtime = PetCoreRuntimeInfo.initial(manifest: nil)
        runtime.phase = .running
        runtime.version = "1.2.3"
        runtime.rpcProtocol = "v2"
        runtime.databaseSchemaRange = "0–5"

        let english = ServiceDiagnosticsPresentation(
            runtimeInfo: runtime,
            serviceStatusText: "ignored global status",
            recentEventSummary: nil,
            desktopPetEnabled: false,
            desktopPetVisible: false,
            activePetName: nil,
            framesPerSecond: 12,
            localeIdentifier: "en"
        )
        let chinese = ServiceDiagnosticsPresentation(
            runtimeInfo: runtime,
            serviceStatusText: "忽略全局状态",
            recentEventSummary: nil,
            desktopPetEnabled: false,
            desktopPetVisible: false,
            activePetName: nil,
            framesPerSecond: 12,
            localeIdentifier: "zh-Hans"
        )

        #expect(try #require(english.row(.localRPC)).title == "Local RPC")
        #expect(try #require(chinese.row(.localRPC)).title == "本地 RPC")
        #expect(ServiceDiagnosticsPresentation.toolbar(
            runtimeInfo: runtime,
            localeIdentifier: "en"
        ).title == "Service healthy")
        #expect(ServiceDiagnosticsPresentation.toolbar(
            runtimeInfo: runtime,
            localeIdentifier: "zh-Hans"
        ).title == "服务正常")
    }

    @Test
    func typedExportDisplayDoesNotExposeLocalizedGlobalStatusPayloads() {
        #expect(DiagnosticsExportState.succeeded("已导出 archive.zip").displayMessage(locale: "en")
            == "Diagnostic archive exported.")
        #expect(DiagnosticsExportState.failed("日志导出失败").displayMessage(locale: "en")
            == "Diagnostic export failed. Try again.")
    }
}
