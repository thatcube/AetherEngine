import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Bounds (and optional track override) for `AetherEngine.probeDetectingAtmos`'s bounded EAC3/JOC decode pass.
///
/// This is entirely separate from `LoadOptions` / the lightweight `probe(url:)` path: it exists so a host can
/// opt into a strictly more expensive, decode-based Atmos check without ever touching the default probe's
/// behavior or performance. See `AetherEngine.probeDetectingAtmos` for the full contract.
public struct AtmosDetectionOptions: Sendable, Equatable {
    /// Explicit AVStream index (== `TrackInfo.id`) to test. `nil` resolves the demuxer's own default audio
    /// pick (`Demuxer.audioStreamIndex`), the same stream `probe(url:)` already reports via its container
    /// default. Set this when a host is badging a NON-default track the user explicitly selected (e.g. via
    /// `AetherEngine.selectAudioIndex`), so the decode targets the track that will actually play.
    public var targetTrackID: Int?

    /// Stop after this many demuxed packets even if none decode. Bounds a malformed / truncated / silent
    /// stream to a fixed amount of work. Default 64: generous for E-AC-3 (~1536-sample frames per packet at
    /// typical container interleave -- a real track decodes its first frame within the first handful of
    /// packets), while still finite on an adversarial or empty-audio source.
    public var maxPackets: Int

    /// Stop after this many cumulative packet bytes, independent of packet count. Guards a stream with
    /// abnormally large packets from exhausting the `maxPackets` budget slowly. Default 8 MiB.
    public var maxBytes: Int64

    /// Soft wall-clock budget checked BETWEEN packet reads. This is NOT preemptive: a single blocking
    /// `av_read_frame()` call (e.g. a stalled remote socket) can still run past it before the next check
    /// fires -- the same AVIO-layer-only limitation `Demuxer.seekBounded` already documents for its deadline.
    /// Default 2 seconds.
    public var timeBudget: TimeInterval

    public init(
        targetTrackID: Int? = nil,
        maxPackets: Int = 64,
        maxBytes: Int64 = 8 * 1024 * 1024,
        timeBudget: TimeInterval = 2.0
    ) {
        self.targetTrackID = targetTrackID
        self.maxPackets = maxPackets
        self.maxBytes = maxBytes
        self.timeBudget = timeBudget
    }
}

/// Result of the bounded EAC3/JOC decode attempt run by `AetherEngine.detectAtmos`. Internal: hosts consume
/// the enriched `SourceProbe.audioTracks` from `probeDetectingAtmos` instead of this directly; it is exposed
/// at module-internal visibility purely so the stop-condition / authority logic is unit-testable without a
/// real decode (`@testable import AetherEngine`).
struct AtmosDetectionOutcome: Sendable, Equatable {
    enum StopReason: Sendable, Equatable {
        /// No audio stream at `targetIndex` (out of range, or the source has no audio at all).
        case noAudioTrack
        /// The target track's `codec_id` is not `AV_CODEC_ID_EAC3`. Per spec, only EAC3 JOC is ever Atmos --
        /// no other codec is decoded or inferred.
        case notEAC3
        /// `avcodec_find_decoder` / `avcodec_open2` failed (no EAC3 decoder built, or bad extradata).
        case decoderOpenFailed
        /// A frame was successfully decoded; `decodedProfile` reflects the post-decode `AVCodecContext.profile`.
        case frameDecoded
        /// `maxPackets` demuxed packets were read without ever decoding a frame for the target stream.
        case packetCap
        /// `maxBytes` cumulative packet bytes were read without ever decoding a frame.
        case byteCap
        /// `timeBudget` elapsed (checked between reads) without ever decoding a frame.
        case timeCap
        /// The demuxer reached EOF before a frame decoded (very short / audio-less-from-here source).
        case demuxEOF
        /// `Demuxer.readPacket()` threw (this is tolerated, never rethrown -- see `probeDetectingAtmos` doc).
        case demuxError
    }

    let stopReason: StopReason
    let packetsRead: Int
    let bytesRead: Int64
    /// Post-decode `AVCodecContext.profile`. Only meaningful when `stopReason == .frameDecoded`.
    let decodedProfile: Int32?

    /// EAC3 profile 30 (FFmpeg's `AV_PROFILE_EAC3_DDP_ATMOS`, `defs.h`) observed on the FIRST successfully
    /// decoded frame. This is the ONLY authoritative signal the whole feature produces -- everything else on
    /// this type is diagnostic. A plain (non-JOC) EAC3 track that decodes cleanly reports `frameDecoded` with
    /// a `decodedProfile` other than 30, so `confirmedAtmos` is correctly `false`.
    var confirmedAtmos: Bool {
        stopReason == .frameDecoded && decodedProfile == AtmosDetectionOutcome.eac3JOCProfile
    }

    /// EAC3 profile 30 = Dolby Digital Plus JOC (Atmos). Mirrors FFmpeg's `AV_PROFILE_EAC3_DDP_ATMOS` macro
    /// (`defs.h`) as a literal: simple `#define` integer constants are not guaranteed to bridge into Swift,
    /// and `Demuxer.trackInfo`'s existing pre-decode check already hardcodes this same literal.
    static let eac3JOCProfile: Int32 = 30
}

extension AetherEngine {

    /// Pure stop-condition check for the bounded decode loop: given how much work has been done, which cap
    /// (if any) has been hit. Extracted so the cap-selection PRIORITY (packets, then bytes, then time) is
    /// unit-testable without a real demuxer/decoder. Returns `nil` while still within all three budgets.
    nonisolated static func atmosDecodeCapReached(
        packetsRead: Int,
        bytesRead: Int64,
        elapsed: TimeInterval,
        options: AtmosDetectionOptions
    ) -> AtmosDetectionOutcome.StopReason? {
        if packetsRead >= options.maxPackets { return .packetCap }
        if bytesRead >= options.maxBytes { return .byteCap }
        if elapsed >= options.timeBudget { return .timeCap }
        return nil
    }

    /// Resolve which AVStream index the decode pass should target: an explicit `targetTrackID` always wins
    /// (even if it does not (yet) name a real stream -- the caller finds out via `.noAudioTrack`); otherwise
    /// the demuxer's own default audio pick. Pure so the override-vs-default precedence is unit-testable.
    nonisolated static func atmosDecodeTargetIndex(options: AtmosDetectionOptions, defaultAudioStreamIndex: Int32) -> Int32 {
        if let explicit = options.targetTrackID {
            return Int32(explicit)
        }
        return defaultAudioStreamIndex
    }

    /// Bounded EAC3/JOC decode attempt. Opens ONE audio decoder for `targetIndex`, reads packets from
    /// `demuxer` (skipping any not addressed to that stream), and stops at the first successfully decoded
    /// frame or whichever cap in `options` is hit first. No video decode, no HLS server, no playback. The
    /// decoder context, `AVPacket`, and `AVFrame` are all freed before returning on every path, including
    /// early-outs and thrown-away errors -- this never leaves FFmpeg resources alive past the call.
    ///
    /// Tolerates a malformed / no-audio / non-EAC3 source: each of those degrades to a distinct
    /// non-`frameDecoded` `stopReason` rather than throwing or hanging. `Demuxer.readPacket()` failures are
    /// caught and folded into `.demuxError`, never rethrown -- an unreadable stream simply fails to confirm
    /// Atmos instead of failing the whole probe.
    nonisolated static func detectAtmos(
        demuxer: Demuxer,
        targetIndex: Int32,
        options: AtmosDetectionOptions
    ) -> AtmosDetectionOutcome {
        guard targetIndex >= 0, let stream = demuxer.stream(at: targetIndex) else {
            return AtmosDetectionOutcome(stopReason: .noAudioTrack, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }
        guard let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
            return AtmosDetectionOutcome(stopReason: .noAudioTrack, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }
        // Only EAC3 ever carries JOC. Every other codec (including plain AC-3/TrueHD/DTS) is left untouched --
        // never inferred, never decoded on this path.
        guard codecpar.pointee.codec_id == AV_CODEC_ID_EAC3 else {
            return AtmosDetectionOutcome(stopReason: .notEAC3, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }

        guard let codec = avcodec_find_decoder(AV_CODEC_ID_EAC3),
              let ctx = avcodec_alloc_context3(codec) else {
            return AtmosDetectionOutcome(stopReason: .decoderOpenFailed, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }
        var mutableCtx: UnsafeMutablePointer<AVCodecContext>? = ctx
        defer { avcodec_free_context(&mutableCtx) }

        guard avcodec_parameters_to_context(ctx, codecpar) >= 0,
              avcodec_open2(ctx, codec, nil) >= 0 else {
            return AtmosDetectionOutcome(stopReason: .decoderOpenFailed, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let f = frame else {
            return AtmosDetectionOutcome(stopReason: .decoderOpenFailed, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
        }

        let start = Date()
        var packetsRead = 0
        var bytesRead: Int64 = 0

        while true {
            if let cap = Self.atmosDecodeCapReached(
                packetsRead: packetsRead, bytesRead: bytesRead,
                elapsed: Date().timeIntervalSince(start), options: options
            ) {
                return AtmosDetectionOutcome(stopReason: cap, packetsRead: packetsRead, bytesRead: bytesRead, decodedProfile: nil)
            }

            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                return AtmosDetectionOutcome(stopReason: .demuxError, packetsRead: packetsRead, bytesRead: bytesRead, decodedProfile: nil)
            }
            guard let pkt = packet else {
                return AtmosDetectionOutcome(stopReason: .demuxEOF, packetsRead: packetsRead, bytesRead: bytesRead, decodedProfile: nil)
            }

            packetsRead += 1
            bytesRead += Int64(pkt.pointee.size)

            var decodedThisPacket = false
            if pkt.pointee.stream_index == targetIndex {
                let sendRet = avcodec_send_packet(ctx, pkt)
                if sendRet >= 0, avcodec_receive_frame(ctx, f) >= 0 {
                    decodedThisPacket = true
                }
            }
            av_packet_unref(pkt)
            av_packet_free_safe(pkt)

            if decodedThisPacket {
                return AtmosDetectionOutcome(
                    stopReason: .frameDecoded, packetsRead: packetsRead, bytesRead: bytesRead,
                    decodedProfile: ctx.pointee.profile
                )
            }
        }
    }
}
