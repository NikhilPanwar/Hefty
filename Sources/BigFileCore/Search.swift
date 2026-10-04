import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SearchOptions: Sendable {
    public var caseSensitive = true
    public var wholeWord = false
    public var regex = false
    public var wrapAround = true
    /// Restrict the search to this range (Find in Selection).
    public var range: Range<Int>?

    public init(caseSensitive: Bool = true, wholeWord: Bool = false, regex: Bool = false,
                wrapAround: Bool = true, range: Range<Int>? = nil) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
        self.wrapAround = wrapAround
        self.range = range
    }
}

public enum SearchError: Error, CustomStringConvertible {
    case badPattern(String)
    public var description: String {
        switch self { case .badPattern(let m): return "Invalid regular expression: \(m)" }
    }
}

@inline(__always) func isWordByte(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
}

/// A compiled search: literal bytes (fast, memchr-driven) or an ICU regular
/// expression run over line-aligned windows of decoded text.
public struct SearchPattern: @unchecked Sendable {
    let literal: [UInt8]?
    let foldedLiteral: [UInt8]?
    let regex: NSRegularExpression?
    public let options: SearchOptions
    public let text: String

    public init(_ text: String, options: SearchOptions) throws {
        self.text = text
        self.options = options
        let bytes = Array(text.utf8)
        let asciiOnly = bytes.allSatisfy { $0 < 0x80 }
        if options.regex || (!options.caseSensitive && !asciiOnly) {
            var pattern = options.regex ? text : NSRegularExpression.escapedPattern(for: text)
            if options.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
            var o: NSRegularExpression.Options = [.anchorsMatchLines]
            if !options.caseSensitive { o.insert(.caseInsensitive) }
            do { regex = try NSRegularExpression(pattern: pattern, options: o) }
            catch { throw SearchError.badPattern((error as NSError).localizedFailureReason ?? (error as NSError).localizedDescription) }
            literal = nil; foldedLiteral = nil
        } else {
            regex = nil
            literal = bytes
            foldedLiteral = options.caseSensitive ? nil : bytes.map(Self.fold)
        }
    }

    @inline(__always) static func fold(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b }
    public var isRegex: Bool { regex != nil }
}

/// Text of a line-aligned window, decoded for the regex engine, with a way
/// back from UTF-16 offsets to byte offsets.
struct DecodedWindow {
    let string: NSString
    let base: Int          // document offset of byte 0
    private let map: [Int32]?   // utf16 index -> byte offset (only for invalid UTF-8)
    private let isASCII: Bool
    private var lastU16 = 0, lastByte = 0

    init(_ buf: UnsafeRawBufferPointer, base: Int) {
        self.base = base
        var ascii = true
        for b in buf where b >= 0x80 { ascii = false; break }
        isASCII = ascii
        if ascii || EncodingDetector.isValidUTF8(buf) {
            string = NSString(bytes: buf.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, length: buf.count,
                              encoding: String.Encoding.utf8.rawValue) ?? ""
            map = nil
        } else {
            let (units, m) = LineDecoder.decode(buf)
            string = units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: units.count) }
            map = m
        }
    }

    /// Byte offset (in the document) of UTF-16 offset `u`. Calls must come
    /// in non-decreasing order of `u` for the fast path.
    mutating func byteOffset(_ u: Int) -> Int {
        if isASCII { return base + u }
        if let map { return base + Int(map[min(u, map.count - 1)]) }
        if u < lastU16 { lastU16 = 0; lastByte = 0 }
        if u > lastU16 {
            let piece = string.substring(with: NSRange(location: lastU16, length: u - lastU16))
            lastByte += piece.utf8.count
            lastU16 = u
        }
        return base + lastByte
    }
}

/// Decodes UTF-8 into UTF-16 units, turning each invalid byte into U+FFFD,
/// and records for every unit the byte offset where its character starts.
public enum LineDecoder {
    public static func decode(_ buf: UnsafeRawBufferPointer) -> (units: [UInt16], map: [Int32]) {
        var units = [UInt16](); units.reserveCapacity(buf.count + 1)
        var map = [Int32](); map.reserveCapacity(buf.count + 1)
        let n = buf.count
        var i = 0
        while i < n {
            let c = buf[i]
            if c < 0x80 { units.append(UInt16(c)); map.append(Int32(i)); i += 1; continue }
            var len = 0, scalar: UInt32 = 0
            if c & 0xE0 == 0xC0 && c >= 0xC2 { len = 2; scalar = UInt32(c & 0x1F) }
            else if c & 0xF0 == 0xE0 { len = 3; scalar = UInt32(c & 0x0F) }
            else if c & 0xF8 == 0xF0 && c <= 0xF4 { len = 4; scalar = UInt32(c & 0x07) }
            var ok = len > 0 && i + len <= n
            if ok {
                for k in 1..<len {
                    let cc = buf[i + k]
                    if cc & 0xC0 != 0x80 { ok = false; break }
                    scalar = (scalar << 6) | UInt32(cc & 0x3F)
                }
            }
            if ok && ((len == 3 && (scalar < 0x800 || (scalar >= 0xD800 && scalar < 0xE000))) ||
                      (len == 4 && (scalar < 0x10000 || scalar > 0x10FFFF))) { ok = false }
            if !ok {
                units.append(0xFFFD); map.append(Int32(i)); i += 1; continue
            }
            if scalar >= 0x10000 {
                let v = scalar - 0x10000
                units.append(UInt16(0xD800 + (v >> 10))); map.append(Int32(i))
                units.append(UInt16(0xDC00 + (v & 0x3FF))); map.append(Int32(i))
            } else {
                units.append(UInt16(scalar)); map.append(Int32(i))
            }
            i += len
        }
        map.append(Int32(n))
        return (units, map)
    }
}

/// Streaming search over a document snapshot. Literal searches scan large
/// windows with memchr (disk/memory bandwidth); regex searches decode
/// line-aligned windows and run ICU on them.
public final class TextSearcher: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}
    public func cancel() { lock.sync { cancelled = true } }
    public var isCancelled: Bool { lock.sync { cancelled } }

    private static let window = 32 << 20
    private static let regexWindow = 4 << 20

    // MARK: Find next / previous

    /// Finds the next match at or after `from` (or ending at/before it, if
    /// `backwards`). Wraps around within `options.range` or the document.
    public func find(_ pattern: SearchPattern, in snap: TextSnapshot, from: Int, backwards: Bool = false,
                     progress: ((Double) -> Void)? = nil) -> Range<Int>? {
        let bounds = pattern.options.range ?? 0..<snap.length
        guard !bounds.isEmpty || pattern.isRegex else { return nil }
        let start = min(max(bounds.lowerBound, from), bounds.upperBound)
        if !backwards {
            if let r = forward(pattern, snap, start..<bounds.upperBound, progress) { return r }
            if pattern.options.wrapAround && start > bounds.lowerBound {
                let extra = pattern.literal.map { $0.count - 1 } ?? 0
                return forward(pattern, snap, bounds.lowerBound..<min(bounds.upperBound, start + extra), progress)
            }
        } else {
            if let r = backward(pattern, snap, bounds.lowerBound..<start, progress) { return r }
            if pattern.options.wrapAround && start < bounds.upperBound {
                return backward(pattern, snap, start..<bounds.upperBound, progress)
            }
        }
        return nil
    }

    /// Convenience used by tests: literal/regex search on a whole document.
    public func find(_ needle: String, in document: TextDocument, from: Int, backwards: Bool = false,
                     options: SearchOptions = SearchOptions()) -> Range<Int>? {
        guard let p = try? SearchPattern(needle, options: options), !needle.isEmpty else { return nil }
        return find(p, in: document.snapshot(), from: from, backwards: backwards)
    }

    private func forward(_ p: SearchPattern, _ snap: TextSnapshot, _ range: Range<Int>,
                         _ progress: ((Double) -> Void)?) -> Range<Int>? {
        var found: Range<Int>?
        scan(p, snap, range, progress: progress) { r, _ in found = r; return false }
        return found
    }

    private func backward(_ p: SearchPattern, _ snap: TextSnapshot, _ range: Range<Int>,
                          _ progress: ((Double) -> Void)?) -> Range<Int>? {
        if let lit = p.literal { return backwardLiteral(lit, p, snap, range, progress) }
        // Regex: walk windows from the end, take the last match in each.
        var end = range.upperBound
        while end > range.lowerBound {
            if isCancelled { return nil }
            var lo = max(range.lowerBound, end - Self.regexWindow)
            if lo > range.lowerBound, let nl = snap.lastNewline(in: max(range.lowerBound, lo - (1 << 20))..<lo) {
                lo = nl + 1
            }
            var last: Range<Int>?
            regexWindow(p, snap, lo..<end, limit: range) { r, _ in
                if r.upperBound <= end { last = r }
                return true
            }
            if let last { return last }
            end = lo
            progress?(Double(range.upperBound - end) / Double(max(1, range.count)))
        }
        return nil
    }

    // MARK: Find all / count

    /// Calls `onMatch` for every match in order (with the replacement bytes
    /// when `template` is given). Return false to stop. Returns the count.
    @discardableResult
    public func findAll(_ p: SearchPattern, in snap: TextSnapshot, template: String? = nil,
                        progress: ((Double) -> Void)? = nil,
                        onMatch: (Range<Int>, [UInt8]?) -> Bool) -> Int {
        let range = p.options.range ?? 0..<snap.length
        var count = 0
        let literalReplacement = template.map { Array($0.utf8) }
        scan(p, snap, range, template: template, progress: progress) { r, rep in
            count += 1
            return onMatch(r, p.isRegex ? rep : literalReplacement)
        }
        return count
    }

    /// Replacement text for the match at `match` (expands $1 etc. for regex).
    public func replacement(for match: Range<Int>, in snap: TextSnapshot, pattern p: SearchPattern,
                            template: String) -> [UInt8] {
        guard p.isRegex else { return Array(template.utf8) }
        // Re-run the regex on the surrounding lines to get capture groups.
        let lo = snap.lastNewline(in: max(0, match.lowerBound - (1 << 20))..<match.lowerBound).map { $0 + 1 }
            ?? max(0, match.lowerBound - (1 << 20))
        let hi = snap.firstNewline(in: match.upperBound..<min(snap.length, match.upperBound + (1 << 20)))
            ?? min(snap.length, match.upperBound + (1 << 20))
        var out: [UInt8]?
        regexWindow(p, snap, lo..<hi, limit: lo..<hi, template: template) { r, rep in
            if r == match { out = rep; return false }
            return r.lowerBound < match.lowerBound
        }
        return out ?? Array(template.utf8)
    }

    // MARK: Scanning

    private func scan(_ p: SearchPattern, _ snap: TextSnapshot, _ range: Range<Int>, template: String? = nil,
                      progress: ((Double) -> Void)?, _ onMatch: (Range<Int>, [UInt8]?) -> Bool) {
        if let lit = p.literal {
            scanLiteral(lit, p, snap, range, progress) { onMatch($0, nil) }
            return
        }
        var pos = range.lowerBound
        while pos < range.upperBound {
            if isCancelled { return }
            var end = min(range.upperBound, pos + Self.regexWindow)
            if end < range.upperBound, let nl = snap.firstNewline(in: end..<min(range.upperBound, end + (1 << 20))) {
                end = nl + 1
            }
            var keepGoing = true
            regexWindow(p, snap, pos..<end, limit: range, template: template) { r, rep in
                keepGoing = onMatch(r, rep)
                return keepGoing
            }
            if !keepGoing || end <= pos { return }
            pos = end
            progress?(Double(pos - range.lowerBound) / Double(max(1, range.count)))
        }
    }

    /// Runs the regex over one window. Matches are reported in document
    /// offsets; empty matches are skipped.
    private func regexWindow(_ p: SearchPattern, _ snap: TextSnapshot, _ w: Range<Int>, limit: Range<Int>,
                             template: String? = nil, _ onMatch: (Range<Int>, [UInt8]?) -> Bool) {
        guard let re = p.regex else { return }
        snap.withContiguousBytes(w) { buf in
            var win = DecodedWindow(buf, base: w.lowerBound)
            let s = win.string
            var stop = false
            re.enumerateMatches(in: s as String, options: [.reportCompletion],
                                range: NSRange(location: 0, length: s.length)) { m, _, halt in
                if self.isCancelled { halt.pointee = true; return }
                guard let m, m.range.location != NSNotFound, m.range.length > 0 else { return }
                let lo = win.byteOffset(m.range.location)
                let hi = win.byteOffset(m.range.location + m.range.length)
                guard lo >= limit.lowerBound, hi <= limit.upperBound else { return }
                var rep: [UInt8]?
                if let template {
                    rep = Array(re.replacementString(for: m, in: s as String, offset: 0, template: template).utf8)
                }
                if !onMatch(lo..<hi, rep) { stop = true; halt.pointee = true }
            }
            _ = stop
        }
    }

    private func scanLiteral(_ pat: [UInt8], _ p: SearchPattern, _ snap: TextSnapshot, _ range: Range<Int>,
                             _ progress: ((Double) -> Void)?, _ onMatch: (Range<Int>) -> Bool) {
        let m = pat.count
        guard m > 0 else { return }
        var pos = range.lowerBound
        let folded = p.foldedLiteral
        while pos < range.upperBound {
            if isCancelled { return }
            let end = min(range.upperBound, pos + Self.window + m - 1)
            if end - pos < m { return }
            var stop = false
            var lastHit = pos - 1
            snap.withContiguousBytes(pos..<end) { buf in
                var from = 0
                while let h = folded != nil ? Self.firstFolded(folded!, in: buf, from: from)
                                            : Self.firstExact(pat, in: buf, from: from) {
                    let r = (pos + h)..<(pos + h + m)
                    from = h + 1
                    if h >= Self.window { break }    // belongs to the next window
                    if p.options.wholeWord && !isWholeWord(r, snap) { continue }
                    lastHit = r.lowerBound
                    if !onMatch(r) { stop = true; return }
                    from = h + m   // matches don't overlap
                }
            }
            if stop { return }
            pos = max(pos + Self.window, lastHit + m)
            progress?(Double(min(pos, range.upperBound) - range.lowerBound) / Double(max(1, range.count)))
        }
    }

    /// Backward literal search: walk windows from the end, and inside each
    /// window find the last match with the (memchr-fast) forward scanner.
    private func backwardLiteral(_ pat: [UInt8], _ p: SearchPattern, _ snap: TextSnapshot, _ range: Range<Int>,
                                 _ progress: ((Double) -> Void)?) -> Range<Int>? {
        let m = pat.count
        var end = range.upperBound
        while end > range.lowerBound {
            if isCancelled { return nil }
            let lo = max(range.lowerBound, end - Self.window)
            var found: Range<Int>?
            snap.withContiguousBytes(lo..<end) { buf in
                var from = 0
                while let h = p.foldedLiteral != nil ? Self.firstFolded(p.foldedLiteral!, in: buf, from: from)
                                                     : Self.firstExact(pat, in: buf, from: from) {
                    let r = (lo + h)..<(lo + h + m)
                    if !p.options.wholeWord || isWholeWord(r, snap) { found = r }
                    from = h + 1
                }
            }
            if let found { return found }
            if lo == range.lowerBound { break }
            end = lo + m - 1    // overlap so matches across the window edge are found
            progress?(Double(range.upperBound - end) / Double(max(1, range.count)))
        }
        return nil
    }

    private func isWholeWord(_ r: Range<Int>, _ snap: TextSnapshot) -> Bool {
        if let b = snap.byte(at: r.lowerBound - 1), isWordByte(b) { return false }
        if let b = snap.byte(at: r.upperBound), isWordByte(b) { return false }
        return true
    }

    static func firstExact(_ pat: [UInt8], in buf: UnsafeRawBufferPointer, from: Int) -> Int? {
        guard let base = buf.baseAddress else { return nil }
        let n = buf.count, m = pat.count
        var i = from
        let first = Int32(pat[0])
        return pat.withUnsafeBytes { p -> Int? in
            while i <= n - m {
                guard let hit = memchr(base + i, first, n - m - i + 1) else { return nil }
                let j = UnsafeRawPointer(hit) - base
                if memcmp(base + j, p.baseAddress!, m) == 0 { return j }
                i = j + 1
            }
            return nil
        }
    }

    /// ASCII case-insensitive: memchr for both cases of the first letter.
    static func firstFolded(_ fp: [UInt8], in buf: UnsafeRawBufferPointer, from: Int) -> Int? {
        guard let base = buf.baseAddress else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let n = buf.count, m = fp.count
        guard n >= m else { return nil }
        let lower = fp[0]
        let upper: UInt8 = (lower >= 0x61 && lower <= 0x7A) ? lower - 0x20 : lower
        var i = from
        var nextLo = -1, nextUp = -1
        func find(_ c: UInt8, _ at: Int) -> Int {
            guard at <= n - m, let h = memchr(base + at, Int32(c), n - m - at + 1) else { return Int.max }
            return UnsafeRawPointer(h) - base
        }
        while i <= n - m {
            if nextLo < i { nextLo = find(lower, i) }
            if upper != lower, nextUp < i { nextUp = find(upper, i) }
            let j = upper != lower ? min(nextLo, nextUp) : nextLo
            if j == Int.max { return nil }
            var k = 1
            while k < m {
                let b = bytes[j + k]
                if ((b >= 0x41 && b <= 0x5A) ? b | 0x20 : b) != fp[k] { break }
                k += 1
            }
            if k == m { return j }
            i = j + 1
        }
        return nil
    }

    // MARK: Line filtering

    /// Streams every line containing a match (or not, if `invert`) to `sink`.
    /// Returns the number of lines written.
    public func filterLines(_ p: SearchPattern, in snap: TextSnapshot, invert: Bool, to sink: FileSink,
                            progress: ((Double) -> Void)? = nil) throws -> Int {
        var written = 0
        var lineStart = 0
        var lastEmittedLine = -1
        var failure: Error?
        func emit(_ lo: Int, _ hi: Int) {
            snap.forEachChunk(in: lo..<hi) { buf, _ in
                do { try sink.write(buf) } catch { failure = error; return false }
                return true
            }
            if hi == snap.length && snap.byte(at: hi - 1) != 0x0A { try? sink.write([0x0A]) }
            written += 1
        }
        func lineBounds(_ at: Int) -> Range<Int> {
            let s = snap.lastNewline(in: max(0, at - (64 << 20))..<at).map { $0 + 1 } ?? 0
            let e = snap.firstNewline(in: at..<snap.length).map { $0 + 1 } ?? snap.length
            return s..<e
        }
        if !invert {
            scan(p, snap, 0..<snap.length, progress: progress) { r, _ in
                guard r.lowerBound > lastEmittedLine else { return true }
                let lb = lineBounds(r.lowerBound)
                emit(lb.lowerBound, lb.upperBound)
                lastEmittedLine = lb.upperBound - 1
                return failure == nil
            }
        } else {
            scan(p, snap, 0..<snap.length, progress: progress) { r, _ in
                guard r.lowerBound >= lineStart else { return true }
                let lb = lineBounds(r.lowerBound)
                // Emit the non-matching lines before this match's line.
                var s = lineStart
                while s < lb.lowerBound {
                    let e = snap.firstNewline(in: s..<lb.lowerBound).map { $0 + 1 } ?? lb.lowerBound
                    emit(s, e); s = e
                }
                lineStart = lb.upperBound
                return failure == nil
            }
            var s = lineStart
            while s < snap.length && failure == nil {
                let e = snap.firstNewline(in: s..<snap.length).map { $0 + 1 } ?? snap.length
                emit(s, e); s = e
            }
        }
        if let failure { throw failure }
        return written
    }
}
