import AppKit
import Darwin
import Foundation

enum AppInstanceClaim: Equatable {
    case primary
    case secondary
    case failed(String)
}

struct AppActivationRequest: Equatable, Sendable {
    private static let bundlePathKey = "bundle_path"
    private static let buildIDKey = "build_id"

    let bundlePath: String
    let buildID: String

    init?(bundlePath: String, buildID: String) {
        let path = bundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = buildID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !build.isEmpty else { return nil }
        self.bundlePath = path
        self.buildID = build
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let bundlePath = userInfo?[Self.bundlePathKey] as? String,
              let buildID = userInfo?[Self.buildIDKey] as? String
        else { return nil }
        self.init(bundlePath: bundlePath, buildID: buildID)
    }

    static func current(bundle: Bundle = .main) -> AppActivationRequest? {
        guard let buildID = bundle.object(forInfoDictionaryKey: "APCBuildID") as? String else {
            return nil
        }
        return AppActivationRequest(bundlePath: bundle.bundleURL.path, buildID: buildID)
    }

    var userInfo: [AnyHashable: Any] {
        [Self.bundlePathKey: bundlePath, Self.buildIDKey: buildID]
    }
}

final class AppInstanceLock {
    private let lockURL: URL
    private var descriptor: Int32 = -1

    init(homeURL: URL) {
        lockURL = homeURL
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("app-instance.lock")
    }

    func acquire() throws -> Bool {
        if descriptor >= 0 { return true }
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fileDescriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(fileDescriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return false
            }
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }
        descriptor = fileDescriptor
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

@MainActor
final class AppSingleInstanceCoordinator: NSObject {
    static let shared = AppSingleInstanceCoordinator()

    private static let activationNotification = Notification.Name(
        "dev.agentpet.companion.activate-running-instance"
    )

    private let homeURL: URL
    private let notificationScope: String
    private var instanceLock: AppInstanceLock?
    private(set) var claim: AppInstanceClaim?
    private var activationHandler: ((AppActivationRequest?) -> Void)?
    private var observesActivationRequests = false

    override init() {
        homeURL = Self.appSupportHomeURL()
        notificationScope = homeURL.standardizedFileURL.path
        super.init()
    }

    func claimPrimaryInstance() -> AppInstanceClaim {
        if let claim { return claim }
        let lock = AppInstanceLock(homeURL: homeURL)
        do {
            guard try lock.acquire() else {
                claim = .secondary
                return .secondary
            }
            instanceLock = lock
            claim = .primary
            beginObservingActivationRequests()
            return .primary
        } catch {
            let failed = AppInstanceClaim.failed(error.localizedDescription)
            claim = failed
            return failed
        }
    }

    func setActivationHandler(_ handler: @escaping (AppActivationRequest?) -> Void) {
        activationHandler = handler
    }

    func activatePrimaryInstance(request: AppActivationRequest? = nil) {
        guard claim == .primary else { return }
        activationHandler?(request)
    }

    func requestPrimaryActivation() {
        let request = AppActivationRequest.current()
        DistributedNotificationCenter.default().postNotificationName(
            Self.activationNotification,
            object: notificationScope,
            userInfo: request?.userInfo,
            deliverImmediately: true
        )
    }

    private func beginObservingActivationRequests() {
        guard !observesActivationRequests else { return }
        observesActivationRequests = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveActivationRequest(_:)),
            name: Self.activationNotification,
            object: notificationScope
        )
    }

    @objc private func receiveActivationRequest(_ notification: Notification) {
        activationHandler?(AppActivationRequest(userInfo: notification.userInfo))
    }

    private static func appSupportHomeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["APC_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("AgentPetCompanion", isDirectory: true)
    }
}

@MainActor
final class AppUpdateHandoffCoordinator {
    enum ActivationDisposition: Equatable {
        case ignored
        case manualInstallation(AppManualInstallationRequest)
        case restartDeferred
        case restartScheduled
    }

    static let shared = AppUpdateHandoffCoordinator()

    private let bundleURL: URL
    private let launchedBuildID: String?
    private let launchedBundleIdentifier: String
    private let launchedAsRelease: Bool
    private var handoffScheduled = false
    private var deferredRestartTarget: RestartTarget?
    private var deferredRestartTask: Task<Void, Never>?
    private var deferredFailureReported = false
    private var canRestart: @MainActor () -> Bool = { true }
    private var onRestartDeferred: @MainActor () -> Void = {}
    private var onRestartFailed: @MainActor (AppManualInstallationRequest) -> Void = { _ in }

    init(bundle: Bundle = .main) {
        bundleURL = bundle.bundleURL
        launchedBuildID = (bundle.object(forInfoDictionaryKey: "APCBuildID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        launchedBundleIdentifier = bundle.bundleIdentifier ?? "dev.agentpet.companion"
        launchedAsRelease =
            bundle.object(forInfoDictionaryKey: "APCReleaseChannel") as? String == "release"
    }

    func configureSafety(
        canRestart: @escaping @MainActor () -> Bool,
        onDeferred: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (AppManualInstallationRequest) -> Void
    ) {
        self.canRestart = canRestart
        onRestartDeferred = onDeferred
        onRestartFailed = onFailure
    }

    func restartIfInstalledBuildChanged() -> Bool {
        if handoffScheduled { return true }
        guard let installedBuildID = Self.installedBuildID(at: bundleURL),
              Self.buildChanged(
            launchedBuildID: launchedBuildID,
            installedBuildID: installedBuildID
        )
        else { return false }

        AppDiagnostics.shared.log(
            .notice,
            category: "lifecycle",
            event: "app_update_handoff_detected"
        )
        guard let candidate = Self.validatedCandidate(
            launchedBuildID: launchedBuildID,
            requestedBuildID: installedBuildID,
            requestedBundleURL: bundleURL,
            expectedBundleIdentifier: launchedBundleIdentifier
        ), !launchedAsRelease || candidate.requiresCanonicalInstallation
        else {
            reportRestartFailure(RestartTarget(
                bundleURL: bundleURL.standardizedFileURL,
                buildID: installedBuildID,
                version: nil,
                bundleIdentifier: launchedBundleIdentifier,
                requiresRelease: launchedAsRelease
            ), kind: .invalidTarget)
            return false
        }
        let disposition = requestRestart(to: restartTarget(for: candidate))
        return disposition == .restartScheduled || disposition == .restartDeferred
    }

    func handleRequestedBuild(_ request: AppActivationRequest?) -> ActivationDisposition {
        if handoffScheduled { return .restartScheduled }
        guard let request else { return .ignored }
        let requestedBundleURL = URL(
            fileURLWithPath: request.bundlePath,
            isDirectory: true
        )
        let allowsInstallationCompletion = Self.isInstallationCompletionHandoff(
            launchedBundleURL: bundleURL,
            launchedBuildID: launchedBuildID,
            requestedBuildID: request.buildID,
            requestedBundleURL: requestedBundleURL,
            expectedBundleIdentifier: launchedBundleIdentifier
        )
        guard let candidate = Self.validatedCandidate(
            launchedBuildID: launchedBuildID,
            requestedBuildID: request.buildID,
            requestedBundleURL: requestedBundleURL,
            expectedBundleIdentifier: launchedBundleIdentifier,
            allowsSameBuildID: allowsInstallationCompletion
        ) else {
            if let invalidRequest = Self.invalidReleaseBundleRequest(
                requestedBuildID: request.buildID,
                requestedBundleURL: requestedBundleURL,
                expectedBundleIdentifier: launchedBundleIdentifier
            ) {
                AppDiagnostics.shared.log(
                    .error,
                    category: "lifecycle",
                    event: "app_update_invalid_release_bundle_requested"
                )
                return .manualInstallation(invalidRequest)
            }
            return .ignored
        }

        guard !candidate.requiresCanonicalInstallation
            || AppInstallationPolicy.isCanonicalBundle(candidate.bundleURL)
        else {
            AppDiagnostics.shared.log(
                .notice,
                category: "lifecycle",
                event: "app_update_manual_installation_requested"
            )
            return .manualInstallation(AppManualInstallationRequest(
                origin: .secondaryDownloadedBuild,
                version: candidate.version,
                candidateBundlePath: candidate.bundleURL.path
            ))
        }

        AppDiagnostics.shared.log(
            .notice,
            category: "lifecycle",
            event: "app_update_handoff_requested"
        )
        return requestRestart(to: restartTarget(for: candidate))
    }

    func restartForRequestedBuildIfNeeded(_ request: AppActivationRequest?) -> Bool {
        let disposition = handleRequestedBuild(request)
        return disposition == .restartScheduled || disposition == .restartDeferred
    }

    private func requestRestart(to target: RestartTarget) -> ActivationDisposition {
        guard canRestart() else {
            deferredRestartTarget = target
            deferredFailureReported = false
            onRestartDeferred()
            scheduleDeferredRestartCheck()
            AppDiagnostics.shared.log(
                .notice,
                category: "lifecycle",
                event: "app_update_handoff_deferred_for_active_work"
            )
            return .restartDeferred
        }
        switch scheduleRestart(to: target) {
        case .scheduled:
            return .restartScheduled
        case let failure:
            reportRestartFailure(target, kind: failure)
            return .ignored
        }
    }

    private func scheduleDeferredRestartCheck() {
        guard deferredRestartTask == nil else { return }
        deferredRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard self.canRestart(), let target = self.deferredRestartTarget else {
                    continue
                }
                switch self.scheduleRestart(to: target) {
                case .scheduled:
                    self.deferredRestartTarget = nil
                    self.deferredRestartTask = nil
                    return
                case .invalidTarget:
                    if !self.deferredFailureReported {
                        self.deferredFailureReported = true
                        self.reportRestartFailure(target, kind: .invalidTarget)
                    }
                case .helperFailed:
                    self.deferredRestartTask = nil
                    self.reportRestartFailure(target, kind: .helperFailed)
                    return
                }
            }
        }
    }

    private enum RestartSchedulingResult: Equatable {
        case scheduled
        case invalidTarget
        case helperFailed
    }

    private struct RestartTarget {
        let bundleURL: URL
        let buildID: String
        let version: String?
        let bundleIdentifier: String
        let requiresRelease: Bool
    }

    private func restartTarget(for candidate: ValidatedCandidate) -> RestartTarget {
        RestartTarget(
            bundleURL: candidate.bundleURL,
            buildID: candidate.buildID,
            version: candidate.version,
            bundleIdentifier: launchedBundleIdentifier,
            requiresRelease: candidate.requiresCanonicalInstallation
        )
    }

    private func scheduleRestart(to target: RestartTarget) -> RestartSchedulingResult {
        guard !handoffScheduled else { return .helperFailed }
        guard Self.isStillValidHandoffTarget(
            bundleURL: target.bundleURL,
            expectedBuildID: target.buildID,
            expectedVersion: target.version,
            expectedBundleIdentifier: target.bundleIdentifier,
            requiresRelease: target.requiresRelease
        ) else {
            AppDiagnostics.shared.log(
                .error,
                category: "lifecycle",
                event: "app_update_handoff_revalidation_failed"
            )
            return .invalidTarget
        }
        handoffScheduled = true
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.05; done; /bin/sleep 0.5; exec /usr/bin/open \"$2\"",
            "agent-pet-update-handoff",
            String(getpid()),
            target.bundleURL.path
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            AppDiagnostics.shared.log(
                .notice,
                category: "lifecycle",
                event: "app_update_handoff_scheduled"
            )
            NSApp.terminate(nil)
            return .scheduled
        } catch {
            handoffScheduled = false
            AppDiagnostics.shared.logFailure(
                error,
                category: "lifecycle",
                event: "app_update_handoff_failed"
            )
            return .helperFailed
        }
    }

    private func reportRestartFailure(
        _ target: RestartTarget,
        kind: RestartSchedulingResult
    ) {
        let origin: AppManualInstallationRequest.Origin = kind == .invalidTarget
            && target.requiresRelease
            ? .invalidReleaseBundle
            : .restartFailed
        onRestartFailed(AppManualInstallationRequest(
            origin: origin,
            version: target.version,
            candidateBundlePath: target.bundleURL.path
        ))
    }

    static func installedBuildID(at bundleURL: URL) -> String? {
        guard let plist = installedInfoDictionary(at: bundleURL),
              let buildID = plist["APCBuildID"] as? String
        else { return nil }
        let trimmed = buildID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func buildChanged(launchedBuildID: String?, installedBuildID: String?) -> Bool {
        guard let launchedBuildID, !launchedBuildID.isEmpty,
              let installedBuildID, !installedBuildID.isEmpty
        else { return false }
        return launchedBuildID != installedBuildID
    }

    static func shouldHandoff(
        launchedBuildID: String?,
        requestedBuildID: String,
        requestedBundleURL: URL,
        expectedBundleIdentifier: String,
        launchedBundleURL: URL? = nil,
        canonicalBundleURL: URL = AppInstallationPolicy.canonicalBundleURL
    ) -> Bool {
        let allowsInstallationCompletion = launchedBundleURL.map {
            isInstallationCompletionHandoff(
                launchedBundleURL: $0,
                launchedBuildID: launchedBuildID,
                requestedBuildID: requestedBuildID,
                requestedBundleURL: requestedBundleURL,
                expectedBundleIdentifier: expectedBundleIdentifier,
                canonicalBundleURL: canonicalBundleURL
            )
        } ?? false
        guard let candidate = validatedCandidate(
            launchedBuildID: launchedBuildID,
            requestedBuildID: requestedBuildID,
            requestedBundleURL: requestedBundleURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            allowsSameBuildID: allowsInstallationCompletion
        ) else { return false }
        return !candidate.requiresCanonicalInstallation
            || AppInstallationPolicy.isCanonicalBundle(
                candidate.bundleURL,
                canonicalBundleURL: canonicalBundleURL
            )
    }

    static func manualInstallationRequest(
        launchedBuildID: String?,
        requestedBuildID: String,
        requestedBundleURL: URL,
        expectedBundleIdentifier: String,
        canonicalBundleURL: URL = AppInstallationPolicy.canonicalBundleURL
    ) -> AppManualInstallationRequest? {
        guard let candidate = validatedCandidate(
            launchedBuildID: launchedBuildID,
            requestedBuildID: requestedBuildID,
            requestedBundleURL: requestedBundleURL,
            expectedBundleIdentifier: expectedBundleIdentifier
        ), candidate.requiresCanonicalInstallation,
           !AppInstallationPolicy.isCanonicalBundle(
            candidate.bundleURL,
            canonicalBundleURL: canonicalBundleURL
        ) else { return nil }
        return AppManualInstallationRequest(
            origin: .secondaryDownloadedBuild,
            version: candidate.version,
            candidateBundlePath: candidate.bundleURL.path
        )
    }

    private struct ValidatedCandidate {
        let bundleURL: URL
        let buildID: String
        let version: String?
        let requiresCanonicalInstallation: Bool
    }

    private static func validatedCandidate(
        launchedBuildID: String?,
        requestedBuildID: String,
        requestedBundleURL: URL,
        expectedBundleIdentifier: String,
        allowsSameBuildID: Bool = false
    ) -> ValidatedCandidate? {
        let requestedBuildID = requestedBuildID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let launchedBuildID,
              !launchedBuildID.isEmpty,
              !requestedBuildID.isEmpty,
              launchedBuildID != requestedBuildID || allowsSameBuildID,
              requestedBundleURL.pathExtension == "app",
              installedBuildID(at: requestedBundleURL) == requestedBuildID,
              installedInfoDictionary(at: requestedBundleURL)?["CFBundleIdentifier"] as? String
                == expectedBundleIdentifier
        else { return nil }
        let bundleURL = requestedBundleURL.standardizedFileURL
        let info = installedInfoDictionary(at: bundleURL)
        let version = (
            info?["CFBundleShortVersionString"] as? String
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let infoReleaseChannel = (
            info?["APCReleaseChannel"] as? String
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifestURL = bundleURL.appendingPathComponent(
            "Contents/Resources/runtime-manifest.json"
        )
        let manifest = try? RuntimeReleaseManifest.read(from: manifestURL)
        let claimsRelease = infoReleaseChannel == "release"
            || manifest?.releaseChannel == "release"
        if claimsRelease {
            guard infoReleaseChannel == "release",
                  manifest?.releaseChannel == "release",
                  manifest?.buildID == requestedBuildID,
                  manifest?.appVersion == version,
                  manifest?.appBuild == (
                    info?["CFBundleVersion"] as? String
                  )?.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return nil }
        }
        return ValidatedCandidate(
            bundleURL: bundleURL,
            buildID: requestedBuildID,
            version: version.flatMap { $0.isEmpty ? nil : $0 },
            requiresCanonicalInstallation: claimsRelease
        )
    }

    static func isStillValidHandoffTarget(
        bundleURL: URL,
        expectedBuildID: String,
        expectedVersion: String?,
        expectedBundleIdentifier: String,
        requiresRelease: Bool,
        canonicalBundleURL: URL = AppInstallationPolicy.canonicalBundleURL
    ) -> Bool {
        let bundleURL = bundleURL.standardizedFileURL
        guard bundleURL.pathExtension == "app",
              let info = installedInfoDictionary(at: bundleURL),
              info["APCBuildID"] as? String == expectedBuildID,
              info["CFBundleIdentifier"] as? String == expectedBundleIdentifier
        else { return false }

        let version = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let expectedVersion, version != expectedVersion {
            return false
        }

        if requiresRelease {
            return AppInstallationPolicy.isCanonicalBundle(
                bundleURL,
                canonicalBundleURL: canonicalBundleURL
            ) && isValidatedReleaseBundle(
                at: bundleURL,
                expectedBuildID: expectedBuildID,
                expectedBundleIdentifier: expectedBundleIdentifier
            )
        }

        let infoReleaseChannel = (info["APCReleaseChannel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = try? RuntimeReleaseManifest.read(
            from: bundleURL.appendingPathComponent(
                "Contents/Resources/runtime-manifest.json"
            )
        )
        return infoReleaseChannel != "release"
            && manifest?.releaseChannel != "release"
    }

    private static func isInstallationCompletionHandoff(
        launchedBundleURL: URL,
        launchedBuildID: String?,
        requestedBuildID: String,
        requestedBundleURL: URL,
        expectedBundleIdentifier: String,
        canonicalBundleURL: URL = AppInstallationPolicy.canonicalBundleURL
    ) -> Bool {
        guard let launchedBuildID,
              !launchedBuildID.isEmpty,
              launchedBuildID == requestedBuildID,
              !AppInstallationPolicy.isCanonicalBundle(
                launchedBundleURL,
                canonicalBundleURL: canonicalBundleURL
              ),
              AppInstallationPolicy.isCanonicalBundle(
                requestedBundleURL,
                canonicalBundleURL: canonicalBundleURL
              )
        else { return false }
        return isValidatedReleaseBundle(
            at: launchedBundleURL,
            expectedBuildID: launchedBuildID,
            expectedBundleIdentifier: expectedBundleIdentifier
        ) && isValidatedReleaseBundle(
            at: requestedBundleURL,
            expectedBuildID: requestedBuildID,
            expectedBundleIdentifier: expectedBundleIdentifier
        )
    }

    static func invalidReleaseBundleRequest(
        requestedBuildID: String,
        requestedBundleURL: URL,
        expectedBundleIdentifier: String
    ) -> AppManualInstallationRequest? {
        let requestedBuildID = requestedBuildID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !requestedBuildID.isEmpty,
              requestedBundleURL.pathExtension == "app",
              let info = installedInfoDictionary(at: requestedBundleURL),
              info["APCReleaseChannel"] as? String == "release",
              info["APCBuildID"] as? String == requestedBuildID,
              info["CFBundleIdentifier"] as? String == expectedBundleIdentifier,
              !isValidatedReleaseBundle(
                at: requestedBundleURL,
                expectedBuildID: requestedBuildID,
                expectedBundleIdentifier: expectedBundleIdentifier
              )
        else { return nil }
        let version = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AppManualInstallationRequest(
            origin: .invalidReleaseBundle,
            version: version.flatMap { $0.isEmpty ? nil : $0 },
            candidateBundlePath: requestedBundleURL.standardizedFileURL.path
        )
    }

    private static func isValidatedReleaseBundle(
        at bundleURL: URL,
        expectedBuildID: String,
        expectedBundleIdentifier: String
    ) -> Bool {
        guard let info = installedInfoDictionary(at: bundleURL),
              info["APCReleaseChannel"] as? String == "release",
              info["APCBuildID"] as? String == expectedBuildID,
              info["CFBundleIdentifier"] as? String == expectedBundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String,
              let manifest = try? RuntimeReleaseManifest.read(
                from: bundleURL.appendingPathComponent(
                    "Contents/Resources/runtime-manifest.json"
                )
              )
        else { return false }
        return manifest.releaseChannel == "release"
            && manifest.buildID == expectedBuildID
            && manifest.appVersion == version
            && manifest.appBuild == build
    }

    private static func installedInfoDictionary(at bundleURL: URL) -> [String: Any]? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else { return nil }
        return plist
    }
}
