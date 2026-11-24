import Foundation
import Testing
@testable import NoSpeakerCore

@Test func drumComposerKeepsStyleAnchorsAndValidEditableGrid() {
    for style in DrumComposerStyle.allCases {
        let result = PatternComposer.drums(style: style, complexity: 80, fills: true, seed: 17)
        #expect(result.contains("kick:0"))
        #expect(result.contains("tom:14"))
        #expect(result == PatternComposer.drums(style: style, complexity: 80, fills: true, seed: 17))
        for key in result {
            let parts = key.split(separator: ":")
            #expect(parts.count == 2)
            if parts.count == 2 {
                #expect(DrumVoice(rawValue: String(parts[0])) != nil)
                #expect(Int(parts[1]).map { (0..<16).contains($0) } == true)
            }
        }
        for step in 0..<16 {
            #expect(!(result.contains("closedHat:" + String(step)) && result.contains("openHat:" + String(step))))
        }
    }
    let simple = PatternComposer.drums(style: .house, complexity: 0, fills: false, seed: 1)
    #expect([0,4,8,12].allSatisfy { simple.contains("kick:" + String($0)) })
    #expect(!simple.contains("tom:14"))
    #expect(PatternComposer.drums(style: .rock, complexity: 101, fills: false, seed: 1).isEmpty)
}

@Test func noteComposerHonorsChordAndScaleAndDensity() throws {
    var bank = ChordBank()
    bank.root = 60
    bank.scale = .naturalMinor
    let notes = try #require(PatternComposer.notes(bank: bank, slot: 0, style: .melody, complexity: 0, seed: 1))
    #expect(notes.count == 16)
    #expect(notes.compactMap { $0 }.count == 4)
    #expect(notes.compactMap { $0 }.allSatisfy { [0,3,7].contains($0 % 12) })
    let dense = try #require(PatternComposer.notes(bank: bank, slot: 0, style: .melody, complexity: 100, seed: 1))
    #expect(dense.compactMap { $0 }.count == 16)
    #expect(dense.compactMap { $0 }.allSatisfy { bank.scale.intervals.contains($0 % 12) })
}

@Test func noteComposerCustomChordArpeggioAndBassStayInRange() throws {
    var bank = ChordBank()
    bank.overrides[0] = .init(name: "Custom", notes: [61,65,68])
    let notes = try #require(PatternComposer.notes(bank: bank, slot: 0, style: .arpeggio, complexity: 100, seed: 9))
    #expect(notes.compactMap { $0 }.allSatisfy { [1,5,8].contains($0 % 12) && (60...83).contains($0) })
    let bass = try #require(PatternComposer.notes(bank: bank, slot: 0, style: .bass, complexity: 100, seed: 9))
    #expect(bass.compactMap { $0 }.allSatisfy { (36...59).contains($0) })
    #expect(PatternComposer.notes(bank: bank, slot: 8, style: .bass, complexity: 50, seed: 1) == nil)
    #expect(PatternComposer.notes(bank: bank, slot: 0, style: .bass, complexity: 50, seed: 0) == nil)
}
