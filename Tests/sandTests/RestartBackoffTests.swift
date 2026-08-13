import XCTest
@testable import sand

final class RestartBackoffTests: XCTestCase {
    func testBackoffIncreasesForSameReason() async {
        let policy = RestartBackoffPolicy(baseDelay: 1, maxDelay: 8, multiplier: 2)
        let backoff = RestartBackoff(policy: policy)
        let first = await backoff.schedule(reason: .sshNotReady)
        let second = await backoff.schedule(reason: .sshNotReady)
        let third = await backoff.schedule(reason: .sshNotReady)
        let fourth = await backoff.schedule(reason: .sshNotReady)
        let fifth = await backoff.schedule(reason: .sshNotReady)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 4)
        XCTAssertEqual(fourth, 8)
        XCTAssertEqual(fifth, 8)
    }

    func testBackoffResetsOnReasonChange() async {
        let policy = RestartBackoffPolicy(baseDelay: 1, maxDelay: 60, multiplier: 2)
        let backoff = RestartBackoff(policy: policy)
        let first = await backoff.schedule(reason: .sshNotReady)
        let second = await backoff.schedule(reason: .sshNotReady)
        let third = await backoff.schedule(reason: .stageFailed("preRun"))
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 1)
    }

    func testTakePendingClearsDelay() async {
        let policy = RestartBackoffPolicy(baseDelay: 1, maxDelay: 60, multiplier: 2)
        let backoff = RestartBackoff(policy: policy)
        _ = await backoff.schedule(reason: .sshNotReady)
        let pending = await backoff.takePending()
        let next = await backoff.takePending()
        XCTAssertEqual(pending.0, 1)
        XCTAssertEqual(next.0, 0)
    }

    func testBackoffEscalatesAcrossBootsForRunnerOffline() async {
        let policy = RestartBackoffPolicy(baseDelay: 1, maxDelay: 60, multiplier: 2)
        let backoff = RestartBackoff(policy: policy)
        let first = await backoff.schedule(reason: .runnerOffline("runner r-1-a3f9c offline on GitHub past threshold"))
        let second = await backoff.schedule(reason: .runnerOffline("runner r-1-7b21e offline on GitHub past threshold"))
        let third = await backoff.schedule(reason: .runnerOffline("runner r-1-fe004 offline on GitHub past threshold"))
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 4)
    }

    func testRunnerMissingReasonDescription() {
        let reason = RestartReason.runnerMissing("runner r-1 no longer registered on GitHub")
        XCTAssertEqual(String(describing: reason), "runner missing: runner r-1 no longer registered on GitHub")
        XCTAssertEqual(reason.backoffKey, "runnerMissing")
    }

    func testRunnerMissingEscalatesAcrossBootsButResetsAgainstOffline() async {
        let policy = RestartBackoffPolicy(baseDelay: 1, maxDelay: 60, multiplier: 2)
        let backoff = RestartBackoff(policy: policy)
        let first = await backoff.schedule(reason: .runnerMissing("runner r-1-a3f9c no longer registered on GitHub"))
        let second = await backoff.schedule(reason: .runnerMissing("runner r-1-7b21e no longer registered on GitHub"))
        let third = await backoff.schedule(reason: .runnerOffline("runner r-1-fe004 offline on GitHub past threshold"))
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 1, "a cause change resets the attempt count; the keys must not share an escalation counter")
    }

    func testProvisionerExitedNeverEscalates() async {
        let policy = RestartBackoffPolicy(baseDelay: 1, maxDelay: 60, multiplier: 2)
        let backoff = RestartBackoff(policy: policy)
        for _ in 0..<5 {
            let delay = await backoff.schedule(reason: .provisionerExited)
            XCTAssertEqual(delay, 1, "a clean ephemeral runner cycle is not a failure; the delay between jobs must stay at the base")
        }
    }

    func testFailureAfterProvisionerExitedStartsAtBaseDelay() async {
        let policy = RestartBackoffPolicy(baseDelay: 1, maxDelay: 60, multiplier: 2)
        let backoff = RestartBackoff(policy: policy)
        _ = await backoff.schedule(reason: .provisionerExited)
        _ = await backoff.schedule(reason: .provisionerExited)
        let failure = await backoff.schedule(reason: .sshNotReady)
        let repeated = await backoff.schedule(reason: .sshNotReady)
        XCTAssertEqual(failure, 1)
        XCTAssertEqual(repeated, 2)
    }

    func testRunnerOfflineReasonDescriptionAndEquality() {
        let reason = RestartReason.runnerOffline("runner r-1 offline on GitHub for 600s+")
        XCTAssertEqual(String(describing: reason), "runner offline: runner r-1 offline on GitHub for 600s+")
        XCTAssertNotEqual(reason, RestartReason.healthCheckFailed("runner r-1 offline on GitHub for 600s+"))
    }
}
