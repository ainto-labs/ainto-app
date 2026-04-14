//! ainto-core: Core logic for AintoApp (macOS launcher)
//!
//! This crate compiles to a static library (.a) linked into the Swift frontend via C ABI FFI.

pub mod ai_commands;
pub mod clipboard_store;
pub mod claude;
pub mod config;
pub mod discovery;
pub mod ffi;
pub mod ranking;
pub mod search;
pub mod snippets;

/// Unified error type for ainto-core.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    #[error("TOML deserialize error: {0}")]
    TomlDeserialize(#[from] toml::de::Error),

    #[error("TOML serialize error: {0}")]
    TomlSerialize(#[from] toml::ser::Error),

    #[error("Image encode error")]
    ImageEncode,

    #[error("Image error: {0}")]
    Image(#[from] image::ImageError),

    #[error("HOME directory not found")]
    NoHomeDir,

    #[error("Claude spawn error: {0}")]
    ClaudeSpawn(String),
}
