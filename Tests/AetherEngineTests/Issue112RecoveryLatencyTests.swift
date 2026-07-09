import Foundation
import Testing
@testable import AetherEngine

/// #112 round 11 (ijuniorfu, 0.9.20, remote ISO): recovery is correct but takes ~20 s. The device log
/// decomposes into three serial costs. (1) Two re-arms fire for one fast-forward (the debounced
/// producer-restart re-anchor and the #65 wedge-reconcile, same anchor); the second must drain the first,
/// which sits wedged in a bounded positioning seek that cannot observe its cancel, so the successor pays
/// the full 5 s drain budget and then sacrifices the healthy side demuxer via markClosed. (2) The fresh
/// demuxer loses the timestampSeekUnreliable latch, so the successor pays the full 8 s timestamp-seek
/// budget again before the byte estimate runs. (3) The cold re-open itself. Round 11: duplicate re-arms
/// coalesce, a successor aborts the predecessor's in-flight positioning read so the warm demuxer survives
/// the handoff, the unreliable latch lives engine-side per source, and the timestamp-seek attempt is
/// capped tight when the byte-estimate fallback is viable.
struct Issue112RecoveryLatencyTests {

    // MARK: - Reversible read abort (provider level)

    @Test("a requested read abort makes the bridge read return the forced-abort code and latch the flag")
    func bridgeAbortStopsRead() {
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: Data([1, 2, 3, 4])))
        bridge.requestReadAbort()
        var buf = [UInt8](repeating: 0, count: 4)
        let n = buf.withUnsafeMutableBufferPointer { bridge.performRead(into: $0.baseAddress!, size: 4) }
        #expect(n == -1)
        #expect(bridge.readDeadlineFired == true)
    }

    @Test("the abort works without any armed deadline (successor aborts a predecessor between windows)")
    func bridgeAbortIndependentOfDeadline() {
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: Data([1, 2, 3, 4])))
        // No beginReadDeadline anywhere: the abort must not depend on an armed window.
        bridge.requestReadAbort()
        var buf = [UInt8](repeating: 0, count: 4)
        let n = buf.withUnsafeMutableBufferPointer { bridge.performRead(into: $0.baseAddress!, size: 4) }
        #expect(n == -1)
    }

    @Test("clearing the abort restores reads, so the successor reuses the same warm demuxer")
    func bridgeAbortIsReversible() {
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: Data([1, 2, 3, 4])))
        bridge.requestReadAbort()
        bridge.clearReadAbort()
        bridge.beginReadDeadline(secondsFromNow: 60)
        defer { bridge.endReadDeadline() }
        var buf = [UInt8](repeating: 0, count: 4)
        let n = buf.withUnsafeMutableBufferPointer { bridge.performRead(into: $0.baseAddress!, size: 4) }
        #expect(n == 4)
        #expect(bridge.readDeadlineFired == false)
    }

    @Test("arming a fresh deadline does not clear a pending abort (abort wins the begin/observe race)")
    func bridgeAbortSurvivesRearm() {
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: Data([1, 2, 3, 4])))
        bridge.requestReadAbort()
        // Predecessor finished seek A (deadline disarmed) and arms seek B before observing the abort.
        bridge.beginReadDeadline(secondsFromNow: 60)
        var buf = [UInt8](repeating: 0, count: 4)
        let n = buf.withUnsafeMutableBufferPointer { bridge.performRead(into: $0.baseAddress!, size: 4) }
        #expect(n == -1)
    }

    // MARK: - Duplicate re-arm coalescing

    @Test("a re-arm for the same stream and anchor while one is in flight coalesces")
    func coalesceSameAnchor() {
        #expect(AetherEngine.shouldCoalesceSubtitleRearm(
            newStreamIndex: 22, newStartAt: 1561.24,
            activeStreamIndex: 22, activeStartAt: 1561.24, activeAgeSeconds: 0.05))
    }

    @Test("anchor drift within the tolerance still coalesces (both derive from the same recovery target)")
    func coalesceWithinTolerance() {
        #expect(AetherEngine.shouldCoalesceSubtitleRearm(
            newStreamIndex: 22, newStartAt: 1561.6,
            activeStreamIndex: 22, activeStartAt: 1561.24, activeAgeSeconds: 1.0))
    }

    @Test("a different subtitle stream never coalesces (track switch must always re-arm)")
    func noCoalesceDifferentStream() {
        #expect(!AetherEngine.shouldCoalesceSubtitleRearm(
            newStreamIndex: 21, newStartAt: 1561.24,
            activeStreamIndex: 22, activeStartAt: 1561.24, activeAgeSeconds: 0.05))
    }

    @Test("a genuinely new anchor never coalesces (user seeked again somewhere else)")
    func noCoalesceNewAnchor() {
        #expect(!AetherEngine.shouldCoalesceSubtitleRearm(
            newStreamIndex: 22, newStartAt: 1620.0,
            activeStreamIndex: 22, activeStartAt: 1561.24, activeAgeSeconds: 2.0))
    }

    @Test("a stale in-flight re-arm does not swallow new ones (hung-task backstop)")
    func noCoalesceStaleActive() {
        #expect(!AetherEngine.shouldCoalesceSubtitleRearm(
            newStreamIndex: 22, newStartAt: 1561.24,
            activeStreamIndex: 22, activeStartAt: 1561.24, activeAgeSeconds: 31.0))
    }

    @Test("no in-flight re-arm means no coalescing")
    func noCoalesceIdle() {
        #expect(!AetherEngine.shouldCoalesceSubtitleRearm(
            newStreamIndex: 22, newStartAt: 1561.24,
            activeStreamIndex: nil, activeStartAt: nil, activeAgeSeconds: nil))
    }

    // MARK: - Adaptive positioning budget

    @Test("with a viable byte estimate the timestamp-seek attempt is capped tight")
    func tightBudgetWhenEstimateViable() {
        let budget = AetherEngine.positioningSeekBudget(estimateViable: true)
        #expect(budget <= 2.0)
        #expect(budget > 0)
    }

    @Test("without a viable estimate the timestamp seek keeps the full budget (it is the only mechanism)")
    func fullBudgetWhenEstimateNotViable() {
        #expect(AetherEngine.positioningSeekBudget(estimateViable: false)
                == AetherEngine.sideReaderSeekBudgetSeconds)
    }
}
