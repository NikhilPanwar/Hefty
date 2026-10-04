import Foundation
import Testing
@testable import BigFileCore

struct BigFileCoreTests {
    private func tempFile(_ text: String, ext: String = "txt") throws -> URL {
        try tempFile(Data(text.utf8), ext: ext)
    }

    private func tempFile(_ data: Data, ext: String = "txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bfe-test-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    private func text(_ doc: TextDocument) -> String {
        String(decoding: doc.buffer.read(0..<doc.length), as: UTF8.self)
    }

    // MARK: Editing and undo

    @Test func pieceTableEditsAndUndo() throws {
        let doc = try TextDocument(url: tempFile("hello world"))
        doc.replace(5..<5, with: Array(",".utf8))
        #expect(text(doc) == "hello, world")
        doc.replace(0..<5, with: Array("HELLO".utf8))
        #expect(text(doc) == "HELLO, world")
        #expect(doc.undo() == [0..<5])
        #expect(text(doc) == "hello, world")
        doc.undo()
        #expect(text(doc) == "hello world")
        #expect(!doc.isModified)
        #expect(doc.redo() == [6..<6])
        #expect(text(doc) == "hello, world")
    }

    @Test func typingCoalescesIntoOneUndo() throws {
        let doc = try TextDocument(url: tempFile("ab"))
        for (i, c) in "xyz".utf8.enumerated() {
            doc.replace((1 + i)..<(1 + i), with: [c], coalesce: .typing)
        }
        #expect(text(doc) == "axyzb")
        #expect(doc.buffer.pieces.count == 3)
        doc.undo()
        #expect(text(doc) == "ab")
        #expect(!doc.buffer.isModified)
    }

    @Test func backspacesCoalesce() throws {
        let doc = try TextDocument(url: tempFile("abcdef"))
        doc.replace(5..<6, with: [], coalesce: .deleteBackward)
        doc.replace(4..<5, with: [], coalesce: .deleteBackward)
        doc.replace(3..<4, with: [], coalesce: .deleteBackward)
        #expect(text(doc) == "abc")
        #expect(doc.undo() == [3..<6])
        #expect(text(doc) == "abcdef")
        #expect(!doc.buffer.canUndo)
    }

    @Test func undoSurvivesSaveAndTracksModified() throws {
        let url = try tempFile("one\ntwo\n")
        let doc = try TextDocument(url: url)
        doc.replace(4..<7, with: Array("TWO".utf8))
        try doc.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\nTWO\n")
        #expect(!doc.isModified)
        doc.undo()
        #expect(text(doc) == "one\ntwo\n")
        #expect(doc.isModified)
        doc.redo()
        #expect(!doc.isModified)
        // Typing right after a save starts a new undo step.
        doc.replace(0..<0, with: [0x41], coalesce: .typing)
        #expect(doc.isModified)
        doc.undo()
        #expect(!doc.isModified)
    }

    @Test func batchEditsAreOneUndoStep() throws {
        let doc = try TextDocument(url: tempFile("a1 a2 a3 a4"))
        doc.applyEdits([(0..<1, Array("bb".utf8)), (3..<4, Array("bb".utf8)), (9..<10, [])],
                       name: "Replace All", before: [0..<0], after: [0..<0])
        #expect(text(doc) == "bb1 bb2 a3 4")
        doc.undo()
        #expect(text(doc) == "a1 a2 a3 a4")
    }

    @Test func undoMemoryStaysSmall() throws {
        // 20k scattered edits used to keep 20k copies of the piece array.
        let doc = try TextDocument(url: tempFile(String(repeating: "0123456789\n", count: 30_000)))
        for i in 0..<20_000 { doc.replace((i * 16)..<(i * 16), with: [0x41]) }
        #expect(doc.buffer.pieces.count > 20_000)
        doc.lineIndex.build()
        #expect(doc.lineNumber(at: doc.length) == 30_000)
        for _ in 0..<20_000 { doc.undo() }
        #expect(!doc.isModified)
    }

    @Test func snapshotIsStableWhileEditing() throws {
        let doc = try TextDocument(url: tempFile("abcdef"))
        let snap = doc.snapshot()
        doc.replace(0..<3, with: Array("XYZ123".utf8))
        #expect(String(decoding: snap.read(0..<snap.length), as: UTF8.self) == "abcdef")
        #expect(text(doc) == "XYZ123def")
    }

    // MARK: Lines

    @Test func lineIndexAndNavigation() throws {
        let lines = (0..<5000).map { "line \($0)" }
        let doc = try TextDocument(url: tempFile(lines.joined(separator: "\n") + "\n"))
        doc.lineIndex.build(chunkSize: 4096)
        #expect(doc.lineIndex.lineCount == 5000)
        #expect(doc.lineCount == 5000)
        let off = try #require(doc.offset(ofLine: 4321))
        #expect(String(decoding: doc.line(at: off).bytes, as: UTF8.self) == "line 4321")
        #expect(doc.lineNumber(at: off + 2) == 4321)
        #expect(doc.lineStart(containing: off + 3) == off)
        let off4300 = try #require(doc.offset(ofLine: 4300))
        #expect(doc.moveLines(from: off, by: -21) == off4300)

        // Line numbers stay correct after an edit inserts lines.
        doc.replace(0..<0, with: Array("new\nnew\n".utf8))
        #expect(doc.lineNumber(at: off + 8) == 4323)
        #expect(doc.offset(ofLine: 4323) == off + 8)
        #expect(doc.lineCount == 5002)
    }

    @Test func veryLongLineIsSegmentedConsistently() throws {
        let m = TextDocument.maxLineBytes
        let doc = try TextDocument(url: tempFile("short\n" + String(repeating: "x", count: m * 5) + "\nend\n"))
        var starts: [Int] = []
        var pos = 0
        while pos < doc.length {
            starts.append(pos)
            pos = doc.nextLineStart(after: pos).next
        }
        for (i, s) in starts.enumerated() {
            let next = i + 1 < starts.count ? starts[i + 1] : doc.length
            #expect(next - s <= 2 * m + 1)
            for probe in [s, (s + next) / 2, next - 1] where probe >= s && probe < next {
                #expect(doc.lineStart(containing: probe) == s, "probe \(probe)")
            }
        }
        #expect(doc.isRealLineStart(starts[1]))
        #expect(!doc.isRealLineStart(starts[2]))
    }

    @Test func documentChangeMapsOffsets() {
        let c = DocumentChange(edits: [(10..<12, 5), (20..<20, 3)], isReset: false)
        #expect(c.map(5, newLength: 100) == 5)
        #expect(c.map(15, newLength: 100) == 18)
        #expect(c.map(25, newLength: 100) == 31)
    }

    // MARK: Search

    @Test func searchForwardBackwardAndCaseInsensitive() throws {
        let doc = try TextDocument(url: tempFile("alpha Beta gamma beta"))
        let s = TextSearcher()
        #expect(s.find("beta", in: doc, from: 0) == 17..<21)
        #expect(s.find("beta", in: doc, from: 0, options: .init(caseSensitive: false)) == 6..<10)
        #expect(s.find("BETA", in: doc, from: 11, backwards: true, options: .init(caseSensitive: false)) == 6..<10)
        #expect(s.find("alpha", in: doc, from: 5) == 0..<5)   // wraps
        #expect(s.find("beta", in: doc, from: 21, backwards: true) == 17..<21)
    }

    @Test func searchWholeWordRegexAndUnicodeCase() throws {
        let doc = try TextDocument(url: tempFile("cat concat cat_x Cat\nÉcole école id=42 id=7\n"))
        let s = TextSearcher()
        #expect(s.find("cat", in: doc, from: 1, options: .init(wholeWord: true)) == nil ||
                s.find("cat", in: doc, from: 1, options: .init(wholeWord: true)) == 0..<3)
        #expect(s.find("cat", in: doc, from: 4, options: .init(caseSensitive: false, wholeWord: true)) == 17..<20)
        let ecole = try #require(s.find("école", in: doc, from: 0, options: .init(caseSensitive: false)))
        #expect(String(decoding: doc.buffer.read(ecole), as: UTF8.self) == "École")
        let r = try #require(s.find(#"id=(\d+)"#, in: doc, from: 0, options: .init(regex: true)))
        #expect(String(decoding: doc.buffer.read(r), as: UTF8.self) == "id=42")
        let back = try #require(s.find(#"id=\d+"#, in: doc, from: doc.length, backwards: true, options: .init(regex: true)))
        #expect(String(decoding: doc.buffer.read(back), as: UTF8.self) == "id=7")
    }

    @Test func findAllCountsAndExpandsTemplates() throws {
        let doc = try TextDocument(url: tempFile("id=1, id=22, id=333"))
        let p = try SearchPattern(#"id=(\d+)"#, options: .init(regex: true))
        var reps: [String] = []
        let n = TextSearcher().findAll(p, in: doc.snapshot(), template: "#$1") { _, rep in
            reps.append(String(decoding: rep ?? [], as: UTF8.self)); return true
        }
        #expect(n == 3)
        #expect(reps == ["#1", "#22", "#333"])
        let lit = try SearchPattern("ID", options: .init(caseSensitive: false))
        #expect(TextSearcher().findAll(lit, in: doc.snapshot()) { _, _ in true } == 3)
    }

    @Test func searchInSelectionOnly() throws {
        let doc = try TextDocument(url: tempFile("x x x x"))
        let p = try SearchPattern("x", options: .init(range: 2..<5))
        #expect(TextSearcher().findAll(p, in: doc.snapshot()) { _, _ in true } == 2)
    }

    @Test func filterLines() throws {
        let doc = try TextDocument(url: tempFile("a ERROR 1\nb ok\nc error 2\nd ok"))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("bfe-\(UUID()).txt")
        let sink = try FileSink(url: out)
        let p = try SearchPattern("error", options: .init(caseSensitive: false))
        #expect(try TextSearcher().filterLines(p, in: doc.snapshot(), invert: false, to: sink) == 2)
        try sink.close()
        #expect(try String(contentsOf: out, encoding: .utf8) == "a ERROR 1\nc error 2\n")
        let out2 = FileManager.default.temporaryDirectory.appendingPathComponent("bfe-\(UUID()).txt")
        let sink2 = try FileSink(url: out2)
        #expect(try TextSearcher().filterLines(p, in: doc.snapshot(), invert: true, to: sink2) == 2)
        try sink2.close()
        #expect(try String(contentsOf: out2, encoding: .utf8) == "b ok\nd ok\n")
    }

    // MARK: Encodings and line endings

    @Test func latin1RoundTrip() throws {
        let url = try tempFile("café naïve\n".data(using: .isoLatin1)!)
        let doc = try TextDocument(url: url, encoding: .latin1)
        #expect(text(doc) == "café naïve\n")
        doc.replace(0..<0, with: Array("Größe ".utf8))
        try doc.save()
        #expect(try String(contentsOf: url, encoding: .isoLatin1) == "Größe café naïve\n")
    }

    @Test func detectsLatin1AndUTF16() throws {
        let latin = try TextDocument(url: tempFile("INSERT 'café'\n".data(using: .isoLatin1)!))
        #expect(latin.encoding == .windows1252)
        #expect(text(latin) == "INSERT 'café'\n")
        let utf16 = try TextDocument(url: tempFile("hello UTF-16\nsecond\n".data(using: .utf16)!))
        #expect(utf16.encoding.id.hasPrefix("UTF-16"))
        #expect(text(utf16) == "hello UTF-16\nsecond\n")
        #expect(TextSearcher().find("second", in: utf16, from: 0) != nil)
    }

    @Test func utf8BOMIsHiddenAndKept() throws {
        let url = try tempFile(Data([0xEF, 0xBB, 0xBF] + Array("{\"a\":1}\n".utf8)))
        let doc = try TextDocument(url: url)
        #expect(doc.encoding == .utf8BOM)
        #expect(text(doc) == "{\"a\":1}\n")
        doc.replace(0..<0, with: Array(" ".utf8))
        try doc.save()
        #expect(Array(try Data(contentsOf: url).prefix(4)) == [0xEF, 0xBB, 0xBF, 0x20])
    }

    @Test func classicMacLineEndings() throws {
        let url = try tempFile("one\rtwo\rthree\r")
        let doc = try TextDocument(url: url)
        #expect(doc.lineEnding == .cr)
        #expect(text(doc) == "one\ntwo\nthree\n")
        doc.replace(0..<0, with: Array("zero\n".utf8))
        try doc.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "zero\rone\rtwo\rthree\r")
    }

    @Test func convertLineEndingsOnSave() throws {
        let url = try tempFile("a\r\nb\nc\r\n")
        let doc = try TextDocument(url: url)
        #expect(doc.lineEnding == .crlf)
        #expect(doc.mixedLineEndings)
        doc.lineEnding = .lf
        doc.convertLineEndingsOnSave = true
        doc.replace(0..<0, with: Array("x".utf8))
        try doc.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "xa\nb\nc\n")
        var c = LineEndingConverter(target: .crlf)
        var out: [UInt8] = []
        for part in ["a\r", "\nb\r", "c\n"] {
            Array(part.utf8).withUnsafeBytes { c.convert($0, final: part == "c\n") { out.append(contentsOf: $0) } }
        }
        #expect(String(decoding: out, as: UTF8.self) == "a\r\nb\r\nc\r\n")
    }

    @Test func unrepresentableCharacterFailsSafely() throws {
        let url = try tempFile("abc\n")
        let doc = try TextDocument(url: url)
        doc.replace(0..<0, with: Array("😀".utf8))
        #expect(throws: EncodingError.self) { try doc.save(encoding: .latin1) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "abc\n")   // original untouched
    }

    @Test func saveKeepsPermissionsAndSymlinks() throws {
        let url = try tempFile("x\n")
        chmod(url.path, 0o600)
        let link = url.deletingLastPathComponent().appendingPathComponent("bfe-link-\(UUID()).txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let doc = try TextDocument(url: link)
        doc.replace(0..<0, with: Array("y".utf8))
        try doc.save()
        let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try String(contentsOf: url, encoding: .utf8) == "yx\n")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func cloneProtectsAgainstOutsideTruncation() throws {
        let url = try tempFile(String(repeating: "data\n", count: 1000))
        let doc = try TextDocument(url: url)
        truncate(url.path, 0)            // another app empties the file
        #expect(doc.file.url != url)     // an APFS clone is mapped, not the file itself
        #expect(doc.byte(at: 4000) == UInt8(ascii: "d"))
        #expect(doc.changedOnDisk)
    }

    // MARK: Highlighting

    @Test func highlighting() {
        let t = Highlighter.tokens(for: Array("SELECT 'a' FROM t -- c".utf8), language: .sql)
        #expect(t.map(\.kind) == [.keyword, .string, .keyword, .comment])
        let j = Highlighter.tokens(for: Array(#"{"k": 1}"#.utf8), language: .json)
        #expect(j.map(\.kind) == [.punctuation, .key, .punctuation, .number, .punctuation])
    }

    @Test func multiLineStateCarriesOver() {
        var s = LexState.normal
        _ = Highlighter.tokens(for: Array("/* start".utf8), language: .sql, state: &s)
        #expect(s == .blockComment)
        let mid = Highlighter.tokens(for: Array("still comment */ SELECT".utf8), language: .sql, state: &s)
        #expect(mid.map(\.kind) == [.comment, .keyword])
        _ = Highlighter.tokens(for: Array("INSERT 'multi".utf8), language: .sql, state: &s)
        #expect(s == .string(UInt8(ascii: "'")))
        _ = Highlighter.tokens(for: Array("line', 2".utf8), language: .sql, state: &s)
        #expect(s == .normal)
        var c = LexState.normal
        _ = Highlighter.tokens(for: Array(#"1,"a"#.utf8), language: .csv, state: &c)
        #expect(c == .csvQuoted(column: 1))
        let next = Highlighter.tokens(for: Array(#"b",x"#.utf8), language: .csv, state: &c)
        #expect(next.map(\.kind) == [.column(1), .punctuation, .column(2)])
    }

    @Test func sqlEdgeCases() {
        let t = Highlighter.tokens(for: Array("SELECT $$x$$, 1e10, 0x1F # not a comment".utf8), language: .sql)
        #expect(t.map(\.kind) == [.keyword, .string, .number, .number, .keyword, .keyword])   // not, comment
        let c = Highlighter.tokens(for: Array("# mysql comment".utf8), language: .sql)
        #expect(c.map(\.kind) == [.comment])
    }

    @Test func xmlAndLogHighlighting() {
        let x = Highlighter.tokens(for: Array("<!-- c --><a href='x'>&amp;</a>".utf8), language: .xml)
        #expect(x.map(\.kind) == [.comment, .tag, .attribute, .punctuation, .string, .tag, .number, .tag, .tag])
        let l = Highlighter.tokens(for: Array("2024-01-01 12:00:00 ERROR [db] failed after 3 tries".utf8), language: .log)
        #expect(l.first?.kind == .timestamp)
        #expect(l.contains { $0.kind == .logError })
    }

    // MARK: Formatting and line tools

    @Test func jsonFormatter() throws {
        let doc = try TextDocument(url: tempFile(#"{"a":[1,2],"b":{}}"#))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("bfe-\(UUID()).json")
        try JSONFormatter.format(doc, to: out)
        #expect(try String(contentsOf: out, encoding: .utf8) == "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {}\n}\n")
        try JSONFormatter.format(doc, to: out, minify: true)
        #expect(try String(contentsOf: out, encoding: .utf8) == #"{"a":[1,2],"b":{}}"#)
    }

    @Test func xmlAndSQLFormatters() throws {
        let doc = try TextDocument(url: tempFile("<a><b x=\"1\">t</b><c/></a>"))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("bfe-\(UUID()).xml")
        let sink = try FileSink(url: out)
        try XMLFormatter.format(doc.snapshot(), to: sink)
        try sink.close()
        #expect(try String(contentsOf: out, encoding: .utf8) == "<a>\n  <b x=\"1\">\n    t\n  </b>\n  <c/>\n</a>\n")
        let sql = String(decoding: SQLFormatter.format(Array("select a, b from t where x = 'from' and y > 1".utf8)), as: UTF8.self)
        #expect(sql == "SELECT a, b\nFROM t\nWHERE x = 'from'\n  AND y > 1\n")
    }

    @Test func sortDedupeAndColumns() throws {
        let csv = Array("b,3\na,10\nc,2\na,10\n".utf8)
        try csv.withUnsafeBytes { buf in
            var o = SortOptions()
            let plain = try LineTools.collect { try LineTools.sort(buf, options: o, newline: [0x0A], emit: $0) }
            #expect(String(decoding: plain, as: UTF8.self) == "a,10\na,10\nb,3\nc,2\n")
            o.numeric = true; o.column = 1; o.descending = true
            let num = try LineTools.collect { try LineTools.sort(buf, options: o, newline: [0x0A], emit: $0) }
            #expect(String(decoding: num, as: UTF8.self) == "a,10\na,10\nb,3\nc,2\n")
            var removed = 0
            let dd = try LineTools.collect { removed = try LineTools.removeDuplicates(buf, adjacentOnly: false, newline: [0x0A], emit: $0) }
            #expect(removed == 1)
            #expect(String(decoding: dd, as: UTF8.self) == "b,3\na,10\nc,2\n")
            let col = try LineTools.collect { try LineTools.extractColumn(buf, column: 0, separator: 0x2C, newline: [0x0A], emit: $0) }
            #expect(String(decoding: col, as: UTF8.self) == "b\na\nc\na\n")
        }
    }

    @Test func crashJournalRoundTrip() throws {
        let url = try tempFile("hello world\n")
        let doc = try TextDocument(url: url)
        doc.replace(5..<5, with: Array(", big".utf8))
        doc.replace(0..<0, with: Array(">> ".utf8))
        let id = UUID().uuidString
        try Recovery.save(doc, id: id)
        defer { Recovery.remove(id: id) }
        let entry = try #require(Recovery.pending().first { $0.id == id })
        let restored = try Recovery.restore(entry)
        #expect(text(restored) == ">> hello, big world\n")
        #expect(restored.isModified)
    }
}
