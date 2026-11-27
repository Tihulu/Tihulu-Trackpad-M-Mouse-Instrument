import Foundation

/// One explicitly saved offline layout per surface type. No activation state.
/// A malformed record must not silently replace a previously saved library.
public struct CustomSurfaceLayoutLibrary: Codable, Equatable, Sendable {
    public private(set) var layouts:[CustomSurfacePadLayout]=[]
    private struct ChannelRecord: Codable, Equatable, Sendable {
        let surface: CustomSurfacePadLayout.Surface
        let channel: Int
    }
    private var channels: [ChannelRecord] = []
    public init(){}
    public func layout(for surface:CustomSurfacePadLayout.Surface)->CustomSurfacePadLayout? {
        layouts.first{$0.surface==surface}
    }
    public mutating func save(_ layout:CustomSurfacePadLayout){
        if let index=layouts.firstIndex(where:{$0.surface==layout.surface}) {
            layouts[index]=layout
        } else {layouts.append(layout)}
    }
    public func melodicChannel(for surface: CustomSurfacePadLayout.Surface) -> Int? {
        channels.first { $0.surface == surface }?.channel
    }
    /// Persist a draft and its melodic channel as one explicit operation.
    /// A channel change never remaps absolute helper/drum destinations.
    @discardableResult
    public mutating func save(_ layout: CustomSurfacePadLayout, melodicChannel: Int) -> Bool {
        guard (0...15).contains(melodicChannel) else { return false }
        save(layout)
        channels.removeAll { $0.surface == layout.surface }
        channels.append(.init(surface:layout.surface,channel:melodicChannel))
        return true
    }
    /// Complete offline pair, not a live route. Explicit legacy defaults
    /// are returned without mutating the underlying stored library.
    public struct NativePair: Equatable, Sendable {
        public let trackpad: CustomSurfacePadLayout
        public let mouse: CustomSurfacePadLayout
        public let trackpadChannel: Int
        public let mouseChannel: Int
        public init?(trackpad: CustomSurfacePadLayout, mouse: CustomSurfacePadLayout,
                     trackpadChannel: Int, mouseChannel: Int) {
            guard trackpad.surface == .trackpad, mouse.surface == .magicMouse,
                  (0...15).contains(trackpadChannel), (0...15).contains(mouseChannel) else { return nil }
            self.trackpad=trackpad;self.mouse=mouse
            self.trackpadChannel=trackpadChannel;self.mouseChannel=mouseChannel
        }
    }
    public var nativePair: NativePair? {
        guard let trackpad=layout(for:.trackpad), let mouse=layout(for:.magicMouse) else { return nil }
        return .init(trackpad:trackpad,mouse:mouse,trackpadChannel:melodicChannel(for:.trackpad) ?? 0,
                     mouseChannel:melodicChannel(for:.magicMouse) ?? 1)
    }
    public mutating func saveNativePair(_ pair: NativePair) {
        // The pair's initializer already validated both channels/surfaces.
        // Publish the entire update together, preserving unrelated surfaces.
        var next=self
        next.save(pair.trackpad,melodicChannel:pair.trackpadChannel)
        next.save(pair.mouse,melodicChannel:pair.mouseChannel)
        self=next
    }
    private enum CodingKeys:String,CodingKey {case layouts,channels}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        var list=try c.nestedUnkeyedContainer(forKey:.layouts)
        while !list.isAtEnd {
            guard layouts.count<CustomSurfacePadLayout.Surface.allCases.count else{
                throw DecodingError.dataCorruptedError(forKey:.layouts,in:c,debugDescription:"Too many surface layouts")
            }
            let layout=try list.decode(CustomSurfacePadLayout.self)
            guard self.layout(for:layout.surface)==nil else{
                throw DecodingError.dataCorruptedError(forKey:.layouts,in:c,debugDescription:"Duplicate surface layout")
            }
            save(layout)
        }
        // Old v1 libraries have no channels field. Preserve their layouts;
        // the caller supplies a visible default until explicitly saved.
        if c.contains(.channels) {
            var records = try c.nestedUnkeyedContainer(forKey: .channels)
            while !records.isAtEnd {
                guard channels.count < CustomSurfacePadLayout.Surface.allCases.count else {
                    throw DecodingError.dataCorruptedError(forKey:.channels,in:c,debugDescription:"Too many channel records")
                }
                let record = try records.decode(ChannelRecord.self)
                guard layout(for:record.surface) != nil, melodicChannel(for:record.surface) == nil,
                      (0...15).contains(record.channel) else {
                    throw DecodingError.dataCorruptedError(forKey:.channels,in:c,debugDescription:"Invalid, orphan or duplicate channel record")
                }
                channels.append(record)
            }
        }
    }
}
