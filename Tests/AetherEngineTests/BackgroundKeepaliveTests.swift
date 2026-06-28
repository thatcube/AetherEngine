import Testing
@testable import AetherEngine

/// Wedge-safe background keepalive policy (iOS): the video pipeline survives backgrounding ONLY while
/// the app stays genuinely running (PiP active, or actively playing for background audio), never across
/// an idle suspension. See AetherEngine.shouldKeepVideoAlive.
@Suite("Background keepalive policy")
struct BackgroundKeepaliveTests {

    @Test("keep alive while playing and enabled")
    func keepAliveWhilePlaying() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: true, pipActive: false, state: .playing) == true)
    }

    @Test("keep alive while PiP active even if paused")
    func keepAliveWhilePiP() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: true, pipActive: true, state: .paused) == true)
    }

    @Test("teardown when paused with no PiP")
    func teardownWhenPausedNoPiP() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: true, pipActive: false, state: .paused) == false)
    }

    @Test("teardown when background playback disabled")
    func teardownWhenDisabled() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: false, pipActive: true, state: .playing) == false)
    }
}
