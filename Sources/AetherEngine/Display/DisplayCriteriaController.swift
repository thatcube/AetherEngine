import Foundation
import CoreMedia
import CoreVideo
import AVFoundation

#if canImport(UIKit)
import UIKit
#endif

#if os(tvOS)
import AVKit
#endif

/// HDMI HDR-mode handshake via AVDisplayManager (tvOS 11.2+). Programs AVDisplayCriteria before playback so the panel finishes its mode negotiation before the first frame. No-op stub on iOS/macOS. Lifted from Sodalite's PlayerViewModel so the engine owns the handshake; hosts no longer touch UIWindow.avDisplayManager.
@MainActor
final class DisplayCriteriaController {

    /// Override window discovery. Default walks connectedScenes and picks the first window; multi-window or custom-presentation hosts can supply their own resolver here.
    nonisolated(unsafe) static var windowProvider: (@MainActor () -> Any?)?

    /// Whether apply() wrote preferredDisplayCriteria this session. reset() is gated on this so AVKit-sole-writer hosts (LoadOptions.suppressDisplayCriteria=true) get zero engine writes; a nil write on a suppressed session races AVKit's in-flight criteria and collapsed EDR headroom to 1.0 (DrHurt#4 Build 176).
    private var didApply: Bool = false

    /// True when the last apply() set HDR color extensions. waitForSwitch uses this to distinguish a legitimate SDR rate-only settle (headroom 1.0 expected) from an HDR handshake failure (headroom 1.0 is wrong).
    private var lastCriteriaWasHDR: Bool = false

    init() {}

    /// Program AVDisplayCriteria before the session starts. `.sdr` programs a rate-only criteria so Match Frame Rate still engages. `codecTag` nil derives from format (`'dvh1'` for DV, `'hvc1'` otherwise). `omitColorExtensions` skips BT.2020 extensions for diagnostic builds. Returns true when a dynamic-range switch is expected (caller should call waitForSwitch).
    @discardableResult
    func apply(format: VideoFormat, frameRate: Double?, codecTag: FourCharCode?, omitColorExtensions: Bool) -> Bool {
        #if os(tvOS)
        // Reset up front so a skipped apply (Match Content off, no window)
        // can't leave a prior HDR session's flag for waitForSwitch to read.
        lastCriteriaWasHDR = false
        guard #available(tvOS 17.0, *) else {
            EngineLog.emit("[DisplayCriteria] skipped: tvOS < 17", category: .engine)
            return false
        }

        guard let window = resolveWindow() else {
            EngineLog.emit("[DisplayCriteria] skipped: no window", category: .engine)
            return false
        }

        let displayManager = window.avDisplayManager

        // isDisplayCriteriaMatchingEnabled covers both Match Dynamic Range and Match Frame Rate; tvOS picks the applicable dimension internally.
        guard displayManager.isDisplayCriteriaMatchingEnabled else {
            EngineLog.emit("[DisplayCriteria] skipped: Match Content disabled (both Dynamic Range AND Frame Rate off)", category: .engine)
            return false
        }

        // HDR sources attach BT.2020 + transfer + matrix extensions; SDR carries only codec + rate so Match Frame Rate can engage without Match Dynamic Range (DrHurt #4: previously early-returned for SDR and Match Frame Rate never fired).
        let isHDR = (format != .sdr)
        let transferFunction: CFString = switch format {
        case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default:   kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        }
        let extensions: NSDictionary? = (isHDR && !omitColorExtensions) ? [
            kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: transferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
        ] : nil

        // Codec FourCC drives the HDMI mode: 'hvc1' -> HDR10/HLG, 'dvh1' -> Dolby Vision. Using HEVC for a DV source kept DrHurt's Philips panel in HDR10 instead of DV (P8 MKV). ref: Jellyfin #16179, KSPlayer #633.
        let dvh1: FourCharCode = 0x64766831
        let codecType: CMVideoCodecType = codecTag ?? (format == .dolbyVision ? dvh1 : kCMVideoCodecType_HEVC)

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: 3840, height: 2160,
            extensions: extensions,
            formatDescriptionOut: &formatDesc
        )
        guard let desc = formatDesc else { return false }

        // Always pass the real rate; tvOS uses it when Match Frame Rate is on, ignores it otherwise (dynamic-range switch still fires).
        let effectiveRate = Float(frameRate ?? 24.0)
        let criteria = AVDisplayCriteria(refreshRate: effectiveRate, formatDescription: desc)
        displayManager.preferredDisplayCriteria = criteria
        didApply = true
        lastCriteriaWasHDR = isHDR

        EngineLog.emit(
            "[DisplayCriteria] SET: format=\(format) codec=\(fourccString(codecType)) "
            + "rate=\(frameRate.map { String(format: "%.3f", $0) } ?? "default(24)") "
            + "extensions=\(extensions != nil ? "HDR" : "none")",
            category: .engine
        )
        // SDR rate-only switches are sub-second; only HDR criteria need the waitForSwitch delay.
        return isHDR
        #else
        return false
        #endif
    }

    /// Block until the panel finishes its HDR mode negotiation, or up to ~5s.
    ///
    /// Two-stage poll: (1) start phase 1000ms/10ms ticks -- the HDMI handshake initiates asynchronously after the preferredDisplayCriteria write, so isDisplayModeSwitchInProgress can be false for a beat (old single-check guard let asset.load race on DV8.1 -> AVPlayer -11848). AVKit-sole-writer path also fires later, so 1000ms gives headroom. Early-return if EDR headroom is already > 1.001 (panel already in HDR). (2) settle phase 50 x 100ms; sanity-checks headroom after the switch clears.
    func waitForSwitch() async {
        #if os(tvOS)
        guard let window = resolveWindow() else { return }
        let displayManager = window.avDisplayManager
        let screen = window.screen

        // Fast exit: panel already in HDR (headroom already raised, e.g. a prior HDR/DV session).
        if screen.currentEDRHeadroom > 1.001 {
            EngineLog.emit("[DisplayCriteria] no switch needed (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) at entry)", category: .engine)
            return
        }

        // The OS mode-switch-end notification is the authoritative "settled" signal
        // WHEN the panel reports it. But on some panels a Dolby Vision switch is
        // effectively unobservable to the app: `currentEDRHeadroom` stays 1.0 and
        // `isDisplayModeSwitchInProgress` can stick `true` even though the panel
        // visibly enters DV. So we watch every available signal AND bound the wait,
        // rather than polling one flag for a fixed 5s (which made every DV load wait
        // the full timeout — twice, ~10s to first frame).
        let switchEnded = SwitchFlag()
        // `AVDisplayManagerModeSwitchEndNotification` (tvOS 11.3+); referenced by
        // raw name to avoid Swift import-form ambiguity across SDKs.
        let endToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVDisplayManagerModeSwitchEndNotification"),
            object: displayManager, queue: nil
        ) { _ in switchEnded.fire() }
        defer { NotificationCenter.default.removeObserver(endToken) }

        // Stage 1: up to 1000ms for a switch to actually start (AVKit's sole-writer
        // path fires the criteria write later than the engine pre-flight).
        var sawSwitchStart = false
        for _ in 0..<100 {
            if switchEnded.fired || screen.currentEDRHeadroom > 1.001 {
                EngineLog.emit("[DisplayCriteria] settled during start phase (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                return
            }
            if displayManager.isDisplayModeSwitchInProgress { sawSwitchStart = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !sawSwitchStart {
            // No switch started within 1000ms: panel already satisfies the criteria
            // or the setter was a no-op. Don't block; AVPlayer tonemaps or errors for real.
            EngineLog.emit("[DisplayCriteria] no switch started (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) after 1000ms); proceeding", category: .engine)
            return
        }

        // Stage 2: proceed as soon as ANY reliable signal says settled — mode-switch-end
        // notification, EDR headroom rising (HDR10/HLG), or the in-progress flag
        // clearing — else a bounded 2s cap so an unobservable DV switch (visible on the
        // panel but silent to the app) can't gate the first frame for the old 5s.
        let capTicks = 40  // 40 × 50ms = 2000ms
        for tick in 0..<capTicks {
            try? await Task.sleep(for: .milliseconds(50))
            let elapsed = (tick + 1) * 50 + 1000
            if switchEnded.fired {
                EngineLog.emit("[DisplayCriteria] switch settled via modeSwitchEnd (~\(elapsed)ms)", category: .engine)
                return
            }
            if screen.currentEDRHeadroom > 1.001 {
                EngineLog.emit("[DisplayCriteria] switch settled via EDR (~\(elapsed)ms, headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                return
            }
            if !displayManager.isDisplayModeSwitchInProgress {
                EngineLog.emit("[DisplayCriteria] switch in-progress cleared (~\(elapsed)ms, EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                return
            }
        }
        EngineLog.emit("[DisplayCriteria] proceed after ~\(capTicks * 50 + 1000)ms cap (switch not observable — likely DV; EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
        #endif
    }

    /// True when UIScreen.currentEDRHeadroom > 1.001 after apply() + waitForSwitch() settle. Reading headroom post-settle is the only authoritative way to distinguish Match Dynamic Range ON vs. rate-only (no public per-sub-toggle API).
    func currentPanelIsHDR() -> Bool {
        #if os(tvOS)
        guard let window = resolveWindow() else { return false }
        return window.screen.currentEDRHeadroom > 1.001
        #else
        return false
        #endif
    }

    /// Nil-out preferredDisplayCriteria to return the panel to default. No-op when apply() was never called this session (suppressed host) to avoid racing AVKit's in-flight criteria management.
    func reset() {
        #if os(tvOS)
        guard didApply else { return }
        guard let window = resolveWindow() else {
            didApply = false
            return
        }
        window.avDisplayManager.preferredDisplayCriteria = nil
        didApply = false
        EngineLog.emit("[DisplayCriteria] RESET", category: .engine)
        #endif
    }

    // MARK: - Window resolution

    #if os(tvOS)
    private func resolveWindow() -> UIWindow? {
        if let provider = Self.windowProvider, let win = provider() as? UIWindow {
            return win
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first
    }

    #endif
}

/// Thread-safe one-shot flag used to hand a display mode-switch-end notification
/// from the observer callback into `waitForSwitch`'s polling loop. (The module
/// targets strict concurrency, so a plain captured `var` isn't `Sendable`.)
private final class SwitchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func fire() { lock.lock(); value = true; lock.unlock() }
}
