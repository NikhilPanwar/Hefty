import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Line-ending style of a document.
public enum LineEnding: String, CaseIterable, Sendable {
    case lf, crlf, cr

    public var bytes: [UInt8] {
        switch self {
        case .lf: return [0x0A]
        case .crlf: return [0x0D, 0x0A]
        case .cr: return [0x0D]
        }
    }
    public var shortName: String {
        switch self { case .lf: return "LF"; case .crlf: return "CRLF"; case .cr: return "CR" }
    }
    public var displayName: String {
        switch self {
        case .lf: return "LF (macOS / Unix)"
        case .crlf: return "CRLF (Windows)"
        case .cr: return "CR (Classic Mac)"
        }
    }
}

/// A text encoding the editor can read and write. Internally the editor always
/// works in UTF-8; other encodings are converted when opening and saving.
public struct TextEncoding: Hashable, Sendable {
    /// iconv name.
    public let id: String
    public let name: String
    public var bom: [UInt8]

    public init(id: String, name: String, bom: [UInt8] = []) {
        self.id = id; self.name = name; self.bom = bom
    }

    public var isUTF8: Bool { id == "UTF-8" }
    public var displayName: String {
        if isUTF8 { return bom.isEmpty ? "UTF-8" : "UTF-8 with BOM" }
        if id.hasPrefix("UTF-16") || id.hasPrefix("UTF-32") { return bom.isEmpty ? "\(name) (no BOM)" : name }
        return name
    }

    public static let utf8 = TextEncoding(id: "UTF-8", name: "UTF-8")
    public static let utf8BOM = TextEncoding(id: "UTF-8", name: "UTF-8", bom: [0xEF, 0xBB, 0xBF])
    public static let utf16LE = TextEncoding(id: "UTF-16LE", name: "UTF-16 LE", bom: [0xFF, 0xFE])
    public static let utf16BE = TextEncoding(id: "UTF-16BE", name: "UTF-16 BE", bom: [0xFE, 0xFF])
    public static let utf32LE = TextEncoding(id: "UTF-32LE", name: "UTF-32 LE", bom: [0xFF, 0xFE, 0x00, 0x00])
    public static let windows1252 = TextEncoding(id: "WINDOWS-1252", name: "Western (Windows 1252)")
    public static let latin1 = TextEncoding(id: "ISO-8859-1", name: "Western (ISO Latin 1)")

    /// Encodings offered in the menus, in display order.
    public static let all: [TextEncoding] = [
        .utf8, .utf8BOM, .utf16LE, .utf16BE,
        TextEncoding(id: "UTF-16LE", name: "UTF-16 LE"), TextEncoding(id: "UTF-16BE", name: "UTF-16 BE"),
        .utf32LE,
        .windows1252, .latin1,
        TextEncoding(id: "ISO-8859-15", name: "Western (ISO Latin 9)"),
        TextEncoding(id: "MACINTOSH", name: "Western (Mac OS Roman)"),
        TextEncoding(id: "WINDOWS-1250", name: "Central European (Windows 1250)"),
        TextEncoding(id: "ISO-8859-2", name: "Central European (ISO Latin 2)"),
        TextEncoding(id: "WINDOWS-1251", name: "Cyrillic (Windows 1251)"),
        TextEncoding(id: "KOI8-R", name: "Cyrillic (KOI8-R)"),
        TextEncoding(id: "WINDOWS-1253", name: "Greek (Windows 1253)"),
        TextEncoding(id: "WINDOWS-1254", name: "Turkish (Windows 1254)"),
        TextEncoding(id: "WINDOWS-1255", name: "Hebrew (Windows 1255)"),
        TextEncoding(id: "WINDOWS-1256", name: "Arabic (Windows 1256)"),
        TextEncoding(id: "WINDOWS-874", name: "Thai (Windows 874)"),
        TextEncoding(id: "SHIFT_JIS", name: "Japanese (Shift JIS)"),
        TextEncoding(id: "EUC-JP", name: "Japanese (EUC)"),
        TextEncoding(id: "GB18030", name: "Chinese Simplified (GB 18030)"),
        TextEncoding(id: "BIG5", name: "Chinese Traditional (Big 5)"),
        TextEncoding(id: "EUC-KR", name: "Korean (EUC)"),
    ]

    public static func named(_ s: String) -> TextEncoding? {
        all.first { $0.displayName == s || ($0.id == s && $0.bom.isEmpty) }
    }
}

public enum EncodingError: Error, CustomStringConvertible {
    case unsupported(String)
    case unrepresentable(String, at: Int)
    case invalidInput(String)

    public var description: String {
        switch self {
        case .unsupported(let e): return "The encoding \(e) is not supported on this Mac."
        case let .unrepresentable(e, at):
            return "The document contains characters that can't be saved as \(e) (first one near byte \(at)). Choose another encoding, such as UTF-8."
        case .invalidInput(let e): return "The file is not valid \(e)."
        }
    }
}

/// What the editor guessed about a file when opening it.
public struct Detection: Sendable {
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    public var mixedLineEndings: Bool
}

public enum EncodingDetector {
    /// Guesses the encoding from the BOM and the first megabyte, falling back
    /// to `fallback` for 8-bit text that isn't valid UTF-8.
    public static func detect(_ file: MappedFile, fallback: TextEncoding = .windows1252) -> TextEncoding {
        let head = file.bytes(0..<min(file.size, 1 << 20))
        let b = Array(head.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return .utf8BOM }
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xFE, b[2] == 0, b[3] == 0 { return .utf32LE }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return .utf16LE }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return .utf16BE }

        // UTF-16 without a BOM: lots of zero bytes on one side of each pair.
        let probe = head.prefix(8192)
        if probe.count >= 64 {
            var evenZero = 0, oddZero = 0
            for (i, x) in probe.enumerated() where x == 0 { if i % 2 == 0 { evenZero += 1 } else { oddZero += 1 } }
            let pairs = probe.count / 2
            if oddZero > pairs * 3 / 10 && evenZero < pairs / 20 { return TextEncoding(id: "UTF-16LE", name: "UTF-16 LE") }
            if evenZero > pairs * 3 / 10 && oddZero < pairs / 20 { return TextEncoding(id: "UTF-16BE", name: "UTF-16 BE") }
        }
        if isValidUTF8(head, allowTruncatedEnd: head.count < file.size) {
            // Also check a sample from the middle and the end of big files.
            for at in [file.size / 2, max(0, file.size - 65536)] where at > head.count {
                let s = file.bytes(at..<min(file.size, at + 65536))
                if !isValidUTF8(s, skipLeadingContinuation: true, allowTruncatedEnd: at + s.count < file.size) {
                    return fallback
                }
            }
            return .utf8
        }
        return fallback
    }

    /// Detects the dominant line ending in the first megabyte of UTF-8 text.
    public static func lineEnding(in buf: UnsafeRawBufferPointer) -> (LineEnding, mixed: Bool) {
        var lf = 0, crlf = 0, cr = 0
        let n = buf.count
        var i = 0
        while i < n {
            let x = buf[i]
            if x == 0x0D {
                if i + 1 < n && buf[i + 1] == 0x0A { crlf += 1; i += 2; continue }
                if i + 1 < n { cr += 1 }
            } else if x == 0x0A { lf += 1 }
            i += 1
        }
        let kinds = [lf, crlf, cr].filter { $0 > 0 }.count
        let style: LineEnding = crlf > lf && crlf >= cr ? .crlf : (cr > lf ? .cr : .lf)
        return (style, kinds > 1)
    }

    public static func isValidUTF8(_ buf: UnsafeRawBufferPointer, skipLeadingContinuation: Bool = false,
                                   allowTruncatedEnd: Bool = false) -> Bool {
        let n = buf.count
        var i = 0
        if skipLeadingContinuation { while i < n && i < 3 && buf[i] & 0xC0 == 0x80 { i += 1 } }
        while i < n {
            let c = buf[i]
            if c < 0x80 { i += 1; continue }
            let len: Int
            if c & 0xE0 == 0xC0 && c >= 0xC2 { len = 2 }
            else if c & 0xF0 == 0xE0 { len = 3 }
            else if c & 0xF8 == 0xF0 && c <= 0xF4 { len = 4 }
            else { return false }
            if i + len > n { return allowTruncatedEnd }
            for k in 1..<len where buf[i + k] & 0xC0 != 0x80 { return false }
            i += len
        }
        return true
    }
}

/// Streaming iconv wrapper. Feed chunks with `convert`; incomplete multi-byte
/// sequences at a chunk end are carried over to the next call.
public final class Transcoder {
    private let cd: iconv_t
    private let from: String, to: String
    private var pending: [UInt8] = []
    private var out = [UInt8](repeating: 0, count: 1 << 20)
    /// When decoding to UTF-8, invalid input becomes U+FFFD instead of failing.
    private let substitute: Bool
    private var consumed = 0

    public init(from: String, to: String, substituteInvalid: Bool) throws {
        let h = iconv_open(to, from)
        guard let h, Int(bitPattern: h) != -1 else { throw EncodingError.unsupported(from == "UTF-8" ? to : from) }
        cd = h
        self.from = from; self.to = to
        substitute = substituteInvalid
    }
    deinit { iconv_close(cd) }

    public func convert(_ input: UnsafeRawBufferPointer, final: Bool,
                        _ emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        if pending.isEmpty {
            try run(input, final: final, emit)
        } else {
            var joined = pending
            joined.append(contentsOf: input)
            pending.removeAll()
            try joined.withUnsafeBytes { try run($0, final: final, emit) }
        }
    }

    private func run(_ input: UnsafeRawBufferPointer, final: Bool,
                     _ emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard let base = input.baseAddress else {
            if final { try flush(emit) }
            return
        }
        var inPtr = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: CChar.self))
        var inLeft = input.count
        while inLeft > 0 {
            let r: Int = try out.withUnsafeMutableBytes { ob in
                var outPtr: UnsafeMutablePointer<CChar>? = ob.baseAddress!.assumingMemoryBound(to: CChar.self)
                var outLeft = ob.count
                var ip: UnsafeMutablePointer<CChar>? = inPtr
                let r = iconv(cd, &ip, &inLeft, &outPtr, &outLeft)
                let err = r == -1 ? Int(errno) : 0
                let produced = ob.count - outLeft
                inPtr = ip!
                if produced > 0 { try emit(UnsafeRawBufferPointer(rebasing: ob[0..<produced])) }
                return err
            }
            if r == 0 { continue }
            switch Int32(r) {
            case E2BIG: continue
            case EINVAL:   // incomplete sequence at the end of this chunk
                if final {
                    if substitute { try emitReplacement(emit); inLeft = 0 }
                    else { throw EncodingError.invalidInput(from) }
                } else {
                    pending = Array(UnsafeRawBufferPointer(start: inPtr, count: inLeft))
                    inLeft = 0
                }
            case EILSEQ:
                let at = consumed + (input.count - inLeft)
                if substitute {
                    try emitReplacement(emit)
                    inPtr += 1; inLeft -= 1
                } else {
                    throw from == "UTF-8" ? EncodingError.unrepresentable(to, at: at) : EncodingError.invalidInput(from)
                }
            default:
                throw EncodingError.invalidInput(from)
            }
        }
        consumed += input.count
        if final { try flush(emit) }
    }

    private func emitReplacement(_ emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        let r: [UInt8] = to == "UTF-8" ? [0xEF, 0xBF, 0xBD] : [0x3F]
        try r.withUnsafeBytes { try emit($0) }
    }

    private func flush(_ emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        try out.withUnsafeMutableBytes { ob in
            var outPtr: UnsafeMutablePointer<CChar>? = ob.baseAddress!.assumingMemoryBound(to: CChar.self)
            var outLeft = ob.count
            _ = iconv(cd, nil, nil, &outPtr, &outLeft)
            let produced = ob.count - outLeft
            if produced > 0 { try emit(UnsafeRawBufferPointer(rebasing: ob[0..<produced])) }
        }
    }
}

/// Streaming line-ending normalizer: every CRLF, CR or LF becomes `target`.
public struct LineEndingConverter {
    public let target: LineEnding
    private var heldCR = false
    private var out: [UInt8] = []

    public init(target: LineEnding) { self.target = target }

    public mutating func convert(_ input: UnsafeRawBufferPointer, final: Bool,
                                 _ emit: (UnsafeRawBufferPointer) throws -> Void) rethrows {
        out.removeAll(keepingCapacity: true)
        out.reserveCapacity(input.count + input.count / 8 + 2)
        let t = target.bytes
        if heldCR {
            heldCR = false
            if let f = input.first, f == 0x0A {
                out.append(contentsOf: t)
                process(UnsafeRawBufferPointer(rebasing: input.dropFirst()), t)
            } else {
                out.append(contentsOf: t)
                process(input, t)
            }
        } else {
            process(input, t)
        }
        if final && heldCR { out.append(contentsOf: t); heldCR = false }
        if !out.isEmpty { try out.withUnsafeBytes { try emit($0) } }
    }

    private mutating func process(_ input: UnsafeRawBufferPointer, _ t: [UInt8]) {
        guard let base = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let n = input.count
        var i = 0, runStart = 0
        while i < n {
            let x = base[i]
            if x == 0x0A || x == 0x0D {
                if i > runStart { out.append(contentsOf: UnsafeBufferPointer(start: base + runStart, count: i - runStart)) }
                if x == 0x0D {
                    if i + 1 < n {
                        if base[i + 1] == 0x0A { i += 1 }
                        out.append(contentsOf: t)
                    } else {
                        heldCR = true
                    }
                } else {
                    out.append(contentsOf: t)
                }
                runStart = i + 1
            }
            i += 1
        }
        if n > runStart { out.append(contentsOf: UnsafeBufferPointer(start: base + runStart, count: n - runStart)) }
    }
}
