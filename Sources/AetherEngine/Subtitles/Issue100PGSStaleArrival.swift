import Foundation

/// Holdback for PGS cues that arrive already behind the playhead (issue #100).
///
/// PGS compositions have no intrinsic end: FFmpeg reports `end_display_time = UINT32_MAX`, the
/// decoder stamps the cue with an open-ended placeholder window, and the SUCCESSOR composition's
/// trim closes it (`pgsTrimAt`). In steady state insert and trim land within a frame of each
/// other and nothing untoward shows. When the side reader catches up after starvation (the #96
/// class), the backlog arrives with multi-second decode gaps and every historical cue's open
/// window covers the playhead the moment it inserts, so ~seconds of stale subtitles flash
/// through the overlay one by one.
///
/// The gate holds a PGS event whose cues start more than `staleEpsilonSeconds` behind the
/// playhead (a catch-up signature; a live cue at a seek landing anchors at most ~2 s back and
/// passes straight through). The next PGS event or clear event resolves the hold: trimmed to the
/// successor's start, the cue publishes only if its true window covers the playhead (it is the
/// genuinely active subtitle), otherwise it is dropped silently. Trade-off, accepted: the LAST
/// backlog cue has no successor yet and stays held until the next composition arrives; missing
/// one line briefly beats replaying 80 s of history through the live overlay.
struct PGSStaleArrivalGate {
    let staleEpsilonSeconds: Double
    private(set) var heldCues: [SubtitleCue] = []

    init(staleEpsilonSeconds: Double = 5.0) {
        self.staleEpsilonSeconds = staleEpsilonSeconds
    }

    var hasHeld: Bool { !heldCues.isEmpty }

    /// Resolve the held event against its successor's trim point. Returns the cues to publish
    /// NOW: the held cues trimmed to `trimAt`, filtered to those whose true window covers the
    /// playhead. History that ended before the playhead is dropped.
    mutating func resolveHeld(trimAt: Double, playhead: Double) -> [SubtitleCue] {
        guard !heldCues.isEmpty else { return [] }
        let resolved = heldCues.map { cue in
            SubtitleCue(id: cue.id, startTime: cue.startTime,
                        endTime: min(cue.endTime, trimAt), body: cue.body)
        }
        heldCues = []
        return resolved.filter { $0.startTime <= playhead && playhead < $0.endTime }
    }

    /// Admit an incoming event's cues. Stale PGS arrivals (every cue starting more than the
    /// epsilon behind the playhead) are held for successor resolution and publish nothing yet;
    /// everything else passes through unchanged.
    mutating func admit(cues: [SubtitleCue], isPGS: Bool, playhead: Double) -> [SubtitleCue] {
        guard isPGS, !cues.isEmpty else { return cues }
        let stale = cues.allSatisfy { $0.startTime < playhead - staleEpsilonSeconds }
        guard stale else { return cues }
        heldCues = cues
        return []
    }

    /// Drop the hold without publishing (seek re-anchor, track switch, clear, stop).
    mutating func reset() {
        heldCues = []
    }
}
