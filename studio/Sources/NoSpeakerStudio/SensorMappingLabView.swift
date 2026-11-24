#if os(macOS)
import Foundation
import SwiftUI
import NoSpeakerCore

/// This isolated lab has no CoreMIDI or sensor side effects. It proves the
/// common engine can evaluate mappings before physical adapters are wired in.
struct SensorMappingLabView: View {
    private enum Target: String, CaseIterable, Identifiable {
        case bend = "Pitch Bend"
        case expression = "Expression CC11"
        case filter = "Filter CC74"
        case note = "Note C4"
        case sustain = "Sustain CC64"
        var id: String { rawValue }
        func destination(channel: Int) -> SensorDestination {
            switch self {
            case .bend: .init(.pitchBend, channel: channel)
            case .expression: .init(.controlChange, channel: channel, number: 11)
            case .filter: .init(.controlChange, channel: channel, number: 74)
            case .note: .init(.note, channel: channel, number: 60)
            case .sustain: .init(.sustain, channel: channel)
            }
        }
    }

    @State private var router = SensorRouter()
    @State private var sourceA: SensorSource = .trackpad
    @State private var sourceB: SensorSource = .phone
    @State private var targetA: Target = .note
    @State private var targetB: Target = .note
    @State private var channel = 1
    @State private var invertB = false
    @State private var idA: UUID?
    @State private var idB: UUID?
    @State private var valueA = 0.0
    @State private var valueB = 0.0
    @State private var sequence: UInt64 = 0
    @State private var messages: [String] = []
    @State private var status = "Choose two routes and start the simulation."

    private var running: Bool { router.sessionCount > 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Mapping Lab").font(.largeTitle.bold())
                Text("Build and test two sensor-to-MIDI routes before connecting hardware.")
                    .foregroundStyle(.secondary)
                Label("Simulation only - no MIDI, camera, microphone or network access",
                      systemImage: "info.circle").font(.callout.weight(.semibold))
                GroupBox("Route setup") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Source A").frame(width: 75, alignment: .leading)
                            Picker("Source A", selection: $sourceA) {
                                ForEach(SensorSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.labelsHidden()
                            Image(systemName: "arrow.right")
                            Picker("Target A", selection: $targetA) {
                                ForEach(Target.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden()
                        }
                        HStack {
                            Text("Source B").frame(width: 75, alignment: .leading)
                            Picker("Source B", selection: $sourceB) {
                                ForEach(SensorSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.labelsHidden()
                            Image(systemName: "arrow.right")
                            Picker("Target B", selection: $targetB) {
                                ForEach(Target.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden()
                        }
                        Stepper("MIDI channel \(channel)", value: $channel, in: 1...16)
                        Toggle("Invert Source B", isOn: $invertB)
                        Text("B has priority for shared continuous controls. Notes and sustain remain active until the last owner releases. Sources with the same kind share its mapping rules.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).disabled(running)
                }
                HStack {
                    Button("Start Simulation") { start() }
                        .buttonStyle(.borderedProminent).disabled(running)
                    Button("Release All Simulated Inputs") { stop() }
                        .disabled(!running)
                    Spacer()
                    Text("\(router.sessionCount) simulated sessions").monospacedDigit()
                }
                GroupBox("Simulated inputs") {
                    VStack(spacing: 12) {
                        inputRow("A", value: $valueA, active: idA != nil, disconnect: { disconnect(first: true) })
                        inputRow("B", value: $valueB, active: idB != nil, disconnect: { disconnect(first: false) })
                    }.padding(8)
                }
                .onChange(of: valueA) { value in send(idA, value) }
                .onChange(of: valueB) { value in send(idB, value) }
                Text(status).font(.callout).foregroundStyle(.secondary)
                GroupBox("Generated MIDI commands (not transmitted)") {
                    VStack(alignment: .leading, spacing: 6) {
                        if messages.isEmpty {
                            Text("Move a slider after starting the simulation.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(messages.enumerated()), id: \.offset) { item in
                            Text(item.element).font(.system(.caption, design: .monospaced))
                        }
                        Button("Clear Monitor") { messages.removeAll() }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(24)
        }.onDisappear { stop() }
    }

    private func inputRow(_ label: String, value: Binding<Double>, active: Bool,
                          disconnect: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.headline).frame(width: 24)
            Slider(value: value, in: 0...1)
                .disabled(!active).accessibilityLabel("Simulated source " + label)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 46)
            Button("Disconnect", action: disconnect).disabled(!active)
        }
    }

    private func start() {
        guard !running else { return }
        valueA = 0
        valueB = 0
        sequence = 0
        messages.removeAll()
        do {
            try router.configure([
                .init(id: "A", source: sourceA, signal: .x, destination: targetA.destination(channel: channel - 1)),
                .init(id: "B", source: sourceB, signal: .x, destination: targetB.destination(channel: channel - 1),
                      calibration: .init(inverted: invertB), priority: 10)
            ])
            let time = ProcessInfo.processInfo.systemUptime
            idA = try router.connect(sourceA, now: time)
            idB = try router.connect(sourceB, now: time)
            status = "Simulation running. Move either slider; disconnect a source to test ownership."
            send(idA, valueA)
            send(idB, valueB)
        } catch {
            stop()
            status = "Invalid simulation configuration."
        }
    }

    private func send(_ id: UUID?, _ value: Double) {
        guard let id else { return }
        sequence &+= 1
        let time = ProcessInfo.processInfo.systemUptime
        let commands = router.ingest(.init(session: id, signal: .x, value: value,
                                           sequence: sequence, timestamp: time), now: time)
        record(commands)
    }

    private func disconnect(first: Bool) {
        guard let id = first ? idA : idB else { return }
        record(router.disconnect(id))
        if first { idA = nil } else { idB = nil }
        status = "One simulated source disconnected. Remaining ownership is preserved."
    }

    private func stop() {
        record(router.panic())
        idA = nil
        idB = nil
        status = "Simulation stopped; all simulated controls released."
    }

    private func record(_ commands: [SensorCommand]) {
        for command in commands {
            let target = command.destination
            let action: String
            switch target.kind {
            case .note: action = command.value == 0 ? "Note Off \(target.number)" : "Note On \(target.number) velocity \(command.value)"
            case .controlChange: action = "CC\(target.number) = \(command.value)"
            case .sustain: action = "CC64 = \(command.value)"
            case .pitchBend: action = "Pitch Bend = \(command.value)"
            }
            messages.insert("Ch \(target.channel + 1)  " + action, at: 0)
        }
        if messages.count > 24 { messages = Array(messages.prefix(24)) }
    }
}
#endif
