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
        // rrgomes shape: frozen pre-seek clock 391.9, requested target 341.9. The user's
        // backward seek intent wins even over a rendered clock that ran further ahead.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: 341.9, currentRendered: 400.0) == 341.9)
        // No pending seek, clock frozen: recover in place.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: nil, currentRendered: 391.9) == 391.9)
    }

    @Test("the nudge target is never below the current rendered position (#115)")
    func nudgeNeverRewinds() {
        // #115 shape (dlev02): wedge trips at 391.9, VOD keeps draining buffered segments
        // through the re-engage grace window, on-screen frame is at 400.0 when the nudge
        // fires. Seeking to the pre-grace capture replayed ~8s; the anchor must track the
        // rendered frame instead.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: nil, currentRendered: 400.0) == 400.0)
        // A lagging/zero rendered read must not drag the anchor backward either.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: nil, currentRendered: 0.0) == 391.9)
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

    @Test("deadline recovery restarts a starved producer OR an unbuffered forward-seek target")
    func deadlineRestartDecision() {
        // Starved wedge (#65): always re-anchor regardless of target buffering.
        #expect(AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: true, targetWithinContiguousBuffer: true))
        #expect(AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: true, targetWithinContiguousBuffer: false))
        // DV/SMB forward-seek revert: NOT starved by the old-playhead buffer metric, but the target
        // is unbuffered -> must re-anchor (previously suppressed, which parked the session).
        #expect(AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: false, targetWithinContiguousBuffer: false))
        // Raced-the-budget seek whose target is already contiguously buffered: lands organically,
        // no needless producer restart.
        #expect(!AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: false, targetWithinContiguousBuffer: true))
        #expect(AetherEngine.shouldReanchorSubtitlesOnLateSeekLanding(
            alreadyReanchored: false
        ))
        #expect(!AetherEngine.shouldReanchorSubtitlesOnLateSeekLanding(
            alreadyReanchored: true
        ))
    }

    @Test("a forward seek target beyond the contiguous buffer is treated as unbuffered")
    func seekTargetBufferCoverage() {
        // DV/SMB shape: rendered/old playhead ~2648, thin forward buffer to ~2653, target 4829.9.
        // The target is far beyond bufferedEnd -> unbuffered.
        #expect(!AetherEngine.seekTargetWithinContiguousBuffer(
            target: 4829.90, bufferedEnd: 2653.41))
        // A backward/short seek whose target sits inside the contiguous buffer -> covered.
        #expect(AetherEngine.seekTargetWithinContiguousBuffer(
            target: 2647.91, bufferedEnd: 2663.0))
        // Boundary: bufferedEnd within tolerance of the target counts as covered.
        #expect(AetherEngine.seekTargetWithinContiguousBuffer(
            target: 100.0, bufferedEnd: 99.7))
        #expect(!AetherEngine.seekTargetWithinContiguousBuffer(
            target: 100.0, bufferedEnd: 99.0))
        // No pending target: fall back to the starved signal alone (treated as covered).
        #expect(AetherEngine.seekTargetWithinContiguousBuffer(
            target: nil, bufferedEnd: 0.0))
    }

    @Test("a disjoint forward buffer island is total forward ahead minus the contiguous portion")
    func disjointForwardIsland() {
        // DV/SMB failing forward seek at deadline: AVPlayer buffered ~4s of the TARGET region into a
        // non-contiguous island while bufferedEnd (contiguous with the pinned old playhead) reads 0.
        #expect(AetherEngine.disjointForwardIslandSeconds(
            totalForwardAhead: 4.0, contiguousForwardAhead: 0.0) == 4.0)
        // Later window: 6.4s of target buffered, still nothing contiguous with the frozen playhead.
        #expect(AetherEngine.disjointForwardIslandSeconds(
            totalForwardAhead: 6.4, contiguousForwardAhead: 0.0) == 6.4)
        // A healthy seek that landed contiguously: all forward buffer is contiguous, no island.
        #expect(AetherEngine.disjointForwardIslandSeconds(
            totalForwardAhead: 14.4, contiguousForwardAhead: 14.4) == 0.0)
        // A true wedge: nothing anywhere -> no island.
        #expect(AetherEngine.disjointForwardIslandSeconds(
            totalForwardAhead: 0.0, contiguousForwardAhead: 0.0) == 0.0)
        // Mixed: 10s total, 3s contiguous -> 7s island.
        #expect(AetherEngine.disjointForwardIslandSeconds(
            totalForwardAhead: 10.0, contiguousForwardAhead: 3.0) == 7.0)
        // A negative contiguous reading (bufferedEnd behind rendered) clamps to 0, not inflating the island.
        #expect(AetherEngine.disjointForwardIslandSeconds(
            totalForwardAhead: 5.0, contiguousForwardAhead: -2.0) == 5.0)
        // Total smaller than contiguous (transient) never yields a negative island.
        #expect(AetherEngine.disjointForwardIslandSeconds(
            totalForwardAhead: 2.0, contiguousForwardAhead: 5.0) == 0.0)
    }

    @Test("a filling forward island extends the deadline; a wedge or exhausted budget does not")
    func extendSeekDeadlineDecision() {
        let floor = 1.0
        let maxExt = 4
        // DV/SMB slow forward seek: 4s island present, budget fresh -> extend instead of recovering.
        #expect(AetherEngine.shouldExtendSeekDeadlineForProgress(
            disjointIslandSeconds: 4.0, extensionsUsed: 0, maxExtensions: maxExt, islandFloor: floor))
        // Still filling on a later extension, budget not exhausted -> keep extending.
        #expect(AetherEngine.shouldExtendSeekDeadlineForProgress(
            disjointIslandSeconds: 6.4, extensionsUsed: 3, maxExtensions: maxExt, islandFloor: floor))
        // True wedge: no island -> do NOT extend, fall through to recovery.
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            disjointIslandSeconds: 0.0, extensionsUsed: 0, maxExtensions: maxExt, islandFloor: floor))
        // Sub-floor sliver is not convincing progress -> recover, don't extend forever.
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            disjointIslandSeconds: 0.5, extensionsUsed: 0, maxExtensions: maxExt, islandFloor: floor))
        // Budget exhausted even with a healthy island -> stop extending, bound the total wait.
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            disjointIslandSeconds: 6.4, extensionsUsed: 4, maxExtensions: maxExt, islandFloor: floor))
        // Exactly at the floor counts as progress.
        #expect(AetherEngine.shouldExtendSeekDeadlineForProgress(
            disjointIslandSeconds: 1.0, extensionsUsed: 0, maxExtensions: maxExt, islandFloor: floor))
    }

    @Test("the device-trace forward seek extends while the target island fills, then lands not wedges")
    @MainActor
    func deviceTraceForwardSeekPrefersExtension() {
        // Reconstruct the failing repro at deadline (build 2017 trace): rendered==buffered==old playhead,
        // so the contiguous-only metric reads starved, but avPlayerBufferAheadSeconds() saw the target
        // island growing 0.55 -> 4.0 -> 6.4s. The engine must EXTEND, not run the harmful recovery.
        let islandAtDeadline = AetherEngine.disjointForwardIslandSeconds(
            totalForwardAhead: 4.0, contiguousForwardAhead: 896.35 - 896.35)
        #expect(islandAtDeadline == 4.0)
        #expect(AetherEngine.shouldExtendSeekDeadlineForProgress(
            disjointIslandSeconds: islandAtDeadline, extensionsUsed: 0,
            maxExtensions: AetherEngine.nativeSeekMaxDeadlineExtensions,
            islandFloor: AetherEngine.nativeSeekProgressIslandFloorSeconds))

        // Contrast: a genuinely wedged seek (producer never served the target) has no island and must
        // NOT be kept alive by endless extensions — it falls through to recovery + re-anchor.
        let wedgeIsland = AetherEngine.disjointForwardIslandSeconds(
            totalForwardAhead: 0.0, contiguousForwardAhead: 0.0)
        #expect(wedgeIsland == 0.0)
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            disjointIslandSeconds: wedgeIsland, extensionsUsed: 0,
            maxExtensions: AetherEngine.nativeSeekMaxDeadlineExtensions,
            islandFloor: AetherEngine.nativeSeekProgressIslandFloorSeconds))
    }

    @Test("a published completion is the authoritative deadline catch-up signal")
    func completionPublicationDecision() {
        #expect(AetherEngine.shouldCatchUpDeadlineLanding(renderedTimePublished: true))
        #expect(!AetherEngine.shouldCatchUpDeadlineLanding(renderedTimePublished: false))
    }

    @Test("a short seek needs rendered movement or completion evidence")
    func shortSeekLandingEvidence() {
        #expect(!AetherEngine.pendingSeekHasRenderedLandingEvidence(
            rendered: 40,
            target: 43,
            initialRendered: 40,
            completionRenderedTimePublished: false
        ))
        #expect(AetherEngine.pendingSeekHasRenderedLandingEvidence(
            rendered: 43,
            target: 43,
            initialRendered: 40,
            completionRenderedTimePublished: false
        ))
        #expect(AetherEngine.pendingSeekHasRenderedLandingEvidence(
            rendered: 40,
            target: 43,
            initialRendered: 40,
            completionRenderedTimePublished: true
        ))
    }

    @MainActor
    @Test("starting or clearing a recovery target resets deadline lifecycle state")
    func targetLifecycleReset() throws {
        let engine = try AetherEngine()
        engine.setPendingRecoverySeekTarget(42)
        engine.pendingRecoverySeekDeadlineExpired = true
        engine.pendingRecoverySeekSubtitlesReanchored = true

        // A superseding seek to the same target is still a new lifecycle.
        engine.setPendingRecoverySeekTarget(42)
        #expect(!engine.pendingRecoverySeekDeadlineExpired)
        #expect(!engine.pendingRecoverySeekSubtitlesReanchored)

        engine.pendingRecoverySeekDeadlineExpired = true
        engine.pendingRecoverySeekSubtitlesReanchored = true
        engine.setPendingRecoverySeekTarget(nil)
        #expect(!engine.pendingRecoverySeekDeadlineExpired)
        #expect(!engine.pendingRecoverySeekSubtitlesReanchored)
    }

    @Test("seek recovery reasserts only pauses covered by the bounded recovery policy")
    func recoveredStateDecision() {
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: false,
            statusIsPaused: false,
            shouldReassertPausedStatus: true
        ) == .playing)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: false,
            statusIsPaused: true,
            shouldReassertPausedStatus: true
        ) == .paused)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: true,
            statusIsPaused: true,
            shouldReassertPausedStatus: false
        ) == .paused)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: true,
            statusIsPaused: true,
            shouldReassertPausedStatus: true
        ) == .playing)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: true,
            statusIsPaused: false,
            shouldReassertPausedStatus: false
        ) == .playing)
    }
}
