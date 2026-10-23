import AppKit
import Combine
import CoreAudio
import Foundation
import MixerCore
import ServiceManagement

enum EffectsTarget: Hashable {
    case app(String)
    case device(String)   // device UID
}

enum Page: Equatable {
    case main
    case effects(EffectsTarget)
}

/// Level meter values live in their own object so 30 Hz updates only redraw the meters.
@MainActor
final class LevelStore: ObservableObject {
    @Published var levels: [String: Float] = [:]
}

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var defaultOutput: AudioObjectID?
    @Published private(set) var defaultInput: AudioObjectID?
    @Published private(set) var systemOutput: AudioObjectID?
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var bluetooth: [BluetoothAudioDevice] = []
    @Published var errors: [String: String] = [:]
    @Published private(set) var launchAtLogin = false
    @Published private(set) var accessibilityTrusted = MediaKeys.trusted
    @Published var page: Page = .main
    @Published var state: AppState
    @Published private(set) var masterVolume: Float = 1
    @Published private(set) var masterMuted = false
    let levels = LevelStore()
    let allDevices: () -> [AudioDevice] = { Devices.list(.output) + Devices.list(.input) }

    private let stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenMixer/state.json")
    private var appTaps: [String: Tap] = [:]
    private var deviceTap: Tap?
    private var meterTaps: [String: Tap] = [:]
    private var pending = Set<String>()       // taps being created off the main thread
    private var failedAt: [String: Date] = [:]  // creation back-off
    private var epoch = 0                       // bumped when taps are torn down, so late completions are discarded
    private var ownProcess: AudioObjectID?
    private var timer: Timer?
    private var meterTimer: Timer?
    private var saveWork: DispatchWorkItem?
    private var refreshWork: DispatchWorkItem?
    private var cancelObservers: [() -> Void] = []
    private var deviceObserver: (() -> Void)?
    private var lastVisibleOutput: AudioObjectID?
    private var registeredShortcuts: [String] = []
    private let hotKeys = HotKeyCenter()
    private lazy var mediaKeys = MediaKeys { [weak self] key in MainActor.assumeIsolated { self?.handleMediaKey(key) ?? false } }
    var showPopover: () -> Void = {}
    var metering = false { didSet { if metering != oldValue { setMetering(metering) } } }

    init() {
        state = AppState.load(from: stateURL)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let system = AudioObjectID(kAudioObjectSystemObject)
        cancelObservers.append(Devices.observe(system, [
            HAL.address(kAudioHardwarePropertyDevices), HAL.address(kAudioHardwarePropertyDefaultOutputDevice),
            HAL.address(kAudioHardwarePropertyDefaultInputDevice), HAL.address(kAudioHardwarePropertyDefaultSystemOutputDevice),
            HAL.address(kAudioHardwarePropertyProcessObjectList),
        ]) { [weak self] in MainActor.assumeIsolated { self?.refreshSoon() } })
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAllTaps(); self?.refreshSoon(after: 1.5) }
        }
        applyDockPolicy()
        refresh()
        syncKeyboardControl()
    }

    // MARK: Refresh

    func refreshSoon(after delay: TimeInterval = 0.15) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func refresh() {
        let previousOutput = defaultOutput
        let hidden = { (d: AudioDevice) in self.state.deviceConfig[d.uid]?.hidden ?? false }
        outputs = Devices.list(.output).filter { !hidden($0) }
        inputs = Devices.list(.input).filter { !hidden($0) }
        var out = Devices.defaultDevice(.output)
        if let o = out, Devices.list(.output).first(where: { $0.id == o }).map(hidden) == true, let back = lastVisibleOutput, back != o {
            Devices.setDefault(back, .output); out = back   // hidden devices can't be chosen as default
        }
        if let o = out, outputs.contains(where: { $0.id == o }) { lastVisibleOutput = o }
        if out != defaultOutput { defaultOutput = out; observeDefaultDevice() }
        defaultInput = Devices.defaultDevice(.input)
        systemOutput = Devices.systemOutput
        let found = Apps.running()
        if found != apps { apps = found }
        if let p = previousOutput, let o = out, p != o { muteBriefly(o) }
        refreshMaster()
        reconcile()
        registerHotKeys()
    }

    private func observeDefaultDevice() {
        deviceObserver?(); deviceObserver = nil
        guard let id = defaultOutput else { return }
        var addresses = [HAL.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain),
                         HAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)]
        for ch in 1...2 as ClosedRange<UInt32> {
            addresses.append(HAL.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, ch))
            addresses.append(HAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, ch))
        }
        deviceObserver = Devices.observe(id, addresses) { [weak self] in MainActor.assumeIsolated { self?.refreshMaster() } }
    }

    private func refreshMaster() {
        guard let d = outputs.first(where: { $0.id == defaultOutput }) else { return }
        let v = volume(of: d, .output), m = isMuted(d, .output)
        if v != masterVolume { masterVolume = v }
        if m != masterMuted { masterMuted = m }
    }

    private func muteBriefly(_ id: AudioObjectID) {
        guard state.preferences.muteOnDeviceChange, Devices.isMuted(id, .output) == false else { return }
        Devices.setMuted(id, .output, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Devices.setMuted(id, .output, false) }
    }

    // MARK: Devices

    func device(uid: String) -> AudioDevice? { (outputs + inputs).first { $0.uid == uid } ?? allDevices().first { $0.uid == uid } }
    func config(_ d: AudioDevice) -> DeviceConfig { state.deviceConfig[d.uid] ?? DeviceConfig() }
    func deviceFX(_ d: AudioDevice) -> Effects { state.deviceFX[d.uid] ?? Effects() }

    func usesSoftwareVolume(_ d: AudioDevice) -> Bool { config(d).forceSoftwareVolume || !Devices.hasHardwareVolume(d.id) }

    private func deviceNeedsTap(_ d: AudioDevice) -> Bool {
        let fx = deviceFX(d)
        return fx.hasProcessing || (usesSoftwareVolume(d) && (fx.volume != 1 || fx.muted))
    }

    /// Slider position 0...1 where 1 is the device's configured maximum.
    func volume(of d: AudioDevice, _ direction: Direction) -> Float {
        let raw = direction == .output && usesSoftwareVolume(d) ? deviceFX(d).volume : Devices.volume(d.id, direction) ?? 1
        return min(1, raw / max(0.05, config(d).maxVolume))
    }

    func setVolume(_ v: Float, of d: AudioDevice, _ direction: Direction) {
        let raw = max(0, min(1, v)) * config(d).maxVolume
        if direction == .output && usesSoftwareVolume(d) {
            update(.device(d.uid)) { $0.volume = raw; if raw > 0 { $0.muted = false } }
        } else {
            Devices.setVolume(d.id, direction, raw)
            if raw > 0, Devices.isMuted(d.id, direction) == true { Devices.setMuted(d.id, direction, false) }
        }
        if d.id == defaultOutput { refreshMaster() }
    }

    func isMuted(_ d: AudioDevice, _ direction: Direction) -> Bool {
        direction == .output && usesSoftwareVolume(d) ? deviceFX(d).muted : Devices.isMuted(d.id, direction) ?? false
    }

    func toggleMute(_ d: AudioDevice, _ direction: Direction) {
        if direction == .output && usesSoftwareVolume(d) {
            update(.device(d.uid)) { $0.muted.toggle() }
        } else {
            Devices.setMuted(d.id, direction, !isMuted(d, direction))
        }
        if d.id == defaultOutput { refreshMaster() }
    }

    func select(_ d: AudioDevice, _ direction: Direction) {
        Devices.setDefault(d.id, direction); refresh()
    }

    func selectSystemOutput(_ d: AudioDevice) { Devices.setSystemOutput(d.id); refresh() }

    func sampleRates(_ d: AudioDevice) -> [Double] { Devices.availableSampleRates(d.id) }
    func sampleRate(_ d: AudioDevice) -> Double { Devices.sampleRate(of: d.id) }
    func setSampleRate(_ d: AudioDevice, _ rate: Double) { Devices.setSampleRate(d.id, rate); refreshSoon(after: 0.4) }

    func setConfig(_ d: AudioDevice, _ change: (inout DeviceConfig) -> Void) {
        var c = config(d); change(&c)
        state.deviceConfig[d.uid] = c == DeviceConfig() ? nil : c
        commit(); refresh()
    }

    // MARK: Master controls (hotkeys, media keys, status item scroll)

    var outputDevice: AudioDevice? { outputs.first { $0.id == defaultOutput } }

    func adjustOutputVolume(by delta: Float) {
        guard let d = outputDevice else { return }
        setVolume(volume(of: d, .output) + delta, of: d, .output)
    }

    func toggleOutputMute() { outputDevice.map { toggleMute($0, .output) } }

    private func handleMediaKey(_ key: MediaKeys.Key) -> Bool {
        guard state.preferences.keyboardVolumeControl, let d = outputDevice,
              usesSoftwareVolume(d) || !Devices.hasHardwareMute(d.id) else { return false }
        switch key {
        case .up: adjustOutputVolume(by: state.preferences.volumeStep)
        case .down: adjustOutputVolume(by: -state.preferences.volumeStep)
        case .mute: toggleOutputMute()
        }
        return true
    }

    func syncKeyboardControl() {
        accessibilityTrusted = MediaKeys.trusted
        if state.preferences.keyboardVolumeControl {
            if !MediaKeys.trusted { MediaKeys.requestTrust() }
            mediaKeys.start()
        } else { mediaKeys.stop() }
    }

    private func registerHotKeys() {
        let wanted = state.deviceConfig.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value.volumeUp?.label ?? "")\($0.value.volumeDown?.label ?? "")\($0.value.mute?.label ?? "")\($0.value.volumeUp?.modifiers ?? 0)\($0.value.volumeDown?.modifiers ?? 0)\($0.value.mute?.modifiers ?? 0)" }
            + ["show\(state.preferences.showShortcut?.label ?? "")\(state.preferences.showShortcut?.modifiers ?? 0)"]
        guard wanted != registeredShortcuts else { return }
        registeredShortcuts = wanted
        hotKeys.removeAll()
        let step = { [weak self] (uid: String, delta: Float) in
            guard let self, let d = self.device(uid: uid) else { return }
            self.setVolume(self.volume(of: d, .output) + delta, of: d, .output)
        }
        for (uid, c) in state.deviceConfig {
            let s = state.preferences.volumeStep
            if let k = c.volumeUp { hotKeys.register(k) { MainActor.assumeIsolated { step(uid, s) } } }
            if let k = c.volumeDown { hotKeys.register(k) { MainActor.assumeIsolated { step(uid, -s) } } }
            if let k = c.mute { hotKeys.register(k) { MainActor.assumeIsolated { if let d = self.device(uid: uid) { self.toggleMute(d, .output) } } } }
        }
        if let k = state.preferences.showShortcut { hotKeys.register(k) { MainActor.assumeIsolated { self.showPopover() } } }
    }

    // MARK: Bluetooth

    /// IOBluetooth can block (e.g. while the permission prompt is up), so it never runs on the main thread.
    func refreshBluetooth() {
        Task.detached {
            let list = Bluetooth.audioDevices()
            await MainActor.run { [weak self] in if self?.bluetooth != list { self?.bluetooth = list } }
        }
    }

    func setBluetooth(_ device: BluetoothAudioDevice, connected: Bool) {
        Bluetooth.setConnected(device.address, connected) { [weak self] ok in
            if !ok { self?.errors["bluetooth"] = "Failed to \(connected ? "connect to" : "disconnect from") \(device.name)." } else { self?.errors["bluetooth"] = nil }
            self?.refreshBluetooth(); self?.refreshSoon(after: 1)
        }
    }

    // MARK: Effects state

    func fx(_ t: EffectsTarget) -> Effects {
        switch t {
        case .app(let id): return state.appFX[id] ?? Effects()
        case .device(let uid): return state.deviceFX[uid] ?? Effects()
        }
    }

    func update(_ t: EffectsTarget, _ change: (inout Effects) -> Void) {
        var e = fx(t); change(&e)
        switch t {
        case .app(let id): state.appFX[id] = e.isNeutral ? nil : e
        case .device(let uid): state.deviceFX[uid] = e.isNeutral ? nil : e
        }
        commit(); reconcile()
    }

    func resetEffects(_ t: EffectsTarget) { update(t) { $0 = Effects() } }

    func commit() {
        saveWork?.cancel()
        let snapshot = state, url = stateURL
        let work = DispatchWorkItem { snapshot.save(to: url) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func toggleFavorite(_ id: String) {
        if let i = state.favoriteApps.firstIndex(of: id) { state.favoriteApps.remove(at: i) } else { state.favoriteApps.append(id) }
        commit()
    }

    func setExcluded(_ id: String, _ excluded: Bool) {
        state.excludedApps.removeAll { $0 == id }
        if excluded { state.excludedApps.append(id) }
        commit(); reconcile()
    }

    func updatePreferences(_ change: (inout Preferences) -> Void) {
        change(&state.preferences); commit(); applyDockPolicy(); syncKeyboardControl(); refreshSoon()
    }

    func applyDockPolicy() { NSApplication.shared.setActivationPolicy(state.preferences.showDockIcon ? .regular : .accessory) }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            errors["login"] = nil
        } catch { errors["login"] = "Couldn't change the login item: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Presets and quick configs

    var presets: [EQPreset] { EQPreset.builtIn + state.userPresets }

    func saveUserPreset(named name: String, gains: [Float]) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !EQPreset.builtIn.contains(where: { $0.name == n }) else { return }
        state.userPresets.removeAll { $0.name == n }
        state.userPresets.append(EQPreset(name: n, gains: gains)); commit()
    }

    func deleteUserPreset(_ name: String) { state.userPresets.removeAll { $0.name == name }; commit() }

    func saveQuickConfig(named name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        state.quickConfigs.removeAll { $0.name == n }
        state.quickConfigs.append(QuickConfig(name: n, appFX: state.appFX, deviceFX: state.deviceFX,
                                              outputUID: outputDevice?.uid, inputUID: inputs.first { $0.id == defaultInput }?.uid))
        commit()
    }

    func applyQuickConfig(_ c: QuickConfig) {
        state.appFX = c.appFX; state.deviceFX = c.deviceFX
        if let u = c.outputUID, let d = outputs.first(where: { $0.uid == u }) { Devices.setDefault(d.id, .output) }
        if let u = c.inputUID, let d = inputs.first(where: { $0.uid == u }) { Devices.setDefault(d.id, .input) }
        commit(); refresh()
    }

    func deleteQuickConfig(_ name: String) { state.quickConfigs.removeAll { $0.name == name }; commit() }

    func importProfile(_ url: URL, into t: EffectsTarget) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { errors["profile"] = "Couldn't read \(url.lastPathComponent)."; return }
        let (preamp, filters) = ParametricProfile.parse(text)
        guard !filters.isEmpty else { errors["profile"] = "\(url.lastPathComponent) has no supported filters (expected AutoEQ ParametricEQ.txt)."; return }
        errors["profile"] = nil
        update(t) { $0.parametric = filters; $0.preamp = preamp; $0.parametricName = url.deletingPathExtension().lastPathComponent }
    }

    // MARK: Taps

    private func ownProcessObject(on device: AudioDevice) -> AudioObjectID? {
        if let o = ownProcess { return o }
        let pid = ProcessInfo.processInfo.processIdentifier
        if let o = HAL.processObject(pid: pid) { ownProcess = o; return o }
        // Core Audio only knows us as a process once we run IO: start a silent proc briefly.
        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, nil, { _, _, _, out, _ in
            for b in UnsafeMutableAudioBufferListPointer(out) { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        }) == noErr, let proc else { return nil }
        AudioDeviceStart(device.id, proc)
        defer { AudioDeviceStop(device.id, proc); AudioDeviceDestroyIOProcID(device.id, proc) }
        for _ in 0..<20 {
            usleep(25_000)
            if let o = HAL.processObject(pid: pid) { ownProcess = o; return o }
        }
        return nil
    }

    /// Creating a tap can block inside Core Audio (for instance while the capture-permission prompt is open),
    /// so it never happens on the main thread. Failures back off for 15 s.
    private func createTap(_ key: String, _ make: @escaping () throws -> Tap, store: @escaping (Tap) -> Void) {
        if let f = failedAt[key], Date().timeIntervalSince(f) < 15 { return }
        guard pending.insert(key).inserted else { return }
        let started = epoch
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try make() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending.remove(key)
                    switch result {
                    case .success(let tap):
                        if started == self.epoch { store(tap); self.errors[key] = nil; self.failedAt[key] = nil } else { tap.stop() }
                    case .failure(let error):
                        self.errors[key] = error.localizedDescription; self.failedAt[key] = Date()
                    }
                    self.reconcile()
                }
            }
        }
    }

    private func stopAllTaps() {
        epoch += 1; pending = []
        appTaps.values.forEach { $0.stop() }; appTaps = [:]
        deviceTap?.stop(); deviceTap = nil
        meterTaps.values.forEach { $0.stop() }; meterTaps = [:]
    }

    func stopForQuit() { stopAllTaps() }

    /// Brings the set of running taps in line with the settings. Cheap and idempotent: called on every change.
    private func reconcile() {
        let defaultDevice = outputDevice
        var wanted: [String: (app: AudioApp, fx: Effects, device: AudioDevice)] = [:]
        var handled = Set<AudioObjectID>()
        // Excluded apps are never intercepted, not even by the device-wide tap.
        for app in apps where state.excludedApps.contains(app.id) { handled.formUnion(app.processes) }
        for app in apps where !state.excludedApps.contains(app.id) {
            let e = fx(.app(app.id))
            guard !e.isNeutral, let device = (e.outputUID.flatMap { uid in outputs.first { $0.uid == uid } } ?? defaultDevice) else { continue }
            wanted[app.id] = (app, e, device)
            handled.formUnion(app.processes)
        }
        for (id, tap) in appTaps {
            guard let w = wanted[id], tap.source == .processes(w.app.processes), tap.outputUID == w.device.uid,
                  (tap.chain.count == 2) == deviceNeedsTap(w.device) else { tap.stop(); appTaps[id] = nil; continue }
        }
        for (id, w) in wanted {
            if appTaps[id] == nil {
                let chain = [Processor()] + (deviceNeedsTap(w.device) ? [Processor()] : [])
                let source = TapSource.processes(w.app.processes), uid = w.device.uid, outID = w.device.id
                createTap(id, { try Tap(source: source, outputUID: uid, outputID: outID, chain: chain) }) { self.appTaps[id] = $0 }
                continue
            }
            guard let tap = appTaps[id] else { continue }
            tap.chain[0].configure(w.fx, sampleRate: tap.sampleRate)
            if tap.chain.count == 2 { tap.chain[1].configure(processorFX(w.device), sampleRate: tap.sampleRate) }
        }

        if let d = defaultDevice, deviceNeedsTap(d), let own = ownProcessObject(on: d) {
            let source = TapSource.global(excluding: handled.union([own]))
            if let t = deviceTap, t.source != source || t.outputUID != d.uid { t.stop(); deviceTap = nil }
            if deviceTap == nil {
                let uid = d.uid, outID = d.id
                createTap("device", { try Tap(source: source, outputUID: uid, outputID: outID, chain: [Processor()]) }) { self.deviceTap = $0 }
            }
            deviceTap?.chain[0].configure(processorFX(d), sampleRate: deviceTap?.sampleRate ?? 48_000)
        } else {
            deviceTap?.stop(); deviceTap = nil
        }
        if metering { reconcileMeters() }
    }

    /// Hardware-volume devices keep volume/mute in hardware; the processor only handles the rest.
    private func processorFX(_ d: AudioDevice) -> Effects {
        var e = deviceFX(d)
        if !usesSoftwareVolume(d) { e.volume = 1; e.muted = false }
        return e
    }

    // MARK: Meters

    private func setMetering(_ on: Bool) {
        meterTimer?.invalidate(); meterTimer = nil
        if on, state.preferences.showMeters {
            reconcileMeters()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickMeters() }
            }
        } else {
            meterTaps.values.forEach { $0.stop() }; meterTaps = [:]
            levels.levels = [:]
        }
    }

    private func reconcileMeters() {
        guard state.preferences.showMeters, let d = outputDevice else { return }
        let present = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        for (id, tap) in meterTaps {
            let keep = id == "master" || (present[id].map { app in app.isPlaying && appTaps[id] == nil && tap.source == .processes(app.processes) } ?? false)
            if !keep { tap.stop(); meterTaps[id] = nil }
        }
        func start(_ id: String, _ source: TapSource) {
            guard meterTaps[id] == nil else { return }
            let uid = d.uid, outID = d.id
            createTap("meter:" + id, { try Tap(source: source, outputUID: uid, outputID: outID, chain: [], meterOnly: true) }) { if self.metering { self.meterTaps[id] = $0 } else { $0.stop() } }
        }
        start("master", .global(excluding: []))
        for app in apps where app.isPlaying && appTaps[app.id] == nil { start(app.id, .processes(app.processes)) }
    }

    private func tickMeters() {
        var next: [String: Float] = [:]
        func smooth(_ id: String, _ raw: Float) {
            let old = levels.levels[id] ?? 0
            next[id] = raw > old ? raw : max(raw, old - 0.05)   // fast attack, slow fall
        }
        for (id, tap) in meterTaps { smooth(id, tap.inputPeak) }
        for (id, tap) in appTaps { smooth(id, tap.chain.first?.peak ?? 0) }
        if next != levels.levels { levels.levels = next }
    }
}
