import AgentPetCompanionCore
import Foundation

let scheduler = FrameScheduler(fps: 12, frameCount: 24)
precondition(scheduler.frameIndex(elapsedSeconds: 0) == 0)
precondition(scheduler.frameIndex(elapsedSeconds: 0.09) == 1)
precondition(scheduler.frameIndex(elapsedSeconds: 2.0) == 0)

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

let rustBehaviorJSON = """
{
  "enabled": true,
  "status_bubble": true,
  "click_menu": true,
  "mouse_passthrough": false,
  "auto_hide": false,
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
precondition(decoded.sources[.claudeCode] == false)
precondition(decoded.events[.tool] == false)
let encoded = try JSONEncoder().encode(decoded)
let encodedObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
precondition((encodedObject["sources"] as! [String: Bool])["claude_code"] == false)

print("AgentPetCompanionCoreValidation ok")
