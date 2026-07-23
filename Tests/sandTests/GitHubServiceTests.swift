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
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
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
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
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
        XCTAssertEqual(listRequest.url?.query, "name=r-a3f9c")
    }

    func testDeleteRunnerNotFoundIssuesNoDelete() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let deleted = try await service.deleteRunner(named: "r-a3f9c")
        XCTAssertFalse(deleted)
        XCTAssertFalse(session.requests.contains { $0.httpMethod == "DELETE" })
    }

    func testDeleteRunnerRepoLevelPaths() async throws {
        let session = MockSession()
        session.responses["/repos/org/repo/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
        session.responses["/repos/org/repo/actions/runners"] = (Data("{\"runners\":[{\"id\":7,\"name\":\"r-00001\"}]}".utf8), 200)
        session.responses["/repos/org/repo/actions/runners/7"] = (Data(), 204)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: "repo")
        let deleted = try await service.deleteRunner(named: "r-00001")
        XCTAssertTrue(deleted)
        XCTAssertEqual(session.requests.last?.url?.path, "/repos/org/repo/actions/runners/7")
    }
}
