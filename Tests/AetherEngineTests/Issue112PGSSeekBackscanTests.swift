import Foundation
import Testing
@testable import AetherEngine

/// #112 (ijuniorfu): after a fast-forward / audio-track switch into the middle of a PGS (Blu-ray) line, the
/// overlay showed nothing for "ten or several tens of seconds". PGS is stateful and sparse: a line's composition
/// (object def) can precede the seek target by tens of seconds, so the fixed -2 s lead-in landed after it and the
/// active line never reconstructed.
///
/// The first attempt scanned backward in geometric probe steps with a throwaway decoder. On a remote MPEG-TS
/// Blu-ray that regressed into "no subtitles at all": a disc has no index and `discardAllStreamsExcept` drops
/// packets only after they are read off the wire, so each backward probe re-downloaded its whole look-back span.
/// Into a subtitle-sparse region every probe missed, the scan ran to the 60 s cap (~114 s of disc re-read,
/// un-cancellable), and the reader was superseded before it served a cue. The reader now seeks back once by a
/// source-aware lead-in and reconstructs in a single forward pass; the #100 stale-arrival gate publishes the
/// composition whose window covers the playhead. Indexed containers (MP4/MKV) fast-walk their sample index
/// between the sparse packets so they get the full window; disc sources are capped tight so a remote ISO is not
/// re-downloaded.
struct Issue112PGSSeekBackscanTests {

    @Test("an indexed container reconstructs across the full look-back window")
    func indexedSourceUsesFullWindow() {
        // MP4/MKV fast-walk their in-memory sample index between the sparse subtitle packets with almost no I/O,
        // so the lead-in can span tens of seconds to recover a long-lived line.
        #expect(AetherEngine.bitmapSubtitleReconstructLeadIn(isDiscSource: false) == 60.0)
    }

    @Test("a disc source caps the look-back so a remote MPEG-TS is not re-downloaded")
    func discSourceCapsLookBack() {
        let disc = AetherEngine.bitmapSubtitleReconstructLeadIn(isDiscSource: true)
        let indexed = AetherEngine.bitmapSubtitleReconstructLeadIn(isDiscSource: false)
        // Still reconstructs a recently-composed line (a disc gets more than the bare -2 s text lead-in) ...
        #expect(disc > 2.0)
        // ... but far less than the indexed window: this is the #112 regression fix. A concat MPEG-TS has no
        // index, so every second of look-back re-downloads a second of the muxed program.
        #expect(disc < indexed)
        // Bounded so a single forward reconstruct read on a remote ISO stays cheap.
        #expect(disc <= 30.0)
    }

    @Test("the lead-in is a fixed, positive per-source constant")
    func leadInIsStableAndPositive() {
        // Deterministic (the seek target must not drift between reader restarts on the same source).
        #expect(AetherEngine.bitmapSubtitleReconstructLeadIn(isDiscSource: true)
                == AetherEngine.bitmapSubtitleReconstructLeadIn(isDiscSource: true))
        #expect(AetherEngine.bitmapSubtitleReconstructLeadIn(isDiscSource: false)
                == AetherEngine.bitmapSubtitleReconstructLeadIn(isDiscSource: false))
        #expect(AetherEngine.bitmapSubtitleReconstructLeadIn(isDiscSource: true) > 0)
        #expect(AetherEngine.bitmapSubtitleReconstructLeadIn(isDiscSource: false) > 0)
    }
}
