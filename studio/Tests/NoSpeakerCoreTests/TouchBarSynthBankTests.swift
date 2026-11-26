import Foundation
import Testing
@testable import NoSpeakerCore

@Test func touchBarSynthControlsMapRangesAndToggles() throws {
    let c=TouchBarSynthBank.Control(name:"Resonance",cc:71,low:20,high:100,neutral:64)
    #expect(c.isValid)
    #expect(c.value(normalized:0)==20)
    #expect(c.value(normalized:0.5)==60)
    #expect(c.value(normalized:1)==100)
    #expect(c.value(normalized:.nan)==nil)
    #expect(c.value(normalized:1.01)==nil)
    let toggle=TouchBarSynthBank.Control(name:"Effect",cc:80,style:.toggle,low:10,high:90)
    #expect(toggle.value(normalized:0.49)==10)
    #expect(toggle.value(normalized:0.5)==90)
}
@Test func touchBarSynthBankRejectsDuplicateAndReservedTargets() throws {
    for cc in [0,1,4,6,11,32,38,64,65,69,74,96,97,98,99,100,101,120,127] {
        #expect(!TouchBarSynthBank.permitsCC(cc))
    }
    let a=TouchBarSynthBank.Control(name:"Resonance",cc:71)
    let b=TouchBarSynthBank.Control(name:"Attack",cc:73)
    let bank=try #require(TouchBarSynthBank(controls:[a,b]))
    #expect(bank.adding(.init(name:"Duplicate",cc:71))==nil)
    #expect(bank.adding(.init(id:a.id,name:"Duplicate ID",cc:72))==nil)
    #expect(bank.adding(.init(name:"Invalid",cc:72,low:Int.max))==nil)
    #expect(bank.moving(id:b.id,delta:-1)?.controls==[b,a])
    #expect(bank.removing(id:a.id)?.controls==[b])
    #expect(try JSONDecoder().decode(TouchBarSynthBank.self,from:JSONEncoder().encode(bank))==bank)
    var profile=TouchBarProfile()
    #expect(profile.effectiveSynthBank.controls.isEmpty)
    profile.synthBank=bank
    #expect(try JSONDecoder().decode(TouchBarProfile.self,from:JSONEncoder().encode(profile)).effectiveSynthBank==bank)
}

@Test func touchBarSynthResetUsesScopedOwnerArbitration() throws {
    let control=TouchBarSynthBank.Control(name:"Pan",cc:10,neutral:64)
    let target=SensorDestination(.controlChange,channel:2,number:control.cc)
    var owners=LegacyContinuousOwners()
    let attack=owners.set(.touchBar,target:target,value:.init(90,neutral:control.neutral))
    #expect(attack.map(\.value)==[90])
    let higher=owners.set(.touch,target:target,value:.init(30,neutral:64))
    #expect(higher.map(\.value)==[30])
    let restore=owners.release(.touch)
    #expect(restore.map(\.value)==[90])
    let reset=owners.release(.touchBar)
    #expect(reset.map(\.value)==[64])
}
