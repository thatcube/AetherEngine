// Tests/AetherEngineTests/NativeSubtitleAvailabilityTests.swift
import XCTest
@testable import AetherEngine

final class NativeSubtitleAvailabilityTests: XCTestCase {
    private func textCue(_ id: Int, _ start: Double, _ end: Double, _ text: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(text))
    }

    func test_storeWithCuesMakesRenditionAvailable_clearResets() {
        let store = NativeSubtitleCueStore()
        store.appendCues([textCue(1, 0, 1, "x")])
        XCTAssertEqual(store.cueCount, 1)
        store.clear()
        XCTAssertEqual(store.cueCount, 0)
    }

    func test_replaceCuesPopulatesStore() {
        let store = NativeSubtitleCueStore()
        store.replaceCues([textCue(1, 0, 1, "a"), textCue(2, 2, 3, "b")])
        XCTAssertEqual(store.cueCount, 2)
    }

    func test_appendCuesAccumulates() {
        let store = NativeSubtitleCueStore()
        store.appendCues([textCue(1, 0, 1, "a")])
        store.appendCues([textCue(2, 1, 2, "b")])
        XCTAssertEqual(store.cueCount, 2)
    }

    func test_loadOptionsPrepareNativeSubtitleDefaultsFalse() {
        let opts = LoadOptions()
        XCTAssertFalse(opts.prepareNativeSubtitles)
    }

    func test_loadOptionsPrepareNativeSubtitleRoundTrips() {
        let opts = LoadOptions(prepareNativeSubtitles: true)
        XCTAssertTrue(opts.prepareNativeSubtitles)
    }
}
