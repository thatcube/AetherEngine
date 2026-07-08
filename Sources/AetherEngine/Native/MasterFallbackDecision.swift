import Foundation

/// A display rejecting the served HLS master playlist: the `AVPlayerItem` failed with a
/// display-incompatibility error. `-11868` (AVErrorNoCompatibleAlternatesForExternalDisplay) is the
/// iOS external-SDR-monitor case; `-11848` is an HDR master shipped to an SDR-parked panel.
struct DisplayRejection: Sendable, Equatable {
    let code: Int
    let message: String
}

/// Pure master to media fallback decision (#98). Kept separate and pure so the gate is testable
/// offline, matching the style of `ItemDeathReviveGate`. On an actual master rejection, reload the
/// bare media playlist (SDR-tone-mappable) instead of hard-failing.
///
/// An SDR-signalled master was tried (Stage 1.5) and reverted: forcing VIDEO-RANGE=SDR on HDR/DV
/// content does not fool the external-display compatibility gate (it checks the real colr/codec, not
/// the manifest string), so HDR/DV on an SDR external display stays media-playlist-driven, which drops
/// the subtitle renditions. Subtitles there are a separate host effort (overlay on the external
/// UIScreen). The #35 gate still reloads an HDR-preserving reduced master (source range kept, DV
/// dropped) because that variant is truthful and only serves an HDR panel.
enum MasterFallbackDecision {

    /// The two AVFoundationErrorDomain codes that mean "this display cannot present the master".
    static func isDisplayRejectionCode(_ code: Int) -> Bool {
        code == -11868 || code == -11848
    }

    /// Fall back to the media playlist only when a display-rejection failed the item, the engine was
    /// serving the master, and this session has not already fallen back (single-shot, no loop).
    static func shouldFallBackToMediaPlaylist(
        errorCode: Int, servingMasterPlaylist: Bool, alreadyFellBack: Bool
    ) -> Bool {
        isDisplayRejectionCode(errorCode) && servingMasterPlaylist && !alreadyFellBack
    }
}
