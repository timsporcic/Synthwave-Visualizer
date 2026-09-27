import CoreAudio
import Foundation
import Testing
@testable import Synthwave_Visualizer

private func format(flags: AudioFormatFlags, channels: UInt32 = 2, bits: UInt32 = 32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
}

struct ProcessTapTests {
    @Test func aggregateIsPrivateAndHoldsOnlyTheTapWithDriftCompensation() throws {
        let uuid = UUID()
        let desc = ProcessTap.aggregateDescription(tapUUID: uuid)
        #expect(desc[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        let taps = try #require(desc[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        #expect(taps.count == 1)
        #expect(taps.first?[kAudioSubTapUIDKey] as? String == uuid.uuidString)
        #expect(taps.first?[kAudioSubTapDriftCompensationKey] as? Bool == true)
    }

    @Test func aggregateOmitsTapAutoStartSoStartNeverBlocks() {
        let desc = ProcessTap.aggregateDescription(tapUUID: UUID())
        #expect(desc[kAudioAggregateDeviceTapAutoStartKey] == nil)
    }

    @Test func acceptsInterleavedStereoFloat32() throws {
        try ProcessTap.validate(format(flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked))
    }

    @Test func rejectsNonInterleaved() {
        #expect(throws: TapError.nonInterleaved) {
            try ProcessTap.validate(format(flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved))
        }
    }

    @Test func rejectsIntegerSamples() {
        #expect(throws: TapError.unsupportedFormat) {
            try ProcessTap.validate(format(flags: kAudioFormatFlagIsSignedInteger, bits: 16))
        }
    }

    @Test func deliverCopiesEveryInputSampleIntoTheRing() {
        let ring = RingBuffer(capacity: 16)
        var samples: [Float] = [0.1, -0.1, 0.2, -0.2]
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            ProcessTap.deliver(&list, to: ring)
        }
        var out = [Float](repeating: 9, count: 4)
        out.withUnsafeMutableBufferPointer { ring.readLatest(into: $0.baseAddress!, count: 4) }
        #expect(out == samples)
    }

    @Test func deliverSkipsDisabledStreams() {
        let ring = RingBuffer(capacity: 16)
        var list = AudioBufferList(
            mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: nil))
        ProcessTap.deliver(&list, to: ring)
        var out = [Float](repeating: 9, count: 4)
        out.withUnsafeMutableBufferPointer { ring.readLatest(into: $0.baseAddress!, count: 4) }
        #expect(out == [0, 0, 0, 0])
    }
}
