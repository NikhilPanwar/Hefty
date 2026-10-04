import Foundation

/// Crash recovery: unsaved edits are journaled every few seconds as the
/// piece list plus the inserted bytes, so a crash or power loss never loses
/// more than a few seconds of work, even on a 100 GB file.
public enum Recovery {
    public struct Entry: Codable {
        public var id: String
        public var path: String?
        public var untitledName: String
        public var size: Int
        public var mtime: Double
        public var encodingID: String
        public var encodingBOM: [UInt8]
        public var lineEnding: String
        public var language: String
        public var pieces: [[Int]]       // [source (0 original, 1 added), start, length]
        public var addStarts: [Int]
        public var savedAt: Date
        public var displayName: String { path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? untitledName }
    }

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Hefty/Recovery", isDirectory: true)
    }

    public static func save(_ doc: TextDocument, id: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let j = doc.buffer.journal()
        let stamp = doc.diskStamp
        let e = Entry(id: id, path: doc.url?.path, untitledName: doc.untitledName,
                      size: stamp?.size ?? 0, mtime: stamp?.mtime ?? 0,
                      encodingID: doc.encoding.id, encodingBOM: doc.encoding.bom,
                      lineEnding: doc.lineEnding.rawValue, language: doc.language.rawValue,
                      pieces: j.pieces.map { [$0.source == .original ? 0 : 1, $0.start, $0.length] },
                      addStarts: j.addStarts, savedAt: Date())
        try Data(j.addBytes).write(to: directory.appendingPathComponent("\(id).bin"), options: .atomic)
        try JSONEncoder().encode(e).write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
    }

    public static func remove(id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).bin"))
    }

    public static func pending() -> [Entry] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        }.sorted { $0.savedAt < $1.savedAt }
    }

    /// Reopens the original file (which must be unchanged since the journal
    /// was written) and re-applies the journaled edits.
    public static func restore(_ e: Entry) throws -> TextDocument {
        let doc: TextDocument
        if let path = e.path {
            let url = URL(fileURLWithPath: path)
            let enc = TextEncoding(id: e.encodingID, name: TextEncoding.all.first { $0.id == e.encodingID }?.name ?? e.encodingID,
                                   bom: e.encodingBOM)
            doc = try TextDocument(url: url, encoding: enc)
            guard let s = doc.diskStamp, s.size == e.size, abs(s.mtime - e.mtime) < 0.001 else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent) changed on disk after the unsaved edits were recorded, so they can't be re-applied safely."])
            }
        } else {
            doc = try TextDocument(untitledName: e.untitledName)
        }
        let bytes = [UInt8]((try? Data(contentsOf: directory.appendingPathComponent("\(e.id).bin"))) ?? Data())
        let pieces = e.pieces.map { Piece(source: $0[0] == 0 ? .original : .added, start: $0[1], length: $0[2]) }
        doc.restoreJournal(pieces: pieces, addBytes: bytes, addStarts: e.addStarts)
        if let l = Language(rawValue: e.language) { doc.language = l }
        if let le = LineEnding(rawValue: e.lineEnding) { doc.lineEnding = le }
        return doc
    }
}
