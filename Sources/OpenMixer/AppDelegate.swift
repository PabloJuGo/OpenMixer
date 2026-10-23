import AppKit
import Combine
import MixerCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = MixerModel()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()
    private var scrollMonitor: Any?
    private var outsideClickMonitor: Any?
    private var host: NSHostingController<RootView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One mixer at a time: a second instance would fight over the same taps.
        if let id = Bundle.main.bundleIdentifier, !CommandLine.arguments.contains("--snapshot"),
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != NSRunningApplication.current }) {
            other.activate(); NSApp.terminate(nil); return
        }
        // macOS orders status items by a saved "preferred position" (distance from the right edge). Any value >= 1 snaps us to the
        // right-most slot allowed for third-party items, i.e. right next to the system items / Control Center. Re-applied on every launch.
        UserDefaults.standard.set(1, forKey: "NSStatusItem Preferred Position OpenMixer")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "OpenMixer"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("OpenMixer")

        let root = RootView(model: model, openSettings: { [weak self] in self?.openSettings() }, togglePin: { [weak self] in self?.togglePin() })
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []   // sized explicitly in `resizePopover`: the automatic path lagged behind page changes
        self.host = host
        popover.contentViewController = host
        popover.animates = true
        // appearance follows the system (light, dark and Liquid Glass)
        popover.delegate = self
        applyPin()

        Publishers.CombineLatest(model.$masterVolume, model.$masterMuted).sink { [weak self] v, m in
            self?.item.button?.image = StatusIcon.image(volume: v, muted: m)
        }.store(in: &bag)

        model.showPopover = { [weak self] in self?.show() }
        // Any model change (page switch, app list) can change the content height; resize right after SwiftUI lays it out.
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePopover() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.resizePopover() }
        }.store(in: &bag)
        // Losing focus (clicking another app or the desktop) also dismisses the popover unless it is pinned.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeUnlessPinned() }
        }
        if CommandLine.arguments.contains("--popover-test") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.popoverTest() } }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.snapshot(to: CommandLine.arguments[i + 1]) }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, e.window == self.item.button?.window else { return e }
            let delta = Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.004 : 0.02)
            self.model.adjustOutputVolume(by: delta)
            return nil
        }
    }

    /// Debug aid: `OpenMixer --snapshot dir` renders the popover pages to PNGs and exits (no screen-recording permission needed).
    private func snapshot(to dir: String) {
        NSApp.appearance = NSAppearance(named: .darkAqua)   // offscreen drawing resolves semantic colours with the app appearance
        let root = RootView(model: model, openSettings: {}, togglePin: {})
        let pages: [(String, Page)] = [("main", .main)] + model.apps.prefix(1).map { ("effects", Page.effects(.app($0.id))) } + (model.outputDevice.map { [("device", Page.effects(.device($0.uid)))] } ?? [])
        let targets: [(String, Page?)] = [("settings", nil)] + pages.map { ($0.0, $0.1) }
        for (name, page) in targets {
            let host = page == nil ? NSHostingView(rootView: AnyView(SettingsView(model: model).environment(\.colorScheme, .dark))) : NSHostingView(rootView: AnyView(root.environment(\.colorScheme, .dark)))
            if let page { model.page = page }
            host.appearance = NSAppearance(named: .darkAqua)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.backgroundColor = NSColor(white: 0.12, alpha: 1)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx   // popover material isn't drawn offscreen: paint a dark fill, then the view over it
            NSColor(white: 0.14, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
            host.displayIgnoringOpacity(host.bounds, in: ctx)
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { model.stopForQuit() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            let menu = NSMenu()
            menu.addItem(withTitle: model.masterMuted ? "Unmute" : "Mute", action: #selector(toggleMute), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(openSettingsItem), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit OpenMixer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if event.modifierFlags.contains(.option) {
            model.toggleOutputMute()
        } else {
            popover.isShown ? popover.performClose(nil) : show()
        }
    }

    @objc private func toggleMute() { model.toggleOutputMute() }
    @objc private func openSettingsItem() { openSettings() }

    private func show() {
        guard let button = item.button, !popover.isShown else { return }
        model.page = .main
        model.refresh()
        resizePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        if model.state.preferences.pinned { popover.contentViewController?.view.window?.level = .floating }
    }

    private func togglePin() {
        model.updatePreferences { $0.pinned.toggle() }
        applyPin()
        if popover.isShown { popover.contentViewController?.view.window?.level = model.state.preferences.pinned ? .floating : .popUpMenu }
    }

    private func applyPin() { popover.behavior = model.state.preferences.pinned ? .applicationDefined : .transient }

    /// Debug aid: opens the popover, flips between pages, and checks the popover size follows the content within 0.3 s.
    private func popoverTest() {
        setvbuf(stdout, nil, _IOLBF, 0)
        show()
        var steps: [(String, Page)] = [("main", .main)]
        if let a = model.apps.first { steps.append(("app effects", .effects(.app(a.id)))) }
        if let d = model.outputDevice { steps.append(("device effects", .effects(.device(d.uid)))) }
        steps.append(("main again", .main))
        var failed = false
        if let w = item.button?.window, let screen = w.screen ?? NSScreen.main {
            let fromRight = screen.frame.maxX - w.frame.maxX
            let ok = fromRight < 300   // default placement sits ~450 pt from the edge on this machine
            print(ok ? "ok  " : "FAIL", "status item is in the right-most slot, \(Int(fromRight)) pt from the screen edge")
            if !ok { failed = true }
        }
        func run(_ i: Int) {
            guard i < steps.count else { print(failed ? "FAILED" : "popover sizing ok"); NSApp.terminate(nil); return }
            model.page = steps[i].1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                let want = host?.sizeThatFits(in: CGSize(width: Layout.width, height: 10_000)) ?? .zero, got = popover.contentSize
                let ok = abs(want.height - got.height) < 1 && abs(got.width - Layout.width) < 1 && popover.isShown
                // Minimum width the content can be squeezed to: anything above the popover width gets clipped.
                let natural = NSHostingController(rootView: RootView(model: model, width: nil, openSettings: {}, togglePin: {})).sizeThatFits(in: CGSize(width: 1, height: 10_000)).width
                let fits = natural <= Layout.width + 0.5
                print(ok && fits ? "ok  " : "FAIL", steps[i].0, "popover", got, "content", want, "natural width", natural, fits ? "" : "← OVERFLOWS \(Layout.width)")
                if !ok || !fits { failed = true }
                run(i + 1)
            }
        }
        run(0)
    }

    private func resizePopover() {
        guard let host else { return }
        let size = host.sizeThatFits(in: CGSize(width: Layout.width, height: 10_000))
        if size.width > 0, size.height > 0, size != popover.contentSize { popover.contentSize = size }
    }

    private func closeUnlessPinned() {
        if popover.isShown, !model.state.preferences.pinned { popover.performClose(nil) }
    }

    func popoverDidShow(_ notification: Notification) {
        model.metering = true
        // Clicks in other apps don't reach this process, so watch for them globally.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeUnlessPinned() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.metering = false
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "OpenMixer Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        if model.state.preferences.pinned == false { popover.performClose(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
