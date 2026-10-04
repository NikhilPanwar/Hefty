import Foundation
import BigFileCore

/// One-time carry-over from the app's pre-1.0 name (BigFileEditor): settings,
/// recent files, window frames and any unsaved-work recovery journals.
/// Runs before anything reads `Prefs`.
enum Migration {
    static let oldDomain = "app.bigfileeditor.BigFileEditor"

    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromBigFileEditor") else { return }
        defer { d.set(true, forKey: "migratedFromBigFileEditor") }
        if let old = UserDefaults(suiteName: oldDomain)?.persistentDomain(forName: oldDomain) {
            for (key, value) in old where d.object(forKey: key) == nil { d.set(value, forKey: key) }
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldRecovery = support.appendingPathComponent("BigFileEditor/Recovery", isDirectory: true)
        let newRecovery = Recovery.directory
        if fm.fileExists(atPath: oldRecovery.path), !fm.fileExists(atPath: newRecovery.path) {
            try? fm.createDirectory(at: newRecovery.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: oldRecovery, to: newRecovery)
        }
    }
}
