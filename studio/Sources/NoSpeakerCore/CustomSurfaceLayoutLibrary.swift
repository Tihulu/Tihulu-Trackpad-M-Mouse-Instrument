import Foundation

/// One explicitly saved offline layout per surface type. No activation state.
/// A malformed record must not silently replace a previously saved library.
public struct CustomSurfaceLayoutLibrary: Codable, Equatable, Sendable {
    public private(set) var layouts:[CustomSurfacePadLayout]=[]
    public init(){}
    public func layout(for surface:CustomSurfacePadLayout.Surface)->CustomSurfacePadLayout? {
        layouts.first{$0.surface==surface}
    }
    public mutating func save(_ layout:CustomSurfacePadLayout){
        if let index=layouts.firstIndex(where:{$0.surface==layout.surface}) {
            layouts[index]=layout
        } else {layouts.append(layout)}
    }
    private enum CodingKeys:String,CodingKey {case layouts}
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
    }
}
