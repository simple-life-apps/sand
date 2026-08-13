import Foundation
import XCTest
@testable import sand

final class MockAuth: GitHubAuthenticating, @unchecked Sendable {
    func token(now: Date) throws -> String {
        return "jwt"
    }
}

final class MockSession: URLSessionProtocol, @unchecked Sendable {
    var responses: [String: (Data, Int)] = [:]
    var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        guard let response = responses[path] else {
            throw NSError(domain: "missing", code: 1)
        }
        let url = request.url ?? URL(string: "https://api.github.com")!
        let http = HTTPURLResponse(url: url, statusCode: response.1, httpVersion: nil, headerFields: nil)!
        return (response.0, http)
    }
}

final class GitHubServiceTests: XCTestCase {
    func testRepoLevelPaths() async throws {
        let session = MockSession()
        session.responses["/repos/org/repo/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/repos/org/repo/actions/runners/registration-token"] = (Data("{\"token\":\"runner\"}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: "repo")
        let token = try await service.runnerRegistrationToken()
        XCTAssertEqual(token, "runner")
        XCTAssertEqual(session.requests.map { $0.url?.path ?? "" }, [
            "/repos/org/repo/installation",
            "/app/installations/1/access_tokens",
            "/repos/org/repo/actions/runners/registration-token"
        ])
    }

    func testDeleteRunnerFoundByName() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\"}]}".utf8), 200)
        session.responses["/orgs/org/actions/runners/42"] = (Data(), 204)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let deleted = try await service.deleteRunner(named: "r-a3f9c")
        XCTAssertTrue(deleted)
        let last = session.requests.last
        XCTAssertEqual(last?.url?.path, "/orgs/org/actions/runners/42")
        XCTAssertEqual(last?.httpMethod, "DELETE")
        let listRequest = session.requests[2]
        XCTAssertEqual(listRequest.url?.path, "/orgs/org/actions/runners")
        XCTAssertEqual(listRequest.url?.query, "name=r-a3f9c&per_page=100")
    }

    func testDeleteRunnerNotFoundIssuesNoDelete() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"total_count\":0,\"runners\":[]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let deleted = try await service.deleteRunner(named: "r-a3f9c")
        XCTAssertFalse(deleted)
        XCTAssertFalse(session.requests.contains { $0.httpMethod == "DELETE" })
    }

    func testDeleteRunnerRepoLevelPaths() async throws {
        let session = MockSession()
        session.responses["/repos/org/repo/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/repos/org/repo/actions/runners"] = (Data("{\"runners\":[{\"id\":7,\"name\":\"r-00001\"}]}".utf8), 200)
        session.responses["/repos/org/repo/actions/runners/7"] = (Data(), 204)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: "repo")
        let deleted = try await service.deleteRunner(named: "r-00001")
        XCTAssertTrue(deleted)
        XCTAssertEqual(session.requests.last?.url?.path, "/repos/org/repo/actions/runners/7")
    }

    func testRunnerStatusOnlineBusy() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\",\"status\":\"online\",\"busy\":true}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, .registered(GitHubService.RunnerStatus(connection: .online, busy: true)))
        let listRequest = session.requests.last
        XCTAssertEqual(listRequest?.url?.path, "/orgs/org/actions/runners")
        XCTAssertEqual(listRequest?.url?.query, "name=r-a3f9c&per_page=100")
    }

    func testRunnerStatusOnlineIdle() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\",\"status\":\"online\",\"busy\":false}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, .registered(GitHubService.RunnerStatus(connection: .online, busy: false)))
    }

    func testRunnerStatusOffline() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\",\"status\":\"offline\",\"busy\":false}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, .registered(GitHubService.RunnerStatus(connection: .offline, busy: false)))
    }

    func testRunnerStatusOfflineBusy() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\",\"status\":\"offline\",\"busy\":true}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, .registered(GitHubService.RunnerStatus(connection: .offline, busy: true)))
    }

    func testRunnerStatusOfflineWithAbsentBusyDecodesAsUnknownBusy() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\",\"status\":\"offline\"}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, .registered(GitHubService.RunnerStatus(connection: .offline, busy: nil)), "an absent busy field is not evidence the runner is idle")
    }

    func testRunnerStatusNotRegistered() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"total_count\":0,\"runners\":[]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, .notRegistered)
    }

    func testRunnerStatusAbsenceFromIncompleteListThrows() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"total_count\":45,\"runners\":[{\"id\":7,\"name\":\"other\",\"status\":\"online\",\"busy\":false}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        do {
            _ = try await service.runnerStatus(named: "r-a3f9c")
            XCTFail("an unpaginated or unfiltered list must not be read as runner deletion")
        } catch let GitHubServiceError.unverifiedRunnerAbsence(returned, totalCount) {
            XCTAssertEqual(returned, 1)
            XCTAssertEqual(totalCount, 45)
        }
    }

    func testRunnerStatusAbsenceWithoutTotalCountThrows() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        do {
            _ = try await service.runnerStatus(named: "r-a3f9c")
            XCTFail("a response missing total_count cannot prove the runner is gone")
        } catch let GitHubServiceError.unverifiedRunnerAbsence(returned, totalCount) {
            XCTAssertEqual(returned, 0)
            XCTAssertNil(totalCount)
        }
    }

    func testDeleteRunnerToleratesUnverifiedAbsence() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"total_count\":45,\"runners\":[{\"id\":7,\"name\":\"other\",\"status\":\"online\",\"busy\":false}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let deleted = try await service.deleteRunner(named: "r-a3f9c")
        XCTAssertFalse(deleted, "best-effort deregistration must not fail on an incomplete list")
        XCTAssertFalse(session.requests.contains { $0.httpMethod == "DELETE" })
    }

    func testRunnerLookupRequestsAFullPage() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"total_count\":0,\"runners\":[]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        _ = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(session.requests.last?.url?.query, "name=r-a3f9c&per_page=100", "a larger page keeps absence verifiable even when the name filter is ignored")
    }

    func testUnverifiedRunnerAbsenceDescribesItself() {
        let error = GitHubServiceError.unverifiedRunnerAbsence(returned: 1, totalCount: 45)
        XCTAssertEqual(
            String(describing: error),
            "runner list returned 1 of 45 runners; cannot confirm the runner is absent"
        )
        let unknownTotal = GitHubServiceError.unverifiedRunnerAbsence(returned: 0, totalCount: nil)
        XCTAssertEqual(
            String(describing: unknownTotal),
            "runner list returned 0 runners without a total count; cannot confirm the runner is absent"
        )
    }

    func testRunnerStatusFoundOnIncompleteListStillReturnsStatus() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"total_count\":45,\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\",\"status\":\"online\",\"busy\":true}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, .registered(GitHubService.RunnerStatus(connection: .online, busy: true)))
    }

    func testRunnerStatusRecoversAfterInstallationIsReinstalled() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"message\":\"Not Found\"}".utf8), 404)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        do {
            _ = try await service.runnerStatus(named: "r-a3f9c")
            XCTFail("expected the stale installation to fail the first poll")
        } catch {}

        session.responses["/orgs/org/installation"] = (Data("{\"id\":2}".utf8), 200)
        session.responses["/app/installations/2/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\",\"status\":\"online\",\"busy\":false}]}".utf8), 200)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, .registered(GitHubService.RunnerStatus(connection: .online, busy: false)))
    }

    func testRunnerStatusUnrecognizedWhenStatusFieldAbsent() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\"}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, .registered(GitHubService.RunnerStatus(connection: .unrecognized(nil), busy: nil)))
    }

    func testRunnerStatusUnrecognizedForUnknownStatusValue() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\",\"status\":\"idle\",\"busy\":false}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, .registered(GitHubService.RunnerStatus(connection: .unrecognized("idle"), busy: false)))
    }

    func testRunnerStatusEscapesPlusInRunnerName() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"macos15+xcode16\",\"status\":\"online\",\"busy\":false}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "macos15+xcode16")
        let listRequest = session.requests.last
        XCTAssertEqual(listRequest?.url?.path, "/orgs/org/actions/runners")
        XCTAssertEqual(listRequest?.url?.query, "name=macos15%2Bxcode16&per_page=100", "a literal + is decoded server-side as a space and would never match the runner")
        XCTAssertEqual(status, .registered(GitHubService.RunnerStatus(connection: .online, busy: false)))
    }

    func testRunnerStatusEscapesAmpersandInRunnerName() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a&b=c\",\"status\":\"online\",\"busy\":true}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a&b=c")
        XCTAssertEqual(session.requests.last?.url?.query, "name=r-a%26b%3Dc&per_page=100")
        XCTAssertEqual(status, .registered(GitHubService.RunnerStatus(connection: .online, busy: true)))
    }

    func testRunnerStatusIgnoresSimilarButDifferentName() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"total_count\":1,\"runners\":[{\"id\":42,\"name\":\"r-a3f9c-2\",\"status\":\"online\",\"busy\":false}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, .notRegistered)
    }

    func testDeleteRunnerIgnoresSimilarButDifferentName() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"total_count\":1,\"runners\":[{\"id\":42,\"name\":\"r-a3f9c-2\"}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let deleted = try await service.deleteRunner(named: "r-a3f9c")
        XCTAssertFalse(deleted)
        XCTAssertFalse(session.requests.contains { $0.httpMethod == "DELETE" })
    }

    func testRunnerStatusReusesInstallationToken() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"total_count\":0,\"runners\":[]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        _ = try await service.runnerStatus(named: "r-a3f9c")
        _ = try await service.runnerStatus(named: "r-a3f9c")
        _ = try await service.runnerStatus(named: "r-a3f9c")
        let authRequests = session.requests.filter { $0.url?.path.contains("access_tokens") == true }
        let installationRequests = session.requests.filter { $0.url?.path == "/orgs/org/installation" }
        XCTAssertEqual(authRequests.count, 1)
        XCTAssertEqual(installationRequests.count, 1)
        let statusRequests = session.requests.filter { $0.url?.path == "/orgs/org/actions/runners" }
        XCTAssertEqual(statusRequests.count, 3)
    }

    func testRunnerStatusRefreshesExpiredToken() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2020-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"total_count\":0,\"runners\":[]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        _ = try await service.runnerStatus(named: "r-a3f9c")
        _ = try await service.runnerStatus(named: "r-a3f9c")
        let authRequests = session.requests.filter { $0.url?.path.contains("access_tokens") == true }
        XCTAssertEqual(authRequests.count, 2)
    }

    func testRunnerStatusRetriesOnceAfter401() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"message\":\"Bad credentials\"}".utf8), 401)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        do {
            _ = try await service.runnerStatus(named: "r-a3f9c")
            XCTFail("expected 401 to propagate after one retry")
        } catch let GitHubServiceError.httpError(status, _) {
            XCTAssertEqual(status, 401)
        }
        let authRequests = session.requests.filter { $0.url?.path.contains("access_tokens") == true }
        let statusRequests = session.requests.filter { $0.url?.path == "/orgs/org/actions/runners" }
        XCTAssertEqual(authRequests.count, 2, "401 must invalidate the cached token and mint once more")
        XCTAssertEqual(statusRequests.count, 2, "the status fetch is retried exactly once")
    }
}
