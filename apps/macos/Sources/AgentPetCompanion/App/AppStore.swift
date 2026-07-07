import AgentPetCompanionCore
import AppKit
import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var selection: NavigationSection = .studio
    @Published var studioTab: StudioTab = .new
    @Published var descriptionText = "安静陪伴的东方幻想角色，工作时衣摆发光，等待确认时抬头提醒。"
    @Published var selectedStyle: StylePreset = .semiRealistic
    @Published var selectedQuality: QualityLevel = .high
    @Published var referenceImages: [String] = []
    @Published var behavior = BehaviorSettings()
    @Published var pets: [PetSummary] = DemoData.pets
    @Published var events: [AgentEvent] = []
    @Published var connections: [AgentConnectionStatus] = []
    @Published var generationMessages: [GenerationMessage] = DemoData.initialMessages
    @Published var generationJobID: String?
    @Published var generationProgress = 0.0
    @Published var isGenerating = false
    @Published var statusText = "正在初始化"
    @Published var overlayScale = 1.0
    @Published var overlayVisible = true

    private let client = PetCoreClient()
    private let processManager = PetCoreProcessManager()
    private let overlayController = PetOverlayController()
    private var refreshTask: Task<Void, Never>?

    var activePet: PetSummary? {
        pets.first(where: \.active) ?? pets.first
    }

    func bootstrap() async {
        processManager.startIfNeeded()
        overlayController.show(store: self)
        await refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.refresh()
                await self?.refreshGenerationMessages()
            }
        }
    }

    func refresh() async {
        do {
            let result = try await requestPetCore(method: "state.snapshot")
            let data = try JSONSerialization.data(withJSONObject: result)
            let snapshot = try JSONDecoder().decode(StateSnapshot.self, from: data)
            behavior = snapshot.behavior
            pets = snapshot.pets.isEmpty ? pets : snapshot.pets
            events = snapshot.events
            connections = snapshot.connections
            statusText = "本地服务运行中"
        } catch {
            statusText = "本地服务未连接，显示演示数据"
        }
    }

    func startGeneration() {
        let form = GenerationForm(
            description: descriptionText,
            style: selectedStyle.rawValue,
            quality: selectedQuality,
            referenceImages: referenceImages,
            note: nil
        )
        isGenerating = true
        generationProgress = 0.08
        generationMessages = [
            GenerationMessage(role: "user", content: "按表单创建一个\(selectedStyle.rawValue)桌宠。", progress: 0.05, createdAt: "")
        ]
        studioTab = .new

        Task {
            do {
                let formData = try JSONEncoder().encode(form)
                let formObject = try JSONSerialization.jsonObject(with: formData)
                let result = try await requestPetCore(method: "generation.start", params: formObject)
                if let dict = result as? [String: Any], let jobID = dict["job_id"] as? String {
                    generationJobID = jobID
                    generationProgress = 0.18
                }
                await refreshGenerationMessages()
            } catch {
                generationMessages.append(GenerationMessage(role: "assistant", content: "生成启动失败：\(error.localizedDescription)", progress: 1, createdAt: ""))
                isGenerating = false
            }
        }
    }

    func refreshGenerationMessages() async {
        guard let generationJobID else { return }
        do {
            let result = try await requestPetCore(method: "generation.messages", params: ["job_id": generationJobID])
            let data = try JSONSerialization.data(withJSONObject: result)
            let messages = try JSONDecoder().decode([GenerationMessage].self, from: data)
            if !messages.isEmpty {
                generationMessages = messages
                generationProgress = messages.map(\.progress).max() ?? generationProgress
                isGenerating = generationProgress < 1
                if generationProgress >= 1 {
                    await refresh()
                    studioTab = .library
                }
            }
        } catch {
            statusText = "生成消息暂不可用"
        }
    }

    func updateBehavior(_ next: BehaviorSettings) {
        behavior = next
        overlayVisible = next.enabled
        overlayController.setVisible(next.enabled)
        Task {
            do {
                let data = try JSONEncoder().encode(next)
                let object = try JSONSerialization.jsonObject(with: data)
                _ = try await requestPetCore(method: "behavior.update", params: object)
            } catch {
                statusText = "设置保存失败"
            }
        }
    }

    func setSource(_ source: AgentSource, enabled: Bool) {
        var next = behavior
        next.sources[source] = enabled
        updateBehavior(next)
    }

    func setEvent(_ event: AgentEventKind, enabled: Bool) {
        var next = behavior
        next.events[event] = enabled
        updateBehavior(next)
    }

    func activatePet(_ pet: PetSummary) {
        pets = pets.map { item in
            var copy = item
            copy.active = item.id == pet.id
            return copy
        }
        Task {
            _ = try? await requestPetCore(method: "pet.activate", params: ["id": pet.id])
            await refresh()
        }
    }

    func deletePet(_ pet: PetSummary) {
        pets.removeAll { $0.id == pet.id }
        Task {
            _ = try? await requestPetCore(method: "pet.delete", params: ["id": pet.id])
            await refresh()
        }
    }

    func repairConnection(_ source: AgentSource) {
        Task {
            _ = try? await requestPetCore(method: "connections.repair", params: ["source": source.rawValue])
            await refresh()
        }
    }

    func checkConnection(_ source: AgentSource) {
        Task {
            _ = try? await requestPetCore(method: "connections.check", params: ["source": source.rawValue])
            await refresh()
        }
    }

    func ingestDemoEvent(_ event: AgentEventKind, source: AgentSource = .claudeCode) {
        Task {
            _ = try? await requestPetCore(
                method: "agent.ingest",
                params: [
                    "source": source.rawValue,
                    "event_type": event.rawValue,
                    "title": event.title,
                    "detail": source.title
                ]
            )
            await refresh()
        }
    }

    func toggleOverlay() {
        var next = behavior
        next.enabled.toggle()
        updateBehavior(next)
    }

    func resizeOverlay(delta: CGSize) {
        let change = (delta.width + delta.height) / 420
        overlayScale = min(1.8, max(0.65, overlayScale + change))
        overlayController.updateScale(overlayScale)
    }

    private func requestPetCore(method: String, params: Any = [:]) async throws -> Any {
        let client = self.client
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let responseData = try await Task.detached(priority: .userInitiated) {
            try client.requestData(method: method, paramsJSONData: paramsData)
        }.value
        guard
            let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else {
            throw PetCoreClientError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw PetCoreClientError.rpcError(String(describing: error["message"] ?? "Unknown PetCore error"))
        }
        return object["result"] ?? NSNull()
    }
}

private struct StateSnapshot: Codable {
    var behavior: BehaviorSettings
    var pets: [PetSummary]
    var events: [AgentEvent]
    var connections: [AgentConnectionStatus]
}

enum DemoData {
    static let pets: [PetSummary] = [
        PetSummary(id: "demo_cloud", name: "Cloud Maiden", style: "半写实", quality: .ultra, renderSize: .init(width: 768, height: 832), petpackPath: "", coverPath: "", active: true, createdAt: "2026-07-07T00:00:00Z"),
        PetSummary(id: "demo_pixel", name: "Pixel Mochi", style: "像素", quality: .high, renderSize: .init(width: 384, height: 416), petpackPath: "", coverPath: "", active: false, createdAt: "2026-07-07T00:00:00Z"),
        PetSummary(id: "demo_neon", name: "Neon Cat", style: "现代", quality: .high, renderSize: .init(width: 384, height: 416), petpackPath: "", coverPath: "", active: false, createdAt: "2026-07-07T00:00:00Z")
    ]

    static let initialMessages = [
        GenerationMessage(role: "assistant", content: "内置 Skill 待启动。填写左侧表单后，后续制作流程在这里完成。", progress: 0, createdAt: "")
    ]
}
