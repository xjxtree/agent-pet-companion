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
        #expect(APCLocalization.resolvedInterfaceLocaleIdentifier(
            interfaceLanguage: .english,
            preferredLanguages: ["zh-Hans"]
        ) == "en")
        #expect(APCLocalization.resolvedInterfaceLocaleIdentifier(
            interfaceLanguage: .simplifiedChinese,
            preferredLanguages: ["en-US"]
        ) == "zh-Hans")
        #expect(APCLocalization.resolvedInterfaceLocaleIdentifier(
            interfaceLanguage: .system,
            preferredLanguages: ["zh-CN"]
        ) == "zh-Hans")
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
        #expect(APCLocalization.text(.libraryAnimationActionPicker, locale: "en")
            == "Preview action")
        #expect(APCLocalization.text(.libraryAnimationActionPicker, locale: "zh-Hans")
            == "预览动作")
        #expect(APCLocalization.format(
            .libraryAnimationAccessibilityFormat,
            locale: "en",
            "Bytebud",
            "Thinking"
        ) == "Bytebud — Thinking action preview")
        #expect(APCLocalization.format(
            .libraryAnimationAccessibilityFormat,
            locale: "zh-Hans",
            "字节芽",
            "正在思考"
        ) == "字节芽——“正在思考”动作预览")
        #expect(APCLocalization.text(.appActionFocusPetSessions, locale: "en")
            == "Focus Pet Sessions")
        #expect(APCLocalization.text(.appActionFocusPetSessions, locale: "zh-Hans")
            == "聚焦桌宠会话")
        #expect(APCLocalization.text(.configDisplayWidthAccessibility, locale: "en")
            == "Pet size")
        #expect(APCLocalization.text(.configDisplayWidthAccessibility, locale: "zh-Hans")
            == "宠物大小")
        #expect(APCLocalization.text(
            .overlaySessionNavigationFailed,
            locale: "en"
        ).contains("message was kept"))
        #expect(APCLocalization.text(
            .overlaySessionNavigationFailed,
            locale: "zh-Hans"
        ).contains("消息已保留"))
        #expect(APCLocalization.text(
            .overlaySessionNavigationDegraded,
            locale: "en"
        ).contains("exact session"))
        #expect(APCLocalization.text(
            .overlaySessionNavigationDegraded,
            locale: "zh-Hans"
        ).contains("对应会话"))
        #expect(APCLocalizedPresentation.interfaceLanguageTitle(
            .system,
            locale: "en"
        ) == "Follow System")
        #expect(APCLocalizedPresentation.interfaceLanguageTitle(
            .english,
            locale: "zh-Hans"
        ) == "English")
        #expect(APCLocalizedPresentation.interfaceLanguageTitle(
            .simplifiedChinese,
            locale: "en"
        ) == "简体中文")
    }

    @Test
    func typedPresentationLocalizesLabelsWithoutTranslatingProtocolNames() {
        #expect(APCLocalizedPresentation.eventTitle(.tool, locale: "en") == "Using Tools")
        #expect(APCLocalizedPresentation.eventTitle(.tool, locale: "zh-Hans") == "正在调用工具")
        #expect(APCLocalizedPresentation.styleTitle(.semiRealistic, locale: "en") == "Semi-realistic")
        #expect(APCLocalizedPresentation.qualityTitle(.standard, locale: "zh-Hans") == "标准")

        let contract = APCLocalization.text(.studioOutputContractDetail, locale: "en")
        for protocolState in ["idle", "thinking", "tool", "waiting", "done", "failed"] {
            #expect(contract.contains(protocolState))
        }
    }

    @Test
    func sessionEventLabelsRemainDistinctFromSparsePetActions() {
        for locale in ["en", "zh-Hans"] {
            #expect(
                APCLocalizedPresentation.eventTitle(.start, locale: locale)
                    != APCLocalizedPresentation.lifecycleTitle(
                        ProductLifecycleState(eventKind: .start),
                        locale: locale
                    )
            )
            #expect(
                APCLocalizedPresentation.eventTitle(.thinking, locale: locale)
                    == APCLocalizedPresentation.lifecycleTitle(.thinking, locale: locale)
            )
            #expect(
                APCLocalizedPresentation.eventTitle(.plan, locale: locale)
                    != APCLocalizedPresentation.lifecycleTitle(.thinking, locale: locale)
            )
        }
    }

    @Test
    func responseEventDetailsExplainTheUnifiedLifecycleMeaning() {
        let expectedEnglish: [(APCLocalizationKey, String)] = [
            (.configEventStartDetail, "The request was accepted; this event does not trigger a pet action"),
            (.configEventThinkingDetail, "The host explicitly reported stable reasoning activity; the pet uses its Thinking action"),
            (.configEventPlanDetail, "The Agent updated its plan; the pet uses its Thinking action"),
            (.configEventToolDetail, "Agent is using a local tool"),
            (.configEventWaitingDetail, "The Agent is paused until you approve, answer, or decide"),
            (.configEventDoneDetail, "The task is complete"),
            (.configEventFailedDetail, "The task failed"),
        ]
        let expectedChinese: [(APCLocalizationKey, String)] = [
            (.configEventStartDetail, "Agent 已接收请求；开始事件不触发宠物动作"),
            (.configEventThinkingDetail, "宿主明确上报了稳定的思考或推理活动；宠物使用“思考”动作"),
            (.configEventPlanDetail, "Agent 更新了规划；宠物使用“思考”动作"),
            (.configEventToolDetail, "Agent 正在调用本地工具"),
            (.configEventWaitingDetail, "Agent 已暂停，必须等你确认、回答或决策后才能继续"),
            (.configEventDoneDetail, "任务已完成"),
            (.configEventFailedDetail, "任务执行失败"),
        ]

        for (key, expected) in expectedEnglish {
            #expect(APCLocalization.text(key, locale: "en") == expected)
        }
        for (key, expected) in expectedChinese {
            #expect(APCLocalization.text(key, locale: "zh-Hans") == expected)
        }
    }

    @Test
    func persistentResponseCopyUsesTheUnifiedAttentionLabels() {
        #expect(
            APCLocalization.text(.configPersistenceNote, locale: "en")
                == "Waiting for You and Failed sessions remain visible regardless of the normal message timeout."
        )
        #expect(
            APCLocalization.text(.configPersistencePreview, locale: "en")
                == "Waiting for You and Failed remain visible until the event changes or you dismiss the session."
        )
        #expect(
            APCLocalization.text(.configPersistenceNote, locale: "zh-Hans")
                == "“等待你操作”和“执行失败”的会话始终保持显示，不受普通消息收起时间影响。"
        )
        #expect(
            APCLocalization.text(.configPersistencePreview, locale: "zh-Hans")
                == "“等待你操作”和“执行失败”会持续显示，直到事件变化或你关闭该会话。"
        )
    }

    @Test
    func productPresentationHasExplicitBilingualMeaningAndActions() {
        #expect(APCLocalizedPresentation.lifecycleTitle(.waiting, locale: "en") == "Waiting for You")
        #expect(APCLocalizedPresentation.lifecycleTitle(.done, locale: "zh-Hans") == "已完成")

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
        #expect(APCLocalizedPresentation.sessionSurfaceTitle(
            .app,
            locale: "en"
        ) == "App")
        #expect(APCLocalizedPresentation.sessionSurfaceTitle(
            .cli,
            locale: "zh-Hans"
        ) == "CLI")

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
        #expect(APCLocalizedPresentation.qualityTitle(.low, locale: "en") == "Low")
        #expect(APCLocalizedPresentation.qualityTitle(.standard, locale: "zh-Hans") == "标准")
        #expect(APCLocalizedPresentation.qualityTitle(.standard, locale: "en") == "Standard")
        #expect(APCLocalizedPresentation.qualityTitle(.high, locale: "en") == "High")
        #expect(APCLocalizedPresentation.qualityTitle(.high, locale: "zh-Hans") == "高清")

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
            .thinking: "Thinking",
            .tool: "Using Tools",
            .waiting: "Waiting for You",
            .done: "Completed",
            .failed: "Failed",
        ]
        let lifecycleChinese: [ProductLifecycleState: String] = [
            .idle: "正在休息",
            .thinking: "正在思考",
            .tool: "正在调用工具",
            .waiting: "等待你操作",
            .done: "已完成",
            .failed: "执行失败",
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
            .notChecked: "Not Checked",
            .checking: "Checking",
            .connected: "Connected",
            .needsRepair: "Needs Repair",
            .unavailable: "Unavailable",
        ]
        let healthChinese: [AgentConnectionHealthState: String] = [
            .notChecked: "未检查",
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
            animationTiming: nil,
            localeIdentifier: "en"
        )
        let chinese = ServiceDiagnosticsPresentation(
            runtimeInfo: runtime,
            serviceStatusText: "忽略全局状态",
            recentEventSummary: nil,
            desktopPetEnabled: false,
            desktopPetVisible: false,
            activePetName: nil,
            animationTiming: nil,
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
