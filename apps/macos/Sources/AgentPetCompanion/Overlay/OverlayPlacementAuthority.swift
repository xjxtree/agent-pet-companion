import AgentPetCompanionCore
import Darwin
import Foundation

struct OverlayPlacementCommit: Equatable, Sendable {
    let interactionID: UUID
    let localRevision: UInt64
    let baseRemoteRevision: UInt64
    let placement: OverlayPlacement
}

/// A closed wire-level reason that permits PetCore to deliberately replace the
/// App's local placement authority. Ordinary snapshots carry no intent.
enum OverlayPlacementRemoteIntent: String, Codable, Equatable, Sendable {
    case externalReposition = "external_reposition"
    case reset
}

enum OverlayPlacementCommitReconciliation: Equatable, Sendable {
    case acknowledged
    case retry(OverlayPlacementCommit)
    case stale
}

enum OverlayPlacementSaveResumeReason: Equatable, Sendable {
    case bootstrap
    case reconnect
    case newLocalCommit
    case explicitRetry
    case ordinarySnapshot

    var mayResumeExhaustedGeneration: Bool {
        switch self {
        case .bootstrap, .reconnect, .newLocalCommit, .explicitRetry:
            true
        case .ordinarySnapshot:
            false
        }
    }
}

enum OverlayPlacementSaveRunOutcome: Equatable, Sendable {
    case converged
    case superseded
    case exhausted(generation: UInt64)
    case cancelled
}

/// Owns the placement that is actually presented on screen. Remote snapshots,
/// save acknowledgements, and local interactions must all pass through this
/// value before they can change the overlay's position.
struct OverlayPlacementAuthority: Equatable, Sendable {
    private(set) var presented: OverlayPlacement
    private(set) var localRevision: UInt64
    /// The independent PetCore overlay-placement revision, not the global state
    /// snapshot revision.
    private(set) var appliedRemoteRevision: UInt64
    private(set) var pending: OverlayPlacementCommit?
    private(set) var bootstrapCompleted: Bool

    init(
        presented: OverlayPlacement = OverlayPlacement(),
        localRevision: UInt64 = 0,
        appliedRemoteRevision: UInt64 = 0,
        pending: OverlayPlacementCommit? = nil,
        bootstrapCompleted: Bool = false
    ) {
        self.presented = OverlayPlacementCanonicalization.placement(presented)
            ?? OverlayPlacement()
        self.localRevision = localRevision
        self.appliedRemoteRevision = appliedRemoteRevision
        self.pending = pending
        self.bootstrapCompleted = bootstrapCompleted
    }

    func allowsRemote(
        _ incoming: OverlayPlacement,
        remoteRevision: UInt64,
        intent: OverlayPlacementRemoteIntent? = nil
    ) -> Bool {
        !bootstrapCompleted
            || (
                pending == nil
                    && remoteRevision > appliedRemoteRevision
                    && intent != nil
            )
    }

    @discardableResult
    mutating func bootstrap(
        _ placement: OverlayPlacement,
        remoteRevision: UInt64 = 0
    ) -> OverlayPlacement {
        guard !bootstrapCompleted else { return presented }
        guard let placement = OverlayPlacementCanonicalization.placement(
            placement
        ) else { return presented }
        presented = placement
        appliedRemoteRevision = remoteRevision
        bootstrapCompleted = true
        return presented
    }

    @discardableResult
    mutating func commitLocal(
        _ placement: OverlayPlacement,
        interactionID: UUID
    ) -> OverlayPlacementCommit {
        let placement = OverlayPlacementCanonicalization.placement(placement)
            ?? presented
        localRevision &+= 1
        presented = placement
        let commit = OverlayPlacementCommit(
            interactionID: interactionID,
            localRevision: localRevision,
            baseRemoteRevision: appliedRemoteRevision,
            placement: placement
        )
        pending = commit
        bootstrapCompleted = true
        return commit
    }

    /// Reconciles a successful CAS (or an idempotent conflict whose actual
    /// placement is the attempted placement). A response from any superseded
    /// local generation is discarded without changing revision knowledge.
    @discardableResult
    mutating func acknowledge(
        _ commit: OverlayPlacementCommit,
        remoteRevision: UInt64
    ) -> OverlayPlacementCommitReconciliation {
        guard pending == commit else { return .stale }
        appliedRemoteRevision = max(appliedRemoteRevision, remoteRevision)
        pending = nil
        return .acknowledged
    }

    /// Reconciles an ordinary CAS conflict. The caller handles explicit remote
    /// intent separately because an explicit reposition is allowed to replace
    /// pending local authority. An ordinary conflict only rebases the latest
    /// pending value onto the actual placement revision.
    mutating func reconcileOrdinaryConflict(
        for commit: OverlayPlacementCommit,
        actualPlacement: OverlayPlacement,
        remoteRevision: UInt64
    ) -> OverlayPlacementCommitReconciliation {
        guard pending == commit else { return .stale }
        if OverlayPlacementCanonicalization.areEquivalent(
            actualPlacement,
            commit.placement
        ) {
            return acknowledge(commit, remoteRevision: remoteRevision)
        }
        appliedRemoteRevision = max(appliedRemoteRevision, remoteRevision)
        let rebased = rebase(commit, remoteRevision: appliedRemoteRevision)
        pending = rebased
        return .retry(rebased)
    }

    /// Applies the authoritative placement returned by a CAS conflict carrying
    /// a newer explicit intent, supersedes every older pending value, and makes
    /// one ordinary commit that consumes the short-lived intent.
    mutating func supersedeWithExplicitRemote(
        _ placement: OverlayPlacement,
        remoteRevision: UInt64,
        interactionID: UUID
    ) -> OverlayPlacementCommit? {
        guard remoteRevision >= appliedRemoteRevision else { return nil }
        guard let placement = OverlayPlacementCanonicalization.placement(
            placement
        ) else { return nil }
        presented = placement
        appliedRemoteRevision = remoteRevision
        pending = nil
        bootstrapCompleted = true
        return commitLocal(placement, interactionID: interactionID)
    }

    mutating func failCommit(_ commit: OverlayPlacementCommit) {
        guard pending == commit else { return }
        // Keep the pending barrier and the presented local value. A retry of
        // this exact commit may acknowledge it; stale snapshots may not.
    }

    @discardableResult
    mutating func applyRemote(
        _ placement: OverlayPlacement,
        remoteRevision: UInt64,
        intent: OverlayPlacementRemoteIntent? = nil
    ) -> OverlayPlacement {
        guard allowsRemote(
            placement,
            remoteRevision: remoteRevision,
            intent: intent
        ) else {
            return presented
        }
        guard let placement = OverlayPlacementCanonicalization.placement(
            placement
        ) else { return presented }
        presented = placement
        appliedRemoteRevision = remoteRevision
        bootstrapCompleted = true
        return presented
    }

    private func rebase(
        _ commit: OverlayPlacementCommit,
        remoteRevision: UInt64
    ) -> OverlayPlacementCommit {
        OverlayPlacementCommit(
            interactionID: commit.interactionID,
            localRevision: commit.localRevision,
            baseRemoteRevision: remoteRevision,
            placement: commit.placement
        )
    }
}

enum OverlayPlacementRevisionCodec {
    static func parse(_ encoded: String) -> UInt64? {
        guard !encoded.isEmpty,
              encoded == "0" || encoded.first != "0",
              encoded.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return nil
        }
        return UInt64(encoded)
    }
}

struct OverlayPlacementJournalEntry: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let interactionID: UUID
    let localRevision: UInt64
    let placement: OverlayPlacement
    let baseRemoteRevision: UInt64

    init(
        interactionID: UUID,
        localRevision: UInt64,
        placement: OverlayPlacement,
        baseRemoteRevision: UInt64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.interactionID = interactionID
        self.localRevision = localRevision
        self.placement = placement
        self.baseRemoteRevision = baseRemoteRevision
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case interactionID = "interaction_id"
        case localRevision = "local_revision"
        case placement
        case baseRemoteRevision = "base_remote_revision"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported overlay placement journal schema"
            )
        }
        let encodedInteractionID = try container.decode(
            String.self,
            forKey: .interactionID
        )
        guard let parsedInteractionID = UUID(uuidString: encodedInteractionID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .interactionID,
                in: container,
                debugDescription: "Expected a UUID commit identity"
            )
        }
        interactionID = parsedInteractionID
        let encodedLocalRevision = try container.decode(
            String.self,
            forKey: .localRevision
        )
        guard let parsedLocalRevision = OverlayPlacementRevisionCodec.parse(
            encodedLocalRevision
        ), parsedLocalRevision > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .localRevision,
                in: container,
                debugDescription: "Expected a positive canonical decimal u64 string"
            )
        }
        localRevision = parsedLocalRevision
        placement = try container.decode(OverlayPlacement.self, forKey: .placement)
        let encodedRevision = try container.decode(
            String.self,
            forKey: .baseRemoteRevision
        )
        guard let parsed = OverlayPlacementRevisionCodec.parse(encodedRevision) else {
            throw DecodingError.dataCorruptedError(
                forKey: .baseRemoteRevision,
                in: container,
                debugDescription: "Expected a canonical decimal u64 string"
            )
        }
        baseRemoteRevision = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(interactionID.uuidString, forKey: .interactionID)
        try container.encode(String(localRevision), forKey: .localRevision)
        try container.encode(placement, forKey: .placement)
        try container.encode(String(baseRemoteRevision), forKey: .baseRemoteRevision)
    }
}

@MainActor
struct OverlayPlacementJournalStore {
    typealias Loader = @MainActor () throws -> OverlayPlacementJournalEntry?
    typealias Saver = @MainActor (OverlayPlacementJournalEntry) throws -> Void
    typealias Remover = @MainActor (OverlayPlacementJournalEntry) throws -> Void

    private let loader: Loader
    private let saver: Saver
    private let remover: Remover

    init(
        load: @escaping Loader,
        save: @escaping Saver,
        removeIfMatching: @escaping Remover
    ) {
        loader = load
        saver = save
        remover = removeIfMatching
    }

    func load() throws -> OverlayPlacementJournalEntry? {
        try loader()
    }

    func save(_ entry: OverlayPlacementJournalEntry) throws {
        try saver(entry)
    }

    func removeIfMatching(_ entry: OverlayPlacementJournalEntry) throws {
        try remover(entry)
    }

    static func disabled() -> Self {
        Self(load: { nil }, save: { _ in }, removeIfMatching: { _ in })
    }

    static func fileBacked(
        homeURL: URL = defaultHomeURL(),
        fileManager: FileManager = .default
    ) -> Self {
        let file = OverlayPlacementJournalFile(
            url: homeURL
                .appendingPathComponent("run", isDirectory: true)
                .appendingPathComponent("overlay-placement-pending.json"),
            fileManager: fileManager
        )
        return Self(
            load: { try file.load() },
            save: { try file.save($0) },
            removeIfMatching: { try file.removeIfMatching($0) }
        )
    }

    private static func defaultHomeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["APC_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("AgentPetCompanion", isDirectory: true)
    }
}

private enum OverlayPlacementJournalFileError: Error {
    case unsafePath
    case invalidPayload
    case io(Int32)
}

private final class OverlayPlacementJournalFile {
    private static let maximumByteCount: Int64 = 4_096
    private static let topLevelKeys: Set<String> = [
        "schema_version",
        "interaction_id",
        "local_revision",
        "placement",
        "base_remote_revision",
    ]
    private static let placementKeys: Set<String> = [
        "x",
        "y",
        "display_width_pt",
        "display_id",
    ]

    private let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager) {
        self.url = url.standardizedFileURL
        self.fileManager = fileManager
    }

    func load() throws -> OverlayPlacementJournalEntry? {
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0 else {
            if errno == ENOENT { return nil }
            throw OverlayPlacementJournalFileError.io(errno)
        }
        try validateRegularFile(pathStatus)

        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw OverlayPlacementJournalFileError.io(errno)
        }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0 else {
            throw OverlayPlacementJournalFileError.io(errno)
        }
        try validateRegularFile(openedStatus)
        guard openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino,
              openedStatus.st_size == pathStatus.st_size else {
            throw OverlayPlacementJournalFileError.unsafePath
        }
        return try readEntry(from: descriptor, status: openedStatus)
    }

    func save(_ entry: OverlayPlacementJournalEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        guard !data.isEmpty,
              data.count <= Self.maximumByteCount else {
            throw OverlayPlacementJournalFileError.invalidPayload
        }

        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try validateDirectory(directory)
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw OverlayPlacementJournalFileError.io(errno)
        }
        defer { Darwin.close(directoryDescriptor) }
        var openedDirectory = stat()
        guard fstat(directoryDescriptor, &openedDirectory) == 0,
              openedDirectory.st_mode & S_IFMT == S_IFDIR,
              openedDirectory.st_uid == getuid() else {
            throw OverlayPlacementJournalFileError.unsafePath
        }

        let filename = url.lastPathComponent
        var existing = stat()
        if fstatat(
            directoryDescriptor,
            filename,
            &existing,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            try validateReplaceableFile(existing)
        } else if errno != ENOENT {
            throw OverlayPlacementJournalFileError.io(errno)
        }

        let temporaryName = ".\(filename).\(UUID().uuidString).tmp"
        let temporaryDescriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard temporaryDescriptor >= 0 else {
            throw OverlayPlacementJournalFileError.io(errno)
        }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporaryDescriptor)
            if shouldRemoveTemporary {
                _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }
        try writeAll(data, to: temporaryDescriptor)
        guard Darwin.fsync(temporaryDescriptor) == 0 else {
            throw OverlayPlacementJournalFileError.io(errno)
        }
        guard Darwin.renameat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            filename
        ) == 0 else {
            throw OverlayPlacementJournalFileError.io(errno)
        }
        shouldRemoveTemporary = false
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw OverlayPlacementJournalFileError.io(errno)
        }
    }

    func removeIfMatching(_ expected: OverlayPlacementJournalEntry) throws {
        let directory = url.deletingLastPathComponent()
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            if errno == ENOENT { return }
            throw OverlayPlacementJournalFileError.io(errno)
        }
        defer { Darwin.close(directoryDescriptor) }
        let filename = url.lastPathComponent
        let descriptor = Darwin.openat(
            directoryDescriptor,
            filename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw OverlayPlacementJournalFileError.io(errno)
        }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0 else {
            throw OverlayPlacementJournalFileError.io(errno)
        }
        try validateRegularFile(openedStatus)
        guard try readEntry(from: descriptor, status: openedStatus) == expected else {
            return
        }
        var currentStatus = stat()
        guard fstatat(
            directoryDescriptor,
            filename,
            &currentStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        currentStatus.st_dev == openedStatus.st_dev,
        currentStatus.st_ino == openedStatus.st_ino else {
            throw OverlayPlacementJournalFileError.unsafePath
        }
        guard Darwin.unlinkat(directoryDescriptor, filename, 0) == 0,
              Darwin.fsync(directoryDescriptor) == 0 else {
            throw OverlayPlacementJournalFileError.io(errno)
        }
    }

    private func validateRegularFile(_ status: stat) throws {
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_size > 0,
              status.st_size <= Self.maximumByteCount else {
            throw OverlayPlacementJournalFileError.unsafePath
        }
    }

    private func validateDirectory(_ directory: URL) throws {
        var status = stat()
        guard lstat(directory.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid() else {
            throw OverlayPlacementJournalFileError.unsafePath
        }
    }

    private func validateReplaceableFile(_ status: stat) throws {
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1 else {
            throw OverlayPlacementJournalFileError.unsafePath
        }
    }

    private func validateClosedPayload(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Self.topLevelKeys,
              let placement = object["placement"] as? [String: Any],
              Set(placement.keys) == Self.placementKeys else {
            throw OverlayPlacementJournalFileError.invalidPayload
        }
    }

    private func readEntry(
        from descriptor: Int32,
        status: stat
    ) throws -> OverlayPlacementJournalEntry {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw OverlayPlacementJournalFileError.io(errno)
        }
        let byteCount = Int(status.st_size)
        var data = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    byteCount - offset
                )
            }
            guard count > 0 else {
                throw OverlayPlacementJournalFileError.io(
                    count == 0 ? EIO : errno
                )
            }
            offset += count
        }
        var extraByte: UInt8 = 0
        guard Darwin.read(descriptor, &extraByte, 1) == 0 else {
            throw OverlayPlacementJournalFileError.invalidPayload
        }
        try validateClosedPayload(data)
        return try JSONDecoder().decode(OverlayPlacementJournalEntry.self, from: data)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }
            guard count > 0 else {
                throw OverlayPlacementJournalFileError.io(errno)
            }
            offset += count
        }
    }
}
