#ifndef AINTO_CORE_H
#define AINTO_CORE_H

#include <stdint.h>
#include <stdbool.h>

// NOTE: All functions returning const char* allocate on the heap.
// Caller must free with rc_free_string() unless documented otherwise.

// ============================================================
// Config
// ============================================================

/// Load config, returns JSON string (caller must free with rc_free_string)
const char* rc_config_load(void);

/// Save config from JSON string, returns 0 on success
int32_t rc_config_save(const char* json);

// ============================================================
// App Discovery & Search
// ============================================================

/// Discover all installed apps, returns JSON array string
const char* rc_discover_apps(bool store_icons);

/// Search apps by query, returns JSON array string
const char* rc_search_apps(const char* query);

/// Get top-ranked (most used) apps, returns JSON array string
const char* rc_get_top_apps(uint64_t limit);

/// Increment ranking for any key (app path or "cmd:name"), returns new value
int32_t rc_increment_ranking(const char* key);

/// Get ranking for any key
int32_t rc_get_ranking(const char* key);

/// Update ranking for an app (called after launch)
void rc_update_ranking(const char* app_path);

// ============================================================
// Clipboard Store
// ============================================================

/// Initialize clipboard store, returns 0 on success
int32_t rc_clipboard_init(uint64_t max_items);

/// Insert text clipboard entry, returns entry ID or -1 on error
int64_t rc_clipboard_insert_text(const char* text, const char* source_app);

/// Insert image clipboard entry (PNG bytes), returns entry ID or -1 on error
int64_t rc_clipboard_insert_image(const uint8_t* png_data, uint64_t png_len,
                                   uint32_t width, uint32_t height,
                                   const char* source_app);

/// Insert file clipboard entry, returns entry ID or -1 on error
int64_t rc_clipboard_insert_file(const char* path, const char* source_app);

/// Get the clipboard image directory path
const char* rc_clipboard_image_dir(void);

/// Get recent clipboard entries as JSON array string
const char* rc_clipboard_get_recent(uint64_t limit);

/// Get recent clipboard entries with pagination
const char* rc_clipboard_get_recent_paged(uint64_t limit, uint64_t offset);

/// Search clipboard entries by text, returns JSON array string
const char* rc_clipboard_search(const char* query);

/// Search clipboard entries with pagination
const char* rc_clipboard_search_paged(const char* query, uint64_t limit, uint64_t offset);

/// Delete a clipboard entry by ID
int32_t rc_clipboard_delete(int64_t id);

/// Clear all entries
int32_t rc_clipboard_clear(void);

// ============================================================
// Snippets
// ============================================================

/// Load snippets, returns JSON array string
const char* rc_snippets_load(void);

/// Save snippets from JSON array string
int32_t rc_snippets_save(const char* json);

/// Expand a snippet's text with placeholders resolved
/// clipboard_text can be NULL
const char* rc_snippet_expand(const char* expansion_text, const char* clipboard_text);

// ============================================================
// AI Commands
// ============================================================

/// Load custom AI commands, returns JSON array string
const char* rc_ai_commands_load(void);

/// Save custom AI commands from JSON array string
int32_t rc_ai_commands_save(const char* json);

// ============================================================
// Claude Code
// ============================================================

/// Start a Claude session, returns session handle or NULL on error
/// resume_session_id can be NULL for new session
void* rc_claude_start(const char* query, const char* binary, const char* resume_session_id);

/// Get session ID (available after first chunk)
const char* rc_claude_get_session_id(void* session);

/// Read next chunk from Claude stream, returns text or NULL when done
const char* rc_claude_next_chunk(void* session);

/// Get accumulated response text
const char* rc_claude_get_response(void* session);

/// Get stderr output for error diagnosis
const char* rc_claude_get_stderr(void* session);

/// Cancel a running Claude session (kills child process, does not free memory)
void rc_claude_cancel(void* session);

/// Free a Claude session (call after reader thread has finished)
void rc_claude_free(void* session);

// ============================================================
// Memory Management
// ============================================================

/// Free a string allocated by Rust
void rc_free_string(const char* s);

#endif // AINTO_CORE_H
