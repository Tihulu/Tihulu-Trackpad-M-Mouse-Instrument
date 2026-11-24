import Foundation

public enum PatchGraphError: LocalizedError, Equatable {
    case limit, duplicateID, missingConnection, invalidNode, invalidPatch
    public var errorDescription: String? {
        switch self {
        case .limit: "Patchbay exceeds its node or route limit."
        case .duplicateID: "Duplicate node identifier."
        case .missingConnection: "Connect every processor to an input and every output to a processor."
        case .invalidNode: "Invalid calibration, gate or MIDI destination."
        case .invalidPatch: "The compiled instrument is invalid."
        }
    }
}

/// Typed three-stage graph. Edges are references to the preceding column,
/// so cycles and backwards connections cannot be represented. Fan-out is
/// supported; arbitrary chains and executable nodes are deliberately absent.
/// The canonical saved instrument remains InstrumentPatch.
public struct PatchGraph: Equatable, Sendable {
    public struct Input: Identifiable, Equatable, Sendable {
        public var id: String
        public var source: SensorSource
        public var signal: SensorSignal
        public init(id: String = UUID().uuidString, source: SensorSource = .trackpad,
                    signal: SensorSignal = .contact) {
            self.id = id; self.source = source; self.signal = signal
        }
    }
    public struct Processor: Identifiable, Equatable, Sendable {
        public var id: String
        public var inputID: String?
        public var calibration: SensorCalibration
        public init(id: String = UUID().uuidString, inputID: String? = nil,
                    calibration: SensorCalibration = .init()) {
            self.id = id; self.inputID = inputID; self.calibration = calibration
        }
    }
    public struct Output: Identifiable, Equatable, Sendable {
        public var id: String
        public var processorID: String?
        public var destination: SensorDestination
        public var priority: Int
        public var threshold: Double
        public var hysteresis: Double
        public var velocity: Int
        public var response: ContinuousResponse?
        public init(id: String = UUID().uuidString, processorID: String? = nil,
                    destination: SensorDestination = .init(.note, number: 60),
                    priority: Int = 0, threshold: Double = 0.55,
                    hysteresis: Double = 0.08, velocity: Int = 100, response: ContinuousResponse? = nil) {
            self.id = id; self.processorID = processorID; self.destination = destination
            self.priority = priority; self.threshold = threshold
            self.hysteresis = hysteresis; self.velocity = velocity; self.response = response
        }
    }

    public var inputs: [Input] = []
    public var processors: [Processor] = []
    public var outputs: [Output] = []
    public var performanceLayout: PerformanceLayout?
    public init() {}
    public static let limit = SensorRouter.maxMappings

    /// Reconstruct a graph from the same saved routes, coalescing identical
    /// inputs and calibrations. Route IDs and order are preserved.
    public init(patch: InstrumentPatch) {
        self.init()
        performanceLayout = patch.performanceLayout
        for route in patch.routes {
            let input: Input
            if let existing = inputs.first(where: { $0.source == route.source && $0.signal == route.signal }) {
                input = existing
            } else {
                input = .init(source: route.source, signal: route.signal)
                inputs.append(input)
            }
            let processor: Processor
            if let existing = processors.first(where: { $0.inputID == input.id && $0.calibration == route.calibration }) {
                processor = existing
            } else {
                processor = .init(inputID: input.id, calibration: route.calibration)
                processors.append(processor)
            }
            outputs.append(.init(id: route.id, processorID: processor.id, destination: route.destination,
                                 priority: route.priority, threshold: route.threshold,
                                 hysteresis: route.hysteresis, velocity: route.velocity, response: route.response))
        }
    }

    public func compile(name: String) throws -> InstrumentPatch {
        guard inputs.count <= Self.limit, processors.count <= Self.limit,
              outputs.count <= Self.limit else { throw PatchGraphError.limit }
        // Validate IDs before constructing dictionaries; malformed data cannot trap.
        let ids = inputs.map(\.id) + processors.map(\.id) + outputs.map(\.id)
        guard Set(ids).count == ids.count else { throw PatchGraphError.duplicateID }
        guard ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 &&
            !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } })
        else { throw PatchGraphError.invalidNode }
        let sources = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })
        let transforms = Dictionary(uniqueKeysWithValues: processors.map { ($0.id, $0) })
        for p in processors {
            guard let id = p.inputID, sources[id] != nil else { throw PatchGraphError.missingConnection }
            guard p.calibration.isValid else { throw PatchGraphError.invalidNode }
        }
        let routes = try outputs.map { out -> SensorMapping in
            guard let processorID = out.processorID, let p = transforms[processorID],
                  let inputID = p.inputID, let input = sources[inputID] else { throw PatchGraphError.missingConnection }
            let route = SensorMapping(id: out.id, source: input.source, signal: input.signal,
                                      destination: out.destination, calibration: p.calibration,
                                      priority: out.priority, threshold: out.threshold,
                                      hysteresis: out.hysteresis, velocity: out.velocity, response: out.response)
            guard InstrumentPatch.permits(route) else { throw PatchGraphError.invalidNode }
            return route
        }
        let patch = InstrumentPatch(name: name, routes: routes, performanceLayout: performanceLayout)
        guard patch.isValid else { throw PatchGraphError.invalidPatch }
        return patch
    }

    /// Disconnect rather than silently delete downstream nodes.
    public mutating func removeInput(_ id: String) {
        inputs.removeAll { $0.id == id }
        for i in processors.indices where processors[i].inputID == id { processors[i].inputID = nil }
    }
    public mutating func removeProcessor(_ id: String) {
        processors.removeAll { $0.id == id }
        for i in outputs.indices where outputs[i].processorID == id { outputs[i].processorID = nil }
    }
}
