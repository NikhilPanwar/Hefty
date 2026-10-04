import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Describes an edit so views can keep their offsets (scroll position,
/// carets, bookmarks) pointing at the same text.
public struct DocumentChange {
    /// Sorted (old range, inserted length) pairs; empty when `isReset`.
    public var edits: [(Range<Int>, Int)]
    /// The whole document changed shape (undo, redo, reload): clamp offsets.
    public var isReset: Bool

    public init(edits: [(Range<Int>, Int)], isReset: Bool) {
        self.edits = edits
        self.isReset = isReset
    }

    /// Maps an offset from before the change to after it.
    public func map(_ offset: Int, newLength: Int) -> Int {
        if isReset { return min(offset, newLength) }
        var delta = 0
        for (r, n) in edits {
            if offset < r.lowerBound { break }
            if offset >= r.upperBound { delta += n - r.count; continue }
            return r.lowerBound + delta + min(n, offset - r.lowerBound)
        }
        return max(0, min(newLength, offset + delta))
    }
}

/// The editor's model: a memory-mapped file + piece table for edits + a
/// background line index. Everything is addressed by *byte offset* (UTF-8),
/// so the view can open and scroll a 100 GB file before indexing finishes.
public final class TextDocument {
    /// The user's file, or nil for a new untitled document.
    public private(set) var url: URL?
    public var untitledName = "Untitled"
    /// What is actually mapped: an APFS clone of the file, a converted
    /// UTF-8 copy, or the file itself when neither is possible.
    public private(set) var file: MappedFile
    public private(set) var buffer: PieceTable
    public private(set) var lineIndex: LineIndex
    public var language: Language
    /// True when `language` came from the extension (so Save As may update it).
    public var languageIsAutomatic = true
    public private(set) var encoding: TextEncoding
    /// Line-ending style; new lines typed use it.
    public var lineEnding: LineEnding
    /// Normalize every line break to `lineEnding` when saving.
    public var convertLineEndingsOnSave = false
    public private(set) var mixedLineEndings = false
    public var isReadOnly = false
    /// Bytes of the backing file before document offset 0 (a UTF-8 BOM).
    public private(set) var headerLength = 0
    /// Size and modification date of the file when it was opened or saved,
    /// to tell our own saves from changes made by other apps.
    public private(set) var diskStamp: (size: Int, mtime: TimeInterval, inode: UInt64)?
    private var tempDir: URL?

    private var observers: [UUID: (DocumentChange) -> Void] = [:]

    /// Lines longer than this are displayed in segments (a 5 GB single-line
    /// JSON must not be laid out as one line).
    public static let maxLineBytes = 16 * 1024

    public var displayName: String { url?.lastPathComponent ?? untitledName }
    public var length: Int { buffer.length }
    public var isModified: Bool { buffer.isModified }
    /// In-memory bytes for a line break typed by the user.
    public var newlineBytes: [UInt8] { lineEnding == .crlf ? [0x0D, 0x0A] : [0x0A] }

    // MARK: Opening

    /// Opens `url` for editing. For anything but UTF-8 (and for classic-Mac CR
    /// line endings) the text is converted to a temporary UTF-8 copy first,
    /// which takes time proportional to the file: call off the main thread.
    public init(url: URL, encoding forced: TextEncoding? = nil, fallback: TextEncoding = .windows1252,
                progress: ((Double) -> Void)? = nil, isCancelled: (() -> Bool)? = nil) throws {
        let direct = try MappedFile(url: url)
        self.url = url
        self.language = Language(fileExtension: url.pathExtension)
        var enc = forced ?? EncodingDetector.detect(direct, fallback: fallback)
        var backing = direct
        var temp: URL?
        var header = 0

        if enc.isUTF8 {
            let hasBOM = direct.size >= 3 && Array(direct.bytes(0..<3)) == [0xEF, 0xBB, 0xBF]
            if hasBOM { header = 3; enc = .utf8BOM } else if forced == nil { enc = .utf8 }
            if let clone = Self.makeClone(of: url) {
                temp = clone.deletingLastPathComponent()
                backing = (try? MappedFile(url: clone)) ?? direct
            }
        } else {
            let dir = try Self.makeTempDir(for: url)
            temp = dir
            let out = dir.appendingPathComponent("converted.txt")
            try Self.transcode(direct, skip: enc.bom.count > 0 && direct.size >= enc.bom.count
                                && Array(direct.bytes(0..<enc.bom.count)) == enc.bom ? enc.bom.count : 0,
                               from: enc, to: out, progress: progress, isCancelled: isCancelled)
            backing = try MappedFile(url: out)
        }

        let sample = backing.bytes(header..<min(backing.size, header + (1 << 20)))
        var (ending, mixed) = EncodingDetector.lineEnding(in: sample)
        if ending == .cr {
            // Classic Mac line endings: convert to LF in memory, back on save.
            let dir = try temp ?? Self.makeTempDir(for: url)
            temp = dir
            let out = dir.appendingPathComponent("lf.txt")
            try Self.convertLineEndings(backing, skip: header, to: out, progress: progress, isCancelled: isCancelled)
            backing = try MappedFile(url: out)
            header = 0
            mixed = false
        }
        self.file = backing
        self.tempDir = temp
        self.headerLength = header
        self.encoding = enc
        self.lineEnding = ending
        self.mixedLineEndings = mixed
        self.buffer = PieceTable(original: backing, range: header..<backing.size)
        self.lineIndex = LineIndex(file: backing)
        self.diskStamp = Self.stamp(of: url)
        self.isReadOnly = access(url.path, W_OK) != 0
    }

    /// A new, empty, untitled document.
    public init(untitledName: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Hefty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let empty = dir.appendingPathComponent("empty.txt")
        FileManager.default.createFile(atPath: empty.path, contents: nil)
        let f = try MappedFile(url: empty)
        self.url = nil
        self.untitledName = untitledName
        self.file = f
        self.tempDir = dir
        self.buffer = PieceTable(original: f)
        self.lineIndex = LineIndex(file: f)
        self.language = .plain
        self.encoding = .utf8
        self.lineEnding = .lf
    }

    /// A new untitled document whose initial contents are `file` (the output
    /// of Filter Lines, Extract Column…). Takes ownership of `file`.
    public init(untitledName: String, contentsOf file: URL, language: Language = .plain) throws {
        let f = try MappedFile(url: file)
        self.url = nil
        self.untitledName = untitledName
        self.file = f
        self.tempDir = file.deletingLastPathComponent()
        self.buffer = PieceTable(original: f)
        self.lineIndex = LineIndex(file: f)
        self.language = language
        self.encoding = .utf8
        let (ending, mixed) = EncodingDetector.lineEnding(in: f.bytes(0..<min(f.size, 1 << 20)))
        self.lineEnding = ending == .cr ? .lf : ending
        self.mixedLineEndings = mixed
        if f.size > 0 { buffer.markUnsaved() }
    }

    /// Chooses the encoding the next save writes (marks the document edited).
    public func setEncoding(_ e: TextEncoding) {
        guard e != encoding else { return }
        encoding = e
        buffer.markUnsaved()
        notify(DocumentChange(edits: [], isReset: false))
    }

    /// Chooses the line-ending style; existing line breaks are converted
    /// when saving (marks the document edited).
    public func setLineEnding(_ le: LineEnding) {
        guard le != lineEnding || mixedLineEndings else { return }
        lineEnding = le
        convertLineEndingsOnSave = true
        mixedLineEndings = false
        buffer.markUnsaved()
        notify(DocumentChange(edits: [], isReset: false))
    }

    deinit {
        lineIndex.cancel()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    static func stamp(of url: URL) -> (Int, TimeInterval, UInt64)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let t = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
        return (Int(st.st_size), t, UInt64(st.st_ino))
    }

    /// True if the file on disk is no longer the one we opened or last saved.
    public var changedOnDisk: Bool {
        guard let url, let old = diskStamp else { return false }
        guard let now = Self.stamp(of: url) else { return true }
        return now.0 != old.size || now.1 != old.mtime || now.2 != old.inode
    }

    public func refreshDiskStamp() { if let url { diskStamp = Self.stamp(of: url) } }

    static func makeTempDir(for url: URL) throws -> URL {
        if let d = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: url, create: true) { return d }
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("Hefty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// An instant copy-on-write clone (APFS), so other apps changing or
    /// truncating the file can never pull bytes out from under the editor.
    static func makeClone(of url: URL) -> URL? {
        guard let dir = try? makeTempDir(for: url) else { return nil }
        let dst = dir.appendingPathComponent("clone-" + url.lastPathComponent)
        if clonefile(url.path, dst.path, 0) == 0 { return dst }
        try? FileManager.default.removeItem(at: dir)
        return nil
    }

    static func transcode(_ src: MappedFile, skip: Int, from enc: TextEncoding, to out: URL,
                          progress: ((Double) -> Void)?, isCancelled: (() -> Bool)?) throws {
        let t = try Transcoder(from: enc.id, to: "UTF-8", substituteInvalid: true)
        let sink = try FileSink(url: out)
        let total = max(1, src.size)
        var pos = skip
        let step = 8 << 20
        src.advise(sequential: true)
        while pos < src.size {
            if isCancelled?() == true { throw CocoaError(.userCancelled) }
            let end = min(src.size, pos + step)
            try t.convert(src.bytes(pos..<end), final: end == src.size) { try sink.write($0) }
            pos = end
            progress?(Double(pos) / Double(total))
        }
        if src.size <= skip { try t.convert(UnsafeRawBufferPointer(start: nil, count: 0), final: true) { try sink.write($0) } }
        try sink.close()
    }

    static func convertLineEndings(_ src: MappedFile, skip: Int, to out: URL,
                                   progress: ((Double) -> Void)?, isCancelled: (() -> Bool)?) throws {
        var c = LineEndingConverter(target: .lf)
        let sink = try FileSink(url: out)
        var pos = skip
        let step = 8 << 20
        while pos < src.size {
            if isCancelled?() == true { throw CocoaError(.userCancelled) }
            let end = min(src.size, pos + step)
            try c.convert(src.bytes(pos..<end), final: end == src.size) { try sink.write($0) }
            pos = end
            progress?(Double(pos) / Double(max(1, src.size)))
        }
        try sink.close()
    }

    /// Takes over the contents of `other` (a fresh open of the same file):
    /// used by Revert, Reopen with Encoding and reloading after outside changes.
    public func adopt(_ other: TextDocument) {
        lineIndex.cancel()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        url = other.url
        file = other.file
        buffer = other.buffer
        lineIndex = other.lineIndex
        encoding = other.encoding
        lineEnding = other.lineEnding
        mixedLineEndings = other.mixedLineEndings
        headerLength = other.headerLength
        diskStamp = other.diskStamp
        isReadOnly = other.isReadOnly
        convertLineEndingsOnSave = false
        tempDir = other.tempDir
        other.tempDir = nil
        notify(DocumentChange(edits: [], isReset: true))
    }

    /// For a file that only grew (a log being appended to): keep the line
    /// index for the old part. Only valid while the document is unmodified.
    public func adoptAppended(_ other: TextDocument) {
        let old = lineIndex
        old.cancel()
        adopt(other)
        lineIndex = LineIndex(file: file, continuing: old)
    }

    /// Replaces the whole document with the contents of `tempURL` (output of
    /// a streamed operation such as Replace All on a huge file or sorting).
    /// Not undoable; the document stays modified until saved.
    public func replaceContents(withFile tempURL: URL) throws {
        let f = try MappedFile(url: tempURL)
        lineIndex.cancel()
        // Keep the new file inside our temp folder so it is cleaned up.
        if tempDir == nil, let u = url { tempDir = try? Self.makeTempDir(for: u) }
        file = f
        buffer = PieceTable(original: f)
        buffer.markUnsaved()
        lineIndex = LineIndex(file: f)
        headerLength = 0
        notify(DocumentChange(edits: [], isReset: true))
    }

    /// Re-applies journaled edits (crash recovery).
    public func restoreJournal(pieces: [Piece], addBytes: [UInt8], addStarts: [Int]) {
        buffer = PieceTable(original: file, pieces: pieces, addBytes: addBytes, addStarts: addStarts)
        notify(DocumentChange(edits: [], isReset: true))
    }

    /// A scratch file next to our other temporary files (same volume as the
    /// document when possible, so renames are cheap).
    public func makeScratchURL(_ name: String) throws -> URL {
        if tempDir == nil { tempDir = try Self.makeTempDir(for: url ?? FileManager.default.temporaryDirectory) }
        return tempDir!.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    /// Starts indexing on a background queue.
    public func startIndexing(onProgress: @escaping (Double) -> Void) {
        let index = lineIndex
        DispatchQueue.global(qos: .utility).async {
            index.build(onProgress: onProgress)
        }
    }

    // MARK: Observers

    @discardableResult
    public func addObserver(_ body: @escaping (DocumentChange) -> Void) -> UUID {
        let id = UUID(); observers[id] = body; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil }
    private func notify(_ c: DocumentChange) { for o in observers.values { o(c) } }

    // MARK: Editing

    public func replace(_ range: Range<Int>, with bytes: [UInt8],
                        coalesce: PieceTable.Coalesce = .none, name: String = "Typing") {
        buffer.replace(range, with: bytes, coalesce: coalesce, name: name)
        notify(DocumentChange(edits: [(range, bytes.count)], isReset: false))
    }

    /// Many edits as one undo step (multi-cursor typing, Replace All, indent).
    public func applyEdits(_ edits: [(Range<Int>, [UInt8])], name: String,
                           before: [Range<Int>], after: [Range<Int>]) {
        guard !edits.isEmpty else { return }
        buffer.applyEdits(edits, name: name, before: before, after: after)
        notify(DocumentChange(edits: edits.map { ($0.0, $0.1.count) }, isReset: false))
    }

    public func undo() -> [Range<Int>]? {
        let r = buffer.undo()
        if r != nil { notify(DocumentChange(edits: [], isReset: true)) }
        return r
    }

    public func redo() -> [Range<Int>]? {
        let r = buffer.redo()
        if r != nil { notify(DocumentChange(edits: [], isReset: true)) }
        return r
    }

    public func snapshot() -> TextSnapshot { buffer.snapshot() }

    // MARK: Line navigation (byte-based, index-free)

    // Display lines end at a newline, or, for lines longer than `maxLineBytes`,
    // at "segment boundaries": absolute offsets g = k * maxLineBytes with no
    // newline in [g - maxLineBytes, g). Both functions below decide boundaries
    // from nearby bytes only, so they agree without ever scanning back to the
    // real start of a multi-GB line.

    /// Start of the display line containing `offset`.
    public func lineStart(containing offset: Int) -> Int {
        let m = Self.maxLineBytes
        let x = min(max(0, offset), length)
        if x == 0 { return 0 }
        let g = (x / m) * m
        if let nl = lastNewline(in: g..<x) { return nl + 1 }
        if g == 0 { return 0 }
        if let nl = lastNewline(in: max(0, g - m)..<g) { return nl + 1 }
        return g
    }

    /// End of the display line starting at `start` (excluding the newline and
    /// any CR) and the start of the next one (== `length` at the end).
    public func nextLineStart(after start: Int) -> (contentEnd: Int, next: Int) {
        let m = Self.maxLineBytes
        let scanEnd = min(length, start + 2 * m)
        let hit = firstNewline(in: start..<scanEnd)
        let lineEnd = hit ?? scanEnd
        var g = (start / m + 1) * m
        while (hit != nil ? g < lineEnd : g <= lineEnd) {
            if g < length && lastNewline(in: (g - m)..<g) == nil { return (g, g) }
            g += m
        }
        if let h = hit {
            let contentEnd = (h > start && byte(at: h - 1) == 0x0D) ? h - 1 : h   // CRLF
            return (contentEnd, h + 1)
        }
        return (scanEnd, scanEnd)
    }

    /// True if `start` begins a real line (not a continuation segment of a
    /// very long line).
    public func isRealLineStart(_ start: Int) -> Bool {
        start == 0 || byte(at: start - 1) == 0x0A
    }

    /// Start and content end of the *logical* line containing `offset`,
    /// limited to `limit` bytes either way.
    public func logicalLine(containing offset: Int, limit: Int = 1 << 20) -> Range<Int> {
        let lo = max(0, offset - limit)
        let s = lastNewline(in: lo..<min(offset, length)).map { $0 + 1 } ?? lo
        let e = firstNewline(in: offset..<min(length, offset + limit)) ?? min(length, offset + limit)
        let ce = e > s && byte(at: e - 1) == 0x0D ? e - 1 : e
        return s..<max(s, ce)
    }

    public func firstNewline(in range: Range<Int>) -> Int? { buffer.snapshot().firstNewline(in: range) }
    public func lastNewline(in range: Range<Int>) -> Int? { buffer.snapshot().lastNewline(in: range) }

    /// Bytes of the display line starting at `start`, without the newline.
    public func line(at start: Int) -> (bytes: [UInt8], next: Int) {
        let (end, next) = nextLineStart(after: start)
        return (buffer.read(start..<end), next)
    }

    public func byte(at offset: Int) -> UInt8? { buffer.snapshot().byte(at: offset) }

    /// Move `count` display lines from the line starting at `start`
    /// (negative = up). Cost is O(|count| * line length).
    public func moveLines(from start: Int, by count: Int) -> Int {
        var pos = lineStart(containing: start)
        if count > 0 {
            for _ in 0..<count {
                let n = nextLineStart(after: pos).next
                if n >= length && !(n == length && byte(at: length - 1) == 0x0A) { break }
                if n > length { break }
                pos = n
            }
        } else if count < 0 {
            for _ in 0..<(-count) {
                if pos == 0 { break }
                pos = lineStart(containing: pos - 1)
            }
        }
        return pos
    }

    // MARK: Line numbers (need the index)

    /// Newline count of piece `i`, computing and caching it if needed.
    private func newlines(ofPiece i: Int) -> Int? {
        let p = buffer.pieces[i]
        if p.newlines >= 0 { return p.newlines }
        switch p.source {
        case .added:
            let n = LineIndex.countNewlines(buffer.addBytes(p))
            buffer.setNewlines(n, at: i)
            return n
        case .original:
            guard let a = lineIndex.line(containing: p.start),
                  let b = lineIndex.line(containing: p.start + p.length) else { return nil }
            buffer.setNewlines(b - a, at: i)
            return b - a
        }
    }

    /// 0-based line number of `offset` in the *current* (edited) document, or
    /// nil while the index has not reached that far.
    public func lineNumber(at offset: Int) -> Int? {
        let x = min(max(0, offset), length)
        if x == 0 || buffer.pieces.isEmpty { return 0 }
        let i = buffer.pieceIndex(containing: x - 1)
        var line = 0
        for j in 0..<i {
            guard let n = newlines(ofPiece: j) else { return nil }
            line += n
        }
        let p = buffer.pieces[i]
        let take = x - buffer.docStart(ofPiece: i)
        if take == p.length, let n = newlines(ofPiece: i) { return line + n }
        switch p.source {
        case .original:
            guard let a = lineIndex.line(containing: p.start),
                  let b = lineIndex.line(containing: p.start + take) else { return nil }
            return line + (b - a)
        case .added:
            let bytes = buffer.addBytes(p)
            return line + LineIndex.countNewlines(UnsafeRawBufferPointer(rebasing: bytes[0..<take]))
        }
    }

    /// Byte offset of 0-based `line` in the current document, or nil if the
    /// index has not reached it (or it does not exist).
    public func offset(ofLine target: Int) -> Int? {
        if target <= 0 { return 0 }
        var line = 0
        for i in 0..<buffer.pieces.count {
            let p = buffer.pieces[i]
            let docPos = buffer.docStart(ofPiece: i)
            guard let n = newlines(ofPiece: i) else { return nil }
            if line + n >= target {
                switch p.source {
                case .original:
                    guard let a = lineIndex.line(containing: p.start),
                          let off = lineIndex.offset(ofLine: a + (target - line)) else { return nil }
                    return docPos + (off - p.start)
                case .added:
                    let bytes = buffer.addBytes(p)
                    for k in 0..<bytes.count where bytes[k] == 0x0A {
                        line += 1
                        if line == target { return docPos + k + 1 }
                    }
                    return nil
                }
            }
            line += n
        }
        return nil
    }

    /// Line count of the current (edited) document, once indexed.
    public var lineCount: Int? {
        guard lineIndex.isComplete, let n = lineNumber(at: length) else { return nil }
        return length == 0 || byte(at: length - 1) == 0x0A ? max(1, n) : n + 1
    }

    // MARK: Saving

    /// Streams `snapshot` to `dest` atomically (temp file + rename), converting
    /// line endings and encoding as requested, and keeping the destination's
    /// permissions, ACLs and extended attributes. Symlinks are followed, so
    /// the link stays a link. Safe on a background thread.
    public static func write(_ snapshot: TextSnapshot, to dest: URL, encoding: TextEncoding,
                             lineEnding: LineEnding?, progress: ((Double) -> Void)? = nil) throws {
        let target = dest.resolvingSymlinksInPath()
        let dir = target.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(target.lastPathComponent).bfe-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).tmp")
        let sink = try FileSink(url: tmp)
        var ok = false
        defer { if !ok { try? sink.close(); unlink(tmp.path) } }

        let encoder = encoding.isUTF8 ? nil : try Transcoder(from: "UTF-8", to: encoding.id, substituteInvalid: false)
        var converter = lineEnding.map { LineEndingConverter(target: $0) }
        if !encoding.bom.isEmpty { try encoding.bom.withUnsafeBytes { try sink.write($0) } }

        func encode(_ buf: UnsafeRawBufferPointer, final: Bool) throws {
            if let encoder { try encoder.convert(buf, final: final) { try sink.write($0) } }
            else { try sink.write(buf) }
        }
        func stage(_ buf: UnsafeRawBufferPointer, final: Bool) throws {
            if converter != nil { try converter!.convert(buf, final: final) { try encode($0, final: false) } }
            else { try encode(buf, final: false) }
            if final { try encode(UnsafeRawBufferPointer(start: nil, count: 0), final: true) }
        }

        var written = 0
        let total = max(1, snapshot.length)
        var failure: Error?
        snapshot.forEachChunk(in: 0..<snapshot.length) { buf, _ in
            var off = 0
            while off < buf.count {
                let n = min(8 << 20, buf.count - off)
                do { try stage(UnsafeRawBufferPointer(rebasing: buf[off..<off + n]), final: false) }
                catch { failure = error; return false }
                off += n
                written += n
                progress?(Double(written) / Double(total))
            }
            return true
        }
        if let failure { throw failure }
        try stage(UnsafeRawBufferPointer(start: nil, count: 0), final: true)
        try sink.close(sync: true)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = copyfile(target.path, tmp.path, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR))
        }
        if rename(tmp.path, target.path) != 0 { throw BigFileError.write(target.path, errno) }
        ok = true
    }

    /// Records a finished save of `snapshot` to `dest`.
    public func didSave(_ snapshot: TextSnapshot, to dest: URL, encoding: TextEncoding) {
        if url != dest, languageIsAutomatic {
            let l = Language(fileExtension: dest.pathExtension)
            if l != .plain || language == .plain { language = l }
        }
        url = dest
        self.encoding = encoding
        buffer.markSaved(stateID: snapshot.stateID)
        diskStamp = Self.stamp(of: dest)
        isReadOnly = access(dest.path, W_OK) != 0
    }

    /// Line-ending conversion to apply when saving, if any.
    public var saveLineEnding: LineEnding? {
        if lineEnding == .cr { return .cr }        // in memory it is LF
        return convertLineEndingsOnSave ? lineEnding : nil
    }

    /// Convenience for tests and scripts: synchronous save in place or to `newURL`.
    public func save(to newURL: URL? = nil, encoding: TextEncoding? = nil,
                     progress: ((Double) -> Void)? = nil) throws {
        guard let dest = newURL ?? url else { throw CocoaError(.fileNoSuchFile) }
        let snap = snapshot()
        let enc = encoding ?? self.encoding
        try Self.write(snap, to: dest, encoding: enc, lineEnding: saveLineEnding, progress: progress)
        didSave(snap, to: dest, encoding: enc)
    }
}

/// Buffered, write-only file used for streamed output.
public final class FileSink {
    private let fd: Int32
    private let path: String
    private var buf: [UInt8] = []
    private var closed = false
    public private(set) var bytesWritten = 0

    public init(url: URL) throws {
        path = url.path
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw BigFileError.write(url.path, errno) }
        buf.reserveCapacity(4 << 20)
    }
    deinit { if !closed { Darwin.close(fd) } }

    public func write(_ data: UnsafeRawBufferPointer) throws {
        guard data.count > 0 else { return }
        bytesWritten += data.count
        if buf.count + data.count > 4 << 20 { try flush() }
        if data.count >= 4 << 20 { try raw(data); return }
        buf.append(contentsOf: data)
    }
    public func write(_ bytes: [UInt8]) throws { try bytes.withUnsafeBytes { try write($0) } }

    private func flush() throws {
        guard !buf.isEmpty else { return }
        try buf.withUnsafeBytes { try raw($0) }
        buf.removeAll(keepingCapacity: true)
    }

    private func raw(_ data: UnsafeRawBufferPointer) throws {
        var off = 0
        while off < data.count {
            let r = Darwin.write(fd, data.baseAddress! + off, data.count - off)
            if r < 0 { if errno == EINTR { continue }; throw BigFileError.write(path, errno) }
            off += r
        }
    }

    public func close(sync: Bool = false) throws {
        guard !closed else { return }
        try flush()
        if sync && fsync(fd) != 0 { let e = errno; Darwin.close(fd); closed = true; throw BigFileError.write(path, e) }
        closed = true
        if Darwin.close(fd) != 0 { throw BigFileError.write(path, errno) }
    }
}
