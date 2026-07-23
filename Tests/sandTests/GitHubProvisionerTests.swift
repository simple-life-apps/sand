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
        let script = provisioner.script(config: config, runnerToken: "token", runnerName: config.runnerName)
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
        let script = provisioner.script(config: config, runnerToken: "token", runnerName: config.runnerName)
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
        let script = provisioner.script(config: config, runnerToken: "token", runnerName: config.runnerName)
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
        let script = provisioner.script(config: config, runnerToken: "token", runnerName: config.runnerName)
        XCTAssertTrue(script[0].contains("actions-runner.tar.gz"))
        XCTAssertTrue(script[0].contains("exit 1"))
    }

    func testUniqueRunnerNameFormat() {
        let name = GitHubProvisioner.uniqueRunnerName(base: "ios-runner-2")
        XCTAssertNotNil(name.range(of: "^ios-runner-2-[0-9a-f]{5}$", options: .regularExpression))
    }

    func testUniqueRunnerNameVaries() {
        let names = Set((0..<20).map { _ in GitHubProvisioner.uniqueRunnerName(base: "r") })
        XCTAssertGreaterThan(names.count, 1)
    }

    func testScriptUsesProvidedRunnerName() {
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
        let script = provisioner.script(config: config, runnerToken: "token", runnerName: "runner-1-a3f9c")
        XCTAssertTrue(script.joined(separator: "\n").contains("--name runner-1-a3f9c"))
    }
}
