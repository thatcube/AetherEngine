import Libavcodec

/// Pure codec-and-field-order routing decision extracted from AetherEngine.load's dispatch so it is
/// unit-testable. Mirrors the historical switch (AV1 gated on HW, VP9/VP8/MPEG4/MPEG2/VC1 always
/// software) and adds the #107 rule: interlaced H.264 goes software so DeinterlaceFilter (bwdif) can
/// deinterlace it. tvOS AVPlayer does not deinterlace, so 1080i broadcast otherwise combs.
enum VideoRoutingPolicy {

    /// Field orders that indicate interlaced content warranting software deinterlacing.
    static let interlacedFieldOrders: Set<AVFieldOrder> = [
        AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT
    ]

    /// True when a video codec must use the software decode path (SoftwarePlaybackHost) instead of
    /// native AVPlayer. `av1Available` is `VTCapabilityProbe.av1Available` (HW AV1 decode support).
    static func requiresSoftwarePath(
        codecID: AVCodecID,
        fieldOrder: AVFieldOrder,
        av1Available: Bool
    ) -> Bool {
        switch codecID {
        case AV_CODEC_ID_AV1:
            return !av1Available
        case AV_CODEC_ID_VP9, AV_CODEC_ID_VP8, AV_CODEC_ID_MPEG4,
             AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VC1:
            return true
        case AV_CODEC_ID_H264:
            return interlacedFieldOrders.contains(fieldOrder)
        default:
            return false
        }
    }
}
