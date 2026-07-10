import AgentPetCompanionCore
import Darwin
import Foundation

@main
struct AgentPetCompanionUIValidationMain {
    static func main() async {
        do {
            _ = FrameScheduler(fps: 12, frameCount: 1)
            let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
            let appExecutable = executableDirectory.appendingPathComponent("AgentPetCompanion")
            guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
                throw UIValidationRunnerError.missingApp(appExecutable.path)
            }

            let result = try await BoundedProcessRunner.run(
                executableURL: appExecutable,
                arguments: ["--run-ui-validation"],
                timeout: .seconds(15),
                outputLimit: 64 * 1_024
            )
            FileHandle.standardOutput.write(result.standardOutput)
            FileHandle.standardError.write(result.standardError)
            switch result.termination {
            case .exited(status: 0):
                break
            case let .exited(status):
                throw UIValidationRunnerError.childFailed(status)
            case .timedOut:
                throw UIValidationRunnerError.timedOut
            }
            try validateOutput(result.standardOutput)
        } catch {
            fputs("AgentPetCompanionUIValidation failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func validateOutput(_ data: Data) throws {
        let output = String(decoding: data, as: UTF8.self)
        let passCount = output.split(separator: "\n").filter { $0.hasPrefix("PASS ") }.count
        guard let summary = output.split(separator: "\n").last(where: {
            $0.hasPrefix("AgentPetCompanionUIValidation ok: ")
        }) else {
            throw UIValidationRunnerError.missingSummary
        }
        let prefix = "AgentPetCompanionUIValidation ok: "
        let countToken = summary.dropFirst(prefix.count).split(separator: " ").first ?? ""
        let counts = countToken.split(separator: "/").compactMap { Int($0) }
        guard counts.count == 2, counts[0] > 0, counts[0] == counts[1], passCount == counts[0] else {
            throw UIValidationRunnerError.invalidSummary(String(summary))
        }
    }
}

private enum UIValidationRunnerError: LocalizedError {
    case missingApp(String)
    case childFailed(Int32)
    case timedOut
    case missingSummary
    case invalidSummary(String)

    var errorDescription: String? {
        switch self {
        case let .missingApp(path):
            "AgentPetCompanion executable is missing at \(path)"
        case let .childFailed(status):
            "AgentPetCompanion validation mode exited with status \(status)"
        case .timedOut:
            "AgentPetCompanion validation mode exceeded the 15-second deadline"
        case .missingSummary:
            "AgentPetCompanion validation output did not include a summary"
        case let .invalidSummary(summary):
            "AgentPetCompanion validation output had an invalid check count: \(summary)"
        }
    }
}
