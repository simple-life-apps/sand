import CryptoKit
import Foundation
import Testing
@testable import sand

@Suite struct RunnerCacheManagerTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func testLogger() -> Logger {
        Logger(label: "test", minimumLevel: .error, sink: nil)
    }

    private func writeAsset(dir: URL, name: String, content: String, sidecar: String?) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        if let sidecar {
            try sidecar.write(toFile: path + ".sha256", atomically: true, encoding: .utf8)
        }
        return path
    }

    private func sha256(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func makeReleaseSource(version: String, assetName: String, content: String) throws -> URL {
        let base = try makeTempDir()
        let versionDir = base.appendingPathComponent("v\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        try content.write(to: versionDir.appendingPathComponent(assetName), atomically: true, encoding: .utf8)
        return base
    }

    @Test func verifiedCacheHitSkipsDownload() async throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let asset = "actions-runner-osx-arm64-2.331.0.tar.gz"
        let digest = sha256("payload")
        _ = try writeAsset(dir: cacheDir, name: asset, content: "payload", sidecar: digest)
        let manager = RunnerCacheManager(
            cacheDirectory: cacheDir.path,
            logger: testLogger(),
            downloadBaseURL: URL(fileURLWithPath: "/nonexistent")
        )
        let path = try await manager.verifiedAsset(assetName: asset, version: "2.331.0", expectedDigest: digest)
        #expect(path == cacheDir.appendingPathComponent(asset).path)
    }

    @Test func legacyFileWithoutSidecarIsReplaced() async throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let asset = "actions-runner-osx-arm64-2.331.0.tar.gz"
        _ = try writeAsset(dir: cacheDir, name: asset, content: "poisoned", sidecar: nil)
        let source = try makeReleaseSource(version: "2.331.0", assetName: asset, content: "genuine")
        defer { try? FileManager.default.removeItem(at: source) }
        let digest = sha256("genuine")
        let manager = RunnerCacheManager(cacheDirectory: cacheDir.path, logger: testLogger(), downloadBaseURL: source)
        let path = try await manager.verifiedAsset(assetName: asset, version: "2.331.0", expectedDigest: digest)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "genuine")
        let sidecar = try String(contentsOfFile: path + ".sha256", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(sidecar == digest)
    }

    @Test func sidecarMismatchTriggersRedownload() async throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let asset = "actions-runner-osx-arm64-2.331.0.tar.gz"
        _ = try writeAsset(dir: cacheDir, name: asset, content: "tampered", sidecar: sha256("something-else"))
        let source = try makeReleaseSource(version: "2.331.0", assetName: asset, content: "genuine")
        defer { try? FileManager.default.removeItem(at: source) }
        let digest = sha256("genuine")
        let manager = RunnerCacheManager(cacheDirectory: cacheDir.path, logger: testLogger(), downloadBaseURL: source)
        let path = try await manager.verifiedAsset(assetName: asset, version: "2.331.0", expectedDigest: digest)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "genuine")
    }

    @Test func downloadDigestMismatchThrows() async throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let asset = "actions-runner-osx-arm64-2.331.0.tar.gz"
        let source = try makeReleaseSource(version: "2.331.0", assetName: asset, content: "evil")
        defer { try? FileManager.default.removeItem(at: source) }
        let manager = RunnerCacheManager(cacheDirectory: cacheDir.path, logger: testLogger(), downloadBaseURL: source)
        await #expect(throws: (any Error).self) {
            _ = try await manager.verifiedAsset(assetName: asset, version: "2.331.0", expectedDigest: sha256("genuine"))
        }
        #expect(!FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(asset).path))
    }

    @Test func tempDirModeWorksWithoutCacheDirectory() async throws {
        let asset = "actions-runner-osx-arm64-2.331.0.tar.gz"
        let source = try makeReleaseSource(version: "2.331.0", assetName: asset, content: "genuine")
        defer { try? FileManager.default.removeItem(at: source) }
        let digest = sha256("genuine")
        let manager = RunnerCacheManager(cacheDirectory: nil, logger: testLogger(), downloadBaseURL: source)
        let path = try await manager.verifiedAsset(assetName: asset, version: "2.331.0", expectedDigest: digest)
        #expect(FileManager.default.fileExists(atPath: path))
        manager.cleanupEphemeralArtifact(at: path)
    }

    @Test func cleanupEphemeralArtifactRemovesTempWorkingDir() async throws {
        let asset = "actions-runner-osx-arm64-2.331.0.tar.gz"
        let source = try makeReleaseSource(version: "2.331.0", assetName: asset, content: "genuine")
        defer { try? FileManager.default.removeItem(at: source) }
        let digest = sha256("genuine")
        let manager = RunnerCacheManager(cacheDirectory: nil, logger: testLogger(), downloadBaseURL: source)
        let path = try await manager.verifiedAsset(assetName: asset, version: "2.331.0", expectedDigest: digest)
        let workingDir = (path as NSString).deletingLastPathComponent
        #expect(FileManager.default.fileExists(atPath: path))
        manager.cleanupEphemeralArtifact(at: path)
        #expect(!FileManager.default.fileExists(atPath: workingDir))
    }

    @Test func cleanupEphemeralArtifactLeavesCacheDirIntact() throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let asset = "actions-runner-osx-arm64-2.331.0.tar.gz"
        let digest = sha256("payload")
        let path = try writeAsset(dir: cacheDir, name: asset, content: "payload", sidecar: digest)
        let manager = RunnerCacheManager(cacheDirectory: cacheDir.path, logger: testLogger())
        manager.cleanupEphemeralArtifact(at: path)
        #expect(FileManager.default.fileExists(atPath: cacheDir.path))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func pruneKeepsJustResolvedOlderVersion() async throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        for minor in 326...330 {
            _ = try writeAsset(
                dir: cacheDir,
                name: "actions-runner-osx-arm64-2.\(minor).0.tar.gz",
                content: "v\(minor)",
                sidecar: sha256("v\(minor)")
            )
        }
        let asset = "actions-runner-osx-arm64-2.325.0.tar.gz"
        let source = try makeReleaseSource(version: "2.325.0", assetName: asset, content: "old")
        defer { try? FileManager.default.removeItem(at: source) }
        let manager = RunnerCacheManager(cacheDirectory: cacheDir.path, logger: testLogger(), downloadBaseURL: source)
        let path = try await manager.verifiedAsset(assetName: asset, version: "2.325.0", expectedDigest: sha256("old"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: path + ".sha256"))
        let entries = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(entries.contains("actions-runner-osx-arm64-2.325.0.tar.gz"))
        #expect(entries.contains("actions-runner-osx-arm64-2.325.0.tar.gz.sha256"))
    }

    @Test func newestVerifiedReleaseIgnoresUnverifiedFiles() throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let goodDigest = sha256("good")
        _ = try writeAsset(dir: cacheDir, name: "actions-runner-osx-arm64-2.330.0.tar.gz", content: "good", sidecar: goodDigest)
        _ = try writeAsset(dir: cacheDir, name: "actions-runner-osx-arm64-2.331.0.tar.gz", content: "no-sidecar", sidecar: nil)
        _ = try writeAsset(dir: cacheDir, name: "actions-runner-osx-arm64-2.332.0.tar.gz", content: "bad", sidecar: sha256("other"))
        let manager = RunnerCacheManager(cacheDirectory: cacheDir.path, logger: testLogger())
        let release = manager.newestVerifiedRelease()
        #expect(release?.version == "2.330.0")
        #expect(release?.digests["actions-runner-osx-arm64-2.330.0.tar.gz"] == goodDigest)
    }

    @Test func newestVerifiedReleasePicksHighestVersion() throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        _ = try writeAsset(dir: cacheDir, name: "actions-runner-osx-arm64-2.330.0.tar.gz", content: "a", sidecar: sha256("a"))
        _ = try writeAsset(dir: cacheDir, name: "actions-runner-osx-arm64-2.331.0.tar.gz", content: "b", sidecar: sha256("b"))
        let manager = RunnerCacheManager(cacheDirectory: cacheDir.path, logger: testLogger())
        #expect(manager.newestVerifiedRelease()?.version == "2.331.0")
    }

    @Test func pruneKeepsFiveNewestVersionsAndForeignFiles() async throws {
        let cacheDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        for minor in 325...329 {
            _ = try writeAsset(
                dir: cacheDir,
                name: "actions-runner-osx-arm64-2.\(minor).0.tar.gz",
                content: "v\(minor)",
                sidecar: sha256("v\(minor)")
            )
        }
        try "keep me".write(to: cacheDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let asset = "actions-runner-osx-arm64-2.330.0.tar.gz"
        let source = try makeReleaseSource(version: "2.330.0", assetName: asset, content: "new")
        defer { try? FileManager.default.removeItem(at: source) }
        let manager = RunnerCacheManager(cacheDirectory: cacheDir.path, logger: testLogger(), downloadBaseURL: source)
        _ = try await manager.verifiedAsset(assetName: asset, version: "2.330.0", expectedDigest: sha256("new"))
        let entries = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(!entries.contains("actions-runner-osx-arm64-2.325.0.tar.gz"))
        #expect(!entries.contains("actions-runner-osx-arm64-2.325.0.tar.gz.sha256"))
        #expect(entries.contains("actions-runner-osx-arm64-2.326.0.tar.gz"))
        #expect(entries.contains("actions-runner-osx-arm64-2.330.0.tar.gz"))
        #expect(entries.contains("notes.txt"))
    }
}
