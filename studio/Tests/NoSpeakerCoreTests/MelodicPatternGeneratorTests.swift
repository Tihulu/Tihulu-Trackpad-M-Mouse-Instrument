import Foundation
import Testing
@testable import NoSpeakerCore

private typealias Generator = MelodicPatternGenerator

@Test(arguments: Generator.Genre.allCases, Generator.Role.allCases)
func melodicGeneratorRespectsKeyRegisterAndClipBounds(genre: MelodicPatternGenerator.Genre, role: MelodicPatternGenerator.Role) throws {
    for scale in Generator.Scale.allCases {
        for root in 0..<12 {
            var c = Generator.Configuration()
            c.genre = genre; c.role = role; c.scale = scale; c.root = root
            c.low = role == .bass ? 28 : 60
            c.high = role == .bass ? 59 : 96
            c.seed = UInt64(root + 1); c.bars = 2
            c.density = (root * 9) % 101; c.complexity = (root * 17) % 101
            let result = try Generator.generate(c)
            #expect(result == (try Generator.generate(c)))
            #expect(result.length == 32 && result.stepsPerBeat == 4)
            #expect(result.steps.count == 2 * (1 + c.density * 15 / 100))
            #expect(Set(result.steps.map(\.index)).count == result.steps.count)
            #expect(Set(result.steps.map(\.id)).count == result.steps.count)
            for step in result.steps {
                let pitch = try #require(step.midi)
                #expect((c.low...c.high).contains(pitch))
                #expect(scale.intervals.contains((pitch % 12 - root + 12) % 12))
                #expect((0..<result.length).contains(step.index))
                #expect(step.gate == c.gate && step.velocity > 0 && step.velocity <= 1)
            }
            let clip = try MIDIClip.melody(result, channel: 15)
            #expect(clip.notes.count == result.steps.count && clip.length == 7680)
            #expect(clip.notes.allSatisfy { $0.channel == 15 })
        }
    }
}

@Test func melodicGeneratorSeedStyleAndRepetitionAreMeaningful() throws {
    var c = Generator.Configuration()
    c.bars = 4; c.variation = 0; c.complexity = 75; c.density = 50
    let repeating = try Generator.generate(c)
    let first = repeating.steps.filter { $0.index < 16 }
    for bar in 1..<4 {
        let other = repeating.steps.filter { $0.index / 16 == bar }
        #expect(first.map(\.midi) == other.map(\.midi))
        #expect(first.map(\.index) == other.map { $0.index % 16 })
    }
    c.variation = 100
    let before = try Generator.generate(c)
    c.seed = 2
    let after = try Generator.generate(c)
    #expect(before.steps.map(\.midi) != after.steps.map(\.midi) || before.steps.map(\.index) != after.steps.map(\.index))
    c.complexity = 0; c.syncopation = 50; c.density = 40; c.bars = 1
    var rhythms = Set<[Int]>()
    for genre in Generator.Genre.allCases {
        c.genre = genre
        rhythms.insert(try Generator.generate(c).steps.map(\.index))
    }
    #expect(rhythms.count >= 6)
    c.role = .solo; c.root = 9; c.low = 60; c.high = 84
    c.complexity = 100; c.density = 100; c.bars = 16; c.seed = UInt64.max
    let full = try Generator.generate(c)
    #expect(full.steps.count == 256)
    #expect(full.steps.last?.midi.map { $0 % 12 } == c.root)
    let decoded = try JSONDecoder().decode(Generator.Configuration.self, from: JSONEncoder().encode(c))
    #expect(decoded == c)
    #expect(try Generator.generate(decoded) == full)
}

@Test func melodicGeneratorRejectsInvalidParametersWithoutFallback() throws {
    let valid = Generator.Configuration()
    let changes: [(inout Generator.Configuration) -> Void] = [
        { $0.root = Int.min }, { $0.root = 12 }, { $0.bpm = .nan }, { $0.bpm = .infinity },
        { $0.bpm = 19 }, { $0.bpm = 301 }, { $0.bars = 0 }, { $0.bars = Int.max },
        { $0.low = -1 }, { $0.high = 128 }, { $0.low = 61; $0.high = 60 },
        { $0.complexity = -1 }, { $0.density = 101 }, { $0.syncopation = Int.max }, { $0.variation = -1 },
        { $0.gate = .nan }, { $0.gate = 0 }, { $0.gate = 1.01 }, { $0.velocity = .infinity }, { $0.velocity = 0 }
    ]
    for change in changes {
        var c = valid; change(&c)
        #expect(throws: Generator.ValidationError.invalidConfiguration) { try Generator.generate(c) }
    }
    var c = valid; c.root = 0; c.scale = .major; c.low = 61; c.high = 61
    #expect(throws: Generator.ValidationError.emptyRegister) { try Generator.generate(c) }
    c.low = 60; c.high = 60; c.density = 0; c.bars = 1; c.seed = 0
    let minimum = try Generator.generate(c)
    #expect(minimum.steps.count == 1 && minimum.steps.first?.midi == 60)
}
