import Foundation
import Libavcodec
import Libavutil
import Dovi

/// In-place rewrite of a HEVC video packet's Dolby Vision metadata from
/// Profile 7 (dual-layer, BL + EL + RPU) to single-layer Profile 8.1.
///
/// Profile 7 carries three kinds of NAL per access unit: the HEVC base
/// layer (normal video NALs), an enhancement layer in NAL type 63
/// (unspec63), and a Dolby Vision RPU in NAL type 62 (unspec62). Profile
/// 8.1 keeps the base layer + RPU but drops the enhancement layer, and
/// the RPU itself is rewritten so its profile field reads 8 with the
/// residual sub-layer disabled. libdovi (mode 2) does the RPU rewrite;
/// we do the NAL surgery (drop EL, splice the converted RPU back in).
///
/// Packets arrive in AVCC / hvcC layout: each NAL is a 4-byte big-endian
/// length prefix followed by the NAL unit bytes. libdovi consumes and
/// produces a full unspec62 NAL UNIT (including the 2-byte HEVC NAL
/// header) and handles emulation-prevention bytes internally, so we
/// never strip or insert EPB ourselves.
public enum DoviRpuConverter {

    /// HEVC NAL types we special-case. All others copy through unchanged.
    private static let nalTypeRPU: UInt8 = 62   // unspec62: Dolby Vision RPU
    private static let nalTypeEL: UInt8  = 63   // unspec63: enhancement layer

    /// AVCC length-prefix width.
    private static let lengthPrefixSize = 4

    /// Convert one HEVC packet's DV metadata to Profile 8.1 in place.
    ///
    /// Returns `false` ONLY on a real libdovi failure (parse / convert /
    /// write), so the caller can fall back to the HDR10 strip path. A
    /// packet with no RPU (and no EL to drop) is not a failure: it is
    /// left untouched and `true` is returned.
    ///
    /// On any libdovi error the packet is left byte-for-byte untouched
    /// and every libdovi allocation made on the failing path is freed.
    public static func convertPacketToProfile81(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        // A null/empty payload has no RPU to convert: not a libdovi failure.
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return true }
        guard packet.pointee.size > 4 else { return true }
        let size = Int(packet.pointee.size)

        // Output NAL units (each WITHOUT its length prefix; we re-prefix
        // on rebuild). We only allocate / mutate the packet if we actually
        // changed something (converted an RPU or dropped an EL).
        var outputNALs: [[UInt8]] = []
        var converted = false
        var droppedEL = false

        var off = 0
        while off + lengthPrefixSize <= size {
            // Big-endian u32 length prefix.
            var len = 0
            for i in 0..<lengthPrefixSize {
                len = (len << 8) | Int(data[off + i])
            }
            let nalStart = off + lengthPrefixSize
            // Bounds check: a truncated / malformed trailer stops the walk.
            // A zero length is degenerate; stop rather than spin.
            if len == 0 || nalStart + len > size { break }

            // HEVC NAL header byte 0: forbidden_zero_bit(1) +
            // nal_unit_type(6) + layer_id high bit(1). Type is bits 1..6.
            let nalType = (data[nalStart] >> 1) & 0x3F

            switch nalType {
            case nalTypeRPU:
                // Parse the full unspec62 NAL unit (header included).
                guard let rpu = dovi_parse_unspec62_nalu(data + nalStart, len) else {
                    // Parse failure: no allocation handed back to free.
                    return false
                }
                // Mode 2 = convert to Profile 8.1.
                let rc = dovi_convert_rpu_with_mode(rpu, 2)
                if rc != 0 {
                    dovi_rpu_free(rpu)
                    return false
                }
                // Write the rewritten unspec62 NAL unit (header included).
                guard let out = dovi_write_unspec62_nalu(rpu) else {
                    dovi_rpu_free(rpu)
                    return false
                }
                let outLen = out.pointee.len
                guard let outData = out.pointee.data, outLen > 0 else {
                    // Zero-length or nil write is a libdovi failure, not an
                    // empty packet. Free and signal failure so the caller falls back.
                    dovi_data_free(out)
                    dovi_rpu_free(rpu)
                    return false
                }
                outputNALs.append([UInt8](UnsafeBufferPointer(start: outData, count: outLen)))
                dovi_data_free(out)
                dovi_rpu_free(rpu)
                converted = true

            case nalTypeEL:
                // Enhancement layer: drop it from the output entirely.
                droppedEL = true

            default:
                // Everything else (base-layer video, SPS/PPS/VPS, SEI, etc.)
                // passes through byte-for-byte.
                outputNALs.append([UInt8](UnsafeBufferPointer(start: data + nalStart, count: len)))
            }

            off = nalStart + len
        }

        // Nothing to do: no RPU converted and no EL dropped. Leave the
        // packet untouched. This is the common case for non-DV-P7 packets
        // and is explicitly NOT an error.
        if !converted && !droppedEL {
            return true
        }

        // Rebuild the packet payload: [4-byte BE length][NAL bytes] per NAL.
        var total = 0
        for nal in outputNALs {
            total += lengthPrefixSize + nal.count
        }
        // Degenerate: all NALs were EL and none survived (no base-layer
        // video, no RPU). Leave the packet untouched rather than producing
        // a zero-length video packet that would confuse downstream decoders.
        guard total > 0 else { return true }

        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let newRef = av_buffer_alloc(total + pad) else {
            // Allocation failure: treat as a real failure so the caller
            // falls back. The packet is still untouched at this point.
            return false
        }
        guard let dst = newRef.pointee.data else {
            var ref: UnsafeMutablePointer<AVBufferRef>? = newRef
            av_buffer_unref(&ref)
            return false
        }

        // Write each NAL with a fresh big-endian length prefix.
        var w = 0
        for nal in outputNALs {
            let n = nal.count
            dst[w + 0] = UInt8((n >> 24) & 0xFF)
            dst[w + 1] = UInt8((n >> 16) & 0xFF)
            dst[w + 2] = UInt8((n >> 8) & 0xFF)
            dst[w + 3] = UInt8(n & 0xFF)
            w += lengthPrefixSize
            nal.withUnsafeBufferPointer { src in
                if let base = src.baseAddress, n > 0 {
                    memcpy(dst + w, base, n)
                }
            }
            w += n
        }
        // Zero the required trailing padding (decoders read past size).
        memset(dst + total, 0, pad)

        // Swap the packet's buffer. Preserve pts / dts / flags / stream_index
        // and every other field; only the payload buffer changes.
        av_buffer_unref(&packet.pointee.buf)
        packet.pointee.buf = newRef
        packet.pointee.data = newRef.pointee.data
        packet.pointee.size = Int32(total)
        return true
    }
}
