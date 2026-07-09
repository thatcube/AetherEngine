import Foundation
import Libavformat

/// Abstraction over a custom-AVIO byte source attached to `AVFormatContext.pb`.
/// `AVIOReader` (HTTP) and `CustomIOReaderBridge` (custom `IOReader`) both conform.
protocol AVIOProvider: AnyObject {
    /// Allocated `AVIOContext`, valid between `open()` and `close()`.
    var context: UnsafeMutablePointer<AVIOContext>? { get }

    /// Bytes fetched since open (memory-probe use). Custom readers that do not
    /// track network I/O report 0.
    var cumulativeBytesFetched: Int64 { get }

    /// Forward-only sources report false; keeps them off the native seek path.
    var isSeekable: Bool { get }

    func open() throws

    /// Fast, allocation-free: unblock a suspended read so the demuxer's access
    /// lock can be acquired during teardown. Call before `close()`.
    func markClosed()

    /// #112 round 9: wall-clock deadline for reads, armed around a bounded positioning seek so an
    /// index-less container's read_timestamp binary search aborts instead of parking for minutes on a
    /// starved source. Checked between read callbacks (demux-thread-only, same contract as AVIOReader's
    /// #27 deadline); one in-flight blocking read can overshoot by its own transport timeout.
    func beginReadDeadline(secondsFromNow seconds: TimeInterval)

    /// Disarm the deadline armed by `beginReadDeadline`.
    func endReadDeadline()

    /// #112 round 11: reversible cross-thread read abort. A successor side reader calls this so a
    /// predecessor wedged inside a bounded positioning seek returns at the next read-callback boundary
    /// (latching `readDeadlineFired`) instead of riding out its budget, WITHOUT killing the provider the
    /// way `markClosed` does: the demuxer stays warm and reusable. One-shot; survives a
    /// `beginReadDeadline` re-arm (so it wins the disarm/re-arm race) and is cleared explicitly by the
    /// successor at acquisition via `clearReadAbort`.
    func requestReadAbort()

    /// Clear a pending `requestReadAbort` so the caller's own positioning reads run normally.
    func clearReadAbort()

    /// True when a read aborted because the deadline passed. Authoritative over the seek's return
    /// value: matroska can report success on a partial index after an abort.
    var readDeadlineFired: Bool { get }

    /// #112 round 9: total byte size of the stream the demuxer sees (Content-Length for HTTP, the
    /// virtual concat length for a disc adapter), nil until/unless known. Backs the byte-estimate
    /// seek fallback when a timestamp seek times out on an index-less container.
    var resolvedByteSize: Int64? { get }

    /// Free the `AVIOContext` and release the underlying source. Idempotent.
    func close()
}
