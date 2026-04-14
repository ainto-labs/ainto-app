//! Snippet management with TOML persistence and placeholder resolution.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::Error;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct Snippet {
    pub id: String,
    pub name: String,
    pub keyword: String,
    pub expansion: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct SnippetFile {
    #[serde(default)]
    pub snippets: Vec<Snippet>,
}

impl Snippet {
    /// Create a new snippet with a generated UUID.
    pub fn new(name: String, keyword: String, expansion: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            keyword,
            expansion,
        }
    }

    /// Get the expanded text with placeholders resolved.
    pub fn expand(&self, clipboard_text: Option<&str>) -> String {
        resolve_placeholders(&self.expansion, clipboard_text)
    }
}

/// Load snippets from a TOML file.
/// Returns empty vec if file doesn't exist.
pub fn load_snippets(path: &Path) -> Result<Vec<Snippet>, Error> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let content = std::fs::read_to_string(path)?;
    let file: SnippetFile = toml::from_str(&content)?;
    Ok(file.snippets)
}

/// Save snippets to a TOML file.
pub fn save_snippets(path: &Path, snippets: &[Snippet]) -> Result<(), Error> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let file = SnippetFile {
        snippets: snippets.to_vec(),
    };
    let content = toml::to_string_pretty(&file)?;
    std::fs::write(path, content)?;
    Ok(())
}

/// Resolve placeholders in expansion text.
///
/// Supported placeholders:
/// - `{date}` → current date (yyyy-MM-dd)
/// - `{time}` → current time (HH:mm:ss)
/// - `{clipboard}` → current clipboard text
/// - `{uuid}` → random UUID
pub fn resolve_placeholders(text: &str, clipboard_text: Option<&str>) -> String {
    use std::time::SystemTime;

    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    // Simple date/time formatting without chrono dependency
    // Unix timestamp → date components
    let (year, month, day, hour, min, sec) = unix_to_datetime(now as i64);

    let date_str = format!("{year:04}-{month:02}-{day:02}");
    let time_str = format!("{hour:02}:{min:02}:{sec:02}");

    text.replace("{date}", &date_str)
        .replace("{time}", &time_str)
        .replace("{clipboard}", clipboard_text.unwrap_or(""))
        .replace("{uuid}", &uuid::Uuid::new_v4().to_string())
}

/// Minimal unix timestamp to date/time conversion (UTC).
fn unix_to_datetime(timestamp: i64) -> (i32, u32, u32, u32, u32, u32) {
    let secs_per_day: i64 = 86400;
    let days = timestamp / secs_per_day;
    let remaining_secs = (timestamp % secs_per_day) as u32;

    let hour = remaining_secs / 3600;
    let min = (remaining_secs % 3600) / 60;
    let sec = remaining_secs % 60;

    // Days since 1970-01-01 → year/month/day
    let mut y = 1970i32;
    let mut remaining_days = days;

    loop {
        let days_in_year = if is_leap_year(y) { 366 } else { 365 };
        if remaining_days < days_in_year {
            break;
        }
        remaining_days -= days_in_year;
        y += 1;
    }

    let days_in_months = if is_leap_year(y) {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };

    let mut m = 0u32;
    for &dim in &days_in_months {
        if remaining_days < dim {
            break;
        }
        remaining_days -= dim;
        m += 1;
    }

    (y, m + 1, remaining_days as u32 + 1, hour, min, sec)
}

fn is_leap_year(y: i32) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resolve_placeholders() {
        let result = resolve_placeholders("Hello {clipboard}!", Some("world"));
        assert_eq!(result, "Hello world!");
    }

    #[test]
    fn test_resolve_date_placeholder() {
        let result = resolve_placeholders("{date}", None);
        // Should be a valid date format
        assert!(result.len() == 10); // yyyy-MM-dd
        assert!(result.contains('-'));
    }

    #[test]
    fn test_snippet_expand() {
        let snippet = Snippet::new(
            "Test".into(),
            "!test".into(),
            "Today is {date}".into(),
        );
        let expanded = snippet.expand(None);
        assert!(expanded.starts_with("Today is "));
    }
}
