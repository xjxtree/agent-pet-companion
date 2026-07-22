import AgentPetCompanionCore
import Foundation

precondition(NavigationSection.allCases == [
    .library,
    .maker,
    .configuration,
    .connections,
    .diagnostics,
])
precondition(NavigationSection.allCases.map(\.title) == [
    "宠物库",
    "AI宠物制作",
    "宠物配置",
    "Agent 连接",
    "服务与诊断",
])
precondition(NavigationSection.allCases.map(\.subtitle) == [
    "Pet Library",
    "AI Pet Maker",
    "Pet Configuration",
    "Agent Connections",
    "Service & Diagnostics",
])

precondition(AgentSource.allCases == [.codex, .claudeCode, .pi, .opencode])
precondition(AgentSource.allCases.map(\.title) == ["Codex", "Claude Code", "Pi Coding Agent", "OpenCode"])

precondition(AgentEventKind.allCases == [.start, .tool, .waiting, .review, .done, .failed])
precondition(AgentEventKind.allCases.map(\.title) == ["开始处理", "执行工具", "等待确认", "待查看", "完成", "失败"])
precondition(AgentEventKind.allCases.map(\.petState) == ["start", "tool", "waiting", "review", "done", "failed"])
precondition(SessionGroupDisplay.allCases == [.stacked, .expanded])
precondition(SessionGroupDisplay.allCases.map(\.title) == ["堆叠", "展开"])

let scheduler = FrameScheduler(fps: 12, frameCount: 24)
precondition(scheduler.frameIndex(elapsedSeconds: 0) == 0)
precondition(scheduler.frameIndex(elapsedSeconds: 0.09) == 1)
precondition(scheduler.frameIndex(elapsedSeconds: 2.0) == 0)

let oneShotScheduler = FrameScheduler(fps: 12, frameCount: 4, loops: false)
precondition(oneShotScheduler.frameIndex(elapsedSeconds: 0) == 0)
precondition(oneShotScheduler.frameIndex(elapsedSeconds: 10) == 3)
precondition(oneShotScheduler.hasCompleted(elapsedSeconds: 10))
var oneShotPlayback = FramePlaybackState(stateID: "start", enteredAt: 10)
precondition(oneShotPlayback.frameIndex(at: 10.25, scheduler: oneShotScheduler) == 3)
oneShotPlayback.enter(stateID: "done", at: 11)
precondition(oneShotPlayback.frameIndex(at: 11, scheduler: oneShotScheduler) == 0)

let highStandard = RendererBudget(quality: .high, fpsProfile: .standard)
precondition(highStandard.rendererBudgetMB == 180)
precondition(highStandard.usesRingCache == false)

let originalSmooth = RendererBudget(quality: .original, fpsProfile: .smooth)
precondition(originalSmooth.rendererBudgetMB == 420)
precondition(originalSmooth.usesRingCache)
precondition(originalSmooth.decodedStateMB > 380)

let settings = BehaviorSettings()
precondition(settings.enabled)
precondition(settings.sources.count == AgentSource.allCases.count)
precondition(settings.events.count == AgentEventKind.allCases.count)
precondition(settings.fpsProfile.fps == 12)
precondition(settings.mousePassthrough)
precondition(settings.appearanceTheme == .system)
precondition(settings.bubbleTransparency == BehaviorSettings.defaultBubbleTransparency)
precondition(settings.sessionGroupDisplay == .stacked)
precondition(settings.showsStatusBubble(hasActiveEvent: false, dismissed: false))
precondition(!settings.showsStatusBubble(hasActiveEvent: true, dismissed: true))

let autoHideSettings = BehaviorSettings(autoHide: true)
precondition(!autoHideSettings.showsStatusBubble(hasActiveEvent: false, dismissed: false))
precondition(autoHideSettings.showsStatusBubble(hasActiveEvent: true, dismissed: false))

precondition(AIPetMakerDefaults.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

let rustBehaviorJSON = """
{
  "enabled": true,
  "status_bubble": true,
  "appearance_theme": "dark",
  "bubble_transparency": 0.7,
  "click_menu": true,
  "mouse_passthrough": false,
  "auto_hide": false,
  "session_group_display": "expanded",
  "fps_profile": "smooth",
  "sources": {
    "codex": true,
    "claude_code": false,
    "pi": true,
    "opencode": true
  },
  "events": {
    "start": true,
    "tool": false,
    "waiting": true,
    "review": true,
    "done": true,
    "failed": true
  }
}
""".data(using: .utf8)!

let decoded = try JSONDecoder().decode(BehaviorSettings.self, from: rustBehaviorJSON)
precondition(decoded.fpsProfile == .smooth)
precondition(decoded.mousePassthrough == false)
precondition(decoded.appearanceTheme == .dark)
precondition(decoded.bubbleTransparency == 0.7)
precondition(decoded.sessionGroupDisplay == .expanded)
precondition(decoded.sources[.claudeCode] == false)
precondition(decoded.events[.tool] == false)
let encoded = try JSONEncoder().encode(decoded)
let encodedObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
precondition((encodedObject["sources"] as! [String: Bool])["claude_code"] == false)
precondition(encodedObject["session_group_display"] as! String == "expanded")

let legacyBehaviorJSON = """
{
  "enabled": true,
  "sources": {
    "codex": false
  },
  "events": {
    "tool": false
  }
}
""".data(using: .utf8)!

let legacyBehavior = try JSONDecoder().decode(BehaviorSettings.self, from: legacyBehaviorJSON)
precondition(legacyBehavior.statusBubble == true)
precondition(legacyBehavior.appearanceTheme == .system)
precondition(legacyBehavior.bubbleTransparency == BehaviorSettings.defaultBubbleTransparency)
precondition(legacyBehavior.clickMenu == true)
precondition(legacyBehavior.mousePassthrough == true)
precondition(legacyBehavior.autoHide == false)
precondition(legacyBehavior.sessionGroupDisplay == .stacked)
precondition(legacyBehavior.fpsProfile == .standard)
precondition(legacyBehavior.sources[.codex] == false)
precondition(legacyBehavior.sources[.claudeCode] == true)
precondition(legacyBehavior.sources[.pi] == true)
precondition(legacyBehavior.sources[.opencode] == true)
precondition(legacyBehavior.events[.tool] == false)
precondition(legacyBehavior.events[.start] == true)
precondition(legacyBehavior.events[.waiting] == true)

let placementJSON = """
{
  "x": 321.0,
  "y": 654.0,
  "scale": 0.82,
  "display_id": "display-test"
}
""".data(using: .utf8)!
let placement = try JSONDecoder().decode(OverlayPlacement.self, from: placementJSON)
precondition(placement.x == 321.0)
precondition(placement.y == 654.0)
precondition(placement.scale == 0.82)
precondition(placement.displayId == "display-test")
let encodedPlacement = try JSONSerialization.jsonObject(with: JSONEncoder().encode(placement)) as! [String: Any]
precondition(encodedPlacement["display_id"] as! String == "display-test")
precondition(OverlayPlacement().scale == 0.72)

let petSummaryJSON = """
{
  "id": "pet_demo",
  "name": "Demo Pet",
  "style": "半写实",
  "quality": "high",
  "render_size": { "width": 384, "height": 416 },
  "petpack_path": "/tmp/demo.petpack",
  "cover_path": "/tmp/demo-cover.png",
  "origin": "generated_by_petcore_job",
  "generator": "codex-app-server-brief-petpack-v1",
  "provenance": "codex_app_server_brief",
  "active": true,
  "created_at": "2026-07-09T00:00:00Z"
}
""".data(using: .utf8)!
let petSummary = try JSONDecoder().decode(PetSummary.self, from: petSummaryJSON)
precondition(petSummary.origin == .generatedByPetcoreJob)
precondition(petSummary.generationSourceTitle == "本地动画预览")
precondition(petSummary.generationSourceDetail == "AI brief + 本地预览 · codex-app-server-brief-petpack-v1 · codex_app_server_brief")

let legacyPetSummaryJSON = """
{
  "id": "pet_legacy",
  "name": "Legacy Pet",
  "style": "半写实",
  "quality": "high",
  "render_size": { "width": 384, "height": 416 },
  "petpack_path": "/tmp/legacy.petpack",
  "cover_path": "/tmp/legacy-cover.png",
  "active": false,
  "created_at": "2026-07-09T00:00:00Z"
}
""".data(using: .utf8)!
let legacyPetSummary = try JSONDecoder().decode(PetSummary.self, from: legacyPetSummaryJSON)
precondition(legacyPetSummary.generator == nil)
precondition(legacyPetSummary.provenance == nil)
precondition(legacyPetSummary.origin == .externalImport)
precondition(legacyPetSummary.generationSourceTitle == "外部导入")

let successfulGeneration = [
    GenerationMessage(role: "assistant", content: "完成，可在宠物库启用。", progress: 1, createdAt: "", kind: "generation_completed")
]
precondition(GenerationConversation.succeeded(successfulGeneration))
precondition(!GenerationConversation.canSendReply(successfulGeneration))
precondition(!GenerationConversation.terminalUnsuccessful(successfulGeneration))
precondition(GenerationConversation.activeStepIndex(messages: successfulGeneration, progress: 1) == 3)

let untypedLegacyGeneration = [
    GenerationMessage(role: "assistant", content: "完成，可在宠物库启用。", progress: 1, createdAt: "")
]
precondition(!GenerationConversation.succeeded(untypedLegacyGeneration))
precondition(!GenerationConversation.terminalUnsuccessful(untypedLegacyGeneration))
precondition(!GenerationConversation.canSendReply(untypedLegacyGeneration))

let inputRequestGeneration = [
    GenerationMessage(role: "assistant", content: "需要补充角色参考。", progress: 0.18, createdAt: "", kind: "input_request")
]
precondition(GenerationConversation.needsUserInput(inputRequestGeneration))
precondition(GenerationConversation.canSendReply(inputRequestGeneration))
precondition(!GenerationConversation.terminalUnsuccessful(inputRequestGeneration))
precondition(GenerationConversation.activeStepIndex(messages: inputRequestGeneration, progress: 0.18) == 1)

let submittedGenerationForm = GenerationForm(
    description: "不可变的已提交描述",
    style: "半写实",
    quality: .high,
    referenceImages: ["/tmp/reference.png"]
)
var resumableGeneration = GenerationSession()
_ = resumableGeneration.reduce(.startRequested(
    form: submittedGenerationForm,
    initialMessage: GenerationMessage(
        id: "msg_validation_user",
        role: "user",
        content: "开始生成",
        progress: 0.05,
        createdAt: ""
    )
))
_ = resumableGeneration.reduce(.startAccepted(jobID: "job_validation"))
let waitingEffects = resumableGeneration.reduce(.messagesReceived(
    [GenerationMessage(
        id: "msg_validation_input",
        role: "assistant",
        content: "请补充颜色",
        progress: 0.18,
        createdAt: "",
        kind: "input_request"
    )],
    revision: "2"
))
precondition(resumableGeneration.state == .waitingForInput)
precondition(resumableGeneration.isActive)
precondition(resumableGeneration.canCancel)
precondition(resumableGeneration.canSendReply)
precondition(!waitingEffects.contains(.stopMessageStream))
precondition(resumableGeneration.submittedForm == submittedGenerationForm)

let completedMessages = [GenerationMessage(
    id: "msg_validation_done",
    role: "assistant",
    content: "完成",
    progress: 1,
    createdAt: "",
    kind: "generation_completed"
)]
let firstTerminalEffects = resumableGeneration.reduce(.messagesReceived(
    completedMessages,
    revision: "3"
))
let repeatedTerminalEffects = resumableGeneration.reduce(.messagesReceived(
    completedMessages,
    revision: "3"
))
precondition(firstTerminalEffects.contains(.stopMessageStream))
precondition(firstTerminalEffects.contains(.refreshSnapshot))
precondition(!repeatedTerminalEffects.contains(.stopMessageStream))

let stableMessageJSON = #"{"id":"msg_validation_stable","role":"assistant","content":"stable","progress":0.5,"created_at":""}"#.data(using: .utf8)!
let stableMessageFirst = try JSONDecoder().decode(GenerationMessage.self, from: stableMessageJSON)
let stableMessageSecond = try JSONDecoder().decode(GenerationMessage.self, from: stableMessageJSON)
precondition(stableMessageFirst.id == "msg_validation_stable")
precondition(stableMessageSecond.id == stableMessageFirst.id)

let activeGenerationJSON = #"""
{
  "job_id": "job_restore_validation",
  "status": "waiting_for_user",
  "form": {
    "description": "可恢复任务",
    "style": "半写实",
    "quality": "high",
    "reference_images": []
  },
  "session_id": "session_restore_validation",
  "result_pet_id": null,
  "owner_instance_id": "instance_previous",
  "heartbeat_at": "2026-07-10T00:00:00Z",
  "message_revision": "8",
  "messages": [
    {
      "id": "msg_restore_validation",
      "job_id": "job_restore_validation",
      "sequence": 8,
      "role": "assistant",
      "kind": "input_request",
      "content": "请补充颜色",
      "progress": 0.2,
      "created_at": "2026-07-10T00:00:00Z"
    }
  ],
  "input_request": {
    "id": "msg_restore_validation",
    "job_id": "job_restore_validation",
    "sequence": 8,
    "role": "assistant",
    "kind": "input_request",
    "content": "请补充颜色",
    "progress": 0.2,
    "created_at": "2026-07-10T00:00:00Z"
  }
}
"""#.data(using: .utf8)!
let activeGeneration = try JSONDecoder().decode(ActiveGenerationSnapshot.self, from: activeGenerationJSON)
let restoredGeneration = GenerationSessionRestore(snapshot: activeGeneration)
precondition(restoredGeneration.state == .waitingForInput)
precondition(restoredGeneration.jobID == "job_restore_validation")
precondition(restoredGeneration.messages.map(\.id) == ["msg_restore_validation"])
precondition(restoredGeneration.messageRevision == "8")

let failedGeneration = [
    GenerationMessage(role: "assistant", content: "Codex App Server 暂不可用，请修复后重试。", progress: 1, createdAt: "", kind: "generation_failed")
]
precondition(!GenerationConversation.succeeded(failedGeneration))
precondition(!GenerationConversation.canSendReply(failedGeneration))
precondition(GenerationConversation.terminalUnsuccessful(failedGeneration))
precondition(GenerationConversation.activeStepIndex(messages: failedGeneration, progress: 1) == 2)

let failedAfterSuccessGeneration = [
    GenerationMessage(role: "assistant", content: "完成，可在宠物库启用。", progress: 1, createdAt: "", kind: "generation_completed"),
    GenerationMessage(role: "user", content: "再调整一下裙摆。", progress: 0.03, createdAt: ""),
    GenerationMessage(role: "assistant", content: "调整失败：Codex App Server 暂不可用。", progress: 1, createdAt: "", kind: "generation_failed")
]
precondition(!GenerationConversation.succeeded(failedAfterSuccessGeneration))
precondition(!GenerationConversation.canSendReply(failedAfterSuccessGeneration))
precondition(GenerationConversation.terminalUnsuccessful(failedAfterSuccessGeneration))

let runningAfterSuccessGeneration = [
    GenerationMessage(role: "assistant", content: "完成，可在宠物库启用。", progress: 1, createdAt: "", kind: "generation_completed"),
    GenerationMessage(role: "user", content: "再调整一下裙摆。", progress: 0.03, createdAt: ""),
    GenerationMessage(role: "assistant", content: "已发送调整意见，正在恢复 Codex 会话生成新版本。", progress: 0.04, createdAt: "")
]
precondition(!GenerationConversation.succeeded(runningAfterSuccessGeneration))
precondition(!GenerationConversation.canSendReply(runningAfterSuccessGeneration))
precondition(!GenerationConversation.terminalUnsuccessful(runningAfterSuccessGeneration))

let canceledGeneration = [
    GenerationMessage(role: "assistant", content: "已取消生成。", progress: 1, createdAt: "", kind: "generation_canceled")
]
precondition(!GenerationConversation.succeeded(canceledGeneration))
precondition(!GenerationConversation.canSendReply(canceledGeneration))
precondition(GenerationConversation.terminalUnsuccessful(canceledGeneration))
precondition(GenerationConversation.activeStepIndex(messages: [], progress: 0.1) == 0)
precondition(GenerationConversation.activeStepIndex(messages: [], progress: 0.35) == 1)
precondition(GenerationConversation.activeStepIndex(messages: [], progress: 0.75) == 2)
precondition(GenerationConversation.activeStepIndex(messages: [], progress: 0.98) == 3)

let generationHistoryJSON = """
{
  "found": true,
  "pet_id": "pet_demo",
  "job_id": "job_demo",
  "status": "completed",
  "session_id": "session_demo",
  "result_pet_id": "pet_demo",
  "created_at": "2026-07-09T00:00:00Z",
  "updated_at": "2026-07-09T00:01:00Z",
  "form": {
    "description": "安静陪伴的角色",
    "style": "半写实",
    "quality": "high",
    "reference_images": ["source/references/reference-00.png"]
  },
  "messages": [
    {
      "role": "assistant",
      "content": "完成，可在宠物库启用。",
      "progress": 1.0,
      "created_at": "2026-07-09T00:01:00Z",
      "kind": "generation_completed"
    }
  ]
}
""".data(using: .utf8)!
let generationHistory = try JSONDecoder().decode(GenerationHistory.self, from: generationHistoryJSON)
precondition(generationHistory.found)
precondition(generationHistory.petId == "pet_demo")
precondition(generationHistory.jobId == "job_demo")
precondition(generationHistory.form?.quality == .high)
precondition(GenerationConversation.succeeded(generationHistory.messages))

let codexConnectionInstalled = AgentConnectionStatus(
    source: .codex,
    items: [
        ConnectionCheckItem(name: "Codex CLI", status: .ok, detail: "命令可用"),
        ConnectionCheckItem(name: "本地事件 CLI", status: .ok, detail: "petcore-cli"),
        ConnectionCheckItem(name: "Codex App Server", status: .ok, detail: "stdio 初始化成功")
    ],
    installPaths: ["/tmp/agent-pet-companion"],
    checkMode: .runtime,
    checkedAt: "2026-07-09T00:00:00Z"
)
precondition(codexConnectionInstalled.checkMode == .runtime)
precondition(!codexConnectionInstalled.hasInstalledConnectorArtifacts)
precondition(!codexConnectionInstalled.hasRepairableConnectorIssue)

let codexConnectionRepairable = AgentConnectionStatus(
    source: .codex,
    items: [
        ConnectionCheckItem(name: "Codex CLI", status: .ok, detail: "命令可用"),
        ConnectionCheckItem(
            code: .managedConnector,
            name: "插件源",
            status: .needsFix,
            detail: "待写入",
            recoveryAction: .confirmManagedRepair
        )
    ],
    installPaths: ["/tmp/agent-pet-companion"],
    capabilities: AgentConnectorCapabilities(
        contractVersion: "codex-current",
        subscribedEvents: [],
        mappedInformation: [],
        privacyExclusions: [],
        repairableConnectorIssue: true,
        managedPathConflict: false,
        canUninstallManagedConnector: false
    )
)
precondition(!codexConnectionRepairable.hasInstalledConnectorArtifacts)
precondition(codexConnectionRepairable.hasRepairableConnectorIssue)

let opencodeConnectionInstalled = AgentConnectionStatus(
    source: .opencode,
    items: [
        ConnectionCheckItem(name: "OpenCode CLI", status: .ok, detail: "命令可用"),
        ConnectionCheckItem(name: "Plugin", status: .ok, detail: "已安装"),
        ConnectionCheckItem(name: "OpenCode Server", status: .ok, detail: "已配置")
    ],
    installPaths: ["/tmp/opencode"],
    connectorInstalled: true,
    capabilities: AgentConnectorCapabilities(
        contractVersion: "opencode-current",
        subscribedEvents: [],
        mappedInformation: [],
        privacyExclusions: [],
        repairableConnectorIssue: false,
        managedPathConflict: false,
        canUninstallManagedConnector: true
    )
)
precondition(opencodeConnectionInstalled.hasInstalledConnectorArtifacts)
precondition(!opencodeConnectionInstalled.hasRepairableConnectorIssue)

precondition(CheckStatus.missing.isBlocking)
precondition(!CheckStatus.notRequired.isBlocking)

let lightConnectionJSON = """
{
  "source": "codex",
  "items": [
    { "name": "Codex App Server", "status": "ok", "detail": "命令已定位，点击检查验证 stdio 初始化" }
  ],
  "install_paths": ["/tmp/agent-pet-companion"],
  "connector_installed": true,
  "check_mode": "light",
  "checked_at": "2026-07-09T00:00:00Z"
}
""".data(using: .utf8)!
let lightConnection = try JSONDecoder().decode(AgentConnectionStatus.self, from: lightConnectionJSON)
precondition(lightConnection.checkMode == .light)
precondition(lightConnection.checkedAt == "2026-07-09T00:00:00Z")
precondition(lightConnection.connectorInstalled == true)
let encodedLightConnection = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lightConnection)) as! [String: Any]
precondition(encodedLightConnection["check_mode"] as! String == "light")

print("AgentPetCompanionCoreValidation ok")
