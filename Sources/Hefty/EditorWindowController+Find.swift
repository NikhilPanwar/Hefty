import AppKit
import BigFileCore

/// Find, replace, Find All, counting and line filtering.
extension EditorWindowController {

    // MARK: Showing the bar

    @objc func showFind(_ sender: Any?) {
        // Seed the field with a short single-line selection, like most Mac editors.
        let sel = textView.selection
        if !sel.isEmpty, sel.count <= 256, !findBar.inSelection {
            let s = String(decoding: textDocument.buffer.read(sel), as: UTF8.self)
            if !s.contains("\n") { findBar.findField.stringValue = s; lastFindText = s }
        }
        findBar.isHidden = false
        window?.makeFirstResponder(findBar.findField)
        findBar.findField.currentEditor()?.selectAll(nil)
        updateHighlightTerm()
        scheduleCount()
    }

    @objc func showFindAndReplace(_ sender: Any?) {
        findBar.setReplaceVisible(true)
        showFind(sender)
    }

    @objc func hideFind() {
        cancelSearch()
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        findBar.setStatus("")
        panes.forEach { $0.textView.findPattern = nil }
        window?.makeFirstResponder(textView)
    }

    @objc func findNext(_ sender: Any?) { find(backwards: false, focusEditor: true) }
    @objc func findPrevious(_ sender: Any?) { find(backwards: true, focusEditor: true) }

    func setFindTextForSnapshot(_ text: String) {
        findBar.findField.stringValue = text
        lastFindText = text
        updateHighlightTerm()
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        let sel = textView.selection
        guard !sel.isEmpty, sel.count <= 4096 else { NSSound.beep(); return }
        let s = String(decoding: textDocument.buffer.read(sel), as: UTF8.self)
        findBar.findField.stringValue = findBar.regex ? NSRegularExpression.escapedPattern(for: s) : s
        lastFindText = findBar.findField.stringValue
        updateHighlightTerm()
        scheduleCount()
    }

    @objc func useSelectionForReplace(_ sender: Any?) {
        let sel = textView.selection
        guard sel.count <= 4096 else { NSSound.beep(); return }
        findBar.replaceField.stringValue = String(decoding: textDocument.buffer.read(sel), as: UTF8.self)
        findBar.setReplaceVisible(true)
    }

    /// ⌘E then Find Next, from the context menu.
    @objc func findSelection(_ sender: Any?) {
        useSelectionForFind(sender)
        if findBar.isHidden { findBar.isHidden = false; updateHighlightTerm() }
        find(backwards: false, focusEditor: true)
    }

    @objc func findFieldChanged(_ sender: NSSearchField) {
        guard sender.stringValue != lastFindText else { return }
        lastFindText = sender.stringValue
        updateHighlightTerm()
        scheduleIncremental()
        scheduleCount()
    }

    func findOptionsChanged() {
        if findBar.inSelection {
            let sel = textView.selection
            if sel.isEmpty {
                findBar.selectionButton.state = .off
                findScope = nil
                statusBar.flash("Select some text first to search inside it.")
            } else { findScope = sel }
        } else { findScope = nil }
        updateHighlightTerm()
        scheduleIncremental()
        scheduleCount()
    }

    private var searchOptions: SearchOptions {
        SearchOptions(caseSensitive: findBar.caseSensitive, wholeWord: findBar.wholeWord, regex: findBar.regex,
                      wrapAround: true, range: findBar.inSelection ? findScope : nil)
    }

    /// The compiled pattern, or nil (and an error shown) if it's invalid.
    func currentPattern(showError: Bool = true) -> SearchPattern? {
        let text = findBar.findField.stringValue
        guard !text.isEmpty else { return nil }
        do { return try SearchPattern(text, options: searchOptions) }
        catch {
            if showError { findBar.setStatus("\(error)", error: true) }
            return nil
        }
    }

    func updateHighlightTerm() {
        let p = findBar.isHidden ? nil : currentPattern(showError: true)
        panes.forEach { $0.textView.findPattern = p }
    }

    /// Search-as-you-type: after a short pause, find the term starting at the
    /// current match so the selection grows/moves with what is typed.
    func scheduleIncremental() {
        pendingIncremental?.cancel()
        guard !findBar.findField.stringValue.isEmpty else {
            cancelSearch(); findBar.setStatus(""); return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.find(backwards: false, from: self.textView.selection.lowerBound, focusEditor: false, quiet: true)
        }
        pendingIncremental = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func cancelSearch() {
        pendingIncremental?.cancel()
        searcher?.cancel()
        if isSearching {
            searchGeneration += 1
            isSearching = false
            findBar.setStatus("")
        }
    }

    func find(backwards: Bool, from explicitStart: Int? = nil, focusEditor: Bool = false, quiet: Bool = false) {
        guard !findBar.findField.stringValue.isEmpty else { showFind(nil); return }
        if findBar.isHidden { findBar.isHidden = false; updateHighlightTerm() }
        guard let pattern = currentPattern() else { if !quiet { NSSound.beep() }; return }
        cancelSearch()
        findBar.remember(pattern.text)
        scheduleCount()

        let snap = textDocument.snapshot()
        let tv = textView
        let from = explicitStart ?? (backwards ? tv.selection.lowerBound : tv.selection.upperBound)
        let s = TextSearcher()
        searcher = s
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        findBar.setStatus("Searching…", busy: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = s.find(pattern, in: snap, from: from, backwards: backwards) { p in
                DispatchQueue.main.async {
                    guard let self, self.searchGeneration == generation else { return }
                    self.findBar.setStatus("Searching… \(Int(p * 100))%", busy: true)
                }
            }
            DispatchQueue.main.async {
                guard let self, self.searchGeneration == generation else { return }
                self.isSearching = false
                guard result == nil || snap.version == self.textDocument.buffer.version else {
                    // Edited while searching: search again on the new text.
                    self.find(backwards: backwards, from: explicitStart, focusEditor: focusEditor, quiet: quiet)
                    return
                }
                if let r = result {
                    tv.select(r)
                    let wrapped = backwards ? r.lowerBound >= from : r.lowerBound < from
                    self.findBar.setStatus(wrapped ? "Wrapped to the \(backwards ? "end" : "start")" : "")
                    if focusEditor { self.window?.makeFirstResponder(tv) }
                } else {
                    if !quiet { NSSound.beep() }
                    self.findBar.setStatus("Not found")
                }
                self.refreshChrome()
            }
        }
    }

    // MARK: Counting ("3 of 120")

    func scheduleCount() {
        guard !findBar.isHidden, let p = currentPattern(showError: false) else {
            counter?.cancel(); matchStarts = nil; matchTotal = nil; countKey = ""; updateMatchStatus(); return
        }
        let snap = textDocument.snapshot()
        let key = "\(p.text)|\(p.options.caseSensitive)|\(p.options.wholeWord)|\(p.options.regex)|\(String(describing: p.options.range))|\(snap.version)"
        guard key != countKey else { return }
        countKey = key
        counter?.cancel()
        matchStarts = nil; matchTotal = nil
        let c = TextSearcher()
        counter = c
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard !c.isCancelled else { return }
            var starts: [Int] = []
            let limit = 2_000_000
            let n = c.findAll(p, in: snap) { r, _ in
                if starts.count < limit { starts.append(r.lowerBound) }
                return true
            }
            guard !c.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, self.countKey == key else { return }
                self.matchTotal = n
                self.matchStarts = starts.count == n ? starts : nil
                self.updateMatchStatus()
            }
        }
        updateMatchStatus()
    }

    func updateMatchStatus() {
        guard !findBar.isHidden, !isSearching, !findBar.findField.stringValue.isEmpty else { return }
        if findBar.statusLabel.textColor == .systemRed { return }
        guard let total = matchTotal else {
            if !countKey.isEmpty, !findBar.statusLabel.stringValue.hasPrefix("Wrapped") { findBar.setStatus("Counting…") }
            return
        }
        if total == 0 { findBar.setStatus("Not found"); return }
        let sel = textView.selection
        var text = "\(total.formatted()) \(total == 1 ? "match" : "matches")"
        if let starts = matchStarts, !sel.isEmpty {
            var lo = 0, hi = starts.count
            while lo < hi { let mid = (lo + hi) / 2; if starts[mid] < sel.lowerBound { lo = mid + 1 } else { hi = mid } }
            if lo < starts.count && starts[lo] == sel.lowerBound { text = "\((lo + 1).formatted()) of \(total.formatted())" }
        }
        let wrapped = findBar.statusLabel.stringValue.hasPrefix("Wrapped") ? findBar.statusLabel.stringValue.components(separatedBy: " · ").first! + " · " : ""
        findBar.setStatus(wrapped + text)
    }

    // MARK: Replace

    func replaceCurrent(thenFind: Bool) {
        guard let pattern = currentPattern(), !textDocument.isReadOnly else { NSSound.beep(); return }
        let tv = textView
        let sel = tv.selection
        let snap = textDocument.snapshot()
        var exact = pattern.options
        exact.range = sel
        exact.wrapAround = false
        let s = TextSearcher()
        var matches = false
        if !sel.isEmpty, let p = try? SearchPattern(pattern.text, options: exact) {
            matches = s.find(p, in: snap, from: sel.lowerBound) == sel
        }
        if matches {
            let rep = s.replacement(for: sel, in: snap, pattern: pattern, template: findBar.replaceField.stringValue)
            tv.replace(sel, with: rep, name: "Replace")
        }
        if thenFind || !matches { find(backwards: false) }
    }

    /// Replaces every match (in the selection if "in selection" is on). Up to
    /// two million replacements are applied as one undoable step; beyond that
    /// the file is rewritten in a streamed pass (not undoable, after asking).
    @objc func replaceAll(_ sender: Any?) {
        guard let pattern = currentPattern() else { showFindAndReplace(nil); return }
        guard !textDocument.isReadOnly else { statusBar.flash("This document is read-only."); NSSound.beep(); return }
        let template = findBar.replaceField.stringValue
        findBar.remember(pattern.text)
        let snap = textDocument.snapshot()
        let limit = 2_000_000
        var edits: [(Range<Int>, [UInt8])] = []
        var overflow = false
        runJob("Replacing") { progress, cancelled in
            TextSearcher().findAll(pattern, in: snap, template: template, progress: progress) { r, rep in
                if cancelled() { return false }
                if edits.count >= limit { overflow = true; return false }
                edits.append((r, rep ?? []))
                return true
            }
        } completion: { [weak self] error in
            guard let self, error == nil else { return }
            guard snap.version == self.textDocument.buffer.version else {
                self.statusBar.flash("The document changed during Replace All. Nothing was replaced; try again.")
                return
            }
            if overflow { self.streamedReplaceAll(pattern, template: template); return }
            guard !edits.isEmpty else { self.findBar.setStatus("Not found"); NSSound.beep(); return }
            let tv = self.textView
            let before = tv.allSelections
            let first = edits[0]
            self.textDocument.applyEdits(edits, name: "Replace All", before: before,
                                         after: [first.0.lowerBound..<first.0.lowerBound + first.1.count])
            tv.setSelections([first.0.lowerBound..<first.0.lowerBound + first.1.count])
            self.findBar.setStatus("Replaced \(edits.count.formatted())")
            self.statusBar.flash("Replaced \(edits.count.formatted()) \(edits.count == 1 ? "match" : "matches").")
        }
    }

    private func streamedReplaceAll(_ pattern: SearchPattern, template: String) {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = "Replace more than 2 million matches?"
        a.informativeText = "This many replacements are written in one pass over the file and can't be undone. Your file on disk is not changed until you save."
        a.addButton(withTitle: "Replace All")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn, let out = try? self.textDocument.makeScratchURL("replaced.txt") else { return }
            let snap = self.textDocument.snapshot()
            var count = 0
            self.runJob("Replacing") { progress, cancelled in
                let sink = try FileSink(url: out)
                var pos = 0
                var failure: Error?
                count = TextSearcher().findAll(pattern, in: snap, template: template, progress: progress) { r, rep in
                    if cancelled() { return false }
                    do {
                        snap.forEachChunk(in: pos..<r.lowerBound) { buf, _ in (try? sink.write(buf)) != nil }
                        try sink.write(rep ?? [])
                    } catch { failure = error; return false }
                    pos = r.upperBound
                    return true
                }
                if let failure { throw failure }
                if cancelled() { throw CocoaError(.userCancelled) }
                snap.forEachChunk(in: pos..<snap.length) { buf, _ in (try? sink.write(buf)) != nil }
                try sink.close()
            } completion: { [weak self] error in
                guard let self, error == nil else { return }
                do {
                    try self.textDocument.replaceContents(withFile: out)
                    self.panes.forEach { $0.textView.documentDidReload() }
                    self.startIndexing()
                    self.statusBar.flash("Replaced \(count.formatted()) matches.")
                } catch { if let w = self.window { self.showError(error, in: w) } }
            }
        }
    }

    // MARK: Find All

    @objc func findAll(_ sender: Any?) {
        guard let pattern = currentPattern() else { showFind(nil); return }
        findBar.remember(pattern.text)
        let snap = textDocument.snapshot()
        var results: [ResultsPanel.Result] = []
        var total = 0
        let cap = 100_000
        runJob("Finding all") { progress, cancelled in
            total = TextSearcher().findAll(pattern, in: snap, progress: progress) { r, _ in
                if cancelled() { return false }
                if results.count < cap {
                    let lo = snap.lastNewline(in: max(0, r.lowerBound - 80)..<r.lowerBound).map { $0 + 1 } ?? max(0, r.lowerBound - 80)
                    let hi = snap.firstNewline(in: r.lowerBound..<min(snap.length, r.lowerBound + 240)) ?? min(snap.length, r.lowerBound + 240)
                    var preview = String(decoding: snap.read(lo..<hi), as: UTF8.self)
                    preview = preview.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    results.append(.init(range: r, preview: preview))
                }
                return true
            }
        } completion: { [weak self] error in
            guard let self, error == nil else { return }
            let shown = results.count < total ? " (showing the first \(results.count.formatted()))" : ""
            let doc = self.textDocument
            self.resultsPanel.lineProvider = { [weak doc] o in doc?.lineNumber(at: o) }
            self.resultsPanel.set(results, title: "\(total.formatted()) \(total == 1 ? "match" : "matches") for “\(pattern.text)”\(shown)")
            self.resultsPanel.isHidden = false
        }
    }

    // MARK: Filter lines

    /// Writes every line that matches (or doesn't match) the find text to a
    /// new document, EmEditor-style.
    @objc func filterLinesToNewDocument(_ sender: Any?) {
        let invert = (sender as? NSMenuItem)?.tag == 1
        guard let pattern = currentPattern() else {
            showFind(nil)
            statusBar.flash("Type what to look for in the find bar, then choose Filter Lines again.")
            return
        }
        guard let out = try? textDocument.makeScratchURL("filtered.txt") else { return }
        let snap = textDocument.snapshot()
        var n = 0
        let lang = textDocument.language
        let name = "\(textDocument.displayName) – \(invert ? "lines without" : "lines with") “\(pattern.text)”"
        runJob("Filtering lines") { progress, _ in
            let sink = try FileSink(url: out)
            n = try TextSearcher().filterLines(pattern, in: snap, invert: invert, to: sink, progress: progress)
            try sink.close()
        } completion: { [weak self] error in
            guard let self, error == nil else { return }
            do {
                let doc = try TextDocument(untitledName: name, contentsOf: out, language: lang)
                self.onOpenDocument?(doc)
                self.statusBar.flash("\(n.formatted()) lines")
            } catch { if let w = self.window { self.showError(error, in: w) } }
        }
    }

    // MARK: Find field keys

    // Esc in the find field cancels a running search, or closes the bar.
    // Return finds the next match, Shift-Return the previous one; Option-Return
    // in the replace field replaces all.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if isSearching { cancelSearch(); findBar.setStatus("Cancelled") } else { hideFind() }
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if control === findBar.replaceField {
                if flags.contains(.option) { replaceAll(nil) } else { replaceCurrent(thenFind: true) }
                return true
            }
            guard control === findBar.findField else { return false }
            pendingIncremental?.cancel()
            find(backwards: flags.contains(.shift))
            return true
        case #selector(NSResponder.insertTab(_:)):
            if control === findBar.findField && !findBar.showsReplace { window?.makeFirstResponder(self.textView); return true }
            return false
        default:
            return false
        }
    }
}
