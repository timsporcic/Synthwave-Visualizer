import CoreAudio

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let selector: AudioObjectPropertySelector
    var description: String { "Core Audio property \(fourCC(selector)) failed with status \(status)" }
}

/// Thin wrappers over AudioObjectGetPropertyData for the global-scope properties this app reads.
nonisolated enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as _: T.Type) throws -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, value)
        guard err == noErr else { throw CoreAudioError(status: err, selector: selector) }
        return value.pointee
    }

    static func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, of _: T.Type) throws -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard err == noErr else { throw CoreAudioError(status: err, selector: selector) }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let values = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { values.deallocate() }
        err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, values)
        guard err == noErr else { throw CoreAudioError(status: err, selector: selector) }
        return Array(UnsafeBufferPointer(start: values, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard err == noErr else { throw CoreAudioError(status: err, selector: selector) }
        return value?.takeRetainedValue() as String? ?? ""
    }
}

nonisolated func fourCC(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
    return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? "'\(String(decoding: bytes, as: UTF8.self))'" : "\(code)"
}
