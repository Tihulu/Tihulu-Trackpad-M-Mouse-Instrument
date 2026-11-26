#if os(macOS)
import SwiftUI
import NoSpeakerCore

/// Read-only reference library, intentionally separate from the active
/// chord/touch/MPE routing configuration. No automatic apply.
struct WorldTuningLibraryPanel: View {
    @State private var expanded=false
    @State private var region:WorldTuningPreset.Region = .turkish
    @State private var query=""
    @State private var selection:String?
    private var results:[WorldTuningPreset] {
        WorldTuningLibrary.presets.filter{
            $0.region==region && (query.isEmpty || $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query))
        }
    }
    var body:some View {
        DisclosureGroup("World tuning library · reference",isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:8) {
                Text("Browse and inspect only · no active tuning or MIDI changes").font(.caption).foregroundStyle(.secondary)
                Picker("Tradition / system",selection:$region) {
                    ForEach(WorldTuningPreset.Region.allCases,id:\.self){Text($0.rawValue).tag($0)}
                }
                TextField("Search in this collection",text:$query)
                if results.isEmpty {Text("No matching references.").foregroundStyle(.secondary)}
                else {
                    Picker("Reference",selection:$selection) {
                        Text("Choose a reference").tag(String?.none)
                        ForEach(results){Text($0.name).tag(Optional($0.id))}
                    }
                }
                if let selection,let preset=results.first(where:{$0.id==selection}) {
                    Text(preset.name).font(.headline)
                    Text(preset.kind.rawValue + (preset.octavePeriodic ? " · octave-periodic model":" · finite reference, cannot repeat")).font(.caption)
                    Text(preset.cents.map{String(format:"%.2f¢",$0)}.joined(separator:" · ")).font(.caption.monospacedDigit()).textSelection(.enabled)
                    Text(preset.note).font(.caption).foregroundStyle(.secondary)
                    Text(preset.source).font(.caption2).textSelection(.enabled)
                }
            }.padding(.vertical,4)
        }
        .onChange(of:region){_ in selection=nil;query=""}
        .onChange(of:query){_ in selection=nil}
    }
}
#endif
