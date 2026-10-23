import MixerCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            DevicesTab(model: model).tabItem { Label("Devices", systemImage: "hifispeaker") }
            HotkeysTab(model: model).tabItem { Label("Hotkeys", systemImage: "keyboard") }
            ApplicationsTab(model: model).tabItem { Label("Applications", systemImage: "app.dashed") }
            AdvancedTab(model: model).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        let prefs = model.state.preferences
        Form {
            Toggle("Open OpenMixer at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            if let e = model.errors["login"] { Text(e).font(.caption).foregroundStyle(.red) }
            Toggle("Show icon in the Dock", isOn: Binding(get: { prefs.showDockIcon }, set: { v in model.updatePreferences { $0.showDockIcon = v } }))
            Toggle("Show level meters", isOn: Binding(get: { prefs.showMeters }, set: { v in model.updatePreferences { $0.showMeters = v } }))
            Toggle("Keep the window above all others", isOn: Binding(get: { prefs.pinned }, set: { v in model.updatePreferences { $0.pinned = v } }))
            Toggle("Briefly mute when the output device changes", isOn: Binding(get: { prefs.muteOnDeviceChange }, set: { v in model.updatePreferences { $0.muteOnDeviceChange = v } }))
                .help("Avoids a blast of sound when switching to speakers or headphones.")
        }
        .padding(24)
    }
}

private struct DevicesTab: View {
    @ObservedObject var model: MixerModel
    private var devices: [AudioDevice] {
        var seen = Set<String>()
        return model.allDevices().filter { seen.insert($0.uid).inserted }.sorted { $0.name < $1.name }
    }

    var body: some View {
        List(devices) { d in
            let c = model.config(d)
            VStack(alignment: .leading, spacing: 4) {
                Text(d.name).font(.headline)
                Toggle("Hide in OpenMixer (and never use as the default)", isOn: Binding(get: { c.hidden }, set: { v in model.setConfig(d) { $0.hidden = v } }))
                Toggle("Force software volume", isOn: Binding(get: { c.forceSoftwareVolume }, set: { v in model.setConfig(d) { $0.forceSoftwareVolume = v } }))
            }
            .padding(.vertical, 4)
        }
    }
}

private struct HotkeysTab: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        let prefs = model.state.preferences
        Form {
            Section("Global") {
                LabeledContent("Show OpenMixer") {
                    ShortcutRecorder(shortcut: Binding(get: { prefs.showShortcut }, set: { v in model.updatePreferences { $0.showShortcut = v } }))
                }
                Toggle("Use keyboard volume keys for devices macOS can't control", isOn: Binding(get: { prefs.keyboardVolumeControl }, set: { v in model.updatePreferences { $0.keyboardVolumeControl = v } }))
                if prefs.keyboardVolumeControl && !model.accessibilityTrusted {
                    Text("Allow OpenMixer in System Settings › Privacy & Security › Accessibility, then toggle this again.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Output devices") {
                ForEach(model.outputs) { d in
                    DisclosureGroup(d.name) {
                        LabeledContent("Volume up") { recorder(d, \.volumeUp) }
                        LabeledContent("Volume down") { recorder(d, \.volumeDown) }
                        LabeledContent("Mute") { recorder(d, \.mute) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func recorder(_ d: AudioDevice, _ key: WritableKeyPath<DeviceConfig, Shortcut?>) -> some View {
        ShortcutRecorder(shortcut: Binding(get: { model.config(d)[keyPath: key] }, set: { v in model.setConfig(d) { $0[keyPath: key] = v } }))
    }
}

private struct ApplicationsTab: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("By default OpenMixer manages every app that plays audio. Excluded apps are never intercepted and don't appear in the mixer.")
                .font(.callout).foregroundStyle(.secondary).padding([.horizontal, .top])
            List {
                let ids = Set(model.apps.map(\.id)).union(model.state.excludedApps)
                ForEach(ids.sorted(), id: \.self) { id in
                    let app = model.apps.first { $0.id == id }
                    Toggle(isOn: Binding(get: { model.state.excludedApps.contains(id) }, set: { model.setExcluded(id, $0) })) {
                        HStack {
                            if let icon = app?.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                            Text(app?.name ?? id)
                            Spacer()
                            Text("Exclude").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct AdvancedTab: View {
    @ObservedObject var model: MixerModel
    @State private var confirm = false

    var body: some View {
        Form {
            Button("Show Settings Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenMixer")])
            }
            Button("Reset All Settings…", role: .destructive) { confirm = true }
                .confirmationDialog("Reset every app, device and preference?", isPresented: $confirm) {
                    Button("Reset", role: .destructive) { model.state = AppState(); model.commit(); model.updatePreferences { _ in } }
                }
            Text("Audio is only intercepted for apps and devices you've changed. Everything else plays natively.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
