import Foundation

/// One variant entry of a master playlist (#EXT-X-STREAM-INF).
struct HLSVariant: Equatable {
    let bandwidth: Int
    let uri: String
}

/// One media segment of a media playlist.
struct HLSMediaSegment: Equatable {
    let uri: String
    let duration: Double
    /// True when an EXT-X-DISCONTINUITY tag directly precedes this segment.
    let discontinuityBefore: Bool
}

struct HLSMediaPlaylist: Equatable {
    let targetDuration: Double
    let mediaSequence: Int
    let segments: [HLSMediaSegment]
    let hasEndList: Bool
    /// Any EXT-X-KEY with METHOD != NONE anywhere in the playlist.
    let isEncrypted: Bool
    /// Any EXT-X-MAP tag (fMP4-segment playlist).
    let hasMap: Bool
}

enum HLSPlaylist: Equatable {
    case master([HLSVariant])
    case media(HLSMediaPlaylist)
}

/// Line-oriented parser for the subset of RFC 8216 the live ingest needs.
/// Pure (no I/O); the ingest reader feeds it fetched playlist text.
enum HLSPlaylistParser {

    static func parse(_ text: String) throws -> HLSPlaylist {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("#EXTM3U") == true else {
            throw HLSIngestError.playlistInvalid(reason: "missing #EXTM3U")
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return .master(try parseMaster(lines))
        }
        return .media(try parseMedia(lines))
    }

    /// Resolve a playlist-relative URI against the playlist's own URL.
    static func resolve(uri: String, against base: URL) -> URL? {
        URL(string: uri, relativeTo: base)?.absoluteURL
    }

    // MARK: - Private

    private static func parseMaster(_ lines: [String]) throws -> [HLSVariant] {
        var variants: [HLSVariant] = []
        var pendingBandwidth: Int?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap(Int.init) ?? 0
            } else if !line.hasPrefix("#"), let bw = pendingBandwidth {
                variants.append(HLSVariant(bandwidth: bw, uri: line))
                pendingBandwidth = nil
            }
        }
        guard !variants.isEmpty else {
            throw HLSIngestError.playlistInvalid(reason: "master playlist without variants")
        }
        return variants
    }

    private static func parseMedia(_ lines: [String]) throws -> HLSMediaPlaylist {
        var targetDuration: Double?
        var mediaSequence = 0
        var segments: [HLSMediaSegment] = []
        var hasEndList = false
        var isEncrypted = false
        var hasMap = false
        var pendingDuration: Double?
        var pendingDiscontinuity = false

        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count))
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let payload = line.dropFirst("#EXTINF:".count)
                pendingDuration = Double(payload.split(separator: ",").first.map(String.init) ?? "")
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = attribute("METHOD", in: line) ?? "NONE"
                if method != "NONE" { isEncrypted = true }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                hasMap = true
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
            } else if !line.hasPrefix("#") {
                segments.append(HLSMediaSegment(
                    uri: line,
                    duration: pendingDuration ?? targetDuration ?? 0,
                    discontinuityBefore: pendingDiscontinuity
                ))
                pendingDuration = nil
                pendingDiscontinuity = false
            }
        }
        guard let target = targetDuration else {
            throw HLSIngestError.playlistInvalid(reason: "missing TARGETDURATION")
        }
        guard !segments.isEmpty else {
            throw HLSIngestError.playlistInvalid(reason: "no segments")
        }
        return HLSMediaPlaylist(
            targetDuration: target,
            mediaSequence: mediaSequence,
            segments: segments,
            hasEndList: hasEndList,
            isEncrypted: isEncrypted,
            hasMap: hasMap
        )
    }

    /// Extract a KEY=VALUE attribute from a tag line; tolerates quoted values.
    ///
    /// The match is anchored: the character before the key must be `:`
    /// or `,` (the attribute-list separators). A bare substring search
    /// matched `BANDWIDTH=` inside `AVERAGE-BANDWIDTH=` (which precedes
    /// it on typical `#EXT-X-STREAM-INF:` lines), so variant selection
    /// ranked streams by their AVERAGE values and could pick the wrong
    /// variant.
    private static func attribute(_ key: String, in line: String) -> String? {
        let needle = "\(key)="
        var searchStart = line.startIndex
        while let range = line.range(of: needle, range: searchStart..<line.endIndex) {
            searchStart = range.upperBound
            if range.lowerBound != line.startIndex {
                let before = line[line.index(before: range.lowerBound)]
                guard before == ":" || before == "," else { continue }
            }
            let rest = line[range.upperBound...]
            if rest.hasPrefix("\"") {
                let afterQuote = rest.dropFirst()
                guard let end = afterQuote.firstIndex(of: "\"") else { return nil }
                return String(afterQuote[..<end])
            }
            let end = rest.firstIndex(of: ",") ?? rest.endIndex
            return String(rest[..<end])
        }
        return nil
    }
}
