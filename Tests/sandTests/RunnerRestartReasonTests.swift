import XCTest
@testable import sand

final class RunnerRestartReasonTests: XCTestCase {
    func testHealthCheckFailureMapsToHealthCheckFailed() {
        XCTAssertEqual(Runner.restartReason(for: .healthCheck("exit code 1")), .healthCheckFailed("exit code 1"))
    }

    func testRunnerOfflineFailureMapsToRunnerOffline() {
        XCTAssertEqual(Runner.restartReason(for: .runnerOffline("runner r-1 offline")), .runnerOffline("runner r-1 offline"))
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
