import Foundation

/// Named snapshots of the existing profile, not live session state.
public struct TouchBarProfileLibrary: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let name:String
        public let profile:TouchBarProfile
        public var id:String {name.lowercased()}
    }
    public enum SaveResult:Equatable,Sendable {case saved,invalidName,duplicate,full,missing}
    public static let capacity=32
    public private(set) var entries:[Entry]=[]
    public init(){}
    private static func validatedName(_ name:String)->String? {
        let value=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.utf8.count<=64,
              !value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{return nil}
        return value
    }
    @discardableResult public mutating func save(name:String,profile:TouchBarProfile)->SaveResult {
        guard let name=Self.validatedName(name) else{return .invalidName}
        guard !entries.contains(where:{$0.id==name.lowercased()}) else{return .duplicate}
        guard entries.count<Self.capacity else{return .full}
        entries.append(.init(name:name,profile:profile.normalized()))
        return .saved
    }
    @discardableResult public mutating func replace(id:String,profile:TouchBarProfile)->SaveResult {
        guard let index=entries.firstIndex(where:{$0.id==id}) else{return .missing}
        entries[index] = .init(name:entries[index].name,profile:profile.normalized())
        return .saved
    }
    @discardableResult public mutating func remove(id:String)->Bool {
        guard let index=entries.firstIndex(where:{$0.id==id}) else{return false}
        entries.remove(at:index)
        return true
    }
    private enum CodingKeys:String,CodingKey {case entries}
    public init(from decoder:Decoder)throws {
        let container=try decoder.container(keyedBy:CodingKeys.self)
        var values=try container.nestedUnkeyedContainer(forKey:.entries)
        guard values.count.map({$0<=Self.capacity}) ?? true else {
            throw DecodingError.dataCorruptedError(forKey:.entries,in:container,debugDescription:"Too many profiles")
        }
        while !values.isAtEnd {
            let entry=try values.decode(Entry.self)
            guard Self.validatedName(entry.name)==entry.name,save(name:entry.name,profile:entry.profile) == .saved else {
                throw DecodingError.dataCorruptedError(forKey:.entries,in:container,debugDescription:"Invalid or duplicate profile")
            }
        }
    }
}
