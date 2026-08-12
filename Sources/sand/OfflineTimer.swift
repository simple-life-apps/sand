struct OfflineTimer {
    enum Signal {
        case healthy
        case offline
        case unknown
    }

    enum Verdict: Equatable {
        case belowThreshold
        case thresholdReached
    }

    let threshold: Duration
    private var accumulated: Duration = .zero
    private var lastOffline: ContinuousClock.Instant?

    init(threshold: Duration) {
        self.threshold = threshold
    }

    var accumulatedOffline: Duration {
        accumulated
    }

    mutating func observe(_ signal: Signal, at now: ContinuousClock.Instant) -> Verdict {
        switch signal {
        case .healthy:
            accumulated = .zero
            lastOffline = nil
            return .belowThreshold
        case .unknown:
            lastOffline = nil
            return .belowThreshold
        case .offline:
            if let lastOffline, now > lastOffline {
                accumulated += lastOffline.duration(to: now)
            }
            lastOffline = now
            return accumulated >= threshold ? .thresholdReached : .belowThreshold
        }
    }
}
