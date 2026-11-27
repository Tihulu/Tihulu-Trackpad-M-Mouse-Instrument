import Foundation
import Testing
@testable import NoSpeakerCore

@Test func savedSurfaceLayoutsRemainIndependentAndRoundTrip() throws {
    let a=try #require(CustomSurfacePadLayout.grid(surface:.trackpad,columns:4,rows:2))
    let b=try #require(CustomSurfacePadLayout.grid(surface:.touchBar,columns:6,rows:1))
    let replacement=try #require(CustomSurfacePadLayout.grid(surface:.trackpad,columns:2,rows:2))
    var library=CustomSurfaceLayoutLibrary()
    library.save(a);library.save(b);library.save(replacement)
    #expect(library.layouts.count==2)
    #expect(library.layout(for:.trackpad)==replacement)
    #expect(library.layout(for:.touchBar)==b)
    #expect(library.layout(for:.phone)==nil)
    #expect(try JSONDecoder().decode(CustomSurfaceLayoutLibrary.self,from:JSONEncoder().encode(library))==library)
}
@Test func savedSurfaceLibraryRejectsDuplicateOrInvalidRecords() throws {
    let a=try #require(CustomSurfacePadLayout.grid(surface:.phone,columns:2,rows:2))
    let item=try JSONSerialization.jsonObject(with:JSONEncoder().encode(a))
    let data=try JSONSerialization.data(withJSONObject:["layouts":[item,item]])
    #expect(throws:DecodingError.self){try JSONDecoder().decode(CustomSurfaceLayoutLibrary.self,from:data)}
    let invalid=try JSONSerialization.data(withJSONObject:["layouts":[["surface":"phone","pads":[]]]])
    #expect(throws:DecodingError.self){try JSONDecoder().decode(CustomSurfaceLayoutLibrary.self,from:invalid)}
}

@Test func savedSurfaceChannelsRoundTripIndependentlyAndInvalidSaveIsAtomic() throws {
    let trackpad=try #require(CustomSurfacePadPreset.chromatic.layout(surface:.trackpad,channel:0))
    let mouse=try #require(CustomSurfacePadPreset.drums.layout(surface:.magicMouse,channel:1))
    var library=CustomSurfaceLayoutLibrary()
    let savedTrackpad=library.save(trackpad,melodicChannel:3)
    let savedMouse=library.save(mouse,melodicChannel:5)
    #expect(savedTrackpad && savedMouse)
    let before=library
    let invalid=library.save(trackpad,melodicChannel:16)
    #expect(!invalid && library==before)
    #expect(library.melodicChannel(for:.trackpad)==3 && library.melodicChannel(for:.magicMouse)==5)
    #expect(try JSONDecoder().decode(CustomSurfaceLayoutLibrary.self,from:JSONEncoder().encode(library))==library)
}
@Test func savedSurfaceChannelMigrationPreservesLegacyAndRejectsCorruptRecords() throws {
    let layout=try #require(CustomSurfacePadLayout.grid(surface:.trackpad,columns:2,rows:2))
    let item=try JSONSerialization.jsonObject(with:JSONEncoder().encode(layout))
    let legacy=try JSONSerialization.data(withJSONObject:["layouts":[item]])
    let library=try JSONDecoder().decode(CustomSurfaceLayoutLibrary.self,from:legacy)
    #expect(library.layout(for:.trackpad)==layout && library.melodicChannel(for:.trackpad)==nil)
    let bad:[[[String:Any]]]=[
        [["surface":"trackpad","channel":16]],
        [["surface":"magicMouse","channel":1]],
        [["surface":"trackpad","channel":0],["surface":"trackpad","channel":1]]
    ]
    for records in bad {
        let data=try JSONSerialization.data(withJSONObject:["layouts":[item],"channels":records])
        #expect(throws:DecodingError.self){try JSONDecoder().decode(CustomSurfaceLayoutLibrary.self,from:data)}
    }
}

@Test func savedNativePairIsCompleteAndPreservesUnrelatedSurfaces() throws {
    let trackpad=try #require(CustomSurfacePadPreset.chromatic.layout(surface:.trackpad,channel:0))
    let mouse=try #require(CustomSurfacePadPreset.xy.layout(surface:.magicMouse,channel:4))
    let tablet=try #require(CustomSurfacePadPreset.chords.layout(surface:.tablet,channel:2))
    var library=CustomSurfaceLayoutLibrary()
    library.save(trackpad)
    #expect(library.nativePair == nil)
    library.save(mouse)
    #expect(library.nativePair?.trackpadChannel == 0 && library.nativePair?.mouseChannel == 1)
    #expect(library.melodicChannel(for:.trackpad) == nil)
    let savedTablet=library.save(tablet,melodicChannel:2)
    #expect(savedTablet)
    let pair=try #require(CustomSurfaceLayoutLibrary.NativePair(trackpad:trackpad,mouse:mouse,trackpadChannel:3,mouseChannel:4))
    library.saveNativePair(pair)
    #expect(library.nativePair == pair && library.layout(for:.tablet) == tablet && library.melodicChannel(for:.tablet) == 2)
    let decoded=try JSONDecoder().decode(CustomSurfaceLayoutLibrary.self,from:JSONEncoder().encode(library))
    #expect(decoded.nativePair == pair && decoded == library)
    #expect(CustomSurfaceLayoutLibrary.NativePair(trackpad:mouse,mouse:trackpad,trackpadChannel:0,mouseChannel:1) == nil)
    #expect(CustomSurfaceLayoutLibrary.NativePair(trackpad:trackpad,mouse:mouse,trackpadChannel:16,mouseChannel:1) == nil)
}
