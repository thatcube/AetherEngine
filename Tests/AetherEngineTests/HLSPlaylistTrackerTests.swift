import XCTest
@testable import AetherEngine

final class HLSPlaylistTrackerTests: XCTestCase {

    private func playlist(sequence: Int, uris: [String]) -> HLSMediaPlaylist {
        HLSMediaPlaylist(
            targetDuration: 4,
            mediaSequence: sequence,
            segments: uris.map { HLSMediaSegment(uri: $0, duration: 4, discontinuityBefore: false) },
            hasEndList: false,
            isEncrypted: false,
            hasMap: false
        )
    }

    func testPrimesAtLiveEdgeMinusOffset() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3)
        let new = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c", "d", "e", "f"]))
        // 6 segments, edge offset 3 -> start at sequence 103 ("d").
        XCTAssertEqual(new.map(\.uri), ["d", "e", "f"])
        XCTAssertEqual(tracker.stallCount, 0)
    }

    func testPrimesAtWindowStartWhenWindowIsShort() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3)
        let new = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b"]))
        XCTAssertEqual(new.map(\.uri), ["a", "b"])
    }

    func testReturnsOnlyNewSegmentsOnRefresh() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        let new = tracker.newSegments(in: playlist(sequence: 101, uris: ["b", "c", "d"]))
        XCTAssertEqual(new.map(\.uri), ["d"])
    }

    func testCountsStallsAndResets() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        XCTAssertEqual(tracker.stallCount, 1)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        XCTAssertEqual(tracker.stallCount, 2)
        _ = tracker.newSegments(in: playlist(sequence: 101, uris: ["b", "c", "d"]))
        XCTAssertEqual(tracker.stallCount, 0)
    }

    func testWindowSlidePastCursorRejoinsAtEdgeWithDiscontinuity() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        // Provider window slid far past our cursor (103): rejoin at edge.
        let new = tracker.newSegments(in: playlist(sequence: 500, uris: ["x", "y", "z", "w", "v", "u"]))
        XCTAssertEqual(new.map(\.uri), ["w", "v", "u"])
        XCTAssertTrue(new[0].discontinuityBefore, "rejoin must be marked as a discontinuity")
    }
}
