import Foundation

/// One stage of the signal path: gain/balance -> EQ -> headphone profile -> plugins -> limiter. Planar stereo, in place.
public final class Processor {
    private let graphic = FilterBank()
    private let profile = FilterBank()
    public let plugins = PluginChain()
    private var targetL: Float = 1, targetR: Float = 1
    private var currentL: Float = 1, currentR: Float = 1
    private var bypassed = false
    private var limiterOn = false
    private var limiterGain: Float = 1
    private var configuredRate = 0.0
    private var started = false
    private var configuredEQ: [Float] = [], configuredProfile: [ParametricFilter] = []
    private var configuredPreamp: Float = 0
    /// Peak |sample| of the most recent buffer, read by the level meters.
    public private(set) var peak: Float = 0
    static let ceiling: Float = 0.98

    public init() {}

    /// Main thread. Cheap when nothing changed, so the model may call it on every reconcile.
    public func configure(_ fx: Effects, sampleRate: Double) {
        let amp = fx.muted ? 0 : Effects.amplitude(fx.volume)
        targetL = amp * min(1, 1 - fx.balance)
        targetR = amp * min(1, 1 + fx.balance)
        bypassed = fx.bypassed
        limiterOn = fx.limiter || amp > 1
        if sampleRate != configuredRate || fx.eq != configuredEQ {
            graphic.set(GraphicEQ.filters(gains: fx.eq, sampleRate: Float(sampleRate)))
            configuredEQ = fx.eq
        }
        if sampleRate != configuredRate || fx.parametric != configuredProfile || fx.preamp != configuredPreamp {
            profile.set(fx.parametric.map { Biquad.make($0, sampleRate: Float(sampleRate)) })
            configuredProfile = fx.parametric; configuredPreamp = fx.preamp
        }
        if !fx.parametric.isEmpty {
            let pre = powf(10, fx.preamp / 20)
            targetL *= pre; targetR *= pre
        }
        plugins.configure(fx.plugins, sampleRate: sampleRate)
        configuredRate = sampleRate
        if !started { currentL = targetL; currentR = targetR; started = true }   // first setting applies at once, no fade-in
    }

    public func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        // Linear ramp across the buffer: no zipper noise when a slider moves.
        var gl = currentL, gr = currentR
        let dl = (targetL - gl) / Float(frames), dr = (targetR - gr) / Float(frames)
        for n in 0..<frames { gl += dl; gr += dr; l[n] *= gl; r[n] *= gr }
        currentL = targetL; currentR = targetR

        if !bypassed {
            graphic.process(l, frames: frames, channel: 0); graphic.process(r, frames: frames, channel: 1)
            profile.process(l, frames: frames, channel: 0); profile.process(r, frames: frames, channel: 1)
            plugins.process(l, r, frames: frames)
        }

        var p: Float = 0
        if limiterOn {
            // Instant attack, 150 ms release: transparent below the ceiling.
            let release: Float = 1 - expf(-1 / (0.15 * Float(max(configuredRate, 8000))))
            var g = limiterGain
            for n in 0..<frames {
                let m = max(abs(l[n]), abs(r[n]))
                let need: Float = m * g > Self.ceiling ? Self.ceiling / m : 1
                g = need < g ? need : g + (1 - g) * release
                l[n] *= g; r[n] *= g
                p = max(p, abs(l[n]), abs(r[n]))
            }
            limiterGain = g
        }
        for n in 0..<frames {
            l[n] = max(-1, min(1, l[n])); r[n] = max(-1, min(1, r[n]))
            p = max(p, abs(l[n]), abs(r[n]))
        }
        peak = p
    }
}
