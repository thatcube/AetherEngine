import XCTest
@testable import AetherEngine

final class BDTitleSelectorTests: XCTestCase {
    func test_picksLongestPlaylist() {
        let a = MPLSPlaylist(clipIDs: ["00001"], durationTicks: 100)
        let b = MPLSPlaylist(clipIDs: ["00002", "00003"], durationTicks: 9000)
        let c = MPLSPlaylist(clipIDs: ["00004"], durationTicks: 500)
        XCTAssertEqual(BDTitleSelector.selectMainTitle([a, b, c]), b)
    }

    func test_nilWhenEmpty() {
        XCTAssertNil(BDTitleSelector.selectMainTitle([]))
    }

    // MARK: - enumerateTitles (#67)

    func test_enumerateTitlesSortsLongestFirstAndDropsShort() {
        let main = MPLSPlaylist(clipIDs: ["00001", "00002"], durationTicks: 5_400_000)  // 120s
        let episode = MPLSPlaylist(clipIDs: ["00003"], durationTicks: 2_700_000)        // 60s
        let menu = MPLSPlaylist(clipIDs: ["00009"], durationTicks: 90_000)              // 2s, below 10s floor
        let titles = BDTitleSelector.enumerateTitles([episode, menu, main])
        XCTAssertEqual(titles.count, 2)                       // the 2s menu loop is dropped
        XCTAssertEqual(titles.map(\.id), [0, 1])             // ordinals assigned after sorting
        XCTAssertEqual(titles[0].durationTicks, 5_400_000)  // longest is id 0 (the main feature)
        XCTAssertEqual(titles[0].bdClipIDs, ["00001", "00002"])
        XCTAssertEqual(titles[1].durationTicks, 2_700_000)
    }

    func test_enumerateTitlesNeverEmptyWhenAllShort() {
        // If filtering would leave nothing, the unfiltered set is used (a disc with only short
        // playlists must still expose them rather than become unplayable).
        let a = MPLSPlaylist(clipIDs: ["1"], durationTicks: 100)
        let b = MPLSPlaylist(clipIDs: ["2"], durationTicks: 500)
        let titles = BDTitleSelector.enumerateTitles([a, b])
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual(titles[0].durationTicks, 500)  // still sorted longest-first
    }

    func test_enumerateTitlesEmptyInput() {
        XCTAssertTrue(BDTitleSelector.enumerateTitles([]).isEmpty)
    }

    func test_enumerateTitlesCarriesChapters() {
        let main = MPLSPlaylist(clipIDs: ["00001"], durationTicks: 5_400_000,
                                chapterStartTicks: [0, 1_350_000, 2_700_000])
        let titles = BDTitleSelector.enumerateTitles([main])
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles[0].chapters.map(\.id), [0, 1, 2])           // chapter ids are 0-based ordinals
        XCTAssertEqual(titles[0].chapters.map(\.startTicks), [0, 1_350_000, 2_700_000])
        XCTAssertEqual(titles[0].titleInfo().chapterCount, 3)
    }
}
