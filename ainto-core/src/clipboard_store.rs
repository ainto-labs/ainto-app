//! Clipboard history storage backed by SQLite.
//!
//! Reference: Maccy (https://github.com/p0deje/Maccy) for architecture patterns.

use std::path::{Path, PathBuf};

use rusqlite::{Connection, params};

use crate::Error;

/// Content type stored in clipboard history.
#[derive(Debug, Clone, PartialEq)]
pub enum ClipboardContent {
    Text(String),
    Image {
        png_bytes: Vec<u8>,
        width: u32,
        height: u32,
        /// Filename relative to image_dir (e.g., "00ab12ef.png")
        filename: Option<String>,
    },
    File {
        path: String,
    },
}

/// A single clipboard history entry.
#[derive(Debug, Clone)]
pub struct ClipboardEntry {
    pub id: i64,
    pub content: ClipboardContent,
    pub hash: u64,
    pub source_app: Option<String>,
    pub last_copied_at: i64,
    pub copy_count: u32,
}

/// SQLite-backed clipboard history store.
pub struct ClipboardStore {
    db: Connection,
    max_items: usize,
    image_dir: PathBuf,
}

impl ClipboardStore {
    /// Open or create the clipboard database.
    pub fn open(db_path: &Path, image_dir: &Path, max_items: usize) -> Result<Self, Error> {
        std::fs::create_dir_all(image_dir)?;
        let db = Connection::open(db_path)?;
        let store = Self {
            db,
            max_items,
            image_dir: image_dir.to_path_buf(),
        };
        store.create_tables()?;
        Ok(store)
    }

    fn create_tables(&self) -> Result<(), Error> {
        self.db.execute_batch(
            "CREATE TABLE IF NOT EXISTS clipboard_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content_type TEXT NOT NULL,
                text_content TEXT,
                image_path TEXT,
                hash INTEGER NOT NULL,
                source_app TEXT,
                last_copied_at INTEGER NOT NULL,
                copy_count INTEGER DEFAULT 1,
                pinned INTEGER DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_hash ON clipboard_items(hash);
            CREATE INDEX IF NOT EXISTS idx_last_copied ON clipboard_items(last_copied_at DESC);",
        )?;
        Ok(())
    }

    /// Insert a new clipboard entry, deduplicating by hash.
    /// If the hash already exists, increments copy_count and updates timestamp.
    pub fn insert(
        &mut self,
        content: &ClipboardContent,
        hash: u64,
        source_app: Option<&str>,
    ) -> Result<i64, Error> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;

        // Check for duplicate
        let existing: Option<i64> = self
            .db
            .query_row(
                "SELECT id FROM clipboard_items WHERE hash = ?1",
                params![hash as i64],
                |row| row.get(0),
            )
            .ok();

        if let Some(id) = existing {
            self.db.execute(
                "UPDATE clipboard_items SET copy_count = copy_count + 1, last_copied_at = ?1 WHERE id = ?2",
                params![now, id],
            )?;
            return Ok(id);
        }

        // Insert new entry
        let (content_type, text, image_path) = match content {
            ClipboardContent::Text(t) => ("text", Some(t.clone()), None),
            ClipboardContent::Image { png_bytes, .. } => {
                let fname = format!("{:016x}.png", hash);
                let path = self.image_dir.join(&fname);
                std::fs::write(&path, png_bytes)?;
                ("image", None, Some(fname))
            }
            ClipboardContent::File { path } => ("file", Some(path.clone()), None),
        };

        self.db.execute(
            "INSERT INTO clipboard_items (content_type, text_content, image_path, hash, source_app, last_copied_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![content_type, text, image_path, hash as i64, source_app, now],
        )?;

        let id = self.db.last_insert_rowid();

        // Evict oldest non-pinned items if over limit
        self.evict()?;

        Ok(id)
    }

    /// Get recent clipboard entries.
    pub fn get_recent(&self, limit: usize) -> Result<Vec<ClipboardEntry>, Error> {
        self.get_recent_paged(limit, 0)
    }

    pub fn get_recent_paged(&self, limit: usize, offset: usize) -> Result<Vec<ClipboardEntry>, Error> {
        let mut stmt = self.db.prepare(
            "SELECT id, content_type, text_content, image_path, hash, source_app, last_copied_at, copy_count
             FROM clipboard_items
             ORDER BY last_copied_at DESC
             LIMIT ?1 OFFSET ?2",
        )?;

        let entries = stmt
            .query_map(params![limit as i64, offset as i64], |row| {
                let id: i64 = row.get(0)?;
                let content_type: String = row.get(1)?;
                let text: Option<String> = row.get(2)?;
                let image_path: Option<String> = row.get(3)?;
                let hash: i64 = row.get(4)?;
                let source_app: Option<String> = row.get(5)?;
                let last_copied_at: i64 = row.get(6)?;
                let copy_count: u32 = row.get(7)?;

                let content = match content_type.as_str() {
                    "image" => ClipboardContent::Image {
                        png_bytes: Vec::new(), // loaded on demand by Swift
                        width: 0,
                        height: 0,
                        filename: image_path,
                    },
                    "file" => ClipboardContent::File {
                        path: text.unwrap_or_default(),
                    },
                    _ => ClipboardContent::Text(text.unwrap_or_default()),
                };

                Ok(ClipboardEntry {
                    id,
                    content,
                    hash: hash as u64,
                    source_app,
                    last_copied_at,
                    copy_count,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(entries)
    }

    /// Search clipboard entries by text content.
    pub fn search(&self, query: &str) -> Result<Vec<ClipboardEntry>, Error> {
        self.search_paged(query, 50, 0)
    }

    pub fn search_paged(&self, query: &str, limit: usize, offset: usize) -> Result<Vec<ClipboardEntry>, Error> {
        let pattern = format!("%{query}%");
        let mut stmt = self.db.prepare(
            "SELECT id, content_type, text_content, image_path, hash, source_app, last_copied_at, copy_count
             FROM clipboard_items
             WHERE text_content LIKE ?1
             ORDER BY last_copied_at DESC
             LIMIT ?2 OFFSET ?3",
        )?;

        let entries = stmt
            .query_map(params![pattern, limit as i64, offset as i64], |row| {
                let content_type: String = row.get(1)?;
                let text: Option<String> = row.get(2)?;
                let content = match content_type.as_str() {
                    "file" => ClipboardContent::File { path: text.unwrap_or_default() },
                    _ => ClipboardContent::Text(text.unwrap_or_default()),
                };
                Ok(ClipboardEntry {
                    id: row.get(0)?,
                    content,
                    hash: row.get::<_, i64>(4)? as u64,
                    source_app: row.get(5)?,
                    last_copied_at: row.get(6)?,
                    copy_count: row.get(7)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(entries)
    }

    /// Delete a clipboard entry by ID.
    pub fn delete(&mut self, id: i64) -> Result<(), Error> {
        let image_path: Option<String> = self
            .db
            .query_row(
                "SELECT image_path FROM clipboard_items WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
            .ok()
            .flatten();

        if let Some(filename) = image_path {
            self.safe_remove_image(&filename);
        }

        self.db
            .execute("DELETE FROM clipboard_items WHERE id = ?1", params![id])?;
        Ok(())
    }

    /// Clear all entries.
    pub fn clear(&mut self) -> Result<(), Error> {
        let mut stmt = self.db.prepare(
            "SELECT image_path FROM clipboard_items WHERE image_path IS NOT NULL",
        )?;
        let paths: Vec<String> = stmt
            .query_map([], |row| row.get(0))?
            .filter_map(|r| r.ok())
            .collect();
        for filename in paths {
            self.safe_remove_image(&filename);
        }
        self.db.execute("DELETE FROM clipboard_items", [])?;
        Ok(())
    }

    /// Evict oldest non-pinned items exceeding max_items.
    fn evict(&mut self) -> Result<(), Error> {
        let count: i64 = self
            .db
            .query_row("SELECT COUNT(*) FROM clipboard_items", [], |row| row.get(0))?;

        if count as usize <= self.max_items {
            return Ok(());
        }

        let to_delete = count as usize - self.max_items;

        let mut stmt = self.db.prepare(
            "SELECT id, image_path FROM clipboard_items ORDER BY last_copied_at ASC LIMIT ?1",
        )?;
        let items: Vec<(i64, Option<String>)> = stmt
            .query_map(params![to_delete as i64], |row| Ok((row.get(0)?, row.get(1)?)))?
            .filter_map(|r| r.ok())
            .collect();

        for (id, image_path) in items {
            if let Some(filename) = image_path {
                self.safe_remove_image(&filename);
            }
            self.db
                .execute("DELETE FROM clipboard_items WHERE id = ?1", params![id])?;
        }

        Ok(())
    }

    /// Remove an image file, rejecting path traversal.
    fn safe_remove_image(&self, filename: &str) {
        if filename.contains("..") || filename.contains('/') {
            return;
        }
        let path = self.image_dir.join(filename);
        if path.starts_with(&self.image_dir) {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// Compute xxhash of content for deduplication.
pub fn hash_content(content: &ClipboardContent) -> u64 {
    use xxhash_rust::xxh3::xxh3_64;
    match content {
        ClipboardContent::Text(t) => xxh3_64(t.as_bytes()),
        ClipboardContent::Image { png_bytes, .. } => xxh3_64(png_bytes),
        ClipboardContent::File { path } => xxh3_64(path.as_bytes()),
    }
}

/// Encode raw RGBA pixels to PNG bytes.
pub fn rgba_to_png(rgba: &[u8], width: u32, height: u32) -> Result<Vec<u8>, Error> {
    use image::{ImageBuffer, Rgba};
    let img: ImageBuffer<Rgba<u8>, _> =
        ImageBuffer::from_raw(width, height, rgba.to_vec()).ok_or(Error::ImageEncode)?;
    let mut buf = Vec::new();
    img.write_to(
        &mut std::io::Cursor::new(&mut buf),
        image::ImageFormat::Png,
    )?;
    Ok(buf)
}
