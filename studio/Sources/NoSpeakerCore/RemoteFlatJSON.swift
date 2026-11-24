import Foundation

/// Bounded wire grammar: one flat JSON object, scalar values or arrays of
/// numbers. Decode each member name before checking uniqueness. The scanner
/// deliberately rejects nested objects, duplicate escaped aliases, invalid
/// UTF-8, and trailing content before the typed decoder runs.
enum RemoteFlatJSON {
    static func uniqueKeys(_ data: Data) -> Set<String>? {
        guard data.count <= RemoteTouchFrame.maximumBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let string = #""(?:[^"\\\x00-\x1F]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*""#
        let number = #"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"#
        let ws = #"[ \t\r\n]*"#
        let array = "\\[" + ws + "(?:" + number + "(?:" + ws + "," + ws + number + ")*)?" + ws + "\\]"
        let value = "(?:" + string + "|" + number + "|true|false|null|" + array + ")"
        guard let member = try? NSRegularExpression(pattern: ws + "(" + string + ")" + ws + ":" + ws + value + ws),
              let start = try? NSRegularExpression(pattern: ws + "\\{" + ws),
              let end = try? NSRegularExpression(pattern: ws + "\\}" + ws + "\\z"),
              let comma = try? NSRegularExpression(pattern: ws + "," + ws) else { return nil }
        let input = text as NSString
        var offset = 0
        func take(_ regex: NSRegularExpression) -> NSTextCheckingResult? {
            guard let m = regex.firstMatch(in: text, options: [.anchored],
                                          range: NSRange(location: offset, length: input.length - offset)) else { return nil }
            offset = NSMaxRange(m.range)
            return m
        }
        guard take(start) != nil else { return nil }
        var keys: Set<String> = []
        if take(end) != nil { return keys }
        while let match = take(member) {
            let keyData = Data(input.substring(with: match.range(at: 1)).utf8)
            guard let key = try? JSONDecoder().decode(String.self, from: keyData),
                  keys.insert(key).inserted else { return nil }
            if take(end) != nil { return keys }
            guard take(comma) != nil else { return nil }
        }
        return nil
    }
}
