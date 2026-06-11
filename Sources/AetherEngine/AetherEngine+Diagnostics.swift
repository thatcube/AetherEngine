import Foundation
import Darwin.Mach
import AVFoundation

extension AetherEngine {

    // MARK: - Memory diagnostic

    /// Start the periodic memory probe. Cancels any prior probe so a
    /// fresh `load(url:)` cycle starts a clean timeline. Drives one
    /// `EngineLog.emit` line every 30 s under the `.engine` category;
    /// the line shape is documented on `memoryProbeTask`.
    func startMemoryProbe() {
        memoryProbeTask?.cancel()
        let sessionStart = Date()
        memoryProbeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                guard let self = self else { return }
                let elapsed = Int(Date().timeIntervalSince(sessionStart))
                let rssMB = Self.residentMemoryMB()
                let cueCount = self.subtitleCues.count

                // AVPlayer-side buffer probe: how much content has the
                // native host's current AVPlayerItem actually loaded? If
                // this number balloons past `preferredForwardBufferDuration`,
                // AVPlayer is buffering more than we asked it to and is
                // a candidate for the linear-growth memory leak.
                var bufferAheadSec = 0.0
                var bufferBehindSec = 0.0
                if let avPlayer = self.currentAVPlayer,
                   let item = avPlayer.currentItem {
                    let now = item.currentTime().seconds
                    for value in item.loadedTimeRanges {
                        let range = value.timeRangeValue
                        let start = range.start.seconds
                        let end = (range.start + range.duration).seconds
                        if end > now { bufferAheadSec += end - max(start, now) }
                        if start < now { bufferBehindSec += min(end, now) - start }
                    }
                }

                // Pipeline counters from the native HLS engine. Zero
                // when the SW path is active (no HLSVideoEngine) or
                // pre-start. Read once per probe — fields are not
                // mutually atomic but the 30 s cadence makes drift
                // irrelevant for trend analysis.
                let stats = self.nativeVideoSession?.diagnosticStats()
                let avioMB = (stats?.avioBytesFetched ?? 0) / 1024 / 1024
                let cacheMB = (stats?.segmentCacheBytes ?? 0) / 1024 / 1024
                let cacheCount = stats?.segmentCacheCount ?? 0
                let packetsWritten = stats?.producerPacketsWritten ?? 0
                let audioFifo = stats?.audioFifoSamples ?? 0
                let abFifoKB = (stats?.audioBridgeFifoBytes ?? 0) / 1024
                let abSwrKB = (stats?.audioBridgeSwrBytes ?? 0) / 1024
                let abTotKB = (stats?.audioBridgeTotalBytes ?? 0) / 1024
                let muxBytesMB = (stats?.muxerLifetimeFragmentBytes ?? 0) / 1024 / 1024
                let muxCuts = stats?.muxerFragmentCuts ?? 0
                let srvConns = stats?.serverConnectionCount ?? 0
                let srvBytesMB = (stats?.serverLifetimeBytesSent ?? 0) / 1024 / 1024
                let srvSfMB = (stats?.serverSendfileBytesSent ?? 0) / 1024 / 1024
                let pktAlive = stats?.packetsAlive ?? 0
                let pktTotal = stats?.packetsTotalAllocs ?? 0

                // VM breakdown so the leak source is visible at probe
                // time: internal (Swift / libavformat heap) vs external
                // (mmap'd cache files, dyld) vs IOSurface (HEVC decoded
                // frames) vs compressed (kernel-compressed pages still
                // accounted to us).
                let vmStr: String
                if let vm = Self.vmBreakdownMB() {
                    vmStr = "vmInt=\(vm.internalMB)MB "
                        + "vmExt=\(vm.externalMB)MB "
                        + "vmCmp=\(vm.compressedMB)MB "
                        + "vmIOS=\(vm.iosurfaceMB)MB "
                        + "physFP=\(vm.physFootprintMB)MB "
                } else {
                    vmStr = ""
                }

                let mallocStr: String
                if let m = Self.mallocZoneSummary() {
                    mallocStr = "mallocBlocks=\(m.blocksInUse) mallocMB=\(m.sizeInUseMB) "
                } else {
                    mallocStr = ""
                }

                let line = "[AetherEngine] memprobe t=\(elapsed)s "
                    + "rss=\(rssMB)MB "
                    + vmStr
                    + mallocStr
                    + "avioFetchedMB=\(avioMB) "
                    + "cacheCount=\(cacheCount) cacheMB=\(cacheMB) "
                    + "packetsWritten=\(packetsWritten) "
                    + "audioFifo=\(audioFifo) "
                    + "abFifoKB=\(abFifoKB) abSwrKB=\(abSwrKB) abTotKB=\(abTotKB) "
                    + "muxBytesMB=\(muxBytesMB) muxCuts=\(muxCuts) "
                    + "srvConns=\(srvConns) srvBytesMB=\(srvBytesMB) srvSfMB=\(srvSfMB) "
                    + "pktAlive=\(pktAlive) pktTotal=\(pktTotal) "
                    + "subCues=\(cueCount) "
                    + "audioTracks=\(self.audioTracks.count) "
                    + "subTracks=\(self.subtitleTracks.count) "
                    + "subActive=\(self.isSubtitleActive) "
                    + "avBufAhead=\(String(format: "%.1f", bufferAheadSec))s "
                    + "avBufBehind=\(String(format: "%.1f", bufferBehindSec))s"

                EngineLog.emit(line, category: .engine)
            }
        }
    }

    /// Start the 1 Hz live-telemetry sampler. Cancels any prior sampler
    /// so a fresh `load(url:)` cycle starts a clean timeline. Mirrors
    /// `startMemoryProbe`'s lifecycle so the two diagnostic surfaces
    /// share the same start + stop hooks.
    func startLiveTelemetrySampler() {
        liveTelemetrySampler?.stop()
        let sampler = LiveTelemetrySampler(engine: self)
        liveTelemetrySampler = sampler
        sampler.start()
    }

    /// Resident memory footprint of the current process in MB, read via
    /// `mach_task_basic_info`. Returns 0 on error. Cheap to call (no
    /// allocations) and safe from any thread.
    static func residentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / 1024 / 1024)
    }

    /// Detailed VM breakdown via `task_vm_info`. Splits the process's
    /// phys_footprint (jetsam-accounted bytes) into the buckets the
    /// kernel tracks separately:
    ///
    ///   internal:   anonymous memory — heap, stack, NSData backing,
    ///               anything malloc'd
    ///   external:   file-backed memory — mmap'd files, dyld text/data,
    ///               our SegmentCache reads via `.alwaysMapped`
    ///   compressed: pages the kernel compressed under pressure (still
    ///               counted against the process footprint)
    ///   iosurfaces: IOSurface-backed device memory (decoded video
    ///               frames, AVPlayer's HEVC reference pool)
    ///
    /// Surfaced in the 30 s memprobe line so memory-growth investigations
    /// can see which bucket moved between samples.
    static func vmBreakdownMB() -> (internalMB: Int,
                                    externalMB: Int,
                                    compressedMB: Int,
                                    iosurfaceMB: Int,
                                    physFootprintMB: Int)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (
            internalMB: Int(info.internal / 1024 / 1024),
            externalMB: Int(info.external / 1024 / 1024),
            compressedMB: Int(info.compressed / 1024 / 1024),
            iosurfaceMB: Int(info.device / 1024 / 1024),
            physFootprintMB: Int(info.phys_footprint / 1024 / 1024)
        )
    }

    /// Malloc-zone statistics for the default zone. `blocks_in_use`
    /// counts how many distinct allocations currently exist;
    /// `size_in_use` is their total bytes. Surfaced in the memprobe so
    /// we can tell whether vmInt growth is many small allocations
    /// leaking (block count climbs linearly) versus a single large
    /// buffer growing (block count flat, size up). Passing `nil` to
    /// malloc_zone_statistics asks libmalloc to sum across all zones
    /// it manages — equivalent to iterating malloc_get_all_zones
    /// without the pointer-cast gymnastics.
    static func mallocZoneSummary() -> (blocksInUse: Int, sizeInUseMB: Int)? {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (blocksInUse: Int(stats.blocks_in_use),
                sizeInUseMB: Int(stats.size_in_use / 1024 / 1024))
    }

    // MARK: - Live telemetry bridge

    /// Apply a fresh `LiveTelemetry` snapshot to the `@Published` mirror
    /// on `diagnostics`. Kept as the single write-through point so the
    /// sampler does not reach into `EngineDiagnostics` directly.
    func applyLiveTelemetry(_ snapshot: LiveTelemetry) {
        diagnostics.liveTelemetry = snapshot
    }


    /// Bytes the active demuxer has fetched from the source. Mirrors
    /// `Demuxer.avioBytesFetched` via HLSVideoEngine's existing
    /// diagnostic surface. Used by `LiveTelemetrySampler` for instant
    /// + average bitrate. Returns 0 on the SW path or pre-start.
    var demuxerBytesFetched: Int64 {
        nativeVideoSession?.demuxerBytesFetched ?? 0
    }

    /// Total resident bytes in the loopback HLS segment cache, or `nil`
    /// when no native session is active.
    var cachedBytes: Int64? {
        guard let bytes = nativeVideoSession?.segmentCacheTotalBytes else { return nil }
        return Int64(bytes)
    }

    /// Authoritative on-disk byte footprint of the loopback HLS segment
    /// cache (freshly stat-ed resident files), or `nil` when no native
    /// session is active. Public so the `aetherctl live --report-cache-
    /// bytes` harness can verify the live window keeps disk bounded.
    public var segmentCacheDiskBytes: Int64? {
        nativeVideoSession?.segmentCacheDiskBytes
    }

    /// Lifetime count of frames the SW host has enqueued into its
    /// AVSampleBufferDisplayLayer. Zero on the native path or pre-start.
    var softwareHostFramesEnqueued: Int {
        softwareHost?.framesEnqueued ?? 0
    }

    /// Number of producer restart sessions in the current session. Zero
    /// on the SW path or pre-start.
    var producerRestartCount: Int {
        nativeVideoSession?.producerRestartCount ?? 0
    }

    /// Lifetime bytes emitted by the active MP4SegmentMuxer.
    var muxedBytesLifetime: Int64 {
        Int64(nativeVideoSession?.muxedBytesLifetime ?? 0)
    }

    /// Lifetime bytes the loopback HLS server has written to AVPlayer.
    var serverBytesSentLifetime: Int64 {
        Int64(nativeVideoSession?.serverLifetimeBytesSent ?? 0)
    }

    /// Number of HTTP requests served by the loopback HLS server.
    var serverRequestCount: Int {
        nativeVideoSession?.serverRequestCount ?? 0
    }

    /// Bytes currently held in `AudioBridge`'s FIFO + swr-delay buffers.
    /// Zero when the bridge isn't live (stream-copy audio path or
    /// video-only source).
    var audioBridgeLiveBytes: Int {
        nativeVideoSession?.audioBridgeLiveBytes ?? 0
    }

    /// Most recently measured audio/video gate gap in source-clock
    /// milliseconds. 0 until the first audio gate opens.
    var lastAVGapMs: Double {
        nativeVideoSession?.lastAVGapMs ?? 0
    }
}
