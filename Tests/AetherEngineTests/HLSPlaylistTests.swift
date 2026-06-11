import XCTest
@testable import AetherEngine

final class HLSPlaylistTests: XCTestCase {

    func testParsesMasterAndPicksHighestBandwidth() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=640x360
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5120000,RESOLUTION=1920x1080
        high/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2560000,RESOLUTION=1280x720
        mid/index.m3u8
        """
        guard case .master(let variants) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected master playlist")
        }
        XCTAssertEqual(variants.count, 3)
        XCTAssertEqual(variants.max(by: { $0.bandwidth < $1.bandwidth })?.uri, "high/index.m3u8")
    }

    func testBandwidthAttributeIgnoresAverageBandwidth() throws {
        // AVERAGE-BANDWIDTH precedes BANDWIDTH on typical STREAM-INF
        // lines; an unanchored substring match used to return the
        // AVERAGE value and could rank variants wrongly.
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=9000000,BANDWIDTH=1280000,RESOLUTION=640x360
        low/index.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=4500000,BANDWIDTH=6000000,RESOLUTION=1920x1080
        high/index.m3u8
        """
        guard case .master(let variants) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected master playlist")
        }
        XCTAssertEqual(variants[0].bandwidth, 1_280_000)
        XCTAssertEqual(variants[1].bandwidth, 6_000_000)
        XCTAssertEqual(variants.max(by: { $0.bandwidth < $1.bandwidth })?.uri, "high/index.m3u8")
    }

    func testParsesMediaPlaylist() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:147
        #EXTINF:6.000,
        seg147.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:5.760,
        seg148.ts
        """
        guard case .media(let media) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertEqual(media.targetDuration, 6.0)
        XCTAssertEqual(media.mediaSequence, 147)
        XCTAssertEqual(media.segments.count, 2)
        XCTAssertEqual(media.segments[0].uri, "seg147.ts")
        XCTAssertFalse(media.segments[0].discontinuityBefore)
        XCTAssertTrue(media.segments[1].discontinuityBefore)
        XCTAssertFalse(media.hasEndList)
        XCTAssertFalse(media.isEncrypted)
        XCTAssertFalse(media.hasMap)
    }

    func testDetectsEncryptionAndMapAndEndlist() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        seg0.m4s
        #EXT-X-ENDLIST
        """
        guard case .media(let media) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertTrue(media.isEncrypted)
        XCTAssertTrue(media.hasMap)
        XCTAssertTrue(media.hasEndList)
    }

    func testKeyMethodNoneIsNotEncrypted() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4.0,
        seg0.ts
        """
        guard case .media(let media) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertFalse(media.isEncrypted)
    }

    func testRejectsNonPlaylist() {
        XCTAssertThrowsError(try HLSPlaylistParser.parse("<!DOCTYPE html><html></html>")) { error in
            guard case HLSIngestError.playlistInvalid = error else {
                return XCTFail("expected playlistInvalid, got \(error)")
            }
        }
    }

    func testRejectsMediaPlaylistWithoutSegments() {
        XCTAssertThrowsError(try HLSPlaylistParser.parse("#EXTM3U\n#EXT-X-TARGETDURATION:6\n"))
    }

    func testResolvesRelativeAndAbsoluteURIs() {
        let base = URL(string: "https://cdn.example.com/live/ch1/index.m3u8")!
        XCTAssertEqual(
            HLSPlaylistParser.resolve(uri: "seg1.ts", against: base)?.absoluteString,
            "https://cdn.example.com/live/ch1/seg1.ts"
        )
        XCTAssertEqual(
            HLSPlaylistParser.resolve(uri: "/abs/seg1.ts", against: base)?.absoluteString,
            "https://cdn.example.com/abs/seg1.ts"
        )
        XCTAssertEqual(
            HLSPlaylistParser.resolve(uri: "https://other.example.com/s.ts", against: base)?.absoluteString,
            "https://other.example.com/s.ts"
        )
    }
}
