import XCTest
@testable import sand

final class OfflineRecyclingThresholdTests: XCTestCase {
    func testDisabledHasNoThresholdSoNoMonitorIsBuilt() {
        XCTAssertNil(OfflineRecycling.disabled.threshold)
    }

    func testAfterExposesItsThreshold() {
        XCTAssertEqual(OfflineRecycling.after(.seconds(600)).threshold, .seconds(600))
    }
}

final class RunnerRestartReasonTests: XCTestCase {
    func testHealthCheckFailureMapsToHealthCheckFailed() {
        XCTAssertEqual(Runner.restartReason(for: .healthCheck("exit code 1")), .healthCheckFailed("exit code 1"))
    }

    func testRunnerOfflineFailureMapsToRunnerOffline() {
        XCTAssertEqual(Runner.restartReason(for: .runnerOffline("runner r-1 offline")), .runnerOffline("runner r-1 offline"))
    }

    func testRunnerMissingFailureMapsToRunnerMissing() {
        XCTAssertEqual(
            Runner.restartReason(for: .runnerMissing("runner r-1 no longer registered on GitHub")),
            .runnerMissing("runner r-1 no longer registered on GitHub")
        )
    }

    func testCompletedProvisionerPrefersRecordedMissingFailure() {
        XCTAssertEqual(
            Runner.restartReason(forCompletedProvisionerWith: .runnerMissing("runner r-1 no longer registered on GitHub")),
            .runnerMissing("runner r-1 no longer registered on GitHub")
        )
    }

    func testCompletedProvisionerWithoutFailureIsProvisionerExited() {
        XCTAssertEqual(Runner.restartReason(forCompletedProvisionerWith: nil), .provisionerExited)
    }

    func testCompletedProvisionerPrefersRecordedOfflineFailure() {
        XCTAssertEqual(
            Runner.restartReason(forCompletedProvisionerWith: .runnerOffline("runner r-1 offline")),
            .runnerOffline("runner r-1 offline")
        )
    }
}
