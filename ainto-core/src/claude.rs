//! Claude Code subprocess management.
//!
//! Spawns `claude -p "<query>" --output-format stream-json` and parses streaming output.
//! Uses std::process (synchronous blocking IO) — called from a background thread on the Swift side.

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};

use crate::Error;

/// A streaming Claude Code session (synchronous/blocking).
pub struct ClaudeSession {
    child: Child,
    reader: BufReader<std::process::ChildStdout>,
    pub response: String,
    pub is_streaming: bool,
    pub session_id: Option<String>,
}

impl ClaudeSession {
    /// Start a new Claude session, or resume an existing one.
    pub fn start(query: &str, binary: &str, resume_session_id: Option<&str>) -> Result<Self, Error> {
        // Validate binary name: reject empty strings and dangerous characters
        if binary.is_empty() {
            return Err(Error::ClaudeSpawn("claude_binary must not be empty".into()));
        }
        if !binary
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '-' | '/' | '.' | '_'))
        {
            return Err(Error::ClaudeSpawn(format!(
                "claude_binary contains invalid characters: {binary:?}. Only alphanumeric, hyphens, slashes, dots, and underscores are allowed."
            )));
        }
        if binary.contains("..") {
            return Err(Error::ClaudeSpawn(
                "claude_binary must not contain '..' path traversal".into(),
            ));
        }

        let resolved_binary = if binary.starts_with('/') {
            binary.to_string()
        } else {
            resolve_binary_path(binary)
        };

        let path_env = std::env::var("PATH").unwrap_or_default();
        let home = std::env::var("HOME").unwrap_or_default();
        let extended_path = format!(
            "{home}/.local/bin:/usr/local/bin:/opt/homebrew/bin:{path_env}"
        );

        let mut cmd = Command::new(&resolved_binary);
        cmd.arg("-p")
            .arg(query)
            .arg("--output-format")
            .arg("stream-json")
            .arg("--verbose");

        // Resume existing session for multi-turn conversation
        if let Some(sid) = resume_session_id {
            // Validate session ID format (UUID-like: hex + hyphens)
            if !sid.chars().all(|c| c.is_ascii_hexdigit() || c == '-') || sid.is_empty() {
                return Err(Error::ClaudeSpawn(format!("invalid session ID: {sid:?}")));
            }
            cmd.arg("--resume").arg(sid);
        }

        let mut child = cmd
            .env("PATH", &extended_path)
            .env("HOME", &home)
            .current_dir(&home)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(Stdio::null())
            .spawn()
            .map_err(|e| Error::ClaudeSpawn(e.to_string()))?;

        let stdout = child.stdout.take().ok_or(Error::ClaudeSpawn(
            "failed to capture stdout".to_string(),
        ))?;

        Ok(Self {
            child,
            reader: BufReader::new(stdout),
            response: String::new(),
            is_streaming: true,
            session_id: None,
        })
    }

    /// Read the next text chunk from the Claude stream (blocking).
    /// Returns `None` when the stream is finished.
    pub fn next_chunk(&mut self) -> Option<String> {
        if !self.is_streaming {
            return None;
        }

        loop {
            let mut line = String::new();
            match self.reader.read_line(&mut line) {
                Ok(0) => {
                    self.is_streaming = false;
                    return None;
                }
                Ok(_) => {
                    // Try to extract session_id from init event
                    if self.session_id.is_none() {
                        if let Some(sid) = extract_session_id(&line) {
                            self.session_id = Some(sid);
                        }
                    }
                    if let Some(text) = extract_text_from_stream_json(&line) {
                        self.response.push_str(&text);
                        return Some(text);
                    }
                    // Non-text event, read next line
                    continue;
                }
                Err(_) => {
                    self.is_streaming = false;
                    return None;
                }
            }
        }
    }

    /// Get error info — reads stderr and checks exit code.
    pub fn get_error(&mut self) -> String {
        // Read all stderr
        let stderr_text = if let Some(stderr) = self.child.stderr.take() {
            let reader = BufReader::new(stderr);
            reader.lines().filter_map(|l| l.ok()).collect::<Vec<_>>().join("\n")
        } else {
            String::new()
        };

        // Check exit status
        let exit_info = match self.child.try_wait() {
            Ok(Some(status)) => {
                if status.success() {
                    String::new()
                } else {
                    format!("Process exited with {status}")
                }
            }
            Ok(None) => "Process still running".into(),
            Err(e) => format!("Could not check process: {e}"),
        };

        let mut parts = Vec::new();
        if !stderr_text.is_empty() {
            parts.push(stderr_text);
        }
        if !exit_info.is_empty() {
            parts.push(exit_info);
        }
        if parts.is_empty() {
            "Claude process ended without output. Possible rate limit or connection issue.".into()
        } else {
            parts.join("\n")
        }
    }

    /// Cancel the running session.
    pub fn cancel(&mut self) {
        self.is_streaming = false;
        let _ = self.child.kill();
    }
}

impl Drop for ClaudeSession {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Extract session_id from the init system event.
fn extract_session_id(line: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
    if v.get("type")?.as_str()? == "system" {
        return v.get("session_id")?.as_str().map(|s| s.to_string());
    }
    None
}

/// Try to find the binary in common locations.
fn resolve_binary_path(name: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = [
        format!("{home}/.local/bin/{name}"),
        format!("/usr/local/bin/{name}"),
        format!("/opt/homebrew/bin/{name}"),
    ];
    for path in &candidates {
        if std::path::Path::new(path).exists() {
            return path.clone();
        }
    }
    // Fallback to bare name, hope it's in PATH
    name.to_string()
}

/// Extract text content from a stream-json line.
///
/// Claude CLI stream-json format (with --verbose):
/// - `{"type":"assistant","message":{"content":[{"type":"text","text":"..."}],...}}`
/// - `{"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}`
/// - `{"type":"result","result":"...","subtype":"success",...}`
fn extract_text_from_stream_json(line: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(line.trim()).ok()?;

    match v.get("type")?.as_str()? {
        // Streaming delta (if Claude uses this format)
        "content_block_delta" => {
            let delta = v.get("delta")?;
            if delta.get("type")?.as_str()? == "text_delta" {
                return delta.get("text")?.as_str().map(|s| s.to_string());
            }
            None
        }
        // Full assistant message (Claude CLI --verbose format)
        "assistant" => {
            let content = v.get("message")?.get("content")?.as_array()?;
            let text: String = content
                .iter()
                .filter_map(|b| {
                    if b.get("type")?.as_str()? == "text" {
                        b.get("text")?.as_str().map(|s| s.to_string())
                    } else {
                        None
                    }
                })
                .collect::<Vec<_>>()
                .join("");
            if text.is_empty() { None } else { Some(text) }
        }
        // Final result — skip since "assistant" already has the text
        "result" => None,
        _ => None,
    }
}
