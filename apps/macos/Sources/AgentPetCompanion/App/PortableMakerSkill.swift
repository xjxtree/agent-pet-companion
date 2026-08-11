import Foundation

enum PortableMakerSkillState: String, Decodable, Equatable, Sendable {
    case missing
    case current
    case updateAvailable = "update_available"
    case needsReinstall = "needs_reinstall"
    case unmanagedCurrent = "unmanaged_current"
    case conflict
}

struct PortableMakerSkillStatus: Decodable, Equatable, Sendable {
    let schemaVersion: String
    let name: String
    let state: PortableMakerSkillState
    let targetDisplayPath: String
    let expectedVersion: String
    let installedVersion: String?
    let managed: Bool
    let targetExists: Bool
    let canInstall: Bool
    let canUpdate: Bool
    let canReinstall: Bool
    let canUninstall: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name
        case state
        case targetDisplayPath = "target_display_path"
        case expectedVersion = "expected_version"
        case installedVersion = "installed_version"
        case managed
        case targetExists = "target_exists"
        case canInstall = "can_install"
        case canUpdate = "can_update"
        case canReinstall = "can_reinstall"
        case canUninstall = "can_uninstall"
    }
}

enum PortableMakerSkillOperation: Equatable {
    case idle
    case checking
    case installing
    case uninstalling

    var isBusy: Bool { self != .idle }
}

enum PortableMakerSkillFailure: Equatable {
    case load
    case install
    case uninstall
}
