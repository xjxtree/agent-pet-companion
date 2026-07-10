import Foundation
import UniformTypeIdentifiers

enum PetpackImportPolicy {
    static let contentType = UTType(exportedAs: "dev.agentpet.petpack", conformingTo: .data)

    static func acceptsFileName(_ fileName: String) -> Bool {
        let url = URL(fileURLWithPath: fileName)
        return !url.deletingPathExtension().lastPathComponent.isEmpty
            && url.pathExtension.caseInsensitiveCompare("petpack") == .orderedSame
    }
}
