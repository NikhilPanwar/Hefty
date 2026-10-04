import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Sparse line index over the *original* file.
///
/// Stores the byte offset of every `stride`-th line instead of every line, so
/// a 100 GB file with ~1 billion lines needs ~1M checkpoints (8 MB) rather than
/// 8 GB. Any exact line is found by jumping to the nearest checkpoint and
/// scanning at most `stride` lines with memchr (microseconds).
///
/// Built on a background thread in large sequential chunks; it is queryable
/// while building (for the part already scanned), so the file is usable the
/// instant it opens.
public final class LineIndex: @unchecked Sendable {
    public static let stride = 1024

    private let file: MappedFile
    private let lock = NSLock()
    private var checkpoints: [Int] = [0]   // checkpoints[k] = offset of line k*stride
    private var _indexedBytes = 0
    private var _newlines = 0
    private var _cancelled = false

    private var resumeOffset = 0

    public init(file: MappedFile) { self.file = file }

    /// An index for `file` that reuses `previous` for the bytes both files
    /// share at the start (a log that grew), so only the new tail is scanned.
    public init(file: MappedFile, continuing previous: LineIndex) {
        self.file = file
        previous.lock.sync {
            // Resume at the last checkpoint so a line split across the old
            // end is counted correctly.
            let keep = previous.checkpoints.filter { $0 <= min(previous._indexedBytes, file.size) }
            checkpoints = keep.isEmpty ? [0] : keep
            resumeOffset = checkpoints.last!
            _newlines = (checkpoints.count - 1) * LineIndex.stride
            _indexedBytes = resumeOffset
        }
    }

    public var indexedBytes: Int { lock.sync { _indexedBytes } }
    public var isComplete: Bool { lock.sync { _indexedBytes >= file.size } }
    public var fileSize: Int { file.size }
    public var progress: Double { file.size == 0 ? 1 : Double(indexedBytes) / Double(file.size) }
    /// Total line count once complete (a trailing line without "\n" counts).
    public var lineCount: Int? {
        lock.sync {
            guard _indexedBytes >= file.size else { return nil }
            let lastByteIsNewline = file.size > 0 && file.bytes(file.size - 1..<file.size)[0] == 0x0A
            return _newlines + (file.size == 0 || lastByteIsNewline ? 0 : 1)
        }
    }

    public func cancel() { lock.sync { _cancelled = true } }

    /// Blocking; call from a background queue. `onProgress` is throttled to
    /// once per chunk.
    public func build(chunkSize: Int = 64 << 20, onProgress: ((Double) -> Void)? = nil) {
        file.advise(sequential: true)
        defer { file.advise(sequential: false) }
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 64)
        defer { scratch.deallocate() }
        var offset = resumeOffset
        var newlines = lock.sync { _newlines }
        var pending: [Int] = []
        while offset < file.size {
            if lock.sync({ _cancelled }) { return }
            let end = min(file.size, offset + chunkSize)
            // pread into a reused buffer: scanning 100 GB this way doesn't
            // inflate the app's resident memory the way touching the map would.
            let n = file.pread(into: scratch, count: end - offset, at: offset)
            guard n == end - offset else { break }
            let buf = UnsafeRawBufferPointer(start: scratch, count: n)
            guard let base = buf.baseAddress else { break }
            var p = base
            let stop = base + buf.count
            while p < stop {
                guard let hit = memchr(p, 0x0A, stop - p) else { break }
                let h = UnsafeRawPointer(hit)
                newlines += 1
                if newlines % LineIndex.stride == 0 {
                    pending.append(offset + (h - base) + 1)
                }
                p = h + 1
            }
            offset = end
            lock.sync {
                checkpoints.append(contentsOf: pending)
                _newlines = newlines
                _indexedBytes = offset
            }
            pending.removeAll(keepingCapacity: true)
            onProgress?(Double(offset) / Double(max(1, file.size)))
        }
        lock.sync { if !_cancelled { _indexedBytes = file.size; _newlines = newlines } }
    }

    /// Byte offset of 0-based `line`, or nil if not indexed yet / out of range.
    public func offset(ofLine line: Int) -> Int? {
        guard line >= 0 else { return nil }
        let (cp, indexed, total) = lock.sync { () -> (Int?, Int, Int) in
            let k = line / LineIndex.stride
            return (k < checkpoints.count ? checkpoints[k] : nil, _indexedBytes, _newlines)
        }
        guard var pos = cp else { return nil }
        if line > total && indexed >= file.size { return nil }
        var remaining = line % LineIndex.stride
        while remaining > 0 {
            let buf = file.bytes(pos..<indexed)
            guard let base = buf.baseAddress,
                  let hit = memchr(base, 0x0A, buf.count) else { return nil }
            pos += UnsafeRawPointer(hit) - base + 1
            remaining -= 1
        }
        return pos
    }

    /// 0-based line containing byte `offset`, or nil if not indexed yet.
    public func line(containing offset: Int) -> Int? {
        let (k, cp, indexed) = lock.sync { () -> (Int, Int, Int) in
            // Last checkpoint <= offset (binary search).
            var lo = 0, hi = checkpoints.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if checkpoints[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return (lo, checkpoints[lo], _indexedBytes)
        }
        guard offset <= indexed else { return nil }
        return k * LineIndex.stride + Self.countNewlines(file.bytes(cp..<offset))
    }

    /// memchr-driven newline count (libc memchr is SIMD-vectorized).
    public static func countNewlines(_ buf: UnsafeRawBufferPointer) -> Int {
        guard let base = buf.baseAddress else { return 0 }
        var n = 0
        var p = base
        let stop = base + buf.count
        while p < stop, let hit = memchr(p, 0x0A, stop - p) {
            n += 1
            p = UnsafeRawPointer(hit) + 1
        }
        return n
    }
}

extension NSLock {
    /// `NSLocking.withLock` needs macOS 14; this works on 13.
    @inline(__always)
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
