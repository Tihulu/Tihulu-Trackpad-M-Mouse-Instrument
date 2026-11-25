import Foundation
import Testing
@testable import NoSpeakerCore

private let noteJSON = #"{"start":0,"duration":480,"channel":0,"pitch":60,"velocity":90}"#
private func planJSON(_ note:String=noteJSON,bpm:String="120",length:String="1920")->String {
    "{\"bpm\":\(bpm),\"length\":\(length),\"notes\":[\(note)]}"
}

@Test func boundedPlanAcceptsReorderedFieldsAndFractionalTempo() throws {
    let input = """
       { "notes" : [ { "velocity":90, "pitch":60, "duration":480, "channel":0, "start":0 } ],
         "length":1920, "bpm":1.205e2 }
       """
    let clip=try BoundedMIDIPlanInput.decode(Data(input.utf8))
    #expect(clip.bpm==120.5 && clip.length==1920 && clip.notes.count==1)
    #expect(clip.notes[0].pitch==60)
}

@Test func boundedPlanRejectsAmbiguousJSONAndCoercions() {
    let bad=[
        planJSON().replacingOccurrences(of:"\"bpm\":120",with:"\"bpm\":120,\"bpm\":121"),
        planJSON(noteJSON.replacingOccurrences(of:"\"pitch\":60",with:"\"pitch\":60,\"pitch\":61")),
        planJSON(noteJSON.replacingOccurrences(of:"\"pitch\":60",with:#""p\u0069tch":60"#)),
        planJSON(noteJSON.replacingOccurrences(of:"\"pitch\":60",with:"\"pitch\":60.0")),
        planJSON(noteJSON.replacingOccurrences(of:"\"pitch\":60",with:"\"pitch\":6e1")),
        planJSON(noteJSON.replacingOccurrences(of:"\"pitch\":60",with:"\"pitch\":true")),
        planJSON(noteJSON.replacingOccurrences(of:"\"pitch\":60",with:"\"pitch\":null")),
        planJSON(noteJSON.replacingOccurrences(of:"\"pitch\":60",with:"\"pitch\":\"60\"")),
        planJSON(noteJSON.replacingOccurrences(of:"\"pitch\":60",with:"\"pitch\":060")),
        planJSON(bpm:"1e999"),planJSON(bpm:"+120"),planJSON(bpm:"120."),
        planJSON(length:"99999999999999999999999"),planJSON() + " {}",
        planJSON(noteJSON+","),
        planJSON(noteJSON.replacingOccurrences(of:"\"pitch\":60,",with:"")),
        planJSON(noteJSON.replacingOccurrences(of:"\"pitch\":60",with:"\"output\":60"))
    ]
    for input in bad {
        #expect(throws:(any Error).self) { _=try BoundedMIDIPlanInput.decode(Data(input.utf8)) }
    }
}

@Test func boundedPlanRejectsOversizeAndSemanticCapacity() {
    let bad=[String(repeating:" ",count:BoundedMIDIPlanInput.maximumBytes+1),
             planJSON(Array(repeating:noteJSON,count:257).joined(separator:",")),
             planJSON(length:"19201"),planJSON(noteJSON+","+noteJSON)]
    for input in bad {
        #expect(throws:(any Error).self) { _=try BoundedMIDIPlanInput.decode(Data(input.utf8)) }
    }
}

@Test func boundedPlanAcceptsExactByteAndNoteCapacity() throws {
    let notes=(0..<256).map { index in
        "{\"start\":0,\"duration\":480,\"channel\":\(index/128),\"pitch\":\(index%128),\"velocity\":90}"
    }.joined(separator:",")
    let input=planJSON(notes,length:"19200")
    let padded=input+String(repeating:" ",count:BoundedMIDIPlanInput.maximumBytes-input.utf8.count)
    let (clip,player)=try BoundedMIDIPlanInput.prepare(Data(padded.utf8))
    #expect(clip.notes.count==256)
    #expect(player.events.count==512 && player.durationNS==10_000_000_000)
    #expect(throws:BoundedMIDIPlanInput.Failure.self) {
        _=try BoundedMIDIPlanInput.prepare(Data((padded+" ").utf8))
    }
}
