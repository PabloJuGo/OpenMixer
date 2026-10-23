import AVFoundation
import CoreAudioKit
import MixerCore
import SwiftUI

/// Hosts a plugin's own editor window. Edits are written back to the settings as `fullState`,
/// which every running chain then picks up.
@MainActor
final class PluginWindows: NSObject, NSWindowDelegate {
    static let shared = PluginWindows()
    private var windows: [UUID: NSWindow] = [:]
    private var units: [UUID: AVAudioUnit] = [:]
    private var tokens: [UUID: AUParameterObserverToken] = [:]
    private var saveWork: [UUID: DispatchWorkItem] = [:]

    func open(_ setting: PluginSetting, model: MixerModel, target: EffectsTarget) {
        if let w = windows[setting.id] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let desc = AudioComponentDescription(componentType: setting.type, componentSubType: setting.subType, componentManufacturer: setting.manufacturer, componentFlags: 0, componentFlagsMask: 0)
        AVAudioUnit.instantiate(with: desc, options: []) { unit, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let unit else { model.errors["plugin"] = "Couldn't load \(setting.name)."; return }
                    if let state = Plugins.decodeState(setting.state) { unit.auAudioUnit.fullState = state }
                    self.units[setting.id] = unit
                    unit.auAudioUnit.requestViewController { vc in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                let content: NSViewController = vc ?? self.genericController(unit)
                                self.show(content, setting: setting, unit: unit, model: model, target: target)
                            }
                        }
                    }
                }
            }
        }
    }

    private func genericController(_ unit: AVAudioUnit) -> NSViewController {
        let vc = NSViewController()
        let v = AUGenericView(audioUnit: unit.audioUnit)
        v.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        v.showsExpertParameters = false
        vc.view = v
        return vc
    }

    private func show(_ vc: NSViewController, setting: PluginSetting, unit: AVAudioUnit, model: MixerModel, target: EffectsTarget) {
        let window = NSWindow(contentViewController: vc)
        window.title = setting.name
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(setting.id.uuidString)
        windows[setting.id] = window
        let id = setting.id
        let save = { [weak self] in
            guard let self, let u = self.units[id] else { return }
            let data = Plugins.encode(u.auAudioUnit.fullState)
            model.update(target) { fx in fx.plugins.indices.filter { fx.plugins[$0].id == id }.forEach { fx.plugins[$0].state = data } }
        }
        tokens[id] = unit.auAudioUnit.parameterTree?.token(byAddingParameterObserver: { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.saveWork[id]?.cancel()
                let w = DispatchWorkItem { MainActor.assumeIsolated { save() } }
                self.saveWork[id] = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
            }
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        closeHandlers[id] = save
    }

    private var closeHandlers: [UUID: () -> Void] = [:]

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = w.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        closeHandlers[id]?()
        if let t = tokens[id] { units[id]?.auAudioUnit.parameterTree?.removeParameterObserver(t) }
        closeHandlers[id] = nil; tokens[id] = nil; units[id] = nil; windows[id] = nil
    }
}
