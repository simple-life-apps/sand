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
        case offlineBusy
        case unrecognized
        case error
    }

    private let script: [Step]
    private let repeats: Bool
    private(set) var calls = 0

    init(_ script: [Step], repeats: Bool = true) {
        self.script = script
        self.repeats = repeats
    }

    func next() throws -> GitHubService.RunnerLookup {
        struct PollError: Error {}
        let step = repeats ? script[calls % script.count] : script[min(calls, script.count - 1)]
        calls += 1
        switch step {
        case .missing:
            return .notRegistered
        case .online:
            return .registered(GitHubService.RunnerStatus(connection: .online, busy: false))
        case .offlineBusy:
            return .registered(GitHubService.RunnerStatus(connection: .offline, busy: true))
        case .unrecognized:
            return .registered(GitHubService.RunnerStatus(connection: .unrecognized("weird"), busy: false))
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
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .offline, busy: nil))) == .unknown, "offline with unknown busy must freeze, not accumulate toward recycling")
        #expect(OfflineMonitor.signal(for: .registered(.init(connection: .online, busy: nil))) == .healthy)
    }

    @Test func freezeReasonMapping() {
        #expect(OfflineMonitor.freezeReason(for: .notRegistered) == nil)
        #expect(OfflineMonitor.freezeReason(for: .registered(.init(connection: .online, busy: true))) == nil)
        #expect(OfflineMonitor.freezeReason(for: .registered(.init(connection: .offline, busy: false))) == nil)
        #expect(OfflineMonitor.freezeReason(for: .registered(.init(connection: .offline, busy: true))) == "busy but offline")
        #expect(OfflineMonitor.freezeReason(for: .registered(.init(connection: .offline, busy: nil))) == "offline with unknown busy state")
        #expect(OfflineMonitor.freezeReason(for: .registered(.init(connection: .unrecognized("idle"), busy: false))) == "unrecognized status (idle)")
        #expect(OfflineMonitor.freezeReason(for: .registered(.init(connection: .unrecognized(nil), busy: nil))) == "unrecognized status (absent)")
    }

    @Test func everyFrozenSignalHasAFreezeReason() {
        let lookups: [GitHubService.RunnerLookup] = [
            .notRegistered,
            .registered(.init(connection: .online, busy: true)),
            .registered(.init(connection: .online, busy: nil)),
            .registered(.init(connection: .offline, busy: false)),
            .registered(.init(connection: .offline, busy: true)),
            .registered(.init(connection: .offline, busy: nil)),
            .registered(.init(connection: .unrecognized("idle"), busy: false)),
            .registered(.init(connection: .unrecognized(nil), busy: true))
        ]
        for lookup in lookups {
            #expect(
                (OfflineMonitor.freezeReason(for: lookup) != nil) == (OfflineMonitor.signal(for: lookup) == .unknown),
                "a frozen timer without a logged reason (or vice versa) for \(lookup)"
            )
        }
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
        let poll = ScriptedPoll([.missing])
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
        let calls = await poll.calls
        #expect(events.count == 1)
        #expect(events[0].cause == .missing)
        #expect(events[0].message.contains("no longer registered"))
        #expect(calls == 3, "the fast path must wait for exactly three confirming polls")
    }

    @Test func registeredPollResetsTheMissingStreak() async {
        let recorder = RecycleRecorder()
        // Any registered status resets the streak, including one that freezes
        // the timer; only a lookup that finds no runner may extend it.
        let poll = ScriptedPoll([.missing, .missing, .offlineBusy, .missing, .missing, .online])
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
            threshold: .milliseconds(200),
            pollInterval: .milliseconds(100),
            poll: { .notRegistered },
            onRecycle: { await recorder.record($0, $1) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        await monitor.run()
        let events = await recorder.events
        #expect(events.count == 1)
        #expect(events[0].cause == .missing)
    }

    @Test func busyOfflineFreezeIsWarnedOncePerEntry() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let poll = ScriptedPoll(
            [.offlineBusy, .offlineBusy, .online, .offlineBusy, .online],
            repeats: false
        )
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { try await poll.next() },
            onRecycle: { _, _ in },
            logger: Logger(label: "test", minimumLevel: .debug, sink: sink)
        )
        let task = Task { await monitor.run() }
        var calls = 0
        var attempts = 0
        while calls < 8, attempts < 200 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(5))
            calls = await poll.calls
        }
        task.cancel()
        await task.value
        let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let warnings = contents.split(separator: "\n").filter { $0.contains("busy but offline") }
        #expect(calls >= 8, "the test is vacuous unless both busy-offline entries were polled")
        #expect(warnings.count == 2, "the freeze warning must fire once per busy-offline entry, not per poll")
    }

    @Test func busyOfflineFreezeRewarnsPeriodicallyAndEventuallyAlarms() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let poll = ScriptedPoll([.offlineBusy])
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { try await poll.next() },
            onRecycle: { _, _ in },
            logger: Logger(label: "test", minimumLevel: .info, sink: sink)
        )
        let task = Task { await monitor.run() }
        var calls = 0
        var attempts = 0
        while calls < 35, attempts < 400 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(5))
            calls = await poll.calls
        }
        task.cancel()
        await task.value
        calls = await poll.calls
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n")
        let rewarns = lines.filter { $0.contains("offline timer still frozen") }
        let alarms = lines.filter { $0.contains("may be wedged") }
        #expect(calls >= 35, "the test is vacuous unless the freeze held past the alarm threshold")
        #expect(rewarns.count >= 2, "a held freeze must keep announcing itself")
        #expect(rewarns.count <= calls / 10 + 1, "the re-warn must be periodic, not per poll")
        #expect(alarms.count == 1, "a long-held freeze must escalate to a single error alarm")
    }

    @Test func unrecognizedStatusFreezeIsWarnedOncePerEntry() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let poll = ScriptedPoll(
            [.unrecognized, .unrecognized, .online, .unrecognized, .online],
            repeats: false
        )
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { try await poll.next() },
            onRecycle: { _, _ in },
            logger: Logger(label: "test", minimumLevel: .info, sink: sink)
        )
        let task = Task { await monitor.run() }
        var calls = 0
        var attempts = 0
        while calls < 8, attempts < 200 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(5))
            calls = await poll.calls
        }
        task.cancel()
        await task.value
        let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let warnings = contents.split(separator: "\n").filter { $0.contains("unrecognized status (weird)") }
        #expect(calls >= 8, "the test is vacuous unless both unrecognized entries were polled")
        #expect(warnings.count == 2, "an unrecognized status must be visible at the default log level, once per entry")
    }

    @Test func freezeReasonChangeIsAnnounced() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let poll = ScriptedPoll([.offlineBusy, .offlineBusy, .unrecognized, .unrecognized, .online], repeats: false)
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .seconds(3600),
            pollInterval: .milliseconds(2),
            poll: { try await poll.next() },
            onRecycle: { _, _ in },
            logger: Logger(label: "test", minimumLevel: .info, sink: sink)
        )
        let task = Task { await monitor.run() }
        var calls = 0
        var attempts = 0
        while calls < 8, attempts < 200 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(5))
            calls = await poll.calls
        }
        task.cancel()
        await task.value
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n")
        let entries = lines.filter { $0.contains("offline timer frozen until it recovers") }
        #expect(calls >= 8, "the test is vacuous unless both freeze reasons were polled")
        #expect(entries.count == 2, "a freeze whose cause changes must announce the new cause")
        #expect(entries.contains { $0.contains("busy but offline") })
        #expect(entries.contains { $0.contains("unrecognized status (weird)") })
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
