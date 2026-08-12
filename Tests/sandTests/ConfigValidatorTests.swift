import Foundation
import XCTest
@testable import sand

final class ConfigValidatorTests: XCTestCase {
    func testValidConfigHasNoIssues() throws {
        let keyURL = try writeTempFile(contents: "key", suffix: ".pem")
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: Config.Cache(hostPath: "/tmp/sand-cache", name: nil),
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let github = GitHubProvisionerConfig(
            appId: 1,
            organization: "acme",
            repository: nil,
            privateKeyPath: keyURL.path,
            runnerName: "runner-1",
            extraLabels: nil,
            runnerGroup: nil
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .github, script: nil, github: github),
            preRun: nil,
            postRun: nil,
            stopAfter: 1,
            healthCheck: Config.HealthCheck(command: "true")
        )
        let config = Config(runners: [runner])
        let issues = ConfigValidator().validate(config)
        XCTAssertTrue(issues.isEmpty)
    }

    func testNegativeRecycleAfterOfflineIsRejected() throws {
        let keyURL = try writeTempFile(contents: "key", suffix: ".pem")
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: Config.Cache(hostPath: "/tmp/sand-cache", name: nil),
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let github = GitHubProvisionerConfig(
            appId: 1,
            organization: "acme",
            repository: nil,
            privateKeyPath: keyURL.path,
            runnerName: "runner-1",
            extraLabels: nil,
            runnerGroup: nil,
            recycleAfterOffline: -1
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .github, script: nil, github: github),
            preRun: nil,
            postRun: nil,
            stopAfter: 1,
            healthCheck: Config.HealthCheck(command: "true")
        )
        let config = Config(runners: [runner])
        let issues = ConfigValidator().validate(config)
        // Runner-scoped messages are prefixed with "runner <name>: " by the
        // validator (ConfigValidator.swift ~line 57), hence hasSuffix.
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.hasSuffix("provisioner.config.recycleAfterOffline must be >= 0 (0 disables offline recycling).") })
    }

    func testInfiniteRecycleAfterOfflineIsRejected() throws {
        let runner = try githubRunner(recycleAfterOffline: .infinity)
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: provisioner.config.recycleAfterOffline must be a finite number of seconds."
        )), "unexpected issues: \(issues)")
    }

    func testNaNRecycleAfterOfflineIsRejected() throws {
        let runner = try githubRunner(recycleAfterOffline: .nan)
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: provisioner.config.recycleAfterOffline must be a finite number of seconds."
        )), "unexpected issues: \(issues)")
    }

    func testNegativeInfiniteRecycleAfterOfflineIsRejected() throws {
        let runner = try githubRunner(recycleAfterOffline: -.infinity)
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: provisioner.config.recycleAfterOffline must be a finite number of seconds."
        )), "unexpected issues: \(issues)")
    }

    func testHugeRecycleAfterOfflineIsRejected() throws {
        let runner = try githubRunner(recycleAfterOffline: 1e30)
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: provisioner.config.recycleAfterOffline must be at most 31536000 seconds (one year)."
        )), "unexpected issues: \(issues)")
    }

    func testOneYearRecycleAfterOfflineIsAccepted() throws {
        let runner = try githubRunner(recycleAfterOffline: 31_536_000)
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.isEmpty, "unexpected issues: \(issues)")
    }

    private func githubRunner(recycleAfterOffline: TimeInterval) throws -> Config.RunnerConfig {
        let keyURL = try writeTempFile(contents: "key", suffix: ".pem")
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: Config.Cache(hostPath: "/tmp/sand-cache", name: nil),
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let github = GitHubProvisionerConfig(
            appId: 1,
            organization: "acme",
            repository: nil,
            privateKeyPath: keyURL.path,
            runnerName: "runner-1",
            extraLabels: nil,
            runnerGroup: nil,
            recycleAfterOffline: recycleAfterOffline
        )
        return Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .github, script: nil, github: github),
            preRun: nil,
            postRun: nil,
            stopAfter: nil,
            healthCheck: nil
        )
    }

    private func githubRunner(repository: String?, runnerGroup: String?) throws -> Config.RunnerConfig {
        let keyURL = try writeTempFile(contents: "key", suffix: ".pem")
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: Config.Cache(hostPath: "/tmp/sand-cache", name: nil),
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let github = GitHubProvisionerConfig(
            appId: 1,
            organization: "acme",
            repository: repository,
            privateKeyPath: keyURL.path,
            runnerName: "runner-1",
            extraLabels: nil,
            runnerGroup: runnerGroup
        )
        return Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .github, script: nil, github: github),
            preRun: nil,
            postRun: nil,
            stopAfter: nil,
            healthCheck: nil
        )
    }

    func testRunnerGroupWithOrgLevelRegistrationIsValid() throws {
        let runner = try githubRunner(repository: nil, runnerGroup: "macos-runners")
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.isEmpty, "unexpected issues: \(issues)")
    }

    func testRunnerGroupWithRepositoryIsRejected() throws {
        let runner = try githubRunner(repository: "repo", runnerGroup: "macos-runners")
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: provisioner.config.runnerGroup requires organization-level registration (remove repository)."
        )))
    }

    func testEmptyRunnerGroupIsRejected() throws {
        let runner = try githubRunner(repository: nil, runnerGroup: "  ")
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: provisioner.config.runnerGroup must not be empty when provided."
        )))
    }

    func testInvalidConfigReportsIssues() {
        let vm = Config.VM(
            source: Config.VMSource(type: .local, image: nil, path: "/missing-vm"),
            hardware: Config.Hardware(
                ramGb: 0,
                cpuCores: 0,
                display: Config.Display(width: 0, height: 0, unit: nil, refit: nil),
                audio: nil
            ),
            mounts: [Config.DirectoryMount(hostPath: "/missing-mount", name: "bad/name", mode: .rw)],
            cache: nil,
            run: .default,
            diskSizeGb: 0,
            ssh: Config.SSH(user: "", password: "", port: 70_000, connectMaxRetries: 0)
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .script, script: .init(run: "  "), github: nil),
            preRun: nil,
            postRun: nil,
            stopAfter: 0,
            healthCheck: Config.HealthCheck(command: "  ", interval: 0, delay: -1)
        )
        let config = Config(runners: [runner])
        let issues = ConfigValidator().validate(config)
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .warning, message: "runner runner-1: stopAfter is 0; sand will exit immediately.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: Local VM path does not exist: /missing-vm.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.hardware.ramGb must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.hardware.cpuCores must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.hardware.display width/height must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.diskSizeGb must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.ssh.user must not be empty.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.ssh.password must not be empty.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.ssh.port must be between 1 and 65535.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.ssh.connectMaxRetries must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.mounts.name must not contain '/'.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: provisioner.config.run must not be empty for script provisioner.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: healthCheck.command must not be empty.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: healthCheck.interval must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: healthCheck.delay must be greater than or equal to 0.")))
    }

    func testLocalSourceOutsideTartVMsIsRejected() throws {
        let vmDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
        let vm = Config.VM(
            source: Config.VMSource(type: .local, image: nil, path: vmDir.path),
            hardware: nil,
            mounts: [],
            cache: nil,
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .script, script: .init(run: "echo ok"), github: nil),
            preRun: nil,
            postRun: nil,
            stopAfter: nil,
            healthCheck: nil
        )
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: Local VM path must be inside \(Config.tartVMsDirectory) so tart can clone it by name: \(vmDir.path)."
        )))
    }

    func testLocalSourceUnderTartVMsIsValid() throws {
        let tartHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("TART_HOME", tartHome.path, 1)
        defer { unsetenv("TART_HOME") }
        let vmDir = tartHome.appendingPathComponent("vms/base-vm")
        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
        let vm = Config.VM(
            source: Config.VMSource(type: .local, image: nil, path: vmDir.path),
            hardware: nil,
            mounts: [],
            cache: nil,
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .script, script: .init(run: "echo ok"), github: nil),
            preRun: nil,
            postRun: nil,
            stopAfter: nil,
            healthCheck: nil
        )
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.isEmpty, "unexpected issues: \(issues)")
    }

    func testDuplicateRunnerNamesAreRejected() {
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: nil,
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let provisioner = Config.Provisioner(type: .script, script: .init(run: "echo hi"), github: nil)
        let runners = [
            Config.RunnerConfig(name: "same", vm: vm, provisioner: provisioner, preRun: nil, postRun: nil, stopAfter: nil, healthCheck: nil),
            Config.RunnerConfig(name: "same", vm: vm, provisioner: provisioner, preRun: nil, postRun: nil, stopAfter: nil, healthCheck: nil)
        ]
        let config = Config(runners: runners)
        let issues = ConfigValidator().validate(config)
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner name must be unique: same.")))
    }

    func testRunnerCacheValidation() throws {
        let cacheFile = try writeTempFile(contents: "not-a-directory")
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: Config.Cache(hostPath: cacheFile.path, name: "sand-cache"),
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .script, script: .init(run: "echo ok"), github: nil),
            preRun: nil,
            postRun: nil,
            stopAfter: nil,
            healthCheck: nil
        )
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .warning,
            message: "runner runner-1: vm.cache is set but provisioner is not github; cache will be ignored."
        )))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .warning,
            message: "runner runner-1: vm.cache.name is ignored: the runner cache is no longer mounted into VMs."
        )))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: vm.cache.host must be a directory: \(cacheFile.path)."
        )))
        XCTAssertFalse(issues.contains { $0.message.contains("must not contain") })
    }
}
