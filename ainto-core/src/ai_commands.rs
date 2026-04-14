//! Custom AI command management with TOML persistence.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::Error;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct AiCommand {
    pub name: String,
    pub icon: Option<String>,
    pub prompt: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct AiCommandFile {
    #[serde(default)]
    pub commands: Vec<AiCommand>,
}

/// Load AI commands from a TOML file.
/// If file doesn't exist, creates it with default built-in commands.
pub fn load_commands(path: &Path) -> Result<Vec<AiCommand>, Error> {
    if !path.exists() {
        let defaults = default_commands();
        save_commands(path, &defaults)?;
        return Ok(defaults);
    }
    let content = std::fs::read_to_string(path)?;
    let file: AiCommandFile = toml::from_str(&content)?;
    Ok(file.commands)
}

const SYS: &str = "IMPORTANT: Output ONLY the result text. No explanations, no preamble, no comments, no markdown formatting. Just the raw transformed text.";

fn default_commands() -> Vec<AiCommand> {
    vec![
        AiCommand {
            name: "Fix Spelling & Grammar".into(),
            icon: Some("text.badge.checkmark".into()),
            prompt: format!("{SYS}\n\nFix the spelling and grammar of the following text:\n\n{{selection}}"),
        },
        AiCommand {
            name: "Improve Writing".into(),
            icon: Some("text.badge.star".into()),
            prompt: format!("{SYS}\n\nImprove the writing quality. Make it clearer and more professional:\n\n{{selection}}"),
        },
        AiCommand {
            name: "Make Shorter".into(),
            icon: Some("arrow.down.right.and.arrow.up.left".into()),
            prompt: format!("{SYS}\n\nMake the following text more concise while keeping the meaning:\n\n{{selection}}"),
        },
        AiCommand {
            name: "Make Longer".into(),
            icon: Some("arrow.up.left.and.arrow.down.right".into()),
            prompt: format!("{SYS}\n\nExpand and elaborate on the following text:\n\n{{selection}}"),
        },
        AiCommand {
            name: "Change Tone to Professional".into(),
            icon: Some("briefcase".into()),
            prompt: format!("{SYS}\n\nRewrite the following text in a professional tone:\n\n{{selection}}"),
        },
        AiCommand {
            name: "Change Tone to Casual".into(),
            icon: Some("face.smiling".into()),
            prompt: format!("{SYS}\n\nRewrite the following text in a casual, friendly tone:\n\n{{selection}}"),
        },
        AiCommand {
            name: "Translate to English".into(),
            icon: Some("globe".into()),
            prompt: format!("{SYS}\n\nTranslate the following text to English:\n\n{{selection}}"),
        },
        AiCommand {
            name: "Translate to Traditional Chinese".into(),
            icon: Some("globe.asia.australia".into()),
            prompt: format!("{SYS}\n\nTranslate the following text to Traditional Chinese (繁體中文):\n\n{{selection}}"),
        },
        AiCommand {
            name: "Explain This".into(),
            icon: Some("questionmark.circle".into()),
            prompt: "Explain the following text or code in simple terms:\n\n{selection}".into(),
        },
        AiCommand {
            name: "Summarize".into(),
            icon: Some("doc.plaintext".into()),
            prompt: "Summarize the following text concisely:\n\n{selection}".into(),
        },
    ]
}

/// Save AI commands to a TOML file.
pub fn save_commands(path: &Path, commands: &[AiCommand]) -> Result<(), Error> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let file = AiCommandFile {
        commands: commands.to_vec(),
    };
    let content = toml::to_string_pretty(&file)?;
    std::fs::write(path, content)?;
    Ok(())
}
