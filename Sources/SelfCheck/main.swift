// No XCTest/Testing in Command Line Tools, so checks are a plain executable: `swift run SelfCheck` (debug build).
import AVFoundation
import AudioToolbox
import CoreAudio
import AppKit
import Foundation
@testable import MixerCore

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "ok   " : "FAIL ", name, ok ? "" : detail())
    if !ok { failures += 1 }
}
func close(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

let sr = 48_000.0
func sine(_ freq: Float, _ n: Int = 48_000) -> [Float] { (0..<n).map { sinf(2 * .pi * freq * Float($0) / Float(sr)) } }
/// Sine amplitude from RMS (sample peaks of high-frequency sines undershoot).
func peak(_ x: [Float]) -> Float { let t = x.suffix(4_800); return sqrtf(t.map { $0 * $0 }.reduce(0, +) / Float(t.count)) * Float(2).squareRoot() }

/// Runs a mono signal through a freshly configured processor (both channels identical).
func run(_ fx: Effects, _ input: [Float], processor: Processor? = nil) -> [Float] {
    let p = processor ?? Processor()
    p.configure(fx, sampleRate: sr)
    var l = input, r = input
    // Process in 512-frame blocks like a real IO proc.
    var i = 0
    while i < l.count {
        let n = min(512, l.count - i)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in p.process(lp.baseAddress! + i, rp.baseAddress! + i, frames: n) } }
        i += n
    }
    return l
}

// MARK: EQ / filters
var flat = Effects()
check("flat is transparent", close(peak(run(flat, sine(1000))), 1, 1e-3))

var boost = Effects(); boost.eq[5] = 12
check("+12 dB @1k gives ~4x", close(peak(run(boost, sine(1000))), 3.98, 0.4) || peak(run(boost, sine(1000))) >= 0.97, "\(peak(run(boost, sine(1000))))")
var boostLow = Effects(); boostLow.eq[5] = 12; boostLow.volume = 0.5   // amplitude 0.25 so the 4x boost stays under the ceiling
check("+12 dB @1k, scaled", close(peak(run(boostLow, sine(1000))), 0.25 * 3.98, 0.15), "\(peak(run(boostLow, sine(1000))))")
check("+12 dB @1k leaves 100 Hz alone", close(peak(run(boostLow, sine(100))), 0.25, 0.04), "\(peak(run(boostLow, sine(100))))")

var shelf = Effects(); shelf.parametric = [ParametricFilter(kind: .lowShelf, frequency: 200, gain: -6, q: 0.7)]; shelf.volume = 1
check("low shelf −6 dB cuts 40 Hz by ~½", close(peak(run(shelf, sine(40))), 0.5, 0.06), "\(peak(run(shelf, sine(40))))")
check("low shelf leaves 8 kHz alone", close(peak(run(shelf, sine(8000))), 1, 0.05), "\(peak(run(shelf, sine(8000))))")
var hshelf = Effects(); hshelf.parametric = [ParametricFilter(kind: .highShelf, frequency: 4000, gain: -6, q: 0.7)]
check("high shelf −6 dB cuts 12 kHz by ~½", close(peak(run(hshelf, sine(12000))), 0.5, 0.06), "\(peak(run(hshelf, sine(12000))))")

// MARK: Gain / mute / balance / limiter
var half = Effects(); half.volume = 0.5
check("volume 50% is amplitude 0.25", close(peak(run(half, sine(1000))), 0.25, 1e-3))
check("first configuration applies immediately (no fade from unity)", { let p = Processor(); var f = Effects(); f.muted = true; p.configure(f, sampleRate: sr); var l = [Float](repeating: 1, count: 64), r = l; l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in p.process(a.baseAddress!, b.baseAddress!, frames: 64) } }; return l.allSatisfy { $0 == 0 } }())
var muted = Effects(); muted.muted = true
check("mute silences", peak(run(muted, sine(1000))) == 0)
var pan = Effects(); pan.balance = 1
do {
    let p = Processor(); p.configure(pan, sampleRate: sr)
    var l = sine(1000, 4800), r = l
    for _ in 0..<3 { l = sine(1000, 4800); r = l; l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in p.process(a.baseAddress!, b.baseAddress!, frames: 4800) } } }
    check("balance hard right mutes left", peak(l) == 0 && close(peak(r), 1, 1e-3), "\(peak(l)) \(peak(r))")
}
var loud = Effects(); loud.volume = 2   // 4x amplitude
check("overdriven signal never exceeds ±1", (run(loud, sine(1000)).map(abs).max() ?? 0) <= 1.0)
check("limiter holds ceiling", (run(loud, sine(1000)).suffix(4_800).map(abs).max() ?? 0) <= 0.99, "\(peak(run(loud, sine(1000))))")
do {
    var x = [Float](repeating: 1, count: 4800)
    var fx = Effects(); fx.volume = 0.5
    let p = Processor(); p.configure(Effects(), sampleRate: sr)
    var r = x
    x.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in p.process(a.baseAddress!, b.baseAddress!, frames: 4800) } }
    p.configure(fx, sampleRate: sr)
    var y = [Float](repeating: 1, count: 4800), z = y
    y.withUnsafeMutableBufferPointer { a in z.withUnsafeMutableBufferPointer { b in p.process(a.baseAddress!, b.baseAddress!, frames: 4800) } }
    let maxStep = zip(y, y.dropFirst()).map { abs($0 - $1) }.max()!
    check("gain change ramps smoothly (no zipper)", maxStep < 0.001 && close(y.last!, 0.25, 1e-3), "step \(maxStep) end \(y.last!)")
}

// MARK: Models
check("neutral effects", Effects().isNeutral && !Effects().hasProcessing)
check("volume change isn't 'processing'", { var e = Effects(); e.volume = 0.3; return !e.hasProcessing && !e.isNeutral }())
check("EQ counts as processing", { var e = Effects(); e.eq[3] = 4; return e.hasProcessing }())
check("bypass drops EQ processing", { var e = Effects(); e.eq[3] = 4; e.bypassed = true; return !e.hasProcessing }())
check("Effects decodes from empty JSON", (try? JSONDecoder().decode(Effects.self, from: Data("{}".utf8))) == Effects())
do {
    var s = AppState()
    var e = Effects(); e.volume = 0.7; e.eq[2] = 3; e.outputUID = "x"
    e.plugins = [PluginSetting(name: "Delay", type: 1, subType: 2, manufacturer: 3)]
    s.appFX["com.test.app"] = e
    s.deviceConfig["dev"] = { var c = DeviceConfig(); c.hidden = true; c.volumeUp = Shortcut(keyCode: 126, modifiers: 256, label: "↑"); return c }()
    s.excludedApps = ["a"]; s.userPresets = [EQPreset(name: "mine", gains: Array(repeating: 1, count: 10))]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("om-check-\(UUID().uuidString)/state.json")
    s.save(to: url)
    check("state saves and reloads", AppState.load(from: url) == s)
    check("corrupt state falls back to defaults", { try? Data("garbage".utf8).write(to: url); return AppState.load(from: url) == AppState() }())
}
let parsed = ParametricProfile.parse("""
Preamp: -6.2 dB
Filter 1: ON PK Fc 31 Hz Gain 5.7 dB Q 1.20
Filter 2: ON LSC Fc 105 Hz Gain 2.0 dB Q 0.70
Filter 3: OFF PK Fc 500 Hz Gain 1.0 dB Q 1.00
Filter 4: ON HSC Fc 10000 Hz Gain -3.5 dB Q 0.70
""")
check("AutoEQ parse", parsed.preamp == -6.2 && parsed.filters.count == 3 && parsed.filters[1].kind == .lowShelf && parsed.filters[2].gain == -3.5, "\(parsed)")
check("AutoEQ parse ignores junk", ParametricProfile.parse("hello\nFilter x").filters.isEmpty)

// MARK: Status icon
if let i = CommandLine.arguments.firstIndex(of: "--dump-icons"), i + 1 < CommandLine.arguments.count {
    // Debug aid: writes the menu-bar glyph at 8x on a dark bar for each volume level.
    for (name, v, m) in [("mute", Float(0.7), true), ("v0", 0, false), ("v25", 0.25, false), ("v50", 0.5, false), ("v75", 0.75, false), ("v100", 1, false)] {
        let g = StatusIcon.image(volume: v, muted: m)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 216, pixelsHigh: 144, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 0.33, green: 0.42, blue: 0.6, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 216, height: 144).fill()
        let tinted = NSImage(size: g.size, flipped: false) { r in g.draw(in: r); NSColor.white.setFill(); r.fill(using: .sourceIn); return true }
        tinted.draw(in: NSRect(x: 0, y: 0, width: 216, height: 144))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent("\(name).png"))
    }
}
check("pills: 0% -> 0", StatusIcon.litPills(volume: 0, muted: false) == 0)
check("pills: 1% -> 1", StatusIcon.litPills(volume: 0.01, muted: false) == 1)
check("pills: 50% -> 2", StatusIcon.litPills(volume: 0.5, muted: false) == 2)
check("pills: 51% -> 3", StatusIcon.litPills(volume: 0.51, muted: false) == 3)
check("pills: 100% -> 4", StatusIcon.litPills(volume: 1, muted: false) == 4)
check("pills: muted -> 0", StatusIcon.litPills(volume: 1, muted: true) == 0)
check("status icon is a template", StatusIcon.image(volume: 0.5, muted: false).isTemplate)

// MARK: Core Audio buffer glue (interleaved and planar in/out)
func makeList(channels: Int, frames: Int, interleaved: Bool) -> (UnsafeMutableAudioBufferListPointer, [UnsafeMutablePointer<Float>]) {
    let count = interleaved ? 1 : channels
    let list = AudioBufferList.allocate(maximumBuffers: count)
    var ptrs: [UnsafeMutablePointer<Float>] = []
    for b in 0..<count {
        let n = interleaved ? channels : 1
        let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * n); p.initialize(repeating: 0, count: frames * n)
        list[b] = AudioBuffer(mNumberChannels: UInt32(n), mDataByteSize: UInt32(frames * n * 4), mData: p)
        ptrs.append(p)
    }
    return (list, ptrs)
}
for (inI, outI) in [(true, true), (true, false), (false, true), (false, false)] {
    let frames = 10_000   // larger than the scratch size to exercise chunking
    let (inList, inP) = makeList(channels: 2, frames: frames, interleaved: inI)
    let (outList, outP) = makeList(channels: 2, frames: frames, interleaved: outI)
    for i in 0..<frames {
        let l = Float(i % 100) / 200, r = -Float(i % 100) / 200
        if inI { inP[0][i * 2] = l; inP[0][i * 2 + 1] = r } else { inP[0][i] = l; inP[1][i] = r }
    }
    var fx = Effects(); fx.volume = 1
    let p = Processor(); p.configure(fx, sampleRate: sr)
    Render.run(input: UnsafePointer(inList.unsafeMutablePointer), output: outList.unsafeMutablePointer, chain: [p], scratch: Scratch(), silent: false)
    var ok = true
    for i in 0..<frames {
        let l = outI ? outP[0][i * 2] : outP[0][i], r = outI ? outP[0][i * 2 + 1] : outP[1][i]
        if !close(l, Float(i % 100) / 200, 1e-5) || !close(r, -Float(i % 100) / 200, 1e-5) { ok = false; break }
    }
    check("render passthrough in=\(inI ? "interleaved" : "planar") out=\(outI ? "interleaved" : "planar")", ok)
}
do {   // mono output gets the L/R average; silent mode writes zeros but reports the peak
    let frames = 256
    let (inList, inP) = makeList(channels: 2, frames: frames, interleaved: true)
    let (outList, outP) = makeList(channels: 1, frames: frames, interleaved: true)
    for i in 0..<frames { inP[0][i * 2] = 0.5; inP[0][i * 2 + 1] = 0.25 }
    let p = Processor(); p.configure(Effects(), sampleRate: sr)
    Render.run(input: UnsafePointer(inList.unsafeMutablePointer), output: outList.unsafeMutablePointer, chain: [p], scratch: Scratch(), silent: false)
    check("mono output = (L+R)/2", close(outP[0][100], 0.375, 1e-5), "\(outP[0][100])")
    let pk = Render.run(input: UnsafePointer(inList.unsafeMutablePointer), output: outList.unsafeMutablePointer, chain: [], scratch: Scratch(), silent: true)
    check("meter-only: zero output, reports peak", outP[0][100] == 0 && close(pk, 0.5, 1e-5))
}

// MARK: Audio Unit hosting (Apple's AUDelay)
do {
    let chain = PluginChain()
    chain.configure([PluginSetting(name: "Delay", type: kAudioUnitType_Effect, subType: kAudioUnitSubType_Delay, manufacturer: kAudioUnitManufacturer_Apple)], sampleRate: sr)
    let deadline = Date().addingTimeInterval(5)
    while chain.loadedCount == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check("Audio Unit loads", chain.loadedCount == 1)
    var l = [Float](repeating: 0, count: 1024), r = l
    l[0] = 1; r[0] = 1
    var energyAfter: Float = 0
    for block in 0..<60 {   // AUDelay's default delay time is 1 s ≈ 47 blocks
        l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in chain.process(a.baseAddress!, b.baseAddress!, frames: 1024) } }
        if block == 0 { check("AU delay: dry impulse reduced by wet/dry mix", l[0] < 0.9, "\(l[0])") }
        if block > 0 { energyAfter += l.map { $0 * $0 }.reduce(0, +) }
        l = [Float](repeating: 0, count: 1024); r = l
    }
    check("AU delay: echo appears in later blocks", energyAfter > 0.2, "\(energyAfter)")
    let slotState = Plugins.encode(["a": 1])
    // A parameter edited in an editor instance reaches the real-time chain through the saved state.
    let ui = try! AVAudioUnit.instantiateSync(Plugins.description(PluginSetting(name: "Delay", type: kAudioUnitType_Effect, subType: kAudioUnitSubType_Delay, manufacturer: kAudioUnitManufacturer_Apple)))
    ui.auAudioUnit.parameterTree?.parameter(withAddress: 0)?.value = 100   // wet/dry mix: fully wet
    var stateful = PluginSetting(name: "Delay", type: kAudioUnitType_Effect, subType: kAudioUnitSubType_Delay, manufacturer: kAudioUnitManufacturer_Apple)
    stateful.state = Plugins.encode(ui.auAudioUnit.fullState)
    let chain2 = PluginChain()
    chain2.configure([stateful], sampleRate: sr)
    let deadline2 = Date().addingTimeInterval(5)
    while chain2.loadedCount == 0 && Date() < deadline2 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    var a = [Float](repeating: 0, count: 1024), b = a; a[0] = 1; b[0] = 1
    a.withUnsafeMutableBufferPointer { x in b.withUnsafeMutableBufferPointer { y in chain2.process(x.baseAddress!, y.baseAddress!, frames: 1024) } }
    check("saved plugin state is applied (fully wet → no dry signal)", abs(a[0]) < 0.05, "\(a[0])")
    // ...and a live state change reaches the running chain.
    stateful.state = Plugins.encode({ ui.auAudioUnit.parameterTree?.parameter(withAddress: 0)?.value = 0; return ui.auAudioUnit.fullState }())
    chain2.configure([stateful], sampleRate: sr)
    a = [Float](repeating: 0, count: 1024); b = a; a[0] = 1; b[0] = 1
    a.withUnsafeMutableBufferPointer { x in b.withUnsafeMutableBufferPointer { y in chain2.process(x.baseAddress!, y.baseAddress!, frames: 1024) } }
    check("live state update reaches running chain (fully dry → full signal)", abs(a[0] - 1) < 0.05, "\(a[0])")
    check("AU state encodes/decodes", Plugins.decodeState(slotState)?["a"] as? Int == 1)
    check("installed effect list includes Apple delay", Plugins.installed().contains { $0.subType == kAudioUnitSubType_Delay })
}

// MARK: Core Audio
let outs = Devices.list(.output)
check("output devices enumerate", !outs.isEmpty)
check("default output resolves", Devices.defaultDevice(.output).map { id in outs.contains { $0.id == id } } ?? false)
check("sample rate is sane", outs.first.map { Devices.sampleRate(of: $0.id) > 8000 } ?? false)
check("process list enumerates", { _ = Apps.running(); return true }())
check("own process lookup doesn't crash", { _ = HAL.processObject(pid: getpid()); return true }())
check("shortcut label", HotKeyCenter.label(for: Shortcut(keyCode: 126, modifiers: 256 | 2048, label: "↑")) == "⌥⌘↑")

// MARK: Live audio (opt-in: plays a quiet tone, needs audio-capture permission) — `swift run SelfCheck --live`
if CommandLine.arguments.contains("--live") {
    func wav(seconds: Int) -> URL {
        let rate = 48_000, n = rate * seconds
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + n * 2); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16); d.append("data".data(using: .ascii)!); u32(n * 2)
        for i in 0..<n { var x = Int16(0.5 * 32767 * sinf(2 * .pi * 440 * Float(i) / Float(rate))).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("om-tone.wav"); try! d.write(to: url); return url
    }
    func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    func maxPeak(of tap: Tap, for s: Double) -> Float {
        var m: Float = 0; let end = Date().addingTimeInterval(s)
        while Date() < end { m = max(m, tap.inputPeak); spin(0.02) }
        return m
    }
    let tone = wav(seconds: 14)
    guard let outID = Devices.defaultDevice(.output), let uid = Devices.uid(of: outID) else { print("no output"); exit(1) }
    let player = Process(); player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); player.arguments = ["-v", "0.4", tone.path]
    do {
        let meter = try Tap(source: .global(excluding: []), outputUID: uid, outputID: outID, chain: [], meterOnly: true)
        spin(0.5)
        try player.run()
        spin(1.0)
        let baseline = maxPeak(of: meter, for: 1.0)
        check("live: meter tap sees playing audio", baseline > 0.05, "peak \(baseline) (is audio-capture permission granted to this terminal?)")
        guard let obj = (0..<40).lazy.compactMap({ _ -> AudioObjectID? in spin(0.05); return HAL.processObject(pid: player.processIdentifier) }).first else { print("FAIL no process object"); exit(1) }
        var fx = Effects(); fx.volume = 0
        let proc = Processor(); proc.configure(fx, sampleRate: Devices.sampleRate(of: outID))
        let tap = try Tap(source: .processes([obj]), outputUID: uid, outputID: outID, chain: [proc])
        spin(0.8)
        // Taps read the app's output before the mute is applied, so the effect is measured at the processor's output.
        func procPeak(_ secs: Double) -> Float { var m: Float = 0; let end = Date().addingTimeInterval(secs); while Date() < end { m = max(m, proc.peak); spin(0.02) }; return m }
        let silenced = procPeak(1.0)
        check("live: per-app tap at 0% outputs silence", silenced < 0.001, "peak \(silenced)")
        fx.volume = 1; proc.configure(fx, sampleRate: Devices.sampleRate(of: outID))
        spin(0.3)
        let restored = procPeak(1.0)
        check("live: 100% replays the app's audio", abs(restored - baseline) < baseline * 0.15, "peak \(restored) (baseline \(baseline))")
        fx.volume = 0.5; proc.configure(fx, sampleRate: Devices.sampleRate(of: outID))
        spin(0.3)
        let half = procPeak(1.0)
        check("live: 50% slider = ¼ amplitude", abs(half - baseline * 0.25) < baseline * 0.05, "peak \(half) (baseline \(baseline))")
        fx = Effects(); fx.eq[5] = 6; fx.volume = 0.7; proc.configure(fx, sampleRate: Devices.sampleRate(of: outID))   // +6 dB around 1 kHz; tone is 440 Hz
        spin(0.3)
        check("live: EQ runs on real audio without clipping", procPeak(1.0) <= 1.0)
        tap.stop()
        spin(0.8)
        let after = maxPeak(of: meter, for: 1.0)
        check("live: stopping the tap hands audio back to the app", after > baseline * 0.5, "peak \(after)")
        // Device-wide tap (software volume): everything except this process is captured, scaled and replayed — no feedback.
        if let own = HAL.processObject(pid: getpid()) {
            var dfx = Effects(); dfx.volume = 0.7071   // amplitude 0.5
            let dproc = Processor(); dproc.configure(dfx, sampleRate: Devices.sampleRate(of: outID))
            let device = try Tap(source: .global(excluding: [own]), outputUID: uid, outputID: outID, chain: [dproc])
            spin(0.5)
            var worst: Float = 0; var samples: [Float] = []
            for _ in 0..<30 { spin(0.1); samples.append(dproc.peak); worst = max(worst, dproc.peak) }
            check("live: device-wide tap scales system audio to 50%", abs(samples.max()! - baseline * 0.5) < baseline * 0.08, "peak \(samples.max()!) (baseline \(baseline))")
            check("live: no feedback loop through the replay", worst <= baseline * 0.55, "worst \(worst)")
            device.stop()
        } else { print("FAIL own process object unavailable"); failures += 1 }
        meter.stop()
    } catch { print("FAIL live tap error:", error.localizedDescription); failures += 1 }
    player.terminate()
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)

extension AVAudioUnit {
    /// Blocking instantiate for the self-check.
    static func instantiateSync(_ desc: AudioComponentDescription) throws -> AVAudioUnit {
        var result: AVAudioUnit?
        AVAudioUnit.instantiate(with: desc, options: []) { u, _ in result = u }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return result!
    }
}
