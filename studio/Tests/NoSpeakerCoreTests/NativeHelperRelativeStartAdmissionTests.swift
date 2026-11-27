import Foundation
import Testing
@testable import NoSpeakerCore

@Test(arguments: [NativeHelperRelativeClutch.Surface.trackpad, .magicMouse], SurfaceOrientation.allCases)
func relativeStartAdmissionRequiresSelectedBoundary(
    selected: NativeHelperRelativeClutch.Surface, orientation: SurfaceOrientation
) throws {
    typealias Clutch = NativeHelperRelativeClutch
    for actual in [Clutch.Surface.trackpad, .magicMouse] {
        for channel in 1...16 {
            for mask in 1...7 {
                let axes = Set(Clutch.Axis.allCases.enumerated().compactMap { (i, axis) in
                    mask & (1 << i) == 0 ? nil : axis
                })
                let request = try NativeHelperRelativeStartRequest.resolve(selectedSurface: selected,
                    orientation: orientation, sendToDAW: true, enabled: axes,
                    selectedSurfaceUsesSustain: true, sharePedalSurface: true,
                    configureReceiverBendRange: false, oneBasedChannel: channel,
                    vibratoCC: 1, expressionCC: 74, settings: .init()).get()
                let registration = UUID(), monitor = UUID()
                let boundary = try #require(NativeHelperRelativeArmBoundary(source: actual,
                    registration: registration, afterSequence: 10, afterAcquisitionNS: 1_000_000_000))
                let binding = NativeHelperRelativeInputBinding(request: request, boundary: boundary, monitor: monitor)
                #expect((binding != nil) == (selected == actual))
                if let binding {
                    #expect(binding.boundary.source == selected)
                    #expect(binding.boundary.registration == registration)
                    #expect(binding.boundary.afterSequence == 10)
                    #expect(binding.boundary.afterAcquisitionNS == 1_000_000_000)
                    #expect(binding.monitor == monitor)
                    #expect(binding.plan.targetDestinations == request.output.configuration.plan.targetDestinations)
                }
            }
        }
    }
}
