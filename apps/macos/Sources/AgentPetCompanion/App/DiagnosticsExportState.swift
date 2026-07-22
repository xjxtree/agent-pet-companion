import Foundation

struct PreparedDiagnosticsArchive: Equatable {
    let stagedURL: URL
    let suggestedFileName: String
}

enum DiagnosticsExportPrimaryAction: Equatable {
    case prepare
    case save
}

enum DiagnosticsExportState: Equatable {
    case idle
    case exporting
    case ready(PreparedDiagnosticsArchive)
    case saving(PreparedDiagnosticsArchive)
    case succeeded(String)
    case failed(String)
    case saveFailed(PreparedDiagnosticsArchive, String)

    var primaryAction: DiagnosticsExportPrimaryAction? {
        switch self {
        case .idle, .succeeded, .failed:
            .prepare
        case .ready, .saveFailed:
            .save
        case .exporting, .saving:
            nil
        }
    }

    var preparedArchive: PreparedDiagnosticsArchive? {
        switch self {
        case let .ready(archive), let .saving(archive), let .saveFailed(archive, _):
            archive
        case .idle, .exporting, .succeeded, .failed:
            nil
        }
    }

    /// Retains the bounded internal result for compatibility with existing
    /// callers. UI surfaces should prefer `displayMessage(locale:)` so a
    /// localized global status string never becomes state.
    var message: String? {
        switch self {
        case .idle:
            nil
        case .exporting:
            APCLocalization.text(.diagnosticsExportingMessage)
        case let .ready(archive), let .saving(archive):
            archive.suggestedFileName
        case let .succeeded(message), let .failed(message), let .saveFailed(_, message):
            message
        }
    }

    func displayMessage(
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        switch self {
        case .idle:
            nil
        case .exporting:
            APCLocalization.text(.diagnosticsExportingMessage, locale: locale)
        case .ready:
            "\(APCLocalization.text(.diagnosticsPackageTitle, locale: locale)) · "
                + APCLocalization.text(.overlayStatusReady, locale: locale)
        case .saving:
            nil
        case .succeeded:
            APCLocalization.text(.diagnosticsExportSucceededMessage, locale: locale)
        case .failed, .saveFailed:
            APCLocalization.text(.diagnosticsExportFailedMessage, locale: locale)
        }
    }
}
