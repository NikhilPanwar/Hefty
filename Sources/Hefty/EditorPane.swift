import AppKit
import BigFileCore

/// One editor: the text view (or hex view) with its byte-proportional
/// vertical scroller and a horizontal scroller when word wrap is off.
final class EditorPane: NSView {
    let textView: BigTextView
    private(set) var hexView: HexView?
    let vScroller = NSScroller()
    let hScroller = NSScroller()
    private var showsH = false

    init(document: TextDocument, bookmarks: Bookmarks) {
        textView = BigTextView(document: document, bookmarks: bookmarks)
        super.init(frame: .zero)
        vScroller.scrollerStyle = .legacy
        vScroller.isEnabled = true
        vScroller.target = self
        vScroller.action = #selector(vMoved(_:))
        hScroller.scrollerStyle = .legacy
        hScroller.isEnabled = true
        hScroller.target = self
        hScroller.action = #selector(hMoved(_:))
        for v in [textView, vScroller, hScroller] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var isHex: Bool { hexView != nil }

    func setHex(_ on: Bool) {
        if on && hexView == nil {
            let h = HexView(document: textView.document)
            h.onScroll = { [weak self] in self?.updateScrollers() }
            h.onSelectionChange = { [weak self] r in
                self?.textView.setSelections([r], reveal: false)
            }
            hexView = h
            addSubview(h)
            h.selection = textView.selection.isEmpty ? textView.caret..<min(textView.document.length, textView.caret + 1) : textView.selection
            h.reveal(textView.caret)
            textView.isHidden = true
            window?.makeFirstResponder(h)
        } else if !on, let h = hexView {
            let sel = h.selection
            h.removeFromSuperview()
            hexView = nil
            textView.isHidden = false
            textView.setSelections([sel.lowerBound..<sel.lowerBound], reveal: true, centered: true)
            window?.makeFirstResponder(textView)
        }
        needsLayout = true
        updateScrollers()
    }

    override func layout() {
        super.layout()
        let w = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let wantH = !isHex && !textView.wordWrap && textView.contentWidth > textView.textAreaWidth + 1
        showsH = wantH
        let hh: CGFloat = wantH ? w : 0
        let main = NSRect(x: 0, y: 0, width: bounds.width - w, height: bounds.height - hh)
        textView.frame = main
        hexView?.frame = main
        vScroller.frame = NSRect(x: bounds.width - w, y: 0, width: w, height: bounds.height - hh)
        hScroller.frame = NSRect(x: 0, y: bounds.height - hh, width: bounds.width - w, height: hh)
        hScroller.isHidden = !wantH
    }
    override var isFlipped: Bool { true }

    func updateScrollers() {
        if let h = hexView {
            vScroller.doubleValue = h.scrollFraction
            vScroller.knobProportion = CGFloat(max(0.02, min(1, h.visibleFraction)))
            return
        }
        let len = textView.document.length
        vScroller.doubleValue = textView.scrollFraction
        vScroller.knobProportion = len == 0 ? 1 : CGFloat(max(0.02, min(1, Double(textView.visibleByteCount) / Double(len))))
        let wantH = !textView.wordWrap && textView.contentWidth > textView.textAreaWidth + 1
        if wantH != showsH { needsLayout = true }
        if wantH {
            let range = max(1, textView.contentWidth + 40 - textView.textAreaWidth)
            hScroller.doubleValue = Double(textView.scrollX / range)
            hScroller.knobProportion = max(0.05, min(1, textView.textAreaWidth / (textView.contentWidth + 40)))
        }
    }

    @objc private func vMoved(_ sender: NSScroller) {
        if let h = hexView {
            switch sender.hitPart {
            case .knob, .knobSlot: h.scroll(toFraction: sender.doubleValue)
            case .decrementPage: h.scrollRows(-h.rowsVisible)
            case .incrementPage: h.scrollRows(h.rowsVisible)
            default: break
            }
            updateScrollers()
            return
        }
        switch sender.hitPart {
        case .knob, .knobSlot: textView.scroll(toFraction: sender.doubleValue)
        case .decrementPage: textView.scrollRows(-textView.visibleRowCount)
        case .incrementPage: textView.scrollRows(textView.visibleRowCount)
        case .decrementLine: textView.scrollRows(-1)
        case .incrementLine: textView.scrollRows(1)
        default: break
        }
    }

    @objc private func hMoved(_ sender: NSScroller) {
        let range = max(1, textView.contentWidth + 40 - textView.textAreaWidth)
        switch sender.hitPart {
        case .knob, .knobSlot: textView.scrollHorizontally(to: CGFloat(sender.doubleValue) * range)
        case .decrementPage: textView.scrollHorizontally(to: textView.scrollX - textView.textAreaWidth)
        case .incrementPage: textView.scrollHorizontally(to: textView.scrollX + textView.textAreaWidth)
        default: break
        }
    }
}
