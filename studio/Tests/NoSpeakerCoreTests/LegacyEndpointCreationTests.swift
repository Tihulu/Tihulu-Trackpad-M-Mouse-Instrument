import Testing
@testable import NoSpeakerCore

struct LegacyEndpointCreationTests {
    @Test(arguments: [Int32.min, -304, -2, -1, 0, 1, Int32.max])
    func creationRequiresSuccessAndNonzeroHandle(status: Int32) {
        for handle in [UInt32(0), 1, 2, UInt32.max] {
            let expected: Int32? = status != 0 ? status : (handle == 0 ? -1 : nil)
            #expect(LegacyRecoveryPolicy.endpointCreationFailure(status: status, handle: handle) == expected)
        }
    }
}
