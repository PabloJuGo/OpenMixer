import CoreAudio
import Foundation

public struct AudioDevice: Identifiable, Hashable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
}

public enum Direction {
    case output, input
    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }
    var defaultSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

public enum Devices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func list(_ direction: Direction) -> [AudioDevice] {
        HAL.array(system, HAL.address(kAudioHardwarePropertyDevices), zero: AudioObjectID(0)).compactMap { id in
            guard !HAL.array(id, HAL.address(kAudioDevicePropertyStreams, direction.scope), zero: AudioObjectID(0)).isEmpty,
                  let uid = HAL.string(id, HAL.address(kAudioDevicePropertyDeviceUID)),
                  let name = HAL.string(id, HAL.address(kAudioObjectPropertyName)) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    public static func defaultDevice(_ direction: Direction) -> AudioObjectID? {
        HAL.get(system, HAL.address(direction.defaultSelector), AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    @discardableResult
    public static func setDefault(_ id: AudioObjectID, _ direction: Direction) -> Bool {
        HAL.set(system, HAL.address(direction.defaultSelector), id)
    }

    public static func uid(of id: AudioObjectID) -> String? {
        HAL.string(id, HAL.address(kAudioDevicePropertyDeviceUID))
    }

    public static func sampleRate(of id: AudioObjectID) -> Double {
        HAL.get(id, HAL.address(kAudioDevicePropertyNominalSampleRate), Float64(0)).flatMap { $0 > 0 ? $0 : nil } ?? 48_000
    }

    /// Master element if the device has one, else the stereo channels.
    private static func elements(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> [AudioObjectPropertyElement] {
        if HAL.has(id, HAL.address(selector, scope, kAudioObjectPropertyElementMain)) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { HAL.has(id, HAL.address(selector, scope, $0)) }
    }

    public static func volume(_ id: AudioObjectID, _ direction: Direction) -> Float? {
        let values = elements(id, kAudioDevicePropertyVolumeScalar, direction.scope).compactMap {
            HAL.get(id, HAL.address(kAudioDevicePropertyVolumeScalar, direction.scope, $0), Float32(0))
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    public static func setVolume(_ id: AudioObjectID, _ direction: Direction, _ value: Float) {
        for e in elements(id, kAudioDevicePropertyVolumeScalar, direction.scope) {
            HAL.set(id, HAL.address(kAudioDevicePropertyVolumeScalar, direction.scope, e), Float32(value))
        }
    }

    public static func isMuted(_ id: AudioObjectID, _ direction: Direction) -> Bool? {
        elements(id, kAudioDevicePropertyMute, direction.scope).first.flatMap {
            HAL.get(id, HAL.address(kAudioDevicePropertyMute, direction.scope, $0), UInt32(0))
        }.map { $0 != 0 }
    }

    public static func setMuted(_ id: AudioObjectID, _ direction: Direction, _ muted: Bool) {
        for e in elements(id, kAudioDevicePropertyMute, direction.scope) {
            HAL.set(id, HAL.address(kAudioDevicePropertyMute, direction.scope, e), UInt32(muted ? 1 : 0))
        }
    }
}

extension Devices {
    public static var systemOutput: AudioObjectID? {
        HAL.get(AudioObjectID(kAudioObjectSystemObject), HAL.address(kAudioHardwarePropertyDefaultSystemOutputDevice), AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    @discardableResult
    public static func setSystemOutput(_ id: AudioObjectID) -> Bool {
        HAL.set(AudioObjectID(kAudioObjectSystemObject), HAL.address(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
    }

    public static func hasHardwareVolume(_ id: AudioObjectID) -> Bool { volume(id, .output) != nil }
    public static func hasHardwareMute(_ id: AudioObjectID) -> Bool { isMuted(id, .output) != nil }

    public static func transportType(_ id: AudioObjectID) -> UInt32 {
        HAL.get(id, HAL.address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
    }

    public static func isBluetooth(_ id: AudioObjectID) -> Bool {
        [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transportType(id))
    }

    public static func isAirPlay(_ id: AudioObjectID) -> Bool { transportType(id) == kAudioDeviceTransportTypeAirPlay }

    public static func availableSampleRates(_ id: AudioObjectID) -> [Double] {
        let ranges = HAL.array(id, HAL.address(kAudioDevicePropertyAvailableNominalSampleRates), zero: AudioValueRange())
        let common: [Double] = [8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000]
        let rates = ranges.flatMap { r in r.mMinimum == r.mMaximum ? [r.mMinimum] : common.filter { $0 >= r.mMinimum && $0 <= r.mMaximum } }
        return Array(Set(rates)).sorted()
    }

    @discardableResult
    public static func setSampleRate(_ id: AudioObjectID, _ rate: Double) -> Bool {
        HAL.set(id, HAL.address(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    /// Calls `body` whenever the listed properties change (on the main queue). Returns a token to cancel.
    public static func observe(_ object: AudioObjectID, _ addresses: [AudioObjectPropertyAddress], _ body: @escaping () -> Void) -> () -> Void {
        let block: AudioObjectPropertyListenerBlock = { _, _ in body() }
        for a in addresses { var a = a; AudioObjectAddPropertyListenerBlock(object, &a, .main, block) }
        return { for a in addresses { var a = a; AudioObjectRemovePropertyListenerBlock(object, &a, .main, block) } }
    }
}
