<p align="center">
  <img src="https://ainto.app/logo-256.png" width="128" alt="Ainto Logo">
</p>

<h1 align="center">Ainto</h1>

<p align="center">
  <strong>A lightweight, open-source macOS launcher with built-in AI integration.</strong><br>
  <em>The Spotlight & Raycast alternative for engineers who keep it simple.</em>
</p>

<p align="center">
  <a href="https://ainto.app">Website</a> &middot;
  <a href="https://github.com/ainto-labs/ainto-app/issues">Issues</a> &middot;
  <a href="#features">Features</a> &middot;
  <a href="#build">Build</a>
</p>

---

## Features

| Feature | Description |
|---------|-------------|
| **App Search** | Fuzzy search and launch macOS apps instantly |
| **AI Chat** | Press Tab to chat with AI directly in the launcher |
| **AI Commands** | Select text → run Fix Grammar, Translate, Summarize, and more |
| **Clipboard History** | Persistent history with text, image, and file support |
| **Snippets** | Text expansion with dynamic placeholders (`{date}`, `{clipboard}`) |
| **Global Expansion** | Type a keyword in any app to auto-expand snippets |
| **Frecency Ranking** | Results improve over time based on your usage patterns |
| **Auto-Update** | Sparkle-based updates via GitHub Releases |

## Architecture

```
Swift (macOS App)                    Rust (Static Library)
├── AppKit lifecycle (NSApplication) ├── App Discovery (LSCopyAllApplicationURLs)
├── NSPanel (non-activating)         ├── Fuzzy Search Engine
├── CGEvent tap (hotkey + snippets)  ├── Clipboard Store (SQLite + xxhash)
├── NSPasteboard monitoring          ├── Snippet Manager (TOML)
├── NSStatusItem (tray)              ├── AI subprocess
├── Sparkle (auto-update)            ├── AI Commands (TOML)
├── SMAppService (launch at login)   ├── Frecency Ranking
│                                    └── Config Manager (TOML)
└──────── C ABI / FFI ──────────────┘
```

## Build

```bash
# Prerequisites: Rust toolchain + Xcode 15+

# Quick dev build (SPM)
make build

# Build and run
make run

# Build .app bundle (for testing Sparkle, app icon, launch at login)
make app

# Generate Xcode project (after editing project.yml)
make generate
```

## Config

All configuration lives in `~/.config/ainto/`:

| File | Purpose |
|------|---------|
| `config.toml` | General settings |
| `snippets.toml` | Snippet definitions |
| `ai-commands.toml` | Custom AI commands |
| `clipboard.db` | Clipboard history (SQLite) |
| `ranking.toml` | Frecency usage data |

## Requirements

- macOS 14.0+
- Xcode 15+
- Rust toolchain (`rustup`)
- xcodegen (`brew install xcodegen`) — for `.app` builds only

## License

MIT

---

<p align="center">
  Built by <a href="https://github.com/ainto-labs">Ainto Labs</a>
</p>
