import Testing
import Foundation
@testable import AetherEngine

/// #93 residual: a waiting out-of-range segment fetch must RIDE an in-flight restart instead of
/// burning a fixed 3x8 s budget into a 503 (device: every pending fetch 503'd while a 44 s restart
/// was genuinely progressing, and AVPlayer gave up), and it must not re-fire a restart at its own
/// stale index against the coalescer's newer target (stale fetches overwrote the pending slot).
struct SegmentFetchWaitTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var fired: [Int] = []
        func record(_ idx: Int) { lock.lock(); fired.append(idx); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return fired }
    }

    private final class ActivityFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        init(_ v: Bool) { value = v }
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func segments(_ n: Int) -> [HLSVideoEngine.Segment] {
        (0..<n).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
    }

    private func makeProvider(cache: SegmentCache, recorder: Recorder, activity: ActivityFlag,
                              slice: TimeInterval = 0.05, rideCap: TimeInterval = 1.0,
                              initialRestartIndex: Int = 0) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: cache, segments: segments(60), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            restartHandler: { idx in recorder.record(idx) },
            restartActivity: { activity.get() },
            initialRestartIndex: initialRestartIndex,
            repositionWaitSlice: slice,
            repositionRideCapSeconds: rideCap
        )
    }

    @Test("a fetch rides an in-flight restart to a late segment instead of 503ing")
    func ridesInFlightRestart() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let recorder = Recorder()
        let activity = ActivityFlag(true)
        let provider = makeProvider(cache: cache, recorder: recorder, activity: activity)
        // The in-flight restart delivers the segment after ~6 wait slices, well past the old
        // fixed 3-attempt budget.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            cache.store(index: 40, data: Data(repeating: 0xAB, count: 8))
        }
        let served = provider.mediaSegment(at: 40)
        #expect(served != nil)
        #expect(recorder.all.isEmpty)
    }

    @Test("riding is bounded: nil at the ride cap when nothing arrives, still no stale re-fire")
    func rideCapBounds() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let recorder = Recorder()
        let activity = ActivityFlag(true)
        let provider = makeProvider(cache: cache, recorder: recorder, activity: activity,
                                    slice: 0.05, rideCap: 0.3)
        let start = DispatchTime.now()
        let served = provider.mediaSegment(at: 40)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        #expect(served == nil)
        #expect(recorder.all.isEmpty)
        #expect(elapsed >= 0.3)
        #expect(elapsed < 2.0)
    }

    @Test("resume-anchored provider cold-waits at the anchor instead of restarting the producer")
    func resumeAnchorColdStart() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let recorder = Recorder()
        let activity = ActivityFlag(false)
        // #93 residual: the first producer anchors at the resume segment; without the matching
        // initialRestartIndex the cold-start heuristic (abs(index - 0) > 2) restarted it immediately.
        let provider = makeProvider(cache: cache, recorder: recorder, activity: activity,
                                    initialRestartIndex: 40)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            cache.store(index: 40, data: Data(repeating: 0x11, count: 8))
        }
        let served = provider.mediaSegment(at: 40)
        #expect(served != nil)
        #expect(recorder.all.isEmpty)
    }

    @Test("without an in-flight restart the fixed-budget behavior is unchanged")
    func fixedBudgetWithoutActivity() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let recorder = Recorder()
        let activity = ActivityFlag(false)
        let provider = makeProvider(cache: cache, recorder: recorder, activity: activity)
        let served = provider.mediaSegment(at: 40)
        #expect(served == nil)
        #expect(recorder.all == [40])
    }

    @Test("restart settling mid-wait hands control back to the fixed budget")
    func settleThenFire() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let recorder = Recorder()
        let activity = ActivityFlag(true)
        let provider = makeProvider(cache: cache, recorder: recorder, activity: activity,
                                    slice: 0.05, rideCap: 5.0)
        // The foreign restart settles after 0.15 s without covering seg 40; the fetch then fires
        // its own restart (the #50 orphan recovery) whose producer stores the segment.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            activity.set(false)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            cache.store(index: 40, data: Data(repeating: 0xEF, count: 8))
        }
        let served = provider.mediaSegment(at: 40)
        #expect(served != nil)
        #expect(recorder.all == [40])
    }
}
