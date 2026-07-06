import Testing
import Foundation
@testable import AetherEngine

/// #93 residual (rrgomes, 8aed0db retest): a wedged-restart reopen queued behind the origin's other
/// connections to the same file (device: `response headers after 13121ms`, server-side connection
/// queuing). With subtitles on, the elective overlay side reader holds one of the origin's limited
/// connection slots throughout the reopen. The reader now defers its origin I/O while a producer
/// restart is in flight (mirroring the native readers' deferral), freeing a slot for the reopen; the
/// pump tap covers the produced region meanwhile. Bounded so a stuck restart never pins the reader.
@MainActor
struct Issue93SubtitleReaderDeferralTests {

    /// Observable completion latch for the async deferral under timed assertions.
    private actor SettleFlag {
        private(set) var settled = false
        func mark() { settled = true }
        var value: Bool { settled }
    }

    @Test("the reader does not defer when no restart is in flight")
    func immediateWhenIdle() async throws {
        let engine = try AetherEngine()
        engine.testHookRestartInFlightOverride = false
        let flag = SettleFlag()
        let waiter = Task { await engine.awaitRestartSettledForSubtitleReader(); await flag.mark() }
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(await flag.value == true)   // returned promptly, no deferral
        _ = await waiter.value
    }

    @Test("the reader defers while a restart is in flight and resumes once it settles")
    func defersThenResumes() async throws {
        let engine = try AetherEngine()
        engine.testHookRestartInFlightOverride = true
        let flag = SettleFlag()
        let waiter = Task { await engine.awaitRestartSettledForSubtitleReader(); await flag.mark() }
        try await Task.sleep(nanoseconds: 450_000_000)
        #expect(await flag.value == false)  // still deferring while the restart is in flight
        engine.testHookRestartInFlightOverride = false
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(await flag.value == true)   // resumed within one poll cycle of the restart settling
        _ = await waiter.value
    }
}
