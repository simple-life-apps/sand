import Foundation
import Testing
@testable import sand

private actor OfflineThenOnlinePoll {
    private var calls = 0

    func next() -> GitHubService.RunnerLookup {
        calls += 1
        return .registered(GitHubService.RunnerStatus(connection: calls > 2 ? .online : .offline, busy: false))
    }
}

private actor RecycleRecorder {
    private(set) var messages: [String] = []
    func record(_ message: String) {
        messages.append(message)
    }
}

private actor PollAlternator {
    private var calls = 0

    func nextIsError() -> Bool {
        let index = calls % 12
        calls += 1
        return index < 10
    }
}

struct OfflineMonitorTests {
    @Test func signalMapping() {
        #expect(OfflineMonitor.signal(for: .notRegistered) == .offline)
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .offline, busy: false))) == .offline)
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .online, busy: false))) == .healthy)
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .online, busy: true))) == .healthy)
        // Busy wins even if GitHub reports the runner offline mid-job.
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .offline, busy: true))) == .healthy)
    }

    // Incident replay: registered, then permanently offline (this is the
    // spec's acceptance scenario). Must recycle once threshold is exceeded.
    @Test func permanentlyOfflineRunnerTriggersRecycle() async {
        let recorder = RecycleRecorder()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .milliseconds(25),
            pollInterval: .milliseconds(5),
            poll: { .registered(GitHubService.RunnerStatus(connection: .offline, busy: false)) },
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
            poll: { .notRegistered },
            onRecycle: { await recorder.record($0) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        await monitor.run()
        let messages = await recorder.messages
        #expect(messages.count == 1)
    }

    @Test func busyRunnerNeverRecyclesAndErrorsFreeze() async {
        let recorder = RecycleRecorder()
        let alternator = PollAlternator()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .milliseconds(10),
            pollInterval: .milliseconds(2),
            poll: {
                struct PollError: Error {}
                // Alternate runs of errors and busy polls: neither may ever
                // fire. Each error run spans more than the threshold, so an
                // error counted as offline instead of unknown would recycle.
                if await alternator.nextIsError() {
                    throw PollError()
                }
                return .registered(GitHubService.RunnerStatus(connection: .online, busy: true))
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

    @Test func offlineAndRecoveryTransitionsAreLogged() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let poll = OfflineThenOnlinePoll()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { await poll.next() },
            onRecycle: { _ in },
            logger: Logger(label: "test", minimumLevel: .debug, sink: sink)
        )
        let task = Task { await monitor.run() }
        var contents = ""
        var attempts = 0
        while !contents.contains("back online after"), attempts < 200 {
            attempts += 1
            contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            if contents.contains("back online after") {
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        await task.value
        #expect(contents.contains("runner r-1 reported offline on GitHub"))
        #expect(contents.contains("runner r-1 back online after"))
        #expect(contents.contains("offline monitor poll (runner=r-1"))
        let transitions = contents.split(separator: "\n").filter { $0.contains("reported offline on GitHub") }
        #expect(transitions.count == 1, "the offline transition must be logged once per run, not once per poll")
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func cancellationStopsTheLoop() async {
        let recorder = RecycleRecorder()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { .registered(GitHubService.RunnerStatus(connection: .offline, busy: false)) },
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
