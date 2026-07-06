import Foundation
import Testing
@testable import AetherEngine

/// #96 (rrgomes): after a wedged backward seek the AVPlayer clock stays frozen AHEAD of the real
/// target (the seek never landed, #37 semantics). The overlay subtitle reader re-sampled that frozen
/// clock and took `max(startAt, frozenClock)`, anchoring itself ahead of the producer's true landing
/// and opening a `(frozenClock - target)`-length cue hole (device: ~25 s, ~44 s, and one ~178 s
/// blackout, all verified on screen). While a recovery seek is pending the clock is a phantom and must
/// not win the #52 forward catch-up; the reader honours the passed target instead.
struct Issue96SubtitleAnchorTests {

    @Test("a wedge-frozen clock ahead of the backward target does not push the anchor forward")
    func wedgeFrozenClockDoesNotAdvanceAnchor() {
        // rrgomes' worst exhibit: reader armed for target 633.84, frozen clock still 824.0.
        #expect(AetherEngine.effectiveSubtitleStart(
            startAt: 633.84, playhead: 824.0, recoveryPending: true) == 633.84)
        // A backward target with the frozen clock behind it is honoured too (no spurious max).
        #expect(AetherEngine.effectiveSubtitleStart(
            startAt: 633.84, playhead: 600.0, recoveryPending: true) == 633.84)
    }

    @Test("the #52 forward catch-up still applies when no recovery seek is pending")
    func liveClockStillCatchesUp() {
        // Unpaused playback advanced a few seconds during the slow open: anchor forward to the playhead.
        #expect(AetherEngine.effectiveSubtitleStart(
            startAt: 560.5, playhead: 563.0, recoveryPending: false) == 563.0)
        // Playhead behind the anchor: keep the anchor.
        #expect(AetherEngine.effectiveSubtitleStart(
            startAt: 560.5, playhead: 559.0, recoveryPending: false) == 560.5)
        // No playhead sample (engine gone): fall back to the anchor.
        #expect(AetherEngine.effectiveSubtitleStart(
            startAt: 560.5, playhead: nil, recoveryPending: false) == 560.5)
    }
}
