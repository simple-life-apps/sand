import Testing
@testable import sand

struct OfflineTimerTests {
    private let start = ContinuousClock().now

    @Test func firesAfterContinuousOfflineReachesThreshold() {
        var timer = OfflineTimer(threshold: .seconds(120))
        #expect(timer.observe(.offline, at: start) == false)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(60))) == false)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(120))) == true)
    }

    @Test func healthyResetsAccumulation() {
        var timer = OfflineTimer(threshold: .seconds(120))
        _ = timer.observe(.offline, at: start)
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(100)))
        _ = timer.observe(.healthy, at: start.advanced(by: .seconds(160)))
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(220))) == false)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(280))) == false)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(340))) == true)
    }

    @Test func unknownIntervalAddsZeroAccumulatedTime() {
        var timer = OfflineTimer(threshold: .seconds(120))
        _ = timer.observe(.offline, at: start)
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(60)))
        // Hours of unknown must not advance the timer...
        _ = timer.observe(.unknown, at: start.advanced(by: .seconds(3600)))
        // ...and the first offline after unknown must not count the gap either.
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(7200))) == false)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(7230))) == false)
        // 60s (before unknown) + 30s + 30s = 120s accumulated -> fires.
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(7260))) == true)
    }

    @Test func unknownDoesNotResetAccumulation() {
        var timer = OfflineTimer(threshold: .seconds(90))
        _ = timer.observe(.offline, at: start)
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(60)))
        _ = timer.observe(.unknown, at: start.advanced(by: .seconds(120)))
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(180)))
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(210))) == true)
    }

    @Test func zeroThresholdFiresOnFirstOffline() {
        var timer = OfflineTimer(threshold: .zero)
        #expect(timer.observe(.offline, at: start) == true)
    }

    @Test func healthyNeverFires() {
        var timer = OfflineTimer(threshold: .zero)
        #expect(timer.observe(.healthy, at: start) == false)
        #expect(timer.observe(.unknown, at: start.advanced(by: .seconds(60))) == false)
    }
}
