#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct TouchBarSavedProfilesPanel:View {
    @EnvironmentObject private var studio:StudioController
    @AppStorage("TIHULU.touchBarNamedProfiles") private var storage=Data()
    @State private var name=""
    @State private var selected=""
    @State private var feedback=""
    @State private var action:Pending?
    private enum Pending:String,Identifiable {case replace,delete;var id:String{rawValue}}
    private var library:TouchBarProfileLibrary? {
        storage.isEmpty ? .init() : try? JSONDecoder().decode(TouchBarProfileLibrary.self,from:storage)
    }
    var body:some View {
        GroupBox("Saved Touch Bar profiles") {
            VStack(alignment:.leading,spacing:8) {
                if let library {
                    Text("Save the current zones and settings, then explicitly load a snapshot. Loading releases the old Touch Bar session; it does not arm output.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("New profile name",text:$name)
                        Button("Save new") {
                            var next=library
                            let result=next.save(name:name,profile:studio.touchBarProfile)
                            if result == .saved {
                                persist(next)
                                selected=next.entries.last?.id ?? ""
                                name=""
                            } else {feedback="Cannot save: duplicate, invalid name or library full."}
                        }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                    Picker("Saved profile",selection:$selected){
                        Text("Choose profile").tag("")
                        ForEach(library.entries){entry in Text(entry.name).tag(entry.id)}
                    }
                    if let entry=library.entries.first(where:{$0.id==selected}) {
                        Text(entry.profile.zones.map(\.rawValue).joined(separator:" · ")).font(.caption)
                        HStack {
                            Button("Load") {
                                studio.setTouchBarProfile(entry.profile)
                                feedback=studio.touchBarProfile==entry.profile ? "Profile loaded.":"Profile not applied; check session or release status."
                            }
                            Button("Update from current"){action = .replace}
                            Button("Delete",role:.destructive){action = .delete}
                        }
                    }
                    Text("\(library.entries.count) / \(TouchBarProfileLibrary.capacity) saved").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Saved profiles could not be read. Existing data is preserved.").foregroundStyle(.orange)
                }
                if !feedback.isEmpty {Text(feedback).font(.caption)}
            }.padding(6)
        }
        .confirmationDialog(action == .replace ? "Replace saved profile?" : "Delete saved profile?",isPresented:Binding(get:{action != nil},set:{if !$0 {action=nil}}),titleVisibility:.visible,presenting:action){pending in
            Button(pending == .replace ? "Replace":"Delete",role:pending == .delete ? .destructive:nil){
                guard var next=library else{return}
                if pending == .replace {
                    if next.replace(id:selected,profile:studio.touchBarProfile) == .saved {persist(next)}
                } else if next.remove(id:selected) {persist(next);selected=""}
                action=nil
            }
        }
    }
    private func persist(_ library:TouchBarProfileLibrary){
        guard let data=try? JSONEncoder().encode(library) else{feedback="Could not encode profiles.";return}
        storage=data;feedback="Saved profiles updated."
    }
}
#endif
