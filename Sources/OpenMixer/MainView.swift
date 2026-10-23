import CoreAudio
import MixerCore
import SwiftUI

enum Layout {
    static let width: CGFloat = 380
    static let padding: CGFloat = 16
}

struct RootView: View {
    @ObservedObject var model: MixerModel
    /// nil lets the content report its natural width (used by the overflow test).
    var width: CGFloat? = Layout.width
    var openSettings: () -> Void
    var togglePin: () -> Void

    var body: some View {
        ZStack {
            switch model.page {
            case .main:
                MainView(model: model, openSettings: openSettings, togglePin: togglePin)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .effects(let target):
                EffectsView(model: model, target: target)
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
            }
        }
        .animation(.smooth(duration: 0.3), value: model.page)
        .environmentObject(model.levels)
        .frame(width: width)
        .onExitCommand { NSApp.keyWindow?.close() }
    }
}

struct MainView: View {
    @ObservedObject var model: MixerModel
    var openSettings: () -> Void
    var togglePin: () -> Void
    @State private var newConfigName = ""
    @State private var savingConfig = false

    private var sortedApps: [AudioApp] {
        model.apps.filter { !model.state.excludedApps.contains($0.id) }.sorted {
            let fa = model.state.favoriteApps.contains($0.id), fb = model.state.favoriteApps.contains($1.id)
            return (fa ? 0 : 1, $0.isPlaying ? 0 : 1, $0.name.lowercased()) < (fb ? 0 : 1, $1.isPlaying ? 0 : 1, $1.name.lowercased())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let d = model.outputDevice {
                DeviceBlock(model: model, title: "Output", devices: model.outputs, current: d, direction: .output)
            } else {
                Text("No output device").foregroundStyle(.secondary)
            }
            if let e = model.errors["device"] { Text(e).font(.caption2).foregroundStyle(.red) }
            if let d = model.inputs.first(where: { $0.id == model.defaultInput }) {
                DeviceBlock(model: model, title: "Input", devices: model.inputs, current: d, direction: .input)
            }
            systemSounds
            applications
            bluetooth
        }
        .padding(Layout.padding)
        .onAppear { model.refreshBluetooth() }
        .alert("Save Quick Config", isPresented: $savingConfig) {
            TextField("Name", text: $newConfigName)
            Button("Save") { model.saveQuickConfig(named: newConfigName); newConfigName = "" }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Stores every app and device setting plus the current devices.") }
    }

    private var header: some View {
        HStack {
            Text("OpenMixer").font(.system(size: 15, weight: .semibold))
            Spacer()
            IconButton(symbol: model.state.preferences.pinned ? "pin.fill" : "pin", active: model.state.preferences.pinned, help: "Keep this window above all others", action: togglePin)
            Menu {
                Menu("Quick Configs") {
                    ForEach(model.state.quickConfigs) { c in Button(c.name) { model.applyQuickConfig(c) } }
                    if !model.state.quickConfigs.isEmpty { Divider() }
                    Button("Save Current…") { savingConfig = true }
                    ForEach(model.state.quickConfigs) { c in Button("Delete “\(c.name)”") { model.deleteQuickConfig(c.name) } }
                }
                Button("Settings…", action: openSettings)
                Divider()
                Button("Quit OpenMixer") { NSApp.terminate(nil) }
            } label: { Image(systemName: "gearshape").font(.system(size: 13)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private var systemSounds: some View {
        HStack {
            SectionHeader(title: "System Sounds")
            Spacer()
            Menu {
                ForEach(model.outputs) { d in
                    Button { model.selectSystemOutput(d) } label: {
                        Label(d.name, systemImage: d.id == model.systemOutput ? "checkmark" : "")
                    }
                }
            } label: {
                Text(model.outputs.first { $0.id == model.systemOutput }?.name ?? "Follow Output").lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Applications")
            if sortedApps.isEmpty {
                Text("No apps are using audio.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 12) { ForEach(sortedApps) { AppRow(app: $0, model: model).transition(.opacity.combined(with: .scale(scale: 0.96))) } }
                        .padding(.vertical, 12)
                        .padding(.leading, 12)
                        .padding(.trailing, 22)   // keeps the overlay scroller off the row buttons
                        .animation(.smooth(duration: 0.3), value: sortedApps.map(\.id))
                }
                .frame(maxHeight: 270)
                .glassCard()
            }
        }
    }

    @ViewBuilder private var bluetooth: some View {
        let missing = model.bluetooth.filter { b in !model.outputs.contains { $0.name == b.name } || !b.connected }
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Bluetooth")
                ForEach(missing) { b in
                    HStack {
                        Image(systemName: "headphones").foregroundStyle(.secondary)
                        Text(b.name).lineLimit(1)
                        Spacer()
                        Button(b.connected ? "Disconnect" : "Connect") { model.setBluetooth(b, connected: !b.connected) }
                            .controlSize(.small)
                    }
                }
                if let e = model.errors["bluetooth"] { Text(e).font(.caption2).foregroundStyle(.red) }
            }
        }
    }
}

struct DeviceBlock: View {
    @ObservedObject var model: MixerModel
    let title: String
    let devices: [AudioDevice]
    let current: AudioDevice
    let direction: Direction

    var body: some View {
        let muted = model.isMuted(current, direction)
        let volume = Binding(get: { Double(model.volume(of: current, direction)) }, set: { model.setVolume(Float($0), of: current, direction) })
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: title)
                Spacer()
                if direction == .output {
                    RoutePicker().frame(width: 22, height: 22).help("AirPlay")
                    IconButton(symbol: "slider.horizontal.3", active: !model.deviceFX(current).isNeutral, help: "Device effects") {
                        model.page = .effects(.device(current.uid))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Menu {
                    ForEach(devices) { d in
                        Button { model.select(d, direction) } label: { Label(d.name, systemImage: d.id == current.id ? "checkmark" : "") }
                    }
                } label: {
                    HStack {
                        Image(systemName: icon).frame(width: 18)
                        Text(current.name).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                HStack(spacing: 8) {
                    IconButton(symbol: muted ? "speaker.slash.fill" : (direction == .output ? "speaker.wave.2.fill" : "mic.fill"), active: muted) {
                        model.toggleMute(current, direction)
                    }
                    LevelSlider(value: volume, meterID: direction == .output ? "master" : nil)
                    Text("\(Int(volume.wrappedValue * 100))%").font(.system(size: 11)).monospacedDigit()
                        .contentTransition(.numericText()).animation(.smooth(duration: 0.2), value: Int(volume.wrappedValue * 100))
                        .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
                if direction == .output, model.usesSoftwareVolume(current) {
                    Text("Using software volume").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .glassCard()
        }
    }

    private var icon: String {
        if Devices.isBluetooth(current.id) { return "headphones" }
        if Devices.isAirPlay(current.id) { return "airplayaudio" }
        return direction == .output ? "hifispeaker.fill" : "mic.fill"
    }
}

struct AppRow: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel

    var body: some View {
        let target = EffectsTarget.app(app.id)
        let fx = model.fx(target)
        let volume = Binding(get: { Double(fx.volume) }, set: { v in model.update(target) { $0.volume = Float(v); if v > 0 { $0.muted = false } } })
        HStack(spacing: 10) {
            Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 30, height: 30)
                .animation(.smooth, value: app.isPlaying)
                .opacity(app.isPlaying ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app.name).lineLimit(1).font(.system(size: 12.5))
                    if model.state.favoriteApps.contains(app.id) { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
                    Spacer()
                    Text(fx.muted ? "Muted" : "\(Int(fx.volume * 100))%").font(.system(size: 10)).monospacedDigit()
                        .contentTransition(.numericText()).animation(.smooth(duration: 0.2), value: fx.volume)
                        .foregroundStyle(.secondary)
                }
                LevelSlider(value: volume, range: 0...2, meterID: app.id, markAt: 1)
                if let e = model.errors[app.id] { Text(e).font(.caption2).foregroundStyle(.red) }
            }
            VStack(spacing: 0) {
                IconButton(symbol: fx.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", active: fx.muted) { model.update(target) { $0.muted.toggle() } }
                IconButton(symbol: "slider.horizontal.3", active: fx.hasProcessing || fx.outputUID != nil) {
                    model.page = .effects(target)
                }
            }
        }
        .contextMenu {
            Button(model.state.favoriteApps.contains(app.id) ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(app.id) }
            Button("Reset") { model.resetEffects(target) }
            Button("Exclude from OpenMixer") { model.setExcluded(app.id, true) }
        }
    }
}
