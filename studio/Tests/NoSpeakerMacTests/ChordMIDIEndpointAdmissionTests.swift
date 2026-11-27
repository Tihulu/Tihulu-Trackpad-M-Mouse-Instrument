#if os(macOS)
import CoreMIDI
import Testing
@testable import NoSpeakerMac

struct ChordMIDIEndpointAdmissionTests {
    @MainActor
    @Test(arguments: [OSStatus(0), -1, -2, -304, 1, Int32.min, Int32.max],
          [MIDIEndpointRef(0), 1, UInt32.max])
    func creationRequiresSuccessAndNonzeroHandle(status: OSStatus, handle: MIDIEndpointRef) throws {
        let output = ChordMIDIOutput()
        var creations = 0
        var registered: [MIDIEndpointRef] = []
        var failure: OSStatus?
        do {
            try output.open(create: {
                creations += 1
                return (status, handle)
            }, register: { registered.append($0) })
        } catch MIDIHapticError.source(let error) {
            failure = error
        }
        let expected: OSStatus? = status != 0 ? status : (handle == 0 ? -1 : nil)
        #expect(failure == expected)
        #expect(registered == (expected == nil ? [handle] : []))
        #expect(creations == 1)

        for _ in 0..<2 {
            try output.open(create: {
                creations += 1
                return (0, 42)
            }, register: { registered.append($0) })
        }
        #expect(registered == (expected == nil ? [handle] : [42]))
        #expect(creations == (expected == nil ? 1 : 2))
    }

    @MainActor
    @Test func creationThrowDoesNotPublishOrPreventRetry() throws {
        let output = ChordMIDIOutput()
        var registered: [MIDIEndpointRef] = []
        var failure: OSStatus?
        do {
            try output.open(create: { throw MIDIHapticError.client(-2) },
                            register: { registered.append($0) })
        } catch MIDIHapticError.client(let error) {
            failure = error
        }
        #expect(failure == -2)
        #expect(registered.isEmpty)
        try output.open(create: { (0, 42) }, register: { registered.append($0) })
        #expect(registered == [42])
    }
}
#endif
