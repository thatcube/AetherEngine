import Testing
@testable import AetherEngine

struct SubtitleRenditionPlaylistTests {
    @Test("VOD subtitle media playlist is single-segment with ENDLIST")
    func vodSubtitlePlaylist() {
        let p = HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 0, programDuration: 42.0)
        #expect(p.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(p.contains("#EXTINF:42.000,"))
        #expect(p.contains("subs_0.vtt"))
        #expect(p.contains("#EXT-X-ENDLIST"))
        #expect(p.contains("#EXT-X-TARGETDURATION:42"))
    }

    @Test("subtitle playlist references the correct ordinal segment")
    func ordinalSegment() {
        let p = HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 3, programDuration: 10.0)
        #expect(p.contains("subs_3.vtt"))
    }

    @Test("parseSubsOrdinal extracts the ordinal from both extensions")
    func parsesOrdinal() {
        #expect(HLSLocalServer.parseSubsOrdinal("/subs_0.m3u8") == 0)
        #expect(HLSLocalServer.parseSubsOrdinal("/subs_2.vtt") == 2)
        #expect(HLSLocalServer.parseSubsOrdinal("/subs_11.m3u8") == 11)
        #expect(HLSLocalServer.parseSubsOrdinal("/garbage") == 0)
    }
}
