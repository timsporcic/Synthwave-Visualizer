# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS app (Swift, SwiftUI, Metal) that taps Spotify's audio through a Core Audio process tap, runs an FFT, and renders a fullscreen synthwave scene. No third-party dependencies.

`synthwave-visualizer-plan.md` is the spec: the architecture, the phase order, each phase's "Done when" criterion, the palette, and the Core Audio gotchas. Read it before starting or resuming any phase, and build phases in order. A phase is finished only when its "Done when" state is observed in the running app.

The repo is currently the bare Xcode template (`MyApp.swift`, `ContentView.swift`); implementation starts at Phase 1.

## Build

```sh
xcodebuild -project Synthwave-Visualizer.xcodeproj -scheme Synthwave-Visualizer -destination 'platform=macOS' build
```

There is no test target yet. Most "Done when" checks require running the app with audio playing, and the first run triggers the System Audio Recording permission prompt.

## Conventions the project config imposes

The target still has the multiplatform template's settings (iOS/visionOS platforms, Swift 5, App Sandbox on); plan Phase 1 lists the changes.

- The `Synthwave-Visualizer/` folder is a file-system synchronized group: new files and subfolders (`Audio/`, `DSP/`, `Render/`, `App/`) join the target automatically, with no `project.pbxproj` edit.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: every type is main-actor isolated unless declared otherwise. Anything Core Audio's IO thread touches (`ProcessTap`, `RingBuffer`) must be `nonisolated`, or Swift 6's runtime isolation check traps on the first IOProc callback.
