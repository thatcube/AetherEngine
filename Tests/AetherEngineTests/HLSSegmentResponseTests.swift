import Testing
@testable import AetherEngine

/// #50: an in-range VOD segment that simply hasn't been produced into the
/// rolling cache yet must NOT surface as a fatal 404. AVPlayer treats a 404
/// on a VOD segment as terminal `loadFailed`. Only a genuinely out-of-range
/// index (past the advertised segmentCount) is "not found"; everything
/// inside [0, segmentCount) is regenerable and must be retriable.
@Suite("Segment response classification (#50)")
struct HLSSegmentResponseTests {

    @Test("Present data serves regardless of index")
    func presentDataServes() {
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 5, segmentCount: 110, hasData: true) == .serve)
        // Even an index reported past the count serves if bytes exist (the
        // live list can grow between the count read and the fetch).
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 200, segmentCount: 110, hasData: true) == .serve)
    }

    @Test("In-range miss is retriable, not 404 (the #50 wedge)")
    func inRangeMissIsRetriable() {
        // rrgomes' device indices: all < segmentCount, evicted from the
        // ~16-19-segment live window, producer positioned elsewhere.
        for idx in [0, 7, 19, 21, 33, 66, 93, 109] {
            #expect(HLSLocalServer.classifySegmentResponse(
                index: idx, segmentCount: 110, hasData: false) == .retryLater,
                "seg\(idx) is in-range (< 110) and must be retriable, never 404")
        }
    }

    @Test("Out-of-range miss is a genuine 404")
    func outOfRangeMissIsNotFound() {
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 110, segmentCount: 110, hasData: false) == .notFound)
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 250, segmentCount: 110, hasData: false) == .notFound)
    }

    @Test("Unknown segment count (provider not ready) is a 404, not a hang")
    func unknownCountIsNotFound() {
        // provider == nil reports segmentCount = -1; nothing is in-range.
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 0, segmentCount: -1, hasData: false) == .notFound)
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 5, segmentCount: 0, hasData: false) == .notFound)
    }
}
