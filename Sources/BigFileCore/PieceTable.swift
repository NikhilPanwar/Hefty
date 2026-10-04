import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A span of either the original (memory-mapped, never modified) file or the
/// append-only buffer of inserted bytes.
public struct Piece: Sendable {
    public enum Source: Sendable { case original, added }
    public var source: Source
    /// Offset in the original file, or virtual offset in the add buffer.
    public var start: Int
    public var length: Int
    /// Cached number of "\n" bytes in the piece; -1 while unknown (an
    /// original piece the line index has not reached yet).
    public var newlines: Int

    public init(source: Source, start: Int, length: Int, newlines: Int = -1) {
        self.source = source
        self.start = start
        self.length = length
        self.newlines = newlines
    }
}

extension Piece: Equatable {
    public static func == (a: Piece, b: Piece) -> Bool {
        a.source == b.source && a.start == b.start && a.length == b.length
    }
}

/// Append-only storage for inserted text. Bytes live in fixed chunks that are
/// never moved or rewritten, so a snapshot can read them from a background
/// thread while the main thread keeps appending.
public final class AddBuffer: @unchecked Sendable {
    struct Chunk { let base: Int; let ptr: UnsafeMutableRawPointer; let capacity: Int }
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var used = 0          // bytes used in the last chunk
    private static let chunkSize = 1 << 20

    deinit { for c in chunks { c.ptr.deallocate() } }

    /// Virtual offset one past the last appended byte.
    var end: Int { lock.sync { chunks.last.map { $0.base + used } ?? 0 } }

    /// Appends `bytes` contiguously and returns their virtual start offset.
    func append(_ bytes: UnsafeRawBufferPointer) -> Int {
        lock.sync {
            if chunks.isEmpty || chunks[chunks.count - 1].capacity - used < bytes.count {
                let base = chunks.last.map { $0.base + $0.capacity } ?? 0
                let cap = max(Self.chunkSize, bytes.count)
                chunks.append(Chunk(base: base, ptr: .allocate(byteCount: cap, alignment: 16), capacity: cap))
                used = 0
            }
            let c = chunks[chunks.count - 1]
            if let src = bytes.baseAddress, bytes.count > 0 {
                (c.ptr + used).copyMemory(from: src, byteCount: bytes.count)
            }
            let start = c.base + used
            used += bytes.count
            return start
        }
    }

    func view() -> AddView { lock.sync { AddView(chunks: chunks) } }
}

/// Immutable list of add-buffer chunks, safe to read on any thread.
struct AddView: @unchecked Sendable {
    let chunks: [AddBuffer.Chunk]
    func bytes(_ start: Int, _ count: Int) -> UnsafeRawBufferPointer {
        var lo = 0, hi = chunks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if chunks[mid].base <= start { lo = mid } else { hi = mid - 1 }
        }
        let c = chunks[lo]
        return UnsafeRawBufferPointer(start: c.ptr + (start - c.base), count: count)
    }
}

/// An immutable view of the document at one moment. Cheap to take (arrays are
/// copy-on-write) and safe to read from a background thread, so search, save
/// and formatting never block editing.
public struct TextSnapshot: @unchecked Sendable {
    public let pieces: [Piece]
    let starts: [Int]
    public let length: Int
    let original: MappedFile
    let add: AddView
    /// Document version this snapshot was taken at.
    public let version: Int
    /// Undo state this snapshot corresponds to (for marking it saved).
    public let stateID: Int

    func pieceIndex(containing offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func bytes(of p: Piece, _ s: Int, _ e: Int) -> UnsafeRawBufferPointer {
        switch p.source {
        case .original: return original.bytes(p.start + s..<p.start + e)
        case .added: return add.bytes(p.start + s, e - s)
        }
    }

    /// Calls `body` with zero-copy buffers covering `range`, in order, with
    /// each buffer's document offset. Return false from `body` to stop.
    public func forEachChunk(in range: Range<Int>, _ body: (UnsafeRawBufferPointer, Int) -> Bool) {
        let lo = max(0, range.lowerBound), hi = min(length, range.upperBound)
        guard lo < hi, !pieces.isEmpty else { return }
        var i = pieceIndex(containing: lo)
        while i < pieces.count {
            let pos = starts[i], p = pieces[i]
            if pos >= hi { break }
            let s = max(lo, pos) - pos, e = min(hi, pos + p.length) - pos
            if e > s, !body(bytes(of: p, s, e), pos + s) { return }
            i += 1
        }
    }

    public func forEachChunkReversed(in range: Range<Int>, _ body: (UnsafeRawBufferPointer, Int) -> Bool) {
        let lo = max(0, range.lowerBound), hi = min(length, range.upperBound)
        guard lo < hi, !pieces.isEmpty else { return }
        var i = pieceIndex(containing: hi - 1)
        while i >= 0 {
            let pos = starts[i], p = pieces[i]
            if pos + p.length <= lo { break }
            let s = max(lo, pos) - pos, e = min(hi, pos + p.length) - pos
            if e > s, !body(bytes(of: p, s, e), pos + s) { return }
            i -= 1
        }
    }

    /// A snapshot of just `range` (offsets start at 0), for running the
    /// streaming formatters and tools on a selection.
    public func slice(_ range: Range<Int>) -> TextSnapshot {
        let lo = max(0, range.lowerBound), hi = min(length, range.upperBound)
        var ps: [Piece] = []
        var ss: [Int] = []
        var pos = 0
        if lo < hi {
            var i = pieceIndex(containing: lo)
            while i < pieces.count && starts[i] < hi {
                let p = pieces[i], st = starts[i]
                let s = max(lo, st) - st, e = min(hi, st + p.length) - st
                if e > s {
                    ps.append(Piece(source: p.source, start: p.start + s, length: e - s))
                    ss.append(pos); pos += e - s
                }
                i += 1
            }
        }
        return TextSnapshot(pieces: ps, starts: ss, length: pos, original: original, add: add,
                            version: version, stateID: stateID)
    }

    /// Copies `range` out. Intended for modest sizes.
    public func read(_ range: Range<Int>) -> [UInt8] {
        let lo = max(0, range.lowerBound), hi = min(length, range.upperBound)
        guard lo < hi else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(hi - lo)
        forEachChunk(in: lo..<hi) { buf, _ in out.append(contentsOf: buf); return true }
        return out
    }

    public func byte(at offset: Int) -> UInt8? {
        guard offset >= 0 && offset < length else { return nil }
        let i = pieceIndex(containing: offset)
        return bytes(of: pieces[i], offset - starts[i], offset - starts[i] + 1).first
    }

    /// Zero-copy if `range` lies inside one piece, otherwise copies.
    public func withContiguousBytes<R>(_ range: Range<Int>, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let lo = max(0, range.lowerBound), hi = min(length, range.upperBound)
        if lo < hi {
            let i = pieceIndex(containing: lo)
            if hi <= starts[i] + pieces[i].length {
                return try body(bytes(of: pieces[i], lo - starts[i], hi - starts[i]))
            }
        }
        let copy = read(lo..<hi)
        return try copy.withUnsafeBytes { try body($0) }
    }

    public func firstNewline(in range: Range<Int>) -> Int? {
        var found: Int?
        forEachChunk(in: range) { buf, off in
            guard let base = buf.baseAddress, let hit = memchr(base, 0x0A, buf.count) else { return true }
            found = off + (UnsafeRawPointer(hit) - base)
            return false
        }
        return found
    }

    public func lastNewline(in range: Range<Int>) -> Int? {
        var found: Int?
        forEachChunkReversed(in: range) { buf, off in
            guard let base = buf.baseAddress else { return true }
            let p = base.assumingMemoryBound(to: UInt8.self)
            var i = buf.count - 1
            while i >= 0 {
                if p[i] == 0x0A { found = off + i; return false }
                i -= 1
            }
            return true
        }
        return found
    }
}

/// Piece-table text storage: the classic structure for editing files far
/// larger than RAM. The original file is never copied; edits only add small
/// pieces. Undo records the pieces each edit replaced, so memory grows with
/// the size of the edits, not with the number of pieces.
public final class PieceTable {
    public private(set) var original: MappedFile
    let add = AddBuffer()
    private var addView = AddView(chunks: [])
    public private(set) var pieces: [Piece]
    private var starts: [Int]
    public private(set) var length: Int
    /// Bumped on every change; lets caches and background jobs detect edits.
    public private(set) var version = 0

    /// One primitive change: `pieces[index..<index+old.count]` became `new`.
    struct Op { var index: Int; var old: [Piece]; var new: [Piece] }
    struct Group {
        var ops: [Op]
        var before: [Range<Int>]
        var after: [Range<Int>]
        var name: String
        var id: Int
    }
    public enum Coalesce: Equatable { case none, typing, deleteBackward, deleteForward }

    private var undoStack: [Group] = []
    private var redoStack: [Group] = []
    private var openGroup: Group?
    private var openDepth = 0
    private var nextGroupID = 1
    private var savedID = 0
    private var coalesceKind: Coalesce = .none
    private var coalescePoint: Int?

    public init(original: MappedFile, range: Range<Int>? = nil) {
        self.original = original
        let r = range ?? 0..<original.size
        self.length = r.count
        self.pieces = r.isEmpty ? [] : [Piece(source: .original, start: r.lowerBound, length: r.count)]
        self.starts = r.isEmpty ? [] : [0]
    }

    /// Restores a previously journaled state (crash recovery).
    public init(original: MappedFile, pieces: [Piece], addBytes: [UInt8], addStarts: [Int]) {
        self.original = original
        self.pieces = []
        self.starts = []
        self.length = 0
        var remap: [Int: Int] = [:]
        for (i, s) in addStarts.enumerated() {
            let next = i + 1 < addStarts.count ? addStarts[i + 1] : addBytes.count
            let v = addBytes.withUnsafeBytes { add.append(UnsafeRawBufferPointer(rebasing: $0[s..<next])) }
            remap[s] = v
        }
        var out: [Piece] = []
        for var p in pieces {
            if p.source == .added {
                // Journaled added pieces are expressed as offsets into addBytes.
                let seg = addStarts.last { $0 <= p.start } ?? 0
                p.start = remap[seg]! + (p.start - seg)
            }
            out.append(p)
        }
        self.pieces = out
        addView = add.view()
        rebuildStarts(from: 0)
        savedID = -1
    }

    public var isModified: Bool { currentID != savedID }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }
    private var currentID: Int { undoStack.last?.id ?? 0 }

    /// Marks the current state as the one on disk.
    public func markSaved() { savedID = currentID; breakCoalescing() }
    /// Marks the state a snapshot was taken at as the one on disk (edits made
    /// while a background save ran keep the document modified).
    public func markSaved(stateID: Int) { savedID = stateID; breakCoalescing() }
    /// Makes the document report modified until the next save (used after a
    /// non-undoable rewrite).
    public func markUnsaved() { savedID = -1 }
    public func breakCoalescing() { coalesceKind = .none; coalescePoint = nil }

    public func snapshot() -> TextSnapshot {
        TextSnapshot(pieces: pieces, starts: starts, length: length, original: original,
                     add: addView, version: version, stateID: currentID)
    }

    // MARK: Lookup

    func pieceIndex(containing offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func rebuildStarts(from index: Int) {
        if starts.count > pieces.count { starts.removeLast(starts.count - pieces.count) }
        let from = min(index, starts.count)
        var pos = from > 0 ? starts[from - 1] + pieces[from - 1].length : 0
        for i in from..<pieces.count {
            if i < starts.count { starts[i] = pos } else { starts.append(pos) }
            pos += pieces[i].length
        }
        length = pos
    }

    func docStart(ofPiece i: Int) -> Int { starts[i] }

    /// Stores a newline count computed later (see TextDocument).
    func setNewlines(_ n: Int, at i: Int) { pieces[i].newlines = n }

    func addBytes(_ p: Piece) -> UnsafeRawBufferPointer { addView.bytes(p.start, p.length) }

    // MARK: Groups

    /// Groups every change until the matching `endGroup` into one undo step.
    public func beginGroup(_ name: String, selection: [Range<Int>]) {
        if openDepth == 0 {
            openGroup = Group(ops: [], before: selection, after: selection, name: name, id: 0)
            breakCoalescing()
        }
        openDepth += 1
    }

    public func endGroup(selection: [Range<Int>]) {
        openDepth -= 1
        guard openDepth == 0, var g = openGroup else { return }
        openGroup = nil
        guard !g.ops.isEmpty else { return }
        g.after = selection
        g.id = nextGroupID; nextGroupID += 1
        undoStack.append(g)
        redoStack.removeAll()
    }

    private func record(_ op: Op, range: Range<Int>, inserted: Int, coalesce: Coalesce, name: String) {
        if openGroup != nil { openGroup!.ops.append(op); return }
        let caretAfter = range.lowerBound + inserted
        if coalesce != .none, coalesce == coalesceKind, let point = coalescePoint, !undoStack.isEmpty,
           undoStack[undoStack.count - 1].id != savedID {
            let fits: Bool
            switch coalesce {
            case .typing: fits = range.isEmpty && range.lowerBound == point
            case .deleteBackward: fits = range.upperBound == point && inserted == 0
            case .deleteForward: fits = range.lowerBound == point && inserted == 0
            case .none: fits = false
            }
            if fits {
                let i = undoStack.count - 1
                if let b = undoStack[i].before.first {
                    if coalesce == .deleteBackward { undoStack[i].before = [range.lowerBound..<b.upperBound] }
                    if coalesce == .deleteForward { undoStack[i].before = [b.lowerBound..<b.upperBound + range.count] }
                }
                undoStack[undoStack.count - 1].ops.append(op)
                undoStack[undoStack.count - 1].after = [caretAfter..<caretAfter]
                coalescePoint = caretAfter
                redoStack.removeAll()
                return
            }
        }
        let before: [Range<Int>] = coalesce == .typing || range.isEmpty ? [range.lowerBound..<range.lowerBound] : [range]
        undoStack.append(Group(ops: [op], before: before, after: [caretAfter..<caretAfter],
                               name: name, id: nextGroupID))
        nextGroupID += 1
        redoStack.removeAll()
        coalesceKind = coalesce
        coalescePoint = coalesce == .none ? nil : caretAfter
    }

    // MARK: Editing

    /// Replace `range` with `bytes`. `coalesce` merges consecutive typing or
    /// deleting into a single undo step.
    public func replace(_ range: Range<Int>, with bytes: [UInt8], coalesce: Coalesce = .none,
                        name: String = "Typing") {
        precondition(range.lowerBound >= 0 && range.upperBound <= length, "range out of bounds")
        if range.isEmpty && bytes.isEmpty { return }
        let lo = range.lowerBound, hi = range.upperBound

        var a = lo < length ? pieceIndex(containing: lo) : pieces.count
        var b = hi > lo ? pieceIndex(containing: hi - 1) + 1 : a
        if a < pieces.count && starts[a] < lo && b == a { b = a + 1 }

        var new: [Piece] = []
        if a < pieces.count && starts[a] < lo {
            let p = pieces[a]
            new.append(split(p, 0, lo - starts[a]))
        }
        if !bytes.isEmpty {
            let addEnd = add.end
            let v = bytes.withUnsafeBytes { add.append($0) }
            addView = add.view()
            let n = bytes.withUnsafeBytes { LineIndex.countNewlines($0) }
            if new.isEmpty, a > 0, pieces[a - 1].source == .added,
               pieces[a - 1].start + pieces[a - 1].length == addEnd, v == addEnd {
                // Typing: extend the previous added piece in place.
                a -= 1
                var prev = pieces[a]
                prev.length += bytes.count
                prev.newlines = prev.newlines >= 0 ? prev.newlines + n : -1
                new.append(prev)
            } else {
                new.append(Piece(source: .added, start: v, length: bytes.count, newlines: n))
            }
        }
        if b > 0 && b - 1 < pieces.count && b - 1 >= a {
            let p = pieces[b - 1], ps = starts[b - 1]
            if ps + p.length > hi {
                let from = max(hi, ps) - ps
                new.append(split(p, from, p.length))
            }
        }
        let op = Op(index: a, old: Array(pieces[a..<b]), new: new)
        apply(op.index, op.old.count, op.new)
        record(op, range: range, inserted: bytes.count, coalesce: coalesce, name: name)
    }

    /// Applies many non-overlapping edits (sorted by position) in one pass and
    /// one undo step. Cost is O(pieces + edits), so Replace All with a million
    /// matches stays fast.
    public func applyEdits(_ edits: [(Range<Int>, [UInt8])], name: String,
                           before: [Range<Int>], after: [Range<Int>]) {
        guard !edits.isEmpty else { return }
        var out: [Piece] = []
        out.reserveCapacity(pieces.count + edits.count * 2)
        var cursor = 0          // document offset copied so far
        var pi = 0              // piece index
        var lastBytes: [UInt8]? = nil
        var lastPiece: Piece? = nil

        func copyUpTo(_ target: Int) {
            while cursor < target && pi < pieces.count {
                let ps = starts[pi], p = pieces[pi]
                let pe = ps + p.length
                if pe <= cursor { pi += 1; continue }
                let s = cursor - ps, e = min(target, pe) - ps
                out.append(s == 0 && e == p.length ? p : split(p, s, e))
                cursor = ps + e
                if cursor >= pe { pi += 1 }
            }
        }
        for (r, bytes) in edits {
            precondition(r.lowerBound >= cursor && r.upperBound <= length, "edits must be sorted and in range")
            copyUpTo(r.lowerBound)
            if !bytes.isEmpty {
                if let lb = lastBytes, let lp = lastPiece, lb == bytes {
                    out.append(lp)
                } else {
                    let v = bytes.withUnsafeBytes { add.append($0) }
                    addView = add.view()
                    let n = bytes.withUnsafeBytes { LineIndex.countNewlines($0) }
                    let piece = Piece(source: .added, start: v, length: bytes.count, newlines: n)
                    out.append(piece)
                    lastBytes = bytes; lastPiece = piece
                }
            }
            // Skip the replaced range.
            cursor = r.upperBound
            while pi < pieces.count && starts[pi] + pieces[pi].length <= cursor { pi += 1 }
        }
        copyUpTo(length)
        let op = Op(index: 0, old: pieces, new: out)
        apply(0, pieces.count, out)
        let g = Group(ops: [op], before: before, after: after, name: name, id: nextGroupID)
        nextGroupID += 1
        if openGroup != nil { openGroup!.ops.append(op) } else {
            undoStack.append(g)
            redoStack.removeAll()
        }
        breakCoalescing()
    }

    private func split(_ p: Piece, _ s: Int, _ e: Int) -> Piece {
        var q = Piece(source: p.source, start: p.start + s, length: e - s)
        if p.source == .added {
            q.newlines = LineIndex.countNewlines(addView.bytes(q.start, q.length))
        } else if s == 0 && e == p.length {
            q.newlines = p.newlines
        }
        return q
    }

    private func apply(_ index: Int, _ removeCount: Int, _ new: [Piece]) {
        pieces.replaceSubrange(index..<index + removeCount, with: new)
        starts.replaceSubrange(index..<min(starts.count, index + removeCount),
                               with: repeatElement(0, count: new.count))
        rebuildStarts(from: index)
        version += 1
    }

    public func insert(_ bytes: [UInt8], at offset: Int, coalesce: Coalesce = .none) {
        replace(offset..<offset, with: bytes, coalesce: coalesce)
    }

    public func delete(_ range: Range<Int>) { replace(range, with: []) }

    /// Returns the selection to restore, or nil if nothing to undo.
    @discardableResult
    public func undo() -> [Range<Int>]? {
        guard let g = undoStack.popLast() else { return nil }
        for op in g.ops.reversed() { apply(op.index, op.new.count, op.old) }
        redoStack.append(g)
        breakCoalescing()
        return g.before
    }

    @discardableResult
    public func redo() -> [Range<Int>]? {
        guard let g = redoStack.popLast() else { return nil }
        for op in g.ops { apply(op.index, op.old.count, op.new) }
        undoStack.append(g)
        breakCoalescing()
        return g.after
    }

    /// Drops all history (after a non-undoable rewrite of the whole file).
    public func clearHistory() {
        undoStack.removeAll(); redoStack.removeAll(); breakCoalescing()
    }

    // MARK: Reading (main thread)

    public func forEachChunk(in range: Range<Int>, _ body: (UnsafeRawBufferPointer, Int) -> Bool) {
        snapshot().forEachChunk(in: range, body)
    }
    public func forEachChunkReversed(in range: Range<Int>, _ body: (UnsafeRawBufferPointer, Int) -> Bool) {
        snapshot().forEachChunkReversed(in: range, body)
    }
    public func read(_ range: Range<Int>) -> [UInt8] { snapshot().read(range) }
    public func withContiguousBytes<R>(_ range: Range<Int>, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try snapshot().withContiguousBytes(range, body)
    }

    /// Pieces as (piece, docOffset), for line-number math.
    func spans() -> [(Piece, Int)] { Array(zip(pieces, starts)) }

    func withAddedBytes<R>(_ range: Range<Int>, _ body: (UnsafeRawBufferPointer) -> R) -> R {
        body(addView.bytes(range.lowerBound, range.count))
    }

    // MARK: Journal (crash recovery)

    /// The added bytes referenced by the current pieces, compacted, plus the
    /// pieces rewritten to point into that compacted buffer.
    public func journal() -> (pieces: [Piece], addBytes: [UInt8], addStarts: [Int]) {
        var bytes: [UInt8] = []
        var starts: [Int] = []
        var out: [Piece] = []
        let view = add.view()
        for var p in pieces {
            if p.source == .added {
                starts.append(bytes.count)
                bytes.append(contentsOf: view.bytes(p.start, p.length))
                p.start = starts.last!
            }
            out.append(p)
        }
        return (out, bytes, starts)
    }
}
