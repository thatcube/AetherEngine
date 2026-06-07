import Foundation

/// A keyframe-indexed, disk-spooled sliding-window ring of compressed
/// packets for the software-decode DVR rewind buffer.
///
/// Packets arrive forward-only from the demux loop via `append`. Old
/// packets are evicted once they fall outside `windowSeconds` behind the
/// current edge, but eviction never cuts to a non-keyframe: the retained
/// span always starts at a decodable keyframe. Rewind reads packets back
/// via `packets(fromPts:)`, which rehydrates bytes from disk lazily.
///
/// Disk layout mirrors SegmentCache: each packet is written as a flat
/// file under the caller-supplied scratch directory, named by a
/// monotonically increasing counter. The in-RAM index holds only the
/// metadata tuple; actual bytes are read back through
/// `Data(contentsOf:, options: .alwaysMapped)` so the kernel manages
/// paging without inflating the process RSS.
///
/// Thread-safety: a single NSLock guards the index. The real caller
/// appends on the demux thread and reads on the seek thread; all public
/// methods lock on entry.
final class PacketRingBuffer {

    // MARK: - Public types

    /// A single packet as returned by `packets(fromPts:)`.
    struct Packet {
        let pts: Double
        let isKeyframe: Bool
        let bytes: Data
    }

    // MARK: - Private types

    private struct Entry {
        let pts: Double
        let isKeyframe: Bool
        let fileURL: URL
        let byteCount: Int
    }

    // MARK: - State

    private let lock = NSLock()
    private let windowSeconds: Double
    private let scratch: URL

    /// Ordered by pts (append-order; pts is expected to be monotonically
    /// non-decreasing from the demux loop).
    private var entries: [Entry] = []

    /// Monotonic counter used to produce unique file names.
    private var counter: Int = 0

    /// Highest pts seen so far (the live edge of the buffer).
    private var edge: Double = -.infinity

    // MARK: - Init / close

    /// Create a new ring buffer.
    /// - Parameters:
    ///   - windowSeconds: How many seconds of packets to retain behind
    ///     the current edge. Eviction is keyframe-aligned: the oldest
    ///     retained packet is the newest keyframe at or before
    ///     `edge - windowSeconds`.
    ///   - scratch: A caller-managed directory to hold packet files.
    ///     The caller is responsible for creating it; `close()` removes
    ///     its contents and the directory itself.
    init(windowSeconds: Double, scratch: URL) throws {
        self.windowSeconds = windowSeconds
        self.scratch = scratch
    }

    /// Remove all packet files and clear the index. Safe to call from
    /// any thread.
    func close() {
        lock.lock()
        let toDelete = entries.map(\.fileURL)
        entries.removeAll(keepingCapacity: false)
        edge = -.infinity
        counter = 0
        lock.unlock()

        for url in toDelete {
            try? FileManager.default.removeItem(at: url)
        }
        // Best-effort remove the scratch dir itself (may still have
        // stale files from a previous close or partial write).
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Writer

    /// Append a compressed packet to the ring.
    /// - Parameters:
    ///   - pts: Presentation timestamp in seconds.
    ///   - isKeyframe: Whether this packet starts a decodable group.
    ///   - bytes: Raw compressed packet bytes.
    func append(pts: Double, isKeyframe: Bool, bytes: Data) throws {
        // Write to disk outside the lock so we don't block readers.
        let fileURL = scratch.appendingPathComponent("pkt-\(nextCounter()).bin")
        try bytes.write(to: fileURL, options: [.atomic])
        let entry = Entry(pts: pts, isKeyframe: isKeyframe, fileURL: fileURL, byteCount: bytes.count)

        lock.lock()
        defer {
            evict()
            lock.unlock()
        }
        entries.append(entry)
        if pts > edge { edge = pts }
    }

    // MARK: - Reader

    /// The newest keyframe pts at or before `target`, or nil if none
    /// exists in the current window.
    func keyframePts(atOrBefore target: Double) throws -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries
            .filter { $0.isKeyframe && $0.pts <= target }
            .last
            .map(\.pts)
    }

    /// All packets with `pts >= pts`, in order, with bytes read from
    /// disk.
    func packets(fromPts startPts: Double) throws -> [Packet] {
        lock.lock()
        let slice = entries.filter { $0.pts >= startPts }
        lock.unlock()

        return try slice.map { entry in
            let data = try Data(contentsOf: entry.fileURL, options: [.alwaysMapped, .uncached])
            return Packet(pts: entry.pts, isKeyframe: entry.isKeyframe, bytes: data)
        }
    }

    // MARK: - Diagnostics

    /// PTS of the oldest retained packet, or nil when the buffer is empty.
    var oldestPts: Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first.map(\.pts)
    }

    /// PTS of the newest retained packet, or nil when the buffer is empty.
    var newestPts: Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last.map(\.pts)
    }

    // MARK: - Internal

    private func nextCounter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let c = counter
        counter += 1
        return c
    }

    /// Drop leading entries outside the retention window, keeping the
    /// retained span keyframe-aligned. Must be called with `lock` held.
    ///
    /// Algorithm:
    ///   cutoff = edge - windowSeconds
    ///   Find the newest keyframe whose pts <= cutoff.
    ///   If such a keyframe exists, drop everything STRICTLY before it
    ///   (i.e. the keyframe itself is the new oldest entry).
    ///   If no such keyframe exists, keep everything.
    ///
    /// This guarantees `oldestPts` is always a keyframe pts that is <=
    /// cutoff (when the buffer is large enough), so a decoder starting
    /// from `oldestPts` always begins at a clean access point.
    private func evict() {
        let cutoff = edge - windowSeconds
        // Find the newest keyframe at or before cutoff.
        guard let pivotIndex = entries.indices.last(where: {
            entries[$0].isKeyframe && entries[$0].pts <= cutoff
        }) else {
            // No evictable keyframe anchor found; retain everything.
            return
        }
        // Drop everything strictly before the pivot keyframe.
        let toRemove = entries[..<pivotIndex]
        let urls = toRemove.map(\.fileURL)
        entries.removeSubrange(..<pivotIndex)

        // Delete the evicted files outside the hot path (best-effort;
        // still inside the lock to keep accounting consistent, but the
        // files are small and the delete is fast).
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
