import Foundation
import XCTest
@testable import sand

final class GitHubRunnerVersionResolverTests: XCTestCase {
    func testParseTagName() {
        XCTAssertEqual(GitHubRunnerVersionResolver.parseTagName("v2.331.0"), "2.331.0")
        XCTAssertEqual(GitHubRunnerVersionResolver.parseTagName("2.331.0"), "2.331.0")
        XCTAssertNil(GitHubRunnerVersionResolver.parseTagName("v2.331.0-beta"))
        XCTAssertNil(GitHubRunnerVersionResolver.parseTagName("v"))
        XCTAssertNil(GitHubRunnerVersionResolver.parseTagName(""))
    }

    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResolverStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func releaseJSON(version: String, digest: String?) -> Data {
        let asset: String
        if let digest {
            asset = "{\"name\":\"actions-runner-osx-arm64-\(version).tar.gz\",\"digest\":\"\(digest)\"}"
        } else {
            asset = "{\"name\":\"actions-runner-osx-arm64-\(version).tar.gz\"}"
        }
        return Data("{\"tag_name\":\"v\(version)\",\"assets\":[\(asset)]}".utf8)
    }

    func testParseDigest() {
        XCTAssertEqual(
            GitHubRunnerVersionResolver.parseDigest("sha256:ABCDEF0123"),
            "abcdef0123"
        )
        XCTAssertNil(GitHubRunnerVersionResolver.parseDigest("md5:abc"))
        XCTAssertNil(GitHubRunnerVersionResolver.parseDigest("sha256:"))
        XCTAssertNil(GitHubRunnerVersionResolver.parseDigest("abcdef"))
    }

    func testCompareVersionStrings() {
        XCTAssertEqual(GitHubRunnerVersionResolver.compareVersionStrings("2.331.0", "2.330.0"), .orderedDescending)
        XCTAssertEqual(GitHubRunnerVersionResolver.compareVersionStrings("2.330.0", "2.330.0"), .orderedSame)
        XCTAssertEqual(GitHubRunnerVersionResolver.compareVersionStrings("2.9.0", "2.10.0"), .orderedAscending)
    }

    func testLatestReleaseParsesDigests() async throws {
        ResolverStubURLProtocol.reset()
        ResolverStubURLProtocol.responses = [
            (200, releaseJSON(version: "2.331.0", digest: "sha256:aa11"))
        ]
        let resolver = GitHubRunnerVersionResolver(session: stubbedSession())
        let release = try await resolver.latestRelease()
        XCTAssertEqual(release.version, "2.331.0")
        XCTAssertEqual(release.digests["actions-runner-osx-arm64-2.331.0.tar.gz"], "aa11")
    }

    func testLatestReleaseCachedWithinTTL() async throws {
        ResolverStubURLProtocol.reset()
        ResolverStubURLProtocol.responses = [
            (200, releaseJSON(version: "2.331.0", digest: "sha256:aa11"))
        ]
        let clock = MutableClock()
        let resolver = GitHubRunnerVersionResolver(session: stubbedSession(), now: { clock.current })
        _ = try await resolver.latestRelease()
        clock.current = clock.current.addingTimeInterval(GitHubRunnerVersionResolver.cacheTTL - 1)
        _ = try await resolver.latestRelease()
        XCTAssertEqual(ResolverStubURLProtocol.requestCount, 1)
    }

    func testLatestReleaseRefetchesAfterTTL() async throws {
        ResolverStubURLProtocol.reset()
        ResolverStubURLProtocol.responses = [
            (200, releaseJSON(version: "2.331.0", digest: "sha256:aa11")),
            (200, releaseJSON(version: "2.332.0", digest: "sha256:bb22"))
        ]
        let clock = MutableClock()
        let resolver = GitHubRunnerVersionResolver(session: stubbedSession(), now: { clock.current })
        let first = try await resolver.latestRelease()
        clock.current = clock.current.addingTimeInterval(GitHubRunnerVersionResolver.cacheTTL + 1)
        let second = try await resolver.latestRelease()
        XCTAssertEqual(first.version, "2.331.0")
        XCTAssertEqual(second.version, "2.332.0")
        XCTAssertEqual(ResolverStubURLProtocol.requestCount, 2)
    }

    func testLatestReleaseFallsBackToStaleOnRefreshFailure() async throws {
        ResolverStubURLProtocol.reset()
        ResolverStubURLProtocol.responses = [
            (200, releaseJSON(version: "2.331.0", digest: "sha256:aa11")),
            (500, Data())
        ]
        let clock = MutableClock()
        let resolver = GitHubRunnerVersionResolver(session: stubbedSession(), now: { clock.current })
        _ = try await resolver.latestRelease()
        clock.current = clock.current.addingTimeInterval(GitHubRunnerVersionResolver.cacheTTL + 1)
        let stale = try await resolver.latestRelease()
        XCTAssertEqual(stale.version, "2.331.0")
        XCTAssertEqual(ResolverStubURLProtocol.requestCount, 2)
    }

    func testLatestReleaseThrowsWhenNoCacheAndFetchFails() async {
        ResolverStubURLProtocol.reset()
        ResolverStubURLProtocol.responses = [(500, Data())]
        let resolver = GitHubRunnerVersionResolver(session: stubbedSession())
        do {
            _ = try await resolver.latestRelease()
            XCTFail("expected error")
        } catch {}
    }
}

final class ResolverStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        responses = []
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let (status, data) = Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MutableClock: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 1_000_000)
}
