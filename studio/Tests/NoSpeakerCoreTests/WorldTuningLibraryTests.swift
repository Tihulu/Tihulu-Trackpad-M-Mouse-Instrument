import Testing
@testable import NoSpeakerCore

@Test func worldTuningCatalogIDsAndPitchDomainsAreValid() throws {
    let presets=WorldTuningLibrary.presets
    #expect(presets.count == 74)
    #expect(Set(presets.map(\.id)).count == presets.count)
    for p in presets {
        #expect(!p.source.isEmpty && !p.note.isEmpty)
        #expect(p.cents.first == 0)
        #expect(p.cents.allSatisfy{$0.isFinite})
        #expect(zip(p.cents,p.cents.dropFirst()).allSatisfy{$0.0<$0.1})
        if p.octavePeriodic {
            let t=try #require(p.tuning())
            #expect(t.degrees==p.cents)
            #expect(t.pitch(step:t.degrees.count)?.centsFromRoot==1200)
        } else {
            #expect(p.tuning()==nil)
        }
    }
}
@Test func worldTuningDoesNotCollapseRegionalRastOrSamePitchAliases() throws {
    let tr=try #require(WorldTuningLibrary.preset(id:"tr.rast"))
    let ar=try #require(WorldTuningLibrary.preset(id:"ar.rast"))
    #expect(tr.cents != ar.cents)
    #expect(abs(tr.cents[2]-1200*17/53)<0.000001)
    #expect(ar.cents[2]==350)
    let shur=try #require(WorldTuningLibrary.preset(id:"ir.shur"))
    let nava=try #require(WorldTuningLibrary.preset(id:"ir.nava"))
    #expect(shur.id != nava.id && shur.cents == nava.cents)
}
@Test func worldTuningFiniteSamplesNeverBecomeOctaveScales() throws {
    let p=try #require(WorldTuningLibrary.preset(id:"americas.bolivia-m0045"))
    #expect(p.cents.last==2394 && p.tuning()==nil)
    let s=try #require(WorldTuningLibrary.preset(id:"tr.saba"))
    #expect(!s.octavePeriodic && s.tuning()==nil)
    #expect(WorldTuningLibrary.preset(id:"ar.jins-sikah")?.tuning()==nil)
}

@Test func worldTuningContextVariantsAndGlobalMeasurementsStayDistinct() throws {
    let u=try #require(WorldTuningLibrary.preset(id:"tr.ussak"))
    let low=try #require(WorldTuningLibrary.preset(id:"tr.ussak-lower2"))
    #expect(abs(u.cents[1]-low.cents[1]-2400/53)<0.000001)
    #expect(Array(u.cents.dropFirst(2)) == Array(low.cents.dropFirst(2)))
    #expect(low.kind == .approximation)
    for id in ["asia.koto-m0420","asia.korea-m0240","americas.peru-m0153"] {
        let p=try #require(WorldTuningLibrary.preset(id:id))
        #expect(p.kind == .documentedSample && p.tuning()==nil)
    }
}
