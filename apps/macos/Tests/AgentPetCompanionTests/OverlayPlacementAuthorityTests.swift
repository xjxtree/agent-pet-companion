import AgentPetCompanionCore
import Foundation
import Testing
@testable import AgentPetCompanion

@Suite("Overlay placement authority")
struct OverlayPlacementAuthorityTests {
    @Test
    func firstRemotePlacementBootstrapsThePresentedValueAndRevision() {
        var authority = OverlayPlacementAuthority()
        let placement = OverlayPlacement(
            x: 984,
            y: 572,
            displayWidthPt: 112,
            displayId: "main"
        )

        #expect(authority.allowsRemote(placement, remoteRevision: 7))
        #expect(
            authority.bootstrap(placement, remoteRevision: 7)
                == placement
        )
        #expect(authority.presented == placement)
        #expect(authority.appliedRemoteRevision == 7)
        #expect(authority.bootstrapCompleted)
    }

    @Test
    func pendingCommitRejectsEveryRemoteSnapshotUntilItIsAcknowledged() {
        var authority = OverlayPlacementAuthority()
        _ = authority.bootstrap(
            OverlayPlacement(x: 744, y: 572, displayWidthPt: 112, displayId: "main"),
            remoteRevision: 4
        )
        let local = OverlayPlacement(
            x: 984,
            y: 572,
            displayWidthPt: 112,
            displayId: "main"
        )
        let commit = authority.commitLocal(
            local,
            interactionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )

        let stale = OverlayPlacement(
            x: 744,
            y: 572,
            displayWidthPt: 112,
            displayId: "main"
        )
        #expect(!authority.allowsRemote(
            stale,
            remoteRevision: 99,
            intent: .reset
        ))
        #expect(
            authority.applyRemote(
                stale,
                remoteRevision: 99,
                intent: .reset
            )
                == local
        )
        #expect(authority.pending == commit)
        #expect(authority.presented == local)
    }

    @Test
    func outOfOrderAcknowledgementCannotClearTheLatestLocalCommit() {
        var authority = OverlayPlacementAuthority()
        _ = authority.bootstrap(
            OverlayPlacement(x: 700, y: 500, displayWidthPt: 112, displayId: "main"),
            remoteRevision: 3
        )
        let first = authority.commitLocal(
            OverlayPlacement(x: 800, y: 500, displayWidthPt: 112, displayId: "main"),
            interactionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let second = authority.commitLocal(
            OverlayPlacement(x: 900, y: 500, displayWidthPt: 112, displayId: "main"),
            interactionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        let firstResult = authority.acknowledge(first, remoteRevision: 8)
        guard case let .retry(rebasedSecond) = firstResult else {
            Issue.record("Expected the latest commit to be rebased")
            return
        }
        #expect(rebasedSecond.localRevision == second.localRevision)
        #expect(rebasedSecond.placement == second.placement)
        #expect(rebasedSecond.baseRemoteRevision == 8)
        #expect(authority.pending == rebasedSecond)
        #expect(authority.presented == second.placement)

        authority.acknowledge(rebasedSecond, remoteRevision: 9)
        #expect(authority.pending == nil)
        #expect(authority.appliedRemoteRevision == 9)
        #expect(authority.presented == second.placement)
    }

    @Test
    func failedSaveRetainsThePresentedPlacementAndPendingBarrier() {
        var authority = OverlayPlacementAuthority()
        _ = authority.bootstrap(
            OverlayPlacement(x: 700, y: 500, displayWidthPt: 112, displayId: "main"),
            remoteRevision: 3
        )
        let commit = authority.commitLocal(
            OverlayPlacement(x: 900, y: 500, displayWidthPt: 112, displayId: "main"),
            interactionID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )

        authority.failCommit(commit)

        #expect(authority.presented == commit.placement)
        #expect(authority.pending == commit)
        #expect(!authority.allowsRemote(
            OverlayPlacement(x: 700, y: 500, displayWidthPt: 112, displayId: "main"),
            remoteRevision: 10
        ))
    }

    @Test
    func newerExplicitRemoteRepositionAppliesWhenNoCommitIsPending() {
        var authority = OverlayPlacementAuthority()
        _ = authority.bootstrap(
            OverlayPlacement(x: 700, y: 500, displayWidthPt: 112, displayId: "main"),
            remoteRevision: 3
        )
        let reset = OverlayPlacement(
            x: 760,
            y: 540,
            displayWidthPt: 112,
            displayId: "secondary"
        )

        #expect(authority.allowsRemote(
            reset,
            remoteRevision: 4,
            intent: .externalReposition
        ))
        #expect(authority.applyRemote(
            reset,
            remoteRevision: 4,
            intent: .externalReposition
        ) == reset)
        #expect(authority.presented == reset)
        #expect(authority.appliedRemoteRevision == 4)
    }

    @Test
    func ordinaryNewerSnapshotCannotReplaceLocalAuthorityAfterAcknowledgement() {
        var authority = OverlayPlacementAuthority()
        _ = authority.bootstrap(
            OverlayPlacement(x: 700, y: 500, displayWidthPt: 112, displayId: "main"),
            remoteRevision: 3
        )
        let local = OverlayPlacement(
            x: 900,
            y: 540,
            displayWidthPt: 112,
            displayId: "main"
        )
        let commit = authority.commitLocal(
            local,
            interactionID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        )
        authority.acknowledge(commit, remoteRevision: 4)
        let ordinaryRemote = OverlayPlacement(
            x: 760,
            y: 520,
            displayWidthPt: 112,
            displayId: "secondary"
        )

        #expect(!authority.allowsRemote(
            ordinaryRemote,
            remoteRevision: 99,
            intent: nil
        ))
        #expect(authority.applyRemote(
            ordinaryRemote,
            remoteRevision: 99,
            intent: nil
        ) == local)
        #expect(authority.presented == local)
        #expect(authority.appliedRemoteRevision == 4)
    }

    @Test
    func ordinaryConflictRebasesOnlyTheLatestLocalCommit() {
        var authority = OverlayPlacementAuthority()
        let server = OverlayPlacement(
            x: 700,
            y: 500,
            displayWidthPt: 112,
            displayId: "main"
        )
        _ = authority.bootstrap(server, remoteRevision: 10)
        let first = authority.commitLocal(
            OverlayPlacement(x: 800, y: 500, displayWidthPt: 112, displayId: "main"),
            interactionID: UUID()
        )
        let latest = authority.commitLocal(
            OverlayPlacement(x: 900, y: 500, displayWidthPt: 112, displayId: "main"),
            interactionID: UUID()
        )

        let result = authority.reconcileOrdinaryConflict(
            for: first,
            actualPlacement: server,
            remoteRevision: 11
        )

        guard case let .retry(rebased) = result else {
            Issue.record("Expected the latest local commit to retry")
            return
        }
        #expect(rebased.localRevision == latest.localRevision)
        #expect(rebased.interactionID == latest.interactionID)
        #expect(rebased.placement == latest.placement)
        #expect(rebased.baseRemoteRevision == 11)
        #expect(authority.presented == latest.placement)
        #expect(authority.pending == rebased)
    }

    @Test
    func explicitConflictSupersedesPendingAndCreatesOneConsumeCommit() throws {
        var authority = OverlayPlacementAuthority()
        _ = authority.bootstrap(
            OverlayPlacement(x: 700, y: 500, displayWidthPt: 112, displayId: "main"),
            remoteRevision: 10
        )
        let old = authority.commitLocal(
            OverlayPlacement(x: 800, y: 500, displayWidthPt: 112, displayId: "main"),
            interactionID: UUID()
        )
        let explicit = OverlayPlacement(
            x: 950,
            y: 540,
            displayWidthPt: 112,
            displayId: "main"
        )

        let optionalConsume = authority.supersedeWithExplicitRemote(
            explicit,
            remoteRevision: 11,
            interactionID: UUID()
        )
        let consume = try #require(optionalConsume)

        #expect(consume.localRevision > old.localRevision)
        #expect(consume.baseRemoteRevision == 11)
        #expect(consume.placement == explicit)
        #expect(authority.presented == explicit)
        #expect(authority.pending == consume)
    }

    @MainActor
    @Test
    func fileJournalRoundTripsWithOwnerOnlyPermissionsAndMatchingAckRemoval() throws {
        let home = try temporaryJournalHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OverlayPlacementJournalStore.fileBacked(homeURL: home)
        let entry = journalEntry()

        try store.save(entry)

        #expect(try store.load() == entry)
        let url = journalURL(home: home)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try store.removeIfMatching(entry)
        #expect(try store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test
    func fileJournalMatchingIdentityPreventsABARemoval() throws {
        let home = try temporaryJournalHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OverlayPlacementJournalStore.fileBacked(homeURL: home)
        let first = journalEntry(interactionID: UUID(), localRevision: 1)
        let sameContentNewCommit = journalEntry(
            interactionID: UUID(),
            localRevision: 2
        )
        try store.save(first)
        try store.save(sameContentNewCommit)

        try store.removeIfMatching(first)

        #expect(try store.load() == sameContentNewCommit)
    }

    @MainActor
    @Test
    func fileJournalRejectsUnknownTopLevelAndPlacementKeysThenCanHeal() throws {
        let home = try temporaryJournalHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = OverlayPlacementJournalStore.fileBacked(homeURL: home)
        let entry = journalEntry()
        try store.save(entry)
        let url = journalURL(home: home)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        object["future"] = true
        try JSONSerialization.data(withJSONObject: object).write(
            to: url,
            options: .atomic
        )
        #expect(throws: (any Error).self) {
            _ = try store.load()
        }

        object.removeValue(forKey: "future")
        var placement = try #require(object["placement"] as? [String: Any])
        placement["future"] = "unsafe"
        object["placement"] = placement
        try JSONSerialization.data(withJSONObject: object).write(
            to: url,
            options: .atomic
        )
        #expect(throws: (any Error).self) {
            _ = try store.load()
        }

        try store.save(entry)
        #expect(try store.load() == entry)
    }

    @MainActor
    @Test
    func fileJournalRejectsSymlinksAndNonRegularFiles() throws {
        let home = try temporaryJournalHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let run = home.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: run,
            withIntermediateDirectories: true
        )
        let target = home.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: target)
        let url = journalURL(home: home)
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: target
        )
        let store = OverlayPlacementJournalStore.fileBacked(homeURL: home)

        #expect(throws: (any Error).self) {
            _ = try store.load()
        }
        #expect(throws: (any Error).self) {
            try store.save(journalEntry())
        }

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            _ = try store.load()
        }
    }

    private func journalEntry(
        interactionID: UUID = UUID(),
        localRevision: UInt64 = 1
    ) -> OverlayPlacementJournalEntry {
        OverlayPlacementJournalEntry(
            interactionID: interactionID,
            localRevision: localRevision,
            placement: OverlayPlacement(
                x: 800,
                y: 500,
                displayWidthPt: 112,
                displayId: "main"
            ),
            baseRemoteRevision: 9
        )
    }

    private func temporaryJournalHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apc-overlay-journal-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private func journalURL(home: URL) -> URL {
        home.appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("overlay-placement-pending.json")
    }
}
