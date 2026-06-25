import Foundation

enum BDTitleSelector {
    /// Playlists shorter than this are dropped from the title list: discs pad PLAYLIST with FBI
    /// warnings, menu loops, and (on anti-rip discs) hundreds of decoy playlists. If filtering would
    /// leave nothing, the unfiltered set is used so a disc never ends up with zero titles.
    static let minTitleSeconds: Double = 10

    static func selectMainTitle(_ playlists: [MPLSPlaylist]) -> MPLSPlaylist? {
        playlists.max { $0.durationTicks < $1.durationTicks }
    }

    /// All playlists as selectable titles, longest first so id 0 is the main feature (preserving the
    /// "default plays the main title" behavior). Trivially-short playlists are filtered (see above).
    static func enumerateTitles(_ playlists: [MPLSPlaylist]) -> [DiscTitle] {
        let minTicks = UInt64(minTitleSeconds * discTickRate)
        let real = playlists.filter { $0.durationTicks >= minTicks }
        let pool = real.isEmpty ? playlists : real
        return pool.sorted { $0.durationTicks > $1.durationTicks }
            .enumerated()
            .map { index, playlist in
                let chapters = playlist.chapterStartTicks.enumerated().map { i, start in
                    DiscChapter(id: i, startTicks: start)
                }
                return DiscTitle(id: index, durationTicks: playlist.durationTicks,
                                 chapters: chapters, bdClipIDs: playlist.clipIDs)
            }
    }
}
