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

    static func signal(for lookup: GitHubService.RunnerLookup) -> OfflineTimer.Signal {
        switch lookup {
        case .notRegistered:
            return .offline
        case let .registered(status):
            switch status.connection {
            case .online:
                return .healthy
            case .offline:
                return status.busy == false ? .offline : .unknown
            case .unrecognized:
                return .unknown
            }
        }
    }

    static func freezeReason(for lookup: GitHubService.RunnerLookup) -> String? {
        guard case let .registered(status) = lookup else {
            return nil
        }
        switch status.connection {
        case .online:
            return nil
        case .offline:
            switch status.busy {
            case .some(false):
                return nil
            case .some(true):
                return "busy but offline"
            case .none:
                return "offline with unknown busy state"
            }
        case let .unrecognized(raw):
            return "unrecognized status (\(raw ?? "absent"))"
        }
    }

    private static func seconds(_ duration: Duration) -> Int64 {
        duration.components.seconds
    }

    private static let pollFailureAlarmThreshold = 5
    private static let freezeRewarnPollInterval = 10
    private static let freezeAlarmPollThreshold = 30

    func run() async {
        let clock = ContinuousClock()
        var timer = OfflineTimer(threshold: threshold)
        var offlineRun = false
        var consecutivePollFailures = 0
        var alarmed = false
        var missingStreak = 0
        var freezePolls = 0
        var freezeStart: ContinuousClock.Instant?
        var lastFreezeReason: String?
        var freezeAlarmed = false
        while !Task.isCancelled {
            let signal: OfflineTimer.Signal
            do {
                let lookup = try await poll()
                signal = Self.signal(for: lookup)
                missingStreak = lookup == .notRegistered ? missingStreak + 1 : 0
                if let freezeReason = Self.freezeReason(for: lookup) {
                    let start = freezeStart ?? clock.now
                    freezeStart = start
                    freezePolls += 1
                    if freezeReason != lastFreezeReason {
                        lastFreezeReason = freezeReason
                        logger.warning("runner \(runnerName) reported \(freezeReason) on GitHub; offline timer frozen until it recovers")
                    } else if freezePolls >= Self.freezeAlarmPollThreshold, !freezeAlarmed {
                        freezeAlarmed = true
                        logger.error("runner \(runnerName) offline timer frozen for \(Self.seconds(start.duration(to: clock.now)))s (\(freezeReason)); the runner may be wedged and will not be recycled while frozen")
                    } else if freezePolls % Self.freezeRewarnPollInterval == 0 {
                        logger.warning("runner \(runnerName) offline timer still frozen after \(Self.seconds(start.duration(to: clock.now)))s (\(freezeReason))")
                    }
                } else {
                    freezePolls = 0
                    freezeStart = nil
                    lastFreezeReason = nil
                    freezeAlarmed = false
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
