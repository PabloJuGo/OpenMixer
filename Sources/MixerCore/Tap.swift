import CoreAudio
import Foundation

public enum TapError: Error, LocalizedError {
    case failed(String, OSStatus)
    public var errorDescription: String? {
        if case let .failed(what, status) = self {
            return "\(what) failed (\(status)). Allow audio capture for OpenMixer in System Settings › Privacy & Security."
        }
        return nil
    }
}

public enum TapSource: Equatable {
    case processes(Set<AudioObjectID>)
    case global(excluding: Set<AudioObjectID>)
}

/// Captures audio with a Core Audio process tap and, unless `meterOnly`, silences the original and replays it
/// through `chain` on an output device. A tap lives only while something needs processing.
public final class Tap {
    public let source: TapSource
    public let outputUID: String
    public let chain: [Processor]
    public let meterOnly: Bool
    public let sampleRate: Double
    /// Peak of the captured signal (meter-only taps).
    public private(set) var inputPeak: Float = 0
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    public init(source: TapSource, outputUID: String, outputID: AudioObjectID, chain: [Processor], meterOnly: Bool = false) throws {
        self.source = source; self.outputUID = outputUID; self.chain = chain; self.meterOnly = meterOnly
        sampleRate = Devices.sampleRate(of: outputID)
        do { try start() } catch { stop(); throw error }
    }

    deinit { stop() }

    private func start() throws {
        let description: CATapDescription
        switch source {
        case .processes(let p): description = CATapDescription(stereoMixdownOfProcesses: Array(p))
        case .global(let excluded): description = CATapDescription(stereoGlobalTapButExcludeProcesses: Array(excluded))
        }
        description.uuid = UUID()
        description.muteBehavior = meterOnly ? .unmuted : .mutedWhenTapped
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.failed("Creating the audio tap", status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenMixer Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError.failed("Creating the aggregate device", status) }

        let scratch = Scratch()
        let chain = self.chain, meterOnly = self.meterOnly
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, DispatchQueue(label: "openmixer.tap", qos: .userInteractive)) { [weak self] _, input, _, output, _ in
            let peak = Render.run(input: input, output: output, chain: chain, scratch: scratch, silent: meterOnly)
            if meterOnly { self?.inputPeak = peak }
        }
        guard status == noErr else { throw TapError.failed("Creating the IO proc", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.failed("Starting playback", status) }
    }

    public func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

/// Preallocated planar work buffers for the audio thread.
final class Scratch {
    static let frames = 4096
    let l = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    deinit { l.deallocate(); r.deallocate() }
}

/// Real-time glue between Core Audio buffer lists and the planar `Processor` chain. No allocation here.
enum Render {
    /// Locates logical channel `channel` across buffers (interleaved or planar Float32).
    static func locate(_ list: UnsafeMutableAudioBufferListPointer, _ channel: Int) -> (data: UnsafeMutablePointer<Float>, stride: Int, frames: Int)? {
        var first = 0
        for b in list {
            let n = Int(b.mNumberChannels)
            guard n > 0, let data = b.mData else { continue }
            if channel < first + n {
                return (data.assumingMemoryBound(to: Float.self) + (channel - first), n, Int(b.mDataByteSize) / (n * 4))
            }
            first += n
        }
        return nil
    }

    static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var n = 0
        for b in list { n += Int(b.mNumberChannels) }
        return n
    }

    /// Returns the input peak. With `silent`, only measures and writes zeros.
    @discardableResult
    static func run(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                    chain: [Processor], scratch: Scratch, silent: Bool) -> Float {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        for b in outList { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }

        let inChannels = channelCount(inList), outChannels = channelCount(outList)
        guard inChannels > 0, let left = locate(inList, 0), let right = locate(inList, min(1, inChannels - 1)) else { return 0 }
        let total = min(left.frames, right.frames)
        var peak: Float = 0
        var offset = 0
        while offset < total {
            let n = min(total - offset, Scratch.frames)
            for i in 0..<n {
                scratch.l[i] = left.data[(offset + i) * left.stride]
                scratch.r[i] = right.data[(offset + i) * right.stride]
                peak = max(peak, abs(scratch.l[i]), abs(scratch.r[i]))
            }
            if !silent {
                for p in chain { p.process(scratch.l, scratch.r, frames: n) }
                if outChannels == 1, let o = locate(outList, 0) {
                    for i in 0..<min(n, o.frames - offset) { o.data[(offset + i) * o.stride] = (scratch.l[i] + scratch.r[i]) * 0.5 }
                } else {
                    for ch in 0..<min(2, outChannels) {
                        guard let o = locate(outList, ch) else { continue }
                        let src = ch == 0 ? scratch.l : scratch.r
                        for i in 0..<min(n, o.frames - offset) { o.data[(offset + i) * o.stride] = src[i] }
                    }
                }
            }
            offset += n
        }
        return peak
    }
}
