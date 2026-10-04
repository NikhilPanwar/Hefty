import Foundation

public struct SortOptions: Sendable {
    public var descending = false
    public var numeric = false
    public var caseInsensitive = true
    /// Sort by this 0-based column of a CSV/TSV line instead of the whole line.
    public var column: Int?
    public var separator: UInt8 = UInt8(ascii: ",")
    public var removeDuplicates = false
    public init() {}
}

/// Whole-line operations (sort, remove duplicates, filter by column, extract
/// a column) over a contiguous buffer: either an in-memory selection or a
/// memory-mapped file for whole huge documents.
public enum LineTools {
    /// Start offset of every line, plus a final entry one past the last line.
    public static func lineStarts(_ buf: UnsafeRawBufferPointer) -> [Int] {
        var starts = [0]
        guard let base = buf.baseAddress else { return [0, 0] }
        var p = base
        let stop = base + buf.count
        while p < stop, let hit = memchr(p, 0x0A, stop - p) {
            let next = UnsafeRawPointer(hit) + 1
            starts.append(next - base)
            p = next
        }
        if starts.last! != buf.count { starts.append(buf.count) }
        return starts
    }

    /// Line `i` without its line break.
    @inline(__always)
    static func line(_ buf: UnsafeRawBufferPointer, _ starts: [Int], _ i: Int) -> UnsafeRawBufferPointer {
        var e = starts[i + 1]
        if e > starts[i] && buf[e - 1] == 0x0A { e -= 1 }
        if e > starts[i] && buf[e - 1] == 0x0D { e -= 1 }
        return UnsafeRawBufferPointer(rebasing: buf[starts[i]..<e])
    }

    static func field(_ line: UnsafeRawBufferPointer, _ column: Int, _ sep: UInt8) -> UnsafeRawBufferPointer {
        let bytes = Array(line)
        let f = Highlighter.fields(bytes, separator: sep)
        guard column < f.count else { return UnsafeRawBufferPointer(rebasing: line[0..<0]) }
        var r = f[column]
        if r.count >= 2, bytes[r.lowerBound] == 0x22, bytes[r.upperBound - 1] == 0x22 { r = r.lowerBound + 1..<r.upperBound - 1 }
        return UnsafeRawBufferPointer(rebasing: line[r])
    }

    static func compareBytes(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer, fold: Bool) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            var x = a[i], y = b[i]
            if fold { if x >= 0x41 && x <= 0x5A { x |= 0x20 }; if y >= 0x41 && y <= 0x5A { y |= 0x20 } }
            if x != y { return x < y ? -1 : 1 }
            i += 1
        }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    static func number(_ b: UnsafeRawBufferPointer) -> Double {
        let s = String(decoding: b, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return Double(s) ?? -Double.infinity
    }

    /// Sorted lines of `buf`, each followed by `newline`.
    public static func sort(_ buf: UnsafeRawBufferPointer, options o: SortOptions, newline: [UInt8],
                            emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        let starts = lineStarts(buf)
        var count = starts.count - 1
        // A trailing empty "line" after the final newline isn't a line.
        if count > 0 && starts[count] == starts[count - 1] { count -= 1 }
        var order = Array(0..<count)
        if o.numeric {
            let keys: [Double] = (0..<count).map { i in
                let l = line(buf, starts, i)
                return number(o.column.map { field(l, $0, o.separator) } ?? l)
            }
            order.sort { o.descending ? keys[$0] > keys[$1] : (keys[$0] < keys[$1] || (keys[$0] == keys[$1] && $0 < $1)) }
        } else if let c = o.column {
            let keys: [(Int, Int)] = (0..<count).map { i in
                let l = line(buf, starts, i)
                let f = field(l, c, o.separator)
                return (f.baseAddress.map { UnsafeRawPointer($0) - buf.baseAddress! } ?? 0, f.count)
            }
            func key(_ i: Int) -> UnsafeRawBufferPointer { UnsafeRawBufferPointer(rebasing: buf[keys[i].0..<keys[i].0 + keys[i].1]) }
            order.sort {
                let c = compareBytes(key($0), key($1), fold: o.caseInsensitive)
                return o.descending ? c > 0 : (c < 0 || (c == 0 && $0 < $1))
            }
        } else {
            order.sort {
                let c = compareBytes(line(buf, starts, $0), line(buf, starts, $1), fold: o.caseInsensitive)
                return o.descending ? c > 0 : (c < 0 || (c == 0 && $0 < $1))
            }
        }
        var previous: UnsafeRawBufferPointer?
        for i in order {
            let l = line(buf, starts, i)
            if o.removeDuplicates, let p = previous, compareBytes(p, l, fold: false) == 0 { continue }
            try emit(l)
            try newline.withUnsafeBytes { try emit($0) }
            previous = l
        }
    }

    /// Lines with duplicates removed, keeping the first occurrence and the
    /// original order (or only collapsing adjacent repeats).
    public static func removeDuplicates(_ buf: UnsafeRawBufferPointer, adjacentOnly: Bool, newline: [UInt8],
                                        emit: (UnsafeRawBufferPointer) throws -> Void) throws -> Int {
        let starts = lineStarts(buf)
        var count = starts.count - 1
        if count > 0 && starts[count] == starts[count - 1] { count -= 1 }
        var removed = 0
        var seen: [Int: [Int]] = [:]   // hash -> line indices with that hash
        var previous: UnsafeRawBufferPointer?
        for i in 0..<count {
            let l = line(buf, starts, i)
            if adjacentOnly {
                if let p = previous, compareBytes(p, l, fold: false) == 0 { removed += 1; continue }
                previous = l
            } else {
                var h = Hasher()
                h.combine(bytes: l)
                let key = h.finalize()
                if let same = seen[key], same.contains(where: { compareBytes(line(buf, starts, $0), l, fold: false) == 0 }) {
                    removed += 1; continue
                }
                seen[key, default: []].append(i)
            }
            try emit(l)
            try newline.withUnsafeBytes { try emit($0) }
        }
        return removed
    }

    /// Lines whose `column` contains `text` (case-insensitive), or equals it
    /// when `exact`. The first line is always kept when `keepHeader`.
    public static func filterColumn(_ buf: UnsafeRawBufferPointer, column: Int, separator: UInt8, text: String,
                                    exact: Bool, keepHeader: Bool, newline: [UInt8],
                                    emit: (UnsafeRawBufferPointer) throws -> Void) throws -> Int {
        let starts = lineStarts(buf)
        var count = starts.count - 1
        if count > 0 && starts[count] == starts[count - 1] { count -= 1 }
        let needle = text.lowercased()
        var kept = 0
        for i in 0..<count {
            let l = line(buf, starts, i)
            let f = String(decoding: field(l, column, separator), as: UTF8.self).lowercased()
            let match = exact ? f == needle : f.contains(needle)
            if match || (keepHeader && i == 0) {
                try emit(l)
                try newline.withUnsafeBytes { try emit($0) }
                if i > 0 || !keepHeader { kept += 1 }
            }
        }
        return kept
    }

    /// Values of one column, one per line.
    public static func extractColumn(_ buf: UnsafeRawBufferPointer, column: Int, separator: UInt8, newline: [UInt8],
                                     emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        let starts = lineStarts(buf)
        var count = starts.count - 1
        if count > 0 && starts[count] == starts[count - 1] { count -= 1 }
        for i in 0..<count {
            try emit(field(line(buf, starts, i), column, separator))
            try newline.withUnsafeBytes { try emit($0) }
        }
    }

    /// Convenience: runs `body` and collects its output in memory.
    public static func collect(_ body: ((UnsafeRawBufferPointer) throws -> Void) throws -> Void) rethrows -> [UInt8] {
        var out: [UInt8] = []
        try body { out.append(contentsOf: $0) }
        return out
    }
}
