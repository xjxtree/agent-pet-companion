import AppKit
import Darwin
import Foundation

private enum LifecycleClient {
    static let appBundleIdentifier = "dev.agentpet.companion"
    static let quitArgument = "--quit-running-app"
    static let quitTimeout: TimeInterval = 10
    static let pollInterval: TimeInterval = 0.05

    static var instanceLockURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return applicationSupport
            .appendingPathComponent("AgentPetCompanion", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("app-instance.lock")
    }

    static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        guard arguments.dropFirst() == [quitArgument] else {
            fputs("usage: AgentPetCompanionLifecycleClient --quit-running-app\n", stderr)
            return 2
        }

        let deadline = Date().addingTimeInterval(quitTimeout)
        var requestedProcessIdentifiers = Set<pid_t>()

        while Date() < deadline {
            let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: appBundleIdentifier)
                .filter { !$0.isTerminated }

            if running.isEmpty, primaryInstanceLockIsFree() {
                if requestedProcessIdentifiers.isEmpty {
                    print("Agent Pet Companion is not running")
                } else {
                    print("Agent Pet Companion exited normally")
                }
                return 0
            }

            for application in running
                where requestedProcessIdentifiers.insert(application.processIdentifier).inserted
            {
                // This is the same normal AppKit termination request used by
                // the system Quit action. Never escalate to forceTerminate().
                // A false result can also mean the process exited between the
                // lookup and request, so the bounded wait below is authoritative.
                _ = application.terminate()
            }

            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }

        let remaining = NSRunningApplication
            .runningApplications(withBundleIdentifier: appBundleIdentifier)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier)
            .sorted()
        let lockIsFree = primaryInstanceLockIsFree()
        guard !remaining.isEmpty || !lockIsFree else {
            print("Agent Pet Companion exited normally")
            return 0
        }
        fputs(
            "timed out waiting for Agent Pet Companion to exit normally; "
                + "remaining pids: \(remaining), instance lock: "
                + "\(lockIsFree ? "free" : "held")\n",
            stderr
        )
        return 1
    }

    private static func primaryInstanceLockIsFree() -> Bool {
        let descriptor = Darwin.open(instanceLockURL.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        _ = flock(descriptor, LOCK_UN)
        return true
    }
}

exit(LifecycleClient.run())
