import Foundation
import AetherEngine

// MARK: - dovitest

/// Validate `DoviRpuConverter.convertPacketToProfile81` against dovi_tool
/// ground truth. Walks the source's HEVC video stream, converts every
/// packet's DV metadata from Profile 7 to Profile 8.1, and writes the
/// result to /tmp/aetherctl-dovitest.hevc in Annex-B form so it can be
/// fed to `dovi_tool extract-rpu`.
func runDoviTest(url: URL) -> Int32 {
    let outputPath = "/tmp/aetherctl-dovitest.hevc"
    print("aetherctl dovitest: \(url.absoluteString)")
    print("output: \(outputPath)")
    print("")

    let result: DoviConvertProbeResult
    do {
        result = try AetherEngine.doviConvertProbe(url: url, outputPath: outputPath)
    } catch {
        print("ERROR: \(error)")
        return 1
    }

    guard result.videoStreamFound else {
        print("VERDICT: dovitest FAIL: no video stream in source.")
        return 2
    }

    print("=== DOVI CONVERT RESULT ===")
    print("Packets processed:    \(result.packetsProcessed)")
    print("Conversions:          \(result.conversions)")
    print("Failures:             \(result.failures)")
    print("Output (Annex-B):     \(result.outputPath)")
    print("===========================")
    print("")

    if result.failures > 0 {
        print("VERDICT: dovitest had \(result.failures) converter failure(s).")
        print("         Validate the surviving RPUs against dovi_tool, then debug:")
        print("           dovi_tool extract-rpu -i \(outputPath) -o /tmp/host.rpu")
        print("           dovi_tool info -i /tmp/host.rpu -f 0")
        return 3
    }

    print("VERDICT: converted \(result.conversions) packet(s) to Profile 8.1.")
    print("         Validate against dovi_tool ground truth:")
    print("           dovi_tool extract-rpu -i \(outputPath) -o /tmp/host.rpu")
    print("           dovi_tool info -i /tmp/host.rpu -f 0 | grep -iE 'dovi_profile|disable_residual|rpu_data_crc32'")
    return 0
}
