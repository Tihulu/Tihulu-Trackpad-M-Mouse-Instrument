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
