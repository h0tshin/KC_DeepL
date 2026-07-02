import AudioToolbox
import CoreAudio
import Foundation

enum LiveAudioDeviceDirection: String {
    case input
    case output

    var coreAudioScope: AudioObjectPropertyScope {
        switch self {
        case .input:
            kAudioDevicePropertyScopeInput
        case .output:
            kAudioDevicePropertyScopeOutput
        }
    }

    var defaultSelector: AudioObjectPropertySelector {
        switch self {
        case .input:
            kAudioHardwarePropertyDefaultInputDevice
        case .output:
            kAudioHardwarePropertyDefaultOutputDevice
        }
    }
}

struct LiveAudioDevice: Identifiable, Hashable {
    let id: String
    let audioObjectID: AudioObjectID?
    let uid: String?
    let name: String
    let channelCount: Int
    let sampleRate: Int
    let direction: LiveAudioDeviceDirection
    let isSystemDefault: Bool

    var displayLabel: String {
        let prefix = isSystemDefault ? "Default" : id
        return "\(prefix): \(name) (\(channelCount)ch, \(sampleRate)Hz)"
    }
}

enum LiveAudioDeviceRegistry {
    static func availableInputDevices() -> [LiveAudioDevice] {
        availableDevices(direction: .input)
    }

    static func availableOutputDevices() -> [LiveAudioDevice] {
        availableDevices(direction: .output)
    }

    static func inputDeviceLabels(including currentSelection: String) -> [String] {
        labels(for: availableInputDevices(), including: currentSelection)
    }

    static func outputDeviceLabels(including currentSelection: String) -> [String] {
        labels(for: availableOutputDevices(), including: currentSelection)
    }

    static func resolveDevice(
        selection: String,
        direction: LiveAudioDeviceDirection,
        preferredNames: [String]
    ) -> LiveAudioDevice {
        let devices = availableDevices(direction: direction)
        guard !devices.isEmpty else {
            return fallbackDevice(direction: direction)
        }

        if let exact = devices.first(where: { $0.displayLabel == selection }) {
            return exact
        }

        let savedName = deviceName(from: selection).lowercased()
        if !savedName.isEmpty,
           let named = devices.first(where: { $0.name.lowercased() == savedName }) {
            return named
        }

        if !savedName.isEmpty,
           let fuzzy = devices.first(where: {
               let name = $0.name.lowercased()
               return name.contains(savedName) || savedName.contains(name)
           }) {
            return fuzzy
        }

        for preferredName in preferredNames {
            if let preferred = devices.first(where: { $0.name.localizedCaseInsensitiveContains(preferredName) }) {
                return preferred
            }
        }

        return devices[0]
    }

    private static func labels(for devices: [LiveAudioDevice], including currentSelection: String) -> [String] {
        var labels = devices.map(\.displayLabel)
        if !currentSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !labels.contains(currentSelection) {
            labels.append(currentSelection)
        }
        return labels
    }

    private static func availableDevices(direction: LiveAudioDeviceDirection) -> [LiveAudioDevice] {
        let defaultDevice = defaultDevice(direction: direction)
        let defaultUID = defaultDevice?.uid
        let concreteDevices = (try? allAudioObjectIDs())?.compactMap { objectID -> LiveAudioDevice? in
            let channelCount = channelCount(for: objectID, scope: direction.coreAudioScope)
            guard channelCount > 0 else {
                return nil
            }

            let name = stringProperty(objectID, selector: kAudioObjectPropertyName) ?? "Unknown Device"
            let uid = stringProperty(objectID, selector: kAudioDevicePropertyDeviceUID)
                ?? "\(objectID)"
            let sampleRate = Int(nominalSampleRate(for: objectID).rounded())

            return LiveAudioDevice(
                id: uid,
                audioObjectID: objectID,
                uid: uid,
                name: name,
                channelCount: channelCount,
                sampleRate: max(sampleRate, 8_000),
                direction: direction,
                isSystemDefault: false
            )
        } ?? []

        let sortedDevices = concreteDevices.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if let defaultDevice {
            let defaultAlias = LiveAudioDevice(
                id: "system-default-\(direction.rawValue)",
                audioObjectID: defaultDevice.audioObjectID,
                uid: nil,
                name: "System default \(direction.rawValue)",
                channelCount: defaultDevice.channelCount,
                sampleRate: defaultDevice.sampleRate,
                direction: direction,
                isSystemDefault: true
            )
            return [defaultAlias] + sortedDevices.filter { $0.uid != defaultUID }
        }

        return sortedDevices.isEmpty ? [fallbackDevice(direction: direction)] : sortedDevices
    }

    private static func defaultDevice(direction: LiveAudioDeviceDirection) -> LiveAudioDevice? {
        guard let objectID = defaultAudioObjectID(direction: direction) else {
            return nil
        }

        let channelCount = max(1, channelCount(for: objectID, scope: direction.coreAudioScope))
        let name = stringProperty(objectID, selector: kAudioObjectPropertyName) ?? "System default \(direction.rawValue)"
        let uid = stringProperty(objectID, selector: kAudioDevicePropertyDeviceUID)
        let sampleRate = Int(nominalSampleRate(for: objectID).rounded())

        return LiveAudioDevice(
            id: uid ?? "system-default-\(direction.rawValue)",
            audioObjectID: objectID,
            uid: uid,
            name: name,
            channelCount: channelCount,
            sampleRate: max(sampleRate, 8_000),
            direction: direction,
            isSystemDefault: false
        )
    }

    private static func fallbackDevice(direction: LiveAudioDeviceDirection) -> LiveAudioDevice {
        LiveAudioDevice(
            id: "system-default-\(direction.rawValue)",
            audioObjectID: nil,
            uid: nil,
            name: "System default \(direction.rawValue)",
            channelCount: direction == .input ? 1 : 2,
            sampleRate: 48_000,
            direction: direction,
            isSystemDefault: true
        )
    }

    private static func allAudioObjectIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else {
            throw LiveAudioQueueError.coreAudio("AudioObjectGetPropertyDataSize(devices)", status)
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = Array(repeating: AudioObjectID(0), count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs)
        guard status == noErr else {
            throw LiveAudioQueueError.coreAudio("AudioObjectGetPropertyData(devices)", status)
        }

        return objectIDs
    }

    private static func defaultAudioObjectID(direction: LiveAudioDeviceDirection) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: direction.defaultSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectID)
        return status == noErr && objectID != 0 ? objectID : nil
    }

    private static func channelCount(for objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              size > 0
        else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, bufferList) == noErr else {
            return 0
        }

        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { total, buffer in
            total + Int(buffer.mNumberChannels)
        }
    }

    private static func nominalSampleRate(for objectID: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(48_000)
        var size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &sampleRate)
        return sampleRate
    }

    private static func stringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let pointer = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        pointer.initialize(to: nil)
        defer {
            pointer.deinitialize(count: 1)
            pointer.deallocate()
        }

        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        guard status == noErr,
              let value = pointer.pointee
        else {
            return nil
        }
        return value as String
    }

    private static func deviceName(from label: String) -> String {
        var value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colonIndex = value.firstIndex(of: ":") {
            value = String(value[value.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = value.range(of: " (", options: .backwards) {
            value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}
