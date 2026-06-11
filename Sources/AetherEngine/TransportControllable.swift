import Foundation

/// Common transport surface of the four playback hosts
/// (`NativeAVPlayerHost`, `SoftwarePlaybackHost`, `AudioPlaybackHost`,
/// `AudioAVPlayerHost`), so `AetherEngine` resolves "who owns
/// transport" in exactly ONE place (`activeTransportHost`) instead of
/// repeating the priority cascade per entry point. The cascades had
/// already drifted once: the volume setter wrote into every host,
/// including the persistent inactive audio host, silently changing the
/// NEXT music session's volume.
@MainActor
protocol TransportControllable: AnyObject {
    func play()
    func pause()
    func setRate(_ rate: Float)
    var volume: Float { get set }
}

extension SoftwarePlaybackHost: TransportControllable {}
extension AudioPlaybackHost: TransportControllable {}
extension AudioAVPlayerHost: TransportControllable {}
extension NativeAVPlayerHost: TransportControllable {}
