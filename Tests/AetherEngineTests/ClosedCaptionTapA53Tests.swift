import Testing
@testable import AetherEngine

// #131: lazy track surfacing keys off the first REAL caption pair; padding-only cc_data (which many
// encoders send continuously with no caption service) must never surface a track.
@Suite("ClosedCaptionTap A53 detection criterion")
@MainActor
struct ClosedCaptionTapA53Tests {

    @Test("Null padding and parity-only bytes are not real caption data")
    func padding() {
        #expect(!ClosedCaptionTap.containsRealCaptionData([]))
        #expect(!ClosedCaptionTap.containsRealCaptionData([.init(d0: 0x00, d1: 0x00)]))
        // 0x80 0x80 is the classic parity-bearing null pad: both bytes strip to 0.
        #expect(!ClosedCaptionTap.containsRealCaptionData([.init(d0: 0x80, d1: 0x80)]))
    }

    @Test("Any non-null pair after parity strip is real caption data")
    func realData() {
        #expect(ClosedCaptionTap.containsRealCaptionData([.init(d0: 0x94, d1: 0x20)]))   // control
        #expect(ClosedCaptionTap.containsRealCaptionData([.init(d0: 0x80, d1: 0xC1)]))   // char pair
        #expect(ClosedCaptionTap.containsRealCaptionData(
            [.init(d0: 0x00, d1: 0x00), .init(d0: 0x94, d1: 0x20)]))
    }

    @Test("Synthetic track id sits between real stream indices and external ids")
    func syntheticID() {
        #expect(AetherEngine.a53ClosedCaptionTrackID == 99_608)
        #expect(AetherEngine.a53ClosedCaptionTrackID < AetherEngine.externalSubtitleTrackIDBase)
    }
}
