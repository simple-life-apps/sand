struct OfflineMonitor: Sendable {
    let runnerName: String
    let threshold: Duration
    let pollInterval: Duration
    let poll: @Sendable () async throws -> GitHubService.RunnerStatus?
    let onRecycle: @Sendable (String) async -> Void
    let logger: Logger

    static func signal(for status: GitHubService.RunnerStatus?) -> OfflineTimer.Signal {
        guard let status else {
            return .offline
        }
        return (status.busy || status.online) ? .healthy : .offline
    }

    private static func seconds(_ duration: Duration) -> Int64 {
        duration.components.seconds
    }

    func run() async {
        let clock = ContinuousClock()
        var timer = OfflineTimer(threshold: threshold)
        var offlineRun = false
        while !Task.isCancelled {
            let signal: OfflineTimer.Signal
            do {
                signal = Self.signal(for: try await poll())
            } catch {
                signal = .unknown
                logger.warning("offline monitor: runner \(runnerName) status unknown, timer frozen: \(String(describing: error))")
            }
            if Task.isCancelled {
                break
            }
            let accumulatedBeforeObservation = timer.accumulatedOffline
            let fired = timer.observe(signal, at: clock.now)
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
            if fired {
                let message = "runner \(runnerName) offline on GitHub past threshold"
                logger.warning("\(message); recycling VM")
                await onRecycle(message)
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
