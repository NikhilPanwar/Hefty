import AppKit
import BigFileCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private(set) var controllers: [EditorWindowController] = []
    private let recentMenu = NSMenu(title: "Open Recent")
    private var untitledCount = 0
    private var opening: Set<URL> = []
    private var settings: SettingsWindowController?
    private var shortcuts: NSWindowController?
    private var about: AboutWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        // File paths, skipping "-key value" pairs (user-defaults overrides).
        var paths: [String] = []
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            if a.hasPrefix("-") { _ = args.next() } else { paths.append(a) }
        }
        let restoring = offerRecovery()
        if paths.isEmpty {
            // Files opened from Finder arrive via application(_:open:) right after launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.controllers.isEmpty, self.opening.isEmpty, !restoring else { return }
                if ProcessInfo.processInfo.environment["BFE_SNAPSHOT"] != nil { self.newDocument(nil) } else { self.openDocument(nil) }
            }
        } else {
            paths.forEach { open(URL(fileURLWithPath: $0)) }
        }
        NSApp.activate(ignoringOtherApps: true)
        Snapshot.scheduleIfRequested()
    }

    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach { open($0) } }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openDocument(nil) }
        return true
    }

    // MARK: Quitting safely

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = controllers.filter { $0.textDocument.isModified }
        guard !dirty.isEmpty else { return .terminateNow }
        if dirty.count == 1 {
            review(dirty)
            return .terminateLater
        }
        let a = NSAlert()
        a.messageText = "You have \(dirty.count) documents with unsaved changes. Do you want to review these changes before quitting?"
        a.informativeText = "If you don't review your documents, all your changes will be lost."
        a.addButton(withTitle: "Review Changes…")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Discard Changes")
        a.buttons[2].hasDestructiveAction = true
        switch a.runModal() {
        case .alertFirstButtonReturn: review(dirty); return .terminateLater
        case .alertThirdButtonReturn:
            for c in dirty { Recovery.remove(id: c.recoveryID) }
            return .terminateNow
        default: return .terminateCancel
        }
    }

    /// Asks about each unsaved document in turn, then finishes quitting.
    private func review(_ list: [EditorWindowController]) {
        guard let c = list.first else { NSApp.reply(toApplicationShouldTerminate: true); return }
        let rest = Array(list.dropFirst())
        c.window?.makeKeyAndOrderFront(nil)
        c.askToSave { [weak self] decision in
            switch decision {
            case .cancel: NSApp.reply(toApplicationShouldTerminate: false)
            case .discard:
                Recovery.remove(id: c.recoveryID)
                self?.review(rest)
            case .save:
                if c.textDocument.url == nil {
                    // Untitled: Save As first; the user can cancel the panel.
                    c.saveCompletion = { ok in ok ? self?.review(rest) : NSApp.reply(toApplicationShouldTerminate: false) }
                    c.saveDocumentAs(nil)
                    self?.watchUntitledSave(c, rest)
                } else {
                    c.save(to: nil, encoding: nil) { ok in
                        ok ? self?.review(rest) : NSApp.reply(toApplicationShouldTerminate: false)
                    }
                }
            }
        }
    }

    private func watchUntitledSave(_ c: EditorWindowController, _ rest: [EditorWindowController]) {
        // Poll until the Save panel is dismissed and the save finishes.
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            guard c.window?.attachedSheet == nil, c.jobText == nil else { return }
            t.invalidate()
            if c.textDocument.url != nil && !c.textDocument.isModified { self?.review(rest) }
            else { NSApp.reply(toApplicationShouldTerminate: false) }
        }
    }

    // MARK: Opening

    @objc func newDocument(_ sender: Any?) {
        untitledCount += 1
        let name = untitledCount == 1 ? "Untitled" : "Untitled \(untitledCount)"
        do {
            let doc = try TextDocument(untitledName: name)
            doc.lineEnding = Prefs.defaultLineEnding == .crlf ? .crlf : .lf
            show(doc)
        } catch { NSAlert(error: error).runModal() }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files of any size to open"
        let enc = NSPopUpButton(frame: .zero, pullsDown: false)
        enc.addItem(withTitle: "Automatic")
        enc.menu?.addItem(.separator())
        for e in TextEncoding.all { enc.addItem(withTitle: e.displayName) }
        let row = NSStackView(views: [NSTextField(labelWithString: "Text encoding:"), enc])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = false
        if panel.runModal() == .OK {
            let forced = TextEncoding.named(enc.titleOfSelectedItem ?? "")
            panel.urls.forEach { open($0, encoding: forced) }
        }
    }

    func open(_ url: URL, encoding: TextEncoding? = nil) {
        // Bring an already-open file to the front instead of opening it twice.
        let std = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = controllers.first(where: { $0.textDocument.url?.standardizedFileURL.resolvingSymlinksInPath() == std }) {
            existing.showWindow(nil)
            return
        }
        guard !opening.contains(std) else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            NSAlert.show("“\(url.lastPathComponent)” is a folder.", "Choose a file to open.")
            return
        }
        opening.insert(std)
        let fallback = Prefs.fallbackTextEncoding
        let progress = OpeningPanel(name: url.lastPathComponent)
        let flag = CancelFlag()
        progress.onCancel = { flag.cancel() }
        let showTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in progress.show() }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try TextDocument(url: url, encoding: encoding, fallback: fallback,
                                 progress: { p in DispatchQueue.main.async { progress.set(p) } },
                                 isCancelled: { flag.isCancelled })
            }
            DispatchQueue.main.async { [weak self] in
                showTimer.invalidate()
                progress.close()
                self?.opening.remove(std)
                switch result {
                case .success(let doc):
                    self?.show(doc)
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled {
                        NSAlert.show("Couldn't open “\(url.lastPathComponent)”.", (error as? CustomStringConvertible)?.description ?? error.localizedDescription)
                    }
                }
            }
        }
    }

    func show(_ doc: TextDocument) {
        let c = EditorWindowController(document: doc)
        c.onOpenURL = { [weak self] in self?.open($0) }
        c.onOpenDocument = { [weak self] in self?.show($0) }
        if let current = NSApp.keyWindow, current.windowController is EditorWindowController, let newWindow = c.window {
            current.addTabbedWindow(newWindow, ordered: .above)
        }
        controllers.append(c)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: c.window, queue: .main) { [weak self, weak c] _ in
            self?.controllers.removeAll { $0 === c }
        }
        c.showWindow(nil)
    }

    // MARK: Crash recovery

    /// Offers to restore unsaved edits left by a crash. Returns true if it did.
    private func offerRecovery() -> Bool {
        let entries = Recovery.pending()
        guard !entries.isEmpty, ProcessInfo.processInfo.environment["BFE_SNAPSHOT"] == nil else { return false }
        let a = NSAlert()
        a.messageText = "Hefty closed unexpectedly with unsaved changes."
        a.informativeText = "Restore the changes to: " + entries.map(\.displayName).joined(separator: ", ") + "?"
        a.addButton(withTitle: "Restore")
        a.addButton(withTitle: "Discard")
        guard a.runModal() == .alertFirstButtonReturn else {
            entries.forEach { Recovery.remove(id: $0.id) }
            return false
        }
        for e in entries {
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Result { try Recovery.restore(e) }
                DispatchQueue.main.async { [weak self] in
                    switch r {
                    case .success(let doc): self?.show(doc); Recovery.remove(id: e.id)
                    case .failure(let err): NSAlert.show("Couldn't restore “\(e.displayName)”.", err.localizedDescription)
                    }
                }
            }
        }
        return true
    }

    // MARK: Recent files

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem(title: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: ""))
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(url)
    }

    @objc private func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(sender) }

    @objc func saveAll(_ sender: Any?) {
        for c in controllers where c.textDocument.isModified && c.textDocument.url != nil { c.saveDocument(nil) }
    }

    // MARK: Preferences (app-wide)

    @objc func chooseTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let t = ThemeChoice(rawValue: raw) else { return }
        Prefs.theme = t
    }
    @objc func toggleWordWrap(_ sender: Any?) { Prefs.wordWrap.toggle() }
    @objc func toggleLineNumbers(_ sender: Any?) { Prefs.showLineNumbers.toggle() }
    @objc func toggleCurrentLine(_ sender: Any?) { Prefs.highlightCurrentLine.toggle() }
    @objc func toggleStatusBar(_ sender: Any?) { Prefs.showStatusBar.toggle() }
    @objc func toggleInvisibles(_ sender: Any?) { Prefs.showInvisibles.toggle() }
    @objc func toggleAlignColumns(_ sender: Any?) { Prefs.alignCSVColumns.toggle() }
    @objc func biggerFont(_ sender: Any?) { Prefs.fontSize = min(Prefs.fontSizes.upperBound, Prefs.fontSize + 1) }
    @objc func smallerFont(_ sender: Any?) { Prefs.fontSize = max(Prefs.fontSizes.lowerBound, Prefs.fontSize - 1) }
    @objc func actualSizeFont(_ sender: Any?) { Prefs.fontSize = Prefs.defaultFontSize }

    @objc func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindowController() }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout(_ sender: Any?) {
        if about == nil { about = AboutWindowController() }
        about?.showWindow(nil)
        about?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showShortcuts(_ sender: Any?) {
        if shortcuts == nil { shortcuts = ShortcutsWindow.make() }
        shortcuts?.showWindow(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(chooseTheme(_:)):
            item.state = (item.representedObject as? String) == Prefs.theme.rawValue ? .on : .off
        case #selector(toggleWordWrap(_:)): item.state = Prefs.wordWrap ? .on : .off
        case #selector(toggleLineNumbers(_:)): item.state = Prefs.showLineNumbers ? .on : .off
        case #selector(toggleCurrentLine(_:)): item.state = Prefs.highlightCurrentLine ? .on : .off
        case #selector(toggleStatusBar(_:)): item.state = Prefs.showStatusBar ? .on : .off
        case #selector(toggleInvisibles(_:)): item.state = Prefs.showInvisibles ? .on : .off
        case #selector(toggleAlignColumns(_:)): item.state = Prefs.alignCSVColumns ? .on : .off
        case #selector(biggerFont(_:)): return Prefs.fontSize < Prefs.fontSizes.upperBound
        case #selector(smallerFont(_:)): return Prefs.fontSize > Prefs.fontSizes.lowerBound
        case #selector(actualSizeFont(_:)): return Prefs.fontSize != Prefs.defaultFontSize
        case #selector(saveAll(_:)): return controllers.contains { $0.textDocument.isModified && $0.textDocument.url != nil }
        default: break
        }
        return true
    }

    static func makeThemeMenu() -> NSMenu {
        let menu = NSMenu(title: "Theme")
        for (i, t) in ThemeChoice.allCases.enumerated() {
            let item = NSMenuItem(title: t.title, action: #selector(chooseTheme(_:)), keyEquivalent: "")
            item.representedObject = t.rawValue
            item.target = NSApp.delegate
            menu.addItem(item)
            if i == 0 { menu.addItem(.separator()) }
        }
        return menu
    }

    // MARK: Menus

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            for i in items { menu.addItem(i) }
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        func fkey(_ title: String, _ action: Selector, _ n: Int, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
            let scalar = Unicode.Scalar(NSF1FunctionKey + n - 1)!
            return item(title, action, String(Character(scalar)), mods)
        }
        func arrow(_ title: String, _ action: Selector, _ key: Int, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
            item(title, action, String(Character(Unicode.Scalar(key)!)), mods)
        }
        func parent(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            i.submenu = m
            return i
        }

        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        submenu("Hefty", [
            item("About Hefty", #selector(showAbout(_:))),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ","),
            .separator(),
            servicesItem,
            .separator(),
            item("Hide Hefty", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Hefty", #selector(NSApplication.terminate(_:)), "q"),
        ])

        recentMenu.delegate = self
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        submenu("File", [
            item("New", #selector(newDocument(_:)), "n"),
            item("Open…", #selector(openDocument(_:)), "o"),
            recentItem,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(EditorWindowController.saveDocument(_:)), "s"),
            item("Save As…", #selector(EditorWindowController.saveDocumentAs(_:)), "s", [.command, .shift]),
            item("Save All", #selector(saveAll(_:)), "s", [.command, .option]),
            item("Revert to Saved", #selector(EditorWindowController.revertDocumentToSaved(_:))),
            .separator(),
            item("Export Selection…", #selector(EditorWindowController.exportSelection(_:))),
            item("Read Only", #selector(EditorWindowController.toggleReadOnly(_:))),
            .separator(),
            item("Show in Finder", #selector(EditorWindowController.revealInFinder(_:)), "r", [.command, .shift]),
            item("Copy File Path", #selector(EditorWindowController.copyFilePath(_:)), "c", [.command, .option, .shift]),
            .separator(),
            item("Page Setup…", #selector(NSApplication.runPageLayout(_:)), "p", [.command, .shift]),
            item("Print…", #selector(EditorWindowController.printDocument(_:)), "p"),
        ])

        let find = parent("Find", [
            item("Find…", #selector(EditorWindowController.showFind(_:)), "f"),
            item("Find and Replace…", #selector(EditorWindowController.showFindAndReplace(_:)), "f", [.command, .option]),
            item("Find Next", #selector(EditorWindowController.findNext(_:)), "g"),
            item("Find Previous", #selector(EditorWindowController.findPrevious(_:)), "g", [.command, .shift]),
            item("Find All", #selector(EditorWindowController.findAll(_:)), "f", [.command, .shift]),
            item("Replace All", #selector(EditorWindowController.replaceAll(_:))),
            .separator(),
            item("Use Selection for Find", #selector(EditorWindowController.useSelectionForFind(_:)), "e"),
            item("Use Selection for Replace", #selector(EditorWindowController.useSelectionForReplace(_:)), "e", [.command, .shift]),
            .separator(),
            item("Filter Lines Matching Find Text", #selector(EditorWindowController.filterLinesToNewDocument(_:)), tag: 0),
            item("Filter Lines Not Matching Find Text", #selector(EditorWindowController.filterLinesToNewDocument(_:)), tag: 1),
            .separator(),
            item("Hide Find Bar", #selector(EditorWindowController.hideFind)),
        ])

        submenu("Edit", [
            item("Undo", #selector(BigTextView.undo(_:)), "z"),
            item("Redo", #selector(BigTextView.redo(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(BigTextView.cut(_:)), "x"),
            item("Copy", #selector(BigTextView.copy(_:)), "c"),
            item("Paste", #selector(BigTextView.paste(_:)), "v"),
            item("Delete", #selector(BigTextView.delete(_:))),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
            .separator(),
            find,
            .separator(),
            parent("Selection", [
                item("Select Line", #selector(BigTextView.selectLine(_:)), "l", [.command, .shift]),
                item("Split into Lines", #selector(BigTextView.splitSelectionIntoLines(_:)), "l", [.command, .option, .shift]),
                item("Add Next Occurrence", #selector(BigTextView.addNextOccurrence(_:)), "d"),
                item("Select All Occurrences", #selector(BigTextView.selectAllOccurrences(_:)), "g", [.command, .control]),
                arrow("Add Caret Above", #selector(BigTextView.addCaretAbove(_:)), NSUpArrowFunctionKey, [.control, .shift]),
                arrow("Add Caret Below", #selector(BigTextView.addCaretBelow(_:)), NSDownArrowFunctionKey, [.control, .shift]),
                item("Jump to Matching Bracket", #selector(BigTextView.jumpToMatchingBracket(_:)), "m", [.control]),
            ]),
            parent("Lines", [
                item("Shift Right", #selector(BigTextView.shiftRight(_:)), "]"),
                item("Shift Left", #selector(BigTextView.shiftLeft(_:)), "["),
                item("Toggle Comment", #selector(BigTextView.toggleComment(_:)), "/"),
                .separator(),
                item("Duplicate Line", #selector(BigTextView.duplicateLines(_:)), "d", [.command, .shift]),
                item("Delete Line", #selector(BigTextView.deleteLines(_:)), "k", [.control, .shift]),
                arrow("Move Line Up", #selector(BigTextView.moveLinesUp(_:)), NSUpArrowFunctionKey, [.command, .control]),
                arrow("Move Line Down", #selector(BigTextView.moveLinesDown(_:)), NSDownArrowFunctionKey, [.command, .control]),
                item("Join Lines", #selector(BigTextView.joinLines(_:)), "j"),
                .separator(),
                item("Sort Lines…", #selector(EditorWindowController.sortLines(_:))),
                item("Remove Duplicate Lines", #selector(EditorWindowController.removeDuplicateLines(_:)), tag: 0),
                item("Remove Adjacent Duplicate Lines", #selector(EditorWindowController.removeDuplicateLines(_:)), tag: 1),
                item("Trim Trailing Whitespace", #selector(BigTextView.trimTrailingWhitespace(_:))),
            ]),
            parent("Transform", [
                item("Make Uppercase", #selector(BigTextView.uppercaseSelection(_:)), "u", [.command, .control]),
                item("Make Lowercase", #selector(BigTextView.lowercaseSelection(_:)), "l", [.command, .control]),
                item("Capitalize", #selector(BigTextView.titlecaseSelection(_:))),
            ]),
            .separator(),
            item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]),
        ])

        let languageItems: [NSMenuItem] = Language.allCases.map {
            let i = item($0.displayName, #selector(EditorWindowController.setLanguageFromMenu(_:)))
            i.representedObject = $0.rawValue
            return i
        }
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = Self.makeThemeMenu()
        submenu("View", [
            themeItem,
            parent("Syntax", languageItems),
            .separator(),
            item("Word Wrap", #selector(toggleWordWrap(_:)), "w", [.command, .option]),
            item("Line Numbers", #selector(toggleLineNumbers(_:)), "l", [.command, .option]),
            item("Show Invisibles", #selector(toggleInvisibles(_:)), "i", [.command, .option]),
            item("Highlight Current Line", #selector(toggleCurrentLine(_:))),
            item("Align CSV Columns", #selector(toggleAlignColumns(_:))),
            item("Status Bar", #selector(toggleStatusBar(_:))),
            .separator(),
            item("Split Editor", #selector(EditorWindowController.toggleSplit(_:)), "\\", [.command, .option]),
            item("Hex View", #selector(EditorWindowController.toggleHexView(_:)), "h", [.command, .control]),
            .separator(),
            item("Bigger", #selector(biggerFont(_:)), "+"),
            item("Smaller", #selector(smallerFont(_:)), "-"),
            item("Actual Size", #selector(actualSizeFont(_:)), "0"),
            .separator(),
            item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]),
            item("Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:))),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        // Make ⌘= also zoom in (the unshifted key on US keyboards).
        let zoomIn = item("Bigger", #selector(biggerFont(_:)), "=")
        zoomIn.isHidden = true
        zoomIn.allowsKeyEquivalentWhenHidden = true
        main.items.last?.submenu?.addItem(zoomIn)

        submenu("Go", [
            item("Go to Line…", #selector(EditorWindowController.goToLine(_:)), "l"),
            item("Go to Top", #selector(EditorWindowController.goToTop(_:))),
            item("Go to Bottom", #selector(EditorWindowController.goToBottom(_:))),
            .separator(),
            fkey("Toggle Bookmark", #selector(EditorWindowController.toggleBookmark(_:)), 2, [.command]),
            fkey("Next Bookmark", #selector(EditorWindowController.nextBookmark(_:)), 2, []),
            fkey("Previous Bookmark", #selector(EditorWindowController.previousBookmark(_:)), 2, [.shift]),
            item("Clear Bookmarks", #selector(EditorWindowController.clearBookmarks(_:))),
        ])
        submenu("Format", [
            item("Format JSON", #selector(EditorWindowController.formatJSONInPlace(_:)), "j", [.command, .shift]),
            item("Minify JSON", #selector(EditorWindowController.minifyJSON(_:))),
            item("Pretty-Print JSON to New File…", #selector(EditorWindowController.formatJSON(_:)), "j", [.command, .option]),
            .separator(),
            item("Format XML / HTML", #selector(EditorWindowController.formatXML(_:))),
            item("Format SQL", #selector(EditorWindowController.formatSQL(_:))),
            .separator(),
            item("Filter Rows by Column…", #selector(EditorWindowController.filterColumn(_:))),
            item("Copy Column to New Document…", #selector(EditorWindowController.extractColumn(_:))),
        ])
        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "{", [.command, .shift]),
            item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "}", [.command, .shift]),
            item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = windowMenu
        let help = submenu("Help", [
            item("Keyboard Shortcuts", #selector(showShortcuts(_:)), "/", [.command, .shift]),
        ])
        NSApp.helpMenu = help
        return main
    }
}

extension NSAlert {
    static func show(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.runModal()
    }
}

/// Small floating progress window for slow opens (converting a huge
/// UTF-16 or Latin-1 file to UTF-8 the first time).
final class OpeningPanel {
    private let panel: NSPanel
    private let bar = NSProgressIndicator()
    var onCancel: (() -> Void)?

    init(name: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Opening"
        let label = NSTextField(labelWithString: "Opening “\(name)”…")
        label.lineBreakMode = .byTruncatingMiddle
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        cancel.target = self
        cancel.action = #selector(cancelTapped)
    }
    @objc private func cancelTapped() { onCancel?() }
    func show() { panel.center(); panel.makeKeyAndOrderFront(nil) }
    func set(_ p: Double) { bar.doubleValue = p }
    func close() { panel.orderOut(nil) }
}
