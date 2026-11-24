import Foundation

/// Fixed assets only. No file access, query parameters, uploads or redirects.
/// This parser handles one bounded HTTP/1.1 GET request per TLS connection.
public enum RemotePageRequest: Equatable, Sendable {
    case incomplete, page, script, rejected
    public static let maximumBytes = 8192
    public static func parse(_ bytes: Data, authority: String) -> Self {
        guard bytes.count <= maximumBytes else { return .rejected }
        guard let end = bytes.range(of: Data([13,10,13,10])) else {
            return bytes.count == maximumBytes ? .rejected : .incomplete
        }
        guard end.upperBound == bytes.endIndex,
              let header = String(data: bytes[..<end.lowerBound], encoding: .ascii)
        else { return .rejected }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first, lines.count <= 40 else { return .rejected }
        let asset: Self
        switch first {
        case "GET / HTTP/1.1": asset = .page
        case "GET /control.js HTTP/1.1": asset = .script
        default: return .rejected
        }
        var hosts: [String] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line.contains(where: { $0.isNewline || ($0.isWhitespace && $0 != " " && $0 != "\t") })
            else { return .rejected }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return .rejected }
            if name == "host" { hosts.append(value) }
            if ["content-length","transfer-encoding","upgrade","expect"].contains(name) { return .rejected }
        }
        return hosts == [authority] ? asset : .rejected
    }
}
