import Foundation

/// Seekable `IOReader` over a remote disc image (ISO 9660 / UDF / Blu-ray BDMV) served over HTTP(S)
/// with byte-range support. The local case has `FileIOReader`; this is its remote twin, so
/// `DiscReader.wrap` can probe and read a remote `.iso` exactly the way it reads a local one (the
/// disc layer issues random-access seeks for the UDF anchor and directory structure, then reads the
/// selected title's m2ts/VOB extents). Without this a remote `.iso` is handed straight to
/// libavformat, which fails to probe it (a disc image is a filesystem, not a media container) (#64).
///
/// Reads are served from a single sliding read-ahead buffer; a read whose position falls outside the
/// buffer issues one synchronous `Range` GET for a fresh `chunkSize` window. Sequential playback
/// therefore costs roughly `fileSize / chunkSize` requests; the scattered disc-structure reads at
/// open cost one request each. The server MUST honor range requests (any static file host does);
/// if it does not, `init` returns nil and the caller falls back to the plain streaming path.
final class HTTPDiscIOReader: IOReader, @unchecked Sendable {

    private let url: URL
    private let extraHeaders: [String: String]
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let chunkSize: Int
    private let totalSize: Int64

    private let lock = NSLock()
    private var position: Int64 = 0
    private var bufferStart: Int64 = -1
    private var buffer: [UInt8] = []

    /// Probes total size and range support with one `bytes=0-0` request. Returns nil if the source
    /// is unreachable, reports an unknown size, or answers `200` (full body, no range support).
    init?(url: URL,
          extraHeaders: [String: String] = [:],
          chunkSize: Int = 1 << 20,
          requestTimeout: TimeInterval = 30,
          sessionConfiguration: URLSessionConfiguration? = nil) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.chunkSize = max(64 * 1024, chunkSize)
        self.requestTimeout = requestTimeout
        let config = sessionConfiguration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            return c
        }()
        self.session = URLSession(configuration: config)

        guard let size = Self.probeSize(
            url: url, extraHeaders: extraHeaders, session: session, timeout: requestTimeout
        ), size > 0 else {
            session.invalidateAndCancel()
            return nil
        }
        self.totalSize = size
    }

    // MARK: - Pure helpers

    /// Inclusive byte-range header for a half-open `[offset, offset+length)` window.
    static func rangeHeader(offset: Int64, length: Int) -> String {
        "bytes=\(offset)-\(offset + Int64(length) - 1)"
    }

    /// Total size from a `Content-Range` value (`bytes 0-0/12345` -> 12345). Nil for `*` or junk.
    static func parseContentRangeTotal(_ value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard total != "*" else { return nil }
        return Int64(total)
    }

    // MARK: - IOReader

    func read(_ outBuffer: UnsafeMutablePointer<UInt8>?, size n: Int32) -> Int32 {
        guard let out = outBuffer, n > 0 else { return -1 }
        lock.lock(); defer { lock.unlock() }
        if position >= totalSize { return 0 }

        if position < bufferStart || position >= bufferStart + Int64(buffer.count) {
            let start = position
            let want = Int(min(Int64(chunkSize), totalSize - start))
            guard want > 0, let data = fetch(offset: start, length: want), !data.isEmpty else {
                return -1
            }
            bufferStart = start
            buffer = [UInt8](data)
        }

        let bufOffset = Int(position - bufferStart)
        let available = buffer.count - bufOffset
        let toCopy = min(Int(n), available, Int(totalSize - position))
        guard toCopy > 0 else { return 0 }
        buffer.withUnsafeBufferPointer { src in
            out.update(from: src.baseAddress!.advanced(by: bufOffset), count: toCopy)
        }
        position += Int64(toCopy)
        return Int32(toCopy)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return totalSize }  // AVSEEK_SIZE
        lock.lock(); defer { lock.unlock() }
        let target: Int64
        switch whence {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END: target = totalSize + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = target
        return target
    }

    func close() { session.invalidateAndCancel() }

    func cancel() { session.getAllTasks { $0.forEach { $0.cancel() } } }

    func makeIndependentReader() -> IOReader? {
        HTTPDiscIOReader(url: url, extraHeaders: extraHeaders,
                         chunkSize: chunkSize, requestTimeout: requestTimeout)
    }

    // MARK: - HTTP

    private func fetch(offset: Int64, length: Int) -> Data? {
        Self.rangeGet(url: url, extraHeaders: extraHeaders, session: session,
                      timeout: requestTimeout, offset: offset, length: length)?.body
    }

    private static func probeSize(url: URL, extraHeaders: [String: String],
                                  session: URLSession, timeout: TimeInterval) -> Int64? {
        guard let r = rangeGet(url: url, extraHeaders: extraHeaders, session: session,
                               timeout: timeout, offset: 0, length: 1) else { return nil }
        // 206 with Content-Range proves range support and carries the total.
        guard r.status == 206, let cr = r.contentRange else { return nil }
        return parseContentRangeTotal(cr)
    }

    private struct RangeResponse { let status: Int; let contentRange: String?; let body: Data }

    private static func rangeGet(url: URL, extraHeaders: [String: String], session: URLSession,
                                 timeout: TimeInterval, offset: Int64, length: Int) -> RangeResponse? {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue(rangeHeader(offset: offset, length: length), forHTTPHeaderField: "Range")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let sem = DispatchSemaphore(value: 0)
        var result: RangeResponse?
        let task = session.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = RangeResponse(
                    status: http.statusCode,
                    contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                    body: data ?? Data()
                )
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            return nil
        }
        return result
    }
}
