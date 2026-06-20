import Foundation
import Libavcodec
import Libavutil

extension HLSVideoEngine {

    /// DV profile + base-layer compatibility classification per the
    /// table in DrHurt's KSPlayer notes (AetherEngine#1), Apple's HLS
    /// Authoring Spec, and Dolby's ETSI TS 103 572. HEVC profiles
    /// 5 / 8 carry HEVC streams; profile 10 carries AV1 streams.
    enum DVVariant {
        case none              // not DV
        case profile5          // HEVC P5  (IPT-PQ-c2, no base)     → dvh1 + PQ
        case profile81         // HEVC P8.1 with HDR10-compat base  → dvh1 + PQ  (on DV display)
        case profile84         // HEVC P8.4 with HLG-compat base    → hvc1 + HLG + SUPPLEMENTAL dvh1/db4h
        case profile7          // HEVC P7 dual-layer (BL = HDR10)   → hvc1 + PQ (BL only)
        case profile82         // HEVC P8.2 with SDR-compat base    → play Rec.709 base as plain hvc1
        case av1Profile10      // AV1 P10.0 (no base)               → dav1 + PQ
        case av1Profile101     // AV1 P10.1 with HDR10-compat base  → dav1 + PQ
        case av1Profile104     // AV1 P10.4 with HLG-compat base    → av01 + HLG + SUPPLEMENTAL dav1
        case av1Profile102     // AV1 P10.2 with SDR-compat base    → play Rec.709 base as plain av01
        case unknown           // anything else                     → reject
    }

    // MARK: - DV / HDR detection

    private func doviConfigRecord(
        from codecpar: UnsafePointer<AVCodecParameters>
    ) -> AVDOVIDecoderConfigurationRecord? {
        let count = Int(codecpar.pointee.nb_coded_side_data)
        guard count > 0, let sideData = codecpar.pointee.coded_side_data else {
            return nil
        }
        for i in 0..<count {
            let item = sideData.advanced(by: i).pointee
            guard item.type == AV_PKT_DATA_DOVI_CONF else { continue }
            guard let raw = item.data, item.size >= 8 else { continue }
            return raw.withMemoryRebound(
                to: AVDOVIDecoderConfigurationRecord.self,
                capacity: 1
            ) { $0.pointee }
        }
        return nil
    }

    private func isHDRTransfer(_ codecpar: UnsafePointer<AVCodecParameters>) -> Bool {
        ColorAttachments.isHDRTransfer(codecpar.pointee.color_trc)
    }

    private func classifyDVVariant(
        _ record: AVDOVIDecoderConfigurationRecord?,
        codecID: AVCodecID
    ) -> DVVariant {
        guard let r = record else { return .none }
        let profile = Int(r.dv_profile)
        let compat = Int(r.dv_bl_signal_compatibility_id)

        // HEVC + DV: profiles 5, 7, 8 per Dolby's ETSI TS 103 572.
        // Profile 9 is AVC+DV which AetherEngine doesn't support
        // (AVPlayer accepts AVC but not AVC+DV per DrHurt's matrix).
        if codecID == AV_CODEC_ID_HEVC {
            if profile == 5 { return .profile5 }
            if profile == 7 { return .profile7 }
            if profile == 8 {
                switch compat {
                case 1: return .profile81
                case 2: return .profile82
                case 4: return .profile84
                default: return .profile81  // P8.6 etc → treat as P8.1
                }
            }
            return .unknown
        }

        // AV1 + DV: profile 10 per Dolby's spec. compat == 0 means
        // P10.0 (no base layer); compat == 1 / 2 / 4 mirror P8's HDR10
        // / SDR / HLG base-layer compatibility flags.
        if codecID == AV_CODEC_ID_AV1 {
            if profile == 10 {
                switch compat {
                case 0: return .av1Profile10
                case 1: return .av1Profile101
                case 2: return .av1Profile102
                case 4: return .av1Profile104
                default: return .av1Profile10
                }
            }
            return .unknown
        }

        return .unknown
    }

    /// Output of codec dispatch for the source's video stream — the full
    /// set of decisions that `start()` makes about how to expose the
    /// video track to AVPlayer. Computed once at start() and consumed by
    /// the producer (codec tag override) + the playlist builder (CODECS
    /// / SUPPLEMENTAL-CODECS / VIDEO-RANGE).
    struct CodecRoute {
        /// `codec_tag` for the mp4 muxer's sample entry FourCC: `avc1`,
        /// `hvc1`, `dvh1`, `av01`, or `dav1`. Optional to match the
        /// producer's `StreamConfig` API (which allows `nil` for muxer
        /// default), but in practice always set by this dispatch.
        let codecTagOverride: String?
        let videoRange: HLSVideoRange
        let primaryCodecs: String
        let supplementalCodecs: String?
        /// Drop the source's `dvcC` configuration record before
        /// `avformat_write_header` writes the sample entry. Used for
        /// HEVC P7 (BL routed as plain HDR10, VT rejects dvcC with
        /// -12906) and for HEVC P8.1 / P8.4 on non-DV panels (tvOS 26
        /// master-level codec filter rejects dvvC + plain hvc1 with
        /// -11868). Mutually exclusive with `rewriteDoviConfigTo81`.
        let stripDolbyVisionMetadata: Bool
        /// Convert every video packet's RPU from P7 to 8.1 in place via
        /// `DoviRpuConverter`. True only for HEVC P7 on a DV-capable
        /// panel; false on all other routes (including P7 on a non-DV
        /// panel, which strips instead). Drives only the per-packet work;
        /// the matching container `dvcC` rewrite rides on
        /// `rewriteDoviConfigTo81`.
        let convertP7ToProfile81: Bool
        /// Rewrite the container `dvcC` record to a valid P8.1 in the
        /// muxer's init.mp4 (no packet rewrite implied). True for two
        /// DV-capable-panel routes: HEVC P7 (alongside
        /// `convertP7ToProfile81`) and the malformed "P8.6" case, where
        /// the bitstream is already a single-layer HDR10-base P8 stream
        /// but the source `dvcC` carries an invalid compat id that
        /// AVPlayer rejects. Mutually exclusive with
        /// `stripDolbyVisionMetadata`.
        let rewriteDoviConfigTo81: Bool
        let dvVariant: DVVariant

        init(
            codecTagOverride: String?,
            videoRange: HLSVideoRange,
            primaryCodecs: String,
            supplementalCodecs: String?,
            stripDolbyVisionMetadata: Bool,
            convertP7ToProfile81: Bool,
            rewriteDoviConfigTo81: Bool = false,
            dvVariant: DVVariant
        ) {
            self.codecTagOverride = codecTagOverride
            self.videoRange = videoRange
            self.primaryCodecs = primaryCodecs
            self.supplementalCodecs = supplementalCodecs
            self.stripDolbyVisionMetadata = stripDolbyVisionMetadata
            self.convertP7ToProfile81 = convertP7ToProfile81
            self.rewriteDoviConfigTo81 = rewriteDoviConfigTo81
            self.dvVariant = dvVariant
        }
    }

    /// Classify the source video's codec + DV profile and decide the
    /// sample-entry / CODECS / SUPPLEMENTAL-CODECS combination AVPlayer
    /// will see. Per-profile policy:
    ///
    ///   - H.264 → `avc1.<profile><level>` derived from codecpar.
    ///   - AV1 → `av01.*` for plain AV1 / HLG; `dav1.10.*` for DV P10.x.
    ///   - HEVC P5 → always `dvh1.05.<level>` + `dvcC`, regardless of
    ///     panel capability. AVPlayer's system DV decoder converts
    ///     IPT-PQ-c2 to YCbCr and auto-tonemaps to the panel's mode.
    ///   - HEVC P8.1 → `dvh1.08.<level>` on DV-capable display, plain
    ///     `hvc1.2.4.L<level>` downgrade on non-DV display (HDR10 base
    ///     layer plays as plain HEVC HDR10).
    ///   - HEVC P8.4 → `hvc1.2.4.L<level>` + SUPPLEMENTAL `dvh1.08.<level>
    ///     /db4h` on every panel; the cross-player-compat form because
    ///     P8.4's base is HLG-HEVC.
    ///   - HEVC P7 → plain `hvc1.2.4.L<level>` HDR10, strip dvcC (no P7
    ///     decoder on any Apple TV chip).
    ///   - HEVC P8.2 / AV1 P10.2 → SDR-compat base, no Apple DV decode
    ///     path and the SDR base can't be repackaged to a DV profile, so
    ///     play the Rec.709 base as plain `hvc1` / `av01` (strip DV).
    ///   - H.264 P9 (AVC+DV) → plain `avc1`, strip DV (no AVC+DV decoder).
    ///   - HEVC plain → `hvc1.2.4.L<level>`, range derived from transfer.
    ///
    /// Pre-condition: caller has validated `codecpar.codec_id` is one of
    /// HEVC / H.264 / AV1 (with HW decode for AV1). Every recognized DV
    /// profile now plays (DV-capable ones as DV, the SDR-base ones P8.2 /
    /// P10.2 / P9 as their stripped Rec.709 base). The dispatch only
    /// throws `unsupportedDVProfile` for genuinely unknown DV variants,
    /// where we can't assume the base layer is independently decodable.
    /// Manifest VIDEO-RANGE for a source transfer characteristic.
    /// PQ and HLG are distinct manifest values; mapping HLG onto PQ made
    /// the panel negotiate the wrong EOTF for HLG broadcasts (the AV1
    /// route already distinguished them, the H.264 and plain-HEVC routes
    /// did not).
    private func manifestVideoRange(_ codecpar: UnsafePointer<AVCodecParameters>) -> HLSVideoRange {
        switch codecpar.pointee.color_trc {
        case AVCOL_TRC_SMPTE2084:    return .pq
        case AVCOL_TRC_ARIB_STD_B67: return .hlg
        default:                     return .sdr
        }
    }

    func resolveCodecRoute(
        codecpar: UnsafePointer<AVCodecParameters>
    ) throws -> CodecRoute {
        let codecID = codecpar.pointee.codec_id

        if codecID == AV_CODEC_ID_H264 {
            let profileIDC = Int(codecpar.pointee.profile)
            let levelIDC = Int(codecpar.pointee.level)
            let safeProfile = profileIDC > 0 ? profileIDC : 100  // High
            let safeLevel = levelIDC > 0 ? levelIDC : 40         // 4.0
            // AVC + DV (Profile 9, dvav.09) has no decoder on any Apple
            // device: AVPlayer accepts AVC but not AVC+DV (DrHurt's
            // matrix). The base layer is an ordinary Rec.709 SDR AVC
            // stream, so play it as plain `avc1` and STRIP the DV config.
            // Without the strip the mov muxer writes a `dvvC` box onto the
            // avc1 sample entry (strict=-2) and tvOS 26's codec filter
            // rejects it (cf. the P8.1/P8.4 non-DV strip path). The RPU
            // NALs ride along ignored, exactly like P7's enhancement layer.
            let hasDV = doviConfigRecord(from: codecpar) != nil
            if hasDV {
                EngineLog.emit(
                    "[HLSVideoEngine] AVC+DV (Profile 9) detected; "
                    + "no Apple AVC+DV decoder, playing Rec.709 base as "
                    + "plain avc1 (DV config stripped)",
                    category: .session
                )
            }
            return CodecRoute(
                codecTagOverride: "avc1",
                videoRange: manifestVideoRange(codecpar),
                primaryCodecs: String(format: "avc1.%02X%02X%02X", safeProfile, 0, safeLevel),
                supplementalCodecs: nil,
                stripDolbyVisionMetadata: hasDV,
                convertP7ToProfile81: false,
                dvVariant: .none
            )
        }

        if codecID == AV_CODEC_ID_AV1 {
            // AV1 path. When dvModeAvailable is false (device can't do
            // DV at all), we deliberately skip the DV side-data probe
            // so classify returns .none → plain AV1 codec string.
            // When dvModeAvailable is true and the source carries
            // Dolby Vision RPU, classify resolves to one of the
            // av1Profile10x variants and we emit the matching `dav1`
            // codec tag + Apple HLS Authoring Spec CODECS string.
            let dvRecord = effectiveDvMode ? doviConfigRecord(from: codecpar) : nil
            let dvVariant = classifyDVVariant(dvRecord, codecID: AV_CODEC_ID_AV1)

            // AV1 codec-string fields (per Apple HLS Authoring Spec +
            // AV1 codec-string IETF draft):
            //
            //   av01.<profile>.<level><tier>.<bitDepth>.
            //        <monochrome>.<chromaSubX><chromaSubY><chromaPos>.
            //        <colorPrim>.<transfer>.<matrix>.<videoFullRange>
            //
            // Profile 0 (Main) is the dominant case in the wild —
            // higher profiles cover 4:2:2 / 4:4:4 / 12-bit which Apple
            // doesn't accept in HLS-fMP4 today, but dav1d decodes them
            // so we let the muxer try; FFmpeg writes the `av1C` box
            // automatically from the codecpar.
            let av1ProfileRaw = Int(codecpar.pointee.profile)
            let av1Profile = (av1ProfileRaw >= 0 && av1ProfileRaw <= 2) ? av1ProfileRaw : 0
            let av1LevelRaw = Int(codecpar.pointee.level)
            // FFmpeg's seq_level_idx encoding: 0..23 → AV1 levels 2.0..7.3.
            // Default to 8 (= level 4.0) when the source doesn't expose
            // a value, matching ~4K @ 30fps.
            let av1Level = (av1LevelRaw >= 0 && av1LevelRaw <= 23) ? av1LevelRaw : 8
            let bitDepthRaw = Int(codecpar.pointee.bits_per_raw_sample)
            let dvLevelRaw = Int(dvRecord?.dv_level ?? 0)
            let dvLevel = dvLevelRaw > 0 ? dvLevelRaw : 6
            let dvLevelStr = String(format: "%02d", dvLevel)

            switch dvVariant {
            case .av1Profile10:
                // P10.0: DV-only, no HDR10 / HLG base layer. AVPlayer
                // refuses the asset on non-DV displays per Apple's
                // spec for `dav1` track type. Same shape as HEVC P5.
                return CodecRoute(
                    codecTagOverride: "dav1",
                    videoRange: .pq,
                    primaryCodecs: "dav1.10.\(dvLevelStr)",
                    supplementalCodecs: nil,
                    stripDolbyVisionMetadata: false,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            case .av1Profile101:
                // P10.1: HDR10-compat base layer. Same `dav1` codec
                // tag — the HDR10 fallback is implicit in the
                // bitstream and the decoder picks it up when DV isn't
                // available. Analogous to HEVC P8.1.
                return CodecRoute(
                    codecTagOverride: "dav1",
                    videoRange: .pq,
                    primaryCodecs: "dav1.10.\(dvLevelStr)",
                    supplementalCodecs: nil,
                    stripDolbyVisionMetadata: false,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            case .av1Profile104:
                // P10.4: HLG-compat base. Plain `av01` codec tag so
                // non-DV hosts present the HLG base layer; DV signaled
                // via the supplemental codecs string. Analogous to
                // HEVC P8.4 ↔ hvc1.2.4.LXX.b0 + dvh1.08.LL/db4h.
                let bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                let primary = String(
                    format: "av01.%d.%02dM.%02d.0.111.09.18.09.0",
                    av1Profile, av1Level, bd
                )
                return CodecRoute(
                    codecTagOverride: "av01",
                    videoRange: .hlg,
                    primaryCodecs: primary,
                    supplementalCodecs: "dav1.10.\(dvLevelStr)/db4h",
                    stripDolbyVisionMetadata: false,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            case .unknown:
                let p = Int(dvRecord?.dv_profile ?? 0)
                let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
                throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
            case .none, .av1Profile102:
                // Plain AV1 (no DV) OR P10.2 (SDR-compat base). P10.2's
                // base is an ordinary Rec.709 SDR AV1 stream; no Apple
                // device decodes P10.2 as DV, and the SDR base can't be
                // repackaged to a DV-capable profile (the pixels are SDR,
                // not PQ). Both play the AV1 base; P10.2 additionally
                // strips its DV config so the muxer writes a clean `av01`
                // sample entry with no `dav1`/DV signaling. Pick color
                // signaling per the source's transfer characteristic so
                // AVPlayer hands the right colorspace to the display.
                if dvVariant == .av1Profile102 {
                    EngineLog.emit(
                        "[HLSVideoEngine] AV1 DV Profile 10.2 (SDR base) "
                        + "detected; not DV-routable, playing Rec.709 base "
                        + "as plain av01 (DV config stripped)",
                        category: .session
                    )
                }
                let trc = codecpar.pointee.color_trc
                let videoRange: HLSVideoRange
                let cp: Int, tc: Int, mc: Int, bd: Int
                if trc == AVCOL_TRC_ARIB_STD_B67 {
                    videoRange = .hlg; cp = 9; tc = 18; mc = 9
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                } else if trc == AVCOL_TRC_SMPTE2084 {
                    videoRange = .pq; cp = 9; tc = 16; mc = 9
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                } else {
                    videoRange = .sdr; cp = 1; tc = 1; mc = 1
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 8
                }
                let primary = String(
                    format: "av01.%d.%02dM.%02d.0.111.%02d.%02d.%02d.0",
                    av1Profile, av1Level, bd, cp, tc, mc
                )
                return CodecRoute(
                    codecTagOverride: "av01",
                    videoRange: videoRange,
                    primaryCodecs: primary,
                    supplementalCodecs: nil,
                    stripDolbyVisionMetadata: dvVariant == .av1Profile102,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            // HEVC DV variants can't reach this switch (classifyDVVariant
            // is called with AV_CODEC_ID_AV1) but Swift's exhaustivity
            // check needs explicit handling.
            case .profile5, .profile81, .profile84, .profile7, .profile82:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: -1, compatID: -1)
            }
        }

        // HEVC path (DV or plain). Always classify the DV variant
        // so DV5 can emit a `dvh1` sample entry + `dvcC` box even
        // on a panel that won't engage DV mode at the HDMI
        // handshake. AVPlayer has a system-level DV decoder on
        // every tvOS 14+ device; it engages on the `dvh1` sample
        // entry regardless of panel state, converts the IPT-PQ-c2
        // elementary stream to a standard YCbCr colorspace, and
        // auto-tonemaps to whatever the panel can accept (HDR10 on
        // an HDR10-only TV, SDR on an SDR-locked panel). Without
        // the `dvh1` sample entry, the HEVC bitstream's IPT chroma
        // gets interpreted as YCbCr+BT.2020+PQ, producing the
        // green/purple cast DrHurt reported on AetherEngine#4
        // Build 160 + 163. Per DrHurt's #19 manual remux test,
        // `dvh1` sample entry + media playlist routing plays DV5
        // correctly on every panel mode. The routing branch below
        // forces media playlist for the DV5-on-non-DV-panel case.
        let dvRecord = doviConfigRecord(from: codecpar)
        let dvVariant = classifyDVVariant(dvRecord, codecID: AV_CODEC_ID_HEVC)

        // Dump the raw DV side data fields so a remote tester can
        // photograph the diagnostic overlay and confirm what the
        // demuxer surfaced for this source. Three fields drive
        // every downstream routing decision: dv_profile (5/7/8),
        // dv_bl_signal_compatibility_id (0/1/4 for no-base / HDR10
        // / HLG), and dv_level (1-13, content frame-rate × HDR
        // overhead). Pair with the source codecpar color fields
        // so the AVPlayer-side color interpretation can be cross-
        // checked against what FFmpeg parsed from the HEVC VUI.
        if let r = dvRecord {
            let cp = Int(codecpar.pointee.color_primaries.rawValue)
            let trc = Int(codecpar.pointee.color_trc.rawValue)
            let csp = Int(codecpar.pointee.color_space.rawValue)
            EngineLog.emit(
                "[HLSVideoEngine] DV source: profile=\(r.dv_profile) "
                + "compat=\(r.dv_bl_signal_compatibility_id) "
                + "level=\(r.dv_level) rpu=\(r.rpu_present_flag) "
                + "el=\(r.el_present_flag) bl=\(r.bl_present_flag) "
                + "color_primaries=\(cp) color_trc=\(trc) color_space=\(csp)",
                category: .session
            )
        }

        let dvLevelRaw = Int(dvRecord?.dv_level ?? 0)
        let dvLevel = dvLevelRaw > 0 ? dvLevelRaw : 6
        let hevcLevelRaw = Int(codecpar.pointee.level)
        let hevcLevel = hevcLevelRaw > 0 ? hevcLevelRaw : 150
        let dvLevelStr = String(format: "%02d", dvLevel)

        switch dvVariant {
        case .profile5:
            // P5 has no HDR10 base layer (IPT-PQ-c2 elementary
            // stream only). `dvh1` sample entry + `dvcC` box is
            // the only legal packaging. Emitted regardless of
            // `effectiveDvMode` because AVPlayer's DV decoder
            // engages on the sample entry independent of panel
            // state and tonemaps internally; without `dvh1` the
            // IPT chroma is misinterpreted as YCbCr (green/purple
            // cast). Master playlist with bare `dvh1.05` CODECS
            // is rejected by tvOS 26's master-level codec filter
            // on non-DV panels (-11868), so the routing logic
            // forces media playlist when the panel can't engage
            // DV/HDR mode.
            return CodecRoute(
                codecTagOverride: "dvh1",
                videoRange: .pq,
                primaryCodecs: "dvh1.05.\(dvLevelStr)",
                supplementalCodecs: nil,
                stripDolbyVisionMetadata: false,
                convertP7ToProfile81: false,
                dvVariant: dvVariant
            )
        case .profile81:
            // P8.1 (HDR10-compat base layer). Two branches based on
            // display capability:
            //
            // DV-capable panel (`effectiveDvMode == true`): emit
            // Apple's HLS Authoring Spec post-WWDC22 signaling for
            // backward-compatible DV: `hvc1` sample entry + `hvcC`
            // + `dvvC` boxes (the mp4 muxer with `strict=-2` writes
            // dvvC automatically when DV side data is preserved on
            // the codecpar), primary CODECS `hvc1.2.4.LXX`,
            // SUPPLEMENTAL-CODECS `dvh1.08.XX/db1p`. The `/db1p`
            // brand identifier marks the supplemental as DV with
            // HDR10 base for AVPlayer's profile-matching; without
            // it the variant is treated as plain HDR10 and the DV
            // pipeline never engages. AVKit's auto-criteria parser
            // reads the dvvC from the live AVPlayerItem.
            // formatDescription via the private CoreMedia hook.
            //
            // Non-DV panel (HDR10-only): emit plain HEVC HDR10 and
            // STRIP DV side data so the muxer writes a clean
            // `hvc1` + `hvcC` sample entry with NO dvvC box. The
            // SUPPLEMENTAL hint causes AVPlayer to engage the DV
            // codec path even on HDR10-only displays and fail
            // silently (regression in 1.4.2, fixed in f7e9f77 by
            // gating SUPPLEMENTAL on `effectiveDvMode`). But a
            // dvvC box left in the sample entry trips tvOS 26's
            // master-level codec filter with -11868 even when
            // CODECS is plain `hvc1.2.4.LXX` (Vincent test
            // 2026-05-26: HDR10 TV + match dynamic range ON,
            // panel switches to HDR correctly but `item.status`
            // goes `.failed` with `AVFoundationErrorDomain -11868`
            // / `CoreMediaErrorDomain -17223`, picture stays
            // black). Stripping DV side data mirrors P7's strategy
            // (P7 always strips because no Apple TV chip has a P7
            // decoder); for P8.1 we strip conditionally based on
            // display capability since DV-capable panels need the
            // dvvC for the upgrade path.
            //
            // Malformed "P8.6": some files are tagged profile 8 with an
            // invalid `dv_bl_signal_compatibility_id` (often 6, borrowed
            // from P7's marker, when an old tool confused the profile
            // with the `dvhe08.06` level field). The bitstream is really
            // a single-layer HDR10-base P8.1 stream, but a `dvvC` whose
            // compat id contradicts the `db1p` brand makes AVPlayer reject
            // the variant outright (issue #53, DrHurt). On a DV panel,
            // normalize the container record to a clean compat==1 (the
            // muxer's `rewriteDoviConfigToProfile81` also pins profile=8 /
            // el=0) so the dvvC and db1p agree; no per-packet RPU work is
            // needed since the elementary stream is already P8.1. On a
            // non-DV panel the strip path already forces HDR10 fallback,
            // matching the server's DOVIInvalid remux behaviour.
            let compat = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 1)
            let needsCompatRewrite = compat != 1
            let supplemental: String?
            let strip: Bool
            if effectiveDvMode {
                supplemental = "dvh1.08.\(dvLevelStr)/db1p"
                strip = false
            } else {
                supplemental = nil
                strip = true
            }
            if needsCompatRewrite && effectiveDvMode {
                EngineLog.emit(
                    "[HLSVideoEngine] HEVC DV Profile 8 with invalid compat="
                    + "\(compat) (\"P8.6\"); normalizing container dvcC to "
                    + "P8.1 (compat=1) for AVPlayer on DV panel",
                    category: .session
                )
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .pq,
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: supplemental,
                stripDolbyVisionMetadata: strip,
                convertP7ToProfile81: false,
                rewriteDoviConfigTo81: needsCompatRewrite && effectiveDvMode,
                dvVariant: dvVariant
            )
        case .profile84:
            // P8.4 (HLG-compat base layer). Two branches mirror P8.1:
            //
            // DV-capable panel (`effectiveDvMode == true`): emit
            // `hvc1` sample entry + `hvcC` + `dvvC` boxes (mp4
            // muxer writes dvvC automatically when DV side data
            // is preserved on the codecpar), primary CODECS
            // `hvc1.2.4.LXX`, SUPPLEMENTAL-CODECS `dvh1.08.XX/db4h`.
            // The `/db4h` brand identifier marks the supplemental
            // as DV with HLG base for AVPlayer's profile matching;
            // AVKit's auto-criteria reads dvvC from the live
            // formatDescription and drives DV mode on the panel.
            //
            // Non-DV panel (HDR10 / HLG-capable / SDR): emit plain
            // HEVC HLG and STRIP DV side data so init.mp4 has a
            // clean `hvc1` + `hvcC` sample entry with NO dvvC.
            // Mirrors P8.1's strip path (Vincent test 2026-05-26
            // on HDR10 panel: dvvC in init.mp4 trips tvOS 26's
            // master-level codec filter even when master CODECS
            // is plain hvc1.2.4 with no SUPPLEMENTAL). The plain
            // HLG variant plays on HLG-capable panels and gets
            // tonemapped on HDR10 / SDR panels by AVPlayer's
            // auto-tonemap path. Bare `dvh1` sample entry was
            // never an option for HLG-base regardless of panel
            // (DrHurt #4 Build 160: AVPlayer rejects dvh1 +
            // HLG transfer outright).
            let supplemental: String?
            let strip: Bool
            if effectiveDvMode {
                supplemental = "dvh1.08.\(dvLevelStr)/db4h"
                strip = false
            } else {
                supplemental = nil
                strip = true
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .hlg,
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: supplemental,
                stripDolbyVisionMetadata: strip,
                convertP7ToProfile81: false,
                dvVariant: dvVariant
            )
        case .profile7:
            // P7 dual-layer (UHD-BD remux territory). The bitstream
            // carries an HEVC Main10 base layer + an enhancement
            // layer + RPU.
            //
            // On a DV-capable panel: convert each packet's RPU from
            // P7 to P8.1 in place via `DoviRpuConverter` and rewrite
            // the container `dvcC` record to Profile 8.1, then route
            // identically to P8.1 (`hvc1` + `dvvC`, SUPPLEMENTAL
            // `dvh1.08.XX/db1p`). The enhancement layer is dropped
            // per-packet by the converter (Apple has no EL decoder),
            // the base layer + converted RPU remain.
            //
            // On a non-DV panel: no P7 decoder exists on any Apple TV
            // chip, so strip `dvcC` and route as plain HEVC HDR10
            // (unchanged from the prior behaviour). The BL is always
            // PQ HEVC Main10 by construction (UHD-BD requires HDR10
            // backwards-compat), so AVPlayer plays PQ correctly.
            //
            // `dv_bl_signal_compatibility_id` is typically 6 for P7
            // sources (P7-specific marker, not a formal HDR10 flag).
            // We don't read compat here; all P7 routes the same way.
            let supplemental: String?
            let strip: Bool
            if effectiveDvMode {
                supplemental = "dvh1.08.\(dvLevelStr)/db1p"
                strip = false
            } else {
                supplemental = nil
                strip = true
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .pq,
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: supplemental,
                stripDolbyVisionMetadata: strip,
                convertP7ToProfile81: effectiveDvMode,
                rewriteDoviConfigTo81: effectiveDvMode,
                dvVariant: dvVariant
            )
        case .unknown:
            let p = Int(dvRecord?.dv_profile ?? 0)
            let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
            throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
        case .none, .profile82:
            // Plain HEVC (no DV) OR P8.2 (SDR-compat base). P8.2's base
            // is an ordinary Rec.709 SDR HEVC stream; Apple has no P8.2
            // DV decode path and the SDR base can't be repackaged to a
            // DV-capable profile (the pixels are SDR, not PQ). Both play
            // the HEVC base; P8.2 additionally strips its DV config so the
            // muxer writes a clean `hvc1` + `hvcC` sample entry with no
            // dvvC box (a leftover dvvC trips tvOS 26's codec filter, cf.
            // the P8.1 non-DV strip path). Range derives from the base
            // transfer (Rec.709 → SDR). The RPU NALs ride along ignored.
            if dvVariant == .profile82 {
                EngineLog.emit(
                    "[HLSVideoEngine] HEVC DV Profile 8.2 (SDR base) "
                    + "detected; not DV-routable, playing Rec.709 base as "
                    + "plain hvc1 (DV config stripped)",
                    category: .session
                )
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: manifestVideoRange(codecpar),
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: nil,
                stripDolbyVisionMetadata: dvVariant == .profile82,
                convertP7ToProfile81: false,
                dvVariant: dvVariant
            )
        // AV1 DV variants unreachable here (classify was called with
        // AV_CODEC_ID_HEVC) but exhaustivity needs them.
        case .av1Profile10, .av1Profile101, .av1Profile104, .av1Profile102:
            throw HLSVideoEngineError.unsupportedDVProfile(profile: -1, compatID: -1)
        }
    }
}
