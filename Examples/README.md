# Examples

Drop-in samples that show the smallest viable AetherEngine integration.

## MinimalPlayer

[`MinimalPlayer/MinimalPlayerApp.swift`](MinimalPlayer/MinimalPlayerApp.swift) is a complete SwiftUI app entry point that loads, plays, and reports state for a single source URL. About 90 lines including comments and UI state plumbing.

### Try it in 5 minutes

1. **Create an Xcode project.** File › New › Project. Pick the SwiftUI template for the platform you want (tvOS / iOS / macOS App). Any product name; no tests target needed.

2. **Add AetherEngine as a Swift Package dependency.** File › Add Package Dependencies, paste:
   ```
   https://github.com/superuser404notfound/AetherEngine
   ```
   Dependency Rule: Up to Next Major Version, starting from `1.5.0`. Add the `AetherEngine` library product to your app target.

3. **Drop the file in.** Replace the Xcode template's default `App.swift` (or whatever the generated `@main` file is called) with the contents of [`MinimalPlayerApp.swift`](MinimalPlayer/MinimalPlayerApp.swift). The file is self-contained: it defines both the `@main App` struct and the `ContentView`.

4. **Point at a real source URL.** Edit the `sourceURL` line:
   ```swift
   @State private var sourceURL = URL(string: "https://example.com/your-video.mkv")!
   ```
   Use any file://, http://, or https:// URL the engine can demux. MKV / MP4 / WebM / MPEG-TS / AVI all work.

5. **Run.** Hit ▶︎ in Xcode. The Load button kicks off the demux + HLS-fMP4 pipeline; Play / Pause / Stop hit the engine directly. State, time, duration, and detected video format update live via the engine's Combine publishers.

### What's not in the minimal example

To stay readable the sample omits things real apps care about:

- **Subtitles.** `engine.subtitleTracks` lists them; `engine.selectSubtitleTrack(index:)` activates one. `engine.$subtitleCues` publishes the cues — text or `CGImage` — that the host paints over the surface.
- **Audio track switching.** `engine.audioTracks` + `engine.selectAudioTrack(index:)`.
- **Resume position.** `engine.load(url:, startPosition: 347.5)`.
- **HTTP headers** for authenticated sources. Pass them in `LoadOptions(httpHeaders: [...])`.
- **HDR / Dolby Vision routing on tvOS.** Requires the engine-driven sole-writer pattern (see README › Host setup on tvOS). The minimal sample relies on default routing; for production tvOS hosts on HDR content, set `appliesPreferredDisplayCriteriaAutomatically = false` on your `AVPlayerViewController` and pass `LoadOptions(matchContentEnabled:, panelIsInHDRMode:)` populated from the runtime EDR state.
- **Now Playing / lock-screen integration.** Subscribe to `engine.$currentAVPlayer` and feed it to `MPNowPlayingSession`. See `Sodalite` for a reference implementation.

For all of these, read the inline docstrings on `AetherEngine`, `LoadOptions`, and `TrackInfo` in `Sources/AetherEngine/`. They're the canonical contract.
