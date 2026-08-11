import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Portable Agent Pet Maker management")
@MainActor
struct PortableMakerSkillManagementTests {
    @Test
    func statusUsesTheFixedBoundedRPCContract() async throws {
        var requests: [(String, Duration?)] = []
        let store = makeStore { method, params, timeout in
            requests.append((method, timeout))
            #expect((params as? [String: Any])?.isEmpty == true)
            return statusObject(state: "missing")
        }

        await store.refreshPortableMakerSkillStatus()

        #expect(requests.count == 1)
        #expect(requests.first?.0 == "portable_skill.status")
        #expect(requests.first?.1 == .seconds(180))
        #expect(store.portableMakerSkillStatus?.state == .missing)
        #expect(
            store.portableMakerSkillStatus?.targetDisplayPath
                == "~/agent/skills/agent-pet-maker"
        )
        #expect(store.portableMakerSkillOperation == .idle)
        #expect(store.portableMakerSkillFailure == nil)
    }

    @Test
    func installAndUninstallPublishReturnedAuthoritativeStatus() async {
        var methods: [String] = []
        let store = makeStore { method, _, _ in
            methods.append(method)
            return switch method {
            case "portable_skill.install":
                statusObject(
                    state: "current",
                    installedVersion: "0.5.6",
                    managed: true,
                    targetExists: true,
                    canReinstall: true,
                    canUninstall: true
                )
            case "portable_skill.uninstall":
                statusObject(state: "missing")
            default:
                throw PortableMakerSkillTestError.unexpectedMethod(method)
            }
        }

        await store.installPortableMakerSkill()
        #expect(store.portableMakerSkillStatus?.state == .current)
        #expect(store.portableMakerSkillStatus?.managed == true)

        await store.uninstallPortableMakerSkill()
        #expect(store.portableMakerSkillStatus?.state == .missing)
        #expect(store.portableMakerSkillStatus?.managed == false)
        #expect(methods == ["portable_skill.install", "portable_skill.uninstall"])
    }

    @Test
    func invalidStatusFailsClosedWithoutPublishingPaths() async {
        let store = makeStore { _, _, _ in
            var value = statusObject(state: "current")
            value["target_display_path"] = "/Users/someone/private"
            return value
        }

        await store.refreshPortableMakerSkillStatus()

        #expect(store.portableMakerSkillStatus == nil)
        #expect(store.portableMakerSkillFailure == .load)
        #expect(store.portableMakerSkillOperation == .idle)
    }

    @Test
    func makerHeaderPlacesThePortableSkillButtonBeforeNewPet() throws {
        let source = try sourceFile("Views/MakerSessionWorkspace.swift")
        let skillButton = try #require(
            source.range(of: "maker.portable-skill.open")?.lowerBound
        )
        let newPetButton = try #require(
            source.range(of: "maker.session-list.new")?.lowerBound
        )
        #expect(skillButton < newPetButton)
        #expect(source.contains("PortableMakerSkillManagementSheet()"))
    }

    @Test
    func sheetUsesOnlyTheAuthoredPortableSkillLocation() throws {
        let source = try sourceFile("Views/PortableMakerSkillManagementSheet.swift")
        #expect(source.contains("appendingPathComponent(\"agent\", isDirectory: true)"))
        #expect(source.contains("appendingPathComponent(\"skills\", isDirectory: true)"))
        #expect(source.contains("appendingPathComponent(\"agent-pet-maker\", isDirectory: true)"))
        #expect(!source.contains(".claude"))
        #expect(!source.contains(".codex"))
        #expect(!source.contains(".config/opencode"))
    }

    private func makeStore(
        request: @escaping AppStore.PetCoreRequestOverride
    ) -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            petCoreRequestOverride: request,
            productConvergenceManifest: nil
        )
    }

    private func statusObject(
        state: String,
        installedVersion: String? = nil,
        managed: Bool = false,
        targetExists: Bool = false,
        canInstall: Bool = true,
        canUpdate: Bool = false,
        canReinstall: Bool = false,
        canUninstall: Bool = false
    ) -> [String: Any] {
        [
            "schema_version": "apc.portable-skill-status.v1",
            "name": "agent-pet-maker",
            "state": state,
            "target_display_path": "~/agent/skills/agent-pet-maker",
            "expected_version": "0.5.6",
            "installed_version": installedVersion ?? NSNull(),
            "managed": managed,
            "target_exists": targetExists,
            "can_install": canInstall,
            "can_update": canUpdate,
            "can_reinstall": canReinstall,
            "can_uninstall": canUninstall,
        ]
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/AgentPetCompanion")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private enum PortableMakerSkillTestError: Error {
    case unexpectedMethod(String)
}
