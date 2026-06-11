import Foundation
import Libavformat
import Libavutil

/// Bridges a public `IOReader` into an `AVIOContext` via FFmpeg's
/// `avio_alloc_context` read/seek callbacks. Mirrors `AVIOReader`'s
/// lifecycle so the `Demuxer` accepts it at the same seam used for HTTP.
///
/// `@unchecked Sendable`: the only mutable state touched across threads is
/// the close latches and the `context` pointer. `isClosed` is a plain Bool
/// written without a lock (a benign race: the read callback only needs to
/// eventually observe the flag to abort), matching AVIOReader's treatment.
/// The `context` pointer is written once under the engine's existing teardown
/// ordering (`markClosed` then `close`).
final class CustomIOReaderBridge: AVIOProvider, @unchecked Sendable {
    private let reader: IOReader
    /// Matches AVIOReader.avioBufferSize (256 KB) for parity.
    private static let bufferSize: Int32 = 256 * 1024
    private var buffer: UnsafeMutablePointer<UInt8>?
    private(set) var context: UnsafeMutablePointer<AVIOContext>?
    private var isClosed = false
    private var isFullyClosed = false
    private(set) var isSeekable: Bool = true

    /// The custom reader owns its own I/O accounting; the memory probe only
    /// meaningfully tracks network bytes, so report 0 here.
    var cumulativeBytesFetched: Int64 { 0 }

    init(reader: IOReader) {
        self.reader = reader
    }

    func open() throws {
        guard let buf = av_malloc(Int(Self.bufferSize)) else {
            throw AVIOReaderError.allocationFailed
        }
        buffer = buf.assumingMemoryBound(to: UInt8.self)

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = avio_alloc_context(
            buffer,
            Self.bufferSize,
            0,                       // read-only (write_flag = 0)
            opaque,
            customBridgeReadCallback,
            nil,                     // no write
            customBridgeSeekCallback
        ) else {
            av_free(buf)
            buffer = nil
            throw AVIOReaderError.allocationFailed
        }
        context = ctx

        // Probe seekability before any reads: SEEK_SET to 0 is a no-op for a
        // seekable reader (returns >= 0) and is refused by a forward-only one
        // (returns negative). Whence 0 == SEEK_SET. Safe here because the
        // reader is fresh at position 0; FFmpeg has not read anything yet.
        isSeekable = reader.seek(offset: 0, whence: 0) >= 0
    }

    func markClosed() {
        isClosed = true
        reader.cancel()
    }

    func close() {
        guard !isFullyClosed else { return }
        isFullyClosed = true
        isClosed = true
        if let ctx = context {
            // avio_context_free releases the struct but NOT ctx->buffer
            // (verified against aviobuf.c); the canonical pattern frees the
            // buffer first. Must free ctx.pointee.buffer, not our original
            // av_malloc pointer: FFmpeg can realloc the buffer internally
            // (ffio_set_buf_size), making the original pointer stale.
            av_free(ctx.pointee.buffer)
            avio_context_free(&context)
        }
        context = nil
        buffer = nil
        // The bridge does NOT own the reader. The engine (primary reader) or
        // the side path (clone reader) closes it. This decoupling lets the
        // engine reuse one reader across an internal reload and run clones
        // concurrently without a bridge teardown killing the source.
    }

    fileprivate func performRead(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        // -1 is an abort (mid-playback teardown), NOT a clean end-of-stream.
        // Mirrors AVIOReader.read, which returns -1 on isClosed and reserves
        // AVERROR_EOF for an actual EOF so FFmpeg does not run EOS handling
        // on a forced stop.
        guard !isClosed else { return -1 }
        let n = reader.read(buf, size: size)
        // IOReader's contract uses 0 for EOF; FFmpeg's avio expects
        // AVERROR_EOF and can spin on a literal 0. Map it.
        if n == 0 { return FFmpegErr.eof }
        return n
    }

    fileprivate func performSeek(offset: Int64, whence: Int32) -> Int64 {
        guard !isClosed else { return -1 }
        return reader.seek(offset: offset, whence: whence)
    }
}

// MARK: - C Callbacks


private func customBridgeReadCallback(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafeMutablePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return -1 }
    let bridge = Unmanaged<CustomIOReaderBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.performRead(into: buf, size: size)
}

private func customBridgeSeekCallback(
    opaque: UnsafeMutableRawPointer?,
    offset: Int64,
    whence: Int32
) -> Int64 {
    guard let opaque = opaque else { return -1 }
    let bridge = Unmanaged<CustomIOReaderBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.performSeek(offset: offset, whence: whence)
}
