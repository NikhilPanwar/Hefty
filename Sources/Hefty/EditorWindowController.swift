import AppKit
import BigFileCore

/// One window per open document: unified toolbar, a find bar that slides in
/// on ⌘F, one or two editor panes, an optional Find All panel and a status
/// bar. Background jobs (save, search, format) read a snapshot of the
/// document, so editing never has to wait for them.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate,
                                    NSToolbarDelegate, NSMenuItemValidation {
    let textDocument: TextDocument
    let bookmarks = Bookmarks()
    var panes: [EditorPane] = []
    let split = NSSplitView()
    let findBar = FindBar()
    let statusBar = StatusBar()
    let resultsPanel = ResultsPanel()
    var indexProgress: Double = 0
    var jobText: String?
    var jobCancel: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onOpenDocument: ((TextDocument) -> Void)?
    var closeAfterSave = false
    var saveCompletion: ((Bool) -> Void)?

    // Find state
    var searcher: TextSearcher?
    var searchGeneration = 0
    var isSearching = false
    var lastFindText = ""
    var pendingIncremental: DispatchWorkItem?
    var findScope: Range<Int>?
    var countKey = ""
    var matchStarts: [Int]?
    var matchTotal: Int?
    var counter: TextSearcher?

    // Files
    private var watcher: DispatchSourceFileSystemObject?
    private var watcherDebounce: DispatchWorkItem?
    private var isReloading = false
    let recoveryID = UUID().uuidString
    private var recoveryTimer: Timer?
    private var journaledVersion = -1
    private var docObserver: UUID?

    /// The pane holding keyboard focus (or the first one).
    var activePane: EditorPane {
        if let r = window?.firstResponder as? NSView {
            if let p = panes.first(where: { r.isDescendant(of: $0) }) { return p }
        }
        return panes[0]
    }
    var textView: BigTextView { activePane.textView }

    init(document: TextDocument) {
        textDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 600, height: 320)
        super.init(window: window)
        window.delegate = self
        if let url = document.url { window.representedURL = url }
        window.title = document.displayName
        Self.placeWindow(window)

        let toolbar = NSToolbar(identifier: "EditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .line

        if let u = document.url, let l = Prefs.language(for: u) { document.language = l; document.languageIsAutomatic = false }
        buildLayout(in: window)
        docObserver = document.addObserver { [weak self] change in self?.documentChanged(change) }
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Prefs.didChange, object: nil)
        applyPrefs()
        startIndexing()
        startWatching()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.journalIfNeeded() }
        window.makeFirstResponder(textView)
        refreshChrome()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Remembers the size of the first window; later windows cascade.
    private static var cascadePoint = NSPoint.zero
    private static func placeWindow(_ window: NSWindow) {
        if cascadePoint == .zero {
            if !window.setFrameUsingName("BigFileEditorWindow") { window.center() }
            window.setFrameAutosaveName("BigFileEditorWindow")
            cascadePoint = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        } else if let saved = UserDefaults.standard.string(forKey: "NSWindow Frame BigFileEditorWindow") {
            let n = saved.split(separator: " ").compactMap { Double($0) }
            if n.count >= 4 { window.setFrame(NSRect(x: n[0], y: n[1], width: n[2], height: n[3]), display: false) }
        }
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
    }

    // MARK: Layout

    private func makePane() -> EditorPane {
        let p = EditorPane(document: textDocument, bookmarks: bookmarks)
        let tv = p.textView
        tv.onStateChange = { [weak self, weak p] in
            p?.updateScrollers()
            self?.refreshChrome()
        }
        tv.onEscape = { [weak self] in self?.hideFind() }
        tv.onReadOnlyEdit = { [weak self] in self?.statusBar.flash("This document is read-only. Click the lock to allow editing.") }
        return p
    }

    private func buildLayout(in window: NSWindow) {
        let content = DropView()
        content.onDrop = { [weak self] urls in urls.forEach { self?.onOpenURL?($0) } }
        window.contentView = content

        findBar.isHidden = true
        findBar.findField.delegate = self
        findBar.findField.target = self
        findBar.findField.action = #selector(findFieldChanged(_:))
        findBar.replaceField.delegate = self
        findBar.onNext = { [weak self] in self?.find(backwards: false) }
        findBar.onPrevious = { [weak self] in self?.find(backwards: true) }
        findBar.onDone = { [weak self] in self?.hideFind() }
        findBar.onOptionsChanged = { [weak self] in self?.findOptionsChanged() }
        findBar.onReplace = { [weak self] thenFind in self?.replaceCurrent(thenFind: thenFind) }
        findBar.onReplaceAll = { [weak self] in self?.replaceAll(nil) }
        findBar.onFindAll = { [weak self] in self?.findAll(nil) }

        split.isVertical = false
        split.dividerStyle = .thin
        let first = makePane()
        panes = [first]
        split.addArrangedSubview(first)

        resultsPanel.isHidden = true
        resultsPanel.onSelect = { [weak self] r in
            guard let self else { return }
            self.textView.select(r)
            self.window?.makeFirstResponder(self.textView)
        }
        resultsPanel.onClose = { [weak self] in self?.resultsPanel.isHidden = true }

        statusBar.language.target = self
        statusBar.language.action = #selector(languageChosen(_:))
        statusBar.position.target = self
        statusBar.position.action = #selector(goToLine(_:))
        statusBar.readOnly.target = self
        statusBar.readOnly.action = #selector(toggleReadOnly(_:))
        statusBar.stopButton.target = self
        statusBar.stopButton.action = #selector(stopJob(_:))
        statusBar.setLanguage(textDocument.language)

        let stack = NSStackView(views: [findBar, split, resultsPanel, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for v in [findBar, split, resultsPanel, statusBar] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        split.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        for v in [findBar, resultsPanel, statusBar] {
            v.setContentHuggingPriority(.required, for: .vertical)
            v.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        split.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        buildStatusMenus()
    }

    @objc private func prefsChanged() { applyPrefs() }

    private func applyPrefs() {
        window?.appearance = Prefs.theme.fixedTheme?.appearance
        statusBar.isHidden = !Prefs.showStatusBar
        buildStatusMenus()
        panes.forEach { $0.needsLayout = true; $0.updateScrollers() }
        refreshChrome()
    }

    // MARK: Document events

    private func documentChanged(_ change: DocumentChange) {
        bookmarks.map(change, length: textDocument.length)
        matchStarts = nil; matchTotal = nil; countKey = ""
        if change.isReset { bookmarks.normalize(textDocument) }
        refreshChrome()
        if !findBar.isHidden && !findBar.findField.stringValue.isEmpty { scheduleCount() }
    }

    func startIndexing() {
        indexProgress = 0
        textDocument.startIndexing { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexProgress = p
                self.panes.forEach { $0.textView.needsDisplay = true }   // line numbers fill in
                self.refreshChrome()
            }
        }
    }

    // MARK: Chrome

    func refreshChrome() {
        guard let window else { return }
        let doc = textDocument
        let tv = textView
        let pos = tv.caretPosition()
        statusBar.setPosition("Ln \(pos.line.map { ($0 + 1).formatted() } ?? "…"), Col \(pos.column.formatted())")
        statusBar.selectionInfo.stringValue = tv.selectionSummary()

        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(doc.length), countStyle: .file)
        statusBar.size.stringValue = sizeText
        if let n = doc.lineCount { statusBar.lines.stringValue = "\(n.formatted()) \(n == 1 ? "line" : "lines")" }
        else { statusBar.lines.stringValue = "" }
        let indexing = indexProgress < 1 && !doc.lineIndex.isComplete
        if let jobText {
            statusBar.progressLabel.stringValue = jobText
            statusBar.progress.isHidden = true
        } else if indexing {
            statusBar.progressLabel.stringValue = "Indexing lines \(Int(indexProgress * 100))%"
            statusBar.progress.isHidden = false
            statusBar.progress.doubleValue = indexProgress
        } else {
            statusBar.progressLabel.stringValue = ""
            statusBar.progress.isHidden = true
        }
        statusBar.stopButton.isHidden = jobCancel == nil
        statusBar.progressLabel.isHidden = statusBar.progressLabel.stringValue.isEmpty
        statusBar.modified.stringValue = doc.isModified ? "Edited" : ""
        statusBar.modified.isHidden = !doc.isModified
        statusBar.readOnly.isHidden = !doc.isReadOnly
        statusBar.setLanguage(doc.language)
        statusBar.encoding.item(at: 0)?.title = doc.encoding.displayName
        statusBar.lineEnding.item(at: 0)?.title = doc.mixedLineEndings ? "Mixed" : doc.lineEnding.shortName
        statusBar.indentation.item(at: 0)?.title = Prefs.indentWithSpaces ? "Spaces: \(Prefs.tabWidth)" : "Tab Width: \(Prefs.tabWidth)"

        window.title = doc.displayName
        window.representedURL = doc.url
        window.subtitle = "\(sizeText) · \(doc.language.displayName)" + (doc.isReadOnly ? " · Read Only" : "")
        window.isDocumentEdited = doc.isModified
        updateMatchStatus()
    }

    @objc private func languageChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let l = Language(rawValue: raw) else { return }
        textDocument.language = l
        textDocument.languageIsAutomatic = false
        if let u = textDocument.url { Prefs.setLanguage(l, for: u) }
        panes.forEach { $0.textView.needsDisplay = true }
        Prefs.post()
    }

    @objc func setLanguageFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = Language(rawValue: raw) else { return }
        statusBar.language.selectItem(at: Language.allCases.firstIndex(of: l) ?? 0)
        languageChosen(statusBar.language)
    }

    private func buildStatusMenus() {
        // Encoding
        let enc = NSMenu()
        enc.addItem(withTitle: textDocument.encoding.displayName, action: nil, keyEquivalent: "")
        let reopen = NSMenuItem(title: "Reopen with Encoding", action: nil, keyEquivalent: "")
        let convert = NSMenuItem(title: "Save with Encoding", action: nil, keyEquivalent: "")
        reopen.submenu = NSMenu(); convert.submenu = NSMenu()
        for e in TextEncoding.all {
            let a = NSMenuItem(title: e.displayName, action: #selector(reopenWithEncoding(_:)), keyEquivalent: "")
            a.representedObject = e.displayName; a.target = self
            let b = NSMenuItem(title: e.displayName, action: #selector(convertEncoding(_:)), keyEquivalent: "")
            b.representedObject = e.displayName; b.target = self
            b.state = e == textDocument.encoding ? .on : .off
            reopen.submenu?.addItem(a); convert.submenu?.addItem(b)
        }
        enc.addItem(reopen); enc.addItem(convert)
        statusBar.encoding.menu = enc

        let le = NSMenu()
        le.addItem(withTitle: textDocument.lineEnding.shortName, action: nil, keyEquivalent: "")
        for e in LineEnding.allCases {
            let i = NSMenuItem(title: "Convert to \(e.displayName)", action: #selector(convertLineEndings(_:)), keyEquivalent: "")
            i.representedObject = e.rawValue; i.target = self
            i.state = e == textDocument.lineEnding && !textDocument.mixedLineEndings ? .on : .off
            le.addItem(i)
        }
        statusBar.lineEnding.menu = le

        let ind = NSMenu()
        ind.addItem(withTitle: "", action: nil, keyEquivalent: "")
        let spaces = NSMenuItem(title: "Indent Using Spaces", action: #selector(toggleIndentSpaces(_:)), keyEquivalent: "")
        spaces.target = self; spaces.state = Prefs.indentWithSpaces ? .on : .off
        ind.addItem(spaces)
        ind.addItem(.separator())
        for w in [2, 3, 4, 8] {
            let i = NSMenuItem(title: "Tab Width: \(w)", action: #selector(setTabWidth(_:)), keyEquivalent: "")
            i.tag = w; i.target = self; i.state = Prefs.tabWidth == w ? .on : .off
            ind.addItem(i)
        }
        statusBar.indentation.menu = ind
        refreshChrome()
    }

    @objc private func toggleIndentSpaces(_ sender: Any?) { Prefs.indentWithSpaces.toggle() }
    @objc private func setTabWidth(_ sender: NSMenuItem) { Prefs.tabWidth = sender.tag }

    // MARK: Background jobs

    /// Runs `work` off the main thread with progress in the status bar and a
    /// Stop button. `work` gets a progress callback and a cancellation check.
    func runJob(_ label: String,
                _ work: @escaping (_ progress: @escaping (Double) -> Void, _ cancelled: @escaping () -> Bool) throws -> Void,
                completion: @escaping (Error?) -> Void = { _ in }) {
        guard jobText == nil else { NSSound.beep(); statusBar.flash("Another operation is still running."); return }
        let flag = CancelFlag()
        jobText = label
        jobCancel = { flag.cancel() }
        refreshChrome()
        var last = Date.distantPast
        let progress: (Double) -> Void = { [weak self] p in
            guard Date().timeIntervalSince(last) > 0.1 else { return }
            last = Date()
            DispatchQueue.main.async {
                guard let self, self.jobText != nil else { return }
                self.jobText = "\(label) \(Int(p * 100))%"
                self.refreshChrome()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try work(progress, { flag.isCancelled }) } catch { failure = error }
            if flag.isCancelled && failure == nil { failure = CocoaError(.userCancelled) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.jobText = nil
                self.jobCancel = nil
                if let failure, (failure as? CocoaError)?.code != .userCancelled, let window = self.window {
                    self.showError(failure, in: window)
                }
                completion(failure)
                self.refreshChrome()
            }
        }
    }

    @objc func stopJob(_ sender: Any?) { jobCancel?() }

    func showError(_ error: Error, in window: NSWindow) {
        let a = NSAlert()
        a.messageText = "The operation couldn't be completed."
        a.informativeText = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        if let e = error as? CocoaError { a.informativeText = e.localizedDescription }
        a.beginSheetModal(for: window)
    }

    // MARK: File

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = textDocument.url else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func copyFilePath(_ sender: Any?) {
        guard let url = textDocument.url else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc func toggleReadOnly(_ sender: Any?) {
        if textDocument.isReadOnly, let url = textDocument.url, access(url.path, W_OK) != 0 {
            statusBar.flash("You don't have permission to change this file. You can edit it and use Save As.")
        }
        textDocument.isReadOnly.toggle()
        refreshChrome()
    }

    // MARK: Saving

    @objc func saveDocument(_ sender: Any?) {
        if textDocument.url == nil { saveDocumentAs(sender); return }
        save(to: nil, encoding: nil)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = textDocument.url?.lastPathComponent ?? textDocument.untitledName + ".txt"
        if let dir = textDocument.url?.deletingLastPathComponent() { panel.directoryURL = dir }
        panel.canCreateDirectories = true
        let (accessory, encPopup, lePopup) = saveAccessory()
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK, let url = panel.url else { return }
            let enc = TextEncoding.named(encPopup.titleOfSelectedItem ?? "") ?? self.textDocument.encoding
            if let raw = lePopup.selectedItem?.representedObject as? String, let le = LineEnding(rawValue: raw),
               le != self.textDocument.lineEnding || self.textDocument.mixedLineEndings {
                self.textDocument.setLineEnding(le)
            }
            self.save(to: url, encoding: enc)
        }
    }

    private func saveAccessory() -> (NSView, NSPopUpButton, NSPopUpButton) {
        let enc = NSPopUpButton(frame: .zero, pullsDown: false)
        for e in TextEncoding.all { enc.addItem(withTitle: e.displayName) }
        enc.selectItem(withTitle: textDocument.encoding.displayName)
        let le = NSPopUpButton(frame: .zero, pullsDown: false)
        for e in LineEnding.allCases { le.addItem(withTitle: e.displayName); le.lastItem?.representedObject = e.rawValue }
        le.selectItem(at: LineEnding.allCases.firstIndex(of: textDocument.lineEnding) ?? 0)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Text encoding:"), enc],
                                      [NSTextField(labelWithString: "Line endings:"), le]])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 76))
        grid.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(grid)
        NSLayoutConstraint.activate([grid.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                                     grid.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
        return (box, enc, le)
    }

    /// Writes a snapshot in the background (editing continues), then marks
    /// that state as saved. Undo history is kept.
    func save(to url: URL?, encoding: TextEncoding?, completion: ((Bool) -> Void)? = nil) {
        let doc = textDocument
        guard let dest = url ?? doc.url else { saveDocumentAs(nil); return }
        if url == nil, doc.changedOnDisk, let window {
            let a = NSAlert()
            a.messageText = "\(doc.displayName) was changed by another application."
            a.informativeText = "Saving will replace those changes with your version."
            a.addButton(withTitle: "Save Anyway")
            a.addButton(withTitle: "Cancel")
            a.beginSheetModal(for: window) { [weak self] r in
                guard r == .alertFirstButtonReturn else { completion?(false); return }
                self?.performSave(dest, encoding: encoding ?? doc.encoding, completion: completion)
            }
            return
        }
        performSave(dest, encoding: encoding ?? doc.encoding, completion: completion)
    }

    private func performSave(_ dest: URL, encoding: TextEncoding, completion: ((Bool) -> Void)?) {
        let doc = textDocument
        let snap = doc.snapshot()
        let le = doc.saveLineEnding
        stopWatching()
        runJob("Saving") { progress, _ in
            try TextDocument.write(snap, to: dest, encoding: encoding, lineEnding: le, progress: progress)
        } completion: { [weak self] error in
            guard let self else { return }
            if error == nil {
                doc.didSave(snap, to: dest, encoding: encoding)
                Recovery.remove(id: self.recoveryID)
                NSDocumentController.shared.noteNewRecentDocumentURL(dest)
                self.statusBar.flash("Saved")
                self.buildStatusMenus()
            }
            self.startWatching()
            self.refreshChrome()
            completion?(error == nil)
            if error == nil && self.closeAfterSave { self.closeAfterSave = false; self.window?.close() }
            self.closeAfterSave = false
        }
    }

    @objc func revertDocumentToSaved(_ sender: Any?) {
        guard let window, textDocument.url != nil else { return }
        let a = NSAlert()
        a.messageText = "Revert to the saved version of \(textDocument.displayName)?"
        a.informativeText = "Your current changes will be lost."
        a.addButton(withTitle: "Revert")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.reload(encoding: self?.textDocument.encoding, appended: false)
        }
    }

    @objc func reopenWithEncoding(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let enc = TextEncoding.named(name),
              textDocument.url != nil, let window else { return }
        let go = { [weak self] in self?.reload(encoding: enc, appended: false) }
        guard textDocument.isModified else { go(); return }
        let a = NSAlert()
        a.messageText = "Reopen \(textDocument.displayName) as \(enc.displayName)?"
        a.informativeText = "Your unsaved changes will be lost."
        a.addButton(withTitle: "Reopen")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { go() } }
    }

    @objc func convertEncoding(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let enc = TextEncoding.named(name) else { return }
        textDocument.setEncoding(enc)
        statusBar.flash("The file will be saved as \(enc.displayName).")
        buildStatusMenus()
    }

    @objc func convertLineEndings(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let le = LineEnding(rawValue: raw) else { return }
        textDocument.setLineEnding(le)
        statusBar.flash("Line endings will be saved as \(le.shortName).")
        buildStatusMenus()
    }

    /// Re-reads the file from disk (Revert, Reopen with Encoding, or after
    /// another app changed it). For a file that only grew, the line index is
    /// reused and, if the caret was at the end, it follows the new end.
    func reload(encoding: TextEncoding?, appended: Bool) {
        guard let url = textDocument.url, !isReloading else { return }
        isReloading = true
        let wasAtEnd = textView.caret >= textDocument.length && textDocument.length > 0
        let fallback = Prefs.fallbackTextEncoding
        stopWatching()
        var fresh: TextDocument?
        runJob("Reloading") { progress, cancelled in
            fresh = try TextDocument(url: url, encoding: encoding, fallback: fallback, progress: progress, isCancelled: cancelled)
        } completion: { [weak self] error in
            guard let self else { return }
            self.isReloading = false
            if let fresh, error == nil {
                let keepLanguage = self.textDocument.language
                if appended { self.textDocument.adoptAppended(fresh) } else { self.textDocument.adopt(fresh) }
                if !self.textDocument.languageIsAutomatic { self.textDocument.language = keepLanguage }
                for p in self.panes { p.textView.documentDidReload() }
                Recovery.remove(id: self.recoveryID)
                self.startIndexing()
                self.buildStatusMenus()
                if appended && wasAtEnd && Prefs.followTail {
                    for p in self.panes { p.textView.setSelections([self.textDocument.length..<self.textDocument.length]) }
                }
            }
            self.startWatching()
            self.refreshChrome()
        }
    }

    // MARK: Watching the file on disk

    func startWatching() {
        stopWatching()
        guard let url = textDocument.url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke],
                                                            queue: .main)
        src.setEventHandler { [weak self] in self?.fileEvent() }
        src.setCancelHandler { Darwin.close(fd) }
        watcher = src
        src.resume()
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func fileEvent() {
        watcherDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.checkDisk() }
        watcherDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Reacts to another app changing, growing or deleting our file.
    func checkDisk() {
        guard let url = textDocument.url, jobText == nil, textDocument.changedOnDisk else {
            // Re-arm after atomic replacements (the watched inode is gone).
            if textDocument.url != nil { startWatching() }
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusBar.flash("\(textDocument.displayName) was moved or deleted. Save to write it again.")
            textDocument.buffer.markUnsaved()
            refreshChrome()
            return
        }
        let oldSize = textDocument.diskStamp?.size ?? 0
        let newSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if !textDocument.isModified && Prefs.autoReload {
            reload(encoding: textDocument.encoding, appended: newSize > oldSize && textDocument.encoding.isUTF8)
            return
        }
        guard let window, window.attachedSheet == nil else { return }
        let a = NSAlert()
        a.messageText = "\(textDocument.displayName) was changed by another application."
        a.informativeText = textDocument.isModified
            ? "You have unsaved changes. Reload the file from disk (losing your changes) or keep your version?"
            : "Reload it to see the changes?"
        a.addButton(withTitle: textDocument.isModified ? "Keep My Version" : "Reload")
        a.addButton(withTitle: textDocument.isModified ? "Reload" : "Ignore")
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            let reload = self.textDocument.isModified ? r == .alertSecondButtonReturn : r == .alertFirstButtonReturn
            if reload { self.reload(encoding: self.textDocument.encoding, appended: false) }
            else { self.textDocument.refreshDiskStamp(); self.startWatching() }
        }
    }

    // MARK: Crash recovery

    private func journalIfNeeded() {
        let doc = textDocument
        guard doc.isModified else {
            if journaledVersion != -1 { Recovery.remove(id: recoveryID); journaledVersion = -1 }
            return
        }
        guard doc.buffer.version != journaledVersion else { return }
        journaledVersion = doc.buffer.version
        try? Recovery.save(doc, id: recoveryID)
    }

    // MARK: Split / hex

    @objc func toggleSplit(_ sender: Any?) {
        if panes.count == 1 {
            let p = makePane()
            p.textView.setSelections([textView.caret..<textView.caret], reveal: true, centered: true)
            panes.append(p)
            split.addArrangedSubview(p)
            split.layoutSubtreeIfNeeded()
            split.adjustSubviews()
            split.setPosition(floor(split.bounds.height / 2), ofDividerAt: 0)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panes.count > 1, self.panes[0].frame.height < 40 else { return }
                self.split.setPosition(floor(self.split.bounds.height / 2), ofDividerAt: 0)
            }
            window?.makeFirstResponder(p.textView)
        } else {
            let p = panes.removeLast()
            p.removeFromSuperview()
            window?.makeFirstResponder(panes[0].textView)
        }
        refreshChrome()
    }

    @objc func toggleHexView(_ sender: Any?) {
        let p = activePane
        p.setHex(!p.isHex)
    }

    // MARK: Bookmarks

    @objc func toggleBookmark(_ sender: Any?) {
        bookmarks.toggle(textDocument.lineStart(containing: textView.caret))
        panes.forEach { $0.textView.needsDisplay = true }
    }
    @objc func nextBookmark(_ sender: Any?) {
        let c = textView.caret
        guard let o = bookmarks.offsets.first(where: { $0 > c }) ?? bookmarks.offsets.first else { NSSound.beep(); return }
        textView.moveCaret(to: o)
    }
    @objc func previousBookmark(_ sender: Any?) {
        let ls = textDocument.lineStart(containing: textView.caret)
        guard let o = bookmarks.offsets.last(where: { $0 < ls }) ?? bookmarks.offsets.last else { NSSound.beep(); return }
        textView.moveCaret(to: o)
    }
    @objc func clearBookmarks(_ sender: Any?) {
        bookmarks.clear()
        panes.forEach { $0.textView.needsDisplay = true }
    }

    // MARK: Go to line

    @objc func goToLine(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        let count = textDocument.lineCount
        alert.informativeText = (count.map { "This file has \($0.formatted()) lines. " } ?? "Line count is still being indexed (\(Int(indexProgress * 100))%). ")
            + "Type a line, line:column, a percentage (50%) or a byte offset (@1024 or 0x400)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = count.map { "1 – \($0.formatted())" } ?? "Line number"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.go(to: field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    func go(to spec: String) {
        let doc = textDocument
        let s = spec.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "_", with: "")
        if s.hasSuffix("%"), let p = Double(s.dropLast()) {
            let o = doc.lineStart(containing: Int(Double(doc.length) * min(100, max(0, p)) / 100))
            textView.moveCaret(to: o); window?.makeFirstResponder(textView); return
        }
        if s.hasPrefix("@") || s.lowercased().hasPrefix("0x") {
            let v = s.hasPrefix("@") ? Int(s.dropFirst()) : Int(s.dropFirst(2), radix: 16)
            guard let o = v, o >= 0 else { NSSound.beep(); return }
            textView.moveCaret(to: min(o, doc.length)); window?.makeFirstResponder(textView); return
        }
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard let n = parts.first.flatMap({ Int($0) }), n >= 1 else { NSSound.beep(); return }
        let col = parts.count > 1 ? max(1, Int(parts[1]) ?? 1) : 1
        guard let off = doc.offset(ofLine: n - 1) else {
            let a = NSAlert()
            a.messageText = "Line \(n.formatted()) is not available yet"
            a.informativeText = doc.lineIndex.isComplete ? "The file has fewer lines."
                : "Still indexing (\(Int(indexProgress * 100))%). Try again shortly."
            if let w = window { a.beginSheetModal(for: w) }
            return
        }
        // Column: count characters along the line.
        let line = doc.logicalLine(containing: off)
        let text = String(decoding: doc.buffer.read(off..<min(line.upperBound, off + 1 << 20)), as: UTF8.self)
        let prefix = String(text.prefix(col - 1))
        textView.moveCaret(to: off + prefix.utf8.count)
        window?.makeFirstResponder(textView)
    }

    @objc func goToTop(_ sender: Any?) { textView.moveCaret(to: 0) }
    @objc func goToBottom(_ sender: Any?) { textView.moveCaret(to: textDocument.length) }

    // MARK: Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let busy = jobText != nil
        switch item.action {
        case #selector(saveDocument(_:)): return (textDocument.isModified || textDocument.url == nil) && !busy
        case #selector(saveDocumentAs(_:)): return !busy
        case #selector(revertDocumentToSaved(_:)): return textDocument.url != nil && textDocument.isModified && !busy
        case #selector(revealInFinder(_:)), #selector(copyFilePath(_:)): return textDocument.url != nil
        case #selector(useSelectionForFind(_:)), #selector(findSelection(_:)): return !textView.selection.isEmpty
        case #selector(toggleSplit(_:)):
            item.title = panes.count > 1 ? "Close Split Editor" : "Split Editor"; return true
        case #selector(toggleHexView(_:)): item.state = activePane.isHex ? .on : .off; return true
        case #selector(toggleReadOnly(_:)): item.state = textDocument.isReadOnly ? .on : .off; return true
        case #selector(setLanguageFromMenu(_:)):
            item.state = (item.representedObject as? String) == textDocument.language.rawValue ? .on : .off; return true
        case #selector(nextBookmark(_:)), #selector(previousBookmark(_:)), #selector(clearBookmarks(_:)): return !bookmarks.offsets.isEmpty
        case #selector(formatJSONInPlace(_:)), #selector(minifyJSON(_:)), #selector(formatXML(_:)), #selector(formatSQL(_:)),
             #selector(sortLines(_:)), #selector(removeDuplicateLines(_:)), #selector(filterColumn(_:)):
            return !busy && !textDocument.isReadOnly
        case #selector(formatJSON(_:)), #selector(extractColumn(_:)), #selector(filterLinesToNewDocument(_:)),
             #selector(replaceAll(_:)), #selector(findAll(_:)), #selector(exportSelection(_:)):
            return !busy
        case #selector(stopJob(_:)): return jobCancel != nil
        default: return true
        }
    }

    // MARK: Toolbar

    private enum ToolbarID {
        static let find = NSToolbarItem.Identifier("find")
        static let goTo = NSToolbarItem.Identifier("goto")
        static let wrap = NSToolbarItem.Identifier("wrap")
        static let theme = NSToolbarItem.Identifier("theme")
        static let format = NSToolbarItem.Identifier("format")
        static let reveal = NSToolbarItem.Identifier("reveal")
        static let split = NSToolbarItem.Identifier("split")
        static let hex = NSToolbarItem.Identifier("hex")
        static let invisibles = NSToolbarItem.Identifier("invisibles")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarID.goTo, ToolbarID.wrap, ToolbarID.split, ToolbarID.theme, ToolbarID.find]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.find, ToolbarID.goTo, ToolbarID.wrap, ToolbarID.theme, ToolbarID.format, ToolbarID.reveal,
         ToolbarID.split, ToolbarID.hex, ToolbarID.invisibles, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector, _ tip: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = tip
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        switch id {
        case ToolbarID.find: return button("Find", "magnifyingglass", #selector(showFind(_:)), "Find (⌘F)")
        case ToolbarID.goTo: return button("Go to Line", "arrow.down.to.line", #selector(goToLine(_:)), "Go to Line (⌘L)")
        case ToolbarID.wrap: return button("Word Wrap", "text.alignleft", #selector(toggleWordWrapFromToolbar(_:)), "Toggle Word Wrap (⌥⌘W)")
        case ToolbarID.format: return button("Format JSON", "curlybraces", #selector(formatJSONInPlace(_:)), "Format JSON (⇧⌘J)")
        case ToolbarID.reveal: return button("Show in Finder", "folder", #selector(revealInFinder(_:)), "Show in Finder")
        case ToolbarID.split: return button("Split", "rectangle.split.1x2", #selector(toggleSplit(_:)), "Split Editor")
        case ToolbarID.hex: return button("Hex", "number", #selector(toggleHexView(_:)), "Hex View")
        case ToolbarID.invisibles: return button("Invisibles", "paragraphsign", #selector(toggleInvisiblesFromToolbar(_:)), "Show Invisibles")
        case ToolbarID.theme:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Theme"
            item.paletteLabel = "Theme"
            item.toolTip = "Editor Theme"
            item.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Theme")
            item.showsIndicator = true
            item.menu = AppDelegate.makeThemeMenu()
            return item
        default: return nil
        }
    }

    @objc private func toggleWordWrapFromToolbar(_ sender: Any?) { Prefs.wordWrap.toggle() }
    @objc private func toggleInvisiblesFromToolbar(_ sender: Any?) { Prefs.showInvisibles.toggle() }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard textDocument.isModified else { return true }
        askToSave { [weak self] decision in
            guard let self else { return }
            switch decision {
            case .save:
                self.closeAfterSave = true
                self.saveDocument(nil)
            case .discard:
                Recovery.remove(id: self.recoveryID)
                self.textDocument.buffer.markSaved()   // so close doesn't ask again
                self.window?.close()
            case .cancel: break
            }
        }
        return false
    }

    enum SaveDecision { case save, discard, cancel }

    /// The standard "Do you want to save the changes…" sheet.
    func askToSave(_ done: @escaping (SaveDecision) -> Void) {
        guard let window else { done(.cancel); return }
        let a = NSAlert()
        a.messageText = "Do you want to save the changes you made to \(textDocument.displayName)?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: textDocument.url == nil ? "Save…" : "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don't Save")
        a.buttons[2].hasDestructiveAction = true
        a.beginSheetModal(for: window) { r in
            switch r {
            case .alertFirstButtonReturn: done(.save)
            case .alertThirdButtonReturn: done(.discard)
            default: done(.cancel)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        textDocument.lineIndex.cancel()
        cancelSearch()
        counter?.cancel()
        jobCancel?()
        stopWatching()
        recoveryTimer?.invalidate()
        if !textDocument.isModified { Recovery.remove(id: recoveryID) }
        if let docObserver { textDocument.removeObserver(docObserver) }
    }
}

/// Thread-safe cancellation flag for background jobs.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Content view that accepts files dropped from Finder.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let u = urls(sender)
        guard !u.isEmpty else { return false }
        onDrop?(u)
        return true
    }
}
