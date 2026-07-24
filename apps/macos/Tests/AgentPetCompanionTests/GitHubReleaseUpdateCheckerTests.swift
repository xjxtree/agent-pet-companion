import Foundation
import Testing
@testable import AgentPetCompanion

@Suite
struct GitHubReleaseUpdateCheckerTests {
    @Test
    func fetchedStableReleaseSelectsTheExactArchitectureAsset() async throws {
        let response = try releaseResponse(
            version: "1.3.0",
            assets: [
                releaseAsset(version: "1.3.0", architecture: .x86_64),
                checksumAsset(version: "1.3.0"),
                releaseAsset(version: "1.3.0", architecture: .arm64)
            ],
            headers: ["ETag": #""release-1.3.0""#]
        )
        let client = StubGitHubReleaseHTTPClient([.response(response)])
        let checker = GitHubReleaseUpdateChecker(client: client, architecture: .arm64)

        let state = await checker.check(currentVersion: "1.2.9", trigger: .automatic)

        guard case let .updateAvailable(trigger, release, freshness) = state else {
            Issue.record("Expected an available update, received \(state)")
            return
        }
        #expect(trigger == .automatic)
        #expect(freshness == .fetched)
        #expect(release.version.description == "1.3.0")
        #expect(release.tagName == "v1.3.0")
        #expect(release.releaseName == "Agent Pet Companion 1.3.0")
        #expect(release.releasePageURL.absoluteString
            == "https://github.com/xjxtree/agent-pet-companion/releases/tag/v1.3.0")
        #expect(release.asset.fileName == "AgentPetCompanion-1.3.0-macos-arm64.zip")
        #expect(release.asset.architecture == .arm64)
        #expect(release.asset.size == 1_048_576)
        #expect(release.asset.sha256 == String(repeating: "a", count: 64))
        #expect(release.asset.downloadURL.absoluteString
            == "https://github.com/xjxtree/agent-pet-companion/releases/download/v1.3.0/AgentPetCompanion-1.3.0-macos-arm64.zip")
        #expect(state.presentation == .updateAvailable)

        let requests = await client.recordedRequests()
        let request = try #require(requests.first)
        #expect(request.url == GitHubReleaseUpdateChecker.latestReleaseURL)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test
    func etagIsSentAndNotModifiedResponseReusesValidatedRelease() async throws {
        let fetched = try releaseResponse(
            version: "2.0.0",
            assets: releaseAssets(version: "2.0.0"),
            headers: ["eTaG": #""immutable-v2""#]
        )
        let notModified = GitHubReleaseHTTPResponse(
            statusCode: 304,
            headers: [:],
            body: Data()
        )
        let client = StubGitHubReleaseHTTPClient([
            .response(fetched),
            .response(notModified)
        ])
        let checker = GitHubReleaseUpdateChecker(client: client, architecture: .arm64)

        _ = await checker.check(currentVersion: "1.0.0", trigger: .automatic)
        let state = await checker.check(currentVersion: "2.0.0", trigger: .manual)

        guard case let .upToDate(trigger, latestVersion, freshness) = state else {
            Issue.record("Expected cached release to report up to date, received \(state)")
            return
        }
        #expect(trigger == .manual)
        #expect(latestVersion.description == "2.0.0")
        #expect(freshness == .notModified)
        #expect(state.presentation == .upToDate)

        let requests = await client.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == #""immutable-v2""#)
    }

    @Test
    func validatedCacheSnapshotRoundTripsAcrossCheckerInstances() async throws {
        let fetched = try releaseResponse(
            version: "2.1.0",
            assets: releaseAssets(version: "2.1.0"),
            headers: ["ETag": #"W/"release-v2.1""#]
        )
        let firstClient = StubGitHubReleaseHTTPClient([.response(fetched)])
        let firstChecker = GitHubReleaseUpdateChecker(
            client: firstClient,
            architecture: .x86_64
        )
        _ = await firstChecker.check(currentVersion: "2.0.0", trigger: .automatic)
        let exported = try #require(await firstChecker.exportedCacheSnapshot())
        let encoded = try JSONEncoder().encode(exported)
        let restored = try JSONDecoder().decode(
            GitHubReleaseUpdateCacheSnapshot.self,
            from: encoded
        )

        let secondClient = StubGitHubReleaseHTTPClient([
            .response(GitHubReleaseHTTPResponse(statusCode: 304, headers: [:], body: Data()))
        ])
        let secondChecker = GitHubReleaseUpdateChecker(
            client: secondClient,
            architecture: .x86_64,
            cacheSnapshot: restored
        )
        let state = await secondChecker.check(currentVersion: "2.0.0", trigger: .manual)

        guard case let .updateAvailable(trigger, release, freshness) = state else {
            Issue.record("Expected restored release cache to survive a 304, received \(state)")
            return
        }
        #expect(trigger == .manual)
        #expect(freshness == .notModified)
        #expect(release.version.description == "2.1.0")
        #expect(release.asset.architecture == .x86_64)
        let requests = await secondClient.recordedRequests()
        #expect(requests.first?.value(forHTTPHeaderField: "If-None-Match")
            == #"W/"release-v2.1""#)
    }

    @Test
    func restoredCacheSnapshotIsRevalidatedBeforeItsETagOrReleaseIsUsed() async throws {
        let fetched = try releaseResponse(
            version: "2.1.0",
            assets: releaseAssets(version: "2.1.0"),
            headers: ["ETag": #""release-v2.1""#]
        )
        let firstClient = StubGitHubReleaseHTTPClient([.response(fetched)])
        let firstChecker = GitHubReleaseUpdateChecker(
            client: firstClient,
            architecture: .arm64
        )
        _ = await firstChecker.check(currentVersion: "2.0.0", trigger: .automatic)
        let valid = try #require(await firstChecker.exportedCacheSnapshot())
        let corruptedRelease = AppReleaseUpdate(
            version: valid.release.version,
            tagName: valid.release.tagName,
            releaseName: valid.release.releaseName,
            releasePageURL: try #require(URL(string: "https://example.com/releases/v2.1.0")),
            asset: valid.release.asset
        )
        let corrupted = GitHubReleaseUpdateCacheSnapshot(
            etag: valid.etag,
            release: corruptedRelease
        )
        let secondClient = StubGitHubReleaseHTTPClient([
            .response(GitHubReleaseHTTPResponse(statusCode: 304, headers: [:], body: Data()))
        ])
        let secondChecker = GitHubReleaseUpdateChecker(
            client: secondClient,
            architecture: .arm64,
            cacheSnapshot: corrupted
        )

        let state = await secondChecker.check(currentVersion: "2.0.0", trigger: .manual)

        #expect(state
            == .failed(trigger: .manual, failure: .notModifiedWithoutCachedRelease))
        let requests = await secondClient.recordedRequests()
        #expect(requests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test
    func checkingPresentationIsVisibleOnlyForManualRequests() {
        #expect(AppUpdateCheckState.checking(.automatic).presentation == .none)
        #expect(AppUpdateCheckState.checking(.manual).presentation == .checking)
    }

    @Test
    func automaticChecksSuppressRoutineAndFailurePresentation() async throws {
        let currentResponse = try releaseResponse(
            version: "1.2.3",
            assets: releaseAssets(version: "1.2.3")
        )
        let currentClient = StubGitHubReleaseHTTPClient([.response(currentResponse)])
        let currentChecker = GitHubReleaseUpdateChecker(
            client: currentClient,
            architecture: .arm64
        )

        let currentState = await currentChecker.check(
            currentVersion: "1.2.3",
            trigger: .automatic
        )
        #expect(currentState.presentation == .none)

        let failureClient = StubGitHubReleaseHTTPClient([.failure])
        let failureChecker = GitHubReleaseUpdateChecker(
            client: failureClient,
            architecture: .arm64
        )
        let automaticFailure = await failureChecker.check(
            currentVersion: "1.2.3",
            trigger: .automatic
        )
        #expect(automaticFailure
            == .failed(trigger: .automatic, failure: .transport))
        #expect(automaticFailure.presentation == .none)

        let manualFailureClient = StubGitHubReleaseHTTPClient([.failure])
        let manualFailureChecker = GitHubReleaseUpdateChecker(
            client: manualFailureClient,
            architecture: .arm64
        )
        let manualFailure = await manualFailureChecker.check(
            currentVersion: "1.2.3",
            trigger: .manual
        )
        #expect(manualFailure == .failed(trigger: .manual, failure: .transport))
        #expect(manualFailure.presentation == .failure)
    }

    @Test(
        arguments: [
            "1.2.3",
            "v1.2",
            "v1.2.3.4",
            "v01.2.3",
            "v1.02.3",
            "v1.2.03",
            "v1.2.3-beta.1",
            "v1.2.3+build.4",
            " v1.2.3",
            "v1.2.3 "
        ]
    )
    func releaseTagRequiresStrictStableSemver(_ tag: String) {
        #expect(StableSemanticVersion(releaseTag: tag) == nil)
    }

    @Test
    func semanticVersionComparisonUsesNumericComponents() throws {
        let oneNine = try #require(StableSemanticVersion(appVersion: "1.9.0"))
        let oneTen = try #require(StableSemanticVersion(appVersion: "1.10.0"))
        let twoZero = try #require(StableSemanticVersion(releaseTag: "v2.0.0"))

        #expect(oneNine < oneTen)
        #expect(oneTen < twoZero)
        #expect(StableSemanticVersion(appVersion: "01.2.3") == nil)
        #expect(StableSemanticVersion(appVersion: "1.2.3-beta") == nil)
    }

    @Test
    func draftAndPrereleasePayloadsAreRejected() async throws {
        let draft = try releaseResponse(
            version: "1.3.0",
            draft: true,
            assets: [releaseAsset(version: "1.3.0", architecture: .arm64)]
        )
        let prerelease = try releaseResponse(
            version: "1.3.0",
            prerelease: true,
            assets: [releaseAsset(version: "1.3.0", architecture: .arm64)]
        )
        let client = StubGitHubReleaseHTTPClient([
            .response(draft),
            .response(prerelease)
        ])
        let checker = GitHubReleaseUpdateChecker(client: client, architecture: .arm64)

        let draftState = await checker.check(currentVersion: "1.0.0", trigger: .manual)
        #expect(draftState == .failed(trigger: .manual, failure: .draftRelease))

        let prereleaseState = await checker.check(
            currentVersion: "1.0.0",
            trigger: .manual
        )
        #expect(prereleaseState == .failed(trigger: .manual, failure: .prerelease))
    }

    @Test
    func mutableReleaseIsAcceptedWhenTheStableAssetContractMatches() async throws {
        let response = try releaseResponse(
            version: "1.3.0",
            immutable: false,
            assets: releaseAssets(version: "1.3.0")
        )
        let client = StubGitHubReleaseHTTPClient([.response(response)])
        let checker = GitHubReleaseUpdateChecker(client: client, architecture: .arm64)

        let state = await checker.check(currentVersion: "1.0.0", trigger: .manual)

        guard case let .updateAvailable(trigger, release, freshness) = state else {
            Issue.record("Expected the standard GitHub Release to be accepted, received \(state)")
            return
        }
        #expect(trigger == .manual)
        #expect(release.version.description == "1.3.0")
        #expect(freshness == .fetched)
    }

    @Test
    func missingAndAmbiguousArchitectureAssetsAreRejected() async throws {
        let missing = try releaseResponse(
            version: "1.3.0",
            assets: [releaseAsset(version: "1.3.0", architecture: .x86_64)]
        )
        let armAsset = releaseAsset(version: "1.3.0", architecture: .arm64)
        let ambiguous = try releaseResponse(
            version: "1.3.0",
            assets: [armAsset, armAsset]
        )
        let client = StubGitHubReleaseHTTPClient([
            .response(missing),
            .response(ambiguous)
        ])
        let checker = GitHubReleaseUpdateChecker(client: client, architecture: .arm64)

        let missingState = await checker.check(currentVersion: "1.0.0", trigger: .manual)
        #expect(missingState
            == .failed(trigger: .manual, failure: .missingArchitectureAsset(.arm64)))

        let ambiguousState = await checker.check(
            currentVersion: "1.0.0",
            trigger: .manual
        )
        #expect(ambiguousState
            == .failed(trigger: .manual, failure: .ambiguousArchitectureAssets(.arm64)))
    }

    @Test
    func assetMustBeUploadedNonemptyHttpsAndHaveSHA256Digest() async throws {
        var invalidAsset = releaseAsset(version: "1.3.0", architecture: .arm64)
        invalidAsset["digest"] = "sha256:not-a-digest"
        let response = try releaseResponse(
            version: "1.3.0",
            assets: [
                invalidAsset,
                releaseAsset(version: "1.3.0", architecture: .x86_64),
                checksumAsset(version: "1.3.0")
            ]
        )
        let client = StubGitHubReleaseHTTPClient([.response(response)])
        let checker = GitHubReleaseUpdateChecker(client: client, architecture: .arm64)

        let state = await checker.check(currentVersion: "1.0.0", trigger: .manual)

        #expect(state == .failed(trigger: .manual, failure: .invalidAsset))
    }

    @Test
    func releaseRequiresTheExactThreeOfficialAssets() async throws {
        let missingChecksum = try releaseResponse(
            version: "1.3.0",
            assets: [
                releaseAsset(version: "1.3.0", architecture: .arm64),
                releaseAsset(version: "1.3.0", architecture: .x86_64)
            ]
        )
        var assetsWithExtra = releaseAssets(version: "1.3.0")
        assetsWithExtra.append([
            "name": "source.zip",
            "state": "uploaded",
            "size": 123,
            "digest": "sha256:\(String(repeating: "c", count: 64))",
            "browser_download_url":
                "https://github.com/xjxtree/agent-pet-companion/releases/download/v1.3.0/source.zip"
        ])
        let extraAsset = try releaseResponse(version: "1.3.0", assets: assetsWithExtra)
        let client = StubGitHubReleaseHTTPClient([
            .response(missingChecksum),
            .response(extraAsset)
        ])
        let checker = GitHubReleaseUpdateChecker(client: client, architecture: .arm64)

        let missingState = await checker.check(currentVersion: "1.0.0", trigger: .manual)
        #expect(missingState
            == .failed(trigger: .manual, failure: .invalidAssetInventory))

        let extraState = await checker.check(currentVersion: "1.0.0", trigger: .manual)
        #expect(extraState
            == .failed(trigger: .manual, failure: .invalidAssetInventory))
    }

    @Test
    func releaseAndDownloadURLsMustMatchTheOfficialRepositoryTagAndAsset() async throws {
        let wrongReleasePage = try releaseResponse(
            version: "1.3.0",
            assets: releaseAssets(version: "1.3.0"),
            htmlURL: "https://example.com/xjxtree/agent-pet-companion/releases/tag/v1.3.0"
        )
        var wrongDownloadAssets = releaseAssets(version: "1.3.0")
        wrongDownloadAssets[0]["browser_download_url"] =
            "https://example.com/AgentPetCompanion-1.3.0-macos-arm64.zip"
        let wrongDownload = try releaseResponse(
            version: "1.3.0",
            assets: wrongDownloadAssets
        )
        let client = StubGitHubReleaseHTTPClient([
            .response(wrongReleasePage),
            .response(wrongDownload)
        ])
        let checker = GitHubReleaseUpdateChecker(client: client, architecture: .arm64)

        let releasePageState = await checker.check(
            currentVersion: "1.0.0",
            trigger: .manual
        )
        #expect(releasePageState
            == .failed(trigger: .manual, failure: .invalidReleaseURL))

        let downloadState = await checker.check(currentVersion: "1.0.0", trigger: .manual)
        #expect(downloadState == .failed(trigger: .manual, failure: .invalidAsset))
    }

    @Test
    func unexpectedStatusAndUnsolicitedNotModifiedAreFailures() async {
        let client = StubGitHubReleaseHTTPClient([
            .response(GitHubReleaseHTTPResponse(statusCode: 503, headers: [:], body: Data())),
            .response(GitHubReleaseHTTPResponse(statusCode: 304, headers: [:], body: Data()))
        ])
        let checker = GitHubReleaseUpdateChecker(client: client, architecture: .arm64)

        let unavailable = await checker.check(currentVersion: "1.0.0", trigger: .manual)
        #expect(unavailable
            == .failed(trigger: .manual, failure: .unexpectedHTTPStatus(503)))

        let notModified = await checker.check(currentVersion: "1.0.0", trigger: .manual)
        #expect(notModified
            == .failed(trigger: .manual, failure: .notModifiedWithoutCachedRelease))
    }

    @Test
    func malformedAndOversizedPayloadsFailClosed() async {
        let client = StubGitHubReleaseHTTPClient([
            .response(
                GitHubReleaseHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"tag_name":"v1.2.3"}"#.utf8)
                )
            ),
            .response(
                GitHubReleaseHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(repeating: 0x20, count: 1_048_577)
                )
            )
        ])
        let checker = GitHubReleaseUpdateChecker(client: client, architecture: .arm64)

        let malformed = await checker.check(currentVersion: "1.0.0", trigger: .manual)
        #expect(malformed == .failed(trigger: .manual, failure: .invalidResponse))

        let oversized = await checker.check(currentVersion: "1.0.0", trigger: .manual)
        #expect(oversized == .failed(trigger: .manual, failure: .invalidResponse))
    }
}

private actor StubGitHubReleaseHTTPClient: GitHubReleaseHTTPClient {
    enum Outcome: Sendable {
        case response(GitHubReleaseHTTPResponse)
        case failure
    }

    private var outcomes: [Outcome]
    private var requests: [URLRequest] = []

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func send(_ request: URLRequest) async throws -> GitHubReleaseHTTPResponse {
        requests.append(request)
        guard !outcomes.isEmpty else {
            throw StubHTTPError.noResponse
        }
        switch outcomes.removeFirst() {
        case let .response(response):
            return response
        case .failure:
            throw StubHTTPError.requestFailed
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private enum StubHTTPError: Error {
    case noResponse
    case requestFailed
}

private func releaseResponse(
    version: String,
    draft: Bool = false,
    prerelease: Bool = false,
    immutable: Bool = true,
    assets: [[String: Any]],
    headers: [String: String] = [:],
    htmlURL: String? = nil
) throws -> GitHubReleaseHTTPResponse {
    let body = try JSONSerialization.data(withJSONObject: [
        "tag_name": "v\(version)",
        "name": "Agent Pet Companion \(version)",
        "html_url": htmlURL
            ?? "https://github.com/xjxtree/agent-pet-companion/releases/tag/v\(version)",
        "draft": draft,
        "prerelease": prerelease,
        "immutable": immutable,
        "assets": assets
    ])
    return GitHubReleaseHTTPResponse(statusCode: 200, headers: headers, body: body)
}

private func releaseAssets(version: String) -> [[String: Any]] {
    [
        releaseAsset(version: version, architecture: .arm64),
        releaseAsset(version: version, architecture: .x86_64),
        checksumAsset(version: version)
    ]
}

private func releaseAsset(
    version: String,
    architecture: AppReleaseArchitecture
) -> [String: Any] {
    let fileName = "AgentPetCompanion-\(version)-macos-\(architecture.rawValue).zip"
    return [
        "name": fileName,
        "state": "uploaded",
        "size": 1_048_576,
        "digest": "sha256:\(String(repeating: "a", count: 64))",
        "browser_download_url":
            "https://github.com/xjxtree/agent-pet-companion/releases/download/v\(version)/\(fileName)"
    ]
}

private func checksumAsset(version: String) -> [String: Any] {
    [
        "name": "AgentPetCompanion-\(version)-SHA256SUMS.txt",
        "state": "uploaded",
        "size": 256,
        "digest": "sha256:\(String(repeating: "b", count: 64))",
        "browser_download_url":
            "https://github.com/xjxtree/agent-pet-companion/releases/download/v\(version)/AgentPetCompanion-\(version)-SHA256SUMS.txt"
    ]
}
