import AppKit
import CoreAudio
import Foundation

public struct AudioApp: Identifiable, Equatable {
    /// Icons are fetched fresh on every call, so equality ignores them to avoid needless UI refreshes.
    public static func == (a: AudioApp, b: AudioApp) -> Bool {
        a.id == b.id && a.name == b.name && a.processes == b.processes && a.isPlaying == b.isPlaying
    }

    public let id: String            // bundle identifier
    public let name: String
    public let icon: NSImage?
    public let processes: Set<AudioObjectID>
    public let isPlaying: Bool
}

public enum Apps {
    /// The app macOS holds responsible for a (helper/XPC) process, e.g. WebKit's GPU process -> Safari.
    /// Private libsystem symbol; absent or failing just means we fall back to bundle-id matching.
    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// Groups Core Audio process objects by owning app (helper processes fold into their parent app).
    public static func running() -> [AudioApp] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier != nil && $0.activationPolicy != .prohibited }
        var groups: [String: (app: NSRunningApplication, processes: Set<AudioObjectID>, playing: Bool)] = [:]

        for object in HAL.array(system, HAL.address(kAudioHardwarePropertyProcessObjectList), zero: AudioObjectID(0)) {
            guard let pid = HAL.get(object, HAL.address(kAudioProcessPropertyPID), pid_t(0)),
                  pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let bundle = HAL.string(object, HAL.address(kAudioProcessPropertyBundleID)) ?? ""
            // Prefer a regular (Dock) app: helpers and XPC services fold into the app that owns them.
            let direct = apps.first { $0.processIdentifier == pid }
            let owner = direct.flatMap { $0.activationPolicy == .regular ? $0 : nil }
                ?? responsiblePID.flatMap { f in let r = f(pid); return apps.first { $0.processIdentifier == r && $0.activationPolicy == .regular } }
                ?? apps.filter { !bundle.isEmpty && $0.activationPolicy == .regular && bundle.hasPrefix($0.bundleIdentifier! + ".") }
                    .max { $0.bundleIdentifier!.count < $1.bundleIdentifier!.count }
                ?? direct
            guard let owner, let id = owner.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            let playing = (HAL.get(object, HAL.address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0
            var g = groups[id] ?? (owner, [], false)
            g.processes.insert(object)
            g.playing = g.playing || playing
            groups[id] = g
        }
        return groups.map { id, g in
            AudioApp(id: id, name: g.app.localizedName ?? id, icon: g.app.icon, processes: g.processes, isPlaying: g.playing)
        }.sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
    }
}
