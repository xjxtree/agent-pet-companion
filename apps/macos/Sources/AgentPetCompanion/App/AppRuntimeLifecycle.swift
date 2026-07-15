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
    static let shared = AppUpdateHandoffCoordinator()

    private let bundleURL: URL
    private let launchedBuildID: String?
    private let launchedBundleIdentifier: String
    private var handoffScheduled = false

    init(bundle: Bundle = .main) {
        bundleURL = bundle.bundleURL
        launchedBuildID = (bundle.object(forInfoDictionaryKey: "APCBuildID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        launchedBundleIdentifier = bundle.bundleIdentifier ?? "dev.agentpet.companion"
    }

    func restartIfInstalledBuildChanged() -> Bool {
        guard !handoffScheduled,
              Self.buildChanged(
                  launchedBuildID: launchedBuildID,
                  installedBuildID: Self.installedBuildID(at: bundleURL)
              )
        else { return false }

        return scheduleRestart(at: bundleURL)
    }

    func restartForRequestedBuildIfNeeded(_ request: AppActivationRequest?) -> Bool {
        guard !handoffScheduled,
              let request,
              Self.shouldHandoff(
                  launchedBuildID: launchedBuildID,
                  requestedBuildID: request.buildID,
                  requestedBundleURL: URL(fileURLWithPath: request.bundlePath, isDirectory: true),
                  expectedBundleIdentifier: launchedBundleIdentifier
              )
        else { return false }

        return scheduleRestart(
            at: URL(fileURLWithPath: request.bundlePath, isDirectory: true).standardizedFileURL
        )
    }

    private func scheduleRestart(at targetBundleURL: URL) -> Bool {
        guard !handoffScheduled else { return false }
        handoffScheduled = true
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.05; done; /bin/sleep 0.5; exec /usr/bin/open \"$2\"",
            "agent-pet-update-handoff",
            String(getpid()),
            targetBundleURL.path
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            NSApp.terminate(nil)
            return true
        } catch {
            handoffScheduled = false
            return false
        }
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
        expectedBundleIdentifier: String
    ) -> Bool {
        let requestedBuildID = requestedBuildID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let launchedBuildID,
              !launchedBuildID.isEmpty,
              !requestedBuildID.isEmpty,
              launchedBuildID != requestedBuildID,
              requestedBundleURL.pathExtension == "app",
              installedBuildID(at: requestedBundleURL) == requestedBuildID,
              installedInfoDictionary(at: requestedBundleURL)?["CFBundleIdentifier"] as? String
                == expectedBundleIdentifier
        else { return false }
        return true
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
