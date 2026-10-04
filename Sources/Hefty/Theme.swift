import AppKit
import BigFileCore

/// A complete editor color scheme. `System` resolves to Light or Dark from the
/// window's appearance; the others force the window appearance to match.
struct Theme {
    let isDark: Bool
    let background: NSColor
    let text: NSColor
    let gutterBackground: NSColor
    let gutterText: NSColor
    let gutterCurrentText: NSColor
    let separator: NSColor
    let currentLine: NSColor
    let selection: NSColor
    let caret: NSColor
    let findHighlight: NSColor
    let findCurrent: NSColor
    let bracketMatch: NSColor
    let invisible: NSColor
    let bookmark: NSColor
    let keyword: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
    let punctuation: NSColor
    let key: NSColor
    let tag: NSColor
    let attribute: NSColor
    let error: NSColor
    let warning: NSColor
    let info: NSColor
    let columns: [NSColor]

    func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .plain: return text
        case .keyword: return keyword
        case .string: return string
        case .number: return number
        case .comment: return comment
        case .punctuation: return punctuation
        case .key: return key
        case .tag: return tag
        case .attribute: return attribute
        case .logError: return error
        case .logWarning: return warning
        case .logInfo: return info
        case .logDebug: return comment
        case .timestamp: return key
        case .column(let i): return columns[i % columns.count]
        }
    }

    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    // MARK: Palettes

    static let light = Theme(
        isDark: false,
        background: hex(0xFFFFFF), text: hex(0x1F1F24),
        gutterBackground: hex(0xF7F7F8), gutterText: hex(0xA6A6AD), gutterCurrentText: hex(0x3C3C43),
        separator: hex(0xE3E3E6), currentLine: hex(0xEDF3FD),
        selection: hex(0xB4D7FF), caret: hex(0x0A60FF), findHighlight: hex(0xFFE36E, 0.55),
        findCurrent: hex(0xFF9F0A, 0.75), bracketMatch: hex(0x34C759, 0.35), invisible: hex(0xC7C7CC),
        bookmark: hex(0x0A60FF),
        keyword: hex(0xAD3DA4), string: hex(0xC41A16), number: hex(0x1C00CF), comment: hex(0x707F8C),
        punctuation: hex(0x6C6C75), key: hex(0x0F68A0), tag: hex(0x0B4F79), attribute: hex(0x815F03),
        error: hex(0xD12F1B), warning: hex(0xB25E00), info: hex(0x1F7A3A),
        columns: [0x0F68A0, 0x3E8087, 0xAD3DA4, 0xC41A16, 0x1C00CF, 0x78492A, 0x326D74, 0x804FB8].map { hex($0) })

    static let dark = Theme(
        isDark: true,
        background: hex(0x1F1F24), text: hex(0xDFDFE0),
        gutterBackground: hex(0x1B1B1F), gutterText: hex(0x6C6C73), gutterCurrentText: hex(0xDFDFE0),
        separator: hex(0x2E2E35), currentLine: hex(0x26272E),
        selection: hex(0x3F5A82), caret: hex(0xFFFFFF), findHighlight: hex(0xB89B2A, 0.45),
        findCurrent: hex(0xFF9F0A, 0.7), bracketMatch: hex(0x30D158, 0.35), invisible: hex(0x4A4A52),
        bookmark: hex(0x409CFF),
        keyword: hex(0xFF7AB2), string: hex(0xFF8170), number: hex(0xD9C97C), comment: hex(0x7F8C98),
        punctuation: hex(0xA6A6AD), key: hex(0x6BDFFF), tag: hex(0x5DD8FF), attribute: hex(0xFFA14F),
        error: hex(0xFF6B5B), warning: hex(0xFFB340), info: hex(0x67D06F),
        columns: [0x6BDFFF, 0x78C2B3, 0xFF7AB2, 0xFF8170, 0xD9C97C, 0xB281EB, 0xFFA14F, 0xACF2E4].map { hex($0) })

    // Solarized accents (Ethan Schoonover).
    private static let sYellow = 0xB58900, sOrange = 0xCB4B16, sRed = 0xDC322F, sMagenta = 0xD33682,
                       sViolet = 0x6C71C4, sBlue = 0x268BD2, sCyan = 0x2AA198, sGreen = 0x859900
    private static let sColumns = [sBlue, sGreen, sMagenta, sCyan, sOrange, sViolet, sYellow, sRed].map { hex($0) }

    static let solarizedLight = Theme(
        isDark: false,
        background: hex(0xFDF6E3), text: hex(0x586E75),
        gutterBackground: hex(0xEEE8D5), gutterText: hex(0x93A1A1), gutterCurrentText: hex(0x586E75),
        separator: hex(0xE4DDC8), currentLine: hex(0xF5EEDA),
        selection: hex(0xE0D9BF), caret: hex(0x657B83), findHighlight: hex(sYellow, 0.3),
        findCurrent: hex(sOrange, 0.45), bracketMatch: hex(sGreen, 0.3), invisible: hex(0xD3CBB7),
        bookmark: hex(sBlue),
        keyword: hex(sGreen), string: hex(sCyan), number: hex(sMagenta), comment: hex(0x93A1A1),
        punctuation: hex(0x657B83), key: hex(sBlue), tag: hex(sOrange), attribute: hex(sYellow),
        error: hex(sRed), warning: hex(sOrange), info: hex(sGreen),
        columns: sColumns)

    static let solarizedDark = Theme(
        isDark: true,
        background: hex(0x002B36), text: hex(0x93A1A1),
        gutterBackground: hex(0x073642), gutterText: hex(0x586E75), gutterCurrentText: hex(0x93A1A1),
        separator: hex(0x0A3F4C), currentLine: hex(0x06323D),
        selection: hex(0x1A4B57), caret: hex(0x93A1A1), findHighlight: hex(sYellow, 0.35),
        findCurrent: hex(sOrange, 0.55), bracketMatch: hex(sGreen, 0.35), invisible: hex(0x1F4B57),
        bookmark: hex(sBlue),
        keyword: hex(sGreen), string: hex(sCyan), number: hex(sMagenta), comment: hex(0x586E75),
        punctuation: hex(0x839496), key: hex(sBlue), tag: hex(sOrange), attribute: hex(sYellow),
        error: hex(sRed), warning: hex(sOrange), info: hex(sGreen),
        columns: sColumns)

    private static func hex(_ v: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
}

enum ThemeChoice: String, CaseIterable {
    case system, light, dark, solarizedLight, solarizedDark

    var title: String {
        switch self {
        case .system: return "System (Light / Dark)"
        case .light: return "Light"
        case .dark: return "Dark"
        case .solarizedLight: return "Solarized Light"
        case .solarizedDark: return "Solarized Dark"
        }
    }

    /// nil means "follow macOS".
    var fixedTheme: Theme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        case .solarizedLight: return .solarizedLight
        case .solarizedDark: return .solarizedDark
        }
    }

    func resolved(for appearance: NSAppearance) -> Theme {
        if let t = fixedTheme { return t }
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

/// App-wide preferences, persisted in UserDefaults. Every change posts
/// `Prefs.didChange` so all open windows update together.
enum Prefs {
    static let didChange = Notification.Name("HeftyPrefsDidChange")
    private static let d = UserDefaults.standard

    private static func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }
    private static func int(_ key: String, _ def: Int) -> Int { d.object(forKey: key) as? Int ?? def }

    static var theme: ThemeChoice = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system {
        didSet { d.set(theme.rawValue, forKey: "theme"); post() }
    }
    static var fontName: String = d.string(forKey: "fontName") ?? "" {   // "" = system monospaced
        didSet { d.set(fontName, forKey: "fontName"); post() }
    }
    static var fontSize: CGFloat = d.object(forKey: "fontSize") as? CGFloat ?? 13 {
        didSet { d.set(fontSize, forKey: "fontSize"); post() }
    }
    static var lineSpacing: CGFloat = d.object(forKey: "lineSpacing") as? CGFloat ?? 1.25 {
        didSet { d.set(lineSpacing, forKey: "lineSpacing"); post() }
    }
    static var wordWrap: Bool = bool("wordWrap", false) { didSet { d.set(wordWrap, forKey: "wordWrap"); post() } }
    static var showLineNumbers: Bool = bool("showLineNumbers", true) { didSet { d.set(showLineNumbers, forKey: "showLineNumbers"); post() } }
    static var highlightCurrentLine: Bool = bool("highlightCurrentLine", true) { didSet { d.set(highlightCurrentLine, forKey: "highlightCurrentLine"); post() } }
    static var showStatusBar: Bool = bool("showStatusBar", true) { didSet { d.set(showStatusBar, forKey: "showStatusBar"); post() } }
    static var showInvisibles: Bool = bool("showInvisibles", false) { didSet { d.set(showInvisibles, forKey: "showInvisibles"); post() } }
    static var tabWidth: Int = int("tabWidth", 4) { didSet { d.set(tabWidth, forKey: "tabWidth"); post() } }
    static var indentWithSpaces: Bool = bool("indentWithSpaces", true) { didSet { d.set(indentWithSpaces, forKey: "indentWithSpaces"); post() } }
    static var autoIndent: Bool = bool("autoIndent", true) { didSet { d.set(autoIndent, forKey: "autoIndent"); post() } }
    static var autoCloseBrackets: Bool = bool("autoCloseBrackets", false) { didSet { d.set(autoCloseBrackets, forKey: "autoCloseBrackets"); post() } }
    static var matchBrackets: Bool = bool("matchBrackets", true) { didSet { d.set(matchBrackets, forKey: "matchBrackets"); post() } }
    static var blinkCaret: Bool = bool("blinkCaret", true) { didSet { d.set(blinkCaret, forKey: "blinkCaret"); post() } }
    static var alignCSVColumns: Bool = bool("alignCSVColumns", true) { didSet { d.set(alignCSVColumns, forKey: "alignCSVColumns"); post() } }
    static var followTail: Bool = bool("followTail", true) { didSet { d.set(followTail, forKey: "followTail"); post() } }
    static var autoReload: Bool = bool("autoReload", true) { didSet { d.set(autoReload, forKey: "autoReload"); post() } }
    static var fallbackEncoding: String = d.string(forKey: "fallbackEncoding") ?? TextEncoding.windows1252.displayName {
        didSet { d.set(fallbackEncoding, forKey: "fallbackEncoding"); post() }
    }
    static var defaultLineEnding: LineEnding = LineEnding(rawValue: d.string(forKey: "defaultLineEnding") ?? "") ?? .lf {
        didSet { d.set(defaultLineEnding.rawValue, forKey: "defaultLineEnding"); post() }
    }

    static let defaultFontSize: CGFloat = 13
    static let fontSizes: ClosedRange<CGFloat> = 8...48

    static var fallbackTextEncoding: TextEncoding { TextEncoding.named(fallbackEncoding) ?? .windows1252 }

    /// The editor font (falls back to the system monospaced font).
    static func font(size: CGFloat? = nil) -> NSFont {
        let s = size ?? fontSize
        if !fontName.isEmpty, let f = NSFont(name: fontName, size: s) { return f }
        return NSFont.monospacedSystemFont(ofSize: s, weight: .regular)
    }

    /// Per-file syntax choice, remembered across launches.
    static func language(for url: URL) -> Language? {
        (d.dictionary(forKey: "languages")?[url.path] as? String).flatMap(Language.init(rawValue:))
    }
    static func setLanguage(_ l: Language?, for url: URL) {
        var dict = d.dictionary(forKey: "languages") ?? [:]
        dict[url.path] = l?.rawValue
        if dict.count > 300 { dict.removeValue(forKey: dict.keys.first!) }
        d.set(dict, forKey: "languages")
    }

    static func post() { NotificationCenter.default.post(name: didChange, object: nil) }
}
