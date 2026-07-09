import Foundation

enum GitHubRunnerVersionResolverError: Error {
    case invalidResponse
    case httpStatus(Int)
    case missingTag
    case invalidTag(String)
}

struct ResolvedRunnerRelease: Sendable, Equatable {
    let version: String
    let digests: [String: String]
}

actor GitHubRunnerVersionResolver: Sendable {
    static let cacheTTL: TimeInterval = 86_400

    private let session: URLSession
    private let now: @Sendable () -> Date
    private var cachedRelease: ResolvedRunnerRelease?
    private var cachedAt: Date?
    private var inFlight: Task<ResolvedRunnerRelease, Error>?

    init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    func latestRelease() async throws -> ResolvedRunnerRelease {
        if let cachedRelease, let cachedAt, now().timeIntervalSince(cachedAt) < Self.cacheTTL {
            return cachedRelease
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await fetchLatestRelease() }
        inFlight = task
        do {
            let release = try await task.value
            cachedRelease = release
            cachedAt = now()
            inFlight = nil
            return release
        } catch {
            inFlight = nil
            if let cachedRelease {
                return cachedRelease
            }
            throw error
        }
    }

    private func fetchLatestRelease() async throws -> ResolvedRunnerRelease {
        guard let url = URL(string: "https://api.github.com/repos/actions/runner/releases/latest") else {
            throw GitHubRunnerVersionResolverError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("sand", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubRunnerVersionResolverError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GitHubRunnerVersionResolverError.httpStatus(httpResponse.statusCode)
        }
        let payload = try JSONDecoder().decode(LatestRelease.self, from: data)
        guard let tag = payload.tag_name else {
            throw GitHubRunnerVersionResolverError.missingTag
        }
        guard let version = Self.parseTagName(tag) else {
            throw GitHubRunnerVersionResolverError.invalidTag(tag)
        }
        var digests: [String: String] = [:]
        for asset in payload.assets ?? [] {
            guard let rawDigest = asset.digest, let digest = Self.parseDigest(rawDigest) else {
                continue
            }
            digests[asset.name] = digest
        }
        return ResolvedRunnerRelease(version: version, digests: digests)
    }

    static func parseDigest(_ digest: String) -> String? {
        let prefix = "sha256:"
        guard digest.hasPrefix(prefix) else {
            return nil
        }
        let hex = String(digest.dropFirst(prefix.count)).lowercased()
        guard !hex.isEmpty else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard hex.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return hex
    }

    static func compareVersionStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = parseVersionComponents(lhs), let right = parseVersionComponents(rhs) else {
            return .orderedSame
        }
        return compareVersions(left, right)
    }

    static func parseTagName(_ tagName: String) -> String? {
        let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        guard !version.isEmpty else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "0123456789.")
        guard version.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return version
    }

    static func extractVersion(from filename: String) -> String? {
        let prefix = "actions-runner-"
        let suffix = ".tar.gz"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else {
            return nil
        }
        let core = String(filename.dropFirst(prefix.count).dropLast(suffix.count))
        guard let dashIndex = core.lastIndex(of: "-") else {
            return nil
        }
        let version = String(core[core.index(after: dashIndex)...])
        return parseTagName(version)
    }

    private static func parseVersionComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".")
        guard !parts.isEmpty else {
            return nil
        }
        var components: [Int] = []
        for part in parts {
            guard let value = Int(part) else {
                return nil
            }
            components.append(value)
        }
        return components
    }

    private static func compareVersions(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left == right {
                continue
            }
            return left < right ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private struct LatestRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let digest: String?
        }

        let tag_name: String?
        let assets: [Asset]?
    }
}
