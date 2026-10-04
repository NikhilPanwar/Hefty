import AppKit
import BigFileCore

/// Developer aid for checking the UI without Screen Recording permission.
///
/// - `BFE_SNAPSHOT=/tmp/shot.png` renders the first window to a PNG, then quits.
/// - `BFE_FIND=text` opens the find bar and searches first.
/// - `BFE_ACTIONS="cmd;cmd;…"` runs editor commands first: `type:text`,
///   `key:moveWordRight:` (any key-binding selector), `do:selector:` (a menu
///   action), `goto:12:5`, `find:text`, `wait:seconds`.
/// - `BFE_DUMP=/tmp/out.txt` writes the document text and caret info after the actions.
/// - `BFE_ABOUT_SNAPSHOT=/tmp/about.png` renders the About window instead, then quits.
enum Snapshot {
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["BFE_ABOUT_SNAPSHOT"] {
            (NSApp.delegate as? AppDelegate)?.showAbout(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let frameView = NSApp.keyWindow?.contentView?.superview ?? NSApp.windows.first(where: { $0.windowController is AboutWindowController })?.contentView?.superview,
                   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
            return
        }
        guard let path = env["BFE_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let window = NSApp.windows.first(where: { $0.windowController is EditorWindowController }),
                  let c = window.windowController as? EditorWindowController else { return }
            var delay = 0.0
            if let term = env["BFE_FIND"], !term.isEmpty {
                c.showFind(nil)
                c.setFindTextForSnapshot(term)
                c.findNext(nil)
                delay = 1.5
            }
            let actions = (env["BFE_ACTIONS"] ?? "").split(separator: ";").map(String.init)
            run(actions, c, after: delay) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let dump = env["BFE_DUMP"] {
                        let doc = c.textDocument
                        let text = String(decoding: doc.buffer.read(0..<min(doc.length, 1 << 20)), as: UTF8.self)
                        let sels = c.panes[0].textView.allSelections.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
                        let info = "PANES=\(c.panes.map { $0.frame })\nFB=\(c.findBar.frame) RP=\(c.resultsPanel.frame) hidden=\(c.resultsPanel.isHidden) SB=\(c.statusBar.frame) CV=\(c.window!.contentView!.frame) amb=\(c.window!.contentView!.hasAmbiguousLayout)\nFRAMES split=\(c.split.frame) pane=\(c.panes[0].frame) tv=\(c.panes[0].textView.frame) status=\(c.findBar.statusLabel.frame) \(c.findBar.statusLabel.stringValue)\nSELECTIONS \(sels)\nMODIFIED \(doc.isModified)\nUNDO \(doc.buffer.undoName ?? "-")\n---\n"
                        try? (info + text).write(toFile: dump, atomically: true, encoding: .utf8)
                    }
                    guard let frameView = window.contentView?.superview else { return }
                    let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    if let doc = Optional(c.textDocument), doc.isModified { doc.buffer.markSaved() }   // don't prompt on quit
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func run(_ actions: [String], _ c: EditorWindowController, after delay: Double, done: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let a = actions.first else { done(); return }
            let rest = Array(actions.dropFirst())
            let tv = c.textView
            let parts = a.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            var wait = 0.05
            switch parts[0] {
            case "type": c.window?.makeFirstResponder(tv); tv.insertText(arg.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: NSRange(location: NSNotFound, length: 0))
            case "key": tv.doCommand(by: NSSelectorFromString(arg))
            case "do":
                // The app may not be active (no key window) when run from a script.
                let sel = NSSelectorFromString(arg)
                if !NSApp.sendAction(sel, to: nil, from: nil) {
                    for t in [tv, c, NSApp.delegate as AnyObject] as [AnyObject] where t.responds(to: sel) {
                        _ = t.perform(sel, with: nil); break
                    }
                }
            case "goto": c.go(to: arg)
            case "find": c.showFind(nil); c.setFindTextForSnapshot(arg); c.findNext(nil); wait = 1
            case "replace": c.showFindAndReplace(nil); c.findBar.replaceField.stringValue = arg
            case "wait": wait = Double(arg) ?? 1
            case "opt":
                let b = arg == "regex" ? c.findBar.regexButton : arg == "word" ? c.findBar.wordButton : c.findBar.caseButton
                b.state = b.state == .on ? .off : .on
                c.findOptionsChanged()
            default: break
            }
            run(rest, c, after: wait, done: done)
        }
    }
}
