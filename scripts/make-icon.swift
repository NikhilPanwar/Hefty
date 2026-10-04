// Draws Hefty's brand art with CoreGraphics, so it is reproducible from source.
//   swift scripts/make-icon.swift iconset Out.iconset    all macOS icon sizes (16–1024)
//   swift scripts/make-icon.swift png 1024 icon.png      one icon PNG
//   swift scripts/make-icon.swift dmg bg.png bg@2x.png   DMG window background (660x420)
import AppKit

func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

// Brand palette (keep in sync with assets/brand/brand.html).
let ink = 0x0E1A2B, midnight = 0x1E2F4D, amber = 0xFFA63D, ember = 0xEE6A12, cream = 0xFFF4E2

func bitmap(_ w: Int, _ h: Int, _ body: (CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    body(CGFloat(w))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The kettlebell mark: an amber kettlebell whose face is a page of text.
/// Drawn in a 1024-unit box scaled to `rect`. `detail` drops the text lines at tiny sizes.
func drawMark(in rect: NSRect, lines: Int) {
    let k = rect.width / 1024
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(origin: p(x, y), size: NSSize(width: w * k, height: h * k))
    }
    // Handle: a thick rounded loop sitting on top of the bell.
    let loop = r(250, 430, 524, 330)
    let handle = NSBezierPath(roundedRect: loop, xRadius: 230 * k, yRadius: 165 * k)
    handle.lineWidth = 92 * k
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = hex(0x000000, 0.35); sh.shadowBlurRadius = 18 * k
    sh.shadowOffset = NSSize(width: 0, height: -8 * k); sh.set()
    hex(0xE58A22).setStroke(); handle.stroke()
    NSGraphicsContext.restoreGraphicsState()
    // Light rim on the handle.
    let rim = NSBezierPath(roundedRect: loop.insetBy(dx: -24 * k, dy: -24 * k),
                           xRadius: 254 * k, yRadius: 189 * k)
    rim.lineWidth = 14 * k
    hex(0xFFD08A, 0.55).setStroke(); rim.stroke()

    // Bell: a circle with a flat base.
    let center = p(512, 380), radius = 300 * k
    let bell = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: r(0, 118, 1024, 900)).addClip()
    let shadow = NSShadow(); shadow.shadowColor = hex(0x000000, 0.45); shadow.shadowBlurRadius = 34 * k
    shadow.shadowOffset = NSSize(width: 0, height: -14 * k); shadow.set()
    NSGradient(starting: hex(amber), ending: hex(ember))!.draw(in: bell, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Base plate.
    NSGraphicsContext.saveGraphicsState()
    bell.addClip()
    hex(0xC9550B).setFill(); r(0, 118, 1024, 52).fill()
    // Soft highlight, upper left.
    NSGradient(colors: [hex(0xFFFFFF, 0.38), hex(0xFFFFFF, 0)])!
        .draw(fromCenter: p(400, 540), radius: 0, toCenter: p(400, 540), radius: 260 * k, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Face: lines of text, like a page of a huge file.
    guard lines > 0 else { return }
    let all: [(CGFloat, CGFloat, Int)] = [(0, 250, ink), (40, 190, ink), (40, 300, ink), (0, 140, ink),
                                         (40, 230, ink), (0, 270, ink)]
    let n = min(lines, all.count)
    let lineH: CGFloat = lines <= 3 ? 46 : 30, gap: CGFloat = lines <= 3 ? 82 : 58
    let top: CGFloat = 372 + CGFloat(n - 1) * gap / 2
    for i in 0..<n {
        let (indent, w, c) = all[i]
        let y = top - CGFloat(i) * gap - lineH / 2
        let x: CGFloat = 512 - 170 + indent
        hex(c, 0.82).setFill()
        NSBezierPath(roundedRect: r(x, y, lines <= 3 ? w * 1.1 : w, lineH), xRadius: lineH / 2 * k, yRadius: lineH / 2 * k).fill()
    }
    // Caret.
    if lines > 3 {
        hex(cream).setFill()
        let y = top - CGFloat(n - 1) * gap - lineH / 2 - 12
        r(512 - 170 + 270 + 22, y, 14, lineH + 24).fill()
    }
}

/// Full app icon: macOS rounded tile (824 of 1024, Big Sur grid) with the mark.
func drawIcon(_ px: Int) -> Data {
    bitmap(px, px) { s in
        let k = s / 1024
        let tile = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
        let path = NSBezierPath(roundedRect: tile, xRadius: 185 * k, yRadius: 185 * k)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = hex(0x000000, 0.30); sh.shadowBlurRadius = 20 * k
        sh.shadowOffset = NSSize(width: 0, height: -10 * k); sh.set()
        hex(ink).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: hex(0x2A3F63), ending: hex(ink))!.draw(in: path, angle: -90)
        // Faint text-line texture in the background.
        if px >= 128 {
            hex(0xFFFFFF, 0.05).setFill()
            for i in 0..<12 {
                let y = tile.maxY - CGFloat(70 + i * 62) * k
                let w = CGFloat([520, 380, 610, 300, 460, 560, 340, 500, 420, 600, 360, 480][i]) * k
                NSBezierPath(roundedRect: NSRect(x: tile.minX + 60 * k, y: y, width: w, height: 18 * k),
                             xRadius: 9 * k, yRadius: 9 * k).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        // Inner top highlight.
        let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 2 * k, dy: 2 * k), xRadius: 183 * k, yRadius: 183 * k)
        edge.lineWidth = max(1, 3 * k)
        hex(0xFFFFFF, 0.10).setStroke(); edge.stroke()
        let markRect = tile.insetBy(dx: 70 * k, dy: 70 * k).offsetBy(dx: 0, dy: -6 * k)
        drawMark(in: markRect, lines: px <= 32 ? 0 : px <= 64 ? 3 : 6)
    }
}

/// DMG background: cream card, wordmark, and an arrow from the app to Applications.
/// Finder icon centres are at (170, 230) and (490, 230) in a 660x420 window.
func drawDMG(scale: Int) -> Data {
    bitmap(660 * scale, 420 * scale) { w in
        let k = w / 660
        hex(cream).setFill(); NSRect(x: 0, y: 0, width: w, height: 420 * k).fill()
        NSGradient(starting: hex(0xFFFFFF, 0), ending: hex(0xFFFFFF, 0.65))!
            .draw(in: NSRect(x: 0, y: 0, width: w, height: 420 * k), angle: 90)
        func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, y: CGFloat, rounded: Bool = false) {
            var font = NSFont.systemFont(ofSize: size * k, weight: weight)
            if rounded, let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: size * k)! }
            let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            a.draw(at: NSPoint(x: (w - a.size().width) / 2, y: y * k))
        }
        // Wordmark with small mark.
        let title = "Hefty"
        var tf = NSFont.systemFont(ofSize: 34 * k, weight: .heavy)
        if let d = tf.fontDescriptor.withDesign(.rounded) { tf = NSFont(descriptor: d, size: 34 * k)! }
        let t = NSAttributedString(string: title, attributes: [.font: tf, .foregroundColor: hex(ink)])
        let markW = 44 * k, total = markW + 10 * k + t.size().width
        let x0 = (w - total) / 2
        drawMark(in: NSRect(x: x0, y: 342 * k, width: markW, height: markW), lines: 3)
        t.draw(at: NSPoint(x: x0 + markW + 10 * k, y: 344 * k))
        text("Drag Hefty to Applications to install", 14, .medium, hex(0x4A5873), y: 316)
        // Arrow between the two icon slots (window y 230 -> image y 190).
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 262 * k, y: 196 * k))
        arrow.curve(to: NSPoint(x: 392 * k, y: 196 * k), controlPoint1: NSPoint(x: 300 * k, y: 222 * k),
                    controlPoint2: NSPoint(x: 354 * k, y: 222 * k))
        arrow.lineWidth = 5 * k; arrow.lineCapStyle = .round
        hex(amber).setStroke(); arrow.stroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 376 * k, y: 216 * k))
        head.line(to: NSPoint(x: 396 * k, y: 194 * k))
        head.line(to: NSPoint(x: 368 * k, y: 186 * k))
        head.lineWidth = 5 * k; head.lineCapStyle = .round; head.lineJoinStyle = .round
        head.stroke()
        // First-launch hint.
        hex(0xFFFFFF, 0.7).setFill()
        let pill = NSRect(x: 110 * k, y: 26 * k, width: 440 * k, height: 50 * k)
        NSBezierPath(roundedRect: pill, xRadius: 12 * k, yRadius: 12 * k).fill()
        text("First launch: right-click Hefty in Applications and choose Open.", 12, .semibold, hex(ink), y: 52)
        text("Not notarized by Apple, so macOS asks once. Then it opens normally.", 11, .regular, hex(0x6B7891), y: 34)
    }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "iconset":
    let out = URL(fileURLWithPath: args[2])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try drawIcon(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
        try drawIcon(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
case "png":
    try drawIcon(Int(args[2])!).write(to: URL(fileURLWithPath: args[3]))
case "dmg":
    try drawDMG(scale: 1).write(to: URL(fileURLWithPath: args[2]))
    try drawDMG(scale: 2).write(to: URL(fileURLWithPath: args[3]))
default:
    print("usage: make-icon.swift iconset DIR | png SIZE FILE | dmg 1x.png 2x.png"); exit(1)
}
