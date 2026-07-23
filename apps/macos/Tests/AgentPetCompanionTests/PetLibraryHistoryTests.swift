import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Pet Library revision history")
struct PetLibraryHistoryTests {
    @Test
    func typedHistoryDecodesMultipleRevisionsAndJobs() throws {
        let payload = Data(#"""
        {
          "ok": true,
          "pet_id": "pet_history",
          "current_revision_id": "rev_22222222222222222222222222222222",
          "revisions": [
            {
              "revision_id": "rev_22222222222222222222222222222222",
              "current": true,
              "validated": true,
              "cover_path": "/owned/current-cover.png",
              "validation_summary": {
                "ok": true,
                "state_count": 7,
                "frame_count": 120,
                "warning_count": 0
              }
            },
            {
              "revision_id": "rev_11111111111111111111111111111111",
              "current": false,
              "validated": true
            }
          ],
          "jobs": [
            {
              "job_id": "job_modify",
              "status": "completed",
              "operation": "modify",
              "baseline_revision_id": "rev_11111111111111111111111111111111",
              "revision_id": "rev_22222222222222222222222222222222",
              "created_at": "2026-07-21T00:00:00Z",
              "updated_at": "2026-07-21T00:01:00Z"
            },
            {
              "job_id": "job_create",
              "status": "completed",
              "operation": "create",
              "created_at": "2026-07-20T00:00:00Z",
              "updated_at": "2026-07-20T00:01:00Z"
            }
          ],
          "truncated": false
        }
        """#.utf8)

        let history = try JSONDecoder().decode(PetHistorySnapshot.self, from: payload)

        #expect(history.petID == "pet_history")
        #expect(history.currentRevisionID == history.revisions.first?.revisionID)
        #expect(history.revisions.map(\.current) == [true, false])
        #expect(history.revisions.allSatisfy { $0.validated })
        #expect(history.jobs.map(\.operation) == [.modify, .create])
        #expect(history.jobs.map(\.status) == [.completed, .completed])
        #expect(history.jobs.first?.baselineRevisionID == "rev_11111111111111111111111111111111")
        #expect(history.hasCreationHistory)
        #expect(!history.truncated)
    }

    @Test
    func emptyInspectorHistoryUsesTheRequiredBilingualCopy() {
        #expect(APCLocalization.text(.libraryHistoryNoRecords, locale: "zh-Hans") == "暂无制作记录")
        #expect(APCLocalization.text(.libraryHistoryNoRecords, locale: "en") == "No creation history")
    }

    @Test
    func jobTimestampIsLocalizedInsteadOfShowingRawRFC3339() {
        let raw = "2026-07-21T08:34:56Z"
        let formatted = PetLibraryHistoryPresentation.localizedTimestamp(
            raw,
            localeIdentifier: "en_US",
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(formatted != raw)
        #expect(formatted != "—")
        #expect(!formatted.contains("T08:34:56Z"))
        #expect(PetLibraryHistoryPresentation.localizedTimestamp("invalid") == "—")
    }

    @Test
    func editInstructionUsesThePetCoreUnicodeScalarBoundary() {
        let combining = String(repeating: "e\u{301}", count: 4_001)

        #expect(combining.count == 4_001)
        #expect(GenerationPromptPolicy.scalarCount(combining) == 8_002)

        let truncated = GenerationPromptPolicy.truncate(combining)
        #expect(GenerationPromptPolicy.scalarCount(truncated) == 8_000)
        #expect(truncated.count == 4_000)
    }

    @Test
    func baselineStateSeparatesLookupFailureFromASuccessfulLegacySnapshot() {
        let lookupFailure = PetHistoryBaselineState.resolve(
            history: nil,
            loadFailed: true,
            selectedRevision: nil
        )
        #expect(lookupFailure == .lookupFailed)
        #expect(!lookupFailure.canStartEdit)
        #expect(lookupFailure.canRetry)

        let loading = PetHistoryBaselineState.resolve(
            history: nil,
            loadFailed: false,
            selectedRevision: nil
        )
        #expect(loading == .loading)
        #expect(!loading.canStartEdit)
        #expect(!loading.canRetry)

        let legacySnapshot = PetHistorySnapshot(petID: "pet_legacy")
        let legacy = PetHistoryBaselineState.resolve(
            history: legacySnapshot,
            loadFailed: false,
            selectedRevision: nil
        )
        #expect(legacy == .legacyPackage)
        #expect(legacy.canStartEdit)
        #expect(!legacy.canRetry)

        let revision = PetRevisionHistoryRecord(
            revisionID: "rev_validated",
            current: true,
            validated: true
        )
        let validated = PetHistoryBaselineState.resolve(
            history: PetHistorySnapshot(
                petID: "pet_owned",
                currentRevisionID: revision.revisionID,
                revisions: [revision]
            ),
            loadFailed: false,
            selectedRevision: revision
        )
        #expect(validated == .validatedRevision)
        #expect(validated.canStartEdit)
        #expect(!validated.canRetry)
    }

    @Test
    func historySheetFallsBackToACompactCompletableLayout() throws {
        let source = try String(
            contentsOf: macOSRootURL
                .appendingPathComponent("Sources/AgentPetCompanion/Views/PetLibraryView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("ViewThatFits(in: .horizontal)"))
        #expect(source.contains("pet-library.history.layout.wide"))
        #expect(source.contains("pet-library.history.layout.compact"))
        #expect(source.contains("minWidth: 520"))
        #expect(!source.contains(".frame(width: 780)"))
        #expect(source.contains("PetLibraryHistoryPresentation.localizedTimestamp(job.updatedAt)"))
        #expect(!source.contains("Text(job.updatedAt)"))
        #expect(source.contains("PetHistoryBaselineState.resolve("))
        #expect(source.contains("pet-library.history.retry"))
        #expect(source.contains("Task { await loadHistory() }"))

        let cancelClosureStart = try #require(source.range(of: "onCancel: {"))
        let startClosureStart = try #require(source.range(
            of: "onStart:",
            range: cancelClosureStart.upperBound ..< source.endIndex
        ))
        let cancelClosure = source[
            cancelClosureStart.lowerBound ..< startClosureStart.lowerBound
        ]
        #expect(cancelClosure.contains("pendingPetSheet = nil"))
        #expect(!cancelClosure.contains("startPetEdit"))
        #expect(!cancelClosure.contains("requestPetCore"))

        let previewStart = try #require(source.range(of: "private struct RevisionCoverImage"))
        let previewEnd = try #require(source.range(
            of: "struct PetCard",
            range: previewStart.upperBound ..< source.endIndex
        ))
        let preview = source[previewStart.lowerBound ..< previewEnd.lowerBound]
        #expect(preview.contains("else if revision != nil"))
        #expect(preview.contains("MissingPetCoverPlaceholder"))
    }

    @Test
    func makerHistoricalBaselineUsesOnlyTheExactRevisionCover() throws {
        let source = try String(
            contentsOf: macOSRootURL
                .appendingPathComponent("Sources/AgentPetCompanion/Views/PetStudioView.swift"),
            encoding: .utf8
        )
        let previewStart = try #require(
            source.range(of: "private struct SubmittedRevisionCoverImage")
        )
        let previewEnd = try #require(source.range(
            of: "private struct InlineSessionNotice",
            range: previewStart.upperBound ..< source.endIndex
        ))
        let preview = source[previewStart.lowerBound ..< previewEnd.lowerBound]

        #expect(preview.contains("revision.coverPath"))
        #expect(preview.contains("MissingPetCoverPlaceholder"))
        #expect(!preview.contains("PetCoverImage(pet:"))
        #expect(source.contains("store.generationSession.baselineRevisionID"))
        #expect(source.contains("store.fetchPetHistory(for: pet, limit: 32)"))
    }

    private var macOSRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
