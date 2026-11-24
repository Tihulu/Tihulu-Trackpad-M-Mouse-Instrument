/// Validate physical samples before any floating-point to integer conversion.
public enum TouchSampleDomain {
    public struct Sample: Equatable, Sendable {
        public let x,y,pressure: Double
    }
    public static func normalize(x: Double,y: Double,pressure: Double) -> Sample? {
        guard x.isFinite,y.isFinite,pressure.isFinite else { return nil }
        return .init(x:min(0.9999,max(0,x)),y:min(1,max(0,y)),pressure:min(1,max(0,pressure)))
    }
    public static func validConfiguration(root: Int,width: Double,span: Double,
                                          threshold: Double,level: Double) -> Bool {
        (0...127).contains(root) && width.isFinite && span.isFinite &&
            threshold.isFinite && level.isFinite &&
            (0.45...2.5).contains(width) && (1...96).contains(span) &&
            (0...1).contains(threshold) && (0...1).contains(level)
    }
}
