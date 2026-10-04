import AppKit

/// Product identity shown in the About window. Fill in the links when the
/// website and repository exist; a nil link shows as "coming soon".
enum Brand {
    static let name = "Hefty"
    static let tagline = "The text editor for files too big for everything else."
    static let website: URL? = nil      // e.g. https://<your-domain>
    static let repository: URL? = nil   // e.g. https://github.com/<you>/hefty
    static let issues: URL? = nil       // e.g. https://github.com/<you>/hefty/issues
    static let amber = NSColor(srgbRed: 1.0, green: 0.651, blue: 0.239, alpha: 1)    // #FFA63D
    static let ink = NSColor(srgbRed: 0.055, green: 0.102, blue: 0.169, alpha: 1)   // #0E1A2B

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© 2026 Nok"
    }

    static func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = f.fontDescriptor.withDesign(.rounded) else { return f }
        return NSFont(descriptor: d, size: size) ?? f
    }
}

final class AboutWindowController: NSWindowController {
    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.title = "About \(Brand.name)"
        self.init(window: w)
        w.contentView = makeContent()
        w.center()
    }

    private func label(_ s: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = font
        l.textColor = color
        l.alignment = .center
        l.isSelectable = true
        return l
    }

    private func linkButton(_ title: String, _ url: URL?) -> NSButton {
        let b = NSButton(title: url == nil ? "\(title) (coming soon)" : title, target: self, action: #selector(openLink(_:)))
        b.bezelStyle = .inline
        b.isEnabled = url != nil
        b.toolTip = url?.absoluteString ?? "Link not set yet"
        b.identifier = NSUserInterfaceItemIdentifier(url?.absoluteString ?? "")
        return b
    }

    @objc private func openLink(_ sender: NSButton) {
        if let s = sender.identifier?.rawValue, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    private func makeContent() -> NSView {
        let root = NSVisualEffectView()
        root.material = .windowBackground
        root.blendingMode = .behindWindow
        root.state = .active

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 128).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 128).isActive = true

        let name = label(Brand.name, Brand.roundedFont(30, .heavy))
        let tagline = label(Brand.tagline, .systemFont(ofSize: 13), .secondaryLabelColor)
        let version = label("Version \(Brand.version) (build \(Brand.build))", .monospacedDigitSystemFont(ofSize: 12, weight: .medium), .secondaryLabelColor)
        let accent = NSBox()
        accent.boxType = .custom
        accent.fillColor = Brand.amber
        accent.borderWidth = 0
        accent.cornerRadius = 2
        accent.translatesAutoresizingMaskIntoConstraints = false
        accent.widthAnchor.constraint(equalToConstant: 36).isActive = true
        accent.heightAnchor.constraint(equalToConstant: 4).isActive = true

        let credits = label("Opens 5–100+ GB SQL dumps, CSV, JSON and logs in a blink.\nDesigned and built by Nok, with Claude.",
                            .systemFont(ofSize: 11), .secondaryLabelColor)
        let links = NSStackView(views: [linkButton("Website", Brand.website),
                                        linkButton("Source", Brand.repository),
                                        linkButton("Report an Issue", Brand.issues)])
        links.orientation = .horizontal
        links.spacing = 6
        let copyright = label(Brand.copyright, .systemFont(ofSize: 10), .tertiaryLabelColor)

        let stack = NSStackView(views: [icon, name, tagline, version, accent, credits, links, copyright])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(4, after: icon)
        stack.setCustomSpacing(2, after: name)
        stack.setCustomSpacing(14, after: version)
        stack.setCustomSpacing(14, after: accent)
        stack.setCustomSpacing(16, after: credits)
        stack.setCustomSpacing(14, after: links)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            tagline.widthAnchor.constraint(equalTo: stack.widthAnchor),
            credits.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return root
    }
}
