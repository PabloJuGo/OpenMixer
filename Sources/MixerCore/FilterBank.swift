import Foundation
import os

/// RBJ biquad coefficient builders. Each returns [b0, b1, b2, a1, a2] normalised by a0.
public enum Biquad {
    public static func make(_ f: ParametricFilter, sampleRate: Float) -> [Float] {
        let a = powf(10, max(-24, min(24, f.gain)) / 40)
        let w = 2 * Float.pi * max(10, min(f.frequency, sampleRate * 0.45)) / sampleRate
        let cw = cosf(w), q = max(0.1, f.q), alpha = sinf(w) / (2 * q)
        switch f.kind {
        case .peak:
            let a0 = 1 + alpha / a
            return [(1 + alpha * a) / a0, -2 * cw / a0, (1 - alpha * a) / a0, -2 * cw / a0, (1 - alpha / a) / a0]
        case .lowShelf:
            let s = 2 * sqrtf(a) * alpha
            let a0 = (a + 1) + (a - 1) * cw + s
            return [a * ((a + 1) - (a - 1) * cw + s) / a0, 2 * a * ((a - 1) - (a + 1) * cw) / a0,
                    a * ((a + 1) - (a - 1) * cw - s) / a0, -2 * ((a - 1) + (a + 1) * cw) / a0,
                    ((a + 1) + (a - 1) * cw - s) / a0]
        case .highShelf:
            let s = 2 * sqrtf(a) * alpha
            let a0 = (a + 1) - (a - 1) * cw + s
            return [a * ((a + 1) + (a - 1) * cw + s) / a0, -2 * a * ((a - 1) + (a + 1) * cw) / a0,
                    a * ((a + 1) + (a - 1) * cw - s) / a0, 2 * ((a - 1) - (a + 1) * cw) / a0,
                    ((a + 1) - (a - 1) * cw - s) / a0]
        }
    }
}

/// A stereo cascade of biquads (transposed direct form II). `set` runs on the main thread,
/// `process` on the audio thread; if they collide the audio thread skips that buffer's filtering.
public final class FilterBank {
    public static let capacity = 32
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private let coeffs = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 5)
    private let state = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 4)
    private var active = 0

    public init() {
        lock.initialize(to: os_unfair_lock())
        coeffs.initialize(repeating: 0, count: Self.capacity * 5)
        state.initialize(repeating: 0, count: Self.capacity * 4)
    }

    deinit { lock.deallocate(); coeffs.deallocate(); state.deallocate() }

    public func set(_ filters: [[Float]]) {
        let list = filters.prefix(Self.capacity)
        os_unfair_lock_lock(lock)
        for (i, f) in list.enumerated() { for k in 0..<5 { coeffs[i * 5 + k] = f[k] } }
        if list.count != active { state.update(repeating: 0, count: Self.capacity * 4) }
        active = list.count
        os_unfair_lock_unlock(lock)
    }

    public func process(_ data: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        guard active > 0, channel < 2, os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }
        for band in 0..<active {
            let c = coeffs + band * 5, s = state + (band * 2 + channel) * 2
            let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
            var z1 = s[0], z2 = s[1]
            for n in 0..<frames {
                let x = data[n]
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                data[n] = y
            }
            s[0] = z1; s[1] = z2
        }
    }
}

public enum GraphicEQ {
    public static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    /// Bands within 0.05 dB of flat are skipped.
    public static func filters(gains: [Float], sampleRate: Float) -> [[Float]] {
        zip(frequencies, gains).filter { abs($0.1) > 0.05 }.map {
            Biquad.make(ParametricFilter(kind: .peak, frequency: $0.0, gain: max(-12, min(12, $0.1)), q: 1.41), sampleRate: sampleRate)
        }
    }
}
