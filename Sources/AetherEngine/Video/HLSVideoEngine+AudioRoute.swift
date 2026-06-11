import Foundation
import Libavformat
import Libavcodec
import Libavutil

extension HLSVideoEngine {

    /// Source audio codec routed to either fMP4 stream-copy or the
    /// FLAC bridge. Stream-copy preserves Atmos / DTS-HD metadata
    /// (EAC3-JOC stays Atmos); the bridge decodes to S16 PCM and
    /// re-encodes losslessly as FLAC so AVPlayer plays codecs that
    /// aren't legal in fMP4. See `project_audio_rework` memory for
    /// the full trade-off matrix (TrueHD-MAT Atmos loses its object
    /// metadata on the FLAC re-encode; lossless 7.1 PCM survives).
    enum AudioCodecCompat {
        // fMP4-legal: stream-copy, no decode.
        case aac, ac3, eac3, flac, alac, mp3, opus
        // Not legal in fMP4: bridge through `AudioBridge` (decode →
        // S16 PCM → FLAC encode).
        case truehd, dts
        case vorbis, pcm, mp2
        /// AAC in LATM/LOAS framing (separate codec id from ADTS AAC).
        /// The framing is what European DVB-T2 / satellite broadcasts
        /// (and IPTV restreams of them) carry, usually around an HE-AAC
        /// payload. It cannot take the ADTS stream-copy path (no ADTS
        /// headers to strip, no ASC in extradata, and the payload is
        /// typically SBR anyway), so it always bridges; the build ships
        /// the aac_latm decoder.
        case aacLatm
        case unsupported

        static func from(_ codecID: AVCodecID) -> AudioCodecCompat {
            switch codecID {
            case AV_CODEC_ID_AAC:    return .aac
            case AV_CODEC_ID_AAC_LATM: return .aacLatm
            case AV_CODEC_ID_AC3:    return .ac3
            case AV_CODEC_ID_EAC3:   return .eac3
            case AV_CODEC_ID_FLAC:   return .flac
            case AV_CODEC_ID_ALAC:   return .alac
            case AV_CODEC_ID_MP3:    return .mp3
            case AV_CODEC_ID_OPUS:   return .opus
            case AV_CODEC_ID_TRUEHD: return .truehd
            case AV_CODEC_ID_DTS:    return .dts
            case AV_CODEC_ID_VORBIS: return .vorbis
            case AV_CODEC_ID_MP2:    return .mp2
            case AV_CODEC_ID_PCM_S16LE,
                 AV_CODEC_ID_PCM_S24LE,
                 AV_CODEC_ID_PCM_F32LE,
                 AV_CODEC_ID_PCM_S16BE,
                 AV_CODEC_ID_PCM_S32LE,
                 AV_CODEC_ID_PCM_U8:
                return .pcm
            default: return .unsupported
            }
        }

        /// CODECS attribute string for the master playlist when this
        /// codec is stream-copied. Empty for codecs that always bridge
        /// (they show up as `fLaC` after the encode, computed by the
        /// engine rather than the enum).
        var hlsCodecsString: String {
            switch self {
            case .aac:    return "mp4a.40.2"
            case .ac3:    return "ac-3"
            case .eac3:   return "ec-3"
            case .flac:   return "fLaC"
            case .alac:   return "alac"
            case .mp3, .opus, .truehd, .dts, .vorbis, .pcm, .mp2, .aacLatm, .unsupported:
                // mp3 is theoretically `mp4a.40.34`, but AVPlayer reads
                // any mp4a sample entry as AAC, so we bridge it to FLAC
                // instead, the engine then computes `fLaC` from the
                // bridged stream rather than reading this enum.
                return ""
            }
        }

        /// Codecs that aren't legal in fMP4 and always have to go
        /// through `AudioBridge` for FLAC transcoding.
        ///
        /// Opus is in this set despite being fMP4-spec-legal: AVPlayer
        /// rejects `opus` inside HLS-fMP4 in practice (only the CAF
        /// container path or WebM-with-VP9-video gets Opus direct-play
        /// on Apple platforms; HLS-fMP4 segments with Opus audio fail
        /// header validation downstream). Routing Opus pre-emptively
        /// through the FLAC bridge avoids a "stream-copy header write
        /// failed, retrying with FLAC bridge" round-trip on every
        /// Opus source.
        ///
        /// MP3 is in the same bucket for the same reason: the muxer
        /// happily writes `mp4a.40.34` (MP3-in-MP4 sample entry), but
        /// AVPlayer reads any `mp4a` entry as AAC and fails to decode
        /// the MP3 frames with -11829 / CoreMedia -12848. Bridge cost
        /// on a lossy mono/stereo source is negligible.
        var requiresBridge: Bool {
            switch self {
            case .opus, .mp3, .truehd, .dts, .vorbis, .pcm, .mp2, .aacLatm: return true
            default: return false
            }
        }
    }

    /// Validate that `index` points at an audio stream in the demuxer's
    /// container. Used to gate `audioSourceStreamIndexOverride` so a
    /// stale picker selection (e.g. a stream index from a previous
    /// title) can't make `start()` filter packets nobody is producing.
    static func isAudioStream(demuxer: Demuxer, index: Int32) -> Bool {
        guard index >= 0, let stream = demuxer.stream(at: index) else {
            return false
        }
        return stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
    }

    /// Try the stream-copy → FLAC-bridge → video-only cascade for the
    /// initial producer construction. Inspired by the equivalent
    /// cascade the old per-fragment FMP4VideoMuxer ran during init
    /// capture; the failure mode it covers is the EAC3-from-MKV case
    /// where the source codecpar lacks the `dec3` extradata the mp4
    /// muxer needs to write the audio track's sample-entry. The same
    /// bytes that fed AVPlayer through stream-copy under the old
    /// architecture now fail header write here too — the fix on both
    /// sides is the same FLAC bridge fallback.
    func buildProducerWithAudioCascade(
        preferBridge: Bool,
        streamCopyAudio: HLSSegmentProducer.AudioConfig?,
        sourceAudioStreamIndex: Int32,
        sourceAudioStream: UnsafeMutablePointer<AVStream>?,
        audioHLSCodecs: inout String?
    ) throws -> HLSSegmentProducer {
        // Detect if the source is EAC3+JOC Atmos so we can flag any
        // stream-copy → FLAC-bridge fallback as an Atmos downgrade.
        // EAC3 profile=30 is the JOC marker libavformat's demuxer sets
        // on Atmos streams. If this fallback ever fires the user is
        // silently getting lossless bed-channel FLAC instead of Atmos
        // (object metadata is lost in the PCM intermediate), so we
        // want this loud in the log so it surfaces before someone
        // notices their AVR's Atmos indicator stayed off.
        let sourceIsAtmos: Bool = {
            guard let stream = sourceAudioStream else { return false }
            return stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3
                && stream.pointee.codecpar.pointee.profile == 30
        }()

        // If the source already needs the bridge (TrueHD / DTS / Vorbis
        // / PCM / MP2), skip the stream-copy attempt — we know the
        // muxer won't accept those codecs in fMP4 anyway.
        // Source-codec label used for diagnostic strings if the cascade
        // makes a decision worth surfacing. Falls back to "audio" so
        // that a missing codec entry in libavcodec (extremely rare,
        // mostly out-of-band-extension exotica) doesn't produce
        // "Stream-copy (nil)" in the UI.
        let sourceCodecLabel: String = {
            if let stream = sourceAudioStream,
               let cstr = avcodec_get_name(stream.pointee.codecpar.pointee.codec_id) {
                return String(cString: cstr).uppercased()
            }
            return "audio"
        }()

        if !preferBridge, let cfg = streamCopyAudio, let vcfg = savedVideoConfig {
            // Pre-flight the mp4 muxer's write_header to detect cases
            // the cascade would otherwise miss. makeProducer no longer
            // exercises avformat_write_header itself — the first muxer
            // alloc happens lazily inside the producer's pump on the
            // first keep-packet, well after this scope has returned.
            // Without the probe a failure there (typical case:
            // EAC3-from-MKV whose CodecPrivate lacks the dec3 extradata
            // the mov muxer needs to write the audio track's
            // sample-entry, returns -22 / "Cannot write moov atom
            // before EAC3 packets parsed") leaves the producer stuck
            // and the bridge fallback below never fires.
            let probeVideo = MP4SegmentMuxer.VideoConfig(
                codecpar: vcfg.codecpar,
                timeBase: vcfg.timeBase,
                codecTagOverride: vcfg.codecTagOverride,
                stripDolbyVisionMetadata: vcfg.stripDolbyVisionMetadata,
                colorOverride: vcfg.colorOverride,
                extradataOverride: vcfg.extradataOverride
            )
            let probeAudio = MP4SegmentMuxer.AudioConfig(
                codecpar: cfg.codecpar,
                timeBase: cfg.timeBase
            )
            let probeRet = MP4SegmentMuxer.probeWriteHeader(
                video: probeVideo,
                audio: probeAudio
            )
            if probeRet < 0 {
                if sourceIsAtmos {
                    EngineLog.emit(
                        "[HLSVideoEngine] WARNING: Atmos downgrade — EAC3+JOC stream-copy probe rejected by mp4 muxer (ret=\(probeRet)). "
                        + "Falling back to FLAC bridge: bed channels stay lossless, but object metadata is lost. "
                        + "Source: \(sourceAudioStream?.pointee.codecpar.pointee.profile.description ?? "?") profile, "
                        + "channels=\(sourceAudioStream?.pointee.codecpar.pointee.ch_layout.nb_channels ?? -1). "
                        + "If you see this in production, capture the source MKV — dec3 extradata reconstruction can recover Atmos.",
                        category: .session
                    )
                } else {
                    EngineLog.emit(
                        "[HLSVideoEngine] audio stream-copy probe failed (ret=\(probeRet)), retrying with FLAC bridge",
                        category: .session
                    )
                }
                // Fall through to bridge attempt.
            } else {
                self.savedAudioConfig = cfg
                do {
                    let prod = try makeProducer(baseIndex: 0)
                    if sourceIsAtmos {
                        EngineLog.emit(
                            "[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged, MAT 2.0 passthrough intact",
                            category: .session
                        )
                    }
                    self.audioPipelineDescription = sourceIsAtmos
                        ? "Stream-copy (EAC3+JOC Atmos)"
                        : "Stream-copy (\(sourceCodecLabel))"
                    return prod
                } catch {
                    EngineLog.emit(
                        "[HLSVideoEngine] makeProducer failed after stream-copy probe succeeded (\(error)), retrying with FLAC bridge",
                        category: .session
                    )
                    // Fall through to bridge attempt.
                }
            }
        } else if preferBridge && sourceIsAtmos && Self.currentRouteSupportsAtmosPassthrough() {
            // Caller pre-decided bridge before reaching here. For Atmos
            // that's wrong UNLESS the route can't carry Atmos at all
            // (Bluetooth A2DP / LE), in which case the cascade setup
            // intentionally forced the bridge and already logged a
            // route-specific message. The remaining case — pre-bridge
            // on an Atmos-capable route — would silently degrade
            // Atmos, so diagnose it explicitly.
            EngineLog.emit(
                "[HLSVideoEngine] WARNING: Atmos source pre-routed to FLAC bridge without stream-copy attempt — Atmos lost. Investigate the codec compatibility table.",
                category: .session
            )
        }

        // FLAC bridge attempt. Requires a source audio stream.
        if let audioStream = sourceAudioStream, sourceAudioStreamIndex >= 0 {
            do {
                let bridge = try AudioBridge(
                    srcCodecpar: audioStream.pointee.codecpar,
                    srcTimeBase: audioStream.pointee.time_base,
                    mode: audioBridgeMode
                )
                if let cp = bridge.encoderCodecpar {
                    let cfg = HLSSegmentProducer.AudioConfig(
                        codecpar: cp,
                        timeBase: bridge.encoderTimeBase,
                        sourceStreamIndex: sourceAudioStreamIndex,
                        inputTimeBase: bridge.encoderTimeBase,
                        sourceTimeBase: audioStream.pointee.time_base,
                        bridge: bridge
                    )
                    self.savedAudioConfig = cfg
                    self.audioBridge = bridge
                    do {
                        let prod = try makeProducer(baseIndex: 0)
                        let (hlsCodec, pipelineLabel): (String, String)
                        switch audioBridgeMode {
                        case .surroundCompat:
                            hlsCodec = "ec-3"
                            pipelineLabel = "EAC3 5.1 bridge ← \(sourceCodecLabel)"
                        case .lossless:
                            hlsCodec = "fLaC"
                            pipelineLabel = "FLAC bridge ← \(sourceCodecLabel)"
                        }
                        audioHLSCodecs = hlsCodec
                        self.audioPipelineDescription = pipelineLabel
                        return prod
                    } catch {
                        EngineLog.emit(
                            "[HLSVideoEngine] \(audioBridgeMode.rawValue) bridge header write failed (\(error)), falling back to video-only",
                            category: .session
                        )
                        self.savedAudioConfig = nil
                        self.audioBridge = nil
                        bridge.close()
                    }
                }
            } catch {
                EngineLog.emit(
                    "[HLSVideoEngine] AudioBridge init failed (\(error)), falling back to video-only",
                    category: .session
                )
            }
        }

        // Video-only fallback.
        self.savedAudioConfig = nil
        self.audioBridge = nil
        audioHLSCodecs = nil
        self.audioPipelineDescription = nil
        return try makeProducer(baseIndex: 0)
    }
}
