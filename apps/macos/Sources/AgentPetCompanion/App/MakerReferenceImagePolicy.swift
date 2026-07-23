import AgentPetCompanionCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MakerReferenceImageIssue: Error, Equatable, Sendable {
    case tooMany
    case unsupportedFormat
    case unavailable
    case tooLarge
    case totalTooLarge
    case tooManyPixels
    case invalidContent
    case reselectionRequired(Int)
}

struct MakerReferenceImageAdmission: Equatable, Sendable {
    let acceptedPaths: [String]
    let issue: MakerReferenceImageIssue?
}

/// Mirrors the public reference-image limits enforced authoritatively by
/// PetCore. This policy provides immediate field feedback; PetCore still
/// reopens and validates every selected file before it enters a job workspace.
enum MakerReferenceImagePolicy {
    static let maximumCount = 4
    static let maximumFileBytes: UInt64 = 20 * 1_024 * 1_024
    static let maximumTotalBytes: UInt64 = 40 * 1_024 * 1_024
    static let maximumPixels: UInt64 = 16_000_000

    private struct ValidatedImage {
        let path: String
        let bytes: UInt64
    }

    static func admit(existingPaths: [String], urls: [URL]) -> MakerReferenceImageAdmission {
        var paths = existingPaths
        var knownPaths = Set(existingPaths)
        var totalBytes = existingPaths.reduce(into: UInt64.zero) { total, path in
            total = total.addingWithoutOverflow(fileBytes(at: URL(fileURLWithPath: path)))
        }
        var firstIssue: MakerReferenceImageIssue?

        for url in urls {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            guard !knownPaths.contains(path) else { continue }
            guard paths.count < maximumCount else {
                firstIssue = firstIssue ?? .tooMany
                continue
            }

            switch validate(standardized) {
            case let .success(image):
                guard totalBytes <= maximumTotalBytes - min(image.bytes, maximumTotalBytes) else {
                    firstIssue = firstIssue ?? .totalTooLarge
                    continue
                }
                totalBytes += image.bytes
                paths.append(image.path)
                knownPaths.insert(image.path)
            case let .failure(issue):
                firstIssue = firstIssue ?? issue
            }
        }

        return MakerReferenceImageAdmission(
            acceptedPaths: Array(paths.dropFirst(existingPaths.count)),
            issue: firstIssue
        )
    }

    static func issue(for paths: [String]) -> MakerReferenceImageIssue? {
        guard paths.count <= maximumCount else { return .tooMany }
        var totalBytes = UInt64.zero
        for path in paths {
            switch validate(URL(fileURLWithPath: path)) {
            case let .success(image):
                guard totalBytes <= maximumTotalBytes - min(image.bytes, maximumTotalBytes) else {
                    return .totalTooLarge
                }
                totalBytes += image.bytes
            case let .failure(issue):
                return issue
            }
        }
        return nil
    }

    static func validatedPath(for url: URL) -> String? {
        guard case let .success(image) = validate(url.standardizedFileURL) else { return nil }
        return image.path
    }

    static func validatedRecoveryProjectionPath(
        _ rawPath: String,
        jobID: String,
        index: Int
    ) -> String? {
        guard !jobID.isEmpty,
              URL(fileURLWithPath: jobID).lastPathComponent == jobID,
              !jobID.contains("/"),
              !jobID.contains("\\"),
              index >= 0
        else { return nil }

        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard url.path == rawPath,
              url.path.hasPrefix("/"),
              url.resolvingSymlinksInPath().path == url.path
        else { return nil }

        let components = url.pathComponents
        guard components.count >= 6 else { return nil }
        let suffix = Array(components.suffix(5))
        guard suffix[0] == "generation-jobs",
              suffix[1] == jobID,
              suffix[2] == "input",
              suffix[3] == "references"
        else { return nil }
        let expectedStem = String(format: "reference-%02d", index)
        let leaf = URL(fileURLWithPath: suffix[4])
        guard leaf.deletingPathExtension().lastPathComponent == expectedStem,
              ["png", "webp"].contains(leaf.pathExtension.lowercased())
        else { return nil }
        return validatedPath(for: url)
    }

    private static func validate(_ url: URL) -> Result<ValidatedImage, MakerReferenceImageIssue> {
        guard url.isFileURL else { return .failure(.unavailable) }
        let extensionName = url.pathExtension.lowercased()
        let expectedType: UTType
        switch extensionName {
        case "png":
            expectedType = .png
        case "webp":
            expectedType = .webP
        default:
            return .failure(.unsupportedFormat)
        }

        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        FileManager.default.isReadableFile(atPath: url.path)
        else {
            return .failure(.unavailable)
        }

        let bytes = UInt64(max(0, values.fileSize ?? 0))
        guard bytes <= maximumFileBytes else { return .failure(.tooLarge) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let actualIdentifier = CGImageSourceGetType(source) as String?,
              actualIdentifier == expectedType.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value,
              width > 0,
              height > 0
        else {
            return .failure(.invalidContent)
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maximumPixels else { return .failure(.tooManyPixels) }
        return .success(ValidatedImage(path: url.standardizedFileURL.path, bytes: bytes))
    }

    private static func fileBytes(at url: URL) -> UInt64 {
        let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return UInt64(max(0, value ?? 0))
    }
}

extension APCLocalizedPresentation {
    static func referenceImageIssue(
        _ issue: MakerReferenceImageIssue,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        if case let .reselectionRequired(count) = issue {
            return APCLocalization.format(
                .studioReferencesIssueReselectionRequiredFormat,
                locale: locale,
                count
            )
        }
        let key: APCLocalizationKey = switch issue {
        case .tooMany: .studioReferencesIssueTooMany
        case .unsupportedFormat: .studioReferencesIssueUnsupported
        case .unavailable: .studioReferencesIssueUnavailable
        case .tooLarge: .studioReferencesIssueTooLarge
        case .totalTooLarge: .studioReferencesIssueTotalTooLarge
        case .tooManyPixels: .studioReferencesIssueTooManyPixels
        case .invalidContent: .studioReferencesIssueInvalidContent
        case .reselectionRequired: .studioReferencesIssueReselectionRequiredFormat
        }
        return APCLocalization.text(key, locale: locale)
    }
}

/// Keeps the App's draft boundary identical to PetCore's Rust `char` count:
/// both count Unicode scalar values, not user-perceived grapheme clusters.
/// This avoids accepting a visually short string made from many combining
/// scalars only for PetCore to reject it after submission.
enum GenerationPromptPolicy {
    static let maximumScalarCount = AIPetMakerDefaults.maximumDescriptionCharacters

    static func scalarCount(_ value: String) -> Int {
        value.unicodeScalars.count
    }

    static func truncate(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count > maximumScalarCount else { return value }
        let end = scalars.index(scalars.startIndex, offsetBy: maximumScalarCount)
        return String(String.UnicodeScalarView(scalars[..<end]))
    }

    static func isValid(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && scalarCount(value) <= maximumScalarCount
    }
}

private extension UInt64 {
    func addingWithoutOverflow(_ value: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(value)
        return overflow ? .max : sum
    }
}

enum PetStudioDraftPolicy {
    static func retryForm(
        session: GenerationSession,
        descriptionText: String,
        style: StylePreset,
        quality: QualityLevel,
        referenceImages: [String],
        nativeFPS: Int = PetAnimationContract.defaultNativeFPS,
        stateDurationsMS: [String: Int] = PetAnimationContract.defaultStateDurationsMS
    ) -> GenerationForm? {
        guard session.canRetry, let submittedForm = session.submittedForm else { return nil }
        if session.operation == .modify {
            return submittedForm
        }
        let description = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GenerationPromptPolicy.isValid(description),
              MakerReferenceImagePolicy.issue(for: referenceImages) == nil
        else {
            return nil
        }
        return GenerationForm(
            description: description,
            style: style.rawValue,
            quality: quality,
            referenceImages: referenceImages,
            nativeFPS: nativeFPS,
            stateDurationsMS: stateDurationsMS
        )
    }
}

enum GenerationRetryRequestPolicy {
    /// PetCore owns the immutable form and edit context for modification retries.
    /// Omitting the optional form avoids racing a not-yet-reconciled local snapshot
    /// against the historical revision that the server accepted.
    static func includesForm(for operation: GenerationOperation) -> Bool {
        operation == .create
    }
}
