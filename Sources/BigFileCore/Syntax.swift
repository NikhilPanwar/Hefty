import Foundation

public enum Language: String, Sendable, CaseIterable {
    case plain, sql, json, csv, tsv, xml, log

    public var displayName: String {
        switch self {
        case .plain: return "Plain Text"
        case .sql: return "SQL"
        case .json: return "JSON"
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .xml: return "XML / HTML"
        case .log: return "Log"
        }
    }

    public init(fileExtension ext: String) {
        switch ext.lowercased() {
        case "sql", "dump", "ddl", "psql", "mysql": self = .sql
        case "json", "ndjson", "jsonl", "geojson", "har", "ipynb": self = .json
        case "csv": self = .csv
        case "tsv", "tab": self = .tsv
        case "xml", "html", "htm", "xhtml", "svg", "plist", "xsd", "xsl", "xslt", "rss", "atom", "kml", "gpx": self = .xml
        case "log", "out", "err", "trace": self = .log
        default: self = .plain
        }
    }

    /// Line-comment prefix for Toggle Comment.
    public var lineComment: String? {
        switch self {
        case .sql: return "-- "
        case .plain, .log: return "# "
        case .json, .csv, .tsv, .xml: return nil
        }
    }
    /// Block comment delimiters for Toggle Comment when there's no line form.
    public var blockComment: (String, String)? {
        switch self {
        case .xml: return ("<!-- ", " -->")
        case .sql: return ("/* ", " */")
        default: return nil
        }
    }

    /// Whether lexer state can carry over from one line to the next.
    public var hasMultilineState: Bool { self == .sql || self == .csv || self == .tsv || self == .xml }
}

public enum TokenKind: Sendable, Equatable {
    case plain, keyword, string, number, comment, punctuation, key, tag, attribute
    case logError, logWarning, logInfo, logDebug, timestamp
    case column(Int)   // CSV/TSV column, colored by index
}

public struct Token: Sendable, Equatable {
    public var range: Range<Int>   // byte range within the line
    public var kind: TokenKind
}

/// Lexer state carried from the end of one line to the start of the next, so
/// multi-line comments, strings and quoted CSV fields color correctly.
public enum LexState: Hashable, Sendable {
    case normal
    case blockComment
    case string(UInt8)
    case dollar([UInt8])
    case csvQuoted(column: Int)
    case xmlComment
    case xmlCData
    case xmlTag
}

/// Per-line, byte-level tokenizers. Only visible lines are ever tokenized, so
/// highlighting cost is O(viewport), independent of file size. Tokens only
/// start/end on ASCII bytes, so UTF-8 sequences are never split.
public enum Highlighter {
    public static func tokens(for line: [UInt8], language: Language) -> [Token] {
        var s = LexState.normal
        return tokens(for: line, language: language, state: &s)
    }

    public static func tokens(for line: [UInt8], language: Language, state: inout LexState) -> [Token] {
        switch language {
        case .sql: return sql(line, &state)
        case .json: state = .normal; return json(line)
        case .csv: return delimited(line, separator: UInt8(ascii: ","), &state)
        case .tsv: return delimited(line, separator: 0x09, &state)
        case .xml: return xml(line, &state)
        case .log: state = .normal; return log(line)
        case .plain: state = .normal; return []
        }
    }

    /// Lexer state at the start of the line beginning at `lineStart`, found by
    /// lexing forward from a point up to `lookBehind` bytes earlier.
    public static func state(atLineStart lineStart: Int, in doc: TextDocument, language: Language,
                             lookBehind: Int = 256 << 10) -> LexState {
        guard language.hasMultilineState, lineStart > 0 else { return .normal }
        var pos = doc.lastNewline(in: max(0, lineStart - lookBehind)..<lineStart - 1).map { $0 + 1 }
            ?? max(0, lineStart - lookBehind)
        if pos > 0 && pos == lineStart - lookBehind {
            pos = doc.firstNewline(in: pos..<lineStart).map { $0 + 1 } ?? lineStart
        }
        var state = LexState.normal
        while pos < lineStart {
            let (bytes, next) = doc.line(at: pos)
            _ = tokens(for: bytes, language: language, state: &state)
            if next <= pos { break }
            pos = next
        }
        return state
    }

    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
        "create", "table", "drop", "alter", "add", "index", "primary", "key", "foreign",
        "references", "not", "null", "default", "unique", "and", "or", "in", "is", "like", "ilike",
        "join", "left", "right", "inner", "outer", "full", "cross", "on", "as", "group", "by", "order",
        "having", "limit", "offset", "distinct", "union", "all", "exists", "case", "when",
        "then", "else", "end", "begin", "commit", "rollback", "transaction", "lock",
        "unlock", "tables", "write", "read", "if", "engine", "charset", "collate",
        "auto_increment", "constraint", "database", "schema", "use", "view", "procedure", "function",
        "trigger", "returns", "return", "declare", "int", "integer", "bigint", "smallint",
        "tinyint", "varchar", "char", "text", "longtext", "mediumtext", "blob", "longblob",
        "date", "datetime", "timestamp", "decimal", "numeric", "float", "double", "boolean", "bool",
        "true", "false", "unsigned", "copy", "with", "cascade", "grant", "revoke", "replace",
        "between", "asc", "desc", "sequence", "serial", "owner", "to", "language", "returning",
        "conflict", "do", "nothing", "using", "temporary", "temp", "comment", "column", "check",
        "real", "json", "jsonb", "uuid", "interval", "time", "zone", "varying", "character", "extension",
    ]

    @inline(__always) static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    @inline(__always) static func isHex(_ b: UInt8) -> Bool {
        isDigit(b) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46)
    }
    @inline(__always) static func isIdent(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || isDigit(b) || b == 0x5F || b >= 0x80
    }

    /// End of a number starting at `i` (handles 0x1F, 1.5e-10).
    static func endOfNumber(_ s: [UInt8], _ i: Int) -> Int {
        let n = s.count
        var j = i
        if s[j] == 0x30, j + 1 < n, s[j + 1] | 0x20 == 0x78 {
            j += 2
            while j < n, isHex(s[j]) { j += 1 }
            return j
        }
        while j < n, isDigit(s[j]) || s[j] == UInt8(ascii: ".") { j += 1 }
        if j < n, s[j] | 0x20 == 0x65 {
            var k = j + 1
            if k < n, s[k] == UInt8(ascii: "+") || s[k] == UInt8(ascii: "-") { k += 1 }
            if k < n, isDigit(s[k]) {
                while k < n, isDigit(s[k]) { k += 1 }
                j = k
            }
        }
        return j
    }

    /// Index just past the closing quote (backslash escapes and doubled quotes
    /// both handled), or nil if the line ends first.
    static func closeQuote(_ s: [UInt8], from j0: Int, quote: UInt8, backslash: Bool = true) -> Int? {
        var j = j0
        while j < s.count {
            if backslash && s[j] == 0x5C { j += 2; continue }
            if s[j] == quote {
                if j + 1 < s.count, s[j + 1] == quote { j += 2; continue }
                return j + 1
            }
            j += 1
        }
        return nil
    }

    static func endOfQuoted(_ s: [UInt8], from i: Int, quote: UInt8) -> Int {
        closeQuote(s, from: i + 1, quote: quote) ?? s.count
    }

    static func find(_ needle: [UInt8], in s: [UInt8], from: Int) -> Int? {
        guard needle.count <= s.count else { return nil }
        var i = from
        while i + needle.count <= s.count {
            if s[i] == needle[0] {
                var k = 1
                while k < needle.count && s[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    static func sql(_ s: [UInt8], _ state: inout LexState) -> [Token] {
        var out: [Token] = []
        let n = s.count
        var i = 0
        // Continue whatever the previous line left open.
        switch state {
        case .blockComment:
            if let e = find([0x2A, 0x2F], in: s, from: 0) {
                out.append(Token(range: 0..<e + 2, kind: .comment)); i = e + 2; state = .normal
            } else { return n > 0 ? [Token(range: 0..<n, kind: .comment)] : [] }
        case .string(let q):
            if let e = closeQuote(s, from: 0, quote: q) {
                out.append(Token(range: 0..<e, kind: q == UInt8(ascii: "`") ? .key : .string)); i = e; state = .normal
            } else { return n > 0 ? [Token(range: 0..<n, kind: .string)] : [] }
        case .dollar(let tag):
            if let e = find(tag, in: s, from: 0) {
                out.append(Token(range: 0..<e + tag.count, kind: .string)); i = e + tag.count; state = .normal
            } else { return n > 0 ? [Token(range: 0..<n, kind: .string)] : [] }
        default:
            state = .normal
        }
        var onlySpaceBefore = i == 0
        while i < n {
            let b = s[i]
            if b == 0x20 || b == 0x09 { i += 1; continue }
            defer { onlySpaceBefore = false }
            if b == UInt8(ascii: "-"), i + 1 < n, s[i + 1] == UInt8(ascii: "-") {
                out.append(Token(range: i..<n, kind: .comment)); break
            } else if b == UInt8(ascii: "#") && onlySpaceBefore {
                out.append(Token(range: i..<n, kind: .comment)); break
            } else if b == UInt8(ascii: "/"), i + 1 < n, s[i + 1] == UInt8(ascii: "*") {
                if let e = find([0x2A, 0x2F], in: s, from: i + 2) {
                    out.append(Token(range: i..<e + 2, kind: .comment)); i = e + 2
                } else {
                    out.append(Token(range: i..<n, kind: .comment)); state = .blockComment; break
                }
            } else if b == UInt8(ascii: "'") || b == UInt8(ascii: "\"") || b == UInt8(ascii: "`") {
                let kind: TokenKind = b == UInt8(ascii: "`") || b == UInt8(ascii: "\"") ? .key : .string
                if let e = closeQuote(s, from: i + 1, quote: b) {
                    out.append(Token(range: i..<e, kind: kind)); i = e
                } else {
                    out.append(Token(range: i..<n, kind: kind)); state = .string(b); break
                }
            } else if b == UInt8(ascii: "$"), i + 1 < n, !isDigit(s[i + 1]) {
                // Postgres dollar quoting: $$...$$ or $tag$...$tag$
                var j = i + 1
                while j < n, isIdent(s[j]) && s[j] < 0x80 { j += 1 }
                if j < n, s[j] == UInt8(ascii: "$") {
                    let tag = Array(s[i...j])
                    if let e = find(tag, in: s, from: j + 1) {
                        out.append(Token(range: i..<e + tag.count, kind: .string)); i = e + tag.count
                    } else {
                        out.append(Token(range: i..<n, kind: .string)); state = .dollar(tag); break
                    }
                } else { i += 1 }
            } else if isDigit(b) {
                let j = endOfNumber(s, i)
                out.append(Token(range: i..<j, kind: .number)); i = j
            } else if isIdent(b) {
                var j = i
                while j < n, isIdent(s[j]) { j += 1 }
                if j - i <= 16, sqlKeywords.contains(String(decoding: s[i..<j], as: UTF8.self).lowercased()) {
                    out.append(Token(range: i..<j, kind: .keyword))
                }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    static func json(_ s: [UInt8]) -> [Token] {
        var out: [Token] = []
        var i = 0
        let n = s.count
        while i < n {
            let b = s[i]
            if b == UInt8(ascii: "\"") {
                var j = i + 1
                while j < n, s[j] != UInt8(ascii: "\"") { j += s[j] == 0x5C ? 2 : 1 }
                j = min(n, j + 1)
                var k = j
                while k < n, s[k] == 0x20 || s[k] == 0x09 { k += 1 }
                out.append(Token(range: i..<j, kind: k < n && s[k] == UInt8(ascii: ":") ? .key : .string))
                i = j
            } else if isDigit(b) || (b == UInt8(ascii: "-") && i + 1 < n && isDigit(s[i + 1])) {
                let j = endOfNumber(s, b == UInt8(ascii: "-") ? i + 1 : i)
                out.append(Token(range: i..<j, kind: .number)); i = j
            } else if b == UInt8(ascii: "t") || b == UInt8(ascii: "f") || b == UInt8(ascii: "n") {
                var j = i
                while j < n, isIdent(s[j]) { j += 1 }
                let w = String(decoding: s[i..<j], as: UTF8.self)
                if w == "true" || w == "false" || w == "null" { out.append(Token(range: i..<j, kind: .keyword)) }
                i = max(j, i + 1)
            } else if b == UInt8(ascii: "{") || b == UInt8(ascii: "}") || b == UInt8(ascii: "[")
                        || b == UInt8(ascii: "]") || b == UInt8(ascii: ":") || b == UInt8(ascii: ",") {
                out.append(Token(range: i..<i + 1, kind: .punctuation)); i += 1
            } else {
                i += 1
            }
        }
        return out
    }

    /// Colors each column differently (EmEditor-style), honoring quoted fields,
    /// including quoted fields that contain line breaks.
    static func delimited(_ s: [UInt8], separator: UInt8, _ state: inout LexState) -> [Token] {
        var out: [Token] = []
        var col = 0
        var inQuotes = false
        if case .csvQuoted(let c) = state { col = c; inQuotes = true }
        var i = 0
        var fieldStart = 0
        while i < s.count {
            let b = s[i]
            if b == UInt8(ascii: "\"") {
                if inQuotes, i + 1 < s.count, s[i + 1] == UInt8(ascii: "\"") { i += 2; continue }
                inQuotes.toggle()
            } else if b == separator && !inQuotes {
                if i > fieldStart { out.append(Token(range: fieldStart..<i, kind: .column(col))) }
                out.append(Token(range: i..<i + 1, kind: .punctuation))
                col += 1
                fieldStart = i + 1
            }
            i += 1
        }
        if s.count > fieldStart { out.append(Token(range: fieldStart..<s.count, kind: .column(col))) }
        state = inQuotes ? .csvQuoted(column: col) : .normal
        return out
    }

    /// Field boundaries of a delimited line (for column alignment and the
    /// column commands): byte ranges of each field, quotes included.
    public static func fields(_ s: [UInt8], separator: UInt8) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var inQuotes = false
        var start = 0
        var i = 0
        while i < s.count {
            let b = s[i]
            if b == UInt8(ascii: "\"") {
                if inQuotes, i + 1 < s.count, s[i + 1] == UInt8(ascii: "\"") { i += 2; continue }
                inQuotes.toggle()
            } else if b == separator && !inQuotes {
                out.append(start..<i); start = i + 1
            }
            i += 1
        }
        out.append(start..<s.count)
        return out
    }

    static func xml(_ s: [UInt8], _ state: inout LexState) -> [Token] {
        var out: [Token] = []
        let n = s.count
        var i = 0
        switch state {
        case .xmlComment:
            if let e = find(Array("-->".utf8), in: s, from: 0) {
                out.append(Token(range: 0..<e + 3, kind: .comment)); i = e + 3; state = .normal
            } else { return n > 0 ? [Token(range: 0..<n, kind: .comment)] : [] }
        case .xmlCData:
            if let e = find(Array("]]>".utf8), in: s, from: 0) {
                out.append(Token(range: 0..<e + 3, kind: .string)); i = e + 3; state = .normal
            } else { return n > 0 ? [Token(range: 0..<n, kind: .string)] : [] }
        case .xmlTag:
            i = tagBody(s, from: 0, &out, &state)
        default:
            state = .normal
        }
        while i < n {
            let b = s[i]
            if b == UInt8(ascii: "<") {
                if s[i...].starts(with: Array("<!--".utf8)) {
                    if let e = find(Array("-->".utf8), in: s, from: i + 4) {
                        out.append(Token(range: i..<e + 3, kind: .comment)); i = e + 3
                    } else { out.append(Token(range: i..<n, kind: .comment)); state = .xmlComment; break }
                    continue
                }
                if s[i...].starts(with: Array("<![CDATA[".utf8)) {
                    if let e = find(Array("]]>".utf8), in: s, from: i + 9) {
                        out.append(Token(range: i..<e + 3, kind: .string)); i = e + 3
                    } else { out.append(Token(range: i..<n, kind: .string)); state = .xmlCData; break }
                    continue
                }
                // Tag name.
                var j = i + 1
                if j < n, s[j] == UInt8(ascii: "/") || s[j] == UInt8(ascii: "?") || s[j] == UInt8(ascii: "!") { j += 1 }
                while j < n, isIdent(s[j]) || s[j] == UInt8(ascii: ":") || s[j] == UInt8(ascii: "-") || s[j] == UInt8(ascii: ".") { j += 1 }
                out.append(Token(range: i..<j, kind: .tag))
                state = .xmlTag
                i = tagBody(s, from: j, &out, &state)
            } else if b == UInt8(ascii: "&") {
                var j = i + 1
                while j < n, j - i < 12, isIdent(s[j]) || s[j] == UInt8(ascii: "#") { j += 1 }
                if j < n, s[j] == UInt8(ascii: ";") { out.append(Token(range: i..<j + 1, kind: .number)); i = j + 1 }
                else { i += 1 }
            } else {
                i += 1
            }
        }
        return out
    }

    /// Attributes inside a tag, up to and including `>`. Leaves `state` as
    /// `.xmlTag` if the tag continues on the next line.
    private static func tagBody(_ s: [UInt8], from start: Int, _ out: inout [Token], _ state: inout LexState) -> Int {
        let n = s.count
        var i = start
        while i < n {
            let b = s[i]
            if b == UInt8(ascii: ">") || (b == UInt8(ascii: "/") && i + 1 < n && s[i + 1] == UInt8(ascii: ">"))
                || (b == UInt8(ascii: "?") && i + 1 < n && s[i + 1] == UInt8(ascii: ">")) {
                let e = b == UInt8(ascii: ">") ? i + 1 : i + 2
                out.append(Token(range: i..<e, kind: .tag))
                state = .normal
                return e
            } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                let e = closeQuote(s, from: i + 1, quote: b, backslash: false) ?? n
                out.append(Token(range: i..<e, kind: .string)); i = e
            } else if isIdent(b) {
                var j = i
                while j < n, isIdent(s[j]) || s[j] == UInt8(ascii: ":") || s[j] == UInt8(ascii: "-") || s[j] == UInt8(ascii: ".") { j += 1 }
                out.append(Token(range: i..<j, kind: .attribute)); i = j
            } else if b == UInt8(ascii: "=") {
                out.append(Token(range: i..<i + 1, kind: .punctuation)); i += 1
            } else {
                i += 1
            }
        }
        state = .xmlTag
        return n
    }

    private static let logLevels: [(Set<String>, TokenKind)] = [
        (["ERROR", "ERR", "FATAL", "CRITICAL", "CRIT", "SEVERE", "EMERG", "ALERT", "PANIC", "EXCEPTION", "FAILED", "FAILURE"], .logError),
        (["WARN", "WARNING"], .logWarning),
        (["INFO", "NOTICE"], .logInfo),
        (["DEBUG", "TRACE", "VERBOSE", "FINE", "FINER", "FINEST"], .logDebug),
    ]

    /// Log files: timestamps, levels (ERROR / WARN / INFO / DEBUG), quoted
    /// strings, [bracketed] fields, numbers and IP addresses.
    static func log(_ s: [UInt8]) -> [Token] {
        var out: [Token] = []
        let n = s.count
        var i = 0
        // Leading timestamp: 2024-01-01T00:00:00(.000)(Z|+00:00), 2024/01/01 00:00:00, or "Jan  1 00:00:00".
        if n >= 8 {
            var j = 0
            if isDigit(s[0]) {
                while j < n, isDigit(s[j]) || s[j] == UInt8(ascii: "-") || s[j] == UInt8(ascii: "/") || s[j] == UInt8(ascii: ":")
                        || s[j] == UInt8(ascii: ".") || s[j] == UInt8(ascii: ",") || s[j] == UInt8(ascii: "T")
                        || s[j] == UInt8(ascii: "Z") || s[j] == UInt8(ascii: "+")
                        || (s[j] == 0x20 && j + 1 < n && isDigit(s[j + 1]) && j < 11) { j += 1 }
                if j >= 8 { out.append(Token(range: 0..<j, kind: .timestamp)); i = j }
            } else if n >= 15, s[0] >= 0x41 && s[0] <= 0x5A, s[3] == 0x20, isDigit(s[7]), s[9] == UInt8(ascii: ":") {
                out.append(Token(range: 0..<15, kind: .timestamp)); i = 15
            }
        }
        while i < n {
            let b = s[i]
            if b == UInt8(ascii: "\"") {
                let j = endOfQuoted(s, from: i, quote: b)
                out.append(Token(range: i..<j, kind: .string)); i = j
            } else if b == UInt8(ascii: "[") {
                var j = i + 1
                while j < n, s[j] != UInt8(ascii: "]"), j - i < 200 { j += 1 }
                if j < n, s[j] == UInt8(ascii: "]") {
                    let inner = String(decoding: s[i + 1..<j], as: UTF8.self).trimmingCharacters(in: .whitespaces).uppercased()
                    let level = logLevels.first { $0.0.contains(inner) }?.1
                    out.append(Token(range: i..<j + 1, kind: level ?? .key)); i = j + 1
                } else { i += 1 }
            } else if isDigit(b) {
                let j = endOfNumber(s, i)
                var k = j
                while k < n, s[k] == UInt8(ascii: ".") || isDigit(s[k]) || s[k] == UInt8(ascii: ":") { k += 1 }   // IPs, times
                out.append(Token(range: i..<k, kind: .number)); i = k
            } else if isIdent(b) {
                var j = i
                while j < n, isIdent(s[j]) { j += 1 }
                if j - i >= 3 && j - i <= 9 {
                    let w = String(decoding: s[i..<j], as: UTF8.self)
                    if w == w.uppercased() || w.first == "E" || w.first == "W" {
                        if let level = logLevels.first(where: { $0.0.contains(w.uppercased()) && (w == w.uppercased() || $0.1 == .logError) })?.1 {
                            out.append(Token(range: i..<j, kind: level))
                        }
                    }
                }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }
}
