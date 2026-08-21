//! Global launcher aliases with TOML persistence.

use std::collections::HashSet;
use std::path::Path;

use serde::{Deserialize, Serialize};
use unicode_casefold::UnicodeCaseFold;
use unicode_normalization::UnicodeNormalization;

use crate::Error;

#[derive(Deserialize, Serialize)]
#[derive(Debug, Clone)]
pub struct AliasEntry {
    pub alias: String,
    pub target_type: String,
    pub target_id: String,
}

#[derive(Deserialize, Serialize)]
#[derive(Debug, Clone, Default)]
struct AliasFile {
    #[serde(default)]
    aliases: Vec<AliasEntry>,
}

/// Normalize aliases for exact, Unicode-aware, case-insensitive matching.
pub fn normalize_alias(value: &str) -> String {
    value.trim().nfkc().case_fold().nfkc().collect()
}

pub fn validate_aliases(aliases: &[AliasEntry]) -> Result<(), String> {
    let mut seen = HashSet::new();
    for entry in aliases {
        let normalized = normalize_alias(&entry.alias);
        if normalized.is_empty() {
            return Err("Alias cannot be empty".into());
        }
        let valid_target_type = matches!(
            entry.target_type.as_str(),
            "app" | "ai_command" | "snippet" | "launcher_command" | "system_action"
        );
        if !valid_target_type || entry.target_id.trim().is_empty() {
            return Err(format!("Alias '{}' has an invalid target", entry.alias));
        }
        if !seen.insert(normalized) {
            return Err(format!("Alias '{}' is already in use", entry.alias.trim()));
        }
    }
    Ok(())
}

pub fn load_aliases(path: &Path) -> Result<Vec<AliasEntry>, Error> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let content = std::fs::read_to_string(path)?;
    let file: AliasFile = toml::from_str(&content)?;
    validate_aliases(&file.aliases).map_err(Error::InvalidAliases)?;
    Ok(file.aliases)
}

pub fn save_aliases(path: &Path, aliases: &[AliasEntry]) -> Result<(), String> {
    validate_aliases(aliases)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let content = toml::to_string_pretty(&AliasFile {
        aliases: aliases.to_vec(),
    })
    .map_err(|e| e.to_string())?;
    let temporary = path.with_extension("toml.tmp");
    std::fs::write(&temporary, content).map_err(|e| e.to_string())?;
    std::fs::rename(&temporary, path).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(alias: &str) -> AliasEntry {
        AliasEntry {
            alias: alias.into(),
            target_type: "system_action".into(),
            target_id: "sleep".into(),
        }
    }

    #[test]
    fn normalization_is_trimmed_and_case_insensitive() {
        assert_eq!(normalize_alias("  TC  "), "tc");
    }

    #[test]
    fn duplicate_aliases_are_rejected_case_insensitively() {
        let error = validate_aliases(&[entry("tc"), entry(" TC ")]).unwrap_err();
        assert!(error.contains("already in use"));
    }

    #[test]
    fn duplicate_aliases_are_rejected_with_full_unicode_case_folding() {
        let error = validate_aliases(&[entry("straße"), entry("STRASSE")]).unwrap_err();
        assert!(error.contains("already in use"));
    }

    #[test]
    fn duplicate_aliases_are_rejected_across_unicode_normalization_forms() {
        let error = validate_aliases(&[entry("café"), entry("cafe\u{301}")]).unwrap_err();
        assert!(error.contains("already in use"));
    }

    #[test]
    fn empty_alias_is_rejected() {
        assert!(validate_aliases(&[entry("  ")]).is_err());
    }
}
