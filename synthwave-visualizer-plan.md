# Synthwave visualizer: implementation plan

A native macOS app (Swift, Metal) that taps Spotify's audio with a Core Audio process tap and renders a fullscreen retrowave scene: gradient sunset, retro sun with cut lines, scrolling perspective grid, and 32 neon equalizer bars (16 analyzer bands, mirrored) driven by a live FFT.

Target: macOS 26 or later (see Implementation notes), Xcode current, Swift 6. No third-party dependencies.

## Architecture

Five parts. Data flows one direction, and the realtime audio thread never touches UI:

```
IOProc (realtime thread)
  -> RingBuffer (lock-free, preallocated)
  -> SpectrumAnalyzer (runs on the render clock, display refresh rate)
  -> FrameFeatures (value type, 16 band levels + bass/mids/rms/beat)
  -> SynthwaveRenderer (Metal, MTKView)
```

| File | Responsibility |
|---|---|
| `Audio/ProcessLocator.swift` | Finds Spotify's `AudioObjectID`; watches the process list so the tap survives a Spotify relaunch |
| `Audio/RingBuffer.swift` | Fixed-size `Float` ring with an atomic write index; written by the IOProc, read by the analyzer |
| `Audio/ProcessTap.swift` | Creates the tap and a private aggregate device, owns the IOProc, start/stop with correct teardown order |
| `DSP/SpectrumAnalyzer.swift` | Hann window, vDSP FFT, log-spaced band buckets, attack/decay smoothing, peak hold, beat flag |
| `DSP/FrameFeatures.swift` | Plain struct the renderer consumes |
| `Render/SynthwaveRenderer.swift` | MTKViewDelegate, render passes, uniforms |
| `Render/Shaders.swift` | Sky, sun, grid, bars, bloom, post (MSL source compiled at runtime; see Implementation notes) |
| `App/` | SwiftUI window, fullscreen, process picker menu, permission handling |

## Phases

Build in this order. Each phase ends on a checkable state; do not start the next phase until the current one passes.

### Phase 1: project skeleton

The Xcode template ships as a multiplatform, sandboxed, Swift 5 target. Steps 1 to 4 bring it in line with this plan.

1. Restrict the target to macOS with a macOS 26.0 deployment target (the template also targets iOS and visionOS). SwiftUI lifecycle, Swift 6 language mode with strict concurrency (the template has `SWIFT_VERSION = 5.0`).
2. Add `NSAudioCaptureUsageDescription` with a one-line reason. Process taps go through the "System Audio Recording" privacy prompt; without this key the create call fails. The target generates its Info.plist (`GENERATE_INFOPLIST_FILE = YES`), so add it as an `INFOPLIST_KEY_NSAudioCaptureUsageDescription` build setting; if Xcode does not pass that key through, point `INFOPLIST_FILE` at a partial Info.plist holding just this key, which Xcode merges with the generated one.
3. Turn App Sandbox off (the template has `ENABLE_APP_SANDBOX = YES`). If it is turned on later, add the `com.apple.security.device.audio-input` entitlement and re-verify taps work.
4. The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so every type is main-actor isolated unless declared otherwise. Declare `RingBuffer` and `ProcessTap` `nonisolated`. Swift 6 infers a closure formed in a main-actor context as main-actor isolated and inserts a runtime executor check, so an IOProc closure created inside a main-actor `ProcessTap` traps on its first callback from Core Audio's IO thread.
5. Link `CoreAudio`, `Accelerate`, `Metal`, `MetalKit`.
6. Add an `MTKView` inside an `NSViewRepresentable` that clears to `#0d0221`.

Done when: the app launches and shows a dark purple window.

### Phase 2: locate Spotify

1. In `ProcessLocator`, read `kAudioHardwarePropertyProcessObjectList` from `kAudioObjectSystemObject`.
2. For each process object, read `kAudioProcessPropertyBundleID` and match `com.spotify.client`.
3. Register an `AudioObjectAddPropertyListenerBlock` on the process list, passing `DispatchQueue.main` as the queue so the block runs where the main-actor default expects it. When it fires, re-run the match and publish the new ID (or nil) through an `AsyncStream`.
4. Also expose the full list of `(bundleID, pid, objectID, isRunningOutput)` for the picker menu, so the same app can tap a browser playing Lofi Girl. Browsers play audio from helper processes (Chrome's `.helper` processes, Safari's WebKit GPU process), so the list shows helper bundle IDs, not app names. Sort entries with `kAudioProcessPropertyIsRunningOutput` set to the top so the process currently playing is easy to find.

Recorded: Spotify's process object appears about 1.3 s after launch, before anything plays.

Done when: launching Spotify, quitting it, and relaunching it (pressing play after each launch if the object only appears on playback) logs three process-ID changes.

### Phase 3: the tap

`ProcessTap.start(process:)` skeleton. The error handling, format read, isolation, and teardown are the parts people get wrong, so keep them.

```swift
import CoreAudio

// nonisolated: the IOProc closure below must not inherit the target's MainActor default.
nonisolated final class ProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var format = AudioStreamBasicDescription()
    let ring: RingBuffer

    init(ring: RingBuffer) { self.ring = ring }

    func start(process: AudioObjectID) throws {
        // 1. Tap description: stereo mixdown of one process, still audible to the user
        let desc = CATapDescription(stereoMixdownOfProcesses: [process])
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw TapError.create(err) }

        // 2. Read the tap's stream format; do not assume 48 kHz
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format)
        guard err == noErr else { throw TapError.format(err) }
        // The IOProc writes buffers to the ring back to back, which is only a valid
        // interleaved stream if the tap delivers one interleaved buffer.
        guard format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else {
            throw TapError.nonInterleaved
        }

        // 3. Private aggregate device containing only the tap. No
        //    kAudioAggregateDeviceTapAutoStartKey: with it, AudioDeviceStart blocks
        //    until the tapped process produces audio, which freezes the caller while
        //    Spotify is paused.
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Synthwave Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        err = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggregateID)
        guard err == noErr else { throw TapError.aggregate(err) }

        // 4. IOProc. Input buffers carry the tapped audio. Realtime thread:
        //    no allocation, no locks, no Swift objects beyond the captured ring.
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [ring] _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            for buf in abl {
                guard let data = buf.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                ring.write(samples, count: Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
            }
        }
        guard err == noErr else { throw TapError.ioProc(err) }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw TapError.start(err) }
    }

    func stop() {
        // Order matters: IOProc, then aggregate, then tap. The aggregate is private, so
        // a leak dies with the process, but every Spotify relaunch runs this teardown,
        // and a long session would pile up leaked devices.
        if let p = ioProcID {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}

enum TapError: Error {
    case create(OSStatus), format(OSStatus), aggregate(OSStatus), ioProc(OSStatus), start(OSStatus)
    case nonInterleaved
}
```

`RingBuffer` requirements:

- `nonisolated final class`, `@unchecked Sendable`: storage is a preallocated `UnsafeMutablePointer<Float>`, and the atomic write index is what makes sharing it safe.
- Capacity a power of two, at least 16384 floats: twice the 8192-float analysis read, so the writer cannot lap the reader mid-copy. Interleaved stereo as delivered.
- `write` is called only from the IOProc. `readLatest(into:count:)` is called only from the analyzer. One writer, one reader, an `Atomic<Int>` write index (`import Synchronization`), no locks.
- `readLatest` copies the most recent `count` samples ending at the write index, so the analyzer always sees fresh audio and never blocks. It does not consume, so there is no read index.

Done when:

- A debug label shows RMS computed on the main thread from `readLatest` (never in the IOProc). It moves while Spotify plays and stays at zero while only another app plays audio.
- After ten `start(process:)`/`stop()` cycles, the device count from `kAudioHardwarePropertyDevices` matches the count before the first start.
- You have recorded what a denied permission looks like. Turn System Audio Recording off for the app in System Settings > Privacy & Security, then launch. Either `AudioHardwareCreateProcessTap` throws `.create`, or it succeeds and the IOProc delivers only exact zeros. Phase 6 step 4 depends on which.

### Phase 4: analysis

Run analysis inside the `MTKView` draw callback so audio and rendering share one clock. Every time-based constant below is defined in seconds or per 60 Hz frame and converted with the frame's `dt`, so the look is identical at 60 Hz and 120 Hz. For a per-frame easing coefficient `k60`, use `k = 1 - pow(1 - k60, dt * 60)`.

1. Pull the latest 8192 interleaved floats (4096 stereo frames) from the ring and mix to mono (average L and R).
2. Multiply by a precomputed 4096-point Hann window (`vDSP.window(ofType:usingSequence: .hanningDenormalized, ...)`).
3. Forward FFT with `vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self)`. Real input has to be packed first: even samples into `realp`, odd samples into `imagp` of a 2048-element split-complex (`vDSP_ctoz`). The output is packed too: `imagp[0]` holds the Nyquist value, not bin 0's imaginary part. The bands start at 40 Hz, so skip bin 0 entirely. Then `vDSP.absolute` for magnitudes.
4. Scale and convert to dB. vDSP's real FFT returns twice the mathematical DFT, and the Hann window has a coherent gain of 0.5, so multiply magnitudes by `1 / (4096 * 0.5)`. A full-scale sine then reads 0 dB. Convert to dB with a floor of -80, and map -80...0 dB to 0...1. Check the scaling with a full-scale 1 kHz test tone before tuning anything else.
5. Bucket into 16 log-spaced bands from 40 Hz to 16 kHz (each band about 1.455 times the width of the one below). Precompute the bin ranges once per sample rate (read `format.mSampleRate`, it is usually 44100 for Spotify). At 44.1 kHz the bins are 10.8 Hz wide and the narrowest band (40 to 58 Hz) spans about 1.7 bins; clamp every band to at least one bin anyway, so a sample-rate change cannot produce an empty band. Band value is the max normalized level in its range.
6. Smooth each band with asymmetric easing: attack `k60 = 0.7`, decay `k60 = 0.12`. Keep a separate peak-hold per band that holds for 0.2 s, then falls at 1.8 per second.
7. Derive scalars: `bass` = mean of bands covering 40 to 120 Hz, `mids` = mean of 200 Hz to 2 kHz, `rms` from the raw mono window.
8. Beat flag, computed on linear energy (a ratio on dB-normalized values fires on noise when quiet and misses kicks when loud). `bassEnergy` = sum of squared scaled magnitudes over the FFT bins from 40 to 120 Hz, taken before dB conversion and smoothing. A beat fires when `bassEnergy` exceeds 1.4 times its running average over the last second (exponential average, `alpha = 1 - exp(-dt / 1.0)`), `bassEnergy` is above an absolute floor equivalent to -50 dBFS, at least 130 ms have passed since the last beat, and energy has dropped back below the threshold since that beat (without this re-arm rule, a sustained bass note re-fires every 130 ms for about a second while the slow average catches up). The floor keeps silence and background noise from firing; tune it with the click track.
9. Publish everything as one `FrameFeatures` value.

Done when: a temporary bar-graph overlay drawn with plain rectangles tracks the music, bars fall smoothly on pause, the beat flag fires on kick drums in a synthwave test track and stays off during silence, and bar fall speed looks the same with `preferredFramesPerSecond` forced to 30 and to 60.

Tuning tip: before wiring real audio, feed the analyzer a generated sine sweep and a 120 BPM click. Easing curves are far easier to tune against predictable input.

### Phase 5: the scene

Set the `MTKView`'s `preferredFramesPerSecond` to the screen's `maximumFramesPerSecond`; it defaults to 60. Render into an RGBA16Float offscreen texture, then post-process to the drawable. Layers back to front. All colors from the palette in the reference section.

1. **Sky.** Fullscreen quad, vertical gradient: background at top, purple at 30 percent, magenta at 55 percent, orange at the horizon. Horizon at 62 percent of height from the top.
2. **Sun.** Half-disc centered on the horizon, radius about 22 percent of height. Radial gradient from sun highlight in the center to magenta at the edge. Horizontal cut lines in the lower half, thin near the middle and widening toward the bottom. Radius eases up by up to 8 percent with `bass`. On `beat`, offset the cut lines by one line width for 33 ms.
3. **Grid.** Perspective plane below the horizon. Vertical lines converge at the sun center; horizontal lines scroll toward the camera at a base speed in world units per second plus a term proportional to `rms`. Line color cyan with a magenta glow halo. Line brightness scales with `mids`.
4. **Bars.** 32 bars standing on the grid plane in perspective, mirrored left and right around the sun so the layout is symmetric: the 16 analyzer bands, each drawn twice, lowest band nearest the sun. Fill gradient cyan at the base to magenta at the top. A two-pixel brighter outline. A thin peak-hold cap floating above each bar.
5. **Post pass.** Bloom (threshold 0.8, two-pass Gaussian blur at half resolution, add back at 0.6). Horizontal chromatic aberration offset proportional to `bass`, max 4 px. CRT scanlines every 2 px at 12 percent darkening. Vignette. A slow-drifting noise texture at 3 percent opacity.

Done when: the scene runs at the display refresh rate at native resolution with Spotify playing, and screenshots at three moments (silence, sustained pad, kick hit) look distinct.

### Phase 6: polish

1. Fullscreen via `NSWindow.toggleFullScreen`, bound to `⌘F`. Hide the cursor after two seconds idle, show on movement.
2. Menu bar picker listing every audio process from `ProcessLocator`, plus a "System audio" entry that uses `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`.
3. Hold an `IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, ...)` while the tap is running; release on stop.
4. Handle the denied-permission case using the signal recorded in Phase 3: either `start` throws `.create`, or the tap delivers exact zeros for several seconds while the target process reports `kAudioProcessPropertyIsRunningOutput` (which tells a denial apart from a paused track). Show a sheet explaining that System Audio Recording must be enabled in System Settings > Privacy & Security, with a button that opens that pane.
5. Optional: track title and artist overlay in a retro display font, read once per second through Spotify's AppleScript interface (`tell application "Spotify" to get name of current track`). This needs `NSAppleEventsUsageDescription`, triggers a separate Automation permission prompt, and under App Sandbox also needs the `com.apple.security.automation.apple-events` entitlement.

Done when: the app can be left running fullscreen for an hour through a Spotify restart without intervention.

## Reference

### Palette

| Role | Hex |
|---|---|
| Background | `#0d0221` |
| Purple | `#8c1eff` |
| Magenta | `#ff2975` |
| Hot pink | `#f222ff` |
| Orange | `#ff901f` |
| Cyan | `#2de2e6` |
| Sun highlight | `#ffd319` |

Grid and bars use cyan and magenta only. Orange and sun highlight belong to the sun, so it stays the focal point.

### Core Audio properties used

| Purpose | Selector / API |
|---|---|
| List audio processes | `kAudioHardwarePropertyProcessObjectList` on `kAudioObjectSystemObject` |
| Bundle ID of a process | `kAudioProcessPropertyBundleID` |
| PID of a process | `kAudioProcessPropertyPID` |
| Whether a process is playing | `kAudioProcessPropertyIsRunningOutput` |
| PID to process object | `kAudioHardwarePropertyTranslatePIDToProcessObject` |
| List devices (leak check) | `kAudioHardwarePropertyDevices` on `kAudioObjectSystemObject` |
| Tap format | `kAudioTapPropertyFormat` |
| Create / destroy tap | `AudioHardwareCreateProcessTap` / `AudioHardwareDestroyProcessTap` |
| Create / destroy aggregate | `AudioHardwareCreateAggregateDevice` / `AudioHardwareDestroyAggregateDevice` |
| IO callback | `AudioDeviceCreateIOProcIDWithBlock`, `AudioDeviceStart`, `AudioDeviceStop`, `AudioDeviceDestroyIOProcID` |

### Gotchas

- The tap format is whatever Spotify outputs, usually 44.1 kHz stereo Float32 interleaved. Read it; do not hardcode. `start` throws `.nonInterleaved` if the tap ever delivers separate channel buffers.
- The target's default isolation is `MainActor`. Anything the IO thread touches (`ProcessTap`, its IOProc closure, `RingBuffer`) must be `nonisolated`, or Swift 6's runtime isolation check traps on the first callback.
- When Spotify is paused, the IOProc keeps firing with silence. Let the bands decay to zero; keep the device running.
- Leave `kAudioAggregateDeviceTapAutoStartKey` out of the aggregate description. With it, `AudioDeviceStart` waits until the tapped process produces audio, which freezes the main thread whenever Spotify is paused at start.
- Spotify relaunch changes its `AudioObjectID`. The listener from Phase 2 must trigger `stop()` then `start(process:)` with the new ID.
- The IOProc block runs on a realtime thread. No allocation, no `os_log`, no locks, no `DispatchQueue`. The captured `ring` is the only object it touches.
- Teardown order is stop, destroy IOProc, destroy aggregate, destroy tap. The aggregate is private, so it never appears in Audio MIDI Setup and cannot outlive the process; the risk is leaks piling up inside a long session, one per Spotify relaunch. The Phase 3 device-count check covers it.
- First launch triggers the System Audio Recording prompt. If the user denies it, only System Settings can fix it. Whether a denial makes `AudioHardwareCreateProcessTap` fail or yields a silent tap is unverified; Phase 3 records which.
- `MTKView` draw callback and analysis share a thread. Keep analysis under 1 ms (a 4096-point vDSP FFT takes tens of microseconds on Apple silicon; the band bucketing loop is the part to watch).

## Implementation notes

Findings and departures from the phases above, recorded during implementation.

- **Deployment target 26.0, not 27.** The development Mac runs macOS 26.6, and a 27 target will not launch there. The tap APIs need 14.2 and `Atomic` needs 15.0.
- **Shaders compile at runtime.** The Metal Toolchain is a separate Xcode download (`xcodebuild -downloadComponent MetalToolchain`) and isn't installed, so the MSL source lives in `Render/Shaders.swift` and goes through `makeLibrary(source:)`. `SceneRendererTests` compiles it, so a shader error still fails the tests. Once the toolchain is installed, moving it to `Shaders.metal` is mechanical.
- **`NSAudioCaptureUsageDescription` needs the partial Info.plist.** Xcode drops it when it's set as an `INFOPLIST_KEY_` build setting, so it lives in `Config/Info.plist`.
- **Taps are by bundle ID, not a single process.** `ProcessLocator.watch(bundleID:)` yields every process object for the bundle, and `ProcessTap.start(processes:)` mixes them all down. Browsers play from several helper processes.
- **`ProcessTap.validate` also rejects anything that isn't stereo Float32**, since the IOProc and analyzer assume it.
- **`RingBuffer.readLatest` detects laps.** The writer publishes the end of each write before copying; if the reader was preempted long enough for the writer to overwrite its slots mid-copy, it copies again (up to 8 times). The concurrency test caught a torn window under parallel test load without this.
- **Grid lines fade by on-screen density.** Where horizontal lines are closer together than a few pixels, they piled up into a solid cyan band below the horizon.
- **The Phase 3 RMS label and Phase 4 bar graph were kept** as Debug > Show Analyzer Overlay (⌘D), off by default. The Phase 3 device-count check is Debug > Run Tap Leak Check.
- **The track title overlay is off by default** (View > Show Track Title, ⌘T), because its first read raises the Automation permission prompt.
- **Not yet observed:** the "Done when" checks that need System Audio Recording permission and real music (Phase 3 RMS, leak check, and permission-denial behavior; Phase 4 overlay against a real track; Phase 5 live frame rate; Phase 6's one-hour run).

