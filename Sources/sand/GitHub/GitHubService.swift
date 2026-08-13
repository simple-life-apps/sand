import Foundation

protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

enum GitHubServiceError: Error, CustomStringConvertible {
    case invalidResponse
    case httpError(status: Int, body: String)
    case unverifiedRunnerAbsence(returned: Int, totalCount: Int?)

    var description: String {
        switch self {
        case .invalidResponse:
            return "response was not HTTP"
        case let .httpError(status, body):
            return "HTTP \(status): \(body)"
        case let .unverifiedRunnerAbsence(returned, totalCount):
            guard let totalCount else {
                return "runner list returned \(returned) runners without a total count; cannot confirm the runner is absent"
            }
            return "runner list returned \(returned) of \(totalCount) runners; cannot confirm the runner is absent"
        }
    }
}

struct GitHubService: Sendable {
    struct InstallationResponse: Decodable {
        let id: Int
    }

    struct AccessTokenResponse: Decodable {
        let token: String
        let expiresAt: Date
    }

    struct RunnerTokenResponse: Decodable {
        let token: String
    }

    struct RunnersListResponse: Decodable {
        struct Runner: Decodable {
            let id: Int
            let name: String
            let status: String?
            let busy: Bool?
        }
        let totalCount: Int?
        let runners: [Runner]
    }


    let auth: GitHubAuthenticating
    let session: URLSessionProtocol
    let organization: String
    let repository: String?
    let baseURL = URL(string: "https://api.github.com")!
    let tokenCache = GitHubTokenCache()

    func runnerRegistrationToken() async throws -> String {
        let installationId = try await installationID()
        let accessToken = try await installationAccessToken(installationId: installationId)
        let tokenResponse: RunnerTokenResponse = try await request(path: registrationTokenPath(), method: "POST", token: accessToken)
        return tokenResponse.token
    }

    func deleteRunner(named name: String) async throws -> Bool {
        let installationId = try await installationID()
        let accessToken = try await installationAccessToken(installationId: installationId)
        guard let runner = try await findRunner(named: name, token: accessToken, requireVerifiedAbsence: false) else {
            return false
        }
        try await requestExpectingNoContent(path: "\(runnersPath())/\(runner.id)", method: "DELETE", token: accessToken)
        return true
    }

    enum RunnerLookup: Equatable, Sendable {
        case notRegistered
        case registered(RunnerStatus)
    }

    struct RunnerStatus: Equatable, Sendable {
        enum Connection: Equatable, Sendable {
            case online
            case offline
            case unrecognized(String?)
        }

        let connection: Connection
        let busy: Bool?
    }

    func runnerStatus(named name: String) async throws -> RunnerLookup {
        do {
            return try await fetchRunnerStatus(named: name, token: cachedInstallationToken())
        } catch let GitHubServiceError.httpError(status, _) where status == 401 {
            await tokenCache.invalidateToken()
            return try await fetchRunnerStatus(named: name, token: cachedInstallationToken())
        }
    }

    private func cachedInstallationToken() async throws -> String {
        if let token = await tokenCache.validToken(now: Date()) {
            return token
        }
        let installationId: Int
        if let cached = await tokenCache.cachedInstallationId() {
            installationId = cached
        } else {
            installationId = try await installationID()
            await tokenCache.store(installationId: installationId)
        }
        let jwt = try auth.token(now: Date())
        let response: AccessTokenResponse
        do {
            response = try await request(
                path: "/app/installations/\(installationId)/access_tokens",
                method: "POST",
                token: jwt
            )
        } catch {
            await tokenCache.invalidateInstallationId()
            throw error
        }
        await tokenCache.store(token: response.token, expiresAt: response.expiresAt)
        return response.token
    }

    private func fetchRunnerStatus(named name: String, token: String) async throws -> RunnerLookup {
        guard let runner = try await findRunner(named: name, token: token) else {
            return .notRegistered
        }
        let connection: RunnerStatus.Connection
        switch runner.status {
        case "online":
            connection = .online
        case "offline":
            connection = .offline
        default:
            connection = .unrecognized(runner.status)
        }
        return .registered(RunnerStatus(connection: connection, busy: runner.busy))
    }

    private func findRunner(named name: String, token: String, requireVerifiedAbsence: Bool = true) async throws -> RunnersListResponse.Runner? {
        let list: RunnersListResponse = try await request(
            path: runnerLookupPath(named: name),
            method: "GET",
            token: token
        )
        if let runner = list.runners.first(where: { $0.name == name }) {
            return runner
        }
        if requireVerifiedAbsence, list.totalCount != list.runners.count {
            throw GitHubServiceError.unverifiedRunnerAbsence(returned: list.runners.count, totalCount: list.totalCount)
        }
        return nil
    }

    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private func runnerLookupPath(named name: String) -> String {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? name
        return "\(runnersPath())?name=\(encodedName)&per_page=100"
    }

    private func installationID() async throws -> Int {
        let token = try auth.token(now: Date())
        let response: InstallationResponse = try await request(path: installationPath(), method: "GET", token: token)
        return response.id
    }

    private func installationAccessToken(installationId: Int) async throws -> String {
        let token = try auth.token(now: Date())
        let response: AccessTokenResponse = try await request(path: "/app/installations/\(installationId)/access_tokens", method: "POST", token: token)
        return response.token
    }

    private func request<T: Decodable>(path: String, method: String, token: String) async throws -> T {
        let data = try await performRequest(path: path, method: method, token: token)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func requestExpectingNoContent(path: String, method: String, token: String) async throws {
        _ = try await performRequest(path: path, method: method, token: token)
    }

    private func performRequest(path: String, method: String, token: String) async throws -> Data {
        let url = URL(string: path, relativeTo: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("sand", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidResponse
        }
        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubServiceError.httpError(status: httpResponse.statusCode, body: body)
        }
        return data
    }

    private func installationPath() -> String {
        if let repository {
            return "/repos/\(organization)/\(repository)/installation"
        }
        return "/orgs/\(organization)/installation"
    }

    private func registrationTokenPath() -> String {
        if let repository {
            return "/repos/\(organization)/\(repository)/actions/runners/registration-token"
        }
        return "/orgs/\(organization)/actions/runners/registration-token"
    }

    private func runnersPath() -> String {
        if let repository {
            return "/repos/\(organization)/\(repository)/actions/runners"
        }
        return "/orgs/\(organization)/actions/runners"
    }

}

actor GitHubTokenCache {
    struct IssuedToken {
        let value: String
        let expiresAt: Date

        func isValid(at now: Date) -> Bool {
            now < expiresAt.addingTimeInterval(-60)
        }
    }

    private var installationId: Int?
    private var issued: IssuedToken?

    func cachedInstallationId() -> Int? {
        installationId
    }

    func store(installationId: Int) {
        self.installationId = installationId
    }

    func validToken(now: Date) -> String? {
        guard let issued, issued.isValid(at: now) else {
            return nil
        }
        return issued.value
    }

    func store(token: String, expiresAt: Date) {
        issued = IssuedToken(value: token, expiresAt: expiresAt)
    }

    func invalidateToken() {
        issued = nil
    }

    func invalidateInstallationId() {
        installationId = nil
    }
}
