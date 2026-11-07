use super::item::{now, ClipboardItem, Kind};
use anyhow::Result;
use rusqlite::{params, Connection, Row};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

pub struct Limits {
    pub max_items: usize,
    pub max_age_days: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Self { max_items: 1000, max_age_days: 30 }
    }
}

/// History kept in memory so the panel opens instantly, mirrored to SQLite
/// with an FTS5 index. Newest item first. Mirrors ClipboardStore.swift.
pub struct ClipboardStore {
    items: Vec<ClipboardItem>,
    db: Connection,
    images: PathBuf,
    limits: Limits,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS clipboardItem (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    text TEXT,
    html TEXT,
    imageFile TEXT,
    thumbnailFile TEXT,
    files TEXT,
    sourceApp TEXT,
    date REAL NOT NULL,
    pinned INTEGER NOT NULL DEFAULT 0,
    fingerprint TEXT NOT NULL UNIQUE,
    searchText TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS clipboardItem_date ON clipboardItem(date);
CREATE VIRTUAL TABLE IF NOT EXISTS clipboardSearch USING fts5(
    searchText, content='clipboardItem', content_rowid='rowid', tokenize='unicode61'
);
CREATE TRIGGER IF NOT EXISTS clipboardItem_ai AFTER INSERT ON clipboardItem BEGIN
    INSERT INTO clipboardSearch(rowid, searchText) VALUES (new.rowid, new.searchText);
END;
CREATE TRIGGER IF NOT EXISTS clipboardItem_ad AFTER DELETE ON clipboardItem BEGIN
    INSERT INTO clipboardSearch(clipboardSearch, rowid, searchText) VALUES ('delete', old.rowid, old.searchText);
END;
CREATE TRIGGER IF NOT EXISTS clipboardItem_au AFTER UPDATE ON clipboardItem BEGIN
    INSERT INTO clipboardSearch(clipboardSearch, rowid, searchText) VALUES ('delete', old.rowid, old.searchText);
    INSERT INTO clipboardSearch(rowid, searchText) VALUES (new.rowid, new.searchText);
END;
";

impl ClipboardStore {
    pub fn open(directory: &Path, limits: Limits) -> Result<Self> {
        let images = directory.join("ClipboardImages");
        fs::create_dir_all(&images)?;
        let db = Connection::open(directory.join("clipboard.sqlite"))?;
        db.execute_batch(SCHEMA)?;
        let items = {
            let mut stmt = db.prepare("SELECT * FROM clipboardItem ORDER BY date DESC")?;
            let rows = stmt.query_map([], read_row)?;
            rows.filter_map(|r| r.ok()).collect()
        };
        let mut store = Self { items, db, images, limits };
        store.prune()?;
        Ok(store)
    }

    pub fn items(&self) -> &[ClipboardItem] {
        &self.items
    }

    pub fn image_path(&self, name: &str) -> PathBuf {
        self.images.join(name)
    }

    /// Copying the same thing again moves it to the top and keeps its pin.
    pub fn add(&mut self, mut item: ClipboardItem) -> Result<()> {
        if let Some(i) = self.items.iter().position(|x| x.fingerprint == item.fingerprint) {
            let old = self.items.remove(i);
            item.pinned = old.pinned;
            if item.image_file.is_some() {
                self.remove_files(&old);
            }
            self.db.execute("DELETE FROM clipboardItem WHERE id = ?", [old.id.to_string()])?;
        }
        self.insert_row(&item)?;
        self.items.insert(0, item);
        self.prune()
    }

    pub fn delete(&mut self, id: Uuid) -> Result<()> {
        if let Some(i) = self.items.iter().position(|x| x.id == id) {
            let item = self.items.remove(i);
            self.remove_files(&item);
            self.db.execute("DELETE FROM clipboardItem WHERE id = ?", [id.to_string()])?;
        }
        Ok(())
    }

    pub fn toggle_pin(&mut self, id: Uuid) -> Result<()> {
        if let Some(item) = self.items.iter_mut().find(|x| x.id == id) {
            item.pinned = !item.pinned;
            self.db.execute(
                "UPDATE clipboardItem SET pinned = ? WHERE id = ?",
                params![item.pinned, id.to_string()],
            )?;
        }
        Ok(())
    }

    /// Moves an item to the top after it gets pasted.
    pub fn touch(&mut self, id: Uuid) -> Result<()> {
        if let Some(i) = self.items.iter().position(|x| x.id == id) {
            let mut item = self.items.remove(i);
            item.date = now();
            self.db.execute(
                "UPDATE clipboardItem SET date = ? WHERE id = ?",
                params![item.date, id.to_string()],
            )?;
            self.items.insert(0, item);
        }
        Ok(())
    }

    /// IDs matching every word of `query` as a prefix. None means the query
    /// has no searchable words.
    pub fn search(&self, query: &str) -> Result<Option<HashSet<Uuid>>> {
        let terms: Vec<String> = query
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| !w.is_empty())
            .map(|w| format!("\"{w}\"*"))
            .collect();
        if terms.is_empty() {
            return Ok(None);
        }
        let mut stmt = self.db.prepare(
            "SELECT clipboardItem.id FROM clipboardItem
             JOIN clipboardSearch ON clipboardSearch.rowid = clipboardItem.rowid
             WHERE clipboardSearch MATCH ?",
        )?;
        let ids = stmt
            .query_map([terms.join(" ")], |r| r.get::<_, String>(0))?
            .filter_map(|r| r.ok())
            .filter_map(|s| Uuid::parse_str(&s).ok())
            .collect();
        Ok(Some(ids))
    }

    fn insert_row(&self, item: &ClipboardItem) -> Result<()> {
        self.db.execute(
            "INSERT INTO clipboardItem
             (id, kind, text, html, imageFile, thumbnailFile, files, sourceApp, date, pinned, fingerprint, searchText)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                item.id.to_string(),
                item.kind.as_str(),
                item.text,
                item.html,
                item.image_file,
                item.thumbnail_file,
                (!item.files.is_empty()).then(|| item.files.join("\n")),
                item.source_app,
                item.date,
                item.pinned,
                item.fingerprint,
                item.search_text(),
            ],
        )?;
        Ok(())
    }

    /// Keeps pinned items, then the newest `max_items` younger than `max_age_days`.
    fn prune(&mut self) -> Result<()> {
        let cutoff = now() - f64::from(self.limits.max_age_days) * 86_400.0;
        let mut unpinned = 0;
        let mut removed = Vec::new();
        let max = self.limits.max_items;
        self.items.retain(|item| {
            let keep = item.pinned || (unpinned < max && item.date >= cutoff);
            if keep && !item.pinned {
                unpinned += 1;
            }
            if !keep {
                removed.push(item.clone());
            }
            keep
        });
        for item in &removed {
            self.remove_files(item);
            self.db.execute("DELETE FROM clipboardItem WHERE id = ?", [item.id.to_string()])?;
        }
        Ok(())
    }

    fn remove_files(&self, item: &ClipboardItem) {
        for name in [&item.image_file, &item.thumbnail_file].into_iter().flatten() {
            let _ = fs::remove_file(self.images.join(name));
        }
    }
}

fn read_row(r: &Row) -> rusqlite::Result<ClipboardItem> {
    let id: String = r.get("id")?;
    let kind: String = r.get("kind")?;
    let files: Option<String> = r.get("files")?;
    Ok(ClipboardItem {
        id: Uuid::parse_str(&id).unwrap_or_else(|_| Uuid::new_v4()),
        kind: Kind::parse(&kind).unwrap_or(Kind::Text),
        text: r.get("text")?,
        html: r.get("html")?,
        image_file: r.get("imageFile")?,
        thumbnail_file: r.get("thumbnailFile")?,
        files: files.map(|f| f.lines().map(String::from).collect()).unwrap_or_default(),
        source_app: r.get("sourceApp")?,
        date: r.get("date")?,
        pinned: r.get("pinned")?,
        fingerprint: r.get("fingerprint")?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(dir: &Path, max_items: usize) -> ClipboardStore {
        ClipboardStore::open(dir, Limits { max_items, max_age_days: 30 }).unwrap()
    }

    #[test]
    fn duplicate_moves_to_top_and_keeps_pin() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = store(dir.path(), 10);
        s.add(ClipboardItem::text("a".into(), None, None)).unwrap();
        let a = s.items()[0].id;
        s.toggle_pin(a).unwrap();
        s.add(ClipboardItem::text("b".into(), None, None)).unwrap();
        s.add(ClipboardItem::text("a".into(), None, None)).unwrap();
        assert_eq!(s.items().len(), 2);
        assert_eq!(s.items()[0].text.as_deref(), Some("a"));
        assert!(s.items()[0].pinned);
    }

    #[test]
    fn prune_keeps_pinned_and_newest() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = store(dir.path(), 2);
        s.add(ClipboardItem::text("old".into(), None, None)).unwrap();
        let old = s.items()[0].id;
        s.toggle_pin(old).unwrap();
        for t in ["x", "y", "z"] {
            s.add(ClipboardItem::text(t.into(), None, None)).unwrap();
        }
        let texts: Vec<_> = s.items().iter().map(|i| i.text.clone().unwrap()).collect();
        assert_eq!(texts, ["z", "y", "old"]);
    }

    #[test]
    fn prune_drops_expired() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = store(dir.path(), 10);
        let mut item = ClipboardItem::text("ancient".into(), None, None);
        item.date = now() - 31.0 * 86_400.0;
        s.add(item).unwrap();
        assert!(s.items().is_empty());
    }

    #[test]
    fn search_prefix_and_persistence() {
        let dir = tempfile::tempdir().unwrap();
        {
            let mut s = store(dir.path(), 10);
            s.add(ClipboardItem::text("hello world".into(), None, None)).unwrap();
            s.add(ClipboardItem::text("goodbye".into(), None, None)).unwrap();
            let hit = s.items()[1].id;
            assert_eq!(s.search("hel wor").unwrap().unwrap(), HashSet::from([hit]));
            assert!(s.search("  ").unwrap().is_none());
            s.delete(s.items()[0].id).unwrap();
        }
        let s = store(dir.path(), 10);
        assert_eq!(s.items().len(), 1);
        assert_eq!(s.search("good").unwrap().unwrap().len(), 0);
        assert_eq!(s.search("hello").unwrap().unwrap().len(), 1);
    }
}
