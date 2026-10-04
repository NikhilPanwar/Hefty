# Hefty: architecture decision

**Decision:** a native macOS app in **Swift + AppKit/CoreText**, built on a
file engine that never loads the file: **mmap + piece table + sparse,
background line index**, with the viewport addressed by **byte offset**.

## Why native Swift/AppKit (not Electron/Tauri, not SwiftUI text views)

| Option | Verdict |
|---|---|
| Electron / web editors (Monaco, CodeMirror) | Rejected. JS strings and the DOM top out around hundreds of MB; a 100 GB file needs direct `mmap` and pointer-level scanning. |
| Tauri (Rust core + web UI) | Viable engine, but the UI is still a WebView and it's two languages to ship one Mac app. |
| SwiftUI `TextEditor` / `NSTextView` | Rejected for the text area. Both want the whole string in memory and lay out the entire document. |
| **Swift + AppKit custom view + CoreText** | **Chosen.** Zero-copy `mmap`, libc `memchr` (SIMD), full control of layout so cost is O(visible lines). It's the same approach EmEditor, Sublime and HexFiend take. SwiftUI can still host the chrome later. |

## The engine (`Sources/BigFileCore`, no UI dependencies)

1. **`MappedFile`**: `mmap` of the whole file, read-only. Opening a 100 GB
   file costs only virtual address space, so **open is O(1)**. The kernel
   pages bytes in on demand and drops them under memory pressure, so RAM use
   tracks what you look at, not the file size.
2. **`PieceTable`**: edits never touch the original. The document is a list of
   spans over *original* (mmap) and an *append-only add buffer*.
   - Insert or delete is O(pieces), with no copying of the file.
   - **Undo/redo** is a stack of piece arrays. That's cheap because arrays are
     copy-on-write and pieces are tiny. Consecutive typing coalesces into one
     undo step.
3. **`LineIndex`**: a background thread scans with `memchr` and stores the
   offset of **every 1024th line** only. With ~1B lines in 100 GB that is ~8 MB
   instead of 8 GB. Any exact line is found by jumping to a checkpoint and
   scanning ≤1024 lines (µs). You can query it *while it is building*. Line
   numbers stay correct after edits by combining the index (original pieces)
   with newline counts of inserted text.
4. **Byte-offset viewport**: the view's scroll position is a byte offset, so
   you can scroll, jump to any % and edit **before indexing finishes**. Line
   numbers fill in as the index catches up.
   - **Very long lines** (e.g. a 5 GB single-line JSON) are shown in 16–32 KB
     segments.
   - Segment boundaries are decided from nearby bytes only, so scrolling never
     scans back GBs.
5. **`TextSearcher`**: streams 32 MB windows (zero-copy on unedited regions)
   with overlap for matches that cross window edges. It runs at disk/memory
   bandwidth, and you can cancel it with Esc. It can search forward or
   backward, wrap around and match case.
6. **`Highlighter`**: per-line byte lexers for SQL, JSON, CSV/TSV (one color
   per column, like EmEditor) and XML. Only visible lines are tokenized.
7. **Save**: streams the pieces to a temp file, then does an atomic `rename`.
   A crash mid-save never corrupts the original. The document then re-maps the
   new file.
8. **`JSONFormatter`**: a streaming pretty-printer/minifier from file to file
   with constant memory. It works on 100 GB JSON.

## UI (`Sources/Hefty`)

- **`BigTextView`**: a custom `NSView`. It lays out only visible lines with
  CoreText and draws:
  - the gutter line numbers, selection and caret
  - optional **word wrap**
  - mouse selection and double-click word select
  - full keyboard navigation and editing, clipboard and undo/redo
- **Window**: find bar (Return / Shift-Return, Match case), a byte-proportional
  scroller, and a status bar showing line/col, size, indexing %, language and
  modified state.
- **Menus**:
  - File: Open / Save / Save As
  - Edit: Undo / Redo / Cut / Copy / Paste / Select All / Find / Find Next /
    Go to Line
  - View: Word Wrap
  - Format: Pretty-print JSON

## Since v0.3

| Was | Now |
|---|---|
| Undo kept a full copy of the piece array per edit | Undo records only the pieces each edit replaced (20k edits: KB, not GB); grouped steps for multi-cursor, Replace All, line commands |
| Line numbers walked every piece with index lookups | Pieces cache their newline counts; lookups stay ~2 ms after 10k edits |
| Background jobs locked editing | Jobs read an immutable `TextSnapshot` (add buffer is chunked and never moves) |
| Line-local highlighting | Lexer state carries across lines (SQL comments/strings/dollar quotes, CSV quoted fields, XML comments/tags) |
| UTF-8 only | Detection + iconv: non-UTF-8 and CR files are converted to a UTF-8 working copy and back on save |
| mmap of the user's file (SIGBUS if truncated) | mmap of an APFS clone; other apps can't pull bytes out from under us |
| Literal search, ASCII case folding | memchr fast paths for both cases; ICU regex over line-aligned windows; whole word; Unicode case via regex |

Remaining limits: regex matches can't span the 4 MB search windows; Replace All beyond 2 million
matches and in-place formatting of results over 512 MB rewrite the document and can't be undone;
hex view is read-only; word wrap of a single segment of a huge line is per 16 KB segment.

## Performance targets

- **Open**: instant (mmap), any size.
- **Index**: roughly SSD read speed. On Apple-silicon NVMe that's 3–7 GB/s cold,
  so ~15–35 s for 100 GB, and the file is usable during it.
- **Scroll / jump / edit**: independent of file size.
- **Memory**: viewport plus ~8 MB index per billion lines, plus edits.
