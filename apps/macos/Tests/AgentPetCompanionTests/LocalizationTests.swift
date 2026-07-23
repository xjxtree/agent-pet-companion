import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Localization")
struct LocalizationTests {
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
    func productPresentationHasExplicitBilingualMeaningAndActions() {
        #expect(APCLocalizedPresentation.lifecycleTitle(.waiting, locale: "en") == "Needs You")
        #expect(APCLocalizedPresentation.lifecycleTitle(.review, locale: "zh-Hans") == "可以查看")

        #expect(APCLocalizedPresentation.navigationActionTitle(
            .exactSession,
            source: .codex,
            locale: "en"
        ) == "Return to Session")
        #expect(APCLocalizedPresentation.navigationActionTitle(
            .agentHost,
            source: .codex,
            locale: "zh-Hans"
        ) == "打开 Codex")
        #expect(APCLocalizedPresentation.navigationActionTitle(
            .unavailable,
            source: .codex,
            locale: "en"
        ) == nil)
        #expect(APCLocalizedPresentation.navigationUnavailableTitle(
            locale: "en"
        ) == "No safe destination is available")

        for preset in AttentionPreset.allCases {
            #expect(!APCLocalizedPresentation.attentionPresetTitle(
                preset,
                locale: "en"
            ).isEmpty)
            #expect(!APCLocalizedPresentation.attentionPresetTitle(
                preset,
                locale: "zh-Hans"
            ).isEmpty)
        }
        #expect(APCLocalizedPresentation.playbackProfileTitle(
            .standard,
            locale: "en"
        ) == "Standard Motion")
        #expect(APCLocalizedPresentation.playbackProfileTitle(
            .smooth,
            locale: "zh-Hans"
        ) == "流畅动效")

        for health in AgentConnectionHealthState.allCases {
            #expect(!APCLocalizedPresentation.connectionHealthTitle(
                health,
                locale: "en"
            ).isEmpty)
            #expect(!APCLocalizedPresentation.connectionHealthTitle(
                health,
                locale: "zh-Hans"
            ).isEmpty)
        }

        #expect(APCLocalizedPresentation.primaryActionTitle(
            PetLibraryPrimaryAction.usePet,
            locale: "en"
        ) == "Use This Pet")
        #expect(APCLocalizedPresentation.primaryActionTitle(
            PetMakerPrimaryAction.continueEditing,
            locale: "zh-Hans"
        ) == "继续修改")
        #expect(APCLocalizedPresentation.primaryActionTitle(
            AgentConnectionPrimaryAction.connect,
            locale: "en"
        ) == "Connect")
        #expect(APCLocalizedPresentation.primaryActionTitle(
            ServiceDiagnosticsPrimaryAction.recover,
            locale: "zh-Hans"
        ) == "恢复服务")
    }

    @Test
    func everyProductPresentationCaseHasAnExplicitBilingualMapping() {
        let lifecycleEnglish: [ProductLifecycleState: String] = [
            .idle: "Resting",
            .start: "Thinking",
            .tool: "Working",
            .waiting: "Needs You",
            .review: "Ready to Review",
            .done: "Completed",
            .failed: "Needs Attention",
        ]
        let lifecycleChinese: [ProductLifecycleState: String] = [
            .idle: "正在休息",
            .start: "正在思考",
            .tool: "正在工作",
            .waiting: "等你处理",
            .review: "可以查看",
            .done: "已完成",
            .failed: "需要处理",
        ]
        for state in ProductLifecycleState.allCases {
            #expect(APCLocalizedPresentation.lifecycleTitle(
                state,
                locale: "en"
            ) == lifecycleEnglish[state])
            #expect(APCLocalizedPresentation.lifecycleTitle(
                state,
                locale: "zh-Hans"
            ) == lifecycleChinese[state])
        }

        let attentionEnglish: [AttentionPreset: String] = [
            .onlyWhenNeeded: "Only When I Am Needed",
            .standard: "Standard",
            .allActivity: "All Activity",
            .custom: "Custom",
        ]
        let attentionChinese: [AttentionPreset: String] = [
            .onlyWhenNeeded: "只在需要我时",
            .standard: "标准",
            .allActivity: "全部活动",
            .custom: "自定义",
        ]
        for preset in AttentionPreset.allCases {
            #expect(APCLocalizedPresentation.attentionPresetTitle(
                preset,
                locale: "en"
            ) == attentionEnglish[preset])
            #expect(APCLocalizedPresentation.attentionPresetTitle(
                preset,
                locale: "zh-Hans"
            ) == attentionChinese[preset])
        }

        let healthEnglish: [AgentConnectionHealthState: String] = [
            .checking: "Checking",
            .connected: "Connected",
            .needsRepair: "Needs Repair",
            .unavailable: "Unavailable",
        ]
        let healthChinese: [AgentConnectionHealthState: String] = [
            .checking: "正在检查",
            .connected: "已连接",
            .needsRepair: "需要修复",
            .unavailable: "不可用",
        ]
        for health in AgentConnectionHealthState.allCases {
            #expect(APCLocalizedPresentation.connectionHealthTitle(
                health,
                locale: "en"
            ) == healthEnglish[health])
            #expect(APCLocalizedPresentation.connectionHealthTitle(
                health,
                locale: "zh-Hans"
            ) == healthChinese[health])
        }

        for action in [
            PetLibraryPrimaryAction.usePet,
            .createPet,
            .importPet,
        ] {
            #expect(APCLocalizedPresentation.primaryActionTitle(action, locale: "en") != nil)
            #expect(APCLocalizedPresentation.primaryActionTitle(action, locale: "zh-Hans") != nil)
        }
        #expect(APCLocalizedPresentation.primaryActionTitle(
            PetLibraryPrimaryAction.unavailable,
            locale: "en"
        ) == nil)

        for action in [
            PetMakerPrimaryAction.createPet,
            .sendReply,
            .cancel,
            .retry,
            .reselectReferences,
            .usePet,
            .continueEditing,
        ] {
            #expect(APCLocalizedPresentation.primaryActionTitle(action, locale: "en") != nil)
            #expect(APCLocalizedPresentation.primaryActionTitle(action, locale: "zh-Hans") != nil)
        }
        #expect(APCLocalizedPresentation.primaryActionTitle(
            PetMakerPrimaryAction.unavailable,
            locale: "en"
        ) == nil)

        for action in [
            AgentConnectionPrimaryAction.connect,
            .repair,
            .verify,
            .retry,
        ] {
            #expect(APCLocalizedPresentation.primaryActionTitle(action, locale: "en") != nil)
            #expect(APCLocalizedPresentation.primaryActionTitle(action, locale: "zh-Hans") != nil)
        }
        #expect(APCLocalizedPresentation.primaryActionTitle(
            AgentConnectionPrimaryAction.unavailable,
            locale: "en"
        ) == nil)

        for action in [
            ServiceDiagnosticsPrimaryAction.refresh,
            .recover,
            .retry,
        ] {
            #expect(APCLocalizedPresentation.primaryActionTitle(action, locale: "en") != nil)
            #expect(APCLocalizedPresentation.primaryActionTitle(action, locale: "zh-Hans") != nil)
        }
        #expect(APCLocalizedPresentation.primaryActionTitle(
            ServiceDiagnosticsPrimaryAction.unavailable,
            locale: "en"
        ) == nil)
    }

    @Test
    func diagnosticsPresentationHasExplicitEnglishAndChinesePaths() throws {
        var runtime = PetCoreRuntimeInfo.initial(manifest: nil)
        runtime.phase = .running
        runtime.version = "1.2.3"
        runtime.rpcProtocol = "v2"
        runtime.databaseSchemaRange = "0–6"

        let english = ServiceDiagnosticsPresentation(
            runtimeInfo: runtime,
            serviceStatusText: "ignored global status",
            recentEventSummary: nil,
            desktopPetEnabled: false,
            desktopPetVisible: false,
            activePetName: nil,
            framesPerSecond: 10,
            localeIdentifier: "en"
        )
        let chinese = ServiceDiagnosticsPresentation(
            runtimeInfo: runtime,
            serviceStatusText: "忽略全局状态",
            recentEventSummary: nil,
            desktopPetEnabled: false,
            desktopPetVisible: false,
            activePetName: nil,
            framesPerSecond: 10,
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
