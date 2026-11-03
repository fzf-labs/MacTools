import CoreAudio
import Foundation

/// Core Audio only; unsupported hardware fails instead of pretending that a key press worked.
enum LauncherSystemAudio {
    static func perform(_ command: LauncherSystemAction) throws {
        let input = command == .toggleMicrophoneMute
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        let deviceSelector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        let device: AudioDeviceID = try read(AudioObjectID(kAudioObjectSystemObject), address(deviceSelector), initial: AudioDeviceID(0))
        guard device != kAudioObjectUnknown else { throw Failure.unsupported }
        if command == .toggleMute || input {
            let controls = try elements(device, selector: kAudioDevicePropertyMute, scope: scope)
            let old: [UInt32] = try controls.map { try read(device, address(kAudioDevicePropertyMute, scope, $0), initial: UInt32(0)) }
            try write(device, selector: kAudioDevicePropertyMute, scope: scope, elements: controls,
                      values: controls.map { _ in old.allSatisfy { $0 != 0 } ? UInt32(0) : UInt32(1) }, previous: old)
        } else {
            let controls = try elements(device, selector: kAudioDevicePropertyVolumeScalar, scope: scope)
            let old: [Float32] = try controls.map { try read(device, address(kAudioDevicePropertyVolumeScalar, scope, $0), initial: Float32(0)) }
            guard old.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.unsupported }
            let target: Float32?
            switch command {
            case .volume0: target = 0
            case .volume25: target = 0.25
            case .volume50: target = 0.5
            case .volume75: target = 0.75
            case .volume100: target = 1
            default: target = nil
            }
            let levels = old.map { min(1, max(0, target ?? ($0 + (command == .volumeUp ? 0.0625 : -0.0625)))) }
            try write(device, selector: kAudioDevicePropertyVolumeScalar, scope: scope, elements: controls, values: levels, previous: old)
            // A volume command also unmutes outputs that expose a writable mute control.
            if let muteControls = try? elements(device, selector: kAudioDevicePropertyMute, scope: scope) {
                let previous: [UInt32] = try muteControls.map { try read(device, address(kAudioDevicePropertyMute, scope, $0), initial: UInt32(0)) }
                try write(device, selector: kAudioDevicePropertyMute, scope: scope, elements: muteControls,
                          values: muteControls.map { _ in UInt32(0) }, previous: previous)
            }
        }
    }
    enum Failure: Error { case unsupported }
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: element)
    }
    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, initial: T) throws -> T {
        var property = property
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { throw Failure.unsupported }
        return value
    }
    private static func elements(_ device: AudioDeviceID, selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope) throws -> [AudioObjectPropertyElement] {
        func writable(_ element: AudioObjectPropertyElement) -> Bool {
            var property = address(selector, scope, element)
            var settable = DarwinBoolean(false)
            return AudioObjectHasProperty(device, &property)
                && AudioObjectIsPropertySettable(device, &property, &settable) == noErr && settable.boolValue
        }
        if writable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        var configuration = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &configuration, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { throw Failure.unsupported }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &configuration, 0, nil, &size, storage) == noErr else { throw Failure.unsupported }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let count = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard count > 0 else { throw Failure.unsupported }
        let channels = (1...count).map { AudioObjectPropertyElement($0) }
        guard channels.allSatisfy(writable) else { throw Failure.unsupported }
        return channels
    }
    private static func write<T: BitwiseCopyable>(_ device: AudioDeviceID, selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope, elements: [AudioObjectPropertyElement],
                                 values: [T], previous: [T]) throws {
        for index in elements.indices {
            var property = address(selector, scope, elements[index])
            var value = values[index]
            guard AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr else {
                for rollback in elements.indices where rollback < index {
                    var oldProperty = address(selector, scope, elements[rollback])
                    var oldValue = previous[rollback]
                    _ = AudioObjectSetPropertyData(device, &oldProperty, 0, nil, UInt32(MemoryLayout<T>.size), &oldValue)
                }
                throw Failure.unsupported
            }
        }
    }
}
