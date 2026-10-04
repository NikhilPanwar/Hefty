import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum BigFileError: Error, CustomStringConvertible {
    case open(String, Int32)
    case stat(String, Int32)
    case mmap(String, Int32)
    case write(String, Int32)

    public var description: String {
        switch self {
        case let .open(p, e): return "Cannot open \(p): \(String(cString: strerror(e)))"
        case let .stat(p, e): return "Cannot stat \(p): \(String(cString: strerror(e)))"
        case let .mmap(p, e): return "Cannot map \(p): \(String(cString: strerror(e)))"
        case let .write(p, e): return "Cannot write \(p): \(String(cString: strerror(e)))"
        }
    }
}

/// Read-only memory map of an entire file.
///
/// Mapping a 100 GB file costs only virtual address space (64-bit macOS has
/// plenty); the kernel pages bytes in on demand and evicts them under memory
/// pressure, so resident memory stays proportional to what is actually read.
/// Opening is O(1) regardless of file size.
public final class MappedFile: @unchecked Sendable {
    public let url: URL
    public let size: Int
    private let fd: Int32
    private let base: UnsafeRawPointer?

    public init(url: URL) throws {
        self.url = url
        let path = url.path
        let fd = openReadOnly(path)
        guard fd >= 0 else { throw BigFileError.open(path, errno) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let e = errno; close(fd)
            throw BigFileError.stat(path, e)
        }
        let size = Int(st.st_size)
        self.fd = fd
        self.size = size

        if size == 0 {
            base = nil
        } else {
            let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
            if p == MAP_FAILED {
                let e = errno; close(fd)
                throw BigFileError.mmap(path, e)
            }
            base = UnsafeRawPointer(p!)
        }
    }

    deinit {
        if let base { munmap(UnsafeMutableRawPointer(mutating: base), size) }
        close(fd)
    }

    /// Zero-copy view of `range`. Valid as long as this object is alive.
    /// Touching the bytes may page-fault (disk read) the first time.
    public func bytes(_ range: Range<Int>) -> UnsafeRawBufferPointer {
        let lo = max(0, min(range.lowerBound, size))
        let hi = max(lo, min(range.upperBound, size))
        guard let base, hi > lo else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        return UnsafeRawBufferPointer(start: base + lo, count: hi - lo)
    }

    /// Reads `count` bytes at `offset` into `buffer` with pread (no mapping),
    /// for sequential scans that shouldn't grow resident memory.
    public func pread(into buffer: UnsafeMutableRawPointer, count: Int, at offset: Int) -> Int {
        var done = 0
        while done < count {
            let r = Darwin.pread(fd, buffer + done, count - done, off_t(offset + done))
            if r < 0 { if errno == EINTR { continue }; return -1 }
            if r == 0 { break }
            done += r
        }
        return done
    }

    /// Drops already-read pages from this process's resident memory (they
    /// stay in the system file cache), so indexing a 100 GB file doesn't make
    /// the app look like it uses gigabytes of RAM.
    public func release(_ range: Range<Int>) {
        guard let base, size > 0 else { return }
        let page = Int(getpagesize())
        let lo = (max(0, range.lowerBound) / page) * page
        let hi = min(size, range.upperBound) / page * page
        guard hi > lo else { return }
        madvise(UnsafeMutableRawPointer(mutating: base + lo), hi - lo, MADV_DONTNEED)
    }

    /// Hint the kernel about the access pattern (sequential for indexing/search,
    /// random for interactive scrolling).
    public func advise(sequential: Bool, range: Range<Int>? = nil) {
        guard let base, size > 0 else { return }
        let r = range ?? 0..<size
        let page = Int(getpagesize())
        let lo = (r.lowerBound / page) * page
        let len = r.upperBound - lo
        guard len > 0 else { return }
        madvise(UnsafeMutableRawPointer(mutating: base + lo), len,
                sequential ? MADV_SEQUENTIAL : MADV_RANDOM)
    }
}

@inline(__always)
private func openReadOnly(_ path: String) -> Int32 {
    open(path, O_RDONLY)
}
