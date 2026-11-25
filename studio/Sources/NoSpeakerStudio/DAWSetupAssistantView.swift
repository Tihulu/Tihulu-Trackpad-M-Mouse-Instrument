#if os(macOS)
import SwiftUI
import AppKit
import NoSpeakerCore

/// Offline, read-only setup instructions. No MIDI sends, device discovery or DAW automation.
struct DAWSetupAssistantView: View {
    let projection: DAWSetupProjection
    @State private var daw: DAW = .logic
    @State private var language: Language = .en

    private enum Language: String, CaseIterable, Identifiable {
        case en = "EN", tr = "TR", de = "DE"
        var id: String { rawValue }
    }
    private enum DAW: String, CaseIterable, Identifiable {
        case logic = "Logic Pro", garage = "GarageBand", live = "Ableton Live", reaper = "REAPER", other = "Other DAW"
        var id: String { rawValue }
        var link: URL? {
            switch self {
            case .logic: return URL(string:"https://support.apple.com/guide/logicpro/lgcp8a4693ee/mac")
            case .garage: return URL(string:"https://support.apple.com/guide/garageband/welcome/mac")
            case .live: return URL(string:"https://www.ableton.com/en/manual/routing-and-i-o/")
            case .reaper: return URL(string:"https://www.reaper.fm/userguide.php")
            case .other: return nil
            }
        }
    }
    private func t(_ en: String, _ tr: String, _ de: String) -> String {
        switch language { case .en: return en; case .tr: return tr; case .de: return de }
    }
    private var instructions: [String] {
        switch daw {
        case .logic:
            return [
                t("Create a software instrument track for each sound.", "Her ses için Software Instrument kanalı oluştur.", "Für jeden Klang eine Software-Instrument-Spur erstellen."),
                t("In Track Inspector choose MIDI In Port and MIDI In Channel as listed below.", "Track Inspector içinde aşağıdaki MIDI In Port ve MIDI In Channel değerlerini seç.", "Im Spur-Inspector MIDI In Port und MIDI In Channel wie unten auswählen."),
                t("Record-enable the target tracks. For custom effects use Smart Controls or Controller Assignments; avoid duplicate All Inputs routing.", "Hedef kanalları kayda hazırla. Özel efektler için Smart Controls veya Controller Assignments kullan; All Inputs çakışmasından kaçın.", "Zielspuren aufnahmebereit schalten. Für Effekte Smart Controls oder Controller Assignments verwenden; doppelte All-Inputs-Zuordnung vermeiden.")
            ]
        case .garage:
            return [t("Create and select a software instrument track. Use a patch containing only the intended sound first.", "Bir Software Instrument kanalı oluştur ve seç. Önce yalnızca hedef sesi içeren bir patch kullan.", "Software-Instrument-Spur erstellen und auswählen. Zuerst einen Patch mit nur dem gewünschten Klang verwenden."),
                    t("Independent port/channel routing and MPE are not verified here. Record separate parts sequentially if necessary.", "Bağımsız port/kanal yönlendirmesi ve MPE burada doğrulanmadı. Gerekirse parçaları sırayla kaydet.", "Unabhängiges Port-/Kanalrouting und MPE sind hier nicht verifiziert. Parts bei Bedarf nacheinander aufnehmen.")]
        case .live:
            return [t("In MIDI settings enable Track for the TIHULU input.", "MIDI ayarlarında TIHULU girişi için Track seçeneğini aç.", "In den MIDI-Einstellungen Track für den TIHULU-Eingang aktivieren."),
                    t("Set MIDI From to the listed port/channel; arm the track with Auto monitoring or choose In. Enable Remote only for intended MIDI mapping.", "MIDI From için listedeki port/kanalı seç; Auto ile kayda hazırla veya In seç. Remote yalnızca gerekli eşlemelerde açık olsun.", "MIDI From auf Port/Kanal einstellen; Spur mit Auto scharf schalten oder In wählen. Remote nur für gewünschtes Mapping aktivieren.")]
        case .reaper:
            return [t("Enable the TIHULU input in Preferences > MIDI Devices.", "Preferences > MIDI Devices altında TIHULU girişini aç.", "TIHULU-Eingang unter Preferences > MIDI Devices aktivieren."),
                    t("Select the MIDI device/channel in track Input, arm and enable input monitoring.", "Track Input alanında MIDI cihazı/kanalı seç, kaydı ve input monitoring'i aç.", "MIDI-Gerät/Kanal im Spureingang auswählen, Aufnahmebereitschaft und Eingangsmonitoring aktivieren.")]
        case .other:
            return [t("Enable the MIDI input, select the listed port/channel on the instrument track and enable monitoring.", "MIDI girişini aç, enstrümanda listedeki port/kanalı seç ve monitoring'i aç.", "MIDI-Eingang aktivieren, Port/Kanal der Instrumentenspur wählen und Monitoring einschalten.")]
        }
    }
    private var statusText: String {
        switch projection.status {
        case .invalid: return t("Invalid or incomplete output setup. Fix mappings and output choices first.", "Çıkış ayarı eksik veya geçersiz. Önce eşlemeleri düzelt.", "Ausgabe unvollständig oder ungültig. Zuerst Zuordnungen korrigieren.")
        case .disabled: return t("MIDI output is off. No DAW routes are enabled.", "MIDI çıkışı kapalı. Etkin DAW yönlendirmesi yok.", "MIDI-Ausgabe ist aus. Keine DAW-Routen aktiv.")
        case .standard: return t("Configured MIDI routes, not a receiver confirmation.", "Yapılandırılmış MIDI rotaları; alıcı doğrulaması değildir.", "Konfigurierte MIDI-Routen, keine Empfangsbestätigung.")
        case .tunedAir: return t("Dedicated MPE port: receive all zone channels, use an MPE-compatible instrument and verify bend range. Logical patch channels are not wire channels.", "Özel MPE portu: tüm bölge kanallarını al, MPE uyumlu enstrüman seç ve bend aralığını doğrula. Mantıksal kanallar fiziksel MIDI kanalları değildir.", "Separater MPE-Port: alle Zonenkanäle empfangen, MPE-fähiges Instrument verwenden und Bend-Bereich prüfen. Logische Kanäle sind keine tatsächlichen MIDI-Kanäle.")
        }
    }
    private var report: String {
        let rows = projection.channels.map { row in
            "CH " + String(row.number) + " | Notes: " + row.notes.joined(separator:", ") + " | Controls: " + row.controls.joined(separator:", ")
        }
        return ([daw.rawValue, statusText, projection.port ?? "—"] + rows + instructions).joined(separator:"\n")
    }
    var body: some View {
        DisclosureGroup("DAW Setup Assistant") {
            VStack(alignment:.leading, spacing:8) {
                HStack {
                    Picker("DAW", selection:$daw) {
                        ForEach(DAW.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Language", selection:$language) {
                        ForEach(Language.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(maxWidth:130)
                }
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if let port = projection.port {
                    Text("MIDI Input: " + port).font(.headline).textSelection(.enabled)
                    ForEach(projection.channels) { row in
                        VStack(alignment:.leading, spacing:3) {
                            Text("MIDI Channel " + String(row.number)).font(.headline)
                            Text("Notes: " + (row.notes.isEmpty ? "—" : row.notes.joined(separator:", "))).font(.caption)
                            ForEach(row.controls, id:\.self) { Text($0).font(.caption).textSelection(.enabled) }
                            if row.notes.count > 1 {
                                Text(t("Shared note channel: these sources intentionally target the same track.", "Ortak nota kanalı: bu kaynaklar aynı hedefe gider.", "Gemeinsamer Notenkanal: diese Quellen nutzen dieselbe Zielspur.")).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    ForEach(Array(instructions.enumerated()), id:\.offset) { item in
                        Text(String(item.offset+1) + ". " + item.element).font(.caption)
                    }
                    Text(t("Manually test one note, pedal and effect at a time. Hearing sound and correct isolation require confirmation in the DAW.", "Nota, pedal ve efektleri tek tek dene. Ses ve kanal izolasyonunu DAW içinde doğrula.", "Note, Pedal und Effekt einzeln testen. Klang und Trennung in der DAW bestätigen.")).font(.caption).foregroundStyle(.secondary)
                    Button(t("Copy setup", "Kurulumu kopyala", "Setup kopieren")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType:.string)
                    }
                }
                if let link = daw.link { Link(t("Official guide", "Resmi kılavuz", "Offizielle Anleitung"), destination:link) }
            }.padding(6)
        }
    }
}
#endif
