import AgentPetCompanionCore
import Foundation

enum PetAssetLocator {
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
                naturalFrameNameCompare(
                    lhs.lastPathComponent,
                    rhs.lastPathComponent
                ) == .orderedAscending
            }
    }

    /// Mirrors PetCore and agent-pet-maker ordering byte-for-byte so strict
    /// frame validation and runtime sampling always address the same poses.
    static func naturalFrameNameCompare(_ left: String, _ right: String) -> ComparisonResult {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        var leftIndex = 0
        var rightIndex = 0

        while leftIndex < leftBytes.count, rightIndex < rightBytes.count {
            if isASCIIDigit(leftBytes[leftIndex]), isASCIIDigit(rightBytes[rightIndex]) {
                let leftEnd = digitRunEnd(in: leftBytes, from: leftIndex)
                let rightEnd = digitRunEnd(in: rightBytes, from: rightIndex)
                let leftSignificant = significantDigitStart(
                    in: leftBytes,
                    from: leftIndex,
                    to: leftEnd
                )
                let rightSignificant = significantDigitStart(
                    in: rightBytes,
                    from: rightIndex,
                    to: rightEnd
                )

                if let ordering = compare(leftEnd - leftSignificant, rightEnd - rightSignificant) {
                    return ordering
                }
                for offset in 0..<(leftEnd - leftSignificant) {
                    if let ordering = compare(
                        leftBytes[leftSignificant + offset],
                        rightBytes[rightSignificant + offset]
                    ) {
                        return ordering
                    }
                }
                if let ordering = compare(leftEnd - leftIndex, rightEnd - rightIndex) {
                    return ordering
                }
                leftIndex = leftEnd
                rightIndex = rightEnd
                continue
            }

            if let ordering = compare(
                asciiLowercased(leftBytes[leftIndex]),
                asciiLowercased(rightBytes[rightIndex])
            ) {
                return ordering
            }
            if let ordering = compare(leftBytes[leftIndex], rightBytes[rightIndex]) {
                return ordering
            }
            leftIndex += 1
            rightIndex += 1
        }

        return compare(leftBytes.count, rightBytes.count) ?? .orderedSame
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    private static func digitRunEnd(in bytes: [UInt8], from start: Int) -> Int {
        var end = start
        while end < bytes.count, isASCIIDigit(bytes[end]) {
            end += 1
        }
        return end
    }

    private static func significantDigitStart(
        in bytes: [UInt8],
        from start: Int,
        to end: Int
    ) -> Int {
        for index in start..<end where bytes[index] != 48 {
            return index
        }
        return max(start, end - 1)
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    private static func compare<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult? {
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return nil
    }

    static func framesRoot(for pet: PetSummary) -> URL? {
        guard !pet.petpackPath.isEmpty else { return nil }
        guard let petpackURL = petpackURL(for: pet) else { return nil }
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
