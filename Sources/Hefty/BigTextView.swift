import AppKit
import CoreText
import BigFileCore

/// Bookmarked line starts for one document, kept in step with edits.
final class Bookmarks {
    private(set) var offsets: [Int] = []
    func toggle(_ lineStart: Int) {
        if let i = offsets.firstIndex(of: lineStart) { offsets.remove(at: i) } else { offsets.append(lineStart); offsets.sort() }
    }
    func contains(_ lineStart: Int) -> Bool { offsets.contains(lineStart) }
    func clear() { offsets.removeAll() }
    func map(_ change: DocumentChange, length: Int) {
        offsets = Array(Set(offsets.map { change.map($0, newLength: length) })).sorted()
    }
    func normalize(_ doc: TextDocument) {
        offsets = Array(Set(offsets.map { doc.lineStart(containing: $0) })).sorted()
    }
}

/// Custom text view that only ever lays out the visible lines.
///
/// The scroll position is a *byte offset* of the top display line plus a row
/// within it (for wrapped lines) and a pixel offset (smooth scrolling), so it
/// works immediately on a 100 GB file whose line count isn't known yet.
/// Rendering cost is O(visible lines).
final class BigTextView: NSView, NSTextInputClient, NSMenuItemValidation {
    let document: TextDocument
    var bookmarks: Bookmarks
    var onStateChange: (() -> Void)?
    var onEscape: (() -> Void)?
    var onReadOnlyEdit: (() -> Void)?
    /// Find term: every visible occurrence gets a soft highlight.
    var findPattern: SearchPattern? { didSet { matchCache.removeAll(); needsDisplay = true } }

    // MARK: Selection model

    struct Sel: Equatable {
        var anchor: Int
        var caret: Int
        var lo: Int { min(anchor, caret) }
        var hi: Int { max(anchor, caret) }
        var range: Range<Int> { lo..<hi }
        var isEmpty: Bool { anchor == caret }
        init(_ a: Int, _ c: Int) { anchor = a; caret = c }
        init(_ r: Range<Int>) { anchor = r.lowerBound; caret = r.upperBound }
    }
    private(set) var sels: [Sel] = [Sel(0, 0)]
    private(set) var primary = 0
    private var desiredX: CGFloat?
    var caret: Int { sels[primary].caret }
    var selection: Range<Int> { sels[primary].range }
    var allSelections: [Range<Int>] { sels.map(\.range) }

    // MARK: Scroll state

    private(set) var topLine = 0
    private var topRow = 0
    private var pixelY: CGFloat = 0
    private(set) var scrollX: CGFloat = 0
    private(set) var contentWidth: CGFloat = 0
    private var scrollRemainder: CGFloat = 0

    // MARK: Appearance

    private var font = Prefs.font()
    private var gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var ascent: CGFloat = 0
    private(set) var lineHeight: CGFloat = 16
    private var charWidth: CGFloat = 8
    private var gutterWidth: CGFloat = 0
    private let textInset: CGFloat = 8
    private var textX: CGFloat { gutterWidth + textInset }
    private var theme: Theme { Prefs.theme.resolved(for: effectiveAppearance) }
    var wordWrap = Prefs.wordWrap { didSet { if wordWrap != oldValue { scrollX = 0; topRow = 0; invalidateLayout() } } }

    // MARK: Layout cache

    private struct Row { let layout: LineLayout; let frag: Int; let y: CGFloat; let lineNumber: Int? }
    private var rows: [Row] = []
    private var rowsValid = false
    private var cache: [Int: LineLayout] = [:]
    private var cacheVersion = -1
    private var cacheStyle: LayoutStyle?
    private var stateCache: [Int: LexState] = [:]
    private var matchCache: [Int: [NSRange]] = [:]
    private var csvWidths: [Int] = []
    private var bracketPair: (Int, Int)?

    // MARK: Input state

    private var markedText: String?
    private var blinkTimer: Timer?
    private var caretOn = true
    private enum DragMode { case none, char, word, line, column, gutter }
    private var dragMode = DragMode.none
    private var dragOrigin = Sel(0, 0)
    private var dragColumnStart: (line: Int, x: CGFloat)?
    private var autoscrollTimer: Timer?
    private var lastDragPoint = NSPoint.zero
    private var observer: UUID?
    private var applyingOwnEdit = false

    init(document: TextDocument, bookmarks: Bookmarks) {
        self.document = document
        self.bookmarks = bookmarks
        super.init(frame: .zero)
        updateFont()
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Prefs.didChange, object: nil)
        observer = document.addObserver { [weak self] change in self?.documentChanged(change) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit {
        if let observer { document.removeObserver(observer) }
        blinkTimer?.invalidate(); autoscrollTimer?.invalidate()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private func updateFont() {
        font = Prefs.font()
        gutterFont = NSFont.monospacedDigitSystemFont(ofSize: max(8, Prefs.fontSize - 2), weight: .regular)
        ascent = CTFontGetAscent(font)
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        lineHeight = ceil(natural * Prefs.lineSpacing)
        charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    }

    @objc private func prefsChanged() {
        updateFont()
        wordWrap = Prefs.wordWrap
        invalidateLayout()
        restartBlink()
    }

    override func viewDidChangeEffectiveAppearance() { invalidateLayout() }

    private func invalidateLayout() {
        cache.removeAll(); stateCache.removeAll(); matchCache.removeAll()
        cacheStyle = nil
        contentWidth = 0
        changed()
    }

    // MARK: Document changes

    private func documentChanged(_ change: DocumentChange) {
        let len = document.length
        cache.removeAll(); matchCache.removeAll()
        if change.isReset { stateCache.removeAll() } else if let first = change.edits.first {
            stateCache = stateCache.filter { $0.key < first.0.lowerBound }
        }
        let newTop = change.map(topLine, newLength: len)
        topLine = document.lineStart(containing: newTop)
        if change.isReset || newTop != topLine { topRow = 0 }
        if !applyingOwnEdit {
            sels = sels.map { Sel(change.map($0.anchor, newLength: len), change.map($0.caret, newLength: len)) }
            normalizeSelections()
        }
        if change.isReset { contentWidth = 0 }
        changed()
    }

    /// Called after Revert / reload: keep the caret near where it was.
    func documentDidReload() {
        let len = document.length
        sels = [Sel(min(caret, len), min(caret, len))]; primary = 0
        topLine = document.lineStart(containing: min(topLine, len)); topRow = 0; pixelY = 0
        invalidateLayout()
    }

    // MARK: Layout

    private var style: LayoutStyle {
        LayoutStyle(fontName: font.fontName, fontSize: font.pointSize, tabWidth: Prefs.tabWidth,
                    wrapWidth: wordWrap ? max(50, bounds.width - textX - textInset) : nil,
                    language: document.language, themeKey: Prefs.theme.rawValue + (theme.isDark ? "d" : "l"),
                    csvWidths: csvWidths)
    }

    private func validateCache() {
        let s = style
        if cacheVersion != document.buffer.version || cacheStyle != s {
            cache.removeAll(); matchCache.removeAll()
            if cacheStyle?.language != s.language { stateCache.removeAll() }
            cacheVersion = document.buffer.version
            cacheStyle = s
        }
        if cache.count > 4000 { cache.removeAll() }
    }

    private func lexState(at start: Int) -> LexState {
        guard document.language.hasMultilineState else { return .normal }
        if let s = stateCache[start] { return s }
        let s = Highlighter.state(atLineStart: start, in: document, language: document.language)
        stateCache[start] = s
        return s
    }

    /// Layout of the display line starting at `start` (cached).
    func layout(_ start: Int) -> LineLayout {
        validateCache()
        if let l = cache[start] { return l }
        let (end, next) = document.nextLineStart(after: start)
        let m: (Int, String)? = markedText.map { (caret, $0) }
        let l = LineLayoutBuilder.build(doc: document, start: start, contentEnd: end, next: next,
                                        state: lexState(at: start), style: cacheStyle!, font: font, theme: theme,
                                        marked: m)
        cache[start] = l
        if document.language.hasMultilineState, next > start { stateCache[next] = l.endState }
        if !wordWrap { contentWidth = max(contentWidth, l.fragments.map(\.width).max() ?? 0) }
        return l
    }

    /// True if there is a display line after the one described by `l`.
    private func hasLine(after l: LineLayout) -> Bool {
        if l.start >= document.length { return false }
        if l.next < document.length { return true }
        return document.byte(at: document.length - 1) == 0x0A   // empty last line
    }

    private func computeCSVWidths() {
        guard Prefs.alignCSVColumns, document.language == .csv || document.language == .tsv else {
            if !csvWidths.isEmpty { csvWidths = [] }
            return
        }
        let sep: UInt8 = document.language == .csv ? 0x2C : 0x09
        var widths: [Int] = []
        var line = topLine
        for _ in 0..<(visibleRowCount + 2) {
            let (end, next) = document.nextLineStart(after: line)
            let bytes = document.buffer.read(line..<min(end, line + 4096))
            let fields = Highlighter.fields(bytes, separator: sep)
            for (i, f) in fields.enumerated() where i < fields.count - 1 {
                let w = min(60, String(decoding: bytes[f], as: UTF8.self).utf16.count)
                if i < widths.count { widths[i] = max(widths[i], w) } else { widths.append(w) }
            }
            if next <= line || next >= document.length { break }
            line = next
        }
        if widths != csvWidths { csvWidths = widths }
    }

    private func layoutRowsIfNeeded() {
        if rowsValid { return }
        computeCSVWidths()
        validateCache()
        updateGutterWidth()
        rows.removeAll(keepingCapacity: true)
        var y = -pixelY
        var line = topLine
        var frag = topRow
        var lineNo = document.lineNumber(at: topLine)
        while y < bounds.height {
            let l = layout(line)
            if frag >= l.rowCount { frag = l.rowCount - 1 }
            for f in frag..<l.rowCount {
                rows.append(Row(layout: l, frag: f, y: y, lineNumber: f == 0 && l.isRealLineStart ? lineNo : nil))
                y += lineHeight
                if y >= bounds.height { break }
            }
            if !hasLine(after: l) { break }
            if let n = lineNo, l.next > 0, document.byte(at: l.next - 1) == 0x0A { lineNo = n + 1 }
            if l.next <= line && !(l.next == document.length && line < document.length) { break }
            line = l.next == line ? document.length : l.next
            frag = 0
        }
        rowsValid = true
    }

    private func updateGutterWidth() {
        guard Prefs.showLineNumbers else { gutterWidth = 0; return }
        let known = document.lineCount ?? 0
        let visible = (document.lineNumber(at: topLine) ?? 0) + visibleRowCount + 1
        let digits = max(4, String(max(known, visible)).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: gutterFont]).width
        let w = ceil(CGFloat(digits) * digitWidth + 26)
        if w != gutterWidth { gutterWidth = w; cacheStyle = nil }
    }

    var visibleRowCount: Int { max(1, Int(bounds.height / lineHeight)) }

    /// Rough fraction of the document above the viewport, for the scroller.
    var scrollFraction: Double { document.length == 0 ? 0 : Double(topLine) / Double(document.length) }
    var visibleByteCount: Int {
        layoutRowsIfNeeded()
        guard let last = rows.last else { return 0 }
        return max(0, last.layout.next - topLine)
    }
    var textAreaWidth: CGFloat { max(10, bounds.width - textX - textInset) }

    // MARK: Geometry

    /// Display line, row and x for a document offset.
    private func locate(_ offset: Int, preferEnd: Bool = false) -> (layout: LineLayout, frag: Int, x: CGFloat) {
        let ls = document.lineStart(containing: offset)
        let l = layout(ls)
        let u = l.utf16(offset)
        let f = l.fragmentIndex(u, preferEnd: preferEnd)
        return (l, f, l.x(u, in: f))
    }

    private var textOriginX: CGFloat { textX - (wordWrap ? 0 : scrollX) }

    private func rowY(_ layout: LineLayout, _ frag: Int) -> CGFloat? {
        rows.first { $0.layout.start == layout.start && $0.frag == frag }?.y
    }

    private func offset(at point: NSPoint) -> Int {
        layoutRowsIfNeeded()
        guard let first = rows.first else { return 0 }
        var row = first
        if point.y >= first.y {
            row = rows.last { $0.y <= point.y } ?? first
        }
        let u = row.layout.index(atX: point.x - textOriginX, in: row.frag)
        return row.layout.byteOffset(u)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = self.theme
        layoutRowsIfNeeded()
        theme.background.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let primarySel = sels[primary]
        let caretLine = document.lineStart(containing: primarySel.caret)
        let showCaret = window?.isKeyWindow == true && window?.firstResponder === self && caretOn

        NSGraphicsContext.saveGraphicsState()
        NSRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth, height: bounds.height).clip()
        let ox = textOriginX
        let spaceW = (" " as NSString).size(withAttributes: [.font: font]).width

        for row in rows {
            let l = row.layout
            let fr = l.fragments[row.frag]
            // Current line.
            if Prefs.highlightCurrentLine && primarySel.isEmpty && sels.count == 1 && l.start == caretLine {
                let caretFrag = locate(primarySel.caret).frag
                if !wordWrap || caretFrag == row.frag {
                    theme.currentLine.setFill()
                    NSRect(x: gutterWidth, y: row.y, width: bounds.width - gutterWidth, height: lineHeight).fill()
                }
            }
            // Bracket match.
            if let (a, b) = bracketPair {
                for o in [a, b] where o >= l.start && o < max(l.contentEnd, l.start + 1) {
                    let u = l.utf16(o)
                    guard u >= fr.range.lowerBound && u < fr.range.upperBound else { continue }
                    let x0 = l.x(u, in: row.frag), x1 = l.x(u + 1, in: row.frag)
                    theme.bracketMatch.setFill()
                    NSBezierPath(roundedRect: NSRect(x: ox + x0, y: row.y + 1, width: max(2, x1 - x0), height: lineHeight - 2),
                                 xRadius: 2, yRadius: 2).fill()
                }
            }
            // Selections.
            for s in sels where !s.isEmpty && s.lo <= l.contentEnd && s.hi >= l.start {
                let u0 = s.lo <= l.start ? 0 : l.utf16(s.lo)
                let u1 = s.hi > l.contentEnd ? l.string.length : l.utf16(s.hi)
                let lo = max(u0, fr.range.lowerBound), hi = min(u1, fr.range.upperBound)
                guard lo <= hi else { continue }
                if lo == hi && !(s.hi > l.contentEnd && row.frag == l.rowCount - 1) && s.lo < l.start { continue }
                let x0 = l.x(lo, in: row.frag)
                var x1 = l.x(hi, in: row.frag)
                if s.hi > l.contentEnd && row.frag == l.rowCount - 1 { x1 += spaceW }
                if wordWrap && row.frag < l.rowCount - 1 && s.hi > l.byteOffset(fr.range.upperBound) {
                    x1 = max(x1, textAreaWidth)
                }
                (window?.isKeyWindow == true ? theme.selection : theme.selection.withAlphaComponent(0.55)).setFill()
                NSRect(x: ox + x0, y: row.y, width: max(0, x1 - x0), height: lineHeight).fill()
            }
            drawMatches(row, ox, theme)
            // Text.
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: ox - fr.shift, y: row.y + round((lineHeight - (font.ascender - font.descender)) / 2) + ascent)
            CTLineDraw(fr.line, ctx)
            if Prefs.showInvisibles { drawInvisibles(row, ox, theme) }
        }

        // Carets.
        if showCaret {
            theme.caret.setFill()
            for s in sels {
                guard let p = caretPoint(s.caret) else { continue }
                NSRect(x: p.x, y: p.y, width: 2, height: lineHeight).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        drawGutter(theme, caretLine: caretLine)
    }

    private func drawGutter(_ theme: Theme, caretLine: Int) {
        guard gutterWidth > 0 else { return }
        theme.gutterBackground.setFill()
        NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height).fill()
        theme.separator.setFill()
        NSRect(x: gutterWidth - 1, y: 0, width: 1, height: bounds.height).fill()
        let numberY = (lineHeight - gutterFont.ascender + gutterFont.descender) / 2
        let attrs: [NSAttributedString.Key: Any] = [.font: gutterFont, .foregroundColor: theme.gutterText]
        let current: [NSAttributedString.Key: Any] = [.font: gutterFont, .foregroundColor: theme.gutterCurrentText]
        for row in rows where row.frag == 0 {
            let l = row.layout
            if bookmarks.contains(l.start) {
                theme.bookmark.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: 3, y: row.y + 2, width: gutterWidth - 8, height: lineHeight - 4),
                             xRadius: 4, yRadius: 4).fill()
            }
            guard let n = row.lineNumber else {
                if !l.isRealLineStart {
                    let s = NSAttributedString(string: "·", attributes: attrs)
                    s.draw(at: NSPoint(x: gutterWidth - 12 - s.size().width, y: row.y + numberY))
                }
                continue
            }
            var a = l.start == caretLine ? current : attrs
            if bookmarks.contains(l.start) { a[.foregroundColor] = NSColor.white }
            let s = NSAttributedString(string: "\(n + 1)", attributes: a)
            s.draw(at: NSPoint(x: gutterWidth - 12 - s.size().width, y: row.y + numberY))
        }
    }

    private func drawInvisibles(_ row: Row, _ ox: CGFloat, _ theme: Theme) {
        let l = row.layout
        let fr = l.fragments[row.frag]
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.invisible]
        for u in l.blanks where u >= fr.range.lowerBound && u < fr.range.upperBound {
            let isTab = l.string.character(at: u) == 0x09
            let x0 = l.x(u, in: row.frag), x1 = l.x(u + 1, in: row.frag)
            let glyph = NSAttributedString(string: isTab ? "→" : "·", attributes: attrs)
            let w = glyph.size().width
            glyph.draw(at: NSPoint(x: ox + (isTab ? x0 + 1 : (x0 + x1 - w) / 2), y: row.y + (lineHeight - glyph.size().height) / 2))
        }
        if row.frag == l.rowCount - 1, l.next > l.contentEnd {
            let glyph = NSAttributedString(string: "¬", attributes: attrs)
            glyph.draw(at: NSPoint(x: ox + fr.width + 2, y: row.y + (lineHeight - glyph.size().height) / 2))
        }
    }

    /// Visible occurrences of the find pattern, from the layout's string.
    private func matches(in l: LineLayout) -> [NSRange] {
        guard let p = findPattern, !p.text.isEmpty else { return [] }
        if let m = matchCache[l.start] { return m }
        var out: [NSRange] = []
        let s = l.string
        if p.isRegex || !p.options.caseSensitive && p.text.utf8.contains(where: { $0 >= 0x80 }) || p.options.regex {
            var pattern = p.options.regex ? p.text : NSRegularExpression.escapedPattern(for: p.text)
            if p.options.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
            if let re = try? NSRegularExpression(pattern: pattern, options: p.options.caseSensitive ? [] : [.caseInsensitive]) {
                re.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, stop in
                    if let m, m.range.length > 0 { out.append(m.range) }
                    if out.count > 2000 { stop.pointee = true }
                }
            }
        } else {
            let opts: NSString.CompareOptions = p.options.caseSensitive ? [.literal] : [.literal, .caseInsensitive]
            var search = NSRange(location: 0, length: s.length)
            while out.count < 2000 {
                let r = s.range(of: p.text, options: opts, range: search)
                if r.location == NSNotFound { break }
                let ok = !p.options.wholeWord || (isBoundary(s, r.location - 1) && isBoundary(s, r.location + r.length))
                if ok { out.append(r) }
                let next = r.location + max(1, ok ? r.length : 1)
                guard next < s.length else { break }
                search = NSRange(location: next, length: s.length - next)
            }
        }
        matchCache[l.start] = out
        return out
    }

    private func isBoundary(_ s: NSString, _ i: Int) -> Bool {
        guard i >= 0 && i < s.length else { return true }
        let c = s.character(at: i)
        if c == 0x5F { return false }
        guard let scalar = Unicode.Scalar(c) else { return false }
        return !CharacterSet.alphanumerics.contains(scalar)
    }

    private func drawMatches(_ row: Row, _ ox: CGFloat, _ theme: Theme) {
        guard findPattern != nil else { return }
        let l = row.layout
        let fr = l.fragments[row.frag]
        let cur = sels[primary].range
        for r in matches(in: l) {
            let lo = max(r.location, fr.range.lowerBound), hi = min(r.location + r.length, fr.range.upperBound)
            guard lo < hi else { continue }
            let isCurrent = l.byteOffset(r.location) == cur.lowerBound && l.byteOffset(r.location + r.length) == cur.upperBound
            let x0 = l.x(lo, in: row.frag), x1 = l.x(hi, in: row.frag)
            (isCurrent ? theme.findCurrent : theme.findHighlight).setFill()
            NSBezierPath(roundedRect: NSRect(x: ox + x0 - 1, y: row.y + 1, width: x1 - x0 + 2, height: lineHeight - 2),
                         xRadius: 3, yRadius: 3).fill()
        }
    }

    private func caretPoint(_ offset: Int) -> NSPoint? {
        let (l, f, x) = locate(offset)
        guard let y = rowY(l, f) else { return nil }
        let markedShift: CGFloat = 0
        return NSPoint(x: textOriginX + x + markedShift, y: y)
    }

    // MARK: Scrolling

    /// Moves the viewport by `n` visual rows. Returns rows actually moved.
    @discardableResult
    func scrollRows(_ n: Int) -> Int {
        var moved = 0
        if n > 0 {
            for _ in 0..<n {
                let l = layout(topLine)
                if topRow + 1 < l.rowCount { topRow += 1 }
                else if hasLine(after: l) && l.next != topLine { topLine = l.next; topRow = 0 }
                else { break }
                moved += 1
            }
        } else {
            for _ in 0..<(-n) {
                if topRow > 0 { topRow -= 1 }
                else if topLine > 0 {
                    topLine = document.lineStart(containing: topLine - 1)
                    topRow = layout(topLine).rowCount - 1
                } else { pixelY = 0; break }
                moved -= 1
            }
        }
        if moved != 0 { changed() }
        return moved
    }

    func scroll(byLines n: Int) { scrollRows(n) }

    func scroll(toFraction f: Double) {
        let target = Int(Double(document.length) * min(1, max(0, f)))
        topLine = document.lineStart(containing: target)
        topRow = 0; pixelY = 0
        if f >= 1 { topLine = document.moveLines(from: document.length, by: -(visibleRowCount - 2)) }
        changed()
    }

    func scrollHorizontally(to x: CGFloat) {
        guard !wordWrap else { return }
        scrollX = max(0, min(x, max(0, contentWidth - textAreaWidth + 40)))
        changed()
    }

    override func scrollWheel(with event: NSEvent) {
        var dy = event.scrollingDeltaY, dx = event.scrollingDeltaX
        if !event.hasPreciseScrollingDeltas { dy *= lineHeight * 3; dx *= charWidth * 3 }
        if event.modifierFlags.contains(.shift) && dx == 0 { dx = dy; dy = 0 }
        if abs(dx) > 0 && !wordWrap {
            scrollX = max(0, min(scrollX - dx, max(0, contentWidth - textAreaWidth + 40)))
            changed()
        }
        guard dy != 0 else { return }
        pixelY -= dy
        while pixelY >= lineHeight { if scrollRows(1) == 0 { pixelY = 0; break }; pixelY -= lineHeight }
        while pixelY < 0 { if scrollRows(-1) == 0 { pixelY = 0; break }; pixelY += lineHeight }
        changed()
    }

    /// Scrolls so `offset` is visible (placing it a third of the way down
    /// when a jump is needed) and keeps the caret column in view.
    func reveal(_ offset: Int, centered: Bool = false) {
        layoutRowsIfNeeded()
        let (l, f, x) = locate(offset)
        let fullyVisible = rows.filter { $0.y >= 0 && $0.y + lineHeight <= bounds.height }
        let isVisible = fullyVisible.contains { $0.layout.start == l.start && $0.frag == f }
        if !isVisible || centered {
            var jumped = true
            if !centered, let last = rows.last {
                // Just below the viewport: scroll a few rows instead of jumping.
                var line = last.layout.start, frag = last.frag, k = 0
                while k < visibleRowCount {
                    let ll = layout(line)
                    if frag + 1 < ll.rowCount { frag += 1 } else if hasLine(after: ll) { line = ll.next; frag = 0 } else { break }
                    k += 1
                    if line == l.start && frag == f {
                        scrollRows(k + (rows.count - fullyVisible.count)); pixelY = 0
                        jumped = false; break
                    }
                }
                // Just above: put it at the top.
                if jumped, offset < topLine || (l.start == topLine && f < topRow) || (pixelY > 0 && rows.first?.layout.start == l.start) {
                    topLine = l.start; topRow = f; pixelY = 0; jumped = false
                }
            }
            if jumped {
                topLine = l.start; topRow = f; pixelY = 0
                scrollRows(-(visibleRowCount / 3))
            }
        }
        if !wordWrap {
            let margin = charWidth * 4
            if x < scrollX + margin { scrollX = max(0, x - margin * 2) }
            else if x > scrollX + textAreaWidth - margin { scrollX = x - textAreaWidth + margin * 3 }
        }
        changed()
    }

    private func changed() {
        rowsValid = false
        needsDisplay = true
        onStateChange?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged && wordWrap { cache.removeAll() }
        changed()
    }

    // MARK: Caret blink

    override func becomeFirstResponder() -> Bool { restartBlink(); needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { blinkTimer?.invalidate(); needsDisplay = true; return true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: window)
    }
    @objc private func windowKeyChanged() { restartBlink(); needsDisplay = true }

    private func restartBlink() {
        blinkTimer?.invalidate()
        caretOn = true
        guard Prefs.blinkCaret, window?.isKeyWindow == true else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caretOn.toggle()
            self.setNeedsDisplay(self.bounds)
            self.rowsValid = true   // a blink never changes the layout
        }
    }

    // MARK: Selection helpers

    private func normalizeSelections() {
        let len = document.length
        let p = sels[min(primary, sels.count - 1)]
        var list = sels.map { Sel(min(max(0, $0.anchor), len), min(max(0, $0.caret), len)) }
        list.sort { $0.lo < $1.lo || ($0.lo == $1.lo && $0.hi < $1.hi) }
        var merged: [Sel] = []
        for s in list {
            if let last = merged.last, s.lo < last.hi || (s.lo == last.hi && (s.isEmpty || last.isEmpty) && s.lo == last.lo) || s == last {
                let lo = min(last.lo, s.lo), hi = max(last.hi, s.hi)
                merged[merged.count - 1] = last.caret >= last.anchor ? Sel(lo, hi) : Sel(hi, lo)
            } else {
                merged.append(s)
            }
        }
        sels = merged.isEmpty ? [Sel(0, 0)] : merged
        primary = sels.firstIndex { $0.lo <= p.caret && p.caret <= $0.hi } ?? sels.count - 1
    }

    private func selectionChanged(reveal r: Bool = true) {
        normalizeSelections()
        updateBracketPair()
        caretOn = true
        restartBlink()
        if r { reveal(caret) } else { changed() }
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    func setSelections(_ ranges: [Range<Int>], primaryIndex: Int? = nil, reveal r: Bool = true, centered: Bool = false) {
        guard !ranges.isEmpty else { return }
        sels = ranges.map { Sel($0) }
        primary = primaryIndex ?? ranges.count - 1
        desiredX = nil
        normalizeSelections()
        updateBracketPair()
        restartBlink()
        if r { reveal(caret, centered: centered) } else { changed() }
    }

    func select(_ range: Range<Int>) { setSelections([range], centered: true) }
    func moveCaret(to o: Int) { setSelections([o..<o], centered: true) }

    // MARK: Character / word / line boundaries

    private func previousCharBoundary(_ o: Int) -> Int {
        var p = max(0, o - 1)
        while p > 0, let b = document.byte(at: p), b & 0xC0 == 0x80, o - p < 4 { p -= 1 }
        if p > 0, document.byte(at: p) == 0x0A, document.byte(at: p - 1) == 0x0D { p -= 1 }
        return p
    }

    private func nextCharBoundary(_ o: Int) -> Int {
        let len = document.length
        if document.byte(at: o) == 0x0D, document.byte(at: o + 1) == 0x0A { return min(len, o + 2) }
        var p = min(len, o + 1)
        while p < len, let b = document.byte(at: p), b & 0xC0 == 0x80, p - o < 4 { p += 1 }
        return p
    }

    private enum CharClass { case word, space, newline, punct }
    private func charClass(_ b: UInt8) -> CharClass {
        if isWordChar(b) { return .word }
        if b == 0x20 || b == 0x09 { return .space }
        if b == 0x0A || b == 0x0D { return .newline }
        return .punct
    }
    private func isWordChar(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
    }

    /// macOS-style word movement: skip spaces/punctuation, then a word.
    private func wordRight(_ o: Int) -> Int {
        let len = document.length, limit = min(len, o + 65536)
        var p = o
        while p < limit, let b = document.byte(at: p), !isWordChar(b) { p += 1 }
        while p < limit, let b = document.byte(at: p), isWordChar(b) { p += 1 }
        return p
    }
    private func wordLeft(_ o: Int) -> Int {
        let limit = max(0, o - 65536)
        var p = o
        while p > limit, let b = document.byte(at: p - 1), !isWordChar(b) { p -= 1 }
        while p > limit, let b = document.byte(at: p - 1), isWordChar(b) { p -= 1 }
        return p
    }

    private func wordRange(at o: Int) -> Range<Int> {
        guard let b = document.byte(at: o) ?? document.byte(at: o - 1) else { return o..<o }
        let cls = charClass(b)
        if cls == .newline { return o..<o }
        var lo = o, hi = o
        while lo > 0, let x = document.byte(at: lo - 1), charClass(x) == cls, o - lo < 4096 { lo -= 1 }
        while let x = document.byte(at: hi), charClass(x) == cls, hi - o < 4096 { hi += 1 }
        if lo == hi, o > 0 { return wordRange(at: o - 1) }
        return lo..<hi
    }

    /// Logical line containing `o`: start, content end and next line start.
    private func logicalLine(_ o: Int) -> (start: Int, end: Int, next: Int) {
        let r = document.logicalLine(containing: o)
        var next = r.upperBound
        if document.byte(at: next) == 0x0D { next += 1 }
        if document.byte(at: next) == 0x0A { next += 1 }
        return (r.lowerBound, r.upperBound, next)
    }

    /// Start of the visual row containing `o` and its end.
    private func rowBounds(_ o: Int) -> (Int, Int) {
        let (l, f, _) = locate(o)
        let fr = l.fragments[f]
        var end = l.byteOffset(fr.range.upperBound)
        if f < l.rowCount - 1 { end = l.byteOffset(max(fr.range.lowerBound, fr.range.upperBound - 1)) }
        return (l.byteOffset(fr.range.lowerBound), f == l.rowCount - 1 ? l.contentEnd : end)
    }

    // MARK: Moving

    private func moveAll(extend: Bool, keepX: Bool = false, _ f: (Sel) -> Int) {
        sels = sels.map { s in
            let c = min(max(0, f(s)), document.length)
            return extend ? Sel(s.anchor, c) : Sel(c, c)
        }
        if !keepX { desiredX = nil }
        selectionChanged()
    }

    /// Offset `rows` visual rows above/below `o`, at the remembered x.
    private func verticalTarget(_ o: Int, rows n: Int, x: CGFloat) -> Int {
        var (l, f, _) = locate(o)
        if n > 0 {
            for _ in 0..<n {
                if f + 1 < l.rowCount { f += 1 }
                else if hasLine(after: l) { l = layout(l.next); f = 0 }
                else { return document.length }
            }
        } else {
            for _ in 0..<(-n) {
                if f > 0 { f -= 1 }
                else if l.start > 0 { l = layout(document.lineStart(containing: l.start - 1)); f = l.rowCount - 1 }
                else { return 0 }
            }
        }
        return l.byteOffset(l.index(atX: x, in: f))
    }

    private func verticalMove(_ n: Int, extend: Bool) {
        if !extend && sels.count == 1 && !sels[0].isEmpty {
            let s = sels[0]
            let o = n < 0 ? s.lo : s.hi
            sels = [Sel(o, o)]
        }
        let x = desiredX ?? locate(caret).x
        desiredX = x
        let primaryCaret = caret
        sels = sels.map { s in
            let sx = s.caret == primaryCaret ? x : locate(s.caret).x
            let c = verticalTarget(s.caret, rows: n, x: sx)
            return extend ? Sel(s.anchor, c) : Sel(c, c)
        }
        selectionChanged()
    }

    // MARK: Editing core

    private var canEdit: Bool {
        if document.isReadOnly { onReadOnlyEdit?(); NSSound.beep(); return false }
        return true
    }

    /// Applies one edit per selection (sorted, non-overlapping) as a single
    /// undo step, then places each caret at `caretInInsert` within its
    /// inserted text (default: after it) or selects the inserted text.
    private func edit(_ name: String, coalesce: PieceTable.Coalesce = .none, selectInserted: Bool = false,
                      _ make: (Sel) -> (Range<Int>, [UInt8], caret: Int?)?) {
        guard canEdit else { return }
        if markedText != nil { markedText = nil }
        var edits: [(Range<Int>, [UInt8])] = []
        var carets: [Int?] = []
        for s in sels {
            guard let e = make(s) else { continue }
            if let last = edits.last, e.0.lowerBound < last.0.upperBound { continue }
            edits.append((e.0, e.1)); carets.append(e.caret)
        }
        guard !edits.isEmpty else { return }
        let before = sels.map(\.range)
        var after: [Range<Int>] = []
        var delta = 0
        for (i, e) in edits.enumerated() {
            let start = e.0.lowerBound + delta
            if selectInserted { after.append(start..<start + e.1.count) }
            else { let c = start + (carets[i] ?? e.1.count); after.append(c..<c) }
            delta += e.1.count - e.0.count
        }
        applyingOwnEdit = true
        if edits.count == 1 && coalesce != .none {
            document.replace(edits[0].0, with: edits[0].1, coalesce: coalesce, name: name)
        } else if edits.count == 1 {
            document.replace(edits[0].0, with: edits[0].1, name: name)
        } else {
            document.applyEdits(edits, name: name, before: before, after: after)
        }
        applyingOwnEdit = false
        sels = after.map { Sel($0) }
        primary = min(primary, sels.count - 1)
        desiredX = nil
        selectionChanged()
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Replaces every selection with `bytes`.
    func insert(_ bytes: [UInt8], name: String = "Typing", coalesce: PieceTable.Coalesce = .none) {
        edit(name, coalesce: coalesce) { s in (s.range, bytes, nil) }
    }

    func replaceSelection(with text: String) { insert(Array(text.utf8), name: "Replace") }

    /// Replaces `range` (e.g. a find match) and selects the result.
    func replace(_ range: Range<Int>, with bytes: [UInt8], name: String) {
        guard canEdit else { return }
        applyingOwnEdit = true
        document.replace(range, with: bytes, name: name)
        applyingOwnEdit = false
        let r = range.lowerBound..<range.lowerBound + bytes.count
        sels = [Sel(r)]; primary = 0
        selectionChanged()
    }

    private var indentUnit: [UInt8] {
        Prefs.indentWithSpaces ? Array(repeating: 0x20, count: max(1, Prefs.tabWidth)) : [0x09]
    }

    private func leadingWhitespace(_ lineStart: Int, upTo limit: Int) -> [UInt8] {
        var out: [UInt8] = []
        var p = lineStart
        while p < limit, let b = document.byte(at: p), b == 0x20 || b == 0x09 { out.append(b); p += 1 }
        return out
    }

    private static let pairs: [UInt8: UInt8] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D, 0x22: 0x22, 0x27: 0x27]

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = nil
        cache.removeAll()
        guard !s.isEmpty else { changed(); return }
        let bytes = Array(s.utf8)
        // Auto-close brackets and quotes, and type over a closer.
        if Prefs.autoCloseBrackets, bytes.count == 1, sels.count == 1 {
            let b = bytes[0], s0 = sels[0]
            if s0.isEmpty, [0x29, 0x5D, 0x7D, 0x22, 0x27].contains(b), document.byte(at: s0.caret) == b {
                moveAll(extend: false) { $0.caret + 1 }; return
            }
            if let close = Self.pairs[b], s0.isEmpty {
                let next = document.byte(at: s0.caret)
                if next == nil || next == 0x20 || next == 0x0A || next == 0x0D || next == 0x29 || next == 0x5D || next == 0x7D {
                    edit("Typing") { s in (s.range, [b, close], 1) }
                    return
                }
            }
        }
        insert(bytes, coalesce: .typing)
    }

    override func insertText(_ insertString: Any) { insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0)) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard canEdit else { return }
        if markedText == nil {
            // Starting composition: collapse to one caret, replacing any selection.
            if sels.count > 1 { sels = [sels[primary]]; primary = 0 }
            if !sels[0].isEmpty { insert([], name: "Typing") }
        }
        markedText = s.isEmpty ? nil : s
        cache.removeAll()
        changed()
    }

    func unmarkText() { markedText = nil; cache.removeAll(); changed() }
    func selectedRange() -> NSRange { NSRange(location: caret, length: selection.count) }
    func markedRange() -> NSRange {
        markedText.map { NSRange(location: caret, length: ($0 as NSString).length) } ?? NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { markedText != nil }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }
    func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return NSNotFound }
        return offset(at: convert(window.convertPoint(fromScreen: point), from: nil))
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let p = caretPoint(caret) ?? NSPoint(x: textX, y: 0)
        let r = NSRect(x: p.x, y: p.y, width: 2, height: lineHeight)
        guard let window else { return r }
        return window.convertToScreen(convert(r, to: nil))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        NSCursor.setHiddenUntilMouseMoves(true)
        interpretKeyEvents([event])
    }

    override func cancelOperation(_ sender: Any?) {
        if sels.count > 1 { sels = [sels[primary]]; primary = 0; selectionChanged() }
        else { onEscape?() }
    }

    /// Standard key bindings (arrows, delete, return, page keys...) arrive
    /// here from `interpretKeyEvents` as selectors.
    override func doCommand(by selector: Selector) {
        let name = NSStringFromSelector(selector)
        if handle(name) { return }
        if responds(to: selector) { perform(selector, with: nil); return }
        super.doCommand(by: selector)
    }

    private func handle(_ name: String) -> Bool {
        let page = max(1, visibleRowCount - 1)
        switch name {
        case "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:": insertNewline()
        case "insertTab:", "insertTabIgnoringFieldEditor:": insertTabKey()
        case "insertBacktab:": shiftLeft(nil)
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:": deleteBackwardKey()
        case "deleteForward:":
            edit("Typing", coalesce: .deleteForward) { s in s.isEmpty ? (s.caret..<nextCharBoundary(s.caret), [], 0) : (s.range, [], 0) }
        case "deleteWordBackward:":
            edit("Delete Word") { s in s.isEmpty ? (wordLeft(s.caret)..<s.caret, [], 0) : (s.range, [], 0) }
        case "deleteWordForward:":
            edit("Delete Word") { s in s.isEmpty ? (s.caret..<wordRight(s.caret), [], 0) : (s.range, [], 0) }
        case "deleteToBeginningOfLine:", "deleteToBeginningOfParagraph:":
            edit("Delete") { s in
                guard s.isEmpty else { return (s.range, [], 0) }
                let st = rowBounds(s.caret).0
                let from = st == s.caret ? previousCharBoundary(s.caret) : st
                return from < s.caret ? (from..<s.caret, [], 0) : nil
            }
        case "deleteToEndOfLine:", "deleteToEndOfParagraph:":
            edit("Delete") { s in
                guard s.isEmpty else { return (s.range, [], 0) }
                let e = logicalLine(s.caret).end
                return e > s.caret ? (s.caret..<e, [], 0) : (s.caret..<nextCharBoundary(s.caret), [], 0)
            }
        case "transpose:": transpose()
        case "moveLeft:":
            moveAll(extend: false) { $0.isEmpty ? previousCharBoundary($0.caret) : $0.lo }
        case "moveRight:":
            moveAll(extend: false) { $0.isEmpty ? nextCharBoundary($0.caret) : $0.hi }
        case "moveLeftAndModifySelection:", "moveBackwardAndModifySelection:": moveAll(extend: true) { previousCharBoundary($0.caret) }
        case "moveRightAndModifySelection:", "moveForwardAndModifySelection:": moveAll(extend: true) { nextCharBoundary($0.caret) }
        case "moveBackward:": moveAll(extend: false) { previousCharBoundary($0.caret) }
        case "moveForward:": moveAll(extend: false) { nextCharBoundary($0.caret) }
        case "moveWordLeft:", "moveWordBackward:": moveAll(extend: false) { wordLeft($0.caret) }
        case "moveWordRight:", "moveWordForward:": moveAll(extend: false) { wordRight($0.caret) }
        case "moveWordLeftAndModifySelection:", "moveWordBackwardAndModifySelection:": moveAll(extend: true) { wordLeft($0.caret) }
        case "moveWordRightAndModifySelection:", "moveWordForwardAndModifySelection:": moveAll(extend: true) { wordRight($0.caret) }
        case "moveUp:": verticalMove(-1, extend: false)
        case "moveDown:": verticalMove(1, extend: false)
        case "moveUpAndModifySelection:": verticalMove(-1, extend: true)
        case "moveDownAndModifySelection:": verticalMove(1, extend: true)
        case "pageUp:": scrollRows(-page); verticalMove(-page, extend: false)
        case "pageDown:": scrollRows(page); verticalMove(page, extend: false)
        case "pageUpAndModifySelection:": scrollRows(-page); verticalMove(-page, extend: true)
        case "pageDownAndModifySelection:": scrollRows(page); verticalMove(page, extend: true)
        case "scrollPageUp:": scrollRows(-page)
        case "scrollPageDown:": scrollRows(page)
        case "scrollLineUp:": scrollRows(-1)
        case "scrollLineDown:": scrollRows(1)
        case "moveToLeftEndOfLine:": moveAll(extend: false) { smartHome($0.caret) }
        case "moveToLeftEndOfLineAndModifySelection:": moveAll(extend: true) { smartHome($0.caret) }
        case "moveToRightEndOfLine:": moveAll(extend: false) { rowBounds($0.caret).1 }
        case "moveToRightEndOfLineAndModifySelection:": moveAll(extend: true) { rowBounds($0.caret).1 }
        case "moveToBeginningOfLine:", "moveToBeginningOfParagraph:": moveAll(extend: false) { logicalLine($0.caret).start }
        case "moveToBeginningOfLineAndModifySelection:", "moveToBeginningOfParagraphAndModifySelection:":
            moveAll(extend: true) { logicalLine($0.caret).start }
        case "moveToEndOfLine:", "moveToEndOfParagraph:": moveAll(extend: false) { logicalLine($0.caret).end }
        case "moveToEndOfLineAndModifySelection:", "moveToEndOfParagraphAndModifySelection:":
            moveAll(extend: true) { logicalLine($0.caret).end }
        case "moveParagraphBackwardAndModifySelection:": moveAll(extend: true) { s in
            let st = logicalLine(s.caret).start
            return st == s.caret && st > 0 ? logicalLine(st - 1).start : st }
        case "moveParagraphForwardAndModifySelection:": moveAll(extend: true) { s in
            let l = logicalLine(s.caret)
            return l.end == s.caret ? logicalLine(l.next).end : l.end }
        case "moveToBeginningOfDocument:": sels = [Sel(0, 0)]; primary = 0; selectionChanged()
        case "moveToEndOfDocument:": let e = document.length; sels = [Sel(e, e)]; primary = 0; selectionChanged()
        case "moveToBeginningOfDocumentAndModifySelection:": sels = [Sel(sels[primary].anchor, 0)]; primary = 0; selectionChanged()
        case "moveToEndOfDocumentAndModifySelection:": sels = [Sel(sels[primary].anchor, document.length)]; primary = 0; selectionChanged()
        case "scrollToBeginningOfDocument:": topLine = 0; topRow = 0; pixelY = 0; changed()
        case "scrollToEndOfDocument:": scroll(toFraction: 1)
        case "centerSelectionInVisibleArea:": reveal(caret, centered: true)
        case "selectAll:": selectAll(nil)
        case "selectLine:": selectLine(nil)
        case "selectParagraph:": selectLine(nil)
        case "selectWord:": sels = sels.map { Sel(wordRange(at: $0.caret)) }; selectionChanged()
        case "uppercaseWord:": transformCase(.upper)
        case "lowercaseWord:": transformCase(.lower)
        case "capitalizeWord:": transformCase(.title)
        case "noop:": NSSound.beep()
        default: return false
        }
        return true
    }

    /// ⌘← goes to the first non-blank character, then to the line start.
    private func smartHome(_ o: Int) -> Int {
        let (rowStart, _) = rowBounds(o)
        let l = logicalLine(o)
        guard rowStart == l.start else { return rowStart }
        let indent = l.start + leadingWhitespace(l.start, upTo: l.end).count
        return o == indent ? l.start : indent
    }

    private func insertNewline() {
        let nl = document.newlineBytes
        guard Prefs.autoIndent else { insert(nl, name: "Typing"); return }
        edit("Typing") { s in
            let line = logicalLine(s.lo)
            var indent = leadingWhitespace(line.start, upTo: s.lo)
            var before = s.lo
            while before > line.start, let b = document.byte(at: before - 1), b == 0x20 || b == 0x09 { before -= 1 }
            let opener = before > line.start ? document.byte(at: before - 1) : nil
            let after = document.byte(at: s.hi)
            if let o = opener, [0x7B, 0x5B, 0x28].contains(o) {
                let base = indent
                indent += indentUnit
                if let a = after, (o == 0x7B && a == 0x7D) || (o == 0x5B && a == 0x5D) || (o == 0x28 && a == 0x29) {
                    return (s.range, nl + indent + nl + base, nl.count + indent.count)
                }
            }
            return (s.range, nl + indent, nil)
        }
    }

    private func insertTabKey() {
        if sels.contains(where: { !$0.isEmpty && spansLines($0) }) { shiftRight(nil); return }
        if Prefs.indentWithSpaces {
            edit("Typing", coalesce: sels.count == 1 ? .typing : .none) { s in
                let col = column(of: s.lo)
                let n = Prefs.tabWidth - col % max(1, Prefs.tabWidth)
                return (s.range, Array(repeating: 0x20, count: n), nil)
            }
        } else {
            insert([0x09], coalesce: .typing)
        }
    }

    /// Visual column (tabs expanded) of `o` in its line.
    private func column(of o: Int) -> Int {
        let st = logicalLine(o).start
        var col = 0
        for b in document.buffer.read(max(st, o - 4096)..<o) {
            if b == 0x09 { col += Prefs.tabWidth - col % max(1, Prefs.tabWidth) }
            else if b & 0xC0 != 0x80 { col += 1 }
        }
        return col
    }

    private func spansLines(_ s: Sel) -> Bool { document.firstNewline(in: s.lo..<s.hi) != nil }

    private func deleteBackwardKey() {
        edit("Typing", coalesce: sels.count == 1 ? .deleteBackward : .none) { s in
            guard s.isEmpty else { return (s.range, [], 0) }
            guard s.caret > 0 else { return nil }
            // In leading spaces, delete back to the previous tab stop.
            if Prefs.indentWithSpaces {
                let l = logicalLine(s.caret)
                let ws = leadingWhitespace(l.start, upTo: s.caret)
                if ws.count == s.caret - l.start, !ws.isEmpty, ws.allSatisfy({ $0 == 0x20 }) {
                    let col = ws.count
                    let n = col % Prefs.tabWidth == 0 ? Prefs.tabWidth : col % Prefs.tabWidth
                    return (s.caret - min(n, col)..<s.caret, [], 0)
                }
            }
            // Delete an empty auto-closed pair together.
            if Prefs.autoCloseBrackets, let a = document.byte(at: s.caret - 1), let close = Self.pairs[a],
               document.byte(at: s.caret) == close {
                return (s.caret - 1..<s.caret + 1, [], 0)
            }
            return (previousCharBoundary(s.caret)..<s.caret, [], 0)
        }
    }

    private func transpose() {
        edit("Transpose") { s in
            guard s.isEmpty, s.caret > 0 else { return nil }
            let c = s.caret == logicalLine(s.caret).end ? previousCharBoundary(s.caret) : s.caret
            let a = previousCharBoundary(c), b = nextCharBoundary(c)
            guard a < c, c < b else { return nil }
            let first = document.buffer.read(a..<c), second = document.buffer.read(c..<b)
            return (a..<b, second + first, b - a)
        }
    }

    // MARK: Mouse

    override func resetCursorRects() {
        addCursorRect(NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height), cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if markedText != nil { inputContext?.discardMarkedText(); markedText = nil }
        let p = convert(event.locationInWindow, from: nil)
        lastDragPoint = p
        let o = offset(at: p)
        let mods = event.modifierFlags
        desiredX = nil
        if p.x < gutterWidth {
            let l = logicalLine(o)
            dragMode = .gutter
            if mods.contains(.shift) {
                let s = sels[primary]
                sels = [Sel(min(s.anchor, l.start), max(s.caret, l.next))]
            } else {
                sels = [Sel(l.start, l.next)]
            }
            primary = 0
            dragOrigin = Sel(l.start, l.next)
            selectionChanged(reveal: false)
            return
        }
        if mods.contains(.option) && !mods.contains(.command) {
            dragMode = .column
            let ls = document.lineStart(containing: o)
            dragColumnStart = (ls, p.x - textOriginX)
            sels = [Sel(o, o)]; primary = 0
            selectionChanged(reveal: false)
            return
        }
        switch event.clickCount {
        case 3:
            let l = logicalLine(o)
            dragMode = .line
            dragOrigin = Sel(l.start, l.next)
            setPrimary(dragOrigin, add: mods.contains(.command))
        case 2:
            dragMode = .word
            dragOrigin = Sel(wordRange(at: o))
            setPrimary(dragOrigin, add: mods.contains(.command))
        default:
            dragMode = .char
            if mods.contains(.shift) {
                sels[primary] = Sel(sels[primary].anchor, o)
                selectionChanged(reveal: false)
            } else if mods.contains(.command) {
                if let i = sels.firstIndex(where: { $0.isEmpty && $0.caret == o }), sels.count > 1 {
                    sels.remove(at: i); primary = sels.count - 1
                    selectionChanged(reveal: false)
                } else {
                    setPrimary(Sel(o, o), add: true)
                }
            } else {
                setPrimary(Sel(o, o), add: false)
            }
            dragOrigin = Sel(sels[primary].anchor, sels[primary].anchor)
        }
    }

    private func setPrimary(_ s: Sel, add: Bool) {
        if add { sels.append(s); primary = sels.count - 1 } else { sels = [s]; primary = 0 }
        let keep = sels[primary]
        normalizeSelections()
        primary = sels.firstIndex { $0.lo <= keep.lo && keep.hi <= $0.hi } ?? primary
        updateBracketPair()
        restartBlink()
        changed()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        lastDragPoint = p
        dragTo(p)
        if p.y < 0 || p.y > bounds.height || (!wordWrap && (p.x > bounds.width || (p.x < textX && scrollX > 0))) {
            if autoscrollTimer == nil {
                autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    let pt = self.lastDragPoint
                    if pt.y < 0 { self.scrollRows(-max(1, Int(-pt.y / self.lineHeight))) }
                    else if pt.y > self.bounds.height { self.scrollRows(max(1, Int((pt.y - self.bounds.height) / self.lineHeight))) }
                    if !self.wordWrap {
                        if pt.x > self.bounds.width { self.scrollHorizontally(to: self.scrollX + self.charWidth * 2) }
                        else if pt.x < self.textX { self.scrollHorizontally(to: self.scrollX - self.charWidth * 2) }
                    }
                    self.dragTo(pt)
                }
            }
        } else {
            autoscrollTimer?.invalidate(); autoscrollTimer = nil
        }
    }

    private func dragTo(_ p: NSPoint) {
        let clamped = NSPoint(x: p.x, y: min(max(p.y, 0), bounds.height - 1))
        let o = offset(at: clamped)
        switch dragMode {
        case .none: return
        case .char:
            sels[primary] = Sel(sels[primary].anchor, p.y < 0 && topLine == 0 && topRow == 0 ? 0 : o)
        case .word:
            let w = wordRange(at: o)
            sels[primary] = o < dragOrigin.lo ? Sel(dragOrigin.hi, w.lowerBound) : Sel(dragOrigin.lo, max(w.upperBound, dragOrigin.hi))
        case .line, .gutter:
            let l = logicalLine(o)
            sels[primary] = l.start < dragOrigin.lo ? Sel(dragOrigin.hi, l.start) : Sel(dragOrigin.lo, max(l.next, dragOrigin.hi))
        case .column:
            guard let start = dragColumnStart else { return }
            let x1 = clamped.x - textOriginX
            let endLine = document.lineStart(containing: o)
            var lines: [Int] = []
            var line = min(start.line, endLine)
            let last = max(start.line, endLine)
            while lines.count < 20_000 {
                lines.append(line)
                if line >= last { break }
                let next = document.nextLineStart(after: line).next
                if next <= line { break }
                line = next
            }
            let xa = min(start.x, x1), xb = max(start.x, x1)
            sels = lines.map { ls in
                let l = layout(ls)
                let a = l.byteOffset(l.index(atX: xa, in: 0)), b = l.byteOffset(l.index(atX: xb, in: 0))
                return x1 >= start.x ? Sel(a, b) : Sel(b, a)
            }
            primary = endLine >= start.line ? sels.count - 1 : 0
        }
        updateBracketPair()
        changed()
    }

    override func mouseUp(with event: NSEvent) {
        autoscrollTimer?.invalidate(); autoscrollTimer = nil
        if dragMode != .none {
            dragMode = .none
            let keep = sels[primary]
            normalizeSelections()
            primary = sels.firstIndex { $0.lo <= keep.caret && keep.caret <= $0.hi } ?? primary
            changed()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let o = offset(at: p)
        if !sels.contains(where: { $0.lo <= o && o <= $0.hi && !$0.isEmpty }) { setSelections([o..<o], reveal: false) }
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, _ key: String = "") { m.addItem(withTitle: title, action: sel, keyEquivalent: key) }
        add("Cut", #selector(cut(_:)))
        add("Copy", #selector(copy(_:)))
        add("Paste", #selector(paste(_:)))
        m.addItem(.separator())
        add("Select All", #selector(selectAll(_:)))
        add("Select Line", #selector(selectLine(_:)))
        m.addItem(.separator())
        add("Find Selection", #selector(EditorWindowController.findSelection(_:)))
        add("Toggle Comment", #selector(toggleComment(_:)))
        add("Uppercase", #selector(uppercaseSelection(_:)))
        add("Lowercase", #selector(lowercaseSelection(_:)))
        m.addItem(.separator())
        add("Toggle Bookmark", #selector(EditorWindowController.toggleBookmark(_:)))
        return m
    }

    // MARK: Bracket matching

    private func updateBracketPair() {
        bracketPair = nil
        guard Prefs.matchBrackets, sels.count == 1, sels[0].isEmpty else { return }
        let c = sels[0].caret
        let opens: [UInt8: UInt8] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
        let closes: [UInt8: UInt8] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]
        for at in [c - 1, c] {
            guard let b = document.byte(at: at) else { continue }
            if let close = opens[b], let m = scanMatch(from: at, open: b, close: close, forward: true) { bracketPair = (at, m); return }
            if let open = closes[b], let m = scanMatch(from: at, open: open, close: b, forward: false) { bracketPair = (m, at); return }
        }
    }

    private func scanMatch(from: Int, open: UInt8, close: UInt8, forward: Bool) -> Int? {
        var depth = 0
        var found: Int?
        let snap = document.snapshot()
        let limit = 1 << 20
        if forward {
            snap.forEachChunk(in: from..<min(snap.length, from + limit)) { buf, off in
                for i in 0..<buf.count {
                    let b = buf[i]
                    if b == open { depth += 1 } else if b == close { depth -= 1; if depth == 0 { found = off + i; return false } }
                }
                return true
            }
        } else {
            snap.forEachChunkReversed(in: max(0, from - limit)..<from + 1) { buf, off in
                var i = buf.count - 1
                while i >= 0 {
                    let b = buf[i]
                    if b == close { depth += 1 } else if b == open { depth -= 1; if depth == 0 { found = off + i; return false } }
                    i -= 1
                }
                return true
            }
        }
        return found
    }

    @objc func jumpToMatchingBracket(_ sender: Any?) {
        guard let (a, b) = bracketPair else { NSSound.beep(); return }
        let c = caret
        let target = abs(c - a) <= 1 && c <= a + 1 ? b + 1 : a
        setSelections([target..<target])
    }

    // MARK: Selection commands

    @objc override func selectAll(_ sender: Any?) {
        sels = [Sel(0, document.length)]; primary = 0
        selectionChanged(reveal: false)
    }
    @objc func selectEverything(_ sender: Any?) { selectAll(sender) }

    @objc override func selectLine(_ sender: Any?) {
        sels = sels.map { s in
            let a = logicalLine(s.lo), b = logicalLine(max(s.lo, s.hi - (s.isEmpty ? 0 : 1)))
            return Sel(a.start, b.next)
        }
        selectionChanged()
    }

    @objc func splitSelectionIntoLines(_ sender: Any?) {
        var out: [Sel] = []
        for s in sels {
            guard !s.isEmpty, spansLines(s) else { out.append(s); continue }
            var p = s.lo
            while p < s.hi && out.count < 50_000 {
                let l = logicalLine(p)
                out.append(Sel(p, min(l.end, s.hi)))
                if l.next <= p { break }
                p = l.next
            }
        }
        sels = out; primary = out.count - 1
        selectionChanged()
    }

    @objc func addCaretAbove(_ sender: Any?) { addCaret(-1) }
    @objc func addCaretBelow(_ sender: Any?) { addCaret(1) }
    private func addCaret(_ dir: Int) {
        let edge = dir < 0 ? sels.first! : sels.last!
        let x = desiredX ?? locate(edge.caret).x
        let o = verticalTarget(edge.caret, rows: dir, x: x)
        guard o != edge.caret else { NSSound.beep(); return }
        sels.append(Sel(o, o))
        primary = sels.count - 1
        let keepX = x
        normalizeSelections()
        desiredX = keepX
        primary = dir < 0 ? 0 : sels.count - 1
        updateBracketPair(); restartBlink()
        reveal(o)
    }

    /// ⌘D: select the word at the caret, or add the next occurrence of the
    /// selected text as another selection.
    @objc func addNextOccurrence(_ sender: Any?) {
        let p = sels[primary]
        if p.isEmpty {
            sels[primary] = Sel(wordRange(at: p.caret)); selectionChanged(); return
        }
        let needle = String(decoding: document.buffer.read(p.range), as: UTF8.self)
        guard !needle.isEmpty, p.range.count <= 4096, let pat = try? SearchPattern(needle, options: .init()) else { return }
        let snap = document.snapshot()
        let from = sels.last!.hi
        let searcher = TextSearcher()
        var found: Range<Int>?
        // Look ahead a bounded amount so this never stalls on a huge file.
        var opts = pat.options; opts.wrapAround = false
        let window = 256 << 20
        opts.range = from..<min(snap.length, from + window)
        if let p1 = try? SearchPattern(needle, options: opts) { found = searcher.find(p1, in: snap, from: from) }
        if found == nil {
            opts.range = 0..<min(sels.first!.lo, window)
            if let p2 = try? SearchPattern(needle, options: opts) { found = searcher.find(p2, in: snap, from: 0) }
        }
        guard let r = found, !sels.contains(where: { $0.range == r }) else { NSSound.beep(); return }
        sels.append(Sel(r)); primary = sels.count - 1
        let keep = r
        normalizeSelections()
        primary = sels.firstIndex { $0.range == keep } ?? primary
        updateBracketPair(); restartBlink()
        reveal(r.upperBound)
    }

    /// Selects every occurrence of the selection (or word) in the document,
    /// up to 20,000.
    @objc func selectAllOccurrences(_ sender: Any?) {
        var p = sels[primary]
        if p.isEmpty { p = Sel(wordRange(at: p.caret)) }
        guard !p.isEmpty, p.range.count <= 4096 else { NSSound.beep(); return }
        let needle = String(decoding: document.buffer.read(p.range), as: UTF8.self)
        guard let pat = try? SearchPattern(needle, options: .init()) else { return }
        var found: [Range<Int>] = []
        TextSearcher().findAll(pat, in: document.snapshot()) { r, _ in found.append(r); return found.count < 20_000 }
        guard !found.isEmpty else { return }
        setSelections(found, primaryIndex: found.firstIndex(of: p.range) ?? 0, reveal: false)
    }

    // MARK: Clipboard

    private static let clipboardLimit = 256 << 20

    private func selectedText(limit: Int = BigTextView.clipboardLimit) -> String? {
        let total = sels.reduce(0) { $0 + $1.range.count }
        guard total <= limit else { return nil }
        let parts = sels.filter { !$0.isEmpty }.map { String(decoding: document.buffer.read($0.range), as: UTF8.self) }
        return parts.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard sels.contains(where: { !$0.isEmpty }) else { NSSound.beep(); return }
        guard let s = selectedText() else {
            let a = NSAlert()
            a.messageText = "The selection is too large to copy"
            a.informativeText = "The clipboard holds up to 256 MB. Use Save As or File > Export Selection to write larger selections to a file."
            if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        guard canEdit, sels.contains(where: { !$0.isEmpty }) else { return }
        if selectedText() == nil {
            let a = NSAlert()
            a.messageText = "Delete the selection without copying it?"
            a.informativeText = "The selection is larger than the 256 MB clipboard limit."
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            insert([], name: "Cut")
            return
        }
        copy(sender)
        edit("Cut") { s in s.isEmpty ? nil : (s.range, [], 0) }
    }

    /// Converts pasted line breaks to the document's style.
    private func normalizeNewlines(_ s: String) -> [UInt8] {
        let unified = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if document.lineEnding == .crlf { return Array(unified.replacingOccurrences(of: "\n", with: "\r\n").utf8) }
        return Array(unified.utf8)
    }

    @objc func paste(_ sender: Any?) {
        guard canEdit, let s = NSPasteboard.general.string(forType: .string) else { return }
        // Pasting N lines into N carets puts one line at each caret.
        let lines = s.components(separatedBy: "\n")
        if sels.count > 1 && lines.count == sels.count {
            var i = 0
            edit("Paste") { sel in
                defer { i += 1 }
                return (sel.range, normalizeNewlines(lines[i]), nil)
            }
            return
        }
        insert(normalizeNewlines(s), name: "Paste")
    }

    @objc func delete(_ sender: Any?) { edit("Delete") { s in s.isEmpty ? nil : (s.range, [], 0) } }

    @objc func undo(_ sender: Any?) {
        guard canEdit else { return }
        guard let r = document.undo() else { NSSound.beep(); return }
        restore(r)
    }

    @objc func redo(_ sender: Any?) {
        guard canEdit else { return }
        guard let r = document.redo() else { NSSound.beep(); return }
        restore(r)
    }

    private func restore(_ ranges: [Range<Int>]) {
        let len = document.length
        let clamped = ranges.isEmpty ? [min(caret, len)..<min(caret, len)]
            : ranges.map { min($0.lowerBound, len)..<min($0.upperBound, len) }
        setSelections(clamped, primaryIndex: 0)
    }

    // MARK: Line commands

    /// The logical lines touched by each selection, merged.
    private func selectedLineSpans() -> [Range<Int>] {
        var spans: [Range<Int>] = []
        for s in sels {
            let a = logicalLine(s.lo).start
            let lastByte = s.isEmpty ? s.lo : max(s.lo, s.hi - 1)
            let b = s.hi > s.lo && s.hi == logicalLine(s.hi).start && s.hi > a ? logicalLine(s.hi - 1).next : logicalLine(lastByte).next
            if let last = spans.last, a <= last.upperBound { spans[spans.count - 1] = last.lowerBound..<max(last.upperBound, b) }
            else { spans.append(a..<b) }
        }
        return spans
    }

    /// Start offsets of every line in `span` (capped).
    private func lineStarts(in span: Range<Int>, cap: Int = 2_000_000) -> [Int] {
        var out: [Int] = []
        var p = span.lowerBound
        let snap = document.snapshot()
        while p < span.upperBound || (p == span.lowerBound && span.isEmpty) {
            out.append(p)
            if out.count >= cap { break }
            guard let nl = snap.firstNewline(in: p..<span.upperBound) else { break }
            p = nl + 1
        }
        return out
    }

    private var tooLargeForLineCommand: Bool {
        let total = selectedLineSpans().reduce(0) { $0 + $1.count }
        if total > 512 << 20 {
            let a = NSAlert()
            a.messageText = "The selection is too large for this command"
            a.informativeText = "Line commands work on selections up to 512 MB."
            if let w = window { a.beginSheetModal(for: w) }
            return true
        }
        return false
    }

    /// Edits at many line starts, keeping the selections attached to the text.
    private func lineEdits(_ name: String, _ edits: [(Range<Int>, [UInt8])]) {
        guard canEdit, !edits.isEmpty else { return }
        let before = sels
        applyingOwnEdit = true
        document.applyEdits(edits, name: name, before: before.map(\.range), after: before.map(\.range))
        applyingOwnEdit = false
        let change = DocumentChange(edits: edits.map { ($0.0, $0.1.count) }, isReset: false)
        let len = document.length
        // Keep selections covering whole lines when they did.
        sels = before.map { s in
            let a = change.map(s.anchor, newLength: len), c = change.map(s.caret, newLength: len)
            return Sel(a, c)
        }
        selectionChanged(reveal: false)
    }

    @objc func shiftRight(_ sender: Any?) {
        guard !tooLargeForLineCommand else { return }
        let unit = indentUnit
        var edits: [(Range<Int>, [UInt8])] = []
        for span in selectedLineSpans() {
            for st in lineStarts(in: span) where document.byte(at: st) != 0x0A && document.byte(at: st) != 0x0D && st < document.length {
                edits.append((st..<st, unit))
            }
        }
        lineEdits("Shift Right", edits)
    }

    @objc func shiftLeft(_ sender: Any?) {
        guard !tooLargeForLineCommand else { return }
        var edits: [(Range<Int>, [UInt8])] = []
        for span in selectedLineSpans() {
            for st in lineStarts(in: span) {
                if document.byte(at: st) == 0x09 { edits.append((st..<st + 1, [])); continue }
                var n = 0
                while n < Prefs.tabWidth, document.byte(at: st + n) == 0x20 { n += 1 }
                if n > 0 { edits.append((st..<st + n, [])) }
            }
        }
        lineEdits("Shift Left", edits)
    }

    @objc func toggleComment(_ sender: Any?) {
        guard !tooLargeForLineCommand else { return }
        let lang = document.language
        if let prefix = lang.lineComment {
            let p = Array(prefix.utf8)
            let bare = Array(prefix.trimmingCharacters(in: .whitespaces).utf8)
            var starts: [(Int, Int)] = []   // (line start, first non-blank)
            for span in selectedLineSpans() {
                for st in lineStarts(in: span) {
                    let l = logicalLine(st)
                    let ws = leadingWhitespace(st, upTo: l.end).count
                    if st + ws < l.end { starts.append((st, st + ws)) }
                }
            }
            guard !starts.isEmpty else { return }
            let allCommented = starts.allSatisfy { document.buffer.read($0.1..<$0.1 + bare.count) == bare }
            var edits: [(Range<Int>, [UInt8])] = []
            if allCommented {
                for (_, fnb) in starts {
                    let has = document.buffer.read(fnb..<fnb + p.count) == p
                    edits.append((fnb..<fnb + (has ? p.count : bare.count), []))
                }
            } else {
                let minIndent = starts.map { $0.1 - $0.0 }.min() ?? 0
                for (st, _) in starts { edits.append((st + minIndent..<st + minIndent, p)) }
            }
            lineEdits("Toggle Comment", edits)
        } else if let (open, close) = lang.blockComment {
            edit("Toggle Comment", selectInserted: true) { s in
                let r = s.isEmpty ? logicalLine(s.lo).start..<logicalLine(s.lo).end : s.range
                let text = String(decoding: document.buffer.read(r), as: UTF8.self)
                let t = text.trimmingCharacters(in: .whitespaces)
                let o = open.trimmingCharacters(in: .whitespaces), c = close.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(o) && t.hasSuffix(c) && t.count >= o.count + c.count {
                    var inner = String(t.dropFirst(o.count).dropLast(c.count))
                    if inner.hasPrefix(" ") { inner.removeFirst() }
                    if inner.hasSuffix(" ") { inner.removeLast() }
                    return (r, Array(inner.utf8), nil)
                }
                return (r, Array((open + text + close).utf8), nil)
            }
        } else {
            NSSound.beep()
        }
    }

    @objc func duplicateLines(_ sender: Any?) {
        guard !tooLargeForLineCommand else { return }
        var edits: [(Range<Int>, [UInt8])] = []
        for span in selectedLineSpans() {
            var bytes = document.buffer.read(span)
            if bytes.last != 0x0A { bytes = document.newlineBytes + bytes; edits.append((span.upperBound..<span.upperBound, bytes)) }
            else { edits.append((span.lowerBound..<span.lowerBound, bytes)) }
        }
        let before = sels
        let shifts = edits
        guard canEdit else { return }
        applyingOwnEdit = true
        document.applyEdits(edits, name: "Duplicate Line", before: before.map(\.range), after: before.map(\.range))
        applyingOwnEdit = false
        // Move selections onto the copies (the second instance).
        var delta = 0
        var out: [Sel] = []
        var ei = 0
        for s in before {
            while ei < shifts.count && shifts[ei].0.lowerBound <= s.lo { delta += shifts[ei].1.count; ei += 1 }
            out.append(Sel(s.anchor + delta, s.caret + delta))
        }
        sels = out
        selectionChanged()
    }

    @objc func deleteLines(_ sender: Any?) {
        guard !tooLargeForLineCommand else { return }
        let spans = selectedLineSpans()
        edit("Delete Line") { s in
            guard let span = spans.first(where: { $0.contains(s.lo) || $0.lowerBound == s.lo }) else { return nil }
            return (span, [], 0)
        }
    }

    @objc func moveLinesUp(_ sender: Any?) { moveLines(-1) }
    @objc func moveLinesDown(_ sender: Any?) { moveLines(1) }
    private func moveLines(_ dir: Int) {
        guard canEdit, !tooLargeForLineCommand else { return }
        let spans = selectedLineSpans()
        guard spans.count == 1, var span = spans.first else { NSSound.beep(); return }
        var text = document.buffer.read(span)
        let nl = document.newlineBytes
        let hadNewline = text.last == 0x0A
        if !hadNewline { text += nl }
        let before = sels
        if dir < 0 {
            guard span.lowerBound > 0 else { NSSound.beep(); return }
            let prev = logicalLine(span.lowerBound - 1)
            var prevText = document.buffer.read(prev.start..<span.lowerBound)
            if !hadNewline { prevText.removeLast(prevText.last == 0x0A ? (prevText.dropLast().last == 0x0D ? 2 : 1) : 0) }
            span = prev.start..<span.upperBound
            applyingOwnEdit = true
            document.replace(span, with: text + prevText, name: "Move Line Up")
            applyingOwnEdit = false
            let shift = -(prev.next - prev.start)
            sels = before.map { Sel($0.anchor + shift, $0.caret + shift) }
        } else {
            guard span.upperBound < document.length else { NSSound.beep(); return }
            let next = logicalLine(span.upperBound)
            var nextText = document.buffer.read(span.upperBound..<next.next)
            let nextHadNewline = nextText.last == 0x0A
            if !nextHadNewline { nextText += nl; text.removeLast(nl.count) }
            span = span.lowerBound..<next.next
            applyingOwnEdit = true
            document.replace(span, with: nextText + text, name: "Move Line Down")
            applyingOwnEdit = false
            let shift = nextText.count
            sels = before.map { Sel($0.anchor + shift, $0.caret + shift) }
        }
        selectionChanged()
    }

    @objc func joinLines(_ sender: Any?) {
        guard !tooLargeForLineCommand else { return }
        edit("Join Lines", selectInserted: false) { s in
            let lineA = logicalLine(s.lo)
            let span: Range<Int>
            if s.isEmpty || !spansLines(s) {
                guard lineA.next < document.length || lineA.next > lineA.end else { return nil }
                span = lineA.start..<logicalLine(lineA.next).end
            } else {
                span = lineA.start..<logicalLine(s.hi).end
            }
            let text = String(decoding: document.buffer.read(span), as: UTF8.self)
            let parts = text.components(separatedBy: .newlines)
            var joined = parts.first ?? ""
            for p in parts.dropFirst() {
                let t = p.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if !joined.hasSuffix(" ") && !joined.isEmpty { joined += " " }
                joined += t
            }
            return (span, Array(joined.utf8), nil)
        }
    }

    enum CaseTransform { case upper, lower, title }
    func transformCase(_ t: CaseTransform) {
        edit("Change Case", selectInserted: true) { s in
            let r = s.isEmpty ? wordRange(at: s.caret) : s.range
            guard r.count <= 64 << 20 else { return nil }
            let text = String(decoding: document.buffer.read(r), as: UTF8.self)
            let out: String
            switch t {
            case .upper: out = text.uppercased()
            case .lower: out = text.lowercased()
            case .title: out = text.capitalized
            }
            return (r, Array(out.utf8), nil)
        }
    }
    @objc func uppercaseSelection(_ sender: Any?) { transformCase(.upper) }
    @objc func lowercaseSelection(_ sender: Any?) { transformCase(.lower) }
    @objc func titlecaseSelection(_ sender: Any?) { transformCase(.title) }

    /// Replaces each selection with `transform(selectedText)` (sort lines,
    /// format, trim…). Selections must be under 512 MB in total.
    func transformSelections(_ name: String, _ transform: ([UInt8]) -> [UInt8]?) {
        guard !tooLargeForLineCommand else { return }
        edit(name, selectInserted: true) { s in
            guard !s.isEmpty else { return nil }
            guard let out = transform(document.buffer.read(s.range)) else { return nil }
            return (s.range, out, nil)
        }
    }

    @objc func trimTrailingWhitespace(_ sender: Any?) {
        let spans: [Range<Int>] = sels.contains(where: { !$0.isEmpty }) ? selectedLineSpans() : [0..<document.length]
        guard spans.reduce(0, { $0 + $1.count }) <= 512 << 20 else { _ = tooLargeForLineCommand; return }
        var edits: [(Range<Int>, [UInt8])] = []
        let snap = document.snapshot()
        for span in spans {
            var p = span.lowerBound
            while p < span.upperBound {
                let nl = snap.firstNewline(in: p..<span.upperBound) ?? span.upperBound
                var e = nl
                if e > p, snap.byte(at: e - 1) == 0x0D { e -= 1 }
                var s = e
                while s > p, let b = snap.byte(at: s - 1), b == 0x20 || b == 0x09 { s -= 1 }
                if s < e { edits.append((s..<e, [])) }
                p = nl + 1
            }
        }
        if edits.isEmpty { return }
        lineEdits("Trim Trailing Whitespace", edits)
    }

    // MARK: Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasSel = sels.contains { !$0.isEmpty }
        let ro = document.isReadOnly
        switch item.action {
        case #selector(undo(_:)):
            item.title = document.buffer.undoName.map { "Undo \($0)" } ?? "Undo"
            return document.buffer.canUndo && !ro
        case #selector(redo(_:)):
            item.title = document.buffer.redoName.map { "Redo \($0)" } ?? "Redo"
            return document.buffer.canRedo && !ro
        case #selector(copy(_:)): return hasSel
        case #selector(cut(_:)), #selector(delete(_:)): return hasSel && !ro
        case #selector(paste(_:)): return !ro && NSPasteboard.general.string(forType: .string) != nil
        case #selector(jumpToMatchingBracket(_:)): return bracketPair != nil
        case #selector(toggleComment(_:)): return !ro && (document.language.lineComment != nil || document.language.blockComment != nil)
        case #selector(shiftLeft(_:)), #selector(shiftRight(_:)), #selector(duplicateLines(_:)), #selector(deleteLines(_:)),
             #selector(moveLinesUp(_:)), #selector(moveLinesDown(_:)), #selector(joinLines(_:)), #selector(uppercaseSelection(_:)),
             #selector(lowercaseSelection(_:)), #selector(titlecaseSelection(_:)), #selector(trimTrailingWhitespace(_:)):
            return !ro
        default: return true
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Editor: \(document.displayName)" }

    private var visibleText: (String, Int) {
        layoutRowsIfNeeded()
        let start = rows.first?.layout.start ?? 0
        let end = rows.last?.layout.next ?? start
        return (String(decoding: document.buffer.read(start..<min(end, start + (1 << 20))), as: UTF8.self), start)
    }
    override func accessibilityValue() -> Any? { visibleText.0 }
    override func accessibilityNumberOfCharacters() -> Int { (visibleText.0 as NSString).length }
    override func accessibilitySelectedText() -> String? { selectedText(limit: 1 << 20) }
    override func accessibilitySelectedTextRange() -> NSRange {
        let (text, start) = visibleText
        let rel = max(0, caret - start)
        let prefix = String(decoding: Array(text.utf8.prefix(rel)), as: UTF8.self)
        let len = selection.count <= 1 << 20 ? String(decoding: document.buffer.read(selection), as: UTF8.self).utf16.count : 0
        return NSRange(location: (prefix as NSString).length, length: len)
    }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: accessibilityNumberOfCharacters()) }
    override func accessibilityInsertionPointLineNumber() -> Int {
        layoutRowsIfNeeded()
        let ls = document.lineStart(containing: caret)
        return rows.firstIndex { $0.layout.start == ls } ?? 0
    }
    override func accessibilityString(for range: NSRange) -> String? {
        (visibleText.0 as NSString).substring(with: NSIntersectionRange(range, NSRange(location: 0, length: accessibilityNumberOfCharacters())))
    }
    override func accessibilityLine(for index: Int) -> Int {
        let text = visibleText.0 as NSString
        let prefix = text.substring(to: min(index, text.length))
        return prefix.components(separatedBy: "\n").count - 1
    }
    override func accessibilityRange(forLine line: Int) -> NSRange {
        let lines = visibleText.0.components(separatedBy: "\n")
        guard line < lines.count else { return NSRange(location: 0, length: 0) }
        let loc = lines[..<line].reduce(0) { $0 + ($1 as NSString).length + 1 }
        return NSRange(location: loc, length: (lines[line] as NSString).length)
    }
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let p = caretPoint(caret) ?? .zero
        let r = NSRect(x: p.x, y: p.y, width: 2, height: lineHeight)
        return window?.convertToScreen(convert(r, to: nil)) ?? r
    }

    // MARK: Info for the status bar

    /// "Ln, Col" of the primary caret (Col counts characters, tabs as one).
    func caretPosition() -> (line: Int?, column: Int) {
        let c = caret
        let st = logicalLine(c).start
        let col = String(decoding: document.buffer.read(max(st, c - (1 << 20))..<c), as: UTF8.self).count + 1
        return (document.lineNumber(at: c), col)
    }

    /// Characters and lines selected (bytes for very large selections).
    func selectionSummary() -> String {
        let total = sels.reduce(0) { $0 + $1.range.count }
        guard total > 0 else { return sels.count > 1 ? "\(sels.count) carets" : "" }
        let prefix = sels.count > 1 ? "\(sels.count) selections, " : ""
        if total <= 4 << 20 {
            var chars = 0, lines = 0
            for s in sels where !s.isEmpty {
                let bytes = document.buffer.read(s.range)
                chars += String(decoding: bytes, as: UTF8.self).count
                lines += bytes.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            }
            let c = "\(chars.formatted()) \(chars == 1 ? "character" : "characters")"
            return prefix + (lines > 0 ? "\(c), \((lines + 1).formatted()) lines" : c)
        }
        return prefix + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file) + " selected"
    }
}
