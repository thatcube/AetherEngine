import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Extract every parameter-set NAL (VPS / SPS / PPS, plus any other
/// array entries) from an hvcC extradata blob, returned as raw NAL unit
/// byte arrays (no length prefix, no start code).
///
/// hvcC layout: a 22-byte fixed header, then byte 22 = numOfArrays.
/// Each array: 1 byte (array_completeness + NAL_unit_type), 2 bytes
/// numNalus, then per NAL: 2 bytes nalUnitLength + the NAL bytes.
private func parseHVCCParameterSets(_ ed: UnsafePointer<UInt8>, _ size: Int) -> [[UInt8]] {
    guard size > 23 else { return [] }
    var out: [[UInt8]] = []
    let numArrays = Int(ed[22])
    var p = 23
    for _ in 0..<numArrays {
        guard p + 3 <= size else { break }
        // ed[p] holds array_completeness + reserved + NAL_unit_type.
        let numNalus = (Int(ed[p + 1]) << 8) | Int(ed[p + 2])
        p += 3
        for _ in 0..<numNalus {
            guard p + 2 <= size else { return out }
            let nalLen = (Int(ed[p]) << 8) | Int(ed[p + 1])
            p += 2
            guard nalLen > 0, p + nalLen <= size else { return out }
            out.append([UInt8](UnsafeBufferPointer(start: ed + p, count: nalLen)))
            p += nalLen
        }
    }
    return out
}

/// Result of a `doviConvertProbe` run over a source's HEVC video stream.
public struct DoviConvertProbeResult: Sendable {
    public let packetsProcessed: Int
    public let conversions: Int
    public let failures: Int
    public let outputPath: String
    public let videoStreamFound: Bool
}

extension AetherEngine {

    // MARK: - Dovi convert probe (aetherctl dovitest)

    /// Walk every packet on a source's HEVC video stream, run
    /// `DoviRpuConverter.convertPacketToProfile81` on each, and append the
    /// (converted) NAL units to `outputPath` in Annex-B form so external
    /// tooling (`dovi_tool extract-rpu`) can validate the rewritten RPU.
    ///
    /// Annex-B conversion: each 4-byte AVCC big-endian length prefix is
    /// replaced with the start code `00 00 00 01`. The NAL unit bytes
    /// (including their 2-byte HEVC header) are written verbatim, so the
    /// emulation-prevention bytes libdovi left in place stay intact.
    ///
    /// `convertPacketToProfile81` returning `false` is counted as a
    /// failure; the original (unconverted) packet is still emitted so the
    /// output stays a valid elementary stream.
    public nonisolated static func doviConvertProbe(
        url: URL,
        outputPath: String,
        options: LoadOptions = .init()
    ) throws -> DoviConvertProbeResult {
        let demuxer = Demuxer()
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        defer { demuxer.close() }

        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else {
            return DoviConvertProbeResult(
                packetsProcessed: 0, conversions: 0, failures: 0,
                outputPath: outputPath, videoStreamFound: false
            )
        }

        // Fresh output file.
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outputPath) else {
            throw AetherEngineError.noVideoStream
        }
        defer { try? handle.close() }

        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // The MP4 demuxer keeps VPS / SPS / PPS in the stream's hvcC
        // extradata, not in-band. dovi_tool's HEVC parser needs those
        // parameter sets in the elementary stream to walk it, so emit
        // them once up front as Annex-B NALs (start code + NAL bytes).
        // This is purely a harness concern: production wiring keeps the
        // packet payloads in AVCC and lets the muxer carry the hvcC.
        if let cp = stream.pointee.codecpar,
           let ed = cp.pointee.extradata, cp.pointee.extradata_size > 0 {
            let edSize = Int(cp.pointee.extradata_size)
            for nal in parseHVCCParameterSets(ed, edSize) {
                handle.write(Data(startCode))
                handle.write(Data(nal))
            }
        }

        var packetsProcessed = 0
        var conversions = 0
        var failures = 0

        while true {
            let maybePacket: UnsafeMutablePointer<AVPacket>?
            do {
                maybePacket = try demuxer.readPacket()
            } catch {
                break
            }
            guard let packet = maybePacket else { break }  // EOF

            if packet.pointee.stream_index == videoIdx {
                packetsProcessed += 1
                let ok = DoviRpuConverter.convertPacketToProfile81(packet)
                if ok {
                    conversions += 1
                } else {
                    failures += 1
                }
                // Emit the (possibly rewritten) packet as Annex-B: replace
                // each 4-byte length prefix with a start code.
                if let data = packet.pointee.data, packet.pointee.size > 4 {
                    let size = Int(packet.pointee.size)
                    var off = 0
                    while off + 4 <= size {
                        var len = 0
                        for i in 0..<4 { len = (len << 8) | Int(data[off + i]) }
                        let nalStart = off + 4
                        if len == 0 || nalStart + len > size { break }
                        handle.write(Data(startCode))
                        handle.write(Data(bytes: data + nalStart, count: len))
                        off = nalStart + len
                    }
                }
            }

            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }

        return DoviConvertProbeResult(
            packetsProcessed: packetsProcessed,
            conversions: conversions,
            failures: failures,
            outputPath: outputPath,
            videoStreamFound: true
        )
    }
}
