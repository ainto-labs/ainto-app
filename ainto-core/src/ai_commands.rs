//! Custom AI command management with TOML persistence.

use std::collections::HashSet;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::Error;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AiCommand {
    #[serde(default)]
    pub id: String,
    pub name: String,
    pub icon: Option<String>,
    pub prompt: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct AiCommandFile {
    #[serde(default)]
    pub commands: Vec<AiCommand>,
}

/// Load AI commands from a TOML file. Missing or duplicate IDs from older
/// versions are migrated once and persisted so aliases survive command renames.
pub fn load_commands(path: &Path) -> Result<Vec<AiCommand>, Error> {
    if !path.exists() {
        let defaults = default_commands();
        save_commands(path, &defaults)?;
        return Ok(defaults);
    }
    let content = std::fs::read_to_string(path)?;
    let file: AiCommandFile = toml::from_str(&content)?;
    let (commands, migrated) = ensure_stable_ids(file.commands);
    if migrated {
        save_commands(path, &commands)?;
    }
    Ok(commands)
}

fn ensure_stable_ids(mut commands: Vec<AiCommand>) -> (Vec<AiCommand>, bool) {
    let mut seen = HashSet::new();
    let mut migrated = false;
    for command in &mut commands {
        if command.id.trim().is_empty() || !seen.insert(command.id.clone()) {
            command.id = uuid::Uuid::new_v4().to_string();
            seen.insert(command.id.clone());
            migrated = true;
        }
    }
    (commands, migrated)
}

const SYS: &str = "IMPORTANT: Output ONLY the result text. No explanations, no preamble, no comments, no markdown formatting. Just the raw transformed text.";

fn default_commands() -> Vec<AiCommand> {
    let commands = [
        command(
            "builtin-fix-spelling-grammar",
            "Fix Spelling & Grammar",
            "text.badge.checkmark",
            format!(
                "{SYS}\n\nFix the spelling and grammar of the following text:\n\n{{selection}}"
            ),
        ),
        command(
            "builtin-improve-writing",
            "Improve Writing",
            "text.badge.star",
            format!(
                "{SYS}\n\nImprove the writing quality. Make it clearer and more professional:\n\n{{selection}}"
            ),
        ),
        command(
            "builtin-make-shorter",
            "Make Shorter",
            "arrow.down.right.and.arrow.up.left",
            format!(
                "{SYS}\n\nMake the following text more concise while keeping the meaning:\n\n{{selection}}"
            ),
        ),
        command(
            "builtin-make-longer",
            "Make Longer",
            "arrow.up.left.and.arrow.down.right",
            format!("{SYS}\n\nExpand and elaborate on the following text:\n\n{{selection}}"),
        ),
        command(
            "builtin-tone-professional",
            "Change Tone to Professional",
            "briefcase",
            format!("{SYS}\n\nRewrite the following text in a professional tone:\n\n{{selection}}"),
        ),
        command(
            "builtin-tone-casual",
            "Change Tone to Casual",
            "face.smiling",
            format!(
                "{SYS}\n\nRewrite the following text in a casual, friendly tone:\n\n{{selection}}"
            ),
        ),
        command(
            "builtin-translate-english",
            "Translate to English",
            "globe",
            format!("{SYS}\n\nTranslate the following text to English:\n\n{{selection}}"),
        ),
        command(
            "builtin-translate-traditional-chinese",
            "Translate to Traditional Chinese",
            "globe.asia.australia",
            format!(
                "{SYS}\n\nTranslate the following text to Traditional Chinese (繁體中文):\n\n{{selection}}"
            ),
        ),
        command(
            "builtin-explain",
            "Explain This",
            "questionmark.circle",
            "Explain the following text or code in simple terms:\n\n{selection}".into(),
        ),
        command(
            "builtin-summarize",
            "Summarize",
            "doc.plaintext",
            "Summarize the following text concisely:\n\n{selection}".into(),
        ),
    ];
    commands.into_iter().collect()
}

fn command(id: &str, name: &str, icon: &str, prompt: String) -> AiCommand {
    AiCommand {
        id: id.into(),
        name: name.into(),
        icon: Some(icon.into()),
        prompt,
    }
}

/// Save AI commands atomically.
pub fn save_commands(path: &Path, commands: &[AiCommand]) -> Result<(), Error> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let file = AiCommandFile {
        commands: commands.to_vec(),
    };
    let content = toml::to_string_pretty(&file)?;
    let temporary = path.with_extension("toml.tmp");
    std::fs::write(&temporary, content)?;
    std::fs::rename(temporary, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrates_missing_and_duplicate_ids() {
        let commands = vec![
            command("", "One", "sparkle", "one".into()),
            command("same", "Two", "sparkle", "two".into()),
            command("same", "Three", "sparkle", "three".into()),
        ];
        let (migrated, changed) = ensure_stable_ids(commands);
        assert!(changed);
        assert!(migrated.iter().all(|command| !command.id.is_empty()));
        assert_eq!(
            migrated
                .iter()
                .map(|command| &command.id)
                .collect::<HashSet<_>>()
                .len(),
            3
        );
    }

    #[test]
    fn preserves_existing_unique_ids() {
        let commands = vec![command("stable", "Renamed", "sparkle", "prompt".into())];
        let (migrated, changed) = ensure_stable_ids(commands);
        assert!(!changed);
        assert_eq!(migrated[0].id, "stable");
    }

    #[test]
    fn loading_legacy_toml_persists_the_generated_id() {
        let path = std::env::temp_dir().join(format!(
            "ainto-ai-command-migration-{}.toml",
            uuid::Uuid::new_v4()
        ));
        std::fs::write(
            &path,
            "[[commands]]\nname = \"Legacy\"\nicon = \"sparkle\"\nprompt = \"{selection}\"\n",
        )
        .unwrap();

        let first = load_commands(&path).unwrap();
        let second = load_commands(&path).unwrap();
        assert!(!first[0].id.is_empty());
        assert_eq!(first[0].id, second[0].id);

        let _ = std::fs::remove_file(path);
    }
}
