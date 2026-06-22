import XCTest
@testable import AetherEngine

final class MovTextSampleBuilderTests: XCTestCase {
    func test_sample_hasBigEndianLengthPrefixThenUTF8() {
        let data = MovTextSampleBuilder.sample(text: "Hi")
        XCTAssertEqual([UInt8](data), [0x00, 0x02, 0x48, 0x69]) // len=2, "Hi"
    }

    func test_emptySample_isTwoZeroBytes() {
        XCTAssertEqual([UInt8](MovTextSampleBuilder.emptySample()), [0x00, 0x00])
    }

    func test_sample_stripsASSOverrideTagsAndConvertsBreaks() {
        let data = MovTextSampleBuilder.sample(text: "{\\an8}{\\b1}Top{\\b0}\\Nline")
        let expectedText = "Top\nline"
        let bytes = [UInt8](data)
        let len = Int(bytes[0]) << 8 | Int(bytes[1])
        XCTAssertEqual(len, expectedText.utf8.count)
        XCTAssertEqual(String(bytes: bytes[2...], encoding: .utf8), expectedText)
    }

    func test_sample_multibyteLengthIsByteCountNotCharCount() {
        let data = MovTextSampleBuilder.sample(text: "ä") // 2 UTF-8 bytes
        XCTAssertEqual([UInt8](data)[0...1], [0x00, 0x02])
    }

    func test_sanitize_plainPassesThrough() {
        XCTAssertEqual(MovTextSampleBuilder.sanitize("plain"), "plain")
    }
}
