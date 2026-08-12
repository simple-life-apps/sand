struct OfflineTimer {
    enum Signal {
        case healthy
        case offline
        case unknown
    }

    let threshold: Duration
    private var accumulated: Duration = .zero
    private var lastOffline: ContinuousClock.Instant?

    init(threshold: Duration) {
        self.threshold = threshold
    }

    mutating func observe(_ signal: Signal, at now: ContinuousClock.Instant) -> Bool {
        switch signal {
        case .healthy:
            accumulated = .zero
            lastOffline = nil
            return false
        case .unknown:
            lastOffline = nil
            return false
        case .offline:
            if let lastOffline, now > lastOffline {
                accumulated += lastOffline.duration(to: now)
            }
            lastOffline = now
            return accumulated >= threshold
        }
    }
}
