import AVFoundation
import AudioToolbox
import CoreAudio
import LocalDictationCore

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let info: InputDeviceInfo
}

final class AudioInputDeviceManager {
    func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let sizeStatus = withUnsafePointer(to: &address) { addressPointer in
            AudioObjectGetPropertyDataSize(
                systemObject,
                addressPointer,
                0,
                nil,
                &dataSize
            )
        }
        guard sizeStatus == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        let status = withUnsafePointer(to: &address) { addressPointer in
            deviceIDs.withUnsafeMutableBufferPointer { buffer in
                AudioObjectGetPropertyData(
                    systemObject,
                    addressPointer,
                    0,
                    nil,
                    &dataSize,
                    buffer.baseAddress!
                )
            }
        }
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { id in
            guard hasInputChannels(for: id),
                  let name = stringProperty(for: id, selector: kAudioDevicePropertyDeviceNameCFString),
                  let uid = stringProperty(for: id, selector: kAudioDevicePropertyDeviceUID) else {
                return nil
            }
            return AudioInputDevice(id: id, info: InputDeviceInfo(name: name, uid: uid))
        }
    }

    func selectedDevice(for preference: InputDevicePreference) -> AudioInputDevice? {
        let devices = inputDevices()
        guard let selectedInfo = InputDeviceSelector.select(
            preference: preference,
            from: devices.map(\.info)
        ) else { return nil }
        return devices.first(where: { $0.info.uid == selectedInfo.uid })
    }

    func configure(_ inputNode: AVAudioInputNode, preference: InputDevicePreference) throws -> InputDeviceInfo {
        guard let selected = selectedDevice(for: preference) else {
            throw AudioInputDeviceError.noPreferredDevice
        }
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioInputDeviceError.audioUnitUnavailable
        }

        var deviceID = selected.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioInputDeviceError.couldNotSelectDevice(selected.info.name, status)
        }
        return selected.info
    }

    private func hasInputChannels(for deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = withUnsafePointer(to: &address) { addressPointer in
            AudioObjectGetPropertyDataSize(deviceID, addressPointer, 0, nil, &dataSize)
        }
        guard sizeStatus == noErr,
              dataSize > 0 else { return false }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        let status = withUnsafePointer(to: &address) { addressPointer in
            AudioObjectGetPropertyData(
                deviceID,
                addressPointer,
                0,
                nil,
                &dataSize,
                rawBuffer
            )
        }
        guard status == noErr else { return false }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.contains(where: { $0.mNumberChannels > 0 })
    }

    private func stringProperty(
        for deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }
}

enum AudioInputDeviceError: LocalizedError {
    case noPreferredDevice
    case audioUnitUnavailable
    case couldNotSelectDevice(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noPreferredDevice:
            return "Neither the preferred HyperX microphone nor the MacBook microphone is available."
        case .audioUnitUnavailable:
            return "The microphone audio unit is unavailable."
        case .couldNotSelectDevice(let name, let status):
            return "Could not select \(name) (Core Audio error \(status))."
        }
    }
}
