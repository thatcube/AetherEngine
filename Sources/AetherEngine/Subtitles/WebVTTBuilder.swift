import Foundation

/// Builds a WebVTT body from decoded cue tuples on the AVPlayer timeline (#15). Text is sanitized
/// (ASS markup stripped) via MovTextSampleBuilder. Plain cues only; no positioning/styling. Served as a
/// separate HLS SUBTITLES rendition so AVKit renders subtitles in the PiP window (the on-frame overlay is not
/// in the PiP layer); muxing timed text into the A/V fMP4 is non-conformant for HLS (see #55).
enum WebVTTBuilder {
    /// `WEBVTT` header followed by one cue block per non-empty cue: `HH:MM:SS.mmm --> HH:MM:SS.mmm` + text.
    static func body(cues: [(start: Double, end: Double, text: String)]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            let text = MovTextSampleBuilder.sanitize(cue.text)
            if text.isEmpty { continue }
            out += "\(timestamp(cue.start)) --> \(timestamp(max(cue.start, cue.end)))\n\(text)\n\n"
        }
        return out
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let whole = Int(total)
        let h = whole / 3600
        let m = (whole % 3600) / 60
        let s = whole % 60
        let ms = min(999, Int((total - Double(whole)) * 1000.0 + 0.5))
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
