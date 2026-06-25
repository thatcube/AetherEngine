import Foundation
import Libavformat
import Libavcodec
import Libavutil


/// Open-time tuning for the demuxer + its AVIO reader. `.playback` is
/// the default everywhere; `.stillExtraction` switches AVIO to a
/// random-access profile (no read-ahead prefetch, small seek chunk) and
/// a minimal probe budget for fast single-keyframe fetches.
struct DemuxerOpenProfile: Sendable {
    var probesize: Int64
    var maxAnalyzeDuration: Int64
    var avioPrefetch: Bool
    var avioChunkSize: Int
    /// Per-chunk Range-request budget for the seekable (still-extraction) AVIO path.
    /// Caps how long a single cold/stalled chunk read can park before it aborts.
    /// Playback keeps the generous default (its reads go through the persistent
    /// reader; this only bounds open-time size probes). Still extraction shrinks it
    /// so a disposable scrub thumbnail never freezes the decode queue (issue #27).
    var avioRequestTimeout: TimeInterval
    /// Retry passes for a failed seekable chunk fetch. Still extraction drops this
    /// to a single attempt: a scrub thumbnail is disposable and must fail fast
    /// rather than ride a 3-retry-times-2-URL storm (issue #27).
    var avioMaxRetries: Int

    static let playback = DemuxerOpenProfile(
        probesize: 50 * 1024 * 1024,
        maxAnalyzeDuration: 60 * 1_000_000,
        avioPrefetch: true,
        avioChunkSize: 4 * 1024 * 1024,
        avioRequestTimeout: 35,
        avioMaxRetries: 3
    )

    static let stillExtraction = DemuxerOpenProfile(
        probesize: 2 * 1024 * 1024,
        maxAnalyzeDuration: 2 * 1_000_000,
        avioPrefetch: false,
        avioChunkSize: 1 * 1024 * 1024,
        avioRequestTimeout: 8,
        avioMaxRetries: 1
    )
}

/// AVFormatContext wrapper. HTTP(S) uses custom AVIO via URLSession (no built-in
/// network stack in FFmpegBuild); file:// uses FFmpeg's file protocol directly.
/// `readPacket()` and `seek()` serialized via `accessLock` for thread safety.
public final class Demuxer: @unchecked Sendable {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?

    // Serializes formatContext access between readPacket() and seek();
    // concurrent access triggers assertion failures in matroskadec.c.
    private let accessLock = NSLock()

    private var avioProvider: AVIOProvider?
    private var openProfile: DemuxerOpenProfile = .playback

    // Memory probe: compare against RSS growth; 0 for file:// sources.
    var avioBytesFetched: Int64 { avioProvider?.cumulativeBytesFetched ?? 0 }

    // Forward-only custom sources report false.
    var isSourceSeekable: Bool { avioProvider?.isSeekable ?? true }

    /// Timestamp of last unplanned reconnect (drop/stall, not a seek).
    /// Live producer correlates with backward source-PTS reset to detect
    /// Jellyfin transcode respawn. See `AVIOReader.lastUnplannedReconnectAt`.
    var lastUnplannedSourceReconnectAt: Date? {
        (avioProvider as? AVIOReader)?.lastUnplannedReconnectAt
    }

    /// Open a media URL and probe its streams.
    /// - Parameters:
    ///   - extraHeaders: Attached to every HTTP request (ignored for file:// URLs).
    ///   - isLive: Suppresses EOF synthesis and surfaces terminal error on reconnect cap.
    func open(url: URL, extraHeaders: [String: String] = [:], profile: DemuxerOpenProfile = .playback, isLive: Bool = false) throws {
        self.openProfile = profile
        let isHTTP = url.scheme == "http" || url.scheme == "https"

        if isHTTP {
            try openHTTP(url: url, extraHeaders: extraHeaders, isLive: isLive)
        } else {
            // Route a local DVD ISO through the disc adapter (FileIOReader keeps it
            // out of RAM). Falls back to the normal local open when not a disc.
            if url.isFileURL, let fileReader = FileIOReader(url: url),
               let (discReader, discHint) = try DiscReader.wrap(fileReader) {
                let bridge = CustomIOReaderBridge(reader: discReader)
                let inputFormat = av_find_input_format(discHint)
                try openWithProvider(bridge, inputFormat: inputFormat, isLive: isLive)
                return
            }
            try openLocal(url: url)
        }
    }

    // MARK: - Open Strategies

    private func openLocal(url: URL) throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocated = ctx else {
            throw DemuxerError.openFailed(code: -1)
        }
        applyProbeBudget(allocated)

        let urlString = url.isFileURL ? url.path : url.absoluteString
        var opts: OpaquePointer? = nil
        Self.applyDemuxerOptions(&opts)
        let ret = avformat_open_input(&ctx, urlString, nil, &opts)
        av_dict_free(&opts)
        guard ret == 0, let openedCtx = ctx else {
            throw DemuxerError.openFailed(code: ret)
        }
        formatContext = openedCtx

        try probeStreams(openedCtx)
    }

    /// Open a custom `IOReader` source. `formatHint` disambiguates probing when
    /// no filename is available. `isLive` suppresses SEEK_END that latches EOF
    /// on forward-only readers (38ad60b). AetherEngine#36: DiscReader adapts
    /// DVD/BD ISOs to VOB/MPEGTS concat streams.
    func open(reader: IOReader, formatHint: String? = nil, profile: DemuxerOpenProfile = .playback, isLive: Bool = false) throws {
        self.openProfile = profile
        if let (discReader, discHint) = try DiscReader.wrap(reader) {
            let bridge = CustomIOReaderBridge(reader: discReader)
            let inputFormat = av_find_input_format(discHint)
            try openWithProvider(bridge, inputFormat: inputFormat, isLive: isLive)
            return
        }
        let bridge = CustomIOReaderBridge(reader: reader)
        let inputFormat: UnsafePointer<AVInputFormat>? = formatHint.flatMap { av_find_input_format($0) }
        try openWithProvider(bridge, inputFormat: inputFormat, isLive: isLive)
    }

    /// A remote disc image (ISO 9660 / UDF / BDMV) by URL extension. Gates the HTTP disc-adapter
    /// path so a normal media URL keeps the optimized streaming AVIOReader open with no probe cost.
    static func isDiscImageURL(_ url: URL) -> Bool {
        ["iso", "img", "udf"].contains(url.pathExtension.lowercased())
    }

    private func openHTTP(url: URL, extraHeaders: [String: String], isLive: Bool = false) throws {
        // A remote disc image goes through the same disc adapter as a local ISO (a raw .iso handed
        // straight to libavformat fails to probe; it is a filesystem, not a media container, #64).
        // Gated on the disc-image extension so normal media URLs skip the range-probe entirely; if
        // the source is not a recognizable disc, fall through to the streaming reader.
        if !isLive, Self.isDiscImageURL(url),
           let discReader = HTTPDiscIOReader(url: url, extraHeaders: extraHeaders) {
            if let (wrapped, discHint) = try DiscReader.wrap(discReader) {
                let bridge = CustomIOReaderBridge(reader: wrapped)
                let inputFormat = av_find_input_format(discHint)
                try openWithProvider(bridge, inputFormat: inputFormat, isLive: false)
                return
            }
            discReader.close()
        }
        let reader = AVIOReader(
            url: url,
            extraHeaders: extraHeaders,
            chunkSize: openProfile.avioChunkSize,
            prefetchEnabled: openProfile.avioPrefetch,
            isLive: isLive,
            chunkRequestTimeout: openProfile.avioRequestTimeout,
            chunkMaxRetries: openProfile.avioMaxRetries
        )
        try openWithProvider(reader, isLive: isLive)
    }

    /// Common AVIO open path. `inputFormat` forces a demuxer (custom sources with
    /// a format hint). `isLive` suppresses duration-estimate SEEK_END that latches
    /// EOF on unknown-length live sources.
    private func openWithProvider(
        _ provider: AVIOProvider,
        inputFormat: UnsafePointer<AVInputFormat>? = nil,
        isLive: Bool = false
    ) throws {
        try provider.open()
        avioProvider = provider

        guard let ctx = avformat_alloc_context() else {
            avioProvider?.close()
            avioProvider = nil
            throw DemuxerError.openFailed(code: -1)
        }
        ctx.pointee.pb = provider.context
        applyProbeBudget(ctx)
        formatContext = ctx

        // URL is nil because pb is already set.
        var ctxPtr: UnsafeMutablePointer<AVFormatContext>? = ctx
        var opts: OpaquePointer? = nil
        Self.applyDemuxerOptions(&opts, isLive: isLive)
        let ret = avformat_open_input(&ctxPtr, nil, inputFormat, &opts)
        av_dict_free(&opts)
        guard ret == 0 else {
            formatContext = nil
            avioProvider?.close()
            avioProvider = nil
            throw DemuxerError.openFailed(code: ret)
        }
        formatContext = ctxPtr  // avformat_open_input may reallocate

        try probeStreams(ctxPtr!)
    }

    /// Default 5 MB/5s budgets miss sparse PGS/DVB tracks on 10-20 GB Blu-ray rips.
    /// 50 MB/60 s ensures codec params are populated without noticeably slowing open.
    private func applyProbeBudget(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        ctx.pointee.probesize = openProfile.probesize
        ctx.pointee.max_analyze_duration = openProfile.maxAnalyzeDuration
    }

    /// Demuxer fflags applied to every avformat_open_input.
    /// +genpts: libavformat regenerates missing pts/dts; per AetherEngine#4 this is
    /// what Jellyfin's server-side remux uses. Cuts 4K HDR HEVC RSS growth ~50%
    /// (3.24 MB/s -> ~1.7 MB/s). Tried+reverted: +sortdts (worse RSS), +discardcorrupt
    /// (worse RSS), +igndts (AetherEngine#5: matroska still emits dts=0 on HEVC open-GOP
    /// CRA B-frames, NOPTS repair stack stayed load-bearing).
    private static func applyDemuxerOptions(_ opts: inout OpaquePointer?, isLive: Bool = false) {
        av_dict_set(&opts, "fflags", "+genpts", 0)
        if isLive {
            // Live sources have no Content-Length; stream-info pass seeks SEEK_END,
            // which latches pb->eof_reached and collapses av_read_frame ~10s in.
            // skip_estimate_duration_from_pts avoids that SEEK_END entirely.
            av_dict_set(&opts, "skip_estimate_duration_from_pts", "1", 0)
        }
    }

    private func probeStreams(_ ctx: UnsafeMutablePointer<AVFormatContext>) throws {
        let findRet = avformat_find_stream_info(ctx, nil)
        guard findRet >= 0 else {
            throw DemuxerError.streamInfoFailed(code: findRet)
        }

        #if DEBUG
        EngineLog.emit("[Demuxer] Opened: \(ctx.pointee.nb_streams) streams, duration=\(ctx.pointee.duration) us", category: .demux)
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar else { continue }
            let codecType = codecpar.pointee.codec_type
            let typeName: String
            switch codecType {
            case AVMEDIA_TYPE_VIDEO: typeName = "video"
            case AVMEDIA_TYPE_AUDIO: typeName = "audio"
            case AVMEDIA_TYPE_SUBTITLE: typeName = "subtitle"
            default: typeName = "other"
            }
            let codecName = String(cString: avcodec_get_name(codecpar.pointee.codec_id))
            EngineLog.emit("[Demuxer]   stream[\(i)] type=\(typeName) codec=\(codecName) \(codecpar.pointee.width)x\(codecpar.pointee.height)", category: .demux)
        }
        #endif
    }

    var duration: Double {
        guard let ctx = formatContext else { return 0 }
        let dur = ctx.pointee.duration
        return dur > 0 ? Double(dur) / Double(AV_TIME_BASE) : 0
    }

    /// AVFormatContext.bit_rate in bps, or 0 if unknown. Used by
    /// HLSVideoEngine.masterBandwidth to populate HLS BANDWIDTH attributes.
    var bitRate: Int64 {
        guard let ctx = formatContext else { return 0 }
        return ctx.pointee.bit_rate
    }

    /// AVFormatContext.start_time in AV_TIME_BASE units. Non-zero on re-muxed
    /// MKV/TS; subtract from packet PTS for file-relative playback time.
    var formatStartTime: Int64 {
        guard let ctx = formatContext else { return 0 }
        return ctx.pointee.start_time
    }

    /// Index of the best video stream, or -1.
    /// Clamped: av_find_best_stream returns AVERROR_STREAM_NOT_FOUND (-1381258232)
    /// on failure, not -1; normalize to -1 to avoid garbage in logs.
    var videoStreamIndex: Int32 {
        guard let ctx = formatContext else { return -1 }
        return max(-1, av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0))
    }

    /// True if `index` names a video stream. Live producer uses this to detect
    /// an SSAI program change that introduces a new video PID mid-stream.
    func isVideoStream(_ index: Int32) -> Bool {
        accessLock.lock(); defer { accessLock.unlock() }
        guard let ctx = formatContext, index >= 0, index < ctx.pointee.nb_streams,
              let stream = ctx.pointee.streams[Int(index)] else { return false }
        return stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
    }


    /// Best audio stream index, or -1 (same AVERROR_STREAM_NOT_FOUND clamp as videoStreamIndex).
    /// GOTCHA: av_find_best_stream skips streams with no channels/sample_rate (live MPEG-TS
    /// probe may leave them that way). Use `firstAudioStreamIndexByType` as fallback.
    var audioStreamIndex: Int32 {
        guard let ctx = formatContext else { return -1 }
        return max(-1, av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0))
    }

    /// First audio stream by codec_type regardless of codecpar completeness.
    /// Fallback for live MPEG-TS where av_find_best_stream skips empty-codecpar
    /// streams; the engine's live AAC codecpar repair fills them downstream.
    var firstAudioStreamIndexByType: Int32 {
        guard let ctx = formatContext else { return -1 }
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            return Int32(i)
        }
        return -1
    }

    func audioTrackInfos() -> [TrackInfo] {
        guard let ctx = formatContext else { return [] }
        var tracks: [TrackInfo] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            tracks.append(trackInfo(from: stream, index: i))
        }
        return tracks
    }

    func subtitleTrackInfos() -> [TrackInfo] {
        guard let ctx = formatContext else { return [] }
        var tracks: [TrackInfo] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            tracks.append(trackInfo(from: stream, index: i))
        }
        return tracks
    }

    func mediaMetadata() -> MediaMetadata {
        guard let ctx = formatContext else {
            return MediaMetadata(title: nil, artist: nil, album: nil, artworkData: nil)
        }
        let dict = ctx.pointee.metadata
        return MediaMetadata.from(
            title: metadataValue(dict, key: "title"),
            artist: metadataValue(dict, key: "artist"),
            album: metadataValue(dict, key: "album"),
            albumArtist: metadataValue(dict, key: "album_artist"),
            artworkData: attachedPictureData()
        )
    }

    private func attachedPictureData() -> Data? {
        guard let ctx = formatContext else { return nil }
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
            else { continue }
            let pkt = stream.pointee.attached_pic
            guard pkt.size > 0, let dataPtr = pkt.data else { return nil }
            return Data(bytes: dataPtr, count: Int(pkt.size))
        }
        return nil
    }

    private func trackInfo(from stream: UnsafeMutablePointer<AVStream>, index: Int) -> TrackInfo {
        let codecpar = stream.pointee.codecpar!
        let codecName: String
        if let codec = avcodec_find_decoder(codecpar.pointee.codec_id) {
            codecName = String(cString: codec.pointee.name)
        } else {
            codecName = "unknown"
        }

        let language = metadataValue(stream.pointee.metadata, key: "language")
        let title = metadataValue(stream.pointee.metadata, key: "title")
        let name: String
        if let title = title, !title.isEmpty {
            name = title
        } else if let lang = language {
            name = "\(lang.uppercased()) (\(codecName))"
        } else {
            name = "Track \(index) (\(codecName))"
        }

        let isDefault = (stream.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0
        let channels = Int(codecpar.pointee.ch_layout.nb_channels)

        // EAC3 profile 30 = JOC (Dolby Atmos on streaming). Lets UI label "Atmos".
        let isAtmos = (codecpar.pointee.codec_id == AV_CODEC_ID_EAC3)
            && codecpar.pointee.profile == 30

        // ASS/SSA codec extradata = script header ([Script Info] + [V4+ Styles] +
        // [Events] format line). Surfaced for LoadOptions.preserveASSMarkup hosts.
        var assHeader: String? = nil
        let codecID = codecpar.pointee.codec_id
        if codecID == AV_CODEC_ID_ASS || codecID == AV_CODEC_ID_SSA,
           let extradata = codecpar.pointee.extradata,
           codecpar.pointee.extradata_size > 0 {
            let bytes = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            // MKV CodecPrivate is frequently NUL-terminated; strip NULs so libass
            // (C-string-style parser) doesn't silently stop before host-appended content.
            assHeader = String(data: bytes, encoding: .utf8)?
                .replacingOccurrences(of: "\0", with: "")
        }

        return TrackInfo(
            id: index,
            name: name,
            codec: codecName,
            language: language,
            channels: channels,
            isDefault: isDefault,
            isAtmos: isAtmos,
            assHeader: assHeader
        )
    }

    /// MKV font attachments. Payload in codec extradata; filename/MIME in stream metadata.
    /// Non-font attachments filtered by isFontPayload.
    func fontAttachmentInfos() -> [FontAttachment] {
        guard let ctx = formatContext else { return [] }
        var fonts: [FontAttachment] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT,
                  let extradata = codecpar.pointee.extradata,
                  codecpar.pointee.extradata_size > 0
            else { continue }
            let filename = metadataValue(stream.pointee.metadata, key: "filename")
            let mimeType = metadataValue(stream.pointee.metadata, key: "mimetype")
            guard FontAttachment.isFontPayload(mimeType: mimeType, filename: filename) else { continue }
            let fallbackExt: String
            switch mimeType?.lowercased() {
            case "font/otf", "application/vnd.ms-opentype", "application/x-font-otf": fallbackExt = "otf"
            case "font/collection": fallbackExt = "ttc"
            default: fallbackExt = "ttf"
            }
            fonts.append(FontAttachment(
                filename: filename ?? "font-\(i).\(fallbackExt)",
                mimeType: mimeType ?? "",
                data: Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            ))
        }
        return fonts
    }

    private func metadataValue(_ dict: OpaquePointer?, key: String) -> String? {
        guard let dict = dict else { return nil }
        guard let entry = av_dict_get(dict, key, nil, 0) else { return nil }
        return String(cString: entry.pointee.value)
    }

    func stream(at index: Int32) -> UnsafeMutablePointer<AVStream>? {
        guard let ctx = formatContext, index >= 0, index < ctx.pointee.nb_streams else {
            return nil
        }
        return ctx.pointee.streams[Int(index)]
    }

    /// Sets AVDISCARD_ALL on streams outside `keep`. Without this, matroska reads
    /// cluster blocks for all streams on every video packet and queues unused PGS
    /// bitmaps and audio frames. AVDISCARD_ALL drops before AVPacket alloc, eliminating
    /// that cycle. Call after open, before readPacket. Safe to call multiple times.
    func discardAllStreamsExcept(_ keep: Set<Int32>) {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return }
        for i in 0..<Int32(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[Int(i)] else { continue }
            // AVDISCARD_DEFAULT = 0 (= passthrough), AVDISCARD_ALL = 48.
            stream.pointee.discard = keep.contains(i)
                ? AVDISCARD_DEFAULT
                : AVDISCARD_ALL
        }
    }

    /// Keyframe timestamps in stream native timebase from libavformat's index.
    /// MKV populates from Cues lazily on first seek (cue-prewarm in
    /// HLSVideoEngine.start() ensures it's ready). MP4 stss / MPEG-TS populate
    /// during avformat_find_stream_info. Empty = no usable index, fall back to
    /// uniform-stride plan. AVINDEX_KEYFRAME checked defensively.
    func indexedKeyframes(streamIndex: Int32) -> [Int64] {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext,
              streamIndex >= 0,
              streamIndex < Int32(ctx.pointee.nb_streams),
              let stream = ctx.pointee.streams[Int(streamIndex)] else {
            return []
        }
        let count = avformat_index_get_entries_count(stream)
        guard count > 0 else { return [] }
        var result: [Int64] = []
        result.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let entry = avformat_index_get_entry(stream, i) else { continue }
            // AVINDEX_KEYFRAME = 0x0001
            if entry.pointee.flags & 0x0001 != 0,
               entry.pointee.timestamp != Int64.min {
                result.append(entry.pointee.timestamp)
            }
        }
        return result
    }

    func readPacket() throws -> UnsafeMutablePointer<AVPacket>? {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return nil }
        var packet: UnsafeMutablePointer<AVPacket>? = trackedPacketAlloc()
        guard packet != nil else { return nil }
        let ret = av_read_frame(ctx, packet)
        if ret < 0 {
            trackedPacketFree(&packet)
            let isEOF = (ret == FFmpegErr.eof)
            if isEOF {
                return nil
            }
            throw DemuxerError.readFailed(code: ret)
        }
        return packet
    }

    /// Seek via avformat_seek_file (not av_seek_frame: assertion failures
    /// in matroskadec.c with nested elements).
    func seek(to seconds: Double) {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return }
        let timestamp = Int64(seconds * Double(AV_TIME_BASE))
        let ret = avformat_seek_file(ctx, -1, Int64.min, timestamp, Int64.max, 0)
        if ret < 0 {
            #if DEBUG
            EngineLog.emit("[Demuxer] Seek to \(seconds)s failed: \(ret)", category: .demux)
            #endif
        }
        avformat_flush(ctx)  // prevents assertion failures in matroskadec.c
    }

    /// Seek with AVIO read deadline. Returns true if completed; false if aborted.
    /// Needed for VOD cue prewarm: missing/truncated MKV Cues causes matroska to
    /// degrade from "1-2 byte-range reads" into a linear half-file scan on a remote
    /// 70+ GB source (de-facto hang). Only AVIOReader honours the deadline.
    @discardableResult
    func seekBounded(to seconds: Double, timeout: TimeInterval) -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return false }
        let reader = avioProvider as? AVIOReader
        reader?.beginReadDeadline(secondsFromNow: timeout)
        defer { reader?.endReadDeadline() }
        let timestamp = Int64(seconds * Double(AV_TIME_BASE))
        let ret = avformat_seek_file(ctx, -1, Int64.min, timestamp, Int64.max, 0)
        avformat_flush(ctx)
        // matroska may return success with a partial index after abort; deadline flag
        // is authoritative, not ret.
        let capped = reader?.readDeadlineFired ?? false
        return ret >= 0 && !capped
    }

    /// Arm a wall-clock read deadline on the AVIO reader so a stalled HTTP read
    /// (seek or readPacket) aborts instead of parking. Used by FrameExtractor still
    /// extraction so a disposable scrub thumbnail bounds its decode and never freezes
    /// the serial decode queue (issue #27). No-op for file:// / custom sources.
    func beginReadDeadline(secondsFromNow seconds: TimeInterval) {
        (avioProvider as? AVIOReader)?.beginReadDeadline(secondsFromNow: seconds)
    }

    /// Disarm the read deadline armed by `beginReadDeadline`.
    func endReadDeadline() {
        (avioProvider as? AVIOReader)?.endReadDeadline()
    }

    /// Fast lock-free unblock: AVIO read callback returns -1, av_read_frame returns
    /// at once. No resource freeing. Call before close() when cancelling a pump.
    func markClosed() {
        avioProvider?.markClosed()
    }

    func close() {
        avioProvider?.markClosed()  // unblocks av_read_frame (tvOS suspends threads in background)
        accessLock.lock()
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        formatContext = nil
        accessLock.unlock()

        avioProvider?.close()
        avioProvider = nil
    }

    deinit {
        close()
    }
}

enum DemuxerError: Error {
    case openFailed(code: Int32)
    case streamInfoFailed(code: Int32)
    case readFailed(code: Int32)
}
