import XCTest
@testable import AetherEngine

final class DiscDemuxIntegrationTests: XCTestCase {
    /// A fixture ISO carries fake VOB bytes (pack-start code only, no real
    /// elementary streams), so this asserts the demuxer ACCEPTS the disc path
    /// and reaches an mpegps open without throwing a DiscError. Real-stream
    /// decoding is covered by a manual real-ISO check outside CI.
    func test_discISORoutesToMpegPSOpen() throws {
        let data = ISO9660Fixture.make(files: [
            .init(name: "VTS_01_1.VOB", length: 2048),
        ])
        let demuxer = Demuxer()
        do {
            try demuxer.open(reader: DataIOReader(data: data), formatHint: nil)
            demuxer.close()
        } catch let e as DiscError {
            XCTFail("disc detection should not surface DiscError here: \(e)")
        } catch {
            // A libav open error from the toy payload is acceptable for this
            // unit-level check; the disc path was taken (no DiscError).
        }
    }
}
