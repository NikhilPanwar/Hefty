import AppKit
import BigFileCore

/// Read-only hex dump of the document: offset, 16 bytes in hex, and ASCII.
/// Like the text view, it only ever reads the visible bytes.
final class HexView: NSView {
    let document: TextDocument
    private(set) var topOffset = 0
    var selection: Range<Int> = 0..<0 { didSet { needsDisplay = true } }
    var onSelectionChange: ((Range<Int>) -> Void)?
    var onScroll: (() -> Void)?
    private var anchor = 0
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var lineHeight: CGFloat = 17
    private var charWidth: CGFloat = 7
    private var remainder: CGFloat = 0
    private var theme: Theme { Prefs.theme.resolved(for: effectiveAppearance) }

    init(document: TextDocument) {
        self.document = document
        super.init(frame: .zero)
        updateFont()
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Prefs.didChange, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Hex view" }

    @objc private func prefsChanged() { updateFont(); needsDisplay = true }
    private func updateFont() {
        font = NSFont.monospacedSystemFont(ofSize: Prefs.fontSize, weight: .regular)
        lineHeight = ceil(font.ascender - font.descender + font.leading + 4)
        charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    var rowsVisible: Int { max(1, Int(bounds.height / lineHeight)) }
    var scrollFraction: Double { document.length == 0 ? 0 : Double(topOffset) / Double(document.length) }
    var visibleFraction: Double { document.length == 0 ? 1 : Double(rowsVisible * 16) / Double(document.length) }

    func scroll(toFraction f: Double) {
        topOffset = (Int(Double(document.length) * min(1, max(0, f))) / 16) * 16
        clampTop()
    }
    func scrollRows(_ n: Int) { topOffset += n * 16; clampTop() }
    private func clampTop() {
        let maxTop = max(0, ((document.length + 15) / 16 - rowsVisible + 1) * 16)
        topOffset = max(0, min(topOffset, maxTop))
        needsDisplay = true
        onScroll?()
    }

    func reveal(_ o: Int) {
        let row = o / 16 * 16
        if row < topOffset || row >= topOffset + rowsVisible * 16 {
            topOffset = max(0, row - rowsVisible / 3 * 16)
            clampTop()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = theme
        t.background.setFill()
        bounds.fill()
        let digits = max(8, String(document.length, radix: 16).count)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: t.text]
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: t.gutterText]
        let hexX = CGFloat(digits + 2) * charWidth + 8
        let asciiX = hexX + CGFloat(16 * 3 + 2) * charWidth
        let bytes = document.buffer.read(topOffset..<min(document.length, topOffset + (rowsVisible + 1) * 16))
        var y: CGFloat = 0
        var row = 0
        while y < bounds.height && row * 16 < max(1, bytes.count) {
            let base = topOffset + row * 16
            let off = String(base, radix: 16, uppercase: true)
            NSAttributedString(string: String(repeating: "0", count: max(0, digits - off.count)) + off, attributes: dim)
                .draw(at: NSPoint(x: 8, y: y + 2))
            for i in 0..<16 {
                let k = row * 16 + i
                guard k < bytes.count else { break }
                let o = base + i
                let x = hexX + CGFloat(i * 3 + (i >= 8 ? 1 : 0)) * charWidth
                if selection.contains(o) {
                    t.selection.setFill()
                    NSRect(x: x - 2, y: y, width: charWidth * 2 + 4, height: lineHeight).fill()
                    NSRect(x: asciiX + CGFloat(i) * charWidth, y: y, width: charWidth, height: lineHeight).fill()
                }
                let b = bytes[k]
                NSAttributedString(string: String(format: "%02X", b), attributes: b == 0 ? dim : attrs).draw(at: NSPoint(x: x, y: y + 2))
                let ch = b >= 0x20 && b < 0x7F ? String(UnicodeScalar(b)) : "."
                NSAttributedString(string: ch, attributes: b >= 0x20 && b < 0x7F ? attrs : dim)
                    .draw(at: NSPoint(x: asciiX + CGFloat(i) * charWidth, y: y + 2))
            }
            y += lineHeight
            row += 1
        }
        t.separator.setFill()
        NSRect(x: hexX - 6, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: asciiX - 8, y: 0, width: 1, height: bounds.height).fill()
    }

    private func offset(at p: NSPoint) -> Int {
        let digits = max(8, String(document.length, radix: 16).count)
        let hexX = CGFloat(digits + 2) * charWidth + 8
        let asciiX = hexX + CGFloat(16 * 3 + 2) * charWidth
        let row = max(0, Int(p.y / lineHeight))
        var col: Int
        if p.x >= asciiX - 4 { col = Int((p.x - asciiX) / charWidth) }
        else { col = Int((p.x - hexX) / (charWidth * 3)) }
        col = max(0, min(15, col))
        return min(document.length, topOffset + row * 16 + col)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let o = offset(at: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift) { selection = min(anchor, o)..<max(anchor, o) + 1 }
        else { anchor = o; selection = o..<min(document.length, o + 1) }
        onSelectionChange?(selection)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y < 0 { scrollRows(-1) } else if p.y > bounds.height { scrollRows(1) }
        let o = offset(at: p)
        selection = min(anchor, o)..<min(document.length, max(anchor, o) + 1)
        onSelectionChange?(selection)
    }

    override func scrollWheel(with event: NSEvent) {
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dy *= lineHeight * 3 }
        remainder += dy
        let rows = Int(remainder / lineHeight)
        if rows != 0 { remainder -= CGFloat(rows) * lineHeight; scrollRows(-rows) }
    }

    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func doCommand(by selector: Selector) {
        switch NSStringFromSelector(selector) {
        case "moveUp:": move(-16)
        case "moveDown:": move(16)
        case "moveLeft:": move(-1)
        case "moveRight:": move(1)
        case "pageUp:", "scrollPageUp:": scrollRows(-rowsVisible); move(-rowsVisible * 16)
        case "pageDown:", "scrollPageDown:": scrollRows(rowsVisible); move(rowsVisible * 16)
        case "moveToBeginningOfDocument:", "scrollToBeginningOfDocument:": select(0)
        case "moveToEndOfDocument:", "scrollToEndOfDocument:": select(max(0, document.length - 1))
        default: break
        }
    }
    override func insertText(_ insertString: Any) { NSSound.beep() }

    private func move(_ d: Int) { select(max(0, min(document.length - 1, selection.lowerBound + d))) }
    func select(_ o: Int) {
        anchor = o
        selection = o..<min(document.length, o + 1)
        reveal(o)
        onSelectionChange?(selection)
    }

    @objc func copy(_ sender: Any?) {
        guard !selection.isEmpty, selection.count <= 16 << 20 else { NSSound.beep(); return }
        let hex = document.buffer.read(selection).map { String(format: "%02X", $0) }.joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
    }
}
