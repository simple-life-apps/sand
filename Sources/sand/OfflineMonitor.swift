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

    func run() async {
        let clock = ContinuousClock()
        var timer = OfflineTimer(threshold: threshold)
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
            if timer.observe(signal, at: clock.now) {
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
