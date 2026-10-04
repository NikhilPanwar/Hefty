import AppKit
import CoreText
import BigFileCore

/// One display line, decoded and laid out with CoreText. Built only for lines
/// that are (nearly) on screen and cached by the view until the next edit.
final class LineLayout {
    struct Fragment {
        var range: Range<Int>     // UTF-16 range within `string`
        var line: CTLine
        var shift: CGFloat        // CoreText x of range.lowerBound
        var width: CGFloat
    }

    let start: Int                // doc offset of the display line
    let contentEnd: Int           // doc offset of its end (before CR/LF)
    let next: Int                 // start of the following display line
    let isRealLineStart: Bool
    let string: NSString
    /// UTF-16 index -> byte offset relative to `start`; count == length + 1.
    let map: [Int32]
    let fragments: [Fragment]
    let endState: LexState
    /// UTF-16 indexes of spaces and tabs (for drawing invisibles).
    let blanks: [Int]

    init(start: Int, contentEnd: Int, next: Int, isRealLineStart: Bool, string: NSString, map: [Int32],
         fragments: [Fragment], endState: LexState, blanks: [Int]) {
        self.start = start; self.contentEnd = contentEnd; self.next = next
        self.isRealLineStart = isRealLineStart
        self.string = string; self.map = map; self.fragments = fragments
        self.endState = endState; self.blanks = blanks
    }

    var rowCount: Int { fragments.count }

    /// Doc offset of UTF-16 index `u`.
    func byteOffset(_ u: Int) -> Int { start + Int(map[max(0, min(u, map.count - 1))]) }

    /// UTF-16 index for doc offset `o` (first unit of the character there).
    func utf16(_ o: Int) -> Int {
        let rel = Int32(max(0, min(o, contentEnd) - start))
        var lo = 0, hi = map.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if map[mid] < rel { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Row containing UTF-16 index `u`. At a wrap boundary the caret belongs
    /// to the next row (unless `preferEnd`).
    func fragmentIndex(_ u: Int, preferEnd: Bool = false) -> Int {
        for (i, f) in fragments.enumerated() {
            if u < f.range.upperBound { return (preferEnd && i > 0 && u == f.range.lowerBound) ? i - 1 : i }
        }
        return fragments.count - 1
    }

    func x(_ u: Int, in f: Int) -> CGFloat {
        let fr = fragments[f]
        return CTLineGetOffsetForStringIndex(fr.line, max(fr.range.lowerBound, min(u, fr.range.upperBound)), nil) - fr.shift
    }

    /// UTF-16 index nearest to `x` on row `f`.
    func index(atX x: CGFloat, in f: Int) -> Int {
        let fr = fragments[f]
        var i = CTLineGetStringIndexForPosition(fr.line, CGPoint(x: x + fr.shift, y: 0))
        if i == kCFNotFound { i = fr.range.lowerBound }
        i = max(fr.range.lowerBound, min(i, fr.range.upperBound))
        // On a wrapped row (not the last), the end belongs to the next row.
        if f < fragments.count - 1 && i == fr.range.upperBound && i > fr.range.lowerBound { i -= 1 }
        // Never land inside a surrogate pair.
        if i > 0 && i < string.length {
            let c = string.character(at: i)
            if c >= 0xDC00 && c <= 0xDFFF { i -= 1 }
        }
        return i
    }
}

/// Everything that affects how lines look; a change invalidates the cache.
struct LayoutStyle: Equatable {
    var fontName: String
    var fontSize: CGFloat
    var tabWidth: Int
    var wrapWidth: CGFloat?
    var language: Language
    var themeKey: String
    var csvWidths: [Int]
}

enum LineLayoutBuilder {
    private static var paraCache: [String: CTParagraphStyle] = [:]

    /// Tab stops every `tabWidth` spaces.
    static func paragraphStyle(font: NSFont, tabWidth: Int) -> CTParagraphStyle {
        let key = "\(font.fontName)-\(font.pointSize)-\(tabWidth)"
        if let p = paraCache[key] { return p }
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        var tab = CGFloat(max(1, tabWidth)) * spaceWidth
        var stops: CFArray = [] as CFArray
        let p: CTParagraphStyle = withUnsafePointer(to: &tab) { tp in
            withUnsafePointer(to: &stops) { sp in
                let settings = [CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: tp),
                                CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: sp)]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        paraCache[key] = p
        return p
    }

    /// Lays out the display line `start..<contentEnd`.
    static func build(doc: TextDocument, start: Int, contentEnd: Int, next: Int, state: LexState,
                      style: LayoutStyle, font: NSFont, theme: Theme,
                      marked: (offset: Int, text: String)?) -> LineLayout {
        let bytes = doc.buffer.read(start..<contentEnd)
        var (units, map) = bytes.withUnsafeBytes { LineDecoder.decode($0) }

        // Tokens -> colors per byte range (before any display-only changes).
        var endState = state
        let tokens = Highlighter.tokens(for: bytes, language: style.language, state: &endState)

        // Control characters become visible "control pictures" (1:1, so the
        // mapping is unchanged): a stray CR or NUL can't break the layout.
        var blanks: [Int] = []
        for i in 0..<units.count {
            let u = units[i]
            if u < 0x20 {
                if u == 0x09 { blanks.append(i) } else { units[i] = 0x2400 + u }
            } else if u == 0x7F { units[i] = 0x2421 }
            else if u == 0x20 { blanks.append(i) }
        }

        // CSV/TSV column alignment: pad each field to its column width.
        let sep: UInt16? = style.language == .csv ? 0x2C : (style.language == .tsv ? 0x09 : nil)
        var padded = false
        if let sep, !style.csvWidths.isEmpty {
            var outU: [UInt16] = []; outU.reserveCapacity(units.count + 64)
            var outM: [Int32] = []; outM.reserveCapacity(units.count + 64)
            var col = 0, width = 0
            var inQuotes = false
            if case .csvQuoted = state { inQuotes = true }
            for i in 0..<units.count {
                let u = units[i]
                if u == 0x22 { inQuotes.toggle() }
                if u == sep && !inQuotes && col < style.csvWidths.count {
                    let pad = style.csvWidths[col] - width
                    if pad > 0 {
                        for _ in 0..<pad { outU.append(0x20); outM.append(map[i]) }
                        padded = true
                    }
                    outU.append(sep == 0x09 ? 0x20 : u); outM.append(map[i])
                    outU.append(0x20); outM.append(map[i] + 1)
                    col += 1; width = 0
                    continue
                }
                outU.append(u); outM.append(map[i])
                if u < 0xDC00 || u > 0xDFFF { width += 1 }
            }
            outM.append(map[units.count])
            units = outU; map = outM
            if padded { blanks = [] }
        }

        // IME marked text is shown inline at the caret, display-only.
        var markedRange: NSRange?
        if let m = marked, m.offset >= start, m.offset <= contentEnd {
            let rel = Int32(m.offset - start)
            var at = 0
            while at < map.count - 1 && map[at] < rel { at += 1 }
            let mu = Array(m.text.utf16)
            units.insert(contentsOf: mu, at: at)
            map.insert(contentsOf: repeatElement(rel, count: mu.count), at: at)
            markedRange = NSRange(location: at, length: mu.count)
        }

        let string = units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress ?? UnsafePointer(bitPattern: 1)!, length: units.count) }
        let attr = NSMutableAttributedString(string: string as String)
        let full = NSRange(location: 0, length: string.length)
        let para = paragraphStyle(font: font, tabWidth: style.tabWidth)
        attr.addAttributes([.font: font, .foregroundColor: theme.text,
                            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para], range: full)

        if !tokens.isEmpty {
            func u16(_ b: Int) -> Int {
                var lo = 0, hi = map.count - 1
                while lo < hi { let mid = (lo + hi) / 2; if Int(map[mid]) < b { lo = mid + 1 } else { hi = mid } }
                return lo
            }
            for t in tokens {
                let a = u16(t.range.lowerBound), b = u16(t.range.upperBound)
                if b > a { attr.addAttribute(.foregroundColor, value: theme.color(for: t.kind), range: NSRange(location: a, length: b - a)) }
            }
        }
        if let markedRange {
            attr.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: theme.text], range: markedRange)
        }

        // Rows: the whole line, or wrapped fragments.
        var fragments: [LineLayout.Fragment] = []
        let ts = CTTypesetterCreateWithAttributedString(attr)
        if let w = style.wrapWidth, string.length > 0 {
            var s = 0
            while s < string.length {
                var count = CTTypesetterSuggestLineBreak(ts, s, Double(max(20, w)))
                if count <= 0 { count = string.length - s }
                let line = CTTypesetterCreateLine(ts, CFRange(location: s, length: count))
                let shift = CTLineGetOffsetForStringIndex(line, s, nil)
                fragments.append(.init(range: s..<s + count, line: line, shift: shift,
                                       width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
                s += count
            }
        } else {
            let line = CTTypesetterCreateLine(ts, CFRange(location: 0, length: string.length))
            fragments.append(.init(range: 0..<string.length, line: line, shift: 0,
                                   width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
        }
        // The caret at the very end belongs to the last row.
        if let last = fragments.indices.last { fragments[last].range = fragments[last].range.lowerBound..<string.length }
        return LineLayout(start: start, contentEnd: contentEnd, next: next,
                          isRealLineStart: doc.isRealLineStart(start), string: string, map: map,
                          fragments: fragments, endState: endState, blanks: blanks)
    }
}
