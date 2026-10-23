import AVFoundation
import AudioToolbox
import CoreAudioKit
import os

public struct InstalledPlugin: Identifiable, Hashable {
    public var id: String { "\(type)-\(subType)-\(manufacturer)" }
    public let name: String, vendor: String
    public let type: UInt32, subType: UInt32, manufacturer: UInt32
    public func setting() -> PluginSetting { PluginSetting(name: name, type: type, subType: subType, manufacturer: manufacturer) }
}

public enum Plugins {
    public static let maxFrames: AUAudioFrameCount = 4096

    /// Installed effect Audio Units (Apple and third party).
    public static func installed() -> [InstalledPlugin] {
        var d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        d.componentType = kAudioUnitType_Effect
        return AVAudioUnitComponentManager.shared().components(matching: d).map {
            let c = $0.audioComponentDescription
            return InstalledPlugin(name: $0.name, vendor: $0.manufacturerName, type: c.componentType, subType: c.componentSubType, manufacturer: c.componentManufacturer)
        }.sorted { ($0.vendor, $0.name) < ($1.vendor, $1.name) }
    }

    static func description(_ s: PluginSetting) -> AudioComponentDescription {
        AudioComponentDescription(componentType: s.type, componentSubType: s.subType, componentManufacturer: s.manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }

    public static func encode(_ state: [String: Any]?) -> Data? {
        state.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
    }

    public static func decodeState(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any] }
    }
}

/// One hosted effect instance driven through the classic AudioUnit API.
/// (`AUAudioUnit.renderBlock` returns "no connection" for bridged v2 effects, so the C API is used instead.)
final class UnitSlot {
    let id: UUID
    let unit: AudioUnit
    var state: Data?
    var bypassed: Bool
    var inL: UnsafeMutablePointer<Float>?
    var inR: UnsafeMutablePointer<Float>?

    init(id: UUID, unit: AudioUnit, state: Data?, bypassed: Bool) { self.id = id; self.unit = unit; self.state = state; self.bypassed = bypassed }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    func applyState(_ data: Data?) {
        guard let dict = Plugins.decodeState(data) else { return }
        var info: CFPropertyList = dict as CFDictionary
        AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info, UInt32(MemoryLayout<CFPropertyList>.size))
        state = data
    }

    /// Instantiates (possibly out of process), formats for planar stereo Float32 and initialises.
    static func make(_ s: PluginSetting, sampleRate: Double, completion: @escaping (UnitSlot?) -> Void) {
        var desc = Plugins.description(s)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return completion(nil) }
        AudioComponentInstantiate(comp, []) { unit, status in
            guard status == noErr, let unit else { return completion(nil) }
            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            var frames = UInt32(Plugins.maxFrames)
            let slot = UnitSlot(id: s.id, unit: unit, state: nil, bypassed: s.bypassed)   // owns `unit` from here on
            let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, size) == noErr,
                  AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, size) == noErr else { return completion(nil) }
            AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, 4)
            var callback = AURenderCallbackStruct(inputProc: { ref, _, _, _, count, data in
                let slot = Unmanaged<UnitSlot>.fromOpaque(ref).takeUnretainedValue()
                let list = UnsafeMutableAudioBufferListPointer(data!)
                guard let l = slot.inL, let r = slot.inR, list.count >= 2 else { return kAudioUnitErr_NoConnection }
                memcpy(list[0].mData, l, Int(count) * 4); memcpy(list[1].mData, r, Int(count) * 4)
                return noErr
            }, inputProcRefCon: Unmanaged.passUnretained(slot).toOpaque())
            guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
                  AudioUnitInitialize(unit) == noErr else { return completion(nil) }
            slot.applyState(s.state)
            completion(slot)
        }
    }
}

/// Real-time chain of Audio Units. Units are built asynchronously and swapped in under a try-lock.
public final class PluginChain {
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var slots: [UnitSlot] = []
    private var wanted: [PluginSetting] = []
    private var rate = 0.0
    private var generation = 0
    private let outL = UnsafeMutablePointer<Float>.allocate(capacity: Int(Plugins.maxFrames))
    private let outR = UnsafeMutablePointer<Float>.allocate(capacity: Int(Plugins.maxFrames))
    private var outList = AudioBufferList.allocate(maximumBuffers: 2)
    private var sampleTime: Float64 = 0

    public init() { lock.initialize(to: os_unfair_lock()) }

    deinit {
        lock.deallocate(); outL.deallocate(); outR.deallocate()
        free(outList.unsafeMutablePointer)
    }

    public var loadedCount: Int { slots.count }

    /// Main thread. Rebuilds units only when the list or sample rate changed; otherwise just syncs state/bypass.
    public func configure(_ settings: [PluginSetting], sampleRate: Double) {
        if settings.map(\.id) == wanted.map(\.id), sampleRate == rate {
            for s in settings {
                guard let slot = slots.first(where: { $0.id == s.id }) else { continue }
                slot.bypassed = s.bypassed
                if s.state != slot.state {
                    os_unfair_lock_lock(lock); slot.applyState(s.state); os_unfair_lock_unlock(lock)
                }
            }
            wanted = settings
            return
        }
        wanted = settings; rate = sampleRate; generation += 1
        let gen = generation
        let group = DispatchGroup()
        var built: [UUID: UnitSlot] = [:]
        let guardBuilt = NSLock()
        for s in settings {
            group.enter()
            UnitSlot.make(s, sampleRate: sampleRate) { slot in
                if let slot { guardBuilt.lock(); built[s.id] = slot; guardBuilt.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [self] in
            guard gen == generation else { return }
            let new = settings.compactMap { built[$0.id] }
            os_unfair_lock_lock(lock)
            slots = new
            os_unfair_lock_unlock(lock)
        }
    }

    public func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        guard !slots.isEmpty, os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, Int(Plugins.maxFrames))
            for slot in slots where !slot.bypassed { render(slot, l + offset, r + offset, n) }
            offset += n
        }
    }

    private func render(_ slot: UnitSlot, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        slot.inL = l; slot.inR = r
        outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: outL)
        outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: outR)
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime; ts.mFlags = .sampleTimeValid
        sampleTime += Float64(n)
        guard AudioUnitRender(slot.unit, &flags, &ts, 0, UInt32(n), outList.unsafeMutablePointer) == noErr else { return }
        if let d = outList[0].mData { memcpy(l, d, n * 4) }
        if let d = outList[1].mData { memcpy(r, d, n * 4) }
    }
}
