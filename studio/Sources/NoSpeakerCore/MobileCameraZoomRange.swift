import Foundation

/// Camera-relative magnification, not a claim of optical focal length.
public struct MobileCameraZoomRange:Equatable,Sendable {
    public let minimum:Double
    public let maximum:Double
    public let switches:[Double]
    public init?(minimum:Double,maximum:Double,switches:[Double]=[]) {
        guard minimum.isFinite,maximum.isFinite,minimum>0,maximum>=minimum else {return nil}
        self.minimum=minimum;self.maximum=maximum
        self.switches=Array(Set(switches.filter {$0.isFinite && $0>=minimum && $0<=maximum})).sorted()
    }
    public var defaultFactor:Double {max(minimum,min(1,maximum))}
    public func contains(_ value:Double)->Bool {value.isFinite && value>=minimum && value<=maximum}
}
