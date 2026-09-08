//! Frecency-based ranking: frequency + recency.
//!
//! Each entry stores a count and last_used timestamp.
//! Score = count * 10 * decay, where decay decreases over days since last use.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::Error;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RankingEntry {
    pub count: i32,
    pub last_used: i64, // unix timestamp
}

impl Default for RankingEntry {
    fn default() -> Self {
        Self::new()
    }
}

impl RankingEntry {
    /// A first use: one hit, right now.
    pub fn new() -> Self {
        Self {
            count: 1,
            last_used: now(),
        }
    }

    /// Increment usage count and update last_used.
    pub fn increment(&mut self) {
        self.count += 1;
        self.last_used = now();
    }

    /// Calculate frecency score.
    /// Decays over time: full score within 1 day, drops to 0 after 20 days.
    pub fn frecency_score(&self) -> i32 {
        let days_since = (now() - self.last_used) as f64 / 86400.0;
        let decay = (1.0 - days_since * 0.05).clamp(0.0, 1.0);
        let raw = (self.count as f64 * 10.0 * decay) as i32;
        raw.min(100) // cap at 100
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RankingFile {
    #[serde(default)]
    pub rankings: HashMap<String, RankingEntry>,
}

/// Load rankings from a TOML file.
pub fn load_rankings(path: &Path) -> HashMap<String, RankingEntry> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|content| {
            // Try new format first
            if let Ok(file) = toml::from_str::<RankingFile>(&content) {
                return Some(file.rankings);
            }
            // Migrate from old format: key = i32
            if let Ok(old) = toml::from_str::<HashMap<String, i32>>(&content) {
                let migrated: HashMap<String, RankingEntry> = old
                    .into_iter()
                    .map(|(k, v)| {
                        (
                            k,
                            RankingEntry {
                                count: v,
                                last_used: now(),
                            },
                        )
                    })
                    .collect();
                // Write back in new format
                let _ = save_rankings(path, &migrated);
                return Some(migrated);
            }
            None
        })
        .unwrap_or_default()
}

/// Save rankings to a TOML file.
pub fn save_rankings(path: &Path, rankings: &HashMap<String, RankingEntry>) -> Result<(), Error> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let file = RankingFile {
        rankings: rankings.clone(),
    };
    let content = toml::to_string_pretty(&file)?;
    std::fs::write(path, content)?;
    Ok(())
}

/// Process-wide cache of the ranking table.
///
/// `get_score` is on the search-scoring path and is called once per candidate
/// while ranking results, so re-reading and re-parsing the TOML on every call
/// cost a file read per lookup. The file is only ever written through
/// `increment_and_save`, so the cache stays authoritative for this process.
///
/// Production uses one ranking path. Keying by path also keeps callers using
/// separate temporary files isolated, including tests running concurrently.
type RankingCache = HashMap<PathBuf, HashMap<String, RankingEntry>>;
static CACHE: Mutex<Option<RankingCache>> = Mutex::new(None);

/// Run `f` against this path's table, loading it from disk on first use.
fn with_cache<T>(path: &Path, f: impl FnOnce(&mut HashMap<String, RankingEntry>) -> T) -> T {
    let mut guard = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    let cache = guard.get_or_insert_with(HashMap::new);
    let rankings = cache
        .entry(path.to_path_buf())
        .or_insert_with(|| load_rankings(path));
    f(rankings)
}

/// Snapshot of the current ranking table.
pub fn all_rankings(path: &Path) -> HashMap<String, RankingEntry> {
    with_cache(path, |rankings| rankings.clone())
}

/// Remove this path's persisted rankings and clear only its cached table.
pub fn reset(path: &Path) -> Result<(), Error> {
    let mut guard = CACHE.lock().unwrap_or_else(|error| error.into_inner());
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    guard
        .get_or_insert_with(HashMap::new)
        .insert(path.to_path_buf(), HashMap::new());
    Ok(())
}

/// Increment a key and save. Returns the new frecency score.
pub fn increment_and_save(path: &Path, key: &str) -> i32 {
    with_cache(path, |rankings| {
        let entry = rankings
            .entry(key.to_string())
            .and_modify(|entry| entry.increment())
            .or_default();
        let score = entry.frecency_score();
        let _ = save_rankings(path, rankings);
        score
    })
}

/// Get frecency score for a key.
pub fn get_score(path: &Path, key: &str) -> i32 {
    with_cache(path, |rankings| {
        rankings.get(key).map(|e| e.frecency_score()).unwrap_or(0)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn separate_paths_keep_independent_cached_tables_and_resets() {
        let directory =
            std::env::temp_dir().join(format!("ainto-ranking-paths-{}", uuid::Uuid::new_v4()));
        let first = directory.join("first.toml");
        let second = directory.join("second.toml");
        let key = "app:shared";
        increment_and_save(&first, key);
        increment_and_save(&second, key);
        increment_and_save(&second, key);
        assert_eq!(all_rankings(&first)[key].count, 1);
        assert_eq!(all_rankings(&second)[key].count, 2);
        assert_eq!(load_rankings(&first)[key].count, 1);
        assert_eq!(load_rankings(&second)[key].count, 2);

        // Returning to another path must retain its cached table, not reload it.
        std::fs::write(&second, "[rankings]\n").unwrap();
        assert_eq!(all_rankings(&first)[key].count, 1);
        assert_eq!(all_rankings(&second)[key].count, 2);
        reset(&first).unwrap();
        assert_eq!(get_score(&first, key), 0);
        assert_eq!(all_rankings(&second)[key].count, 2);
        increment_and_save(&second, key);
        assert_eq!(load_rankings(&second)[key].count, 3);
        reset(&second).unwrap();
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn concurrent_paths_do_not_share_counts() {
        let directory =
            std::env::temp_dir().join(format!("ainto-ranking-parallel-{}", uuid::Uuid::new_v4()));
        std::thread::scope(|scope| {
            for expected in 1..=4 {
                let path = directory.join(format!("{expected}.toml"));
                scope.spawn(move || {
                    for _ in 0..expected {
                        increment_and_save(&path, "app:shared");
                    }
                    assert_eq!(all_rankings(&path)["app:shared"].count, expected);
                    assert_eq!(load_rankings(&path)["app:shared"].count, expected);
                    reset(&path).unwrap();
                });
            }
        });
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn reset_clears_the_cache_and_removes_the_file() {
        let directory = std::env::temp_dir().join(format!(
            "ainto-ranking-test-{}",
            uuid::Uuid::new_v4().simple()
        ));
        let path = directory.join("ranking.toml");

        assert!(increment_and_save(&path, "app:test") > 0);
        assert!(path.exists());

        reset(&path).unwrap();

        assert_eq!(get_score(&path, "app:test"), 0);
        assert!(!path.exists());
        std::fs::remove_dir_all(directory).ok();
    }
}
