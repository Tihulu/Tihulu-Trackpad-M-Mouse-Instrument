import Foundation

@main struct AirEffectiveRangeChecks {
    static func main() {
        let values: [Double] = [.nan, -.infinity, -1, 0, 0.099, 0.1, 0.15, 0.2, 0.25, 0.3, 0.5, 0.85, 1.5, 2.9, 3, 3.001, .infinity]
        var combinations = 0
        for near in values {
            for far in values {
                let normal = MobileAirEffectiveRange.resolve(usesDepth: false, near: near, far: far)
                precondition(normal == MobileAirEffectiveRange(near: 0.25, far: 0.85))
                let depth = MobileAirEffectiveRange.resolve(usesDepth: true, near: near, far: far)
                let admitted = near.isFinite && far.isFinite && near >= 0.1 && far <= 3 && far - near >= 0.1
                precondition((depth != nil) == admitted)
                if let depth { precondition(depth.near == near && depth.far == far) }
                combinations += 2
            }
        }
        var rejectedBoundary = 0
        for cm in stride(from: 10, through: 150, by: 5) {
            let near = Double(cm) / 100
            let far = Double(cm + 10) / 100
            let depth = MobileAirEffectiveRange.resolve(usesDepth: true, near: near, far: far)
            precondition((depth != nil) == (far - near >= 0.1))
            if depth == nil { rejectedBoundary += 1 }
            precondition(MobileAirEffectiveRange.resolve(usesDepth: true, near: near, far: Double(cm + 9) / 100) == nil)
        }
        precondition(MobileAirEffectiveRange.resolve(usesDepth: true, near: 0.25, far: 0.35) == nil)
        precondition(MobileAirEffectiveRange.resolve(usesDepth: true, near: 0.25, far: 0.4) != nil)
        print("\(combinations)/\(combinations) range cases PASS; 29 boundary and 29 below-minimum cases PASS; \(rejectedBoundary)/29 nominal 10cm pairs conservatively rejected")
    }
}
