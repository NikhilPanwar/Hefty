import AppKit

// Plain AppKit bootstrap (no storyboard / NSDocument): NSDocument would read
// the whole file into memory, which is exactly what this app must avoid.
Migration.run()
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
