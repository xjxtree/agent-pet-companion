import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct PetLibraryImportTests {
    @MainActor
    @Test
    func validPetpackImportsAndRefreshesTheLibrary() async throws {
        let snapshot = try Self.stateSnapshotPayload()
        let probe = PetpackImportRequestProbe(snapshot: snapshot)
        let store = makeStore(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/import-success/Cloud.PETPACK")
        store.selection = .diagnostics

        store.importPetpacks(urls: [url])

        #expect(store.isImportingPetpack)
        await store.waitForPetpackImport()

        #expect(!store.isImportingPetpack)
        #expect(store.selection == .library)
        #expect(store.petLibraryNotice == nil)
        #expect(store.statusText == "已导入本 App .petpack")
        #expect(probe.importWorkflowMethods == ["petpack.import", "state.snapshot"])
        #expect(probe.importedPaths == [url.standardizedFileURL.path])
    }

    @MainActor
    @Test
    func partialFailureImportsTheValidFileAndPublishesTypedNotice() async throws {
        let snapshot = try Self.stateSnapshotPayload()
        let rejectedURL = URL(
            fileURLWithPath: "/tmp/backend-secret/import-failed/broken.petpack"
        )
        let acceptedURL = URL(fileURLWithPath: "/tmp/import-success/valid.petpack")
        let probe = PetpackImportRequestProbe(
            snapshot: snapshot,
            rejectedPaths: [rejectedURL.standardizedFileURL.path]
        )
        let store = makeStore(probe: probe)
        store.selection = .connections

        store.importPetpacks(urls: [acceptedURL, rejectedURL])
        await store.waitForPetpackImport()

        #expect(!store.isImportingPetpack)
        #expect(store.selection == .library)
        #expect(probe.importWorkflowMethods == [
            "petpack.import",
            "petpack.import",
            "state.snapshot",
        ])
        #expect(probe.importedPaths == [
            acceptedURL.standardizedFileURL.path,
            rejectedURL.standardizedFileURL.path,
        ])
        #expect(store.petLibraryNotice?.kind == .importFailure)
        #expect(store.petLibraryNotice?.title == APCLocalization.text(.libraryImportPartialTitle))
        #expect(store.petLibraryNotice?.message.contains("broken.petpack") == true)
        #expect(store.petLibraryNotice?.message.contains("backend-secret") == false)
        #expect(!store.statusText.contains("\n"))
    }

    @MainActor
    @Test
    func emptyURLListFailsWithoutOpeningAPanelOrSendingRequests() async throws {
        let probe = PetpackImportRequestProbe(snapshot: try Self.stateSnapshotPayload())
        let store = makeStore(probe: probe)

        store.importPetpacks(urls: [])
        await store.waitForPetpackImport()

        #expect(probe.methods.isEmpty)
        #expect(!store.isImportingPetpack)
        #expect(store.petLibraryNotice?.kind == .importFailure)
        #expect(store.petLibraryNotice?.title == APCLocalization.text(.libraryImportFailureTitle))
        #expect(store.petLibraryNotice?.message.contains(
            APCLocalization.text(.libraryImportValidPetpack)
        ) == true)
    }

    @MainActor
    @Test
    func overlappingImportRequestsKeepTheFirstTaskAndItsProgressState() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/import-delayed/first.petpack")
        let secondURL = URL(fileURLWithPath: "/tmp/import-overlap/second.petpack")
        let probe = PetpackImportRequestProbe(
            snapshot: try Self.stateSnapshotPayload(),
            delayedPath: firstURL.standardizedFileURL.path
        )
        let store = makeStore(probe: probe)
        let completion = PetpackImportWaitCompletionProbe()

        store.importPetpacks(urls: [firstURL])
        await probe.waitForDelayedRequestToStart()
        #expect(store.isImportingPetpack)

        store.importPetpacks(urls: [secondURL])
        let waiter = Task { @MainActor in
            await store.waitForPetpackImport()
            completion.didComplete = true
        }

        for _ in 0 ..< 20 where !completion.didComplete {
            await Task.yield()
        }

        #expect(probe.importedPaths == [firstURL.standardizedFileURL.path])
        #expect(!completion.didComplete)
        #expect(store.isImportingPetpack)

        probe.releaseDelayedRequest()
        await waiter.value

        #expect(completion.didComplete)
        #expect(!store.isImportingPetpack)
        #expect(probe.importedPaths == [firstURL.standardizedFileURL.path])
    }

    @MainActor
    private func makeStore(probe: PetpackImportRequestProbe) -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                try await probe.response(method: method, params: params)
            }
        )
    }

    private static func stateSnapshotPayload() throws -> [String: Any] {
        let behavior = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(BehaviorSettings())
        )
        return [
            "revision": "petpack-import-test",
            "behavior": behavior,
            "behavior_revision": "0",
            "pets": [],
            "events": [],
            "connections": [],
        ]
    }
}

@MainActor
private final class PetpackImportRequestProbe {
    let snapshot: [String: Any]
    let rejectedPaths: Set<String>
    let delayedPath: String?
    var requests: [(method: String, params: Any)] = []
    private var delayedRequestStarted = false
    private var delayedRequestStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var delayedRequestContinuation: CheckedContinuation<Void, Never>?

    init(
        snapshot: [String: Any],
        rejectedPaths: Set<String> = [],
        delayedPath: String? = nil
    ) {
        self.snapshot = snapshot
        self.rejectedPaths = rejectedPaths
        self.delayedPath = delayedPath
    }

    var methods: [String] {
        requests.map(\.method)
    }

    var importedPaths: [String] {
        requests.compactMap { request in
            guard request.method == "petpack.import",
                  let params = request.params as? [String: Any]
            else { return nil }
            return params["path"] as? String
        }
    }

    var importWorkflowMethods: [String] {
        methods.filter { $0 == "petpack.import" || $0 == "state.snapshot" }
    }

    func waitForDelayedRequestToStart() async {
        guard !delayedRequestStarted else { return }
        await withCheckedContinuation { continuation in
            delayedRequestStartWaiters.append(continuation)
        }
    }

    func releaseDelayedRequest() {
        delayedRequestContinuation?.resume()
        delayedRequestContinuation = nil
    }

    func response(method: String, params: Any) async throws -> Any {
        requests.append((method, params))
        switch method {
        case "petpack.import":
            let path = (params as? [String: Any])?["path"] as? String
            if path == delayedPath, !delayedRequestStarted {
                delayedRequestStarted = true
                delayedRequestStartWaiters.forEach { $0.resume() }
                delayedRequestStartWaiters.removeAll()
                await withCheckedContinuation { continuation in
                    delayedRequestContinuation = continuation
                }
            }
            if let path, rejectedPaths.contains(path) {
                throw PetpackImportTestError.rejected
            }
            return [:]
        case "state.snapshot":
            return snapshot
        case "overlay.placement.update":
            return [:]
        default:
            throw PetpackImportTestError.unexpectedMethod(method)
        }
    }
}

@MainActor
private final class PetpackImportWaitCompletionProbe {
    var didComplete = false
}

private enum PetpackImportTestError: Error {
    case rejected
    case unexpectedMethod(String)
}
