enum PetCoreOperationalState: String, Equatable, Sendable {
    case checking
    case recovering
    case online
    case offline
    case runtimeMismatch
    case error

    static func failure(for code: PetCoreServiceFailureCode) -> Self {
        switch code {
        case .candidateHealthFailed, .updateRollbackFailed:
            .runtimeMismatch
        case .petCoreBinaryMissing,
             .cliMissing,
             .launchAgentDisabled,
             .launchctlFailed,
             .directLaunchFailed:
            .offline
        case .runtimePathsFailed, .unknown, .none:
            .error
        }
    }
}
