import Foundation
import XCTest
@testable import sand

final class GitHubProvisionerTests: XCTestCase {
    func testScriptWithExtraLabels() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: "repo",
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: ["fast", "arm64"],
            runnerGroup: nil
        )
        let script = provisioner.script(config: config, runnerToken: "token")
        let joined = script.joined(separator: "\n")
        XCTAssertTrue(joined.contains("--labels sand,fast,arm64"))
        XCTAssertTrue(joined.contains("--url https://github.com/org/repo"))
        XCTAssertFalse(joined.contains("curl"))
        XCTAssertFalse(joined.contains("releases/download"))
    }

    func testScriptWithDefaultLabels() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: nil,
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: nil,
            runnerGroup: nil
        )
        let script = provisioner.script(config: config, runnerToken: "token")
        let joined = script.joined(separator: "\n")
        XCTAssertTrue(joined.contains("--labels sand"))
        XCTAssertTrue(joined.contains("--url https://github.com/org"))
        XCTAssertFalse(joined.contains("--runnergroup"))
    }

    func testScriptWithRunnerGroup() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: nil,
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: nil,
            runnerGroup: "macos runners"
        )
        let script = provisioner.script(config: config, runnerToken: "token")
        XCTAssertTrue(script.joined(separator: "\n").contains("--runnergroup 'macos runners'"))
    }

    func testScriptFailsWhenTarballMissing() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: nil,
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: nil,
            runnerGroup: nil
        )
        let script = provisioner.script(config: config, runnerToken: "token")
        XCTAssertTrue(script[0].contains("actions-runner.tar.gz"))
        XCTAssertTrue(script[0].contains("exit 1"))
    }
}
