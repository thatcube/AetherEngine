import Foundation

/// Live HLS ingest as a public `IOReader`: resolves the upstream playlist
/// (master -> highest-BANDWIDTH variant), polls the media playlist, fetches
/// the MPEG-TS segments sequentially, and exposes the result as a single
/// forward-only TS byte stream the engine demuxes through
/// `AetherEngine.load(source: .custom(reader, formatHint: "mpegts"),
/// options: <isLive>)`.
///
/// Phase-1 contract (see the 2026-06-11 design spec): unencrypted TS
/// segments only. Encrypted playlists (EXT-X-KEY), fMP4 playlists
/// (EXT-X-MAP), non-TS first segments, unreachable/invalid playlists, and
/// stalled providers all terminate the stream with a logged
/// `HLSIngestError`; the read side then errors and the host falls back.
///
/// Forward-only: `seek` always returns -1 (including AVSEEK_SIZE; length is
/// unknown). Requires the engine's live custom-source gates (same commit
/// series) so it still dispatches to the native loopback path.
///
/// Memory: the FIFO caps at 16 MB plus at most one segment of overshoot;
/// extreme-bitrate sources transiently hold one fetched segment on top.
/// Switching to streamed segment reads is a P2 option if that ever bites.
public final class HLSLiveIngestReader: IOReader, @unchecked Sendable {
    private let playlistURL: URL
    private let fifo = ByteFIFO(capacity: 16 * 1024 * 1024)
    private let session: URLSession
    private var ingestTask: Task<Void, Never>?
    private let startLock = NSLock()
    private var started = false
    private var closed = false
    /// Terminal ingest error, readable by the host for fallback logging.
    /// Protected by startLock: written from the detached ingest task under
    /// startLock, read by the host after the FIFO signals failure.
    private var _terminalError: HLSIngestError?

    /// Terminal ingest error, readable by the host for fallback logging.
    public var terminalError: HLSIngestError? {
        startLock.withLock { _terminalError }
    }

    public init(playlistURL: URL) {
        self.playlistURL = playlistURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        // 30s resource ceiling per one-shot fetch: a trickling CDN must fail
        // the segment (and ultimately the ingest) instead of stalling
        // playback forever with no host fallback. The c7592ed no-ceiling
        // lesson applies to LONG-LIVED stream connections, not to bounded
        // one-shot playlist/segment fetches.
        self.session = URLSession(configuration: config)
    }

    // MARK: - IOReader

    public func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        startIfNeeded()
        let n = fifo.read(into: buffer, maxLength: Int(size))
        return Int32(n)
    }

    public func seek(offset: Int64, whence: Int32) -> Int64 {
        // Forward-only live stream of unknown length: reject everything,
        // including AVSEEK_SIZE (65536).
        -1
    }

    public func close() {
        startLock.lock()
        closed = true
        let wasStarted = started
        let task = ingestTask
        ingestTask = nil
        task?.cancel()
        startLock.unlock()

        fifo.cancel()
        if !wasStarted {
            // Ingest never launched: we are the sole owner of the session.
            session.invalidateAndCancel()
        }
        // If wasStarted, the defer inside runIngest() owns session teardown.
    }

    public func cancel() {
        // Unblock a pending read without invalidating the reader.
        fifo.cancel()
    }

    // MARK: - Ingest loop

    private func startIfNeeded() {
        startLock.lock()
        defer { startLock.unlock() }
        guard !started, !closed else { return }
        started = true
        // Strong capture on purpose: the ingest loop must keep the reader
        // (and its FIFO) alive until close() cancels it; close() is
        // guaranteed by the IOReader contract.
        ingestTask = Task.detached(priority: .userInitiated) { [self] in
            await runIngest()
        }
    }

    private func runIngest() async {
        defer { session.invalidateAndCancel() }
        do {
            let (mediaURL, seedPlaylist) = try await resolveMediaPlaylistURL()
            var tracker = HLSPlaylistTracker()
            var sniffedFirstSegment = false
            var refreshInterval: Double = 2
            var pendingPlaylist: HLSMediaPlaylist? = seedPlaylist

            while !Task.isCancelled {
                let media: HLSMediaPlaylist
                if let seeded = pendingPlaylist {
                    // First iteration: reuse the already-parsed media playlist
                    // from resolveMediaPlaylistURL so we don't refetch it.
                    media = seeded
                    pendingPlaylist = nil
                } else {
                    let (playlist, _) = try await fetchPlaylist(mediaURL)
                    guard case .media(let fetched) = playlist else {
                        throw HLSIngestError.playlistInvalid(reason: "expected media playlist on refresh")
                    }
                    media = fetched
                }
                if media.isEncrypted { throw HLSIngestError.encryptedNotSupported }
                if media.hasMap { throw HLSIngestError.unsupportedSegmentFormat }
                refreshInterval = min(6, max(1, media.targetDuration / 2))

                let fresh = tracker.newSegments(in: media)
                if tracker.stallCount > 6 { throw HLSIngestError.ingestStalled }

                for segment in fresh {
                    guard !Task.isCancelled else { return }
                    if segment.discontinuityBefore {
                        // Phase 1 decision (design spec): the seam is logged, the actual
                        // timestamp handling rides on the producer's PTS-leap rebase
                        // heuristic downstream; a deterministic force-cut hint is a P2 item.
                        EngineLog.emit("[HLSIngest] discontinuity seam before segment \(segment.uri)", category: .engine)
                    }
                    guard let segmentURL = HLSPlaylistParser.resolve(uri: segment.uri, against: mediaURL) else {
                        throw HLSIngestError.playlistInvalid(reason: "unresolvable segment URI")
                    }
                    let bytes = try await fetchSegment(segmentURL)
                    if bytes.isEmpty { continue } // 404: slid out of the window
                    if !sniffedFirstSegment {
                        sniffedFirstSegment = true
                        guard bytes.first == 0x47 else {
                            throw HLSIngestError.unsupportedSegmentFormat
                        }
                    }
                    guard fifo.write(bytes) else { return } // closed underneath us
                }

                if media.hasEndList {
                    fifo.finish() // a "live" playlist that ended: clean EOF
                    return
                }
                if fresh.isEmpty {
                    try await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
                }
            }
        } catch is CancellationError {
            // teardown
        } catch let error as HLSIngestError {
            startLock.withLock { _terminalError = error }
            EngineLog.emit("[HLSIngest] terminal: \(error)", category: .engine)
            fifo.cancel()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return // teardown rides through as cancellation, not a terminal error
            }
            startLock.withLock { _terminalError = .playlistUnreachable(status: -1) }
            EngineLog.emit("[HLSIngest] terminal (transport): \(error.localizedDescription)", category: .engine)
            fifo.cancel()
        }
    }

    /// Resolves the media playlist URL and returns the already-parsed
    /// `HLSMediaPlaylist` when the input URL is a direct media playlist
    /// (so the caller can reuse it without a second fetch). Returns `nil`
    /// for the seed in the master-playlist case.
    private func resolveMediaPlaylistURL() async throws -> (URL, HLSMediaPlaylist?) {
        let (playlist, finalURL) = try await fetchPlaylist(playlistURL)
        switch playlist {
        case .media(let media):
            // Direct media playlist: hand the parsed result back so the
            // ingest loop's first iteration does not refetch it.
            return (finalURL, media)
        case .master(let variants):
            guard let best = variants.max(by: { $0.bandwidth < $1.bandwidth }),
                  let url = HLSPlaylistParser.resolve(uri: best.uri, against: finalURL) else {
                throw HLSIngestError.playlistInvalid(reason: "no usable variant")
            }
            EngineLog.emit("[HLSIngest] master playlist: picked variant bandwidth=\(best.bandwidth)", category: .engine)
            return (url, nil)
        }
    }

    /// Fetch + parse a playlist. Returns the parsed playlist and the FINAL
    /// URL after redirects, which relative segment URIs resolve against.
    private func fetchPlaylist(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSIngestError.playlistInvalid(reason: "non-UTF8 playlist")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    private func fetchSegment(_ url: URL) async throws -> Data {
        // Bounded retry per segment; a 404 means the segment slid out of
        // the provider window, skip it (the tracker advances regardless).
        var lastStatus = -1
        for attempt in 0..<3 {
            if Task.isCancelled { throw CancellationError() }
            do {
                let (data, response) = try await session.data(from: url)
                lastStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
                if (200..<300).contains(lastStatus) { return data }
                if lastStatus == 404 { return Data() } // slid out of window
                if (400..<500).contains(lastStatus) && lastStatus != 429 {
                    throw HLSIngestError.playlistUnreachable(status: lastStatus)
                }
            } catch let error as HLSIngestError { throw error }
            catch { /* transport blip: retry */ }
            if attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(0.5 * Double(attempt + 1) * 1_000_000_000))
            }
        }
        throw HLSIngestError.playlistUnreachable(status: lastStatus)
    }
}
