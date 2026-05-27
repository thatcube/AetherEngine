# DemoPlayerMac

Standalone macOS demonstrator for AetherEngine. Single window, drop a video file onto it, video plays. No menus, no transport bar, no settings — the entire UI surface is one `AetherPlayerSurface` plus a placeholder for the empty state.

Intended for two audiences:

- **Beta testers** who want to exercise the engine against their own media without setting up an Xcode project or writing a host app. Useful for repro on bug reports: "does the source play in DemoPlayerMac too?" decouples engine bugs from Sodalite-specific bugs.
- **Developers** evaluating AetherEngine who want to see playback working before integrating.

## Running it (Phase A: source build)

From this directory:

```bash
swift run
```

A window labelled *AetherEngine Demo* opens. Drag any video file onto it; playback starts immediately. The corner indicator shows whether the source landed on the native AVPlayer path (`native`) or the SW dav1d / libavcodec path (`sw`).

Controls:

| Action | Effect |
| --- | --- |
| Click on the video | Toggle play / pause |
| Space | Toggle play / pause |
| Escape | Stop and return to the drop zone |
| Drop a different file | Loads the new file (current one is stopped first by the engine) |

## Distribution build (Phase B, planned)

A `Scripts/build-dmg.sh` will be added to produce a notarized `.dmg` so end users can download an `.app` from the GitHub Release assets without compiling. Until then, the source build is the supported path.

## Why a separate `Package.swift`

`Examples/DemoPlayerMac/Package.swift` is its own package that depends on the parent AetherEngine via `path: "../.."`. Keeping it isolated avoids pulling a SwiftUI macOS app target into the main engine package (which would force every SPM consumer of `AetherEngine` to drag in `AppKit` / `SwiftUI` dependencies they don't need).

## Scope

The demonstrator deliberately stops where DrHurt's [issue #18](https://github.com/superuser404notfound/AetherEngine/issues/18) does: *"Just a super simple wrapper app, no menus, no nothing. One window → drop file on top → play."* Adding a transport bar, subtitle picker, audio track switcher, etc. is feature creep that would turn this into a "real" player and miss the point — those things belong in a host app like [Sodalite](https://github.com/superuser404notfound/Sodalite). The demonstrator's job is to prove the engine plays files; the host's job is to ship the experience around that.
