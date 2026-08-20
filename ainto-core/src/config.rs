//! Configuration management.
//!
//! Reads/writes TOML config at `~/.config/ainto/config.toml`.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::Error;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct Config {
    pub clipboard_max_items: usize,
    pub clipboard_max_image_items: usize,
    pub claude_binary: String,
    pub snippets_enabled: bool,
    /// Master switch for all AI-related features in the UI.
    /// When false, the launcher hides every AI surface.
    pub ai_enabled: bool,
    /// Spotlight folders used by File Search. Empty values are ignored.
    pub file_search_paths: Vec<String>,
    /// Search the entire local Spotlight index instead of selected folders.
    pub file_search_all_locations: bool,
    /// Include hidden Spotlight results.
    pub file_search_include_hidden: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            clipboard_max_items: 200,
            clipboard_max_image_items: 50,
            claude_binary: "claude".to_string(),
            snippets_enabled: true,
            ai_enabled: true,
            file_search_paths: dirs::home_dir()
                .map(|path| vec![path.to_string_lossy().into_owned()])
                .unwrap_or_default(),
            file_search_all_locations: false,
            file_search_include_hidden: false,
        }
    }
}

impl Config {
    /// Load config from the default path, creating with defaults if missing.
    pub fn load() -> Result<Self, Error> {
        let path = Self::default_path()?;
        if path.exists() {
            let content = std::fs::read_to_string(&path)?;
            let config: Config = toml::from_str(&content)?;
            Ok(config)
        } else {
            let config = Config::default();
            config.save()?;
            Ok(config)
        }
    }

    /// Save config to the default path.
    pub fn save(&self) -> Result<(), Error> {
        let path = Self::default_path()?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = toml::to_string_pretty(self)?;
        std::fs::write(path, content)?;
        Ok(())
    }

    /// Default config file path: `~/.config/ainto/config.toml`
    pub fn default_path() -> Result<PathBuf, Error> {
        config_dir().map(|d| d.join("config.toml"))
    }
}

/// Returns the ainto config directory: `~/.config/ainto/`
pub fn config_dir() -> Result<PathBuf, Error> {
    let home = dirs::home_dir().ok_or(Error::NoHomeDir)?;
    Ok(home.join(".config").join("ainto"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_config_receives_file_search_defaults() {
        let config: Config = toml::from_str(
            r#"
clipboard_max_items = 100
clipboard_max_image_items = 25
claude_binary = "claude"
snippets_enabled = true
ai_enabled = true
"#,
        )
        .unwrap();

        assert!(!config.file_search_all_locations);
        assert!(!config.file_search_include_hidden);
        assert_eq!(
            config.file_search_paths,
            Config::default().file_search_paths
        );
    }

    #[test]
    fn file_search_settings_round_trip() {
        let config = Config {
            file_search_paths: vec!["/Users/example/Documents".into()],
            file_search_all_locations: true,
            file_search_include_hidden: true,
            ..Config::default()
        };
        let encoded = toml::to_string(&config).unwrap();
        let decoded: Config = toml::from_str(&encoded).unwrap();
        assert_eq!(decoded, config);
    }
}
