# Synthwave Visualizer

A macOS app that listens to Spotify and draws a fullscreen synthwave scene in time with the music. It reads the audio through a Core Audio process tap, so Spotify keeps playing through your speakers as usual and nothing has to be rerouted.

![A sunset sky, a striped sun on the horizon, a neon grid, and equalizer bars](docs/screenshot.png)

The image above is the offscreen frame `SceneRendererTests` renders for a kick drum hit.

It is written in Swift 6 with SwiftUI and Metal, and has no third-party dependencies.

## What you see

- A gradient sunset sky and a sun with cut lines. The sun grows with the bass, and its lines jump on each beat.
- A perspective grid that scrolls toward you. It speeds up as the music gets louder and brightens with the mids.
- 32 equalizer bars, which are 16 frequency bands mirrored around the sun, each with a peak cap that hangs for a moment before it falls.
- Bloom, chromatic aberration, scanlines, a vignette, and film noise on top.

## Requirements

- macOS 26.0 or later
- Xcode with Swift 6

## Build and run

Open `Synthwave-Visualizer.xcodeproj` in Xcode and run the `Synthwave-Visualizer` scheme. From a terminal:

```sh
xcodebuild -project Synthwave-Visualizer.xcodeproj -scheme Synthwave-Visualizer -destination 'platform=macOS' build
```

On first launch macOS asks for System Audio Recording permission. The tap delivers only silence without it. If you deny the prompt, the app shows a sheet with a button that opens the right pane in System Settings > Privacy & Security.

Debug builds are ad-hoc signed, so macOS may ask again after a rebuild.

## Using it

The app starts on Spotify and follows it across relaunches. Pausing leaves the tap running, and the bars fall to zero.

| Menu item | Shortcut | What it does |
|---|---|---|
| View > Toggle Full Screen | ⌘F | Fullscreen. The cursor hides after two seconds without movement. |
| View > Show Track Title | ⌘T | Shows Spotify's current track and artist. Off by default, because the first read raises macOS's Automation permission prompt. |
| Source | | Picks what to listen to: Spotify, System Audio, or any other app with an audio process. A ♪ marks the ones playing now. |
| Debug > Show Analyzer Overlay | ⌘D | Draws the analyzer's band levels as a plain bar graph, with bass, mids, RMS, a beat light, and the tap status. |
| Debug > Run Tap Leak Check | | Starts and stops the tap ten times and compares the audio device count before and after. |

The display stays awake while the tap is running. Closing the window quits the app.

## Tests

```sh
xcodebuild -project Synthwave-Visualizer.xcodeproj -scheme Synthwave-Visualizer -destination 'platform=macOS' test
```

The tests run hosted inside the app, which skips starting the tap under test, so they never raise the permission prompt. They cover the ring buffer, the analyzer, the scene state, and offscreen renders of the scene. The offscreen renders also compile the shaders, which is the only place a shader error shows up before launch.

To write the rendered frames out as PNGs, pass a directory:

```sh
TEST_RUNNER_SYNTHWAVE_SNAPSHOT_DIR=/tmp/snapshots xcodebuild -project Synthwave-Visualizer.xcodeproj -scheme Synthwave-Visualizer -destination 'platform=macOS' test -only-testing:Synthwave-VisualizerTests/SceneRendererTests
```

Unit tests can't cover the tap, the permission flow, or live audio, because all three need the permission grant. Check those by hand with the two Debug menu items.

## How it works

Audio flows one way, and the realtime audio thread never touches UI.

```
ProcessTap IOProc (realtime thread)
  -> RingBuffer (lock-free, preallocated)
  -> SpectrumAnalyzer (4096-point FFT, 16 log-spaced bands, beat detection)
  -> FrameFeatures
  -> SceneState -> SceneRenderer (Metal)
```

The analyzer runs inside the `MTKView` draw callback, so audio analysis and rendering share one clock. Every easing constant is converted with the frame's `dt`, so the scene moves the same at 60 Hz and 120 Hz.

| Folder | Contents |
|---|---|
| `Synthwave-Visualizer/Audio` | Process lookup, the tap, the ring buffer, the permission heuristic |
| `Synthwave-Visualizer/DSP` | FFT, band levels, beat flag |
| `Synthwave-Visualizer/Render` | Scene state, Metal renderer, shader source, palette |
| `Synthwave-Visualizer/App` | Window, menus, track title, debug overlay |

`synthwave-visualizer-plan.md` is the full spec. It has the build phases, the palette, the Core Audio gotchas, and notes on where the code departs from the original plan. `CLAUDE.md` lists the project conventions, such as which types must be `nonisolated`.

## Status

All six phases of the plan are implemented and the test suite passes. The checks that need real music and the permission grant are still open: the leak check, the denied-permission path, live frame rate, and an hour-long fullscreen run through a Spotify restart. The plan's implementation notes list them, along with one known risk in how the tap's aggregate device is set up.
