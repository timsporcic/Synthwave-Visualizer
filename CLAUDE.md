# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS app (Swift 6, SwiftUI, Metal) that taps Spotify's audio (or any app's, or all system audio) through a Core Audio process tap, runs an FFT, and renders a fullscreen synthwave scene. No third-party dependencies.

`synthwave-visualizer-plan.md` is the spec: architecture, phase order, each phase's "Done when" criterion, palette, and Core Audio gotchas. Where the code deliberately departs from it, the plan's "Implementation notes" section says why.

## Build and test

```sh
xcodebuild -project Synthwave-Visualizer.xcodeproj -scheme Synthwave-Visualizer -destination 'platform=macOS' build
xcodebuild -project Synthwave-Visualizer.xcodeproj -scheme Synthwave-Visualizer -destination 'platform=macOS' test
```

- One suite or test: `-only-testing:Synthwave-VisualizerTests/SpectrumAnalyzerBeatTests` or `-only-testing:'Synthwave-VisualizerTests/SceneRendererTests/sunIsBrightAboveTheHorizonCenter()'`. Swift Testing functions need the trailing `()`; without it xcodebuild runs zero tests and still exits 0.
- Tests use Swift Testing and run hosted inside the app. The app skips `audio.start()` when `XCTestConfigurationFilePath` is set, so tests never raise the System Audio Recording prompt.
- The test host's stdout does not reach xcodebuild's output. Put diagnostics in the `#expect` message and read failures from the `.xcresult` (`xcrun xcresulttool get test-results tests --path <bundle>`).
- `SceneRendererTests` renders silence/pad/kick frames offscreen. Pass `TEST_RUNNER_SYNTHWAVE_SNAPSHOT_DIR=<dir>` to xcodebuild to also write them as PNGs for a visual check.
- Tap, permission, and live-audio behavior can't be unit tested (they need the permission grant). Debug > Run Tap Leak Check and Debug > Show Analyzer Overlay (⌘D) exist for checking them by hand.

## Architecture

Audio flows one way, and the realtime thread never touches UI: `ProcessTap`'s IOProc writes into `RingBuffer` → each `MTKView` draw, `SynthwaveRenderer` reads the latest 8192 floats, `SpectrumAnalyzer` produces `FrameFeatures`, `SceneState` advances by `dt`, and `SceneRenderer` draws. `AudioController` owns the tap and restarts it whenever `ProcessLocator` reports that the selected bundle ID's process set changed (a Spotify relaunch gets a new process object ID).

Pure logic lives in small value types with tests (`PermissionProbe`, `IdleCursor`, `SourceMenuEntry`, `SceneState`, `TrackInfo`). Keep that split when adding behavior: effects in the thin shell, decisions in something a test can drive.

## Conventions the project config imposes

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: every type is main-actor isolated unless declared otherwise. Anything Core Audio's IO thread touches (`ProcessTap`, `RingBuffer`) must be `nonisolated`, or Swift 6's runtime isolation check traps on the first IOProc callback. Types the (nonisolated) test target uses directly (value types, `SpectrumAnalyzer`, `AudioController.Target`) are `nonisolated` too.
- Shaders are a Swift string (`Render/Shaders.swift`) compiled at runtime with `makeLibrary(source:)`, because the Metal Toolchain isn't installed here. A shader error only shows up at runtime, so run `SceneRendererTests` after any shader edit. `SceneUniforms` in Swift and MSL must keep the same field order.
- The `Synthwave-Visualizer/` and `Synthwave-VisualizerTests/` folders are file-system synchronized groups: new files join their target with no `project.pbxproj` edit.
- `NSAudioCaptureUsageDescription` lives in `Config/Info.plist`, merged into the generated Info.plist. Xcode drops it when it's set as an `INFOPLIST_KEY_` build setting. Keep the file outside the synchronized folder, or it gets copied as a resource.
- Deployment target is macOS 26.0: the development Mac runs 26.x, and a 27 target would not launch there.
