import Foundation
import Testing
@testable import sand

private actor RecycleRecorder {
    private(set) var events: [(cause: OfflineMonitor.RecycleCause, message: String)] = []
    var messages: [String] { events.map(\.message) }
    var causes: [OfflineMonitor.RecycleCause] { events.map(\.cause) }
    func record(_ cause: OfflineMonitor.RecycleCause, _ message: String) {
        events.append((cause, message))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct OfflineMonitorTests {
    @Test func signalClassification() {
        #expect(OfflineMonitor.classify(.notRegistered).signal == .offline)
        #expect(OfflineMonitor.classify(.registered(.init(connection: .offline, busy: false))).signal == .offline)
        #expect(OfflineMonitor.classify(.registered(.init(connection: .online, busy: false))).signal == .healthy)
        #expect(OfflineMonitor.classify(.registered(.init(connection: .online, busy: true))).signal == .healthy)
        // A busy claim without an online connection freezes the timer rather
        // than vouching for health: GitHub keeps busy=true for a runner that
        // died mid-job until the job is reaped.
        #expect(OfflineMonitor.classify(.registered(.init(connection: .offline, busy: true))).signal == .unknown)
        #expect(OfflineMonitor.classify(.registered(.init(connection: .unrecognized("idle"), busy: false))).signal == .unknown)
        #expect(OfflineMonitor.classify(.registered(.init(connection: .unrecognized(nil), busy: false))).signal == .unknown)
        #expect(OfflineMonitor.classify(.registered(.init(connection: .unrecognized(nil), busy: true))).signal == .unknown)
        #expect(OfflineMonitor.classify(.registered(.init(connection: .offline, busy: nil))).signal == .unknown, "offline with unknown busy must freeze, not accumulate toward recycling")
        #expect(OfflineMonitor.classify(.registered(.init(connection: .online, busy: nil))).signal == .healthy)
    }

    @Test func freezeReasonClassification() {
        #expect(OfflineMonitor.classify(.notRegistered).freezeReason == nil)
        #expect(OfflineMonitor.classify(.registered(.init(connection: .online, busy: true))).freezeReason == nil)
        #expect(OfflineMonitor.classify(.registered(.init(connection: .offline, busy: false))).freezeReason == nil)
        #expect(OfflineMonitor.classify(.registered(.init(connection: .offline, busy: true))).freezeReason == "busy but offline")
        #expect(OfflineMonitor.classify(.registered(.init(connection: .offline, busy: nil))).freezeReason == "offline with unknown busy state")
        #expect(OfflineMonitor.classify(.registered(.init(connection: .unrecognized("idle"), busy: false))).freezeReason == "unrecognized status (idle)")
        #expect(OfflineMonitor.classify(.registered(.init(connection: .unrecognized(nil), busy: nil))).freezeReason == "unrecognized status (absent)")
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
            let classification = OfflineMonitor.classify(lookup)
            #expect(
                (classification.freezeReason != nil) == (classification.signal == .unknown),
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
        let calls = await poll.waitForCalls(atLeast: 12, attempts: 200)
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
        let poll = ScriptedPoll([.offlineBusy, .offlineBusy, .online, .offlineBusy, .online], repeats: false)
        let (calls, lines) = try await runMonitor(poll, untilCalls: 8, level: .debug)
        let warnings = lines.filter { $0.contains("busy but offline") }
        #expect(calls >= 8, "the test is vacuous unless both busy-offline entries were polled")
        #expect(warnings.count == 2, "the freeze warning must fire once per busy-offline entry, not per poll")
    }

    @Test func busyOfflineFreezeRewarnsPeriodicallyAndEventuallyAlarms() async throws {
        let poll = ScriptedPoll([.offlineBusy])
        let (calls, lines) = try await runMonitor(poll, untilCalls: 35, level: .info)
        let rewarns = lines.filter { $0.contains("offline timer still frozen") }
        let alarms = lines.filter { $0.contains("may be wedged") }
        #expect(calls >= 35, "the test is vacuous unless the freeze held past the alarm threshold")
        #expect(rewarns.count >= 2, "a held freeze must keep announcing itself")
        #expect(rewarns.count <= calls / 10 + 1, "the re-warn must be periodic, not per poll")
        #expect(alarms.count == 1, "a long-held freeze must escalate to a single error alarm")
    }

    @Test func unrecognizedStatusFreezeIsWarnedOncePerEntry() async throws {
        let poll = ScriptedPoll([.unrecognized, .unrecognized, .online, .unrecognized, .online], repeats: false)
        let (calls, lines) = try await runMonitor(poll, untilCalls: 8, level: .info)
        let warnings = lines.filter { $0.contains("unrecognized status (weird)") }
        #expect(calls >= 8, "the test is vacuous unless both unrecognized entries were polled")
        #expect(warnings.count == 2, "an unrecognized status must be visible at the default log level, once per entry")
    }

    @Test func freezeReasonChangeIsAnnounced() async throws {
        let poll = ScriptedPoll([.offlineBusy, .offlineBusy, .unrecognized, .unrecognized, .online], repeats: false)
        let (calls, lines) = try await runMonitor(poll, untilCalls: 8, level: .info)
        let entries = lines.filter { $0.contains("offline timer frozen until it recovers") }
        #expect(calls >= 8, "the test is vacuous unless both freeze reasons were polled")
        #expect(entries.count == 2, "a freeze whose cause changes must announce the new cause")
        #expect(entries.contains { $0.contains("busy but offline") })
        #expect(entries.contains { $0.contains("unrecognized status (weird)") })
    }

    @Test func busyRunnerNeverRecyclesAndErrorsFreeze() async {
        let recorder = RecycleRecorder()
        // Alternate runs of errors and busy polls: neither may ever fire. Each
        // error run spans more than the threshold, so an error counted as
        // offline instead of unknown would recycle.
        let poll = ScriptedPoll(Array(repeating: .error, count: 10) + [.onlineBusy, .onlineBusy])
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: .milliseconds(10),
            pollInterval: .milliseconds(2),
            poll: { try await poll.next() },
            onRecycle: { await recorder.record($0, $1) },
            logger: Logger(label: "test", minimumLevel: .error, sink: nil)
        )
        let task = Task { await monitor.run() }
        let polls = await poll.waitForCalls(atLeast: 24, attempts: 200)
        task.cancel()
        await task.value
        let messages = await recorder.messages
        #expect(polls >= 24, "the test is vacuous unless at least two full error/busy cycles ran")
        #expect(messages.isEmpty)
    }

    @Test func offlineAndRecoveryTransitionsAreLogged() async throws {
        let poll = ScriptedPoll([.offline, .offline, .online], repeats: false)
        let (calls, lines) = try await runMonitor(poll, untilCalls: 8, level: .debug)
        let contents = lines.joined(separator: "\n")
        #expect(calls >= 8, "the test is vacuous unless the recovery was polled")
        #expect(contents.contains("runner r-1 reported offline on GitHub"))
        #expect(contents.contains("runner r-1 back online after"))
        #expect(contents.contains("offline monitor poll (runner=r-1"))
        let transitions = lines.filter { $0.contains("reported offline on GitHub") }
        #expect(transitions.count == 1, "the offline transition must be logged once per run, not once per poll")
    }

    @Test func sustainedPollFailuresEscalateToASingleErrorAlarm() async throws {
        let poll = ScriptedPoll([.error])
        let (calls, lines) = try await runMonitor(poll, untilCalls: 7, level: .debug)
        let alarms = lines.filter { $0.contains("offline recycling is inactive") }
        #expect(calls >= 7, "the test is vacuous unless the failure streak passed the alarm threshold")
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

    /// Runs a monitor over the scripted poll until it has been polled
    /// `untilCalls` times, then cancels it and returns the log lines.
    private func runMonitor(
        _ poll: ScriptedPoll,
        untilCalls: Int,
        level: LogLevel,
        threshold: Duration = .seconds(3600)
    ) async throws -> (calls: Int, lines: [String]) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let monitor = OfflineMonitor(
            runnerName: "r-1",
            threshold: threshold,
            pollInterval: .milliseconds(2),
            poll: { try await poll.next() },
            onRecycle: { _, _ in },
            logger: Logger(label: "test", minimumLevel: level, sink: sink)
        )
        let task = Task { await monitor.run() }
        await poll.waitForCalls(atLeast: untilCalls)
        task.cancel()
        await task.value
        let calls = await poll.calls
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
        return (calls, lines)
    }
}
