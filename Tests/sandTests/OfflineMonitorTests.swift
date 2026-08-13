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
    private(set) var events: [(cause: OfflineMonitor.RecycleCause, message: String)] = []
    var messages: [String] { events.map(\.message) }
    var causes: [OfflineMonitor.RecycleCause] { events.map(\.cause) }
    func record(_ cause: OfflineMonitor.RecycleCause, _ message: String) {
        events.append((cause, message))
    }
}

private actor ScriptedPoll {
    enum Step {
        case missing
        case online
        case error
    }

    private let script: [Step]
    private(set) var calls = 0

    init(_ script: [Step]) {
        self.script = script
    }

    func next() throws -> GitHubService.RunnerLookup {
        struct PollError: Error {}
        let step = script[calls % script.count]
        calls += 1
        switch step {
        case .missing:
            return .notRegistered
        case .online:
            return .registered(GitHubService.RunnerStatus(connection: .online, busy: false))
        case .error:
            throw PollError()
        }
    }
}

private actor PollAlternator {
    private(set) var calls = 0

    func nextIsError() -> Bool {
        let index = calls % 12
        calls += 1
        return index < 10
    }
}

@Suite(.timeLimit(.minutes(1)))
struct OfflineMonitorTests {
    @Test func signalMapping() {
        #expect(OfflineMonitor.signal(for: .notRegistered) == .offline)
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .offline, busy: false))) == .offline)
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .online, busy: false))) == .healthy)
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .online, busy: true))) == .healthy)
        // A busy claim without an online connection freezes the timer rather
        // than vouching for health: GitHub keeps busy=true for a runner that
        // died mid-job until the job is reaped.
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .offline, busy: true))) == .unknown)
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .unrecognized("idle"), busy: false))) == .unknown)
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .unrecognized(nil), busy: false))) == .unknown)
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .unrecognized(nil), busy: true))) == .unknown)
    }

    @Test func permanentlyOfflineRunnerTriggersRecycle() async {
        let recorder = RecycleRecorder()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .milliseconds(25),
            pollInterval: .milliseconds(5),
            poll: { .registered(GitHubService.RunnerStatus(connection: .offline, busy: false)) },
            onRecycle: { await recorder.record($0, $1) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        await monitor.run()
        let events = await recorder.events
        #expect(events.count == 1)
        #expect(events[0].cause == .offlinePastThreshold)
        #expect(events[0].message.contains("r-1"))
    }

    @Test func unregisteredRunnerTriggersFastRecycleWithMissingCause() async {
        let recorder = RecycleRecorder()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { .notRegistered },
            onRecycle: { await recorder.record($0, $1) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        await monitor.run()
        let events = await recorder.events
        #expect(events.count == 1)
        #expect(events[0].cause == .missing)
        #expect(events[0].message.contains("no longer registered"))
    }

    @Test func registeredPollResetsTheMissingStreak() async {
        let recorder = RecycleRecorder()
        let poll = ScriptedPoll([.missing, .missing, .online])
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { try await poll.next() },
            onRecycle: { await recorder.record($0, $1) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        let task = Task { await monitor.run() }
        var calls = 0
        var attempts = 0
        while calls < 12, attempts < 200 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(5))
            calls = await poll.calls
        }
        task.cancel()
        await task.value
        let events = await recorder.events
        #expect(calls >= 12, "the test is vacuous unless several miss/miss/online cycles ran")
        #expect(events.isEmpty)
    }

    @Test func pollErrorsPreserveTheMissingStreak() async {
        let recorder = RecycleRecorder()
        let poll = ScriptedPoll([.missing, .error, .error, .missing, .error, .missing])
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { try await poll.next() },
            onRecycle: { await recorder.record($0, $1) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        await monitor.run()
        let events = await recorder.events
        #expect(events.count == 1)
        #expect(events[0].cause == .missing)
    }

    @Test func subFloorThresholdRecyclesAsOfflineBeforeThirdMiss() async {
        let recorder = RecycleRecorder()
        let poll = ScriptedPoll([.missing])
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .milliseconds(1),
            pollInterval: .milliseconds(5),
            poll: { try await poll.next() },
            onRecycle: { await recorder.record($0, $1) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        await monitor.run()
        let events = await recorder.events
        let calls = await poll.calls
        #expect(events.count == 1)
        #expect(events[0].cause == .offlinePastThreshold)
        #expect(calls == 2, "a threshold below one poll interval must trip the timer on the second poll")
    }

    @Test func missingCauseWinsWhenTimerAndStreakTripOnTheSamePoll() async {
        let recorder = RecycleRecorder()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .milliseconds(60),
            pollInterval: .milliseconds(30),
            poll: { .notRegistered },
            onRecycle: { await recorder.record($0, $1) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        await monitor.run()
        let events = await recorder.events
        #expect(events.count == 1)
        #expect(events[0].cause == .missing)
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
            onRecycle: { await recorder.record($0, $1) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        let task = Task { await monitor.run() }
        var polls = 0
        var attempts = 0
        while polls < 24, attempts < 200 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(5))
            polls = await alternator.calls
        }
        task.cancel()
        await task.value
        let messages = await recorder.messages
        #expect(polls >= 24, "the test is vacuous unless at least two full error/busy cycles ran")
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
            onRecycle: { _, _ in },
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

    @Test func sustainedPollFailuresEscalateToASingleErrorAlarm() async throws {
        struct PollFailure: Error {}
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(1),
            poll: { throw PollFailure() },
            onRecycle: { _, _ in },
            logger: Logger(label: "test", minimumLevel: .debug, sink: sink)
        )
        let task = Task { await monitor.run() }
        var contents = ""
        var attempts = 0
        while !contents.contains("offline recycling is inactive"), attempts < 200 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(5))
            contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }
        task.cancel()
        await task.value
        #expect(contents.contains("offline recycling is inactive"))
        let alarms = contents.split(separator: "\n").filter { $0.contains("offline recycling is inactive") }
        #expect(alarms.count == 1, "the alarm must fire once, not once per poll")
    }

    @Test func cancellationMidPollIsNotReportedAsUnknownStatus() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .seconds(3600),
            poll: {
                try await Task.sleep(for: .seconds(3600))
                return .notRegistered
            },
            onRecycle: { _, _ in },
            logger: Logger(label: "test", minimumLevel: .debug, sink: sink)
        )
        let task = Task { await monitor.run() }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await task.value
        let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        #expect(!contents.contains("status unknown"), "teardown must not warn that the GitHub API is unhealthy")
    }

    @Test func cancellationStopsTheLoop() async {
        let recorder = RecycleRecorder()
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { .registered(GitHubService.RunnerStatus(connection: .offline, busy: false)) },
            onRecycle: { await recorder.record($0, $1) },
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
