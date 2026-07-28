//! Snippet management with TOML persistence and placeholder resolution.

use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

#[cfg(target_os = "macos")]
use std::os::unix::process::CommandExt;

use serde::{Deserialize, Serialize, Serializer};

use crate::Error;

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Snippet {
    pub id: String,
    pub name: String,
    #[serde(default = "default_mode")]
    pub mode: String,
    pub keyword: String,
    #[serde(default)]
    pub expansion: String,
    #[serde(default)]
    pub command: String,
}

fn default_mode() -> String {
    "text".into()
}

impl Serialize for Snippet {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        #[derive(Serialize)]
        struct SnippetWire<'a> {
            id: &'a str,
            name: &'a str,
            mode: &'a str,
            keyword: &'a str,
            #[serde(skip_serializing_if = "Option::is_none")]
            expansion: Option<&'a str>,
            #[serde(skip_serializing_if = "Option::is_none")]
            command: Option<&'a str>,
        }

        let shell = self.is_shell();
        SnippetWire {
            id: &self.id,
            name: &self.name,
            mode: &self.mode,
            keyword: &self.keyword,
            expansion: (!shell && !self.expansion.is_empty()).then_some(&self.expansion),
            command: (shell && !self.command.is_empty()).then_some(&self.command),
        }
        .serialize(serializer)
    }
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
            mode: default_mode(),
            command: String::new(),
        }
    }

    /// Get the expanded text with placeholders resolved.
    pub fn expand(&self, clipboard_text: Option<&str>) -> String {
        resolve_placeholders(&self.expansion, clipboard_text)
    }

    pub fn is_shell(&self) -> bool {
        self.mode.eq_ignore_ascii_case("shell")
    }
}

const SHELL_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_SHELL_OUTPUT: usize = 1024 * 1024;

/// Stop the shell and any descendants that inherited its stdout pipe.
fn cleanup_shell_process_group(child: &mut std::process::Child) {
    #[cfg(target_os = "macos")]
    {
        // `process_group(0)` makes the child the leader of a new process
        // group. A negative PID targets the whole group, including any
        // descendants that still hold stdout open.
        let process_group = child.id() as libc::pid_t;
        if process_group > 0 {
            unsafe {
                libc::kill(-process_group, libc::SIGKILL);
            }
        }
    }

    let _ = child.kill();
    let _ = child.wait();
}

/// Execute an explicitly configured shell snippet and return stdout.
/// Commands are resolved with the same placeholders as text snippets.
pub fn execute_shell(command: &str, clipboard_text: Option<&str>) -> Result<String, Error> {
    let command = resolve_shell_placeholders(command);
    if command.trim().is_empty() {
        return Err(Error::ShellExecution("shell command is empty".into()));
    }

    let mut shell = Command::new("/bin/zsh");
    shell
        .args(["-c", &command])
        .env("AINTO_SNIPPET_CLIPBOARD", clipboard_text.unwrap_or(""))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(target_os = "macos")]
    shell.process_group(0);

    let mut child = shell
        .spawn()
        .map_err(|e| Error::ShellExecution(e.to_string()))?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| Error::ShellExecution("stdout unavailable".into()))?;
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let mut limited = stdout.take((MAX_SHELL_OUTPUT + 1) as u64);
        let result = limited.read_to_end(&mut bytes);
        let _ = sender.send((result, bytes));
    });

    let deadline = Instant::now() + SHELL_TIMEOUT;
    loop {
        let status = match child.try_wait() {
            Ok(status) => status,
            Err(error) => {
                cleanup_shell_process_group(&mut child);
                return Err(Error::ShellExecution(error.to_string()));
            }
        };
        if let Some(status) = status {
            let (read_result, bytes) = match receiver.recv_timeout(Duration::from_millis(100)) {
                Ok(result) => result,
                Err(_) => {
                    cleanup_shell_process_group(&mut child);
                    return Err(Error::ShellExecution("failed to read stdout".into()));
                }
            };
            if read_result.is_err() {
                cleanup_shell_process_group(&mut child);
                return Err(Error::ShellExecution("failed to read stdout".into()));
            }
            if bytes.len() > MAX_SHELL_OUTPUT {
                return Err(Error::ShellExecution("stdout exceeds 1 MiB".into()));
            }
            if !status.success() {
                return Err(Error::ShellExecution(format!(
                    "command exited with {status}"
                )));
            }
            let output = String::from_utf8(bytes)
                .map_err(|_| Error::ShellExecution("stdout is not UTF-8".into()))?;
            return Ok(output.trim_end_matches(['\r', '\n']).to_string());
        }

        if Instant::now() >= deadline {
            cleanup_shell_process_group(&mut child);
            return Err(Error::ShellExecution(
                "command timed out after 3 seconds".into(),
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
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
    resolve_static_placeholders(text).replace("{clipboard}", clipboard_text.unwrap_or(""))
}

fn resolve_static_placeholders(text: &str) -> String {
    use std::time::SystemTime;

    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    // Use the host timezone so snippets match the user's macOS clock.
    let (year, month, day, hour, min, sec) = local_datetime(now as i64);

    let date_str = format!("{year:04}-{month:02}-{day:02}");
    let time_str = format!("{hour:02}:{min:02}:{sec:02}");

    text.replace("{date}", &date_str)
        .replace("{time}", &time_str)
        .replace("{uuid}", &uuid::Uuid::new_v4().to_string())
}

const SHELL_CLIPBOARD_VAR: &str = "\"$AINTO_SNIPPET_CLIPBOARD\"";

/// Resolve placeholders for shell commands without interpolating clipboard text
/// into zsh source. Clipboard data is passed through an environment variable;
/// single-quoted placeholders are rewritten with a safely quoted literal because
/// variables do not expand inside single quotes.
fn resolve_shell_placeholders(text: &str) -> String {
    let resolved = resolve_static_placeholders(text);
    let chars: Vec<char> = resolved.chars().collect();
    let placeholder: Vec<char> = "{clipboard}".chars().collect();
    let single_quote = 39 as char;
    // A parameter expansion inside double quotes is not reparsed as shell code.
    let quoted_clipboard = "\"$AINTO_SNIPPET_CLIPBOARD\"";

    let mut output = String::with_capacity(text.len());
    let mut quote: Option<char> = None;
    let mut escaped = false;
    let mut index = 0;

    while index < chars.len() {
        let ch = chars[index];

        if escaped {
            output.push(ch);
            escaped = false;
            index += 1;
            continue;
        }

        if ch == '\\' && quote != Some(single_quote) {
            output.push(ch);
            escaped = true;
            index += 1;
            continue;
        }

        if index + placeholder.len() <= chars.len()
            && chars[index..index + placeholder.len()] == placeholder[..]
        {
            if quote == Some(single_quote) {
                // Close the surrounding single quote, insert a shell-quoted
                // value, then reopen it so surrounding text remains quoted.
                output.push(single_quote);
                output.push_str(quoted_clipboard);
                output.push(single_quote);
            } else if quote == Some('"') {
                // The surrounding double quotes already protect expansion.
                output.push_str("$AINTO_SNIPPET_CLIPBOARD");
            } else {
                output.push_str(SHELL_CLIPBOARD_VAR);
            }
            index += placeholder.len();
            continue;
        }

        if ch == single_quote {
            if quote == Some(single_quote) {
                quote = None;
            } else if quote.is_none() {
                quote = Some(single_quote);
            }
        } else if ch == '"' {
            if quote == Some('"') {
                quote = None;
            } else if quote.is_none() {
                quote = Some('"');
            }
        }
        output.push(ch);
        index += 1;
    }

    output
}

/// Convert a Unix timestamp to local date/time without adding a date-time crate.
#[cfg(target_os = "macos")]
fn local_datetime(timestamp: i64) -> (i32, u32, u32, u32, u32, u32) {
    let mut tm = std::mem::MaybeUninit::<libc::tm>::zeroed();
    // `localtime_r` is not required to refresh the process timezone state.
    // Refresh it explicitly so runtime timezone changes are observed.
    unsafe extern "C" {
        fn tzset();
    }
    unsafe { tzset() };
    // `localtime_r` writes a fully initialized `tm` on success.
    let result = unsafe { libc::localtime_r(&timestamp, tm.as_mut_ptr()) };
    if result.is_null() {
        return unix_to_datetime_utc(timestamp);
    }
    let tm = unsafe { tm.assume_init() };
    (
        tm.tm_year + 1900,
        tm.tm_mon as u32 + 1,
        tm.tm_mday as u32,
        tm.tm_hour as u32,
        tm.tm_min as u32,
        tm.tm_sec as u32,
    )
}

#[cfg(not(target_os = "macos"))]
fn local_datetime(timestamp: i64) -> (i32, u32, u32, u32, u32, u32) {
    unix_to_datetime_utc(timestamp)
}

/// Minimal Unix timestamp conversion used as a portable fallback.
fn unix_to_datetime_utc(timestamp: i64) -> (i32, u32, u32, u32, u32, u32) {
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
    fn test_resolve_time_and_uuid_placeholders() {
        let result = resolve_placeholders("{time} {uuid}", None);
        let mut parts = result.split(' ');
        let time = parts.next().unwrap();
        let uuid = parts.next().unwrap();
        assert_eq!(time.len(), 8);
        assert!(time.as_bytes()[2] == b':' && time.as_bytes()[5] == b':');
        assert_eq!(uuid.len(), 36);
        assert_eq!(uuid.chars().filter(|c| *c == '-').count(), 4);
    }

    #[test]
    fn test_missing_clipboard_resolves_to_empty() {
        assert_eq!(
            resolve_placeholders("before{clipboard}after", None),
            "beforeafter"
        );
    }

    #[test]
    fn test_snippet_expand() {
        let snippet = Snippet::new("Test".into(), "!test".into(), "Today is {date}".into());
        let expanded = snippet.expand(None);
        assert!(expanded.starts_with("Today is "));
    }

    #[test]
    fn test_shell_command_output_is_trimmed() {
        let output = execute_shell("printf 'hello\\n'", None).unwrap();
        assert_eq!(output, "hello");
    }

    #[test]
    fn test_shell_command_resolves_placeholders() {
        let output = execute_shell("printf '%s' '{clipboard}'", Some("copied")).unwrap();
        assert_eq!(output, "copied");
    }

    #[test]
    fn test_shell_clipboard_is_not_reparsed_as_code() {
        let clipboard = "O'Reilly; $(printf injected) && echo compromised";
        let output = execute_shell("printf '%s' '{clipboard}'", Some(clipboard)).unwrap();
        assert_eq!(output, clipboard);
    }

    #[test]
    fn test_shell_clipboard_is_safe_inside_double_quotes() {
        let clipboard = "$(printf injected) 'quoted'";
        let output = execute_shell("printf '%s' \"{clipboard}\"", Some(clipboard)).unwrap();
        assert_eq!(output, clipboard);
    }

    #[test]
    fn test_shell_command_failure_is_not_output() {
        assert!(execute_shell("exit 7", None).is_err());
    }

    #[test]
    fn test_empty_shell_command_is_rejected() {
        let error = execute_shell("  \n\t", None).unwrap_err();
        assert!(error.to_string().contains("shell command is empty"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn test_shell_timeout_kills_descendant_processes() {
        let marker = std::env::temp_dir().join(format!(
            "ainto-shell-timeout-{}.marker",
            uuid::Uuid::new_v4()
        ));
        let quoted_marker = format!("'{}'", marker.to_string_lossy().replace('\'', "'\"'\"'"));
        let command = format!("(sleep 4; : > {quoted_marker}) & wait");

        let error = execute_shell(&command, None).unwrap_err();
        assert!(error.to_string().contains("timed out after 3 seconds"));

        // Without process-group cleanup, the descendant would still run and
        // create the marker after the parent zsh has timed out.
        std::thread::sleep(Duration::from_secs(2));
        assert!(!marker.exists());
        let _ = std::fs::remove_file(marker);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn test_shell_stdout_failure_kills_descendant_processes() {
        let marker = std::env::temp_dir().join(format!(
            "ainto-shell-stdout-failure-{}.marker",
            uuid::Uuid::new_v4()
        ));
        let quoted_marker = format!("'{}'", marker.to_string_lossy().replace('\'', "'\"'\"'"));
        let command = format!("(sleep 1; : > {quoted_marker}) & exit 0");

        let error = execute_shell(&command, None).unwrap_err();
        assert!(error.to_string().contains("failed to read stdout"));

        // The descendant inherited stdout after the parent shell exited. It
        // must still be killed when stdout collection fails or times out.
        std::thread::sleep(Duration::from_secs(2));
        assert!(!marker.exists());
        let _ = std::fs::remove_file(marker);
    }

    #[test]
    fn test_legacy_snippet_defaults_to_text_mode() {
        let snippet: Snippet = toml::from_str(
            r#"
            id = "legacy"
            name = "Legacy"
            keyword = ";legacy"
            expansion = "hello"
            "#,
        )
        .unwrap();
        assert_eq!(snippet.mode, "text");
        assert!(snippet.command.is_empty());
    }

    #[test]
    fn test_mode_specific_toml_fields() {
        let text = Snippet::new("Text".into(), ";text".into(), "hello".into());
        let text_toml = toml::to_string(&text).unwrap();
        assert!(text_toml.contains("mode = \"text\""));
        assert!(text_toml.contains("expansion = \"hello\""));
        assert!(!text_toml.contains("command ="));

        let shell = Snippet {
            id: "shell".into(),
            name: "Shell".into(),
            mode: "shell".into(),
            keyword: ";shell".into(),
            expansion: "ignored".into(),
            command: "printf ok".into(),
        };
        let shell_toml = toml::to_string(&shell).unwrap();
        assert!(shell_toml.contains("mode = \"shell\""));
        assert!(shell_toml.contains("command = \"printf ok\""));
        assert!(!shell_toml.contains("expansion ="));
        assert!(shell_toml.find("name =").unwrap() < shell_toml.find("mode =").unwrap());
    }

    #[test]
    fn test_mode_specific_records_without_empty_fields_load() {
        let file: SnippetFile = toml::from_str(
            r#"
            [[snippets]]
            id = "text"
            name = "ok"
            mode = "text"
            keyword = ";ok"
            expansion = "test"

            [[snippets]]
            id = "shell"
            name = "branch"
            mode = "shell"
            keyword = ";branch"
            command = "printf main"
            "#,
        )
        .unwrap();
        assert_eq!(file.snippets.len(), 2);
        assert_eq!(file.snippets[0].expansion, "test");
        assert!(file.snippets[0].command.is_empty());
        assert!(file.snippets[1].expansion.is_empty());
        assert_eq!(file.snippets[1].command, "printf main");
    }
}
