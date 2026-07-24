import Foundation

enum AppUpdateCheckTrigger: Equatable, Sendable {
    case automatic
    case manual
}

enum AppUpdateCheckFreshness: Equatable, Sendable {
    case fetched
    case notModified
}

enum AppUpdateCheckPresentation: Equatable, Sendable {
    case none
    case checking
    case updateAvailable
    case upToDate
    case failure
}

enum AppUpdateCheckFailure: Equatable, Sendable {
    case invalidCurrentVersion
    case transport
    case unexpectedHTTPStatus(Int)
    case invalidResponse
    case draftRelease
    case prerelease
    case invalidReleaseVersion
    case invalidReleaseURL
    case invalidAssetInventory
    case missingArchitectureAsset(AppReleaseArchitecture)
    case ambiguousArchitectureAssets(AppReleaseArchitecture)
    case invalidAsset
    case notModifiedWithoutCachedRelease
    case downloadOpenFailed
}

enum AppUpdateCheckState: Equatable, Sendable {
    case idle
    case checking(AppUpdateCheckTrigger)
    case updateAvailable(
        trigger: AppUpdateCheckTrigger,
        release: AppReleaseUpdate,
        freshness: AppUpdateCheckFreshness
    )
    case upToDate(
        trigger: AppUpdateCheckTrigger,
        latestVersion: StableSemanticVersion,
        freshness: AppUpdateCheckFreshness
    )
    case failed(trigger: AppUpdateCheckTrigger, failure: AppUpdateCheckFailure)

    var presentation: AppUpdateCheckPresentation {
        switch self {
        case .idle:
            .none
        case let .checking(trigger):
            trigger == .manual ? .checking : .none
        case .updateAvailable:
            .updateAvailable
        case let .upToDate(trigger, _, _):
            trigger == .manual ? .upToDate : .none
        case let .failed(trigger, _):
            trigger == .manual ? .failure : .none
        }
    }
}

struct StableSemanticVersion: Codable, Comparable, CustomStringConvertible, Equatable, Sendable {
    let major: UInt64
    let minor: UInt64
    let patch: UInt64

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    init?(appVersion value: String) {
        guard let parsed = Self.parse(value) else { return nil }
        self = parsed
    }

    init?(releaseTag value: String) {
        guard value.hasPrefix("v"),
              let parsed = Self.parse(String(value.dropFirst()))
        else { return nil }
        self = parsed
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    private static func parse(_ value: String) -> Self? {
        guard value.range(
            of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = UInt64(parts[0]),
              let minor = UInt64(parts[1]),
              let patch = UInt64(parts[2])
        else {
            return nil
        }
        return Self(major: major, minor: minor, patch: patch)
    }

    private init(major: UInt64, minor: UInt64, patch: UInt64) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

enum AppReleaseArchitecture: String, CaseIterable, Codable, Equatable, Sendable {
    case arm64
    case x86_64

    static var current: Self {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        #error("Agent Pet Companion releases support only arm64 and x86_64")
        #endif
    }
}

struct AppReleaseAsset: Codable, Equatable, Sendable {
    let fileName: String
    let architecture: AppReleaseArchitecture
    let downloadURL: URL
    let size: Int64
    let sha256: String
}

struct AppReleaseUpdate: Codable, Equatable, Sendable {
    let version: StableSemanticVersion
    let tagName: String
    let releaseName: String?
    let releasePageURL: URL
    let asset: AppReleaseAsset
}

struct GitHubReleaseUpdateCacheSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let etag: String?
    let release: AppReleaseUpdate

    init(etag: String?, release: AppReleaseUpdate) {
        schemaVersion = Self.schemaVersion
        self.etag = etag
        self.release = release
    }
}

struct GitHubReleaseHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    func header(named name: String) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

protocol GitHubReleaseHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> GitHubReleaseHTTPResponse
}

struct URLSessionGitHubReleaseHTTPClient: GitHubReleaseHTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> GitHubReleaseHTTPResponse {
        let (body, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubReleaseHTTPClientError.nonHTTPResponse
        }
        let headers = httpResponse.allHeaderFields.reduce(
            into: [String: String]()
        ) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        return GitHubReleaseHTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: body
        )
    }
}

private enum GitHubReleaseHTTPClientError: Error {
    case nonHTTPResponse
}

actor GitHubReleaseUpdateChecker {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/xjxtree/agent-pet-companion/releases/latest"
    )!

    private let client: any GitHubReleaseHTTPClient
    private let latestReleaseURL: URL
    private let architecture: AppReleaseArchitecture
    private var cachedRelease: GitHubReleaseUpdateCacheSnapshot?

    private(set) var state: AppUpdateCheckState = .idle

    init(
        client: any GitHubReleaseHTTPClient = URLSessionGitHubReleaseHTTPClient(),
        latestReleaseURL: URL = GitHubReleaseUpdateChecker.latestReleaseURL,
        architecture: AppReleaseArchitecture = .current,
        cacheSnapshot: GitHubReleaseUpdateCacheSnapshot? = nil
    ) {
        self.client = client
        self.latestReleaseURL = latestReleaseURL
        self.architecture = architecture
        cachedRelease = cacheSnapshot.flatMap {
            Self.validatedCacheSnapshot($0, architecture: architecture)
        }
    }

    @discardableResult
    func check(
        currentVersion: String,
        trigger: AppUpdateCheckTrigger
    ) async -> AppUpdateCheckState {
        state = .checking(trigger)

        guard let currentVersion = StableSemanticVersion(appVersion: currentVersion) else {
            return finish(.failed(trigger: trigger, failure: .invalidCurrentVersion))
        }

        do {
            var request = URLRequest(url: latestReleaseURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("AgentPetCompanion", forHTTPHeaderField: "User-Agent")
            if let etag = cachedRelease?.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            let response = try await client.send(request)
            let release: AppReleaseUpdate
            let freshness: AppUpdateCheckFreshness

            switch response.statusCode {
            case 200:
                release = try decodeRelease(from: response.body)
                cachedRelease = GitHubReleaseUpdateCacheSnapshot(
                    etag: normalizedETag(response.header(named: "ETag")),
                    release: release
                )
                freshness = .fetched
            case 304:
                guard let cachedRelease else {
                    return finish(
                        .failed(
                            trigger: trigger,
                            failure: .notModifiedWithoutCachedRelease
                        )
                    )
                }
                release = cachedRelease.release
                freshness = .notModified
            default:
                return finish(
                    .failed(
                        trigger: trigger,
                        failure: .unexpectedHTTPStatus(response.statusCode)
                    )
                )
            }

            if release.version > currentVersion {
                return finish(
                    .updateAvailable(
                        trigger: trigger,
                        release: release,
                        freshness: freshness
                    )
                )
            }
            return finish(
                .upToDate(
                    trigger: trigger,
                    latestVersion: release.version,
                    freshness: freshness
                )
            )
        } catch let error as ReleaseValidationError {
            return finish(.failed(trigger: trigger, failure: error.failure))
        } catch {
            return finish(.failed(trigger: trigger, failure: .transport))
        }
    }

    func resetCache() {
        cachedRelease = nil
        state = .idle
    }

    func exportedCacheSnapshot() -> GitHubReleaseUpdateCacheSnapshot? {
        cachedRelease
    }

    private func finish(_ nextState: AppUpdateCheckState) -> AppUpdateCheckState {
        state = nextState
        return nextState
    }

    private func decodeRelease(from data: Data) throws -> AppReleaseUpdate {
        guard !data.isEmpty, data.count <= 1_048_576 else {
            throw ReleaseValidationError(.invalidResponse)
        }
        let payload: GitHubLatestRelease
        do {
            payload = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
        } catch {
            throw ReleaseValidationError(.invalidResponse)
        }

        guard !payload.draft else {
            throw ReleaseValidationError(.draftRelease)
        }
        guard !payload.prerelease else {
            throw ReleaseValidationError(.prerelease)
        }
        guard let version = StableSemanticVersion(releaseTag: payload.tagName) else {
            throw ReleaseValidationError(.invalidReleaseVersion)
        }
        let expectedReleasePage =
            "https://github.com/xjxtree/agent-pet-companion/releases/tag/\(payload.tagName)"
        guard payload.htmlURL == expectedReleasePage,
              let releasePageURL = secureURL(payload.htmlURL)
        else {
            throw ReleaseValidationError(.invalidReleaseURL)
        }

        let expectedFileName =
            "AgentPetCompanion-\(version)-macos-\(architecture.rawValue).zip"
        let matches = payload.assets.filter { asset in
            asset.name == expectedFileName
        }
        guard !matches.isEmpty else {
            throw ReleaseValidationError(.missingArchitectureAsset(architecture))
        }
        guard matches.count == 1, let payloadAsset = matches.first else {
            throw ReleaseValidationError(.ambiguousArchitectureAssets(architecture))
        }
        let expectedAssetNames = Set([
            "AgentPetCompanion-\(version)-macos-\(AppReleaseArchitecture.arm64.rawValue).zip",
            "AgentPetCompanion-\(version)-macos-\(AppReleaseArchitecture.x86_64.rawValue).zip",
            "AgentPetCompanion-\(version)-SHA256SUMS.txt"
        ])
        guard payload.assets.count == expectedAssetNames.count,
              Set(payload.assets.map(\.name)) == expectedAssetNames
        else {
            throw ReleaseValidationError(.invalidAssetInventory)
        }
        let expectedDownloadURL =
            "https://github.com/xjxtree/agent-pet-companion/releases/download/"
            + "\(payload.tagName)/\(expectedFileName)"
        guard payloadAsset.state == "uploaded",
              payloadAsset.size > 0,
              payloadAsset.browserDownloadURL == expectedDownloadURL,
              let downloadURL = secureURL(payloadAsset.browserDownloadURL),
              let sha256 = normalizedSHA256(payloadAsset.digest)
        else {
            throw ReleaseValidationError(.invalidAsset)
        }

        return AppReleaseUpdate(
            version: version,
            tagName: payload.tagName,
            releaseName: normalizedOptionalText(payload.name),
            releasePageURL: releasePageURL,
            asset: AppReleaseAsset(
                fileName: payloadAsset.name,
                architecture: architecture,
                downloadURL: downloadURL,
                size: payloadAsset.size,
                sha256: sha256
            )
        )
    }

    private func secureURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else {
            return nil
        }
        return url
    }

    private func normalizedSHA256(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let prefix = "sha256:"
        guard digest.hasPrefix(prefix) else { return nil }
        let value = String(digest.dropFirst(prefix.count))
        guard value.range(
            of: #"^[A-Fa-f0-9]{64}$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return value.lowercased()
    }

    private func normalizedETag(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isValidCachedETag(trimmed) ? trimmed : nil
    }

    private func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func validatedCacheSnapshot(
        _ snapshot: GitHubReleaseUpdateCacheSnapshot,
        architecture: AppReleaseArchitecture
    ) -> GitHubReleaseUpdateCacheSnapshot? {
        guard snapshot.schemaVersion == GitHubReleaseUpdateCacheSnapshot.schemaVersion,
              snapshot.release.tagName == "v\(snapshot.release.version)",
              snapshot.release.releasePageURL.absoluteString
                  == "https://github.com/xjxtree/agent-pet-companion/releases/tag/"
                  + snapshot.release.tagName,
              snapshot.release.asset.architecture == architecture
        else {
            return nil
        }

        let expectedFileName =
            "AgentPetCompanion-\(snapshot.release.version)-macos-\(architecture.rawValue).zip"
        let expectedDownloadURL =
            "https://github.com/xjxtree/agent-pet-companion/releases/download/"
            + "\(snapshot.release.tagName)/\(expectedFileName)"
        guard snapshot.release.asset.fileName == expectedFileName,
              snapshot.release.asset.downloadURL.absoluteString == expectedDownloadURL,
              snapshot.release.asset.size > 0,
              snapshot.release.asset.sha256.range(
                  of: #"^[a-f0-9]{64}$"#,
                  options: .regularExpression
              ) != nil,
              isValidCachedETag(snapshot.etag)
        else {
            return nil
        }
        return snapshot
    }

    private static func isValidCachedETag(_ value: String?) -> Bool {
        guard let value else { return true }
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }
}

private struct GitHubLatestRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAssetPayload]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubReleaseAssetPayload: Decodable {
    let name: String
    let state: String
    let size: Int64
    let digest: String?
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case state
        case size
        case digest
        case browserDownloadURL = "browser_download_url"
    }
}

private struct ReleaseValidationError: Error {
    let failure: AppUpdateCheckFailure

    init(_ failure: AppUpdateCheckFailure) {
        self.failure = failure
    }
}
