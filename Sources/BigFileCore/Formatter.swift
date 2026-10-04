import Foundation

/// Streaming JSON pretty-printer / minifier: reads the document in chunks and
/// writes to an output file, so it works on files of any size with constant
/// memory. Does not validate; it re-indents based on brackets outside strings.
public enum JSONFormatter {
    public static func format(_ document: TextDocument, to url: URL, indent: Int = 2,
                              minify: Bool = false, progress: ((Double) -> Void)? = nil) throws {
        let sink = try FileSink(url: url)
        try format(document.snapshot(), to: sink, indent: indent, minify: minify, progress: progress)
        try sink.close()
    }

    public static func format(_ snap: TextSnapshot, to sink: FileSink, indent: Int = 2, useTabs: Bool = false,
                              minify: Bool = false, progress: ((Double) -> Void)? = nil) throws {
        var buf: [UInt8] = []
        buf.reserveCapacity(1 << 20)
        var depth = 0
        var inString = false
        var escaped = false
        var emptyContainer = false
        var written = 0
        let total = max(1, snap.length)
        var writeError: Error?

        func flushIfNeeded(_ force: Bool = false) {
            if buf.count >= 1 << 20 || (force && !buf.isEmpty) {
                do { try sink.write(buf) } catch { writeError = error }
                buf.removeAll(keepingCapacity: true)
            }
        }
        func newline() {
            guard !minify else { return }
            buf.append(0x0A)
            if useTabs { buf.append(contentsOf: repeatElement(0x09, count: depth)) }
            else { buf.append(contentsOf: repeatElement(0x20, count: depth * indent)) }
        }

        snap.forEachChunk(in: 0..<snap.length) { chunk, _ in
            for b in chunk {
                if inString {
                    buf.append(b)
                    if escaped { escaped = false }
                    else if b == 0x5C { escaped = true }
                    else if b == 0x22 { inString = false }
                    continue
                }
                switch b {
                case 0x20, 0x09, 0x0A, 0x0D:
                    continue   // drop insignificant whitespace
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    if emptyContainer { newline() }
                    buf.append(b)
                    depth += 1
                    emptyContainer = true
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth = max(0, depth - 1)
                    if !emptyContainer { newline() }
                    emptyContainer = false
                    buf.append(b)
                case UInt8(ascii: ","):
                    buf.append(b)
                    newline()
                case UInt8(ascii: ":"):
                    buf.append(b)
                    if !minify { buf.append(0x20) }
                default:
                    if emptyContainer { newline(); emptyContainer = false }
                    if b == 0x22 { inString = true }
                    buf.append(b)
                }
            }
            written += chunk.count
            flushIfNeeded()
            progress?(Double(written) / Double(total))
            return writeError == nil
        }
        if !minify { buf.append(0x0A) }
        flushIfNeeded(true)
        if let writeError { throw writeError }
    }
}

/// Streaming XML / HTML pretty-printer: one tag per line, indented by
/// nesting depth. Comments, CDATA, processing instructions and the contents
/// of <script>/<style>/<pre> are copied untouched.
public enum XMLFormatter {
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    public static func format(_ snap: TextSnapshot, to sink: FileSink, indent: Int = 2, useTabs: Bool = false,
                              progress: ((Double) -> Void)? = nil) throws {
        var out: [UInt8] = []
        out.reserveCapacity(1 << 20)
        var depth = 0
        var tag: [UInt8] = []         // current markup being collected
        var inTag = false
        var quote: UInt8 = 0
        var text: [UInt8] = []
        var raw: [UInt8]? = nil       // inside <script> etc: closing tag to wait for
        var rawBuf: [UInt8] = []
        var lineStarted = false
        var written = 0
        var failure: Error?

        func pad() {
            if lineStarted { out.append(0x0A) }
            if useTabs { out.append(contentsOf: repeatElement(0x09, count: depth)) }
            else { out.append(contentsOf: repeatElement(0x20, count: depth * indent)) }
            lineStarted = true
        }
        func flush(_ force: Bool = false) {
            if out.count > 1 << 20 || force {
                do { try sink.write(out) } catch { failure = error }
                out.removeAll(keepingCapacity: true)
            }
        }
        func emitText() {
            let trimmed = text.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
            var t = Array(trimmed)
            while let l = t.last, l == 0x20 || l == 0x09 || l == 0x0A || l == 0x0D { t.removeLast() }
            if !t.isEmpty { pad(); out.append(contentsOf: t) }
            text.removeAll(keepingCapacity: true)
        }
        func name(_ t: [UInt8]) -> String {
            var i = 1
            if i < t.count, t[i] == UInt8(ascii: "/") { i += 1 }
            var j = i
            while j < t.count, !(t[j] == 0x20 || t[j] == 0x09 || t[j] == 0x0A || t[j] == 0x0D
                                  || t[j] == UInt8(ascii: ">") || t[j] == UInt8(ascii: "/")) { j += 1 }
            return String(decoding: t[i..<j], as: UTF8.self).lowercased()
        }
        func emitTag() {
            let t = tag
            tag.removeAll(keepingCapacity: true)
            let isComment = t.starts(with: Array("<!--".utf8)) || t.starts(with: Array("<![CDATA[".utf8))
            let isDecl = t.count > 1 && (t[1] == UInt8(ascii: "?") || t[1] == UInt8(ascii: "!"))
            let closing = t.count > 1 && t[1] == UInt8(ascii: "/")
            let selfClosing = t.count > 2 && t[t.count - 2] == UInt8(ascii: "/")
            let n = name(t)
            if closing { depth = max(0, depth - 1) }
            pad()
            out.append(contentsOf: t)
            if !closing && !selfClosing && !isComment && !isDecl && !voidElements.contains(n) {
                depth += 1
                if n == "script" || n == "style" || n == "pre" || n == "textarea" {
                    raw = Array("</\(n)".utf8)
                }
            }
        }

        snap.forEachChunk(in: 0..<snap.length) { chunk, _ in
            for b in chunk {
                if let end = raw {
                    rawBuf.append(b)
                    if rawBuf.count >= end.count, rawBuf.suffix(end.count).elementsEqual(end, by: { $0 | 0x20 == $1 | 0x20 }) {
                        out.append(contentsOf: rawBuf.dropLast(end.count))
                        rawBuf.removeAll()
                        raw = nil
                        inTag = true
                        tag = end
                    }
                    continue
                }
                if inTag {
                    tag.append(b)
                    let isComment = tag.starts(with: Array("<!--".utf8))
                    let isCData = tag.starts(with: Array("<![CDATA[".utf8))
                    if isComment || isCData {
                        if (isComment && tag.count >= 7 && tag.suffix(3) == ArraySlice("-->".utf8)) ||
                           (isCData && tag.count >= 12 && tag.suffix(3) == ArraySlice("]]>".utf8)) {
                            inTag = false; emitTag()
                        }
                        continue
                    }
                    if quote != 0 { if b == quote { quote = 0 }; continue }
                    if b == 0x22 || b == 0x27 { quote = b; continue }
                    if b == UInt8(ascii: ">") { inTag = false; emitTag() }
                } else if b == UInt8(ascii: "<") {
                    emitText()
                    inTag = true
                    tag = [b]
                } else {
                    text.append(b)
                }
            }
            written += chunk.count
            flush()
            progress?(Double(written) / Double(max(1, snap.length)))
            return failure == nil
        }
        if !tag.isEmpty { out.append(contentsOf: tag) }
        out.append(contentsOf: rawBuf)
        emitText()
        out.append(0x0A)
        flush(true)
        if let failure { throw failure }
    }
}

/// SQL formatter for queries (in memory): puts major clauses on their own
/// lines and indents lists. Strings, quoted identifiers and comments are
/// left untouched.
public enum SQLFormatter {
    private static let breakBefore: [String] = [
        "select", "from", "where", "group by", "order by", "having", "limit", "offset", "values", "set",
        "union all", "union", "inner join", "left outer join", "right outer join", "left join", "right join",
        "full join", "cross join", "join", "on conflict", "returning", "insert into", "update", "delete from",
        "with",
    ]
    private static let andOr: Set<String> = ["and", "or"]

    public static func format(_ input: [UInt8], indent: String = "  ", uppercaseKeywords: Bool = true) -> [UInt8] {
        let s = input
        var out: [UInt8] = []
        out.reserveCapacity(s.count + s.count / 4)
        var i = 0
        let n = s.count
        var depth = 0
        var atLineStart = true
        var pendingSpace = false

        func newline(_ extra: Int = 0) {
            while let l = out.last, l == 0x20 { out.removeLast() }
            if !out.isEmpty { out.append(0x0A) }
            for _ in 0..<(depth + extra) { out.append(contentsOf: indent.utf8) }
            atLineStart = true
            pendingSpace = false
        }
        func put(_ bytes: ArraySlice<UInt8>) {
            if pendingSpace && !atLineStart { out.append(0x20) }
            out.append(contentsOf: bytes)
            atLineStart = false
            pendingSpace = false
        }
        while i < n {
            let b = s[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { pendingSpace = true; i += 1; continue }
            if b == UInt8(ascii: "-"), i + 1 < n, s[i + 1] == UInt8(ascii: "-") {
                var j = i; while j < n, s[j] != 0x0A { j += 1 }
                put(s[i..<j]); newline(); i = j; continue
            }
            if b == UInt8(ascii: "/"), i + 1 < n, s[i + 1] == UInt8(ascii: "*") {
                let e = Highlighter.find([0x2A, 0x2F], in: s, from: i + 2).map { $0 + 2 } ?? n
                put(s[i..<e]); i = e; continue
            }
            if b == UInt8(ascii: "'") || b == UInt8(ascii: "\"") || b == UInt8(ascii: "`") {
                let e = Highlighter.closeQuote(s, from: i + 1, quote: b) ?? n
                put(s[i..<e]); i = e; continue
            }
            if b == UInt8(ascii: ";") { put(s[i..<i + 1]); depth = 0; newline(); i += 1; continue }
            if b == UInt8(ascii: "(") { put(s[i..<i + 1]); depth += 1; i += 1; continue }
            if b == UInt8(ascii: ")") { depth = max(0, depth - 1); put(s[i..<i + 1]); i += 1; continue }
            if b == UInt8(ascii: ",") { out.append(b); pendingSpace = true; atLineStart = false; i += 1; continue }
            if Highlighter.isIdent(b) {
                var j = i
                while j < n, Highlighter.isIdent(s[j]) { j += 1 }
                let word = String(decoding: s[i..<j], as: UTF8.self).lowercased()
                // Multi-word clause starting here?
                var matched: String?
                for kw in breakBefore where kw.hasPrefix(word) {
                    let parts = kw.split(separator: " ")
                    var k = i, ok = true, end = i
                    for p in parts {
                        while k < n, s[k] == 0x20 || s[k] == 0x0A || s[k] == 0x09 || s[k] == 0x0D { k += 1 }
                        var e = k; while e < n, Highlighter.isIdent(s[e]) { e += 1 }
                        if String(decoding: s[k..<e], as: UTF8.self).lowercased() != p { ok = false; break }
                        end = e; k = e
                    }
                    if ok { matched = kw; j = end; break }
                }
                if let kw = matched {
                    newline()
                    let text = uppercaseKeywords ? kw.uppercased() : String(decoding: s[i..<j], as: UTF8.self)
                    put(ArraySlice(text.utf8))
                    pendingSpace = true
                } else if andOr.contains(word) {
                    newline(1)
                    put(ArraySlice((uppercaseKeywords ? word.uppercased() : word).utf8))
                    pendingSpace = true
                } else {
                    let isKeyword = word.count <= 16 && Highlighter.tokens(for: Array(word.utf8), language: .sql).first?.kind == .keyword
                    put(isKeyword && uppercaseKeywords ? ArraySlice(word.uppercased().utf8) : s[i..<j])
                }
                i = j
                continue
            }
            put(s[i..<i + 1]); i += 1
        }
        while let l = out.last, l == 0x20 || l == 0x0A { out.removeLast() }
        out.append(0x0A)
        return out
    }
}
