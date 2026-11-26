import Foundation
import Testing
@testable import NoSpeakerCore

@Test func touchBarSavedProfilesKeepIndependentSettings() throws {
    var library=TouchBarProfileLibrary()
    var a=TouchBarProfile(zones:[.keys,.sustain],channel:2,noteVelocity:87)
    a.visibleKeyCount=13
    let b=TouchBarProfile(zones:[.pitchBend,.expression],sustainMode:.hold,channel:8)
    let savedA=library.save(name:" Piano ",profile:a)
    let savedB=library.save(name:"Helper",profile:b)
    #expect(savedA == .saved && savedB == .saved)
    let duplicate=library.save(name:"PIANO",profile:b)
    #expect(duplicate == .duplicate)
    #expect(library.entries.first?.profile == a.normalized())
    let restored=try JSONDecoder().decode(TouchBarProfileLibrary.self,from:JSONEncoder().encode(library))
    #expect(restored == library)
    let replaced=library.replace(id:"piano",profile:b)
    #expect(replaced == .saved)
    #expect(library.entries.map(\.profile)==[b.normalized(),b.normalized()])
    let removed=library.remove(id:"piano")
    #expect(removed && library.entries.count==1)
}
@Test func touchBarSavedProfilesRejectInvalidAndOversizedLibraries() throws {
    var library=TouchBarProfileLibrary()
    for name in ["","   ","a\u{0001}b",String(repeating:"x",count:65)] {
        let result=library.save(name:name,profile:.init())
        #expect(result == .invalidName)
    }
    for index in 0..<TouchBarProfileLibrary.capacity {
        let result=library.save(name:"Profile \(index)",profile:.init())
        #expect(result == .saved)
    }
    let overflow=library.save(name:"Overflow",profile:.init())
    #expect(overflow == .full)
    let data=try JSONEncoder().encode(library)
    var json=try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
    var entries=try #require(json["entries"] as? [[String:Any]])
    entries[1]=entries[0];json["entries"]=entries
    let invalid=try JSONSerialization.data(withJSONObject:json)
    #expect(throws:DecodingError.self){try JSONDecoder().decode(TouchBarProfileLibrary.self,from:invalid)}
}
