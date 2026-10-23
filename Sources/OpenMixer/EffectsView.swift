import CoreAudio
import MixerCore
import SwiftUI
import UniformTypeIdentifiers

struct EffectsView: View {
    @ObservedObject var model: MixerModel
    let target: EffectsTarget
    @State private var tab = Tab.eq
    @State private var presetName = ""
    @State private var savingPreset = false

    enum Tab: String, CaseIterable { case eq = "EQ", headphones = "Headphones", plugins = "Plugins", output = "Output" }

    private var fx: Effects { model.fx(target) }
    private var title: String {
        switch target {
        case .app(let id): return model.apps.first { $0.id == id }?.name ?? id
        case .device(let uid): return model.device(uid: uid)?.name ?? "Device"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.page = .main } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                Spacer()
                Toggle("Bypass", isOn: Binding(get: { fx.bypassed }, set: { v in model.update(target) { $0.bypassed = v } }))
                    .toggleStyle(.switch).controlSize(.mini).fixedSize().help("Bypass equalizer and plugins")
            }
            SegmentedTabs(items: Tab.allCases.map { ($0, $0.rawValue) }, selection: $tab)
            ZStack(alignment: .top) {
                switch tab {
                case .eq: equalizer.transition(.opacity)
                case .headphones: headphones.transition(.opacity)
                case .plugins: PluginsTab(model: model, target: target).transition(.opacity)
                case .output: output.transition(.opacity)
                }
            }
            .frame(minHeight: 170, alignment: .top)
            .animation(.smooth(duration: 0.25), value: tab)
            HStack {
                Spacer()
                Button("Reset All Effects") { model.resetEffects(target) }.controlSize(.small)
            }
        }
        .padding(Layout.padding)
        .alert("Save Preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { model.saveUserPreset(named: presetName, gains: fx.eq); presetName = "" }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var equalizer: some View {
        VStack(spacing: 10) {
            HStack {
                Menu("Preset") {
                    ForEach(model.presets) { p in Button(p.name) { model.update(target) { $0.eq = p.gains } } }
                    Divider()
                    Button("Save Current…") { savingPreset = true }
                    ForEach(model.state.userPresets) { p in Button("Delete “\(p.name)”") { model.deleteUserPreset(p.name) } }
                }.fixedSize()
                Spacer()
                Text("±12 dB").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { band in
                    VStack(spacing: 4) {
                        Text(String(format: "%+.0f", fx.eq[band])).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                        VerticalSlider(value: Binding(get: { Double(fx.eq[band]) }, set: { g in model.update(target) { $0.eq[band] = Float(g) } }))
                            .frame(height: 100)
                        Text(Self.label(GraphicEQ.frequencies[band])).font(.system(size: 9)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private static func label(_ hz: Float) -> String { hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))" }

    private var headphones: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Load a parametric correction profile for your headphones, such as an AutoEQ “ParametricEQ.txt”.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Import Profile…") { importProfile() }
                if !fx.parametric.isEmpty { Button("Remove") { model.update(target) { $0.parametric = []; $0.parametricName = nil; $0.preamp = 0 } } }
            }
            if !fx.parametric.isEmpty {
                Text("\(fx.parametricName ?? "Profile") — \(fx.parametric.count) filters, preamp \(String(format: "%+.1f", fx.preamp)) dB").font(.callout)
            }
            if let e = model.errors["profile"] { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a ParametricEQ.txt profile"
        if panel.runModal() == .OK, let url = panel.url { model.importProfile(url, into: target) }
    }

    @ViewBuilder private var output: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Balance").frame(width: 70, alignment: .leading)
                Text("L").font(.caption).foregroundStyle(.secondary)
                LevelSlider(value: Binding(get: { Double(fx.balance) }, set: { v in model.update(target) { $0.balance = abs(v) < 0.04 ? 0 : Float(v) } }), range: -1...1, markAt: 0)
                Text("R").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Limiter (prevents clipping)", isOn: Binding(get: { fx.limiter }, set: { v in model.update(target) { $0.limiter = v } }))
            switch target {
            case .app:
                Picker("Output", selection: Binding(get: { fx.outputUID ?? "" }, set: { u in model.update(target) { $0.outputUID = u.isEmpty ? nil : u } })) {
                    Text("System Default").tag("")
                    ForEach(model.outputs) { Text($0.name).tag($0.uid) }
                }
            case .device(let uid):
                if let d = model.device(uid: uid) { DeviceOptions(model: model, device: d) }
            }
        }
    }
}

struct DeviceOptions: View {
    @ObservedObject var model: MixerModel
    let device: AudioDevice

    var body: some View {
        let c = model.config(device)
        VStack(alignment: .leading, spacing: 10) {
            let rates = model.sampleRates(device)
            if !rates.isEmpty {
                Picker("Sample Rate", selection: Binding(get: { model.sampleRate(device) }, set: { model.setSampleRate(device, $0) })) {
                    ForEach(rates, id: \.self) { Text("\(String(format: "%g", $0 / 1000)) kHz").tag($0) }
                }
            }
            Toggle("Force software volume", isOn: Binding(get: { c.forceSoftwareVolume }, set: { v in model.setConfig(device) { $0.forceSoftwareVolume = v } }))
                .help("Adjust volume in OpenMixer instead of hardware. Useful for devices with missing or unreliable volume.")
            HStack {
                Text("Maximum volume")
                LevelSlider(value: Binding(get: { Double(c.maxVolume) }, set: { v in model.setConfig(device) { $0.maxVolume = Float(max(0.1, v)) } }), range: 0.1...1)
                Text("\(Int(c.maxVolume * 100))%").monospacedDigit().font(.caption).frame(width: 36)
            }
        }
    }
}

struct PluginsTab: View {
    @ObservedObject var model: MixerModel
    let target: EffectsTarget
    @State private var installed: [InstalledPlugin] = []

    var body: some View {
        let plugins = model.fx(target).plugins
        VStack(alignment: .leading, spacing: 8) {
            if plugins.isEmpty { Text("No plugins. Add any installed Audio Unit effect.").font(.callout).foregroundStyle(.secondary) }
            ForEach(plugins) { p in
                HStack {
                    Toggle("", isOn: Binding(get: { !p.bypassed }, set: { on in model.update(target) { fx in fx.plugins.indices.filter { fx.plugins[$0].id == p.id }.forEach { fx.plugins[$0].bypassed = !on } } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Button("Open") { PluginWindows.shared.open(p, model: model, target: target) }.controlSize(.small)
                    IconButton(symbol: "trash") { model.update(target) { $0.plugins.removeAll { $0.id == p.id } } }
                }
            }
            Menu("Add Plugin") {
                ForEach(Dictionary(grouping: installed, by: \.vendor).sorted { $0.key < $1.key }, id: \.key) { vendor, list in
                    Menu(vendor) { ForEach(list) { i in Button(i.name) { model.update(target) { $0.plugins.append(i.setting()) } } } }
                }
            }.fixedSize()
        }
        .onAppear { installed = Plugins.installed() }
    }
}
