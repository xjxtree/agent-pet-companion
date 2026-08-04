import AgentPetCompanionCore
import Foundation
import Testing
@testable import AgentPetCompanion

@Suite("Overlay placement authority")
struct OverlayPlacementAuthorityTests {
    @Test
    func sharedCanonicalizationFixtureMatchesSwiftJSONRoundTrips() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "fixtures/overlay-placement-canonicalization-v1.json"
            )
        let fixture = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixtureURL)
            ) as? [String: Any]
        )
        #expect(
            fixture["schema_version"] as? String
                == "apc.overlay-placement-canonicalization.v1"
        )
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        for testCase in cases {
            let inputObject = try #require(
                testCase["input"] as? [String: Any]
            )
            let expectedObject = try #require(
                testCase["expected"] as? [String: Any]
            )
            let input = try JSONDecoder().decode(
                OverlayPlacement.self,
                from: JSONSerialization.data(withJSONObject: inputObject)
            )
            let expected = try JSONDecoder().decode(
                OverlayPlacement.self,
                from: JSONSerialization.data(withJSONObject: expectedObject)
            )
            #expect(input == expected, Comment(rawValue: String(
                describing: testCase["id"]
            )))
            let canonical = try #require(
                OverlayPlacementCanonicalization.placement(input)
            )
            #expect(canonical == input)
            let roundTrip = try JSONDecoder().decode(
                OverlayPlacement.self,
                from: JSONEncoder().encode(canonical)
            )
            #expect(roundTrip == canonical)
            if canonical.x == 0 { #expect(canonical.x.sign == .plus) }
            if canonical.y == 0 { #expect(canonical.y.sign == .plus) }
        }
    }

    @Test
    func coordinateCanonicalizationIsMonotonicIdempotentAndClosed() throws {
        let values = [
            -1_000_000.001953125,
            -10.001953125,
            -0.001953125,
            -0.0,
            0.001953125,
            10.001953125,
            1_000_000.001953125,
        ]
        let canonical = try values.map {
            try #require(OverlayPlacementCanonicalization.coordinate($0))
        }
        for pair in zip(canonical, canonical.dropFirst()) {
            #expect(pair.0 <= pair.1)
        }
        for value in canonical {
            #expect(
                OverlayPlacementCanonicalization.coordinate(value) == value
            )
            #expect(
                value * OverlayPlacementCanonicalization.gridUnitsPerPoint
                    == (value
                        * OverlayPlacementCanonicalization.gridUnitsPerPoint)
                        .rounded()
            )
        }
        for invalid in [
            Double.nan,
            -Double.infinity,
            Double.infinity,
            Double.greatestFiniteMagnitude,
        ] {
            #expect(
                OverlayPlacementCanonicalization.coordinate(invalid) == nil
            )
        }
    }

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
    func outOfOrderAcknowledgementCannotMutateTheLatestLocalCommit() {
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

        #expect(
            authority.acknowledge(first, remoteRevision: 8) == .stale
        )
        #expect(authority.pending == second)
        #expect(authority.appliedRemoteRevision == 3)
        #expect(authority.presented == second.placement)

        authority.acknowledge(second, remoteRevision: 9)
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
    func ordinaryConflictFromAnOldGenerationIsDiscarded() {
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

        #expect(result == .stale)
        #expect(authority.appliedRemoteRevision == 10)
        #expect(authority.presented == latest.placement)
        #expect(authority.pending == latest)
    }

    @Test
    func canonicalEquivalentConflictAcknowledgesWithoutAnotherRequest() {
        var authority = OverlayPlacementAuthority()
        _ = authority.bootstrap(
            OverlayPlacement(
                x: 700,
                y: 500,
                displayWidthPt: 112,
                displayId: "main"
            ),
            remoteRevision: 10
        )
        let commit = authority.commitLocal(
            OverlayPlacement(
                x: 800,
                y: 520,
                displayWidthPt: 112,
                displayId: "main"
            ),
            interactionID: UUID()
        )
        var equivalentWireValue = commit.placement
        equivalentWireValue.x += 0.0001
        equivalentWireValue.y -= 0.0001

        let result = authority.reconcileOrdinaryConflict(
            for: commit,
            actualPlacement: equivalentWireValue,
            remoteRevision: 11
        )

        #expect(result == .acknowledged)
        #expect(authority.pending == nil)
        #expect(authority.appliedRemoteRevision == 11)
        #expect(authority.presented == commit.placement)
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
