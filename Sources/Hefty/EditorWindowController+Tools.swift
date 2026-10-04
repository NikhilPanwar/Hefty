import AppKit
import BigFileCore

/// Formatting, sorting, column tools, export and printing.
extension EditorWindowController {

    /// Selection if there is exactly one non-empty selection, else the whole document.
    private var scope: (range: Range<Int>, isSelection: Bool) {
        let sels = textView.allSelections.filter { !$0.isEmpty }
        if sels.count == 1 { return (sels[0], true) }
        return (0..<textDocument.length, false)
    }

    private static let inMemoryLimit = 512 << 20

    /// Runs a streaming transform on the selection (or whole document) into a
    /// scratch file, then swaps the result in: as one undoable edit when it
    /// fits in memory, otherwise as a non-undoable rewrite (after asking).
    func transformInPlace(_ name: String,
                          _ produce: @escaping (TextSnapshot, FileSink, @escaping (Double) -> Void, @escaping () -> Bool) throws -> Void) {
        guard !textDocument.isReadOnly else { statusBar.flash("This document is read-only."); NSSound.beep(); return }
        guard let out = try? textDocument.makeScratchURL("transformed.txt") else { return }
        let (range, isSelection) = scope
        let full = textDocument.snapshot()
        let snap = isSelection ? full.slice(range) : full
        runJob(name) { progress, cancelled in
            let sink = try FileSink(url: out)
            try produce(snap, sink, progress, cancelled)
            try sink.close()
        } completion: { [weak self] error in
            guard let self, error == nil else { try? FileManager.default.removeItem(at: out); return }
            guard full.version == self.textDocument.buffer.version else {
                self.statusBar.flash("The document changed while \(name.lowercased()) ran. Nothing was changed; try again.")
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            if size <= Self.inMemoryLimit, let data = try? Data(contentsOf: out) {
                try? FileManager.default.removeItem(at: out)
                let tv = self.textView
                tv.replace(range, with: [UInt8](data), name: name)
                if !isSelection { tv.setSelections([0..<0]) }
                return
            }
            guard !isSelection, let window = self.window else {
                self.statusBar.flash("The result is too large to replace a selection.")
                return
            }
            let a = NSAlert()
            a.messageText = "\(name) can't be undone for a file this large."
            a.informativeText = "The result (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) replaces the document. Your file on disk is not changed until you save."
            a.addButton(withTitle: "Continue")
            a.addButton(withTitle: "Cancel")
            a.beginSheetModal(for: window) { r in
                guard r == .alertFirstButtonReturn else { try? FileManager.default.removeItem(at: out); return }
                do {
                    try self.textDocument.replaceContents(withFile: out)
                    self.panes.forEach { $0.textView.documentDidReload() }
                    self.startIndexing()
                } catch { self.showError(error, in: window) }
            }
        }
    }

    /// The bytes of `snap` as one buffer: in memory for modest sizes, or a
    /// memory-mapped scratch copy for whole huge documents.
    private func contiguous(_ snap: TextSnapshot, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        if snap.length <= Self.inMemoryLimit {
            let bytes = snap.read(0..<snap.length)
            try bytes.withUnsafeBytes(body)
            return
        }
        let tmp = try textDocument.makeScratchURL("copy.txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sink = try FileSink(url: tmp)
        var failure: Error?
        snap.forEachChunk(in: 0..<snap.length) { buf, _ in
            do { try sink.write(buf) } catch { failure = error; return false }
            return true
        }
        if let failure { throw failure }
        try sink.close()
        let m = try MappedFile(url: tmp)
        try body(m.bytes(0..<m.size))
    }

    // MARK: Formatting

    var indentText: (Int, Bool) { (Prefs.tabWidth, !Prefs.indentWithSpaces) }

    @objc func formatJSONInPlace(_ sender: Any?) {
        let (w, tabs) = indentText
        transformInPlace("Format JSON") { snap, sink, progress, _ in
            try JSONFormatter.format(snap, to: sink, indent: w, useTabs: tabs, progress: progress)
        }
    }

    @objc func minifyJSON(_ sender: Any?) {
        transformInPlace("Minify JSON") { snap, sink, progress, _ in
            try JSONFormatter.format(snap, to: sink, minify: true, progress: progress)
        }
    }

    @objc func formatXML(_ sender: Any?) {
        let (w, tabs) = indentText
        transformInPlace("Format XML") { snap, sink, progress, _ in
            try XMLFormatter.format(snap, to: sink, indent: w, useTabs: tabs, progress: progress)
        }
    }

    @objc func formatSQL(_ sender: Any?) {
        guard scope.range.count <= 64 << 20 else {
            statusBar.flash("SQL formatting works on up to 64 MB. Select the statements to format.")
            NSSound.beep(); return
        }
        let indent = Prefs.indentWithSpaces ? String(repeating: " ", count: Prefs.tabWidth) : "\t"
        transformInPlace("Format SQL") { snap, sink, _, _ in
            try sink.write(SQLFormatter.format(snap.read(0..<snap.length), indent: indent))
        }
    }

    /// Pretty-prints JSON into a new file (keeps the original untouched).
    @objc func formatJSON(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        let base = textDocument.url?.deletingPathExtension().lastPathComponent ?? textDocument.untitledName
        panel.nameFieldStringValue = "\(base).formatted.json"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK, let out = panel.url else { return }
            let snap = self.textDocument.snapshot()
            let (w, tabs) = self.indentText
            self.runJob("Formatting") { progress, _ in
                let sink = try FileSink(url: out)
                try JSONFormatter.format(snap, to: sink, indent: w, useTabs: tabs, progress: progress)
                try sink.close()
            } completion: { [weak self] error in
                if error == nil { self?.onOpenURL?(out) }
            }
        }
    }

    // MARK: Columns

    private var separator: UInt8 { textDocument.language == .tsv ? 0x09 : 0x2C }

    /// Column names from the first line (for CSV/TSV), else "Column N".
    private func columnTitles() -> [String] {
        let (bytes, _) = textDocument.line(at: 0)
        let fields = Highlighter.fields(Array(bytes.prefix(1 << 16)), separator: separator)
        return fields.enumerated().map { i, r in
            var t = String(decoding: bytes[r], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t = String(t.dropFirst().dropLast()) }
            return "Column \(i + 1)" + (t.isEmpty || t.count > 40 ? "" : " – \(t)")
        }
    }

    private func columnPopup(includeWholeLine: Bool) -> NSPopUpButton {
        let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        if includeWholeLine { p.addItem(withTitle: "Whole line") }
        let isDelimited = textDocument.language == .csv || textDocument.language == .tsv
        for t in isDelimited ? columnTitles() : [] { p.addItem(withTitle: t) }
        return p
    }

    private func form(_ rows: [[NSView]]) -> NSView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 380, height: CGFloat(rows.count) * 30)
        return grid
    }

    @objc func sortLines(_ sender: Any?) {
        guard let window else { return }
        let column = columnPopup(includeWholeLine: true)
        let desc = NSButton(checkboxWithTitle: "Descending", target: nil, action: nil)
        let numeric = NSButton(checkboxWithTitle: "Numeric", target: nil, action: nil)
        let cs = NSButton(checkboxWithTitle: "Case-sensitive", target: nil, action: nil)
        let dedupe = NSButton(checkboxWithTitle: "Remove duplicates", target: nil, action: nil)
        let header = NSButton(checkboxWithTitle: "Keep first line (header) in place", target: nil, action: nil)
        let isDelimited = textDocument.language == .csv || textDocument.language == .tsv
        header.state = isDelimited && !scope.isSelection ? .on : .off
        let a = NSAlert()
        a.messageText = scope.isSelection ? "Sort Selected Lines" : "Sort Lines"
        a.informativeText = scope.isSelection ? "" : "Sorts the whole document."
        a.accessoryView = form([[NSTextField(labelWithString: "Sort by:"), column],
                                [NSGridCell.emptyContentView, desc], [NSGridCell.emptyContentView, numeric],
                                [NSGridCell.emptyContentView, cs], [NSGridCell.emptyContentView, dedupe],
                                [NSGridCell.emptyContentView, header]])
        a.addButton(withTitle: "Sort")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            var o = SortOptions()
            o.descending = desc.state == .on
            o.numeric = numeric.state == .on
            o.caseInsensitive = cs.state == .off
            o.removeDuplicates = dedupe.state == .on
            o.column = column.indexOfSelectedItem > 0 ? column.indexOfSelectedItem - 1 : nil
            o.separator = self.separator
            let keepHeader = header.state == .on
            let nl = self.textDocument.newlineBytes
            self.transformInPlace("Sort Lines") { snap, sink, _, _ in
                try self.contiguous(snap) { buf in
                    var body = buf
                    if keepHeader, let base = buf.baseAddress, let nlp = memchr(base, 0x0A, buf.count) {
                        let cut = UnsafeRawPointer(nlp) - base + 1
                        try sink.write(UnsafeRawBufferPointer(rebasing: buf[0..<cut]))
                        body = UnsafeRawBufferPointer(rebasing: buf[cut...])
                    }
                    try LineTools.sort(body, options: o, newline: nl) { try sink.write($0) }
                }
            }
        }
    }

    @objc func removeDuplicateLines(_ sender: Any?) {
        let adjacent = (sender as? NSMenuItem)?.tag == 1
        let nl = textDocument.newlineBytes
        var removed = 0
        transformInPlace("Remove Duplicate Lines") { [weak self] snap, sink, _, _ in
            try self?.contiguous(snap) { buf in
                removed = try LineTools.removeDuplicates(buf, adjacentOnly: adjacent, newline: nl) { try sink.write($0) }
            }
            DispatchQueue.main.async { self?.statusBar.flash("Removed \(removed.formatted()) duplicate \(removed == 1 ? "line" : "lines").") }
        }
    }

    @objc func filterColumn(_ sender: Any?) {
        guard let window else { return }
        let column = columnPopup(includeWholeLine: false)
        guard column.numberOfItems > 0 else { statusBar.flash("Column tools need a CSV or TSV file. Choose CSV or TSV in the status bar."); return }
        let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        text.placeholderString = "Value to look for"
        let exact = NSButton(checkboxWithTitle: "Whole value must match", target: nil, action: nil)
        let header = NSButton(checkboxWithTitle: "Keep header row", target: nil, action: nil)
        header.state = .on
        let a = NSAlert()
        a.messageText = "Filter Rows by Column"
        a.informativeText = "Rows whose column contains the value (ignoring case) go to a new document."
        a.accessoryView = form([[NSTextField(labelWithString: "Column:"), column],
                                [NSTextField(labelWithString: "Contains:"), text],
                                [NSGridCell.emptyContentView, exact], [NSGridCell.emptyContentView, header]])
        a.addButton(withTitle: "Filter")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = text
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            let col = column.indexOfSelectedItem, value = text.stringValue
            let sep = self.separator, nl = self.textDocument.newlineBytes
            let isExact = exact.state == .on, keep = header.state == .on
            self.toNewDocument("Filtering rows", name: "\(self.textDocument.displayName) – rows where \(column.titleOfSelectedItem ?? "") contains “\(value)”") { snap, sink in
                try self.contiguous(snap) { buf in
                    _ = try LineTools.filterColumn(buf, column: col, separator: sep, text: value, exact: isExact,
                                                   keepHeader: keep, newline: nl) { try sink.write($0) }
                }
            }
        }
    }

    @objc func extractColumn(_ sender: Any?) {
        guard let window else { return }
        let column = columnPopup(includeWholeLine: false)
        guard column.numberOfItems > 0 else { statusBar.flash("Column tools need a CSV or TSV file. Choose CSV or TSV in the status bar."); return }
        let a = NSAlert()
        a.messageText = "Copy Column to New Document"
        a.accessoryView = form([[NSTextField(labelWithString: "Column:"), column]])
        a.addButton(withTitle: "Copy Column")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            let col = column.indexOfSelectedItem, sep = self.separator, nl = self.textDocument.newlineBytes
            self.toNewDocument("Extracting column", name: "\(self.textDocument.displayName) – \(column.titleOfSelectedItem ?? "column")") { snap, sink in
                try self.contiguous(snap) { buf in
                    try LineTools.extractColumn(buf, column: col, separator: sep, newline: nl) { try sink.write($0) }
                }
            }
        }
    }

    private func toNewDocument(_ label: String, name: String, _ produce: @escaping (TextSnapshot, FileSink) throws -> Void) {
        guard let out = try? textDocument.makeScratchURL("result.txt") else { return }
        let (range, isSelection) = scope
        let full = textDocument.snapshot()
        let snap = isSelection ? full.slice(range) : full
        let lang = textDocument.language
        runJob(label) { _, _ in
            let sink = try FileSink(url: out)
            try produce(snap, sink)
            try sink.close()
        } completion: { [weak self] error in
            guard let self, error == nil else { return }
            do { self.onOpenDocument?(try TextDocument(untitledName: name, contentsOf: out, language: lang)) }
            catch { if let w = self.window { self.showError(error, in: w) } }
        }
    }

    // MARK: Export / print

    /// Writes the selection to a file (for selections too big for the clipboard).
    @objc func exportSelection(_ sender: Any?) {
        guard let window else { return }
        let sel = textView.selection
        guard !sel.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Selection.\(textDocument.url?.pathExtension.isEmpty == false ? textDocument.url!.pathExtension : "txt")"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK, let url = panel.url else { return }
            let snap = self.textDocument.snapshot().slice(sel)
            let enc = self.textDocument.encoding
            self.runJob("Exporting") { progress, _ in
                try TextDocument.write(snap, to: url, encoding: TextEncoding(id: enc.id, name: enc.name), lineEnding: nil, progress: progress)
            }
        }
    }

    @objc func printDocument(_ sender: Any?) {
        let sel = textView.selection
        let limit = 8 << 20
        let range = sel.isEmpty ? 0..<min(textDocument.length, limit) : sel.lowerBound..<min(sel.upperBound, sel.lowerBound + limit)
        var text = String(decoding: textDocument.buffer.read(range), as: UTF8.self)
        let truncated = (sel.isEmpty ? textDocument.length : sel.count) > limit
        if truncated { text += "\n\n[Printing stops after the first 8 MB. Select a part of the file to print it.]\n" }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.font = Prefs.font(size: 9)
        tv.string = text
        tv.textContainer?.widthTracksTextView = true
        tv.isEditable = false
        tv.sizeToFit()
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.jobTitle = textDocument.displayName
        if let window { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }
}
