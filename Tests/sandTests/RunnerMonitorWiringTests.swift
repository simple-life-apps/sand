import Foundation
import Testing
@testable import sand

private actor RecycleWiringRecorder {
    private(set) var failures: [MonitorFailure] = []
    private(set) var terminations = 0

    func markFailed(_ failure: MonitorFailure) {
        failures.append(failure)
    }

    func terminate() {
        terminations += 1
    }
}

private actor PollCounter {
    private(set) var calls = 0

    func next() -> GitHubService.RunnerLookup {
        calls += 1
        return .registered(GitHubService.RunnerStatus(connection: .online, busy: false))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RunnerMonitorWiringTests {
    @Test func offlineCauseIsAttributedAsRunnerOfflineAndTerminatesProvisioning() async {
        let recorder = RecycleWiringRecorder()
        let handler = Runner.monitorRecycleHandler(
            markFailed: { await recorder.markFailed($0) },
            terminate: { await recorder.terminate() }
        )
        await handler(.offlinePastThreshold, "runner r-1 offline on GitHub past threshold")
        #expect(await recorder.failures == [.runnerOffline("runner r-1 offline on GitHub past threshold")])
        #expect(await recorder.terminations == 1)
    }

    @Test func missingCauseIsAttributedAsRunnerMissingAndTerminatesProvisioning() async {
        let recorder = RecycleWiringRecorder()
        let handler = Runner.monitorRecycleHandler(
            markFailed: { await recorder.markFailed($0) },
            terminate: { await recorder.terminate() }
        )
        await handler(.missing, "runner r-1 no longer registered on GitHub")
        #expect(await recorder.failures == [.runnerMissing("runner r-1 no longer registered on GitHub")])
        #expect(await recorder.terminations == 1)
    }

    @Test func monitorIsCancelledWhenTheBodyReturns() async {
        let poll = PollCounter()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { await poll.next() },
            onRecycle: { _, _ in },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        let result = await Runner.withOfflineMonitor(monitor) {
            var calls = 0
            var attempts = 0
            while calls < 3, attempts < 200 {
                attempts += 1
                try? await Task.sleep(for: .milliseconds(5))
                calls = await poll.calls
            }
            return "done"
        }
        #expect(result == "done")
        let callsAtReturn = await poll.calls
        #expect(callsAtReturn >= 3, "the test is vacuous unless the monitor polled while the body ran")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await poll.calls == callsAtReturn, "the monitor must stop polling once the provisioner returns")
    }

    @Test func withoutAMonitorTheBodyRunsDirectly() async {
        let result = await Runner.withOfflineMonitor(nil) { "direct" }
        #expect(result == "direct")
    }

    @Test func firstRecordedFailureWinsAndResumesWaiters() async throws {
        let state = MonitorFailureState()
        let waiter = Task {
            try await state.waitForFailure()
        }
        try? await Task.sleep(for: .milliseconds(10))
        await state.markFailed(.runnerMissing("first"))
        await state.markFailed(.healthCheck("second"))
        let observed = try await waiter.value
        #expect(observed == .runnerMissing("first"))
        #expect(await state.failure() == .runnerMissing("first"), "a later failure must not overwrite the cause that triggered the recycle")
    }

    @Test func waiterJoiningAfterTheFailureGetsItImmediately() async throws {
        let state = MonitorFailureState()
        await state.markFailed(.runnerOffline("gone"))
        let observed = try await state.waitForFailure()
        #expect(observed == .runnerOffline("gone"))
    }
}
