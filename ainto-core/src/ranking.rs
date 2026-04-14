//! Frecency-based ranking: frequency + recency.
//!
//! Each entry stores a count and last_used timestamp.
//! Score = count * 10 * decay, where decay decreases over days since last use.

use std::collections::HashMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::Error;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RankingEntry {
    pub count: i32,
    pub last_used: i64, // unix timestamp
}

impl RankingEntry {
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
        let decay = (1.0 - days_since * 0.05).max(0.0).min(1.0);
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

/// Increment a key and save. Returns the new frecency score.
pub fn increment_and_save(path: &Path, key: &str) -> i32 {
    let mut rankings = load_rankings(path);
    rankings
        .entry(key.to_string())
        .and_modify(|e| e.increment())
        .or_insert_with(RankingEntry::new);
    let _ = save_rankings(path, &rankings);
    rankings.get(key).map(|e| e.frecency_score()).unwrap_or(0)
}

/// Get frecency score for a key.
pub fn get_score(path: &Path, key: &str) -> i32 {
    load_rankings(path)
        .get(key)
        .map(|e| e.frecency_score())
        .unwrap_or(0)
}
