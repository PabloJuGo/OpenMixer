import AppKit
import ApplicationServices

/// Intercepts the keyboard volume keys so they can drive devices macOS can't control natively.
/// Needs the Accessibility permission; `handler` returns true to swallow the key.
public final class MediaKeys {
    public enum Key { case up, down, mute }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate let handler: (Key) -> Bool

    public init(handler: @escaping (Key) -> Bool) { self.handler = handler }
    deinit { stop() }

    public static var trusted: Bool { AXIsProcessTrusted() }
    public static func requestTrust() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil, Self.trusted else { return tap != nil }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
            let me = Unmanaged<MediaKeys>.fromOpaque(info!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
            let code = (ns.data1 & 0xFFFF_0000) >> 16, down = ((ns.data1 & 0xFF00) >> 8) == 0xA
            let key: Key? = code == 0 ? .up : code == 1 ? .down : code == 7 ? .mute : nil
            guard let key else { return Unmanaged.passUnretained(event) }
            if !down { return me.swallowRelease ? nil : Unmanaged.passUnretained(event) }
            me.swallowRelease = me.handler(key)
            return me.swallowRelease ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    fileprivate var swallowRelease = false

    public func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil; source = nil
    }
}
