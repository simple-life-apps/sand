struct OfflineMonitor: Sendable {
    static let defaultPollInterval: Duration = .seconds(60)
    static let missingPollThreshold = 3

    enum RecycleCause: Equatable, Sendable {
        case offlinePastThreshold
        case missing
    }

    let runnerName: String
    let threshold: Duration
    let pollInterval: Duration
    let poll: @Sendable () async throws -> GitHubService.RunnerLookup
    let onRecycle: @Sendable (RecycleCause, String) async -> Void
    let logger: Logger

    static func classify(_ lookup: GitHubService.RunnerLookup) -> (signal: OfflineTimer.Signal, freezeReason: String?) {
        switch lookup {
        case .notRegistered:
            return (.offline, nil)
        case let .registered(status):
            switch status.connection {
            case .online:
                return (.healthy, nil)
            case .offline:
                switch status.busy {
                case .some(false):
                    return (.offline, nil)
                case .some(true):
                    return (.unknown, "busy but offline")
                case .none:
                    return (.unknown, "offline with unknown busy state")
                }
            case let .unrecognized(raw):
                return (.unknown, "unrecognized status (\(raw ?? "absent"))")
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Int64 {
        duration.components.seconds
    }

    private static let pollFailureAlarmThreshold = 5
    private static let freezeRewarnPollInterval = 10
    private static let freezeAlarmPollThreshold = 30

    struct FreezeTracker {
        enum Event: Equatable {
            case entered(reason: String)
            case wedged(reason: String, frozenFor: Duration)
            case stillFrozen(reason: String, frozenFor: Duration)
        }

        private var polls = 0
        private var start: ContinuousClock.Instant?
        private var lastReason: String?
        private var alarmed = false

        mutating func observe(reason: String?, now: ContinuousClock.Instant) -> Event? {
            guard let reason else {
                self = FreezeTracker()
                return nil
            }
            let start = self.start ?? now
            self.start = start
            polls += 1
            if reason != lastReason {
                lastReason = reason
                return .entered(reason: reason)
            }
            if polls >= OfflineMonitor.freezeAlarmPollThreshold, !alarmed {
                alarmed = true
                return .wedged(reason: reason, frozenFor: start.duration(to: now))
            }
            if polls % OfflineMonitor.freezeRewarnPollInterval == 0 {
                return .stillFrozen(reason: reason, frozenFor: start.duration(to: now))
            }
            return nil
        }
    }

    private func log(_ event: FreezeTracker.Event) {
        switch event {
        case let .entered(reason):
            logger.warning("runner \(runnerName) reported \(reason) on GitHub; offline timer frozen until it recovers")
        case let .wedged(reason, frozenFor):
            logger.error("runner \(runnerName) offline timer frozen for \(Self.seconds(frozenFor))s (\(reason)); the runner may be wedged and will not be recycled while frozen")
        case let .stillFrozen(reason, frozenFor):
            logger.warning("runner \(runnerName) offline timer still frozen after \(Self.seconds(frozenFor))s (\(reason))")
        }
    }

    func run() async {
        let clock = ContinuousClock()
        var timer = OfflineTimer(threshold: threshold)
        var offlineRun = false
        var consecutivePollFailures = 0
        var alarmed = false
        var missingStreak = 0
        var freeze = FreezeTracker()
        while !Task.isCancelled {
            let signal: OfflineTimer.Signal
            do {
                let lookup = try await poll()
                let (classifiedSignal, freezeReason) = Self.classify(lookup)
                signal = classifiedSignal
                missingStreak = lookup == .notRegistered ? missingStreak + 1 : 0
                if let event = freeze.observe(reason: freezeReason, now: clock.now) {
                    log(event)
                }
                consecutivePollFailures = 0
                alarmed = false
            } catch {
                if Task.isCancelled {
                    break
                }
                signal = .unknown
                consecutivePollFailures += 1
                logger.warning("offline monitor: runner \(runnerName) status unknown, timer frozen: \(String(describing: error))")
                if consecutivePollFailures >= Self.pollFailureAlarmThreshold, !alarmed {
                    alarmed = true
                    logger.error("offline monitor: runner \(runnerName) status unpollable for \(consecutivePollFailures) consecutive polls; offline recycling is inactive: \(String(describing: error))")
                }
            }
            if Task.isCancelled {
                break
            }
            let accumulatedBeforeObservation = timer.accumulatedOffline
            let verdict = timer.observe(signal, at: clock.now)
            switch signal {
            case .offline where !offlineRun:
                offlineRun = true
                logger.warning("runner \(runnerName) reported offline on GitHub; recycling after \(Self.seconds(threshold))s accumulated offline")
            case .healthy where offlineRun:
                offlineRun = false
                logger.warning("runner \(runnerName) back online after \(Self.seconds(accumulatedBeforeObservation))s offline")
            default:
                break
            }
            logger.debug("offline monitor poll (runner=\(runnerName), signal=\(signal), offlineFor=\(Self.seconds(timer.accumulatedOffline))s/\(Self.seconds(threshold))s)")
            if missingStreak >= Self.missingPollThreshold {
                let message = "runner \(runnerName) no longer registered on GitHub"
                logger.warning("\(message); recycling VM")
                await onRecycle(.missing, message)
                return
            }
            if verdict == .thresholdReached {
                let message = "runner \(runnerName) offline on GitHub past threshold"
                logger.warning("\(message); recycling VM")
                await onRecycle(.offlinePastThreshold, message)
                return
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                break
            }
        }
        logger.debug("offline monitor stopped (runner=\(runnerName))")
    }
}
