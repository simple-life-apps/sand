import CryptoKit
import Foundation

struct RunnerCacheManager: Sendable {
    enum CacheError: Error {
        case downloadFailed(url: String, status: Int?)
        case digestMismatch(asset: String, expected: String, actual: String)
    }

    static let maxCachedVersions = 5
    static let defaultDownloadBaseURL = URL(string: "https://github.com/actions/runner/releases/download")!

    let cacheDirectory: String?
    let session: URLSession
    let logger: Logger
    let downloadBaseURL: URL

    init(
        cacheDirectory: String?,
        session: URLSession = .shared,
        logger: Logger,
        downloadBaseURL: URL = RunnerCacheManager.defaultDownloadBaseURL
    ) {
        self.cacheDirectory = cacheDirectory
        self.session = session
        self.logger = logger
        self.downloadBaseURL = downloadBaseURL
    }

    func verifiedAsset(assetName: String, version: String, expectedDigest: String) async throws -> String {
        let directory = try workingDirectory()
        let assetPath = (directory as NSString).appendingPathComponent(assetName)
        let sidecarPath = assetPath + ".sha256"
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: assetPath) {
            if Self.readSidecar(at: sidecarPath) == expectedDigest,
               let actual = try? Self.sha256Hex(ofFileAt: assetPath),
               actual == expectedDigest {
                logger.info("runner cache hit: \(assetPath)")
                return assetPath
            }
            logger.warning("runner cache entry failed verification, removing: \(assetPath)")
            try? fileManager.removeItem(atPath: assetPath)
            try? fileManager.removeItem(atPath: sidecarPath)
        }
        var lastError: Error = CacheError.downloadFailed(url: downloadBaseURL.absoluteString, status: nil)
        for attempt in 1...2 {
            do {
                try await downloadAndVerify(
                    assetName: assetName,
                    version: version,
                    expectedDigest: expectedDigest,
                    assetPath: assetPath,
                    sidecarPath: sidecarPath
                )
                if cacheDirectory != nil {
                    prune(directory: directory, keeping: version)
                }
                return assetPath
            } catch {
                lastError = error
                logger.warning("runner download attempt \(attempt) failed: \(String(describing: error))")
            }
        }
        throw lastError
    }

    func cleanupEphemeralArtifact(at path: String) {
        guard cacheDirectory == nil else {
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/" else {
            return
        }
        try? FileManager.default.removeItem(atPath: parent)
    }

    func newestVerifiedRelease() -> ResolvedRunnerRelease? {
        guard let cacheDirectory,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory) else {
            return nil
        }
        var digestsByVersion: [String: [String: String]] = [:]
        for entry in entries where Self.isRunnerTarball(entry) {
            guard let version = GitHubRunnerVersionResolver.extractVersion(from: entry) else {
                continue
            }
            let assetPath = (cacheDirectory as NSString).appendingPathComponent(entry)
            guard let sidecar = Self.readSidecar(at: assetPath + ".sha256"),
                  let actual = try? Self.sha256Hex(ofFileAt: assetPath),
                  actual == sidecar else {
                continue
            }
            digestsByVersion[version, default: [:]][entry] = sidecar
        }
        guard let newest = digestsByVersion.keys.max(by: {
            GitHubRunnerVersionResolver.compareVersionStrings($0, $1) == .orderedAscending
        }) else {
            return nil
        }
        return ResolvedRunnerRelease(version: newest, digests: digestsByVersion[newest] ?? [:])
    }

    static func sha256Hex(ofFileAt path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func workingDirectory() throws -> String {
        if let cacheDirectory {
            return cacheDirectory
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sand-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp.path
    }

    private func downloadAndVerify(
        assetName: String,
        version: String,
        expectedDigest: String,
        assetPath: String,
        sidecarPath: String
    ) async throws {
        let url = downloadBaseURL
            .appendingPathComponent("v\(version)")
            .appendingPathComponent(assetName)
        logger.info("runner download: \(url.absoluteString)")
        let tempURL = try await fetch(from: url)
        let actual = try Self.sha256Hex(ofFileAt: tempURL.path)
        guard actual == expectedDigest else {
            try? FileManager.default.removeItem(at: tempURL)
            throw CacheError.digestMismatch(asset: assetName, expected: expectedDigest, actual: actual)
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: assetPath)
        try fileManager.moveItem(atPath: tempURL.path, toPath: assetPath)
        try actual.write(toFile: sidecarPath, atomically: true, encoding: .utf8)
        logger.info("runner cache populated: \(assetPath)")
    }

    private func fetch(from url: URL) async throws -> URL {
        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CacheError.downloadFailed(url: url.absoluteString, status: nil)
            }
            let data = try Data(contentsOf: url)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try data.write(to: destination)
            return destination
        }
        let (tempURL, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw CacheError.downloadFailed(url: url.absoluteString, status: http.statusCode)
        }
        return tempURL
    }

    private func prune(directory: String, keeping version: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return
        }
        var versions = Set<String>()
        for entry in entries where Self.isRunnerTarball(entry) {
            if let version = GitHubRunnerVersionResolver.extractVersion(from: entry) {
                versions.insert(version)
            }
        }
        guard versions.count > Self.maxCachedVersions else {
            return
        }
        let sorted = versions.sorted {
            GitHubRunnerVersionResolver.compareVersionStrings($0, $1) == .orderedDescending
        }
        let stale = Set(sorted.dropFirst(Self.maxCachedVersions)).subtracting([version])
        for entry in entries where Self.isRunnerTarball(entry) {
            guard let version = GitHubRunnerVersionResolver.extractVersion(from: entry), stale.contains(version) else {
                continue
            }
            let assetPath = (directory as NSString).appendingPathComponent(entry)
            try? FileManager.default.removeItem(atPath: assetPath)
            try? FileManager.default.removeItem(atPath: assetPath + ".sha256")
            logger.info("runner cache pruned: \(entry)")
        }
    }

    private static func isRunnerTarball(_ name: String) -> Bool {
        name.hasPrefix("actions-runner-") && name.hasSuffix(".tar.gz")
    }

    private static func readSidecar(at path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
