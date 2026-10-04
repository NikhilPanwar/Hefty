import AppKit
import BigFileCore

/// Base for the bars around the editor: themed background plus a hairline
/// separator on one edge.
class ThemedBar: NSView {
    enum Edge { case top, bottom }
    private let edge: Edge

    init(separatorAt edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Prefs.didChange, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var theme: Theme { Prefs.theme.resolved(for: effectiveAppearance) }

    @objc func themeChanged() { needsDisplay = true; applyTheme() }
    override func viewDidChangeEffectiveAppearance() { themeChanged() }
    func applyTheme() {}

    override func draw(_ dirtyRect: NSRect) {
        let t = theme
        t.gutterBackground.setFill()
        bounds.fill()
        t.separator.setFill()
        let y = (edge == .top) == isFlipped ? 0 : bounds.height - 1
        NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
    }
}

/// A small toggle button for find options (Aa, W, .*, selection).
final class OptionToggle: NSButton {
    init(_ title: String, symbol: String? = nil, tip: String) {
        super.init(frame: .zero)
        setButtonType(.pushOnPushOff)
        bezelStyle = .push
        controlSize = .regular
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            image = img; imagePosition = .imageOnly
        } else {
            self.title = title
            font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        }
        toolTip = tip
        setAccessibilityLabel(tip)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Find / replace bar shown above the editor on ⌘F and hidden on Esc.
final class FindBar: ThemedBar {
    let findField = NSSearchField()
    let replaceField = NSTextField()
    let statusLabel = NSTextField(labelWithString: "")
    let caseButton = OptionToggle("Aa", tip: "Match Case")
    let wordButton = OptionToggle("W", symbol: "textformat.abc.dottedunderline", tip: "Whole Words")
    let regexButton = OptionToggle(".*", tip: "Regular Expression")
    let selectionButton = OptionToggle("", symbol: "text.viewfinder", tip: "Search in Selection")
    let navigation = NSSegmentedControl()
    let findAllButton = NSButton(title: "Find All", target: nil, action: nil)
    let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    let replaceFindButton = NSButton(title: "Replace & Find", target: nil, action: nil)
    let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    let disclosure = NSButton()
    private let replaceRow: NSStackView
    private let spinner = NSProgressIndicator()

    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onReplace: ((_ thenFind: Bool) -> Void)?
    var onReplaceAll: (() -> Void)?
    var onFindAll: (() -> Void)?
    var onDone: (() -> Void)?
    var onOptionsChanged: (() -> Void)?

    var caseSensitive: Bool { caseButton.state == .on }
    var wholeWord: Bool { wordButton.state == .on }
    var regex: Bool { regexButton.state == .on }
    var inSelection: Bool { selectionButton.state == .on }
    var showsReplace: Bool { !replaceRow.isHidden }

    init() {
        replaceRow = NSStackView()
        super.init(separatorAt: .bottom)

        disclosure.bezelStyle = .regularSquare
        disclosure.isBordered = false
        disclosure.image = Self.symbol("chevron.right", "Show Replace")
        disclosure.imagePosition = .imageOnly
        disclosure.target = self
        disclosure.action = #selector(toggleReplace)
        disclosure.toolTip = "Show Replace"
        disclosure.widthAnchor.constraint(equalToConstant: 18).isActive = true

        findField.placeholderString = "Find"
        findField.sendsWholeSearchString = false
        findField.sendsSearchStringImmediately = false
        findField.recentsAutosaveName = "BigFileEditorFindHistory"
        findField.maximumRecents = 20
        let menu = NSMenu(title: "Recents")
        let t = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: ""); t.tag = NSSearchField.recentsTitleMenuItemTag
        let r = NSMenuItem(title: "", action: nil, keyEquivalent: ""); r.tag = NSSearchField.recentsMenuItemTag
        let n = NSMenuItem(title: "No Recent Searches", action: nil, keyEquivalent: ""); n.tag = NSSearchField.noRecentsMenuItemTag
        let c = NSMenuItem(title: "Clear Recent Searches", action: nil, keyEquivalent: ""); c.tag = NSSearchField.clearRecentsMenuItemTag
        for i in [t, r, n, .separator(), c] { menu.addItem(i) }
        findField.searchMenuTemplate = menu

        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .vertical)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        navigation.segmentCount = 2
        navigation.trackingMode = .momentary
        navigation.segmentStyle = .rounded
        navigation.setImage(Self.symbol("chevron.left", "Previous"), forSegment: 0)
        navigation.setImage(Self.symbol("chevron.right", "Next"), forSegment: 1)
        navigation.setToolTip("Find Previous (⇧⌘G)", forSegment: 0)
        navigation.setToolTip("Find Next (⌘G)", forSegment: 1)
        navigation.setWidth(28, forSegment: 0)
        navigation.setWidth(28, forSegment: 1)
        navigation.target = self
        navigation.action = #selector(navigate(_:))

        for b in [caseButton, wordButton, regexButton, selectionButton] {
            b.target = self
            b.action = #selector(optionsChanged)
        }

        for (b, sel) in [(doneButton, #selector(done)), (findAllButton, #selector(findAll))] {
            b.bezelStyle = .push; b.target = self; b.action = sel
        }
        findAllButton.toolTip = "List every match"

        replaceField.placeholderString = "Replace (use $1, $2 with regular expressions)"
        replaceField.bezelStyle = .roundedBezel
        for b in [replaceButton, replaceFindButton] {
            b.bezelStyle = .push
            b.target = self
            b.action = #selector(replace(_:))
        }
        replaceAllButton.bezelStyle = .push
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAll)

        let findRow = NSStackView(views: [disclosure, findField, caseButton, wordButton, regexButton, selectionButton,
                                          spinner, statusLabel, findAllButton, navigation, doneButton])
        findRow.spacing = 6
        findRow.setCustomSpacing(10, after: findField)
        findRow.setCustomSpacing(10, after: selectionButton)
        for v in [disclosure, caseButton, wordButton, regexButton, selectionButton, navigation, doneButton, spinner, findAllButton] as [NSView] {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        findField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.setContentHuggingPriority(.init(1), for: .horizontal)

        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 18).isActive = true
        for v in [spacer, replaceField, replaceButton, replaceFindButton, replaceAllButton] { replaceRow.addArrangedSubview(v) }
        replaceRow.spacing = 6
        replaceRow.isHidden = true

        let column = NSStackView(views: [findRow, replaceRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setHuggingPriority(.required, for: .vertical)
        findRow.setHuggingPriority(.required, for: .vertical)
        replaceRow.setHuggingPriority(.required, for: .vertical)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            findRow.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            findField.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            replaceField.widthAnchor.constraint(equalTo: findField.widthAnchor),
        ])
        let preferred = findField.widthAnchor.constraint(equalToConstant: 340)
        preferred.priority = .defaultLow
        preferred.isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setStatus(_ text: String, busy: Bool = false, error: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    func setReplaceVisible(_ visible: Bool) {
        replaceRow.isHidden = !visible
        disclosure.image = Self.symbol(visible ? "chevron.down" : "chevron.right", "Toggle Replace")
        disclosure.toolTip = visible ? "Hide Replace" : "Show Replace"
    }

    func remember(_ term: String) {
        guard !term.isEmpty else { return }
        var r = findField.recentSearches
        r.removeAll { $0 == term }
        r.insert(term, at: 0)
        findField.recentSearches = Array(r.prefix(20))
    }

    @objc private func toggleReplace() { setReplaceVisible(replaceRow.isHidden) }
    @objc private func navigate(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? onPrevious?() : onNext?()
    }
    @objc private func optionsChanged() { onOptionsChanged?() }
    @objc private func replace(_ sender: NSButton) { onReplace?(sender === replaceFindButton) }
    @objc private func replaceAll() { onReplaceAll?() }
    @objc private func findAll() { onFindAll?() }
    @objc private func done() { onDone?() }

    static func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }
}

/// Bottom status bar: caret position on the left, file facts on the right.
/// Encoding, line endings, syntax and indentation are menus.
final class StatusBar: ThemedBar {
    let position = NSButton(title: "", target: nil, action: nil)
    let selectionInfo = NSTextField(labelWithString: "")
    let message = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "")
    let lines = NSTextField(labelWithString: "")
    let size = NSTextField(labelWithString: "")
    let readOnly = NSButton()
    let language = NSPopUpButton(frame: .zero, pullsDown: false)
    let indentation = NSPopUpButton(frame: .zero, pullsDown: true)
    let encoding = NSPopUpButton(frame: .zero, pullsDown: true)
    let lineEnding = NSPopUpButton(frame: .zero, pullsDown: true)
    let modified = NSTextField(labelWithString: "")
    let stopButton = NSButton()
    private var labels: [NSTextField] { [selectionInfo, message, progressLabel, lines, size, modified] }
    private var messageTimer: Timer?

    init() {
        super.init(separatorAt: .top)
        for l in labels {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            l.lineBreakMode = .byTruncatingTail
        }
        position.isBordered = false
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        position.toolTip = "Go to Line… (⌘L)"
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 90).isActive = true

        stopButton.isBordered = false
        stopButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop")
        stopButton.imagePosition = .imageOnly
        stopButton.toolTip = "Stop"
        stopButton.isHidden = true

        readOnly.isBordered = false
        readOnly.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Read Only")
        readOnly.imagePosition = .imageOnly
        readOnly.toolTip = "Read only. Click to allow editing."
        readOnly.isHidden = true

        for p in [language, indentation, encoding, lineEnding] {
            p.isBordered = false
            p.controlSize = .small
            p.font = .systemFont(ofSize: 11)
            (p.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        }
        for l in Language.allCases {
            language.addItem(withTitle: l.displayName)
            language.lastItem?.representedObject = l.rawValue
        }
        language.toolTip = "Syntax coloring"
        indentation.toolTip = "Indentation"
        encoding.toolTip = "Text encoding"
        lineEnding.toolTip = "Line endings"

        let left = NSStackView(views: [position, selectionInfo, message])
        left.spacing = 14
        let right = NSStackView(views: [progress, progressLabel, stopButton, modified, lines, size, readOnly, language, indentation, encoding, lineEnding])
        right.spacing = 12
        right.setCustomSpacing(6, after: progress)
        for v in [left, right] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectionInfo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            left.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 16),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func applyTheme() {
        let t = theme
        for l in labels { l.textColor = t.gutterCurrentText }
        selectionInfo.textColor = t.gutterText
        progressLabel.textColor = t.gutterText
        message.textColor = t.gutterText
        position.contentTintColor = t.gutterCurrentText
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: t.gutterCurrentText]
        position.attributedTitle = NSAttributedString(string: position.title, attributes: attrs)
    }

    func setPosition(_ s: String) {
        position.title = s
        applyTheme()
    }

    func setLanguage(_ l: Language) {
        language.selectItem(at: Language.allCases.firstIndex(of: l) ?? 0)
    }

    /// A transient note (e.g. "Document is read-only"), cleared after a while.
    func flash(_ text: String) {
        message.stringValue = text
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.message.stringValue = "" }
    }
}

/// Bottom panel listing Find All results; clicking a row jumps to the match.
final class ResultsPanel: ThemedBar, NSTableViewDataSource, NSTableViewDelegate {
    struct Result { var range: Range<Int>; var preview: String }
    private(set) var results: [Result] = []
    /// Line numbers are looked up only for rows on screen.
    var lineProvider: ((Int) -> Int?)?
    private var lineCache: [Int: Int] = [:]
    var onSelect: ((Range<Int>) -> Void)?
    var onClose: (() -> Void)?
    let title = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()

    init() {
        super.init(separatorAt: .top)
        let col = NSTableColumn(identifier: .init("r"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 18
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.style = .plain
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Results")!,
                             target: self, action: #selector(closePanel))
        close.isBordered = false
        for v in [title, close, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 180),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ r: [Result], title t: String) {
        results = r
        lineCache.removeAll()
        title.stringValue = t
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        let r = results[row]
        var line = lineCache[row]
        if line == nil, let l = lineProvider?(r.range.lowerBound) { lineCache[row] = l; line = l }
        let ln = line.map { String(format: "%8@  ", ($0 + 1).formatted() as NSString) } ?? "          "
        cell.stringValue = ln + r.preview
        return cell
    }

    @objc private func clicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 && row < results.count else { return }
        onSelect?(results[row].range)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { clicked() }
    @objc private func closePanel() { onClose?() }
}
