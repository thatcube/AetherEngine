import Foundation
import Testing
@testable import AetherEngine

/// #93 retest (rrgomes): a user seek that wedges never lands, so the frozen AVPlayer clock still
/// reports the PRE-seek position (#37 semantics); the stall recovery then nudged/reloaded at that
/// frozen position (391.9 s) instead of the requested target (341.9 s), so the seek was silently
/// lost. The engine now keeps the unlanded seek target as recovery intent: the nudge and the
/// stage-2 reload aim at it. The intent clears when the seek demonstrably lands (rendered near
/// the target) or goes stale (organic playback progress far from the target, meaning AVPlayer
/// abandoned the seek and the user is watching elsewhere).
struct RecoverySeekTargetTests {

    @Test("recovery aims at the pending seek target when one exists")
    func anchorDecision() {
        // rrgomes shape: frozen pre-seek clock 391.9, requested target 341.9.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: 341.9) == 341.9)
        // No pending seek: recover in place.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: nil) == 391.9)
    }

    @Test("a pending target counts as landed once rendered output reaches its neighbourhood")
    func landedDecision() {
        #expect(AetherEngine.pendingSeekLanded(rendered: 341.9, target: 341.9))
        #expect(AetherEngine.pendingSeekLanded(rendered: 344.0, target: 341.9))
        // Frozen at the pre-seek position: not landed.
        #expect(!AetherEngine.pendingSeekLanded(rendered: 391.9, target: 341.9))
    }

    @Test("organic playback progress far from the target marks the intent stale")
    func staleDecision() {
        // A frozen clock accumulates no progress: intent survives the whole wedge.
        #expect(!AetherEngine.isPendingSeekStale(progressWhilePending: 0.0))
        #expect(!AetherEngine.isPendingSeekStale(progressWhilePending: 2.0))
        // AVPlayer abandoned the seek and playback runs elsewhere: drop the intent so a later,
        // unrelated stall cannot teleport to a minutes-old target.
        #expect(AetherEngine.isPendingSeekStale(progressWhilePending: 3.5))
    }
}
