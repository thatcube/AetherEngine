import Testing
import Libavcodec
@testable import AetherEngine

@Suite("Teletext decoder options + classification (#107)")
struct TeletextDecoderOptionsTests {
    @Test("teletext gets txt_format=text and txt_page=subtitle")
    func teletextOptions() {
        let opts = EmbeddedSubtitleDecoder.decoderOptions(for: AV_CODEC_ID_DVB_TELETEXT)
        #expect(opts["txt_format"] == "text")
        #expect(opts["txt_page"] == "subtitle")
    }

    @Test("non-teletext codecs get no decoder options")
    func otherCodecsNoOptions() {
        #expect(EmbeddedSubtitleDecoder.decoderOptions(for: AV_CODEC_ID_HDMV_PGS_SUBTITLE).isEmpty)
        #expect(EmbeddedSubtitleDecoder.decoderOptions(for: AV_CODEC_ID_SUBRIP).isEmpty)
        #expect(EmbeddedSubtitleDecoder.decoderOptions(for: AV_CODEC_ID_DVB_SUBTITLE).isEmpty)
    }

    @Test("teletext is classified as text, not bitmap, at both classifiers")
    func teletextIsText() {
        #expect(!EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_DVB_TELETEXT))
        #expect(!AetherEngine.isBitmapSubtitleCodec("dvb_teletext"))
    }
}
