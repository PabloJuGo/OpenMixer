import AppKit
import Carbon.HIToolbox

/// Global shortcuts via Carbon (needs no special permission).
public final class HotKeyCenter {
    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var next: UInt32 = 1
    private var handlerRef: EventHandlerRef?

    public init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Unmanaged<HotKeyCenter>.fromOpaque(userData!).takeUnretainedValue().handlers[id.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    deinit { removeAll(); if let handlerRef { RemoveEventHandler(handlerRef) } }

    public func removeAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []; handlers = [:]
    }

    /// Returns false if the system refused (e.g. already in use).
    @discardableResult
    public func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4F4D_5859), id: next)
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return false }
        refs.append(ref); handlers[next] = action; next += 1
        return true
    }

    public static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    public static func label(for shortcut: Shortcut) -> String {
        var s = ""
        if shortcut.modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if shortcut.modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + shortcut.label
    }

    /// Builds a shortcut from a key event; nil if it has no modifier and isn't a function key.
    public static func shortcut(from event: NSEvent) -> Shortcut? {
        let mods = carbonModifiers(event.modifierFlags)
        let fkeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        guard mods != 0 || fkeys.contains(Int(event.keyCode)) else { return nil }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        let label = names[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, label: label)
    }
}
