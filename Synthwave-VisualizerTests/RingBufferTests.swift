import Foundation
import Testing
@testable import Synthwave_Visualizer

private extension RingBuffer {
    func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { write($0.baseAddress!, count: $0.count) }
    }

    func latest(_ count: Int) -> [Float] {
        var out = [Float](repeating: -1, count: count)
        out.withUnsafeMutableBufferPointer { readLatest(into: $0.baseAddress!, count: count) }
        return out
    }
}

struct RingBufferTests {
    @Test func readLatestReturnsMostRecentSamplesInOrder() {
        let ring = RingBuffer(capacity: 16)
        ring.write([1, 2, 3, 4, 5, 6])
        #expect(ring.latest(4) == [3, 4, 5, 6])
    }

    @Test func readLatestSpansTheWrapPoint() {
        let ring = RingBuffer(capacity: 8)
        ring.write([1, 2, 3, 4, 5, 6])
        ring.write([7, 8, 9, 10])  // wraps: slots 0 and 1 now hold 9 and 10
        #expect(ring.latest(6) == [5, 6, 7, 8, 9, 10])
    }

    @Test func readLatestZeroFillsWhatWasNeverWritten() {
        let ring = RingBuffer(capacity: 8)
        ring.write([1, 2])
        #expect(ring.latest(5) == [0, 0, 0, 1, 2])
    }

    @Test func writeLargerThanCapacityKeepsItsTail() {
        let ring = RingBuffer(capacity: 4)
        ring.write([1, 2, 3, 4, 5, 6, 7])
        #expect(ring.latest(4) == [4, 5, 6, 7])
    }

    @Test func concurrentReaderNeverSeesATornWindow() {
        // The writer publishes consecutive integers in IOProc-sized chunks. Every window the
        // reader copies must be one consecutive run: stale slots from a previous lap, or a
        // write published before its copy finished, break the run at a chunk boundary.
        let ring = RingBuffer(capacity: 16384)
        let chunk = 1024, window = 8192
        let source = (1...(1 << 22)).map(Float.init)  // a whole number of chunks; exact in Float up to 2^24
        let writer = Thread {
            source.withUnsafeBufferPointer { all in
                for offset in stride(from: 0, to: all.count, by: chunk) {
                    ring.write(all.baseAddress! + offset, count: chunk)
                }
            }
        }
        let out = UnsafeMutablePointer<Float>.allocate(capacity: window)
        defer { out.deallocate() }
        writer.start()
        var torn = 0, reads = 0
        while !writer.isFinished {
            ring.readLatest(into: out, count: window)
            reads += 1
            let first = out[0]
            guard first != 0 else { continue }  // still zero-filled at startup
            for i in stride(from: chunk - 1, to: window, by: chunk) where out[i] != first + Float(i) {
                torn += 1
                break
            }
        }
        #expect(reads > 100)
        #expect(torn == 0)
    }
}
