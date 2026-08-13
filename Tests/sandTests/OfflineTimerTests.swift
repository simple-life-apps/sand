import Testing
@testable import sand

struct OfflineTimerTests {
    private let start = ContinuousClock().now

    @Test func firesAfterContinuousOfflineReachesThreshold() {
        var timer = OfflineTimer(threshold: .seconds(120))
        #expect(timer.observe(.offline, at: start) == .belowThreshold)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(60))) == .belowThreshold)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(120))) == .thresholdReached)
    }

    @Test func healthyResetsAccumulation() {
        var timer = OfflineTimer(threshold: .seconds(120))
        _ = timer.observe(.offline, at: start)
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(100)))
        _ = timer.observe(.healthy, at: start.advanced(by: .seconds(160)))
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(220))) == .belowThreshold)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(280))) == .belowThreshold)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(340))) == .thresholdReached)
    }

    @Test func unknownIntervalAddsZeroAccumulatedTime() {
        var timer = OfflineTimer(threshold: .seconds(120))
        _ = timer.observe(.offline, at: start)
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(60)))
        // Hours of unknown must not advance the timer...
        _ = timer.observe(.unknown, at: start.advanced(by: .seconds(3600)))
        // ...and the first offline after unknown must not count the gap either.
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(7200))) == .belowThreshold)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(7230))) == .belowThreshold)
        // 60s (before unknown) + 30s + 30s = 120s accumulated -> fires.
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(7260))) == .thresholdReached)
    }

    @Test func unknownDoesNotResetAccumulation() {
        var timer = OfflineTimer(threshold: .seconds(90))
        _ = timer.observe(.offline, at: start)
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(60)))
        _ = timer.observe(.unknown, at: start.advanced(by: .seconds(120)))
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(180)))
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(210))) == .thresholdReached)
    }

    @Test func subIntervalThresholdTakesEffectAtOnePollIntervalAsTheValidatorClaims() {
        var timer = OfflineTimer(threshold: .seconds(30))
        #expect(timer.observe(.offline, at: start) == .belowThreshold)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(60))) == .thresholdReached)
    }

    @Test func betweenIntervalsThresholdRoundsUpToTheNextPollAsTheValidatorClaims() {
        var timer = OfflineTimer(threshold: .seconds(90))
        #expect(timer.observe(.offline, at: start) == .belowThreshold)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(60))) == .belowThreshold)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(120))) == .thresholdReached)
    }

    @Test func zeroThresholdFiresOnFirstOffline() {
        var timer = OfflineTimer(threshold: .zero)
        #expect(timer.observe(.offline, at: start) == .thresholdReached)
    }

    @Test func healthyNeverFires() {
        var timer = OfflineTimer(threshold: .zero)
        #expect(timer.observe(.healthy, at: start) == .belowThreshold)
        #expect(timer.observe(.unknown, at: start.advanced(by: .seconds(60))) == .belowThreshold)
    }
}
