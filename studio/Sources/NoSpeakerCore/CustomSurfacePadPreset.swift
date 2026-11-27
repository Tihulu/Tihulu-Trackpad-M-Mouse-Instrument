import Foundation

/// Explicit starter drafts. A preset is editable geometry and MIDI intent,
/// not an armed device, a synthesizer patch or a DAW instrument selection.
/// Continuous controls have absolute target channels; changing the later
/// melodic channel does not silently rewrite those assignments.
public enum CustomSurfacePadPreset: String, CaseIterable, Sendable {
    case chromatic = "Chromatic notes"
    case drums = "GM drum pads"
    case chords = "Major / minor chords"
    case sustain = "Sustain pedal"
    case pitchBend = "Pitch bend"
    case xy = "Modulation / expression XY"

    public func layout(surface: CustomSurfacePadLayout.Surface, channel: Int) -> CustomSurfacePadLayout? {
        guard (0...15).contains(channel) else { return nil }
        typealias Layout = CustomSurfacePadLayout
        let assignments: [(String, Layout.Assignment)]
        switch self {
        case .chromatic:
            assignments = ["C4","C#4","D4","D#4","E4","F4","F#4","G4","G#4","A4","A#4","B4"].enumerated().map {
                ($0.element, .note(60 + $0.offset))
            }
        case .drums:
            assignments = [("Kick", .drum(36)),("Snare", .drum(38)),("Closed hat", .drum(42)),("Open hat", .drum(46)),
                           ("Low tom", .drum(45)),("High tom", .drum(50)),("Clap", .drum(39)),("Crash", .drum(49))]
        case .chords:
            assignments = [("C", .chord([60,64,67])),("Dm", .chord([62,65,69])),
                           ("Em", .chord([64,67,71])),("F", .chord([65,69,72])),
                           ("G", .chord([67,71,74])),("Am", .chord([69,72,76]))]
        case .sustain: assignments = [("Sustain", .helper(.init(.sustain,channel:channel)))]
        case .pitchBend: assignments = [("Pitch bend", .helper(.init(.pitchBend,channel:channel)))]
        case .xy:
            assignments = [("Mod / expression", .xy(.init(.controlChange,channel:channel,number:1),
                                                      .init(.controlChange,channel:channel,number:11)))]
        }
        let columns = surface == .touchBar ? assignments.count : (assignments.count == 1 ? 1 : (self == .chords ? 3 : 4))
        let rows = (assignments.count + columns - 1) / columns
        let pads = assignments.enumerated().map { index, item in
            let x = index % columns, y = index / columns
            let left = x * 10000 / columns, top = y * 10000 / rows
            return Layout.Pad(id:"preset-"+String(index+1),label:item.0,x:left,y:top,
                width:(x+1)*10000/columns-left,height:(y+1)*10000/rows-top,assignment:item.1)
        }
        return Layout(surface:surface,pads:pads)
    }
}
