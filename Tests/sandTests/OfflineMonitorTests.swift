import Testing
@testable import sand

private actor RecycleRecorder {
    private(set) var messages: [String] = []
    func record(_ message: String) {
        messages.append(message)
    }
}

struct OfflineMonitorTests {
    @Test func signalMapping() {
        #expect(OfflineMonitor.signal(for: nil) == .offline)
        #expect(OfflineMonitor.signal(for: .init(online: false, busy: false)) == .offline)
        #expect(OfflineMonitor.signal(for: .init(online: true, busy: false)) == .healthy)
        #expect(OfflineMonitor.signal(for: .init(online: true, busy: true)) == .healthy)
        // Busy wins even if GitHub reports the runner offline mid-job.
        #expect(OfflineMonitor.signal(for: .init(online: false, busy: true)) == .healthy)
    }

    // Incident replay: registered, then permanently offline (this is the
    // spec's acceptance scenario). Must recycle once threshold is exceeded.
    @Test func permanentlyOfflineRunnerTriggersRecycle() async {
        let recorder = RecycleRecorder()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .milliseconds(25),
            pollInterval: .milliseconds(5),
            poll: { GitHubService.RunnerStatus(online: false, busy: false) },
            onRecycle: { await recorder.record($0) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        await monitor.run()
        let messages = await recorder.messages
        #expect(messages.count == 1)
        #expect(messages[0].contains("r-1"))
    }

    @Test func unregisteredRunnerTriggersRecycle() async {
        let recorder = RecycleRecorder()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .milliseconds(25),
            pollInterval: .milliseconds(5),
            poll: { nil },
            onRecycle: { await recorder.record($0) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        await monitor.run()
        let messages = await recorder.messages
        #expect(messages.count == 1)
    }

    @Test func busyRunnerNeverRecyclesAndErrorsFreeze() async {
        let recorder = RecycleRecorder()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .milliseconds(10),
            pollInterval: .milliseconds(2),
            poll: {
                struct PollError: Error {}
                // Alternate busy and error: neither may ever fire.
                if Bool.random() { throw PollError() }
                return GitHubService.RunnerStatus(online: true, busy: true)
            },
            onRecycle: { await recorder.record($0) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        let task = Task { await monitor.run() }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await task.value
        let messages = await recorder.messages
        #expect(messages.isEmpty)
    }

    @Test func cancellationStopsTheLoop() async {
        let recorder = RecycleRecorder()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { GitHubService.RunnerStatus(online: false, busy: false) },
            onRecycle: { await recorder.record($0) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        let task = Task { await monitor.run() }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await task.value  // must return promptly; awaiting out is the isolation guarantee
        let messages = await recorder.messages
        #expect(messages.isEmpty)
    }
}
