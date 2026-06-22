import Foundation

/// Stateless builder for tx3g (mov_text) sample payloads (#55). A
/// mov_text sample is a uint16 big-endian byte-length prefix followed
/// by the UTF-8 text (style boxes omitted; plain text for broad
/// AVPlayer compatibility). Pure, no engine state.
enum MovTextSampleBuilder {

    /// `[uint16 BE byte-length][UTF-8 text]` for a cue, ASS markup
    /// stripped. Empty text produces the empty sample.
    static func sample(text: String) -> Data {
        let clean = sanitize(text)
        let utf8 = Array(clean.utf8)
        let len = min(utf8.count, 0xFFFF)
        var data = Data([UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        data.append(contentsOf: utf8.prefix(len))
        return data
    }

    /// `[0x00, 0x00]`: a zero-length mov_text sample, used to fill the
    /// gaps between cues so the track stays contiguous.
    static func emptySample() -> Data {
        Data([0x00, 0x00])
    }

    /// Strip ASS/SSA override blocks (`{\...}`) and normalize the inline
    /// escapes mov_text cannot carry. Conservative: plain text only.
    static func sanitize(_ assText: String) -> String {
        var s = assText
        while let open = s.firstIndex(of: "{"), let close = s[open...].firstIndex(of: "}") {
            s.removeSubrange(open...close)
        }
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
