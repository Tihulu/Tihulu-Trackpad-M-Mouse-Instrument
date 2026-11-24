import Foundation

/// Magnitude-based percussive onset, not an inference of user intent.
/// Input is normalized gravity-free acceleration. Host monotonic time only.
public struct AirStrikeDetector: Sendable {
    public struct Settings: Equatable, Sendable {
        public let threshold: Double
        public let resetThreshold: Double
        public let quietSeconds: Double
        public let minimumInterval: Double
        public init?(threshold: Double = 0.45, resetThreshold: Double = 0.20,
                     quietSeconds: Double = 0.08, minimumInterval: Double = 0.12) {
            guard threshold.isFinite, resetThreshold.isFinite,
                  (0.10...0.95).contains(threshold), (0...0.8).contains(resetThreshold),
                  threshold-resetThreshold >= 0.05,
                  quietSeconds.isFinite, (0.03...0.25).contains(quietSeconds),
                  minimumInterval.isFinite, (0.10...0.5).contains(minimumInterval) else { return nil }
            self.threshold = threshold
            self.resetThreshold = resetThreshold
            self.quietSeconds = quietSeconds
            self.minimumInterval = minimumInterval
        }
    }
    public let settings: Settings
    private var lastTime: Double?
    private var quietSince: Double?
    private var ready = false
    private var lastStrike: Double?
    public init(settings: Settings = Settings()!) { self.settings = settings }

    /// Returns a normalized velocity strength once per qualified onset.
    /// A gap or invalid/replayed sample resets readiness; no latent strike.
    public mutating func ingest(_ magnitude: Double, now: Double) -> Double? {
        guard magnitude.isFinite, (0...1).contains(magnitude), now.isFinite, now >= 0 else {
            reset(); return nil
        }
        if let lastTime, now <= lastTime || now-lastTime >= 0.35 {
            reset()
            return nil
        }
        lastTime = now
        if magnitude <= settings.resetThreshold {
            if quietSince == nil { quietSince = now }
            if now-(quietSince ?? now) >= settings.quietSeconds { ready = true }
            return nil
        }
        quietSince = nil
        guard magnitude >= settings.threshold else { return nil }
        let wasReady = ready
        ready = false
        guard wasReady, lastStrike.map({ now-$0 >= settings.minimumInterval }) ?? true else { return nil }
        lastStrike = now
        return 0.25 + 0.75 * (magnitude-settings.threshold)/(1-settings.threshold)
    }
    public mutating func reset() {
        lastTime = nil; quietSince = nil; ready = false; lastStrike = nil
    }
}
