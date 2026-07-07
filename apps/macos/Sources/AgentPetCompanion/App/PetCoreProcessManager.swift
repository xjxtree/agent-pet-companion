import Foundation

final class PetCoreProcessManager {
    private var process: Process?

    func startIfNeeded() {
        guard process == nil else { return }
        guard let executable = locatePetCore() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["RUST_LOG"] = "info"
        process.environment = environment
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
        }
    }

    private func locatePetCore() -> String? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("bin/petcore")
            .path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("../../target/debug/petcore").standardized.path,
            cwd.appendingPathComponent("target/debug/petcore").standardized.path
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
