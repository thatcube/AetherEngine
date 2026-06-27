import Foundation
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

/// In-band CEA-608 closed-caption support for a demuxable caption track (`eia_608` / QuickTime `c608`) (#77).
///
/// Externalised tap: a read-only observer attached to the `HLSSegmentProducer`'s source demuxer (the
/// connection the engine already reads reliably). The producer keeps the `eia_608` caption stream, hands
/// each of its packets to the tap, then drops it (never muxed → output byte-identical). The tap decodes
/// on the pump thread
/// and **owns the cue buffer**, publishing an immutable snapshot to the MainActor whenever it changes.
/// The engine mirrors that snapshot into `subtitleCues` while the CC track is the active subtitle.
///
/// Because the tap holds the full buffer, enabling CC mid-playback shows captions instantly (mirror the
/// snapshot — no producer restart), and a seek that re-pumps an overlapping region can't create duplicate
/// cues (the single buffer owns them). `makeProducer` re-threads the observer onto every restart, so it
/// survives seek/reload/wedge with no second connection.
///
/// First cut: 608 field-1 / CC1 only (see `CEA608Decoder`). Decode state is guarded by an internal lock
/// (the restart path can briefly overlap two pumps on one tap); `@unchecked Sendable` for the
/// observer-closure boundary. Snapshot publication hops to the MainActor.
final class ClosedCaptionTap: @unchecked Sendable {
    private weak var engine: AetherEngine?
    let ccStreamIndex: Int32

    /// Guards all decode state below. `ingest()` normally runs only on the single producer pump thread, but
    /// the restart path abandons an old pump after a 5 s join timeout (`HLSVideoEngine.performRestart`), so an
    /// abandoned old pump can briefly overlap the new one calling into the same tap. The lock keeps `decoder`
    /// (not thread-safe) and the cue buffer memory-safe under that overlap, mirroring `NativeSubtitleCueStore`
    /// (#55). Worst case during the rare overlap is a few garbled cues that self-correct on the next reset/EOC.
    private let lock = NSLock()

    private let decoder = CEA608Decoder()
    private var lastPTS: Double = -1

    // Cue buffer, guarded by `lock`.
    private var cues: [SubtitleCue] = []
    private var openCueID: Int?
    private var nextID = 0

    /// Keep this many seconds of decoded cues behind the furthest-decoded caption (the producer runs
    /// ahead of the playhead, so this window comfortably covers the visible region in both directions).
    private static let retentionSeconds: Double = 180
    /// Provisional dwell for a caption with no explicit end yet; trimmed by the next caption/erase.
    private static let provisionalDwell: Double = 12

    /// Monotonic snapshot sequence. The MainActor hops are unstructured Tasks with no ordering guarantee,
    /// so a burst of rapid publishes (fast initial pump) could land a STALE snapshot after a fresh one and
    /// overwrite it — captions then render with un-trimmed provisional ends (too early / back-to-back).
    /// The engine drops any snapshot whose seq is older than the last it applied.
    private var publishSeq = 0
    /// Set from the MainActor on `seek()`; consumed on the next ingest to drop decoder + buffer state at a
    /// known discontinuity. A plain `Bool` write/read across threads is benign here — at worst a reset is
    /// applied one packet late. Preferred over a wall-clock PTS-gap heuristic, which false-fires on the
    /// long no-caption gaps (silence / music) that are normal for a sparse caption track.
    private var resetRequested = false

    init(engine: AetherEngine, ccStreamIndex: Int32) {
        self.engine = engine
        self.ccStreamIndex = ccStreamIndex
    }

    /// Drop decoder + cue-buffer state on the next ingest. Called from `seek()` so a scrub starts clean.
    func requestReset() {
        lock.lock(); resetRequested = true; lock.unlock()
    }

    /// Called on the producer pump thread for each CC-stream packet.
    func ingest(_ packet: UnsafePointer<AVPacket>, timeBase tb: AVRational) {
        let triplets = CCDataParser.parseCCDataTriplets(packet: packet).filter { $0.type == 0 }
        guard !triplets.isEmpty else { return }

        // Parsing above touches only the packet; everything below mutates shared decode state.
        lock.lock()
        defer { lock.unlock() }

        let raw = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
        let pts: Double
        if raw != Int64.min, tb.num > 0, tb.den > 0 {
            pts = Double(raw) * Double(tb.num) / Double(tb.den)
        } else {
            pts = lastPTS >= 0 ? lastPTS : 0
        }

        // Discontinuity: an explicit seek (resetRequested) or a backward PTS jump means the producer
        // re-anchored. Drop stale decoder state AND the cue buffer so the old region can't bleed across the
        // cut (or duplicate when the new region is re-pumped). A forward PTS gap is NOT treated as a seek —
        // it's a normal silence/music gap in a sparse caption track.
        if resetRequested || (lastPTS >= 0 && pts < lastPTS - 1.0) {
            resetRequested = false
            decoder.reset()
            cues.removeAll(keepingCapacity: true)
            openCueID = nil
        }
        lastPTS = pts

        var changed = false
        for t in triplets {
            for action in decoder.feed(t.data0, t.data1) {
                applyAction(action, pts: pts)
                changed = true
            }
        }
        guard changed else { return }
        prune(referencePTS: pts)
        publishSnapshot()
    }

    private func applyAction(_ action: CEA608Decoder.Action, pts: Double) {
        // Close the currently-displayed caption at this PTS.
        if let id = openCueID, let idx = cues.firstIndex(where: { $0.id == id }) {
            let c = cues[idx]
            if c.endTime > pts, c.startTime <= pts {
                cues[idx] = SubtitleCue(id: c.id, startTime: c.startTime, endTime: pts, body: c.body)
            }
            openCueID = nil
        }
        guard case .display(let text) = action, !text.isEmpty else { return }
        // Dedupe: an in-buffer re-decode of the same caption adopts the existing cue instead of stacking.
        if let existing = cues.first(where: { abs($0.startTime - pts) < 0.10 && $0.text == text }) {
            openCueID = existing.id
            return
        }
        let id = nextID
        nextID += 1
        let cue = SubtitleCue(id: id, startTime: pts, endTime: pts + Self.provisionalDwell, body: .text(text))
        var lo = 0, hi = cues.count
        while lo < hi { let m = (lo + hi) / 2; if cues[m].startTime < cue.startTime { lo = m + 1 } else { hi = m } }
        cues.insert(cue, at: lo)
        openCueID = id
    }

    private func prune(referencePTS: Double) {
        let cutoff = referencePTS - Self.retentionSeconds
        guard cutoff > 0 else { return }
        cues.removeAll { $0.endTime < cutoff && $0.id != openCueID }
    }

    private func publishSnapshot() {
        publishSeq += 1
        let snapshot = cues
        let seq = publishSeq
        let idx = ccStreamIndex
        Task { @MainActor [weak engine] in
            engine?.updateClosedCaptionCues(snapshot, seq: seq, ccStreamIndex: idx)
        }
    }
}

extension AetherEngine {

    /// True when the subtitle stream at `streamIndex` is an in-band CEA-608/708 track (rendered by the CC
    /// tap rather than the side-demuxer `EmbeddedSubtitleDecoder`).
    func activeSubtitleStreamIsClosedCaption(_ streamIndex: Int32) -> Bool {
        guard let codec = subtitleTracks.first(where: { $0.id == Int(streamIndex) })?.codec else { return false }
        return Self.isEmbeddedClosedCaptionCodec(codec)
    }

    /// Create the CC tap and wire it onto the video session before `start()` so the first producer keeps
    /// the CC stream. The tap runs for the whole session (CC packets are sparse — negligible cost) and
    /// maintains the cue buffer; cues are mirrored into `subtitleCues` only while CC is the active subtitle.
    /// No-op when the source has no in-band CC track.
    func setupClosedCaptionTapIfNeeded(session: HLSVideoEngine) {
        guard let ccTrack = subtitleTracks.first(where: { Self.isEmbeddedClosedCaptionCodec($0.codec) }) else {
            closedCaptionTap = nil
            ccCueSnapshot = []
            ccLastSnapshotSeq = 0
            return
        }
        let idx = Int32(ccTrack.id)
        let tap = ClosedCaptionTap(engine: self, ccStreamIndex: idx)
        closedCaptionTap = tap
        ccCueSnapshot = []
        ccLastSnapshotSeq = 0   // fresh tap's publishSeq restarts at 1
        session.closedCaptionStreamIndexForSession = idx
        session.closedCaptionObserverForSession = { [weak tap] packet, tb in
            tap?.ingest(packet, timeBase: tb)
        }
        EngineLog.emit("[AetherEngine] CC tap armed on source stream=\(idx)", category: .engine)
    }

    /// Receive the tap's latest cue snapshot (off the pump thread). Drops out-of-order snapshots (the
    /// MainActor hops aren't FIFO) so a stale one can't overwrite a fresher one. Mirror into `subtitleCues`
    /// only while the CC track is the active primary subtitle.
    @MainActor
    func updateClosedCaptionCues(_ snapshot: [SubtitleCue], seq: Int, ccStreamIndex: Int32) {
        guard seq > ccLastSnapshotSeq else { return }
        ccLastSnapshotSeq = seq
        ccCueSnapshot = snapshot
        guard isSubtitleActive(for: .primary), activeEmbeddedSubtitleStreamIndex == ccStreamIndex else { return }
        subtitleCues = snapshot
    }
}
