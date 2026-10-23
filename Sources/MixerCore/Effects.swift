import Foundation

public struct ParametricFilter: Codable, Equatable {
    public enum Kind: String, Codable { case peak, lowShelf, highShelf }
    public var kind: Kind
    public var frequency: Float
    public var gain: Float
    public var q: Float
    public init(kind: Kind, frequency: Float, gain: Float, q: Float) {
        self.kind = kind; self.frequency = frequency; self.gain = gain; self.q = q
    }
}

/// An Audio Unit effect in a chain. `state` is a property-list encoded `fullState`.
public struct PluginSetting: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var type: UInt32
    public var subType: UInt32
    public var manufacturer: UInt32
    public var state: Data?
    public var bypassed = false
    public init(name: String, type: UInt32, subType: UInt32, manufacturer: UInt32) {
        self.name = name; self.type = type; self.subType = subType; self.manufacturer = manufacturer
    }
}

/// Everything that can be applied to an app's or a device's audio.
public struct Effects: Codable, Equatable {
    public var volume: Float = 1            // slider position, 0...2 (amplitude is volume²)
    public var muted = false
    public var balance: Float = 0           // -1 (left) ... 1 (right)
    public var eq = [Float](repeating: 0, count: 10)
    public var parametric: [ParametricFilter] = []
    public var parametricName: String?
    public var preamp: Float = 0            // dB, applied with the parametric profile
    public var limiter = false
    public var plugins: [PluginSetting] = []
    public var bypassed = false             // bypass EQ/plugins, keep volume
    public var outputUID: String?           // apps only: nil follows the system default output

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        volume = get(.volume, 1); muted = get(.muted, false); balance = get(.balance, 0)
        eq = get(.eq, eq); parametric = get(.parametric, []); parametricName = get(.parametricName, nil)
        preamp = get(.preamp, 0); limiter = get(.limiter, false); plugins = get(.plugins, [])
        bypassed = get(.bypassed, false); outputUID = get(.outputUID, nil)
        if eq.count != 10 { eq = [Float](repeating: 0, count: 10) }
    }

    /// True when processing beyond volume/mute is configured.
    public var hasProcessing: Bool {
        balance != 0 || limiter || (!bypassed && (eq.contains { abs($0) > 0.05 } || !parametric.isEmpty || plugins.contains { !$0.bypassed }))
    }

    /// True when the settings do nothing at all, so the audio can be left untouched.
    public var isNeutral: Bool { self == Effects() }

    /// Linear amplitude for a slider position.
    public static func amplitude(_ volume: Float) -> Float { volume * volume }
}

public struct Shortcut: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32   // Carbon modifier mask
    public var label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
}

public struct DeviceConfig: Codable, Equatable {
    public var hidden = false
    public var forceSoftwareVolume = false
    public var maxVolume: Float = 1
    public var volumeUp: Shortcut?
    public var volumeDown: Shortcut?
    public var mute: Shortcut?
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
        forceSoftwareVolume = (try? c.decodeIfPresent(Bool.self, forKey: .forceSoftwareVolume)) ?? false
        maxVolume = (try? c.decodeIfPresent(Float.self, forKey: .maxVolume)) ?? 1
        volumeUp = try? c.decodeIfPresent(Shortcut.self, forKey: .volumeUp)
        volumeDown = try? c.decodeIfPresent(Shortcut.self, forKey: .volumeDown)
        mute = try? c.decodeIfPresent(Shortcut.self, forKey: .mute)
    }
}

public struct EQPreset: Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var gains: [Float]
    public init(name: String, gains: [Float]) { self.name = name; self.gains = gains }
    public static let builtIn: [EQPreset] = [
        EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 6]),
        EQPreset(name: "Vocal", gains: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
        EQPreset(name: "Loudness", gains: [5, 4, 1, 0, -1, 0, 1, 3, 4, 3]),
        EQPreset(name: "Late Night", gains: [-4, -2, 0, 1, 2, 2, 1, 0, -2, -4]),
    ]
}

public struct QuickConfig: Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var appFX: [String: Effects]
    public var deviceFX: [String: Effects]
    public var outputUID: String?
    public var inputUID: String?
    public init(name: String, appFX: [String: Effects], deviceFX: [String: Effects], outputUID: String?, inputUID: String?) {
        self.name = name; self.appFX = appFX; self.deviceFX = deviceFX; self.outputUID = outputUID; self.inputUID = inputUID
    }
}

public struct Preferences: Codable, Equatable {
    public var muteOnDeviceChange = true
    public var keyboardVolumeControl = false
    public var showDockIcon = false
    public var pinned = false
    public var showMeters = true
    public var volumeStep: Float = 1.0 / 16
    public var showShortcut: Shortcut?
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        muteOnDeviceChange = get(.muteOnDeviceChange, true); keyboardVolumeControl = get(.keyboardVolumeControl, false)
        showDockIcon = get(.showDockIcon, false); pinned = get(.pinned, false); showMeters = get(.showMeters, true)
        volumeStep = get(.volumeStep, 1.0 / 16); showShortcut = get(.showShortcut, nil)
    }
}

/// Everything OpenMixer persists, stored as one JSON file.
public struct AppState: Codable, Equatable {
    public var appFX: [String: Effects] = [:]
    public var deviceFX: [String: Effects] = [:]
    public var deviceConfig: [String: DeviceConfig] = [:]
    public var excludedApps: [String] = []
    public var favoriteApps: [String] = []
    public var userPresets: [EQPreset] = []
    public var quickConfigs: [QuickConfig] = []
    public var preferences = Preferences()
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        appFX = get(.appFX, [:]); deviceFX = get(.deviceFX, [:]); deviceConfig = get(.deviceConfig, [:])
        excludedApps = get(.excludedApps, []); favoriteApps = get(.favoriteApps, []); userPresets = get(.userPresets, [])
        quickConfigs = get(.quickConfigs, []); preferences = get(.preferences, Preferences())
    }

    public static func load(from url: URL) -> AppState {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AppState.self, from: $0) } ?? AppState()
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Parser for the AutoEQ "ParametricEQ.txt" format used by most open headphone-correction profiles.
public enum ParametricProfile {
    public static func parse(_ text: String) -> (preamp: Float, filters: [ParametricFilter]) {
        var preamp: Float = 0
        var filters: [ParametricFilter] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if t.first?.lowercased() == "preamp:", t.count > 1, let v = Float(t[1]) { preamp = v; continue }
            guard t.first?.lowercased() == "filter", t.contains("ON") else { continue }
            func value(after key: String) -> Float? { t.firstIndex(of: key).flatMap { $0 + 1 < t.count ? Float(t[$0 + 1]) : nil } }
            let kind: ParametricFilter.Kind? = t.contains("PK") ? .peak : (t.contains("LSC") || t.contains("LS")) ? .lowShelf : (t.contains("HSC") || t.contains("HS")) ? .highShelf : nil
            guard let kind, let fc = value(after: "Fc"), let gain = value(after: "Gain") else { continue }
            filters.append(ParametricFilter(kind: kind, frequency: fc, gain: gain, q: value(after: "Q") ?? 0.707))
        }
        return (preamp, filters)
    }
}
