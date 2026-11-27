import Foundation
import Testing
@testable import NoSpeakerCore

private typealias Envelope = NativeHelperRelativeEnvelope
private let registration = UUID()
private func record(_ state: Int, id: Int = 1, source: NativeHelperRelativeClutch.Surface = .magicMouse,
                    x: Double = 0.5, down: Bool? = nil) -> Envelope.Record {
    .init(state:state,isDown:down ?? (state != 5),contact:.init(surface:source,id:id,x:x,y:0.5,contactSize:0.5))
}
private func project(_ count: Int?, _ states: [Int] = [], _ records: [Envelope.Record] = [],
                     valid: Bool = true, current: Bool = true, token: UUID? = registration,
                     acquisition: Int64? = 1_000_000_000) -> NativeHelperRelativeClutch.SourceFrame {
    Envelope.project(surface:.magicMouse,registration:token,registrationCurrent:current,acquisitionNS:acquisition,
                     validEnvelope:valid,rawCount:count,rawStates:states,records:records,maximumRecords:32)
}
@Test func nativeRelativeEnvelopeRejectsMalformedFilteredAndUnregisteredNeutral() {
    let zero = project(0)
    #expect(zero.isGenuineNeutral && zero.acquisitionNS == 1_000_000_000 && zero.receipt == 1)
    for count in [-1,1,33] { #expect(!project(count,valid:false).isGenuineNeutral) }
    #expect(!project(nil).isGenuineNeutral)
    #expect(!project(1,[2]).isGenuineNeutral)
    #expect(!project(1,[5],[record(5)]).isGenuineNeutral)
    #expect(!project(0,current:false).isGenuineNeutral)
    #expect(!project(0,token:nil).isGenuineNeutral)
    #expect(!project(0,acquisition:nil).isGenuineNeutral)
    #expect(!project(0,acquisition:-1).isGenuineNeutral)
}
@Test func nativeRelativeEnvelopeRequiresExactStateParityAndRawDomains() {
    #expect(project(1,[3],[record(3)]).isComplete)
    #expect(!project(1,[4],[record(3)]).isComplete)
    #expect(!project(1,[3],[record(3,down:false)]).isComplete)
    #expect(!project(1,[3],[record(3,source:.trackpad)]).isComplete)
    #expect(!project(1,[3],[record(3,x:.nan)]).isComplete)
    #expect(!project(2,[3,4],[record(3),record(4)]).isComplete)
    #expect(project(2,[3,5],[record(3),record(5,id:2)]).isComplete)
    #expect(project(32,Array(repeating:3,count:32),(0..<32).map{record(3,id:$0)}).isComplete)
    #expect(!project(33,Array(repeating:3,count:33),(0..<33).map{record(3,id:$0)}).isComplete)
}
