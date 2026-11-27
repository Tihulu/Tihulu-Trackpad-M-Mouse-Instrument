import Foundation

@main struct XYZSetupAdmissionChecks {
    static func main() {
        var count = 0
        for depth in [false, true] {
            for volume in [false, true] {
                for controls in [false, true] {
                    for foreground in [false, true] {
                        for axes in -1...8 {
                            let result = MobileXYZSetupIssue.check(hasDepth: depth, validVolume: volume,
                                usesControls: controls, axes: axes, foreground: foreground)
                            let valid = depth && volume && foreground && (!controls || (1...7).contains(axes))
                            precondition((result == nil) == valid)
                            count += 1
                        }
                    }
                }
            }
        }
        var gate = MobilePermissionRequestFence()
        precondition(!gate.pending)
        let first = gate.begin()!
        precondition(gate.pending)
        precondition(gate.begin() == nil)
        gate.retire()
        precondition(!gate.pending)
        precondition(!gate.finish(first))
        let second = gate.begin()!
        precondition(second != first)
        precondition(!gate.finish(first))
        precondition(gate.pending)
        precondition(gate.finish(second))
        precondition(!gate.pending)
        precondition(!gate.finish(second))
        print("\(count)/\(count) setup combinations and 11 permission-fence assertions PASS")
    }
}
