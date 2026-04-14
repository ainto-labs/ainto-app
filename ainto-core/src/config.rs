//! Configuration management.
//!
//! Reads/writes TOML config at `~/.config/ainto/config.toml`.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::Error;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct Config {
    pub clipboard_max_items: usize,
    pub clipboard_max_image_items: usize,
    pub search_dirs: Vec<String>,
    pub debounce_delay: u64,
    pub claude_binary: String,
    pub claude_enabled: bool,
    pub snippets_enabled: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            clipboard_max_items: 200,
            clipboard_max_image_items: 50,
            search_dirs: vec!["~".to_string()],
            debounce_delay: 300,
            claude_binary: "claude".to_string(),
            claude_enabled: true,
            snippets_enabled: true,
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

/// Expand `~` in a path string to the home directory.
pub fn expand_tilde(path: &str) -> PathBuf {
    if let Some(rest) = path.strip_prefix('~') {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest.strip_prefix('/').unwrap_or(rest));
        }
    }
    Path::new(path).to_path_buf()
}
