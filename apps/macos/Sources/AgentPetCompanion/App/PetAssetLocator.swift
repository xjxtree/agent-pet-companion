import AgentPetCompanionCore
import Foundation

enum PetAssetLocator {
#if DEBUG
    /// Marker used only by checked-in, non-interactive UI regression fixtures.
    /// The file itself need not exist; its parent owns `assets/frames` and the
    /// fixture supplies a readable explicit cover path. Release builds retain
    /// only the normal PetCore-extracted `<pet-id>-frames` contract.
    static let uiNextFixturePetpackMarker = ".ui-next-visual-fixture.petpack"
#endif

    static func coverURL(for pet: PetSummary) -> URL? {
        candidateURLs(for: pet).first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    static func frameURLs(for pet: PetSummary, stateName: String) -> [URL] {
        guard let root = framesRoot(for: pet) else { return [] }
        let stateDirectory = root.appendingPathComponent(stateName, isDirectory: true)
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: stateDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return urls
            .filter { $0.pathExtension.caseInsensitiveCompare("png") == .orderedSame }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    static func framesRoot(for pet: PetSummary) -> URL? {
        guard !pet.petpackPath.isEmpty else { return nil }
        guard let petpackURL = petpackURL(for: pet) else { return nil }
#if DEBUG
        if petpackURL.lastPathComponent == uiNextFixturePetpackMarker {
            return petpackURL
                .deletingLastPathComponent()
                .appendingPathComponent("assets/frames", isDirectory: true)
        }
#endif
        return petpackURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(pet.id)-frames", isDirectory: true)
    }

    private static func candidateURLs(for pet: PetSummary) -> [URL] {
        var urls: [URL] = []
        if !pet.coverPath.isEmpty {
            let coverURL = URL(fileURLWithPath: pet.coverPath)
            urls.append(coverURL)
            if !(pet.coverPath as NSString).isAbsolutePath, let petpackURL = petpackURL(for: pet) {
                urls.append(
                    petpackURL
                        .deletingLastPathComponent()
                        .appendingPathComponent(pet.coverPath)
                )
            }
        }

        if let petpackURL = petpackURL(for: pet) {
            urls.append(
                petpackURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("\(pet.id)-cover.png")
            )
        }

        urls.append(contentsOf: frameURLs(for: pet, stateName: "idle").prefix(1))
        return urls
    }

    private static func petpackURL(for pet: PetSummary) -> URL? {
        guard !pet.petpackPath.isEmpty else { return nil }
        return URL(fileURLWithPath: pet.petpackPath)
    }
}
