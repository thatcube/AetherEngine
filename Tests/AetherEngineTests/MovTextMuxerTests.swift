import XCTest
@testable import AetherEngine

final class MovTextMuxerTests: XCTestCase {
    // The muxer's FFmpeg interop is validated end-to-end by the Phase 0
    // spike + ffprobe; here we pin the pure helper the muxer uses to map
    // seconds onto the subtitle stream time_base (1/1000), so the
    // sample-write timing cannot silently regress.
    func test_secondsToSubtitleTimeBaseTicks_millisecondBase() {
        XCTAssertEqual(MP4SegmentMuxer.subtitleTicks(forSeconds: 1.5, timescale: 1000), 1500)
        XCTAssertEqual(MP4SegmentMuxer.subtitleTicks(forSeconds: 0.0, timescale: 1000), 0)
        XCTAssertEqual(MP4SegmentMuxer.subtitleTicks(forSeconds: 90.0, timescale: 1000), 90000)
    }
}
