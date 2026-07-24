import Foundation
import Testing
@testable import AgentPetCompanion

@Suite("App update controller")
struct AppUpdateControllerTests {
    @MainActor
    @Test
    func restartRestoresOnlyFreshStrictlyNewerValidatedRelease() async throws {
        let currentDate = Date(timeIntervalSince1970: 900_000)

        let freshSuiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let freshDefaults = try #require(UserDefaults(suiteName: freshSuiteName))
        defer { freshDefaults.removePersistentDomain(forName: freshSuiteName) }
        let freshPreferences = AppUpdatePreferences(defaults: freshDefaults)
        freshPreferences.recordCheck(at: currentDate.addingTimeInterval(-3_600))
        freshPreferences.save(cacheSnapshot: Self.cacheSnapshot(version: "1.1.0"))
        let freshChecker = GitHubReleaseUpdateChecker(
            client: AppUpdateHTTPSequence(responses: []),
            architecture: .arm64,
            cacheSnapshot: freshPreferences.cacheSnapshot
        )
        let freshController = AppUpdateController(
            checker: freshChecker,
            preferences: freshPreferences,
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            now: { currentDate },
            diagnostics: .disabled
        )

        #expect(await Self.waitForAvailableVersion("1.1.0", in: freshController))
        #expect(freshController.isUpdateAvailable)
        #expect(freshController.shouldShowBanner)
        #expect(freshController.state.presentation == .updateAvailable)

        let equalSuiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let equalDefaults = try #require(UserDefaults(suiteName: equalSuiteName))
        defer { equalDefaults.removePersistentDomain(forName: equalSuiteName) }
        let equalPreferences = AppUpdatePreferences(defaults: equalDefaults)
        equalPreferences.recordCheck(at: currentDate.addingTimeInterval(-3_600))
        equalPreferences.save(cacheSnapshot: Self.cacheSnapshot(version: "1.0.0"))
        let equalChecker = GitHubReleaseUpdateChecker(
            client: AppUpdateHTTPSequence(responses: []),
            architecture: .arm64,
            cacheSnapshot: equalPreferences.cacheSnapshot
        )
        let equalController = AppUpdateController(
            checker: equalChecker,
            preferences: equalPreferences,
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            now: { currentDate },
            diagnostics: .disabled
        )
        await Self.settleAsyncWork()

        #expect(equalController.availableRelease == nil)
        #expect(!equalController.isUpdateAvailable)
        #expect(equalController.state == .idle)
    }

    @MainActor
    @Test
    func restartRejectsInvalidOrExpiredCachedAvailability() async throws {
        let currentDate = Date(timeIntervalSince1970: 950_000)

        let invalidSuiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let invalidDefaults = try #require(UserDefaults(suiteName: invalidSuiteName))
        defer { invalidDefaults.removePersistentDomain(forName: invalidSuiteName) }
        let invalidPreferences = AppUpdatePreferences(defaults: invalidDefaults)
        invalidPreferences.recordCheck(at: currentDate.addingTimeInterval(-60))
        invalidPreferences.save(
            cacheSnapshot: Self.cacheSnapshot(
                version: "1.1.0",
                downloadHost: "downloads.example.invalid"
            )
        )
        let invalidChecker = GitHubReleaseUpdateChecker(
            client: AppUpdateHTTPSequence(responses: []),
            architecture: .arm64,
            cacheSnapshot: invalidPreferences.cacheSnapshot
        )
        let invalidController = AppUpdateController(
            checker: invalidChecker,
            preferences: invalidPreferences,
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            now: { currentDate },
            diagnostics: .disabled
        )

        let expiredSuiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let expiredDefaults = try #require(UserDefaults(suiteName: expiredSuiteName))
        defer { expiredDefaults.removePersistentDomain(forName: expiredSuiteName) }
        let expiredPreferences = AppUpdatePreferences(defaults: expiredDefaults)
        expiredPreferences.recordCheck(
            at: currentDate.addingTimeInterval(
                -AppUpdateController.automaticCheckInterval
            )
        )
        expiredPreferences.save(cacheSnapshot: Self.cacheSnapshot(version: "1.1.0"))
        let expiredController = AppUpdateController(
            checker: GitHubReleaseUpdateChecker(
                client: AppUpdateHTTPSequence(responses: []),
                architecture: .arm64,
                cacheSnapshot: expiredPreferences.cacheSnapshot
            ),
            preferences: expiredPreferences,
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            now: { currentDate },
            diagnostics: .disabled
        )
        await Self.settleAsyncWork()

        #expect(invalidController.availableRelease == nil)
        #expect(expiredController.availableRelease == nil)
    }

    @MainActor
    @Test
    func automaticChecksAreQuietAndRunAtMostOncePerDay() async throws {
        let suiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppUpdatePreferences(defaults: defaults)
        let client = AppUpdateHTTPSequence(responses: [
            Self.releaseResponse(version: "1.0.0", etag: #""one""#),
            Self.releaseResponse(version: "1.0.0", etag: #""two""#),
        ])
        let checker = GitHubReleaseUpdateChecker(client: client, architecture: .arm64)
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        let controller = AppUpdateController(
            checker: checker,
            preferences: preferences,
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            now: { currentDate },
            diagnostics: .disabled
        )

        controller.checkAutomaticallyIfDue()
        await Self.waitForCheck(controller)
        #expect(await client.requestCount == 1)
        #expect(!controller.isSheetPresented)
        #expect(controller.availableRelease == nil)

        controller.checkAutomaticallyIfDue()
        await Task.yield()
        #expect(await client.requestCount == 1)

        currentDate.addTimeInterval(AppUpdateController.automaticCheckInterval + 1)
        controller.checkAutomaticallyIfDue()
        await Self.waitForCheck(controller)
        #expect(await client.requestCount == 2)
        #expect(preferences.cacheSnapshot?.release.version.description == "1.0.0")
    }

    @MainActor
    @Test
    func cadenceIsRecordedAtCompletionNotAtRequestStart() async throws {
        let suiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppUpdatePreferences(defaults: defaults)
        let gate = AppUpdateHTTPGate(
            response: Self.releaseResponse(version: "1.0.0", etag: #""complete""#)
        )
        var currentDate = Date(timeIntervalSince1970: 1_500_000)
        let controller = AppUpdateController(
            checker: GitHubReleaseUpdateChecker(client: gate, architecture: .arm64),
            preferences: preferences,
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            now: { currentDate },
            diagnostics: .disabled
        )

        controller.checkAutomaticallyIfDue()
        await gate.waitUntilRequested()
        #expect(await gate.requestCount == 1)
        #expect(preferences.lastCheckDate == nil)

        currentDate.addTimeInterval(90)
        await gate.complete()
        await Self.waitForCheck(controller)

        #expect(preferences.lastCheckDate == currentDate)
        #expect(!preferences.isAutomaticCheckDue(
            now: currentDate,
            interval: AppUpdateController.automaticCheckInterval
        ))
    }

    @MainActor
    @Test
    func cancellingAnUnfinishedControllerDoesNotCommitCadence() async throws {
        let suiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppUpdatePreferences(defaults: defaults)
        let gate = AppUpdateHTTPGate(
            response: Self.releaseResponse(version: "1.0.0", etag: #""cancelled""#)
        )
        let currentDate = Date(timeIntervalSince1970: 1_600_000)
        var controller: AppUpdateController? = AppUpdateController(
            checker: GitHubReleaseUpdateChecker(client: gate, architecture: .arm64),
            preferences: preferences,
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            now: { currentDate },
            diagnostics: .disabled
        )
        weak var releasedController: AppUpdateController?
        releasedController = controller

        controller?.checkAutomaticallyIfDue()
        await gate.waitUntilRequested()
        #expect(await gate.requestCount == 1)
        #expect(preferences.lastCheckDate == nil)

        controller = nil
        #expect(releasedController == nil)
        await gate.complete()
        await Self.settleAsyncWork()

        #expect(preferences.lastCheckDate == nil)
        #expect(preferences.isAutomaticCheckDue(
            now: currentDate,
            interval: AppUpdateController.automaticCheckInterval
        ))
    }

    @MainActor
    @Test
    func residentControllerRunsOneShotNextDueCheckAndCanCancelReschedule() async throws {
        let suiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppUpdatePreferences(defaults: defaults)
        var currentDate = Date(timeIntervalSince1970: 1_700_000)
        preferences.recordCheck(at: currentDate)
        let delayGate = AppUpdateDelayGate()
        let client = AppUpdateHTTPSequence(responses: [
            Self.releaseResponse(version: "1.0.0", etag: #""one""#),
            Self.releaseResponse(version: "1.0.0", etag: #""two""#),
        ])
        let controller = AppUpdateController(
            checker: GitHubReleaseUpdateChecker(client: client, architecture: .arm64),
            preferences: preferences,
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            automaticCheckInterval: 100,
            now: { currentDate },
            waitForDelay: { delay in
                await delayGate.wait(for: delay)
            },
            diagnostics: .disabled
        )

        controller.checkAutomaticallyIfDue()
        await delayGate.waitUntilScheduled(1)
        #expect(await delayGate.waitCount == 1)
        #expect(await client.requestCount == 0)
        currentDate.addTimeInterval(100)
        await delayGate.resumeNext()
        await client.waitUntilRequestCount(1)
        await Self.waitForCheck(controller)
        #expect(await client.requestCount == 1)

        await delayGate.waitUntilScheduled(2)
        #expect(await delayGate.waitCount == 2)
        currentDate.addTimeInterval(100)
        await delayGate.resumeNext()
        await client.waitUntilRequestCount(2)
        await Self.waitForCheck(controller)
        await delayGate.waitUntilScheduled(3)
        #expect(await delayGate.waitCount == 3)

        controller.cancelScheduledAutomaticCheck()
        currentDate.addTimeInterval(100)
        await delayGate.resumeNext()
        await Self.settleAsyncWork()
        #expect(await client.requestCount == 2)
    }

    @MainActor
    @Test
    func manualCheckBypassesCadenceAndPresentsTheResult() async throws {
        let suiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppUpdatePreferences(defaults: defaults)
        preferences.recordCheck(at: Date(timeIntervalSince1970: 2_000_000))
        let client = AppUpdateHTTPSequence(responses: [
            Self.releaseResponse(version: "1.1.0", etag: #""available""#)
        ])
        let controller = AppUpdateController(
            checker: GitHubReleaseUpdateChecker(client: client, architecture: .arm64),
            preferences: preferences,
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            now: { Date(timeIntervalSince1970: 2_000_001) },
            diagnostics: .disabled
        )

        controller.checkManually()
        #expect(controller.isSheetPresented)
        await Self.waitForCheck(controller)

        #expect(await client.requestCount == 1)
        #expect(controller.availableRelease?.version.description == "1.1.0")
        #expect(controller.isUpdateAvailable)
        #expect(controller.shouldShowBanner)
    }

    @MainActor
    @Test
    func automaticFailureDoesNotPresentOrDiscardAValidatedUpdate() async throws {
        let suiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppUpdatePreferences(defaults: defaults)
        let client = AppUpdateHTTPSequence(responses: [
            Self.releaseResponse(version: "1.1.0", etag: #""available""#),
            GitHubReleaseHTTPResponse(statusCode: 503, headers: [:], body: Data()),
        ])
        var currentDate = Date(timeIntervalSince1970: 3_000_000)
        let controller = AppUpdateController(
            checker: GitHubReleaseUpdateChecker(client: client, architecture: .arm64),
            preferences: preferences,
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            now: { currentDate },
            diagnostics: .disabled
        )

        controller.checkAutomaticallyIfDue()
        await Self.waitForCheck(controller)
        #expect(controller.availableRelease?.version.description == "1.1.0")

        currentDate.addTimeInterval(AppUpdateController.automaticCheckInterval + 1)
        controller.checkAutomaticallyIfDue()
        await Self.waitForCheck(controller)
        #expect(!controller.isSheetPresented)
        #expect(controller.availableRelease?.version.description == "1.1.0")
    }

    @MainActor
    @Test
    func manualFailureTakesSheetPriorityWithoutDiscardingValidatedReminder() async throws {
        let suiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppUpdatePreferences(defaults: defaults)
        let client = AppUpdateHTTPSequence(responses: [
            Self.releaseResponse(version: "1.1.0", etag: #""available""#),
            GitHubReleaseHTTPResponse(statusCode: 503, headers: [:], body: Data()),
        ])
        let controller = AppUpdateController(
            checker: GitHubReleaseUpdateChecker(client: client, architecture: .arm64),
            preferences: preferences,
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            diagnostics: .disabled
        )

        controller.checkManually()
        await Self.waitForCheck(controller)
        #expect(controller.availableRelease?.version.description == "1.1.0")

        controller.checkManually()
        await Self.waitForCheck(controller)

        #expect(
            controller.state
                == .failed(trigger: .manual, failure: .unexpectedHTTPStatus(503))
        )
        #expect(controller.state.presentation == .failure)
        #expect(controller.isSheetPresented)
        #expect(controller.availableRelease?.version.description == "1.1.0")
        #expect(controller.shouldShowBanner)

        controller.dismissSheet()
        controller.presentAvailableUpdate()
        #expect(controller.state.presentation == .updateAvailable)
        #expect(controller.isSheetPresented)
    }

    @MainActor
    @Test
    func downloadOpenFailureKeepsTheVerifiedReleaseAndShowsRecovery() async throws {
        let suiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppUpdateController(
            checker: GitHubReleaseUpdateChecker(
                client: AppUpdateHTTPSequence(responses: [
                    Self.releaseResponse(
                        version: "1.1.0",
                        etag: #""available""#
                    )
                ]),
                architecture: .arm64
            ),
            preferences: AppUpdatePreferences(defaults: defaults),
            currentVersion: "1.0.0",
            automaticChecksEnabled: true,
            diagnostics: .disabled
        )

        controller.checkManually()
        await Self.waitForCheck(controller)
        controller.reportDownloadOpenFailure()

        #expect(
            controller.state
                == .failed(trigger: .manual, failure: .downloadOpenFailed)
        )
        #expect(controller.isSheetPresented)
        #expect(controller.availableRelease?.version.description == "1.1.0")
        #expect(controller.shouldShowBanner)
    }

    @MainActor
    private static func waitForCheck(_ controller: AppUpdateController) async {
        while controller.isChecking {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private static func waitForAvailableVersion(
        _ version: String,
        in controller: AppUpdateController
    ) async -> Bool {
        for _ in 0..<100 {
            if controller.availableRelease?.version.description == version {
                return true
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    private static func settleAsyncWork() async {
        for _ in 0..<10 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(5))
    }

    private static func cacheSnapshot(
        version: String,
        downloadHost: String = "github.com"
    ) -> GitHubReleaseUpdateCacheSnapshot {
        let semanticVersion = StableSemanticVersion(appVersion: version)!
        let tag = "v\(version)"
        let fileName = "AgentPetCompanion-\(version)-macos-arm64.zip"
        return GitHubReleaseUpdateCacheSnapshot(
            etag: #""cached""#,
            release: AppReleaseUpdate(
                version: semanticVersion,
                tagName: tag,
                releaseName: "Agent Pet Companion \(version)",
                releasePageURL: URL(
                    string:
                        "https://github.com/xjxtree/agent-pet-companion/releases/tag/\(tag)"
                )!,
                asset: AppReleaseAsset(
                    fileName: fileName,
                    architecture: .arm64,
                    downloadURL: URL(
                        string:
                            "https://\(downloadHost)/xjxtree/agent-pet-companion/releases/"
                            + "download/\(tag)/\(fileName)"
                    )!,
                    size: 4_096,
                    sha256: String(repeating: "a", count: 64)
                )
            )
        )
    }

    private static func releaseResponse(
        version: String,
        etag: String
    ) -> GitHubReleaseHTTPResponse {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let tag = "v\(version)"
        let assets: [[String: Any]] = [
            releaseAsset(version: version, tag: tag, architecture: "arm64", digest: digest),
            releaseAsset(version: version, tag: tag, architecture: "x86_64", digest: digest),
            [
                "name": "AgentPetCompanion-\(version)-SHA256SUMS.txt",
                "state": "uploaded",
                "size": 256,
                "digest": digest,
                "browser_download_url":
                    "https://github.com/xjxtree/agent-pet-companion/releases/download/"
                    + "\(tag)/AgentPetCompanion-\(version)-SHA256SUMS.txt",
            ],
        ]
        let payload: [String: Any] = [
            "tag_name": tag,
            "name": "Agent Pet Companion \(version)",
            "html_url":
                "https://github.com/xjxtree/agent-pet-companion/releases/tag/\(tag)",
            "draft": false,
            "prerelease": false,
            "immutable": true,
            "assets": assets,
        ]
        return GitHubReleaseHTTPResponse(
            statusCode: 200,
            headers: ["ETag": etag],
            body: try! JSONSerialization.data(withJSONObject: payload)
        )
    }

    private static func releaseAsset(
        version: String,
        tag: String,
        architecture: String,
        digest: String
    ) -> [String: Any] {
        let name = "AgentPetCompanion-\(version)-macos-\(architecture).zip"
        return [
            "name": name,
            "state": "uploaded",
            "size": 4_096,
            "digest": digest,
            "browser_download_url":
                "https://github.com/xjxtree/agent-pet-companion/releases/download/\(tag)/\(name)",
        ]
    }
}

private actor AppUpdateHTTPSequence: GitHubReleaseHTTPClient {
    private var responses: [GitHubReleaseHTTPResponse]
    private var requestWaiters: [
        (expectedCount: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private(set) var requestCount = 0

    init(responses: [GitHubReleaseHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> GitHubReleaseHTTPResponse {
        requestCount += 1
        resumeSatisfiedRequestWaiters()
        return responses.removeFirst()
    }

    func waitUntilRequestCount(_ expectedCount: Int) async {
        guard requestCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((expectedCount, continuation))
        }
    }

    private func resumeSatisfiedRequestWaiters() {
        var pending: [
            (expectedCount: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in requestWaiters {
            if requestCount >= waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        requestWaiters = pending
    }
}

private actor AppUpdateHTTPGate: GitHubReleaseHTTPClient {
    private let response: GitHubReleaseHTTPResponse
    private var continuation: CheckedContinuation<GitHubReleaseHTTPResponse, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0

    init(response: GitHubReleaseHTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> GitHubReleaseHTTPResponse {
        requestCount += 1
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func complete() {
        continuation?.resume(returning: response)
        continuation = nil
    }
}

private actor AppUpdateDelayGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var scheduleWaiters: [
        (expectedCount: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private(set) var requestedDelays: [TimeInterval] = []

    var waitCount: Int {
        requestedDelays.count
    }

    func wait(for delay: TimeInterval) async {
        requestedDelays.append(delay)
        resumeSatisfiedScheduleWaiters()
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilScheduled(_ expectedCount: Int) async {
        guard waitCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            scheduleWaiters.append((expectedCount, continuation))
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    private func resumeSatisfiedScheduleWaiters() {
        var pending: [
            (expectedCount: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in scheduleWaiters {
            if waitCount >= waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        scheduleWaiters = pending
    }
}
