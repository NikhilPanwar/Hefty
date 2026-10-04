import AppKit
import BigFileCore

/// Settings (⌘,): Editor, Appearance and Files tabs. Changes apply live.
final class SettingsWindowController: NSWindowController {
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func tab(_ title: String, _ symbol: String, _ view: NSView) {
            let vc = NSViewController()
            vc.view = view
            vc.title = title
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        tab("Editor", "character.cursor.ibeam", Self.editorPane())
        tab("Appearance", "paintpalette", Self.appearancePane())
        tab("Files", "doc", Self.filesPane())
        let window = NSWindow(contentViewController: tabs)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Building blocks

    private static func check(_ title: String, _ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> NSButton {
        let b = ClosureButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = get() ? .on : .off
        b.handler = { set($0.state == .on) }
        return b
    }

    private static func grid(_ rows: [[NSView]]) -> NSView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 10
        g.columnSpacing = 10
        g.column(at: 0).xPlacement = .trailing
        g.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.addSubview(g)
        NSLayoutConstraint.activate([
            g.topAnchor.constraint(equalTo: box.topAnchor, constant: 24),
            g.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -24),
            g.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 32),
            g.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -32),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        return box
    }

    private static func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
    private static var empty: NSView { NSGridCell.emptyContentView }

    // MARK: Panes

    private static func editorPane() -> NSView {
        let tabWidth = ClosurePopUp()
        for w in [2, 3, 4, 8] { tabWidth.addItem(withTitle: "\(w)"); tabWidth.lastItem?.tag = w }
        tabWidth.selectItem(withTag: Prefs.tabWidth)
        tabWidth.handler = { Prefs.tabWidth = $0.selectedTag() }
        return grid([
            [label("Tab width:"), tabWidth],
            [empty, check("Indent using spaces", { Prefs.indentWithSpaces }, { Prefs.indentWithSpaces = $0 })],
            [empty, check("Auto-indent new lines", { Prefs.autoIndent }, { Prefs.autoIndent = $0 })],
            [empty, check("Auto-close brackets and quotes", { Prefs.autoCloseBrackets }, { Prefs.autoCloseBrackets = $0 })],
            [empty, check("Highlight matching brackets", { Prefs.matchBrackets }, { Prefs.matchBrackets = $0 })],
            [label("View:"), check("Wrap long lines", { Prefs.wordWrap }, { Prefs.wordWrap = $0 })],
            [empty, check("Show line numbers", { Prefs.showLineNumbers }, { Prefs.showLineNumbers = $0 })],
            [empty, check("Highlight the current line", { Prefs.highlightCurrentLine }, { Prefs.highlightCurrentLine = $0 })],
            [empty, check("Show invisible characters", { Prefs.showInvisibles }, { Prefs.showInvisibles = $0 })],
            [empty, check("Align CSV / TSV columns", { Prefs.alignCSVColumns }, { Prefs.alignCSVColumns = $0 })],
            [empty, check("Blinking caret", { Prefs.blinkCaret }, { Prefs.blinkCaret = $0 })],
        ])
    }

    private static func appearancePane() -> NSView {
        let theme = ClosurePopUp()
        for t in ThemeChoice.allCases { theme.addItem(withTitle: t.title); theme.lastItem?.representedObject = t.rawValue }
        theme.selectItem(at: ThemeChoice.allCases.firstIndex(of: Prefs.theme) ?? 0)
        theme.handler = { p in
            if let raw = p.selectedItem?.representedObject as? String, let t = ThemeChoice(rawValue: raw) { Prefs.theme = t }
        }
        let font = ClosurePopUp()
        font.addItem(withTitle: "System Monospaced (SF Mono)")
        font.lastItem?.representedObject = ""
        let mono = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Array(Set(mono.compactMap { NSFont(name: $0, size: 12)?.familyName })).sorted()
        font.menu?.addItem(.separator())
        for f in families {
            guard let face = NSFontManager.shared.font(withFamily: f, traits: [], weight: 5, size: 12) else { continue }
            font.addItem(withTitle: f)
            font.lastItem?.representedObject = face.fontName
        }
        if let i = font.itemArray.firstIndex(where: { ($0.representedObject as? String) == Prefs.fontName }) { font.selectItem(at: i) }
        font.handler = { p in Prefs.fontName = p.selectedItem?.representedObject as? String ?? "" }

        let size = ClosureStepperField(value: Double(Prefs.fontSize), range: Prefs.fontSizes) { Prefs.fontSize = CGFloat($0) }
        let spacing = ClosurePopUp()
        for (t, v) in [("Compact", 1.1), ("Normal", 1.25), ("Relaxed", 1.45), ("Double", 1.9)] {
            spacing.addItem(withTitle: t); spacing.lastItem?.representedObject = v
        }
        if let i = spacing.itemArray.firstIndex(where: { abs(($0.representedObject as? Double ?? 0) - Double(Prefs.lineSpacing)) < 0.01 }) {
            spacing.selectItem(at: i)
        } else { spacing.selectItem(at: 1) }
        spacing.handler = { p in Prefs.lineSpacing = CGFloat(p.selectedItem?.representedObject as? Double ?? 1.25) }
        return grid([
            [label("Theme:"), theme],
            [label("Font:"), font],
            [label("Size:"), size],
            [label("Line spacing:"), spacing],
        ])
    }

    private static func filesPane() -> NSView {
        let fallback = ClosurePopUp()
        for e in TextEncoding.all where !e.isUTF8 && e.bom.isEmpty && !e.id.hasPrefix("UTF") { fallback.addItem(withTitle: e.displayName) }
        fallback.selectItem(withTitle: Prefs.fallbackEncoding)
        fallback.handler = { Prefs.fallbackEncoding = $0.titleOfSelectedItem ?? Prefs.fallbackEncoding }
        let le = ClosurePopUp()
        for e in [LineEnding.lf, .crlf] { le.addItem(withTitle: e.displayName); le.lastItem?.representedObject = e.rawValue }
        le.selectItem(at: Prefs.defaultLineEnding == .crlf ? 1 : 0)
        le.handler = { p in Prefs.defaultLineEnding = LineEnding(rawValue: p.selectedItem?.representedObject as? String ?? "lf") ?? .lf }
        let note = label("Files that aren't valid UTF-8 (and have no BOM) open with this encoding.\nYou can always reopen a file with another encoding from the status bar.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        return grid([
            [label("Non-UTF-8 files:"), fallback],
            [empty, note],
            [label("New documents use:"), le],
            [label("Changes on disk:"), check("Reload automatically when there are no unsaved changes", { Prefs.autoReload }, { Prefs.autoReload = $0 })],
            [empty, check("Follow the end of growing files (logs)", { Prefs.followTail }, { Prefs.followTail = $0 })],
        ])
    }
}

final class ClosureButton: NSButton {
    var handler: ((NSButton) -> Void)? { didSet { target = self; action = #selector(fire) } }
    @objc private func fire() { handler?(self) }
}

final class ClosurePopUp: NSPopUpButton {
    var handler: ((NSPopUpButton) -> Void)? { didSet { target = self; action = #selector(fire) } }
    init() { super.init(frame: .zero, pullsDown: false) }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { handler?(self) }
}

/// Number field with a stepper.
final class ClosureStepperField: NSStackView {
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let onChange: (Double) -> Void

    init(value: Double, range: ClosedRange<CGFloat>, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.doubleValue = value
        stepper.target = self
        stepper.action = #selector(stepped)
        field.doubleValue = value
        field.widthAnchor.constraint(equalToConstant: 50).isActive = true
        field.target = self
        field.action = #selector(typed)
        addArrangedSubview(field)
        addArrangedSubview(stepper)
        addArrangedSubview(NSTextField(labelWithString: "pt"))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func stepped() { field.doubleValue = stepper.doubleValue; onChange(stepper.doubleValue) }
    @objc private func typed() {
        let v = min(stepper.maxValue, max(stepper.minValue, field.doubleValue))
        field.doubleValue = v; stepper.doubleValue = v; onChange(v)
    }
}

/// Help > Keyboard Shortcuts.
enum ShortcutsWindow {
    static let list: [(String, String)] = [
        ("File", ""), ("⌘N / ⌘O / ⌘S / ⇧⌘S / ⌥⌘S", "New / Open / Save / Save As / Save All"),
        ("Edit", ""), ("⌘Z / ⇧⌘Z", "Undo / Redo"), ("⌘X / ⌘C / ⌘V", "Cut / Copy / Paste"),
        ("⌥← / ⌥→, ⌥⌫ / ⌥⌦", "Move / delete by word"), ("⌘← / ⌘→, ⌘⌫", "Line start (first character) / end, delete to line start"),
        ("⌃K", "Delete to end of line"), ("⌃T", "Transpose characters"),
        ("⌘] / ⌘[ (Tab / ⇧Tab)", "Shift lines right / left"), ("⌘/", "Toggle comment"),
        ("⇧⌘D / ⌃⇧K", "Duplicate / delete line"), ("⌃⌘↑ / ⌃⌘↓", "Move line up / down"), ("⌘J", "Join lines"),
        ("⌃⌘U / ⌃⌘L", "Uppercase / lowercase"),
        ("Multiple cursors", ""), ("⌘-click", "Add a caret"), ("⌥-drag", "Column (box) selection"),
        ("⌘D", "Select word / add next occurrence"), ("⌃⌘G", "Select all occurrences"),
        ("⌃⇧↑ / ⌃⇧↓", "Add caret above / below"), ("⌥⇧⌘L", "Split selection into lines"), ("Esc", "Back to one caret"),
        ("Find", ""), ("⌘F / ⌥⌘F", "Find / Find and Replace"), ("Return / ⇧Return, ⌘G / ⇧⌘G", "Next / previous match"),
        ("⇧⌘F", "Find All (list of matches)"), ("⌥Return in Replace", "Replace All"), ("⌘E / ⇧⌘E", "Use selection for Find / Replace"),
        ("Go", ""), ("⌘L", "Go to line (line:col, 50%, @offset)"), ("⌘↑ / ⌘↓", "Top / bottom"),
        ("⌘F2 / F2 / ⇧F2", "Toggle / next / previous bookmark"), ("⌃M", "Jump to matching bracket"),
        ("View", ""), ("⌥⌘W / ⌥⌘L / ⌥⌘I", "Word wrap / line numbers / invisibles"), ("⌥⌘\\", "Split editor"),
        ("⌃⌘H", "Hex view"), ("⌘+ / ⌘- / ⌘0", "Bigger / smaller / actual size"),
        ("Format", ""), ("⇧⌘J", "Format JSON (selection or document)"), ("⌥⌘J", "Pretty-print JSON to a new file"),
    ]

    static func make() -> NSWindowController {
        let text = NSMutableAttributedString()
        for (k, v) in list {
            if v.isEmpty {
                text.append(NSAttributedString(string: (text.length > 0 ? "\n" : "") + k + "\n",
                                               attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
            } else {
                text.append(NSAttributedString(string: "\(k)\t\(v)\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            }
        }
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 230)]
        para.headIndent = 230
        text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
        tv.isEditable = false
        tv.textStorage?.setAttributedString(text)
        tv.textContainerInset = NSSize(width: 16, height: 16)
        let scroll = NSScrollView(frame: tv.frame)
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        let w = NSWindow(contentRect: tv.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Keyboard Shortcuts"
        w.contentView = scroll
        w.center()
        return NSWindowController(window: w)
    }
}
