import AppKit
import GRDB
import Observation
import os

extension ClipboardItem: FetchableRecord, PersistableRecord {
    static let databaseTableName = "clipboardItem"

    /// Stores `searchText` as a real column so the FTS5 table can index it.
    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["kind"] = kind.rawValue
        container["text"] = text
        container["rtf"] = rtf
        container["html"] = html
        container["imageFile"] = imageFile
        container["thumbnailFile"] = thumbnailFile
        container["fileURLs"] = try fileURLs.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        container["sourceBundleID"] = sourceBundleID
        container["date"] = date
        container["pinned"] = pinned
        container["fingerprint"] = fingerprint
        container["searchText"] = searchText
    }
}

/// History kept in memory so the panel opens instantly, mirrored to SQLite
/// (GRDB) in `~/Library/Application Support/MacUtility/`. Writes run on GRDB's
/// serial writer queue, off the main thread. Newest item first.
@MainActor
@Observable
final class ClipboardStore {
    private(set) var items: [ClipboardItem] = []

    @ObservationIgnored private let log = Logger(subsystem: "com.giovani.MacUtility", category: "clipboard")
    @ObservationIgnored private var thumbnails: [UUID: NSImage] = [:]
    @ObservationIgnored private var db: DatabaseQueue?

    let directory: URL
    let imagesDirectory: URL

    /// Override with `defaults write com.giovani.MacUtility clipboardMaxItems <n>`.
    private var maxItems: Int {
        let value = UserDefaults.standard.integer(forKey: "clipboardMaxItems")
        return value > 0 ? value : 1000
    }

    /// Override with `defaults write com.giovani.MacUtility clipboardMaxDays <n>`.
    private var maxAge: TimeInterval {
        let value = UserDefaults.standard.integer(forKey: "clipboardMaxDays")
        return TimeInterval(value > 0 ? value : 30) * 86_400
    }

    init() {
        directory = URL.applicationSupportDirectory.appending(path: "MacUtility")
        imagesDirectory = directory.appending(path: "ClipboardImages")
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        do {
            let db = try DatabaseQueue(path: directory.appending(path: "clipboard.sqlite").path)
            try Self.migrator.migrate(db)
            self.db = db
            items = try db.read { try ClipboardItem.order(Column("date").desc).fetchAll($0) }
        } catch {
            log.error("clipboard database failed: \(error.localizedDescription)")
        }
        importLegacyJSON()
        prune()
    }

    func add(_ item: ClipboardItem) {
        var item = item
        var replaced: ClipboardItem?
        if let index = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            let existing = items.remove(at: index)
            item.pinned = existing.pinned
            replaced = existing
            if item.imageFile != nil { removeFiles(of: existing) }
        }
        items.insert(item, at: 0)
        let (new, old) = (item, replaced)
        write { db in
            if let old { _ = try old.delete(db) }
            try new.insert(db)
        }
        prune()
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        removeFiles(of: item)
        write { db in _ = try item.delete(db) }
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        let item = items[index]
        write { db in try item.update(db) }
    }

    /// Moves an item to the top after it gets pasted.
    func touch(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.date = Date()
        items.insert(item, at: 0)
        let updated = item
        write { db in try updated.update(db) }
    }

    /// IDs matching `query` through the FTS5 index, as prefix matches on every
    /// word. Nil means the query has no searchable words.
    func search(_ query: String) -> Set<UUID>? {
        guard let db, let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return nil }
        do {
            let ids = try db.read { db in
                try String.fetchAll(db, sql: """
                    SELECT clipboardItem.id FROM clipboardItem
                    JOIN clipboardSearch ON clipboardSearch.rowid = clipboardItem.rowid
                    WHERE clipboardSearch MATCH ?
                    """, arguments: [pattern])
            }
            return Set(ids.compactMap(UUID.init(uuidString:)))
        } catch {
            log.error("clipboard search failed: \(error.localizedDescription)")
            return []
        }
    }

    func imageURL(_ name: String) -> URL { imagesDirectory.appending(path: name) }

    func thumbnail(for item: ClipboardItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        guard let name = item.thumbnailFile ?? item.imageFile,
              let image = NSImage(contentsOf: imageURL(name)) else { return nil }
        thumbnails[item.id] = image
        return image
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        var kept: [ClipboardItem] = []
        var removed: [ClipboardItem] = []
        var unpinned = 0
        for item in items {
            if item.pinned {
                kept.append(item)
            } else if unpinned < maxItems, item.date >= cutoff {
                kept.append(item)
                unpinned += 1
            } else {
                removed.append(item)
            }
        }
        guard !removed.isEmpty else { return }
        items = kept
        removed.forEach(removeFiles(of:))
        let ids = removed.map(\.id.uuidString)
        write { db in _ = try ClipboardItem.deleteAll(db, keys: ids) }
    }

    private func removeFiles(of item: ClipboardItem) {
        thumbnails[item.id] = nil
        for name in [item.imageFile, item.thumbnailFile].compactMap(\.self) {
            try? FileManager.default.removeItem(at: imageURL(name))
        }
    }

    private func write(_ updates: @escaping @Sendable (Database) throws -> Void) {
        guard let db else { return }
        let log = log
        db.asyncWrite(updates) { _, result in
            if case let .failure(error) = result {
                log.error("clipboard write failed: \(error.localizedDescription)")
            }
        }
    }

    /// One-time import of the history.json the first version wrote.
    private func importLegacyJSON() {
        let file = directory.appending(path: "history.json")
        guard let db, let data = try? Data(contentsOf: file) else { return }
        do {
            let legacy = try JSONDecoder().decode([ClipboardItem].self, from: data)
            let known = Set(items.map(\.fingerprint))
            let fresh = legacy.filter { !known.contains($0.fingerprint) }
            try db.write { db in try fresh.forEach { try $0.insert(db) } }
            items = (items + fresh).sorted { $0.date > $1.date }
            try FileManager.default.removeItem(at: file)
            log.info("imported \(fresh.count) items from history.json")
        } catch {
            log.error("history.json import failed: \(error.localizedDescription)")
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "clipboardItem") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("text", .text)
                t.column("rtf", .blob)
                t.column("html", .blob)
                t.column("imageFile", .text)
                t.column("thumbnailFile", .text)
                t.column("fileURLs", .text)
                t.column("sourceBundleID", .text)
                t.column("date", .datetime).notNull().indexed()
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("fingerprint", .text).notNull().unique()
                t.column("searchText", .text).notNull().defaults(to: "")
            }
            try db.create(virtualTable: "clipboardSearch", using: FTS5()) { t in
                t.synchronize(withTable: "clipboardItem")
                t.tokenizer = .unicode61()
                t.column("searchText")
            }
        }
        return migrator
    }
}
