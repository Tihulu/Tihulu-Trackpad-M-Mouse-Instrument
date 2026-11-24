import Foundation

/// Bounded wire grammar: one flat JSON object, scalar values or arrays of
/// numbers. Decode each member name before checking uniqueness. The scanner
/// deliberately rejects nested objects, duplicate escaped aliases, invalid
/// UTF-8, and trailing content before the typed decoder runs.
enum RemoteFlatJSON {
    // NSRegularExpression instances are immutable and shared across callers.
    private static let patterns: [NSRegularExpression]? = {
        let string = #""(?:[^"\\\x00-\x1F]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*""#
        let number = #"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"#
        let ws = #"[ \t\r\n]*"#
        let array = "\\[" + ws + "(?:" + number + "(?:" + ws + "," + ws + number + ")*)?" + ws + "\\]"
        let value = "(?:" + string + "|" + number + "|true|false|null|" + array + ")"
        return try? [
            ws + "(" + string + ")" + ws + ":" + ws + "(" + value + ")" + ws,
            ws + "\\{" + ws, ws + "\\}" + ws + "\\z", ws + "," + ws
        ].map { try NSRegularExpression(pattern: $0) }
    }()

    private static func unsigned(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.allSatisfy { (48...57).contains($0) } &&
            (token == "0" || !token.hasPrefix("0"))
    }

    static func uniqueKeys(_ data: Data) -> Set<String>? {
        guard data.count <= RemoteTouchFrame.maximumBytes,
              !data.starts(with: [0xef, 0xbb, 0xbf]),
              let text = String(data: data, encoding: .utf8),
              let patterns else { return nil }
        let member = patterns[0], start = patterns[1], end = patterns[2], comma = patterns[3]
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
        var mask: Int?
        var levelTokens: [String]?
        func finish() -> Set<String>? {
            if let tokens = levelTokens {
                guard let mask, (0...63).contains(mask), tokens.count == 6 else { return nil }
                for (i, token) in tokens.enumerated() {
                    let active = mask & (1 << i) != 0
                    if !active && token != "0" { return nil }
                    if active && i >= 3 && token != "1" { return nil }
                }
            }
            return keys
        }
        if take(end) != nil { return finish() }
        while let match = take(member) {
            let keyData = Data(input.substring(with: match.range(at: 1)).utf8)
            guard let key = try? JSONDecoder().decode(String.self, from: keyData),
                  keys.insert(key).inserted else { return nil }
            let token = input.substring(with: match.range(at: 2))
            if ["version", "sequence", "mask"].contains(key) {
                guard unsigned(token) else { return nil }
                if key == "mask" { mask = Int(token) }
            }
            if key == "levels" {
                guard token.hasPrefix("["), token.hasSuffix("]") else { return nil }
                levelTokens = token.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if take(end) != nil { return finish() }
            guard take(comma) != nil else { return nil }
        }
        return nil
    }
}
