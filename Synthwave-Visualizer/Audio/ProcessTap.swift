import CoreAudio
import Foundation

/// Taps one or more processes (or all system audio) through a private aggregate device and
/// streams the interleaved Float32 samples into a `RingBuffer`.
///
/// nonisolated: the IOProc closure must not inherit the target's MainActor default isolation, or
/// Swift 6's runtime isolation check traps on the first callback from Core Audio's IO thread.
nonisolated final class ProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var format = AudioStreamBasicDescription()
    let ring: RingBuffer

    init(ring: RingBuffer) { self.ring = ring }

    var isRunning: Bool { ioProcID != nil }

    /// Stereo mixdown of the given processes, still audible to the user.
    func start(processes: [AudioObjectID]) throws {
        try start(CATapDescription(stereoMixdownOfProcesses: processes))
    }

    /// Stereo mixdown of everything the system plays.
    func startSystemAudio() throws {
        try start(CATapDescription(stereoGlobalTapButExcludeProcesses: []))
    }

    private func start(_ desc: CATapDescription) throws {
        stop()
        do {
            try create(desc)
        } catch {
            stop()
            throw error
        }
    }

    private func create(_ desc: CATapDescription) throws {
        // 1. Tap description
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw TapError.create(err) }

        // 2. Read the tap's stream format; do not assume 48 kHz
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = CoreAudioProperty.address(kAudioTapPropertyFormat)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format)
        guard err == noErr else { throw TapError.format(err) }
        try Self.validate(format)

        // 3. Private aggregate device containing only the tap
        err = AudioHardwareCreateAggregateDevice(
            Self.aggregateDescription(tapUUID: desc.uuid) as CFDictionary, &aggregateID)
        guard err == noErr else { throw TapError.aggregate(err) }

        // 4. IOProc. Realtime thread: no allocation, no locks, no Swift objects beyond the ring.
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [ring] _, inInputData, _, _, _ in
            Self.deliver(inInputData, to: ring)
        }
        guard err == noErr else { throw TapError.ioProc(err) }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw TapError.start(err) }
    }

    func stop() {
        // Order matters: IOProc, then aggregate, then tap. The aggregate is private, so a leak
        // dies with the process, but every Spotify relaunch runs this teardown, and a long
        // session would pile up leaked devices.
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

    /// No kAudioAggregateDeviceTapAutoStartKey: with it, AudioDeviceStart blocks until the tapped
    /// process produces audio, which freezes the caller while Spotify is paused.
    static func aggregateDescription(tapUUID: UUID) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Synthwave Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
    }

    /// The IOProc writes buffers to the ring back to back as Float32, which is only a valid
    /// interleaved stereo stream if the tap delivers exactly that.
    static func validate(_ format: AudioStreamBasicDescription) throws {
        guard format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else { throw TapError.nonInterleaved }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame == 2 else { throw TapError.unsupportedFormat }
    }

    /// The IOProc body. Runs on the realtime thread.
    static func deliver(_ input: UnsafePointer<AudioBufferList>, to ring: RingBuffer) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        for buf in buffers {
            guard let data = buf.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            ring.write(samples, count: Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
        }
    }
}

enum TapError: Error, Equatable, LocalizedError {
    case create(OSStatus), format(OSStatus), aggregate(OSStatus), ioProc(OSStatus), start(OSStatus)
    case nonInterleaved, unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .create(let s): "Could not create the audio tap (\(s))."
        case .format(let s): "Could not read the tap's audio format (\(s))."
        case .aggregate(let s): "Could not create the tap's aggregate device (\(s))."
        case .ioProc(let s): "Could not install the audio callback (\(s))."
        case .start(let s): "Could not start the tap's aggregate device (\(s))."
        case .nonInterleaved: "The tap delivers non-interleaved audio, which this app does not handle."
        case .unsupportedFormat: "The tap delivers audio in a format other than stereo Float32."
        }
    }
}
