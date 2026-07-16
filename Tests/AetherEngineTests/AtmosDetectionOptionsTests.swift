import Testing
@testable import AetherEngine

/// Pure unit tests for the bounded EAC3/JOC decode pass's control-flow logic (cap selection, track-target
/// resolution, and the authoritative-Atmos truth table). No real media / decoder needed: these exercise the
/// same seams `AetherEngine.detectAtmos` calls internally, per the "no redistributable Atmos fixture" note --
/// the actual decode plumbing is covered separately in `AtmosDetectionProbeIntegrationTests` against a
/// synthesized (non-Atmos) EAC3 fixture.
@Suite("AtmosDetectionOptions defaults + bounded decode cap selection")
struct AtmosDetectionOptionsTests {

    // MARK: - AtmosDetectionOptions defaults

    @Test("default options: no explicit track, generous-but-finite caps")
    func defaultOptions() {
        let options = AtmosDetectionOptions()
        #expect(options.targetTrackID == nil)
        #expect(options.maxPackets == 64)
        #expect(options.maxBytes == 8 * 1024 * 1024)
        #expect(options.timeBudget == 2.0)
    }

    @Test("options are independently overridable")
    func customOptions() {
        let options = AtmosDetectionOptions(targetTrackID: 3, maxPackets: 10, maxBytes: 1024, timeBudget: 0.5)
        #expect(options.targetTrackID == 3)
        #expect(options.maxPackets == 10)
        #expect(options.maxBytes == 1024)
        #expect(options.timeBudget == 0.5)
    }

    // MARK: - atmosDecodeTargetIndex (explicit override vs demuxer default)

    @Test("nil targetTrackID resolves the demuxer's own default audio stream")
    func targetIndexDefaultsToDemuxerPick() {
        let options = AtmosDetectionOptions()
        let resolved = AetherEngine.atmosDecodeTargetIndex(options: options, defaultAudioStreamIndex: 2)
        #expect(resolved == 2)
    }

    @Test("an explicit targetTrackID always wins over the demuxer default")
    func explicitTargetWinsOverDefault() {
        let options = AtmosDetectionOptions(targetTrackID: 5)
        let resolved = AetherEngine.atmosDecodeTargetIndex(options: options, defaultAudioStreamIndex: 2)
        #expect(resolved == 5)
    }

    @Test("an explicit targetTrackID of 0 still wins (not confused with the nil/default case)")
    func explicitZeroTargetWins() {
        let options = AtmosDetectionOptions(targetTrackID: 0)
        let resolved = AetherEngine.atmosDecodeTargetIndex(options: options, defaultAudioStreamIndex: 4)
        #expect(resolved == 0)
    }

    @Test("no default audio stream (-1) surfaces unchanged when no override is given")
    func noAudioStreamPropagatesAsNegativeOne() {
        let options = AtmosDetectionOptions()
        let resolved = AetherEngine.atmosDecodeTargetIndex(options: options, defaultAudioStreamIndex: -1)
        #expect(resolved == -1)
    }

    // MARK: - atmosDecodeCapReached (packet / byte / time cap priority)

    @Test("no cap reached while within every budget")
    func noCapWithinBudget() {
        let options = AtmosDetectionOptions(maxPackets: 64, maxBytes: 1_000_000, timeBudget: 2.0)
        let cap = AetherEngine.atmosDecodeCapReached(packetsRead: 5, bytesRead: 1000, elapsed: 0.1, options: options)
        #expect(cap == nil)
    }

    @Test("packet cap fires at the exact threshold, checked first")
    func packetCapFiresAtThreshold() {
        let options = AtmosDetectionOptions(maxPackets: 10, maxBytes: 1_000_000, timeBudget: 100)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 9, bytesRead: 0, elapsed: 0, options: options) == nil)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 10, bytesRead: 0, elapsed: 0, options: options) == .packetCap)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 11, bytesRead: 0, elapsed: 0, options: options) == .packetCap)
    }

    @Test("byte cap fires at the exact threshold when packets are still under budget")
    func byteCapFiresAtThreshold() {
        let options = AtmosDetectionOptions(maxPackets: 1000, maxBytes: 4096, timeBudget: 100)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 1, bytesRead: 4095, elapsed: 0, options: options) == nil)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 1, bytesRead: 4096, elapsed: 0, options: options) == .byteCap)
    }

    @Test("time cap fires at the exact threshold when packets and bytes are still under budget")
    func timeCapFiresAtThreshold() {
        let options = AtmosDetectionOptions(maxPackets: 1000, maxBytes: 1_000_000, timeBudget: 1.5)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 1, bytesRead: 0, elapsed: 1.49, options: options) == nil)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 1, bytesRead: 0, elapsed: 1.5, options: options) == .timeCap)
    }

    @Test("packet cap takes priority over byte and time caps when several are simultaneously exceeded")
    func packetCapHasPriority() {
        let options = AtmosDetectionOptions(maxPackets: 5, maxBytes: 10, timeBudget: 0.01)
        let cap = AetherEngine.atmosDecodeCapReached(packetsRead: 5, bytesRead: 100, elapsed: 10, options: options)
        #expect(cap == .packetCap)
    }

    @Test("byte cap takes priority over time cap when both are exceeded but packets are not")
    func byteCapHasPriorityOverTime() {
        let options = AtmosDetectionOptions(maxPackets: 1000, maxBytes: 10, timeBudget: 0.01)
        let cap = AetherEngine.atmosDecodeCapReached(packetsRead: 1, bytesRead: 100, elapsed: 10, options: options)
        #expect(cap == .byteCap)
    }

    // MARK: - AtmosDetectionOutcome.confirmedAtmos truth table

    @Test("confirmedAtmos is true only for a decoded frame with profile 30")
    func confirmedAtmosTrueOnJOCProfile() {
        let outcome = AtmosDetectionOutcome(stopReason: .frameDecoded, packetsRead: 3, bytesRead: 900, decodedProfile: 30)
        #expect(outcome.confirmedAtmos == true)
    }

    @Test("a decoded frame with a non-30 profile (plain EAC3) is never Atmos")
    func confirmedAtmosFalseOnPlainEAC3Profile() {
        // -99 == AV_PROFILE_UNKNOWN; a real plain-EAC3 decode reports this or another non-JOC value.
        let outcome = AtmosDetectionOutcome(stopReason: .frameDecoded, packetsRead: 2, bytesRead: 400, decodedProfile: -99)
        #expect(outcome.confirmedAtmos == false)
    }

    @Test("hitting any cap without a decoded frame is never Atmos, regardless of decodedProfile")
    func confirmedAtmosFalseWhenCapReachedBeforeDecode() {
        for reason: AtmosDetectionOutcome.StopReason in [.packetCap, .byteCap, .timeCap, .demuxEOF, .demuxError] {
            let outcome = AtmosDetectionOutcome(stopReason: reason, packetsRead: 64, bytesRead: 8_000_000, decodedProfile: nil)
            #expect(outcome.confirmedAtmos == false, "\(reason) must never confirm Atmos")
        }
    }

    @Test("a non-EAC3 / no-audio / decoder-open-failure source is never Atmos")
    func confirmedAtmosFalseForSkippedOrFailedSources() {
        for reason: AtmosDetectionOutcome.StopReason in [.noAudioTrack, .notEAC3, .decoderOpenFailed] {
            let outcome = AtmosDetectionOutcome(stopReason: reason, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
            #expect(outcome.confirmedAtmos == false, "\(reason) must never confirm Atmos")
        }
    }

    @Test("eac3JOCProfile mirrors FFmpeg's AV_PROFILE_EAC3_DDP_ATMOS (30)")
    func jocProfileConstant() {
        #expect(AtmosDetectionOutcome.eac3JOCProfile == 30)
    }
}
