import Foundation

@MainActor
final class AppUpdateController: ObservableObject {
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var state: AppUpdateCheckState = .idle
    @Published private(set) var availableRelease: AppReleaseUpdate?
    @Published private(set) var bannerDismissedVersion: StableSemanticVersion?
    @Published var isSheetPresented = false

    private let checker: GitHubReleaseUpdateChecker
    private let preferences: AppUpdatePreferences
    private let currentVersion: String
    private let automaticChecksEnabled: Bool
    private let automaticCheckInterval: TimeInterval
    private let now: @MainActor () -> Date
    private let waitForDelay: @Sendable (TimeInterval) async throws -> Void
    private let diagnostics: AppDiagnostics
    private var checkTask: Task<Void, Never>?
    private var cacheRestoreTask: Task<Void, Never>?
    private var nextAutomaticCheckTask: Task<Void, Never>?
    private var manualPresentationRequestedWhileChecking = false

    init(
        checker: GitHubReleaseUpdateChecker? = nil,
        preferences: AppUpdatePreferences = AppUpdatePreferences(),
        currentVersion: String = AppUpdateController.currentAppVersion,
        automaticChecksEnabled: Bool =
            PetCoreRuntimeContract.requiredManifest?.releaseChannel == "release",
        automaticCheckInterval: TimeInterval = AppUpdateController.automaticCheckInterval,
        now: @escaping @MainActor () -> Date = Date.init,
        waitForDelay: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        diagnostics: AppDiagnostics = .shared
    ) {
        self.checker = checker ?? GitHubReleaseUpdateChecker(
            cacheSnapshot: preferences.cacheSnapshot
        )
        self.preferences = preferences
        self.currentVersion = currentVersion
        self.automaticChecksEnabled = automaticChecksEnabled
        self.automaticCheckInterval = max(0.001, automaticCheckInterval)
        self.now = now
        self.waitForDelay = waitForDelay
        self.diagnostics = diagnostics
        restoreValidatedCachedAvailabilityIfFresh()
    }

    deinit {
        checkTask?.cancel()
        cacheRestoreTask?.cancel()
        nextAutomaticCheckTask?.cancel()
    }

    var isChecking: Bool {
        if case .checking = state { true } else { false }
    }

    var shouldShowBanner: Bool {
        guard let availableRelease else { return false }
        return bannerDismissedVersion != availableRelease.version
    }

    var isUpdateAvailable: Bool {
        availableRelease != nil
    }

    func checkAutomaticallyIfDue() {
        guard automaticChecksEnabled, checkTask == nil else { return }
        guard preferences.isAutomaticCheckDue(
            now: now(),
            interval: automaticCheckInterval
        ) else {
            scheduleNextAutomaticCheckIfNeeded()
            return
        }
        startCheck(trigger: .automatic, presentSheet: false)
    }

    func checkManually() {
        isSheetPresented = true
        guard checkTask == nil else {
            manualPresentationRequestedWhileChecking = true
            return
        }
        startCheck(trigger: .manual, presentSheet: true)
    }

    func presentAvailableUpdate() {
        guard let availableRelease else {
            checkManually()
            return
        }
        state = .updateAvailable(
            trigger: .automatic,
            release: availableRelease,
            freshness: .notModified
        )
        isSheetPresented = true
    }

    func dismissSheet() {
        isSheetPresented = false
    }

    func dismissBannerForCurrentLaunch() {
        bannerDismissedVersion = availableRelease?.version
    }

    func reportDownloadOpenFailure() {
        state = .failed(trigger: .manual, failure: .downloadOpenFailed)
        isSheetPresented = true
    }

    func cancelScheduledAutomaticCheck() {
        nextAutomaticCheckTask?.cancel()
        nextAutomaticCheckTask = nil
    }

    private func startCheck(trigger: AppUpdateCheckTrigger, presentSheet: Bool) {
        cacheRestoreTask?.cancel()
        cacheRestoreTask = nil
        cancelScheduledAutomaticCheck()
        state = .checking(trigger)
        if presentSheet {
            isSheetPresented = true
        }
        diagnostics.log(
            .info,
            category: "update",
            event: "github_release_check_started",
            metadata: ["trigger": .string(trigger.diagnosticValue)]
        )

        let checker = checker
        let currentVersion = currentVersion
        checkTask = Task { @MainActor [weak self] in
            let result = await checker.check(
                currentVersion: currentVersion,
                trigger: trigger
            )
            let cacheSnapshot = await checker.exportedCacheSnapshot()
            guard !Task.isCancelled, let self else { return }
            self.finishCheck(
                result,
                completedAt: self.now(),
                cacheSnapshot: cacheSnapshot
            )
        }
    }

    private func finishCheck(
        _ result: AppUpdateCheckState,
        completedAt: Date,
        cacheSnapshot: GitHubReleaseUpdateCacheSnapshot?
    ) {
        checkTask = nil
        preferences.recordCheck(at: completedAt)
        preferences.save(cacheSnapshot: cacheSnapshot)
        let shouldPresentAsManual = manualPresentationRequestedWhileChecking
        manualPresentationRequestedWhileChecking = false
        let presentedResult = shouldPresentAsManual
            ? result.replacingTrigger(with: .manual)
            : result
        state = presentedResult

        switch presentedResult {
        case let .updateAvailable(trigger, release, _):
            availableRelease = release
            diagnostics.log(
                .notice,
                category: "update",
                event: "github_release_update_available",
                metadata: [
                    "trigger": .string(trigger.diagnosticValue),
                    "version": .string(release.version.description),
                    "architecture": .string(release.asset.architecture.rawValue)
                ]
            )
        case let .upToDate(trigger, latestVersion, _):
            availableRelease = nil
            bannerDismissedVersion = nil
            diagnostics.log(
                .info,
                category: "update",
                event: "github_release_up_to_date",
                metadata: [
                    "trigger": .string(trigger.diagnosticValue),
                    "version": .string(latestVersion.description)
                ]
            )
        case let .failed(trigger, failure):
            diagnostics.log(
                trigger == .manual ? .error : .info,
                category: "update",
                event: "github_release_check_failed",
                metadata: [
                    "trigger": .string(trigger.diagnosticValue),
                    "failure": .string(failure.diagnosticValue),
                    "checked_at": .string(ISO8601DateFormatter().string(from: completedAt))
                ],
                throttleKey: trigger == .automatic ? "automatic_update_check_failed" : nil,
                minimumInterval: trigger == .automatic ? 86_400 : 0
            )
        case .idle, .checking:
            break
        }
        scheduleNextAutomaticCheckIfNeeded()
    }

    private func restoreValidatedCachedAvailabilityIfFresh() {
        guard automaticChecksEnabled,
              preferences.hasFreshCompletedCheck(
                  now: now(),
                  interval: automaticCheckInterval
              ),
              let currentVersion = StableSemanticVersion(appVersion: currentVersion)
        else { return }

        let checker = checker
        cacheRestoreTask = Task { @MainActor [weak self] in
            let cacheSnapshot = await checker.exportedCacheSnapshot()
            guard let self else { return }
            self.cacheRestoreTask = nil
            guard !Task.isCancelled,
                  self.checkTask == nil,
                  let release = cacheSnapshot?.release,
                  release.version > currentVersion,
                  self.preferences.hasFreshCompletedCheck(
                      now: self.now(),
                      interval: self.automaticCheckInterval
                  )
            else { return }

            self.availableRelease = release
            self.state = .updateAvailable(
                trigger: .automatic,
                release: release,
                freshness: .notModified
            )
        }
    }

    private func scheduleNextAutomaticCheckIfNeeded() {
        cancelScheduledAutomaticCheck()
        guard automaticChecksEnabled,
              checkTask == nil,
              let delay = preferences.delayUntilNextAutomaticCheck(
                  now: now(),
                  interval: automaticCheckInterval
              )
        else { return }

        let waitForDelay = waitForDelay
        nextAutomaticCheckTask = Task { @MainActor [weak self] in
            do {
                try await waitForDelay(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.nextAutomaticCheckTask = nil
            self.checkAutomaticallyIfDue()
        }
    }

    private static var currentAppVersion: String {
        PetCoreRuntimeContract.requiredManifest?.appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }
}

@MainActor
final class AppUpdatePreferences {
    private static let lastCheckKey =
        "dev.agentpet.companion.update.github-release.last-check"
    private static let cacheKey =
        "dev.agentpet.companion.update.github-release.validated-cache"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isAutomaticCheckDue(now: Date, interval: TimeInterval) -> Bool {
        guard let lastCheck = lastCheckDate else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    func hasFreshCompletedCheck(now: Date, interval: TimeInterval) -> Bool {
        guard let lastCheck = lastCheckDate else { return false }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= 0 && elapsed < interval
    }

    func delayUntilNextAutomaticCheck(
        now: Date,
        interval: TimeInterval
    ) -> TimeInterval? {
        guard let lastCheck = lastCheckDate else { return nil }
        let elapsed = now.timeIntervalSince(lastCheck)
        guard elapsed >= 0, elapsed < interval else { return nil }
        return interval - elapsed
    }

    func recordCheck(at date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastCheckKey)
    }

    func save(cacheSnapshot: GitHubReleaseUpdateCacheSnapshot?) {
        guard let cacheSnapshot,
              let data = try? JSONEncoder().encode(cacheSnapshot)
        else {
            defaults.removeObject(forKey: Self.cacheKey)
            return
        }
        defaults.set(data, forKey: Self.cacheKey)
    }

    var cacheSnapshot: GitHubReleaseUpdateCacheSnapshot? {
        guard let data = defaults.data(forKey: Self.cacheKey) else { return nil }
        return try? JSONDecoder().decode(
            GitHubReleaseUpdateCacheSnapshot.self,
            from: data
        )
    }

    var lastCheckDate: Date? {
        let value = defaults.double(forKey: Self.lastCheckKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }
}

private extension AppUpdateCheckTrigger {
    var diagnosticValue: String {
        switch self {
        case .automatic: "automatic"
        case .manual: "manual"
        }
    }
}

private extension AppUpdateCheckFailure {
    var diagnosticValue: String {
        switch self {
        case .invalidCurrentVersion: "invalid_current_version"
        case .transport: "transport"
        case let .unexpectedHTTPStatus(status): "unexpected_http_status_\(status)"
        case .invalidResponse: "invalid_response"
        case .draftRelease: "draft_release"
        case .prerelease: "prerelease"
        case .invalidReleaseVersion: "invalid_release_version"
        case .invalidReleaseURL: "invalid_release_url"
        case .invalidAssetInventory: "invalid_asset_inventory"
        case let .missingArchitectureAsset(architecture):
            "missing_architecture_asset_\(architecture.rawValue)"
        case let .ambiguousArchitectureAssets(architecture):
            "ambiguous_architecture_assets_\(architecture.rawValue)"
        case .invalidAsset: "invalid_asset"
        case .notModifiedWithoutCachedRelease: "not_modified_without_cache"
        case .downloadOpenFailed: "download_open_failed"
        }
    }
}

private extension AppUpdateCheckState {
    func replacingTrigger(with trigger: AppUpdateCheckTrigger) -> Self {
        switch self {
        case .idle:
            .idle
        case .checking:
            .checking(trigger)
        case let .updateAvailable(_, release, freshness):
            .updateAvailable(trigger: trigger, release: release, freshness: freshness)
        case let .upToDate(_, latestVersion, freshness):
            .upToDate(
                trigger: trigger,
                latestVersion: latestVersion,
                freshness: freshness
            )
        case let .failed(_, failure):
            .failed(trigger: trigger, failure: failure)
        }
    }
}
