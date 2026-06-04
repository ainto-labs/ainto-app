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

<p align="center">
  English &middot; <a href="README.zh-TW.md">正體中文</a>
</p>

---

## Features

| Feature | Description |
|---------|-------------|
| **AI** | Press Tab to chat, or select text → run & replace (Fix Grammar, Translate, Summarize, or your own) |
| **App Search** | Fuzzy search and launch macOS apps instantly |
| **Clipboard History** | Persistent history with text, image, and file support |
| **Snippets** | Text expansion in any app with dynamic placeholders (`{date}`, `{clipboard}`) |

> **AI & billing:** Ainto runs the Claude Code CLI on your Mac (`claude -p`), so AI usage is billed to your own Claude account — Ainto stores no API key and never charges you. See [how Claude meters Agent SDK / `claude -p` usage](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan).

## Under the hood

Ainto is a native macOS app: an AppKit + SwiftUI front end over a Rust core, bridged through a C ABI. No Electron, no web view.

```mermaid
flowchart TD
    User([User]) -->|global hotkey| HK["Global hotkey (Carbon)"]
    User -->|snippet keyword| Tap["CGEvent tap"]

    subgraph FE["Front end — AppKit + SwiftUI"]
        HK --> Panel["Non-activating NSPanel"]
        Panel --> Views["Search / Clipboard / Snippets / AI views"]
        Views --> Table["NSTableView (cell reuse)"]
        Tap --> Expand["Inline snippet expansion"]
    end

    Views <-->|"C ABI / FFI"| Core
    Expand -->|reads snippets| Snip

    subgraph Core["Rust core — static library"]
        Disc["App discovery"]
        Search["Fuzzy search"]
        Rank["Frecency ranking"]
        Clip["Clipboard store"]
        Snip["Snippets"]
        AICmd["AI commands"]
    end

    Disc -->|Launch Services| OS["macOS"]
    Clip --> DB[("SQLite — clipboard.db")]
    Clip --> Img[["Images on disk"]]
    Snip --> Cfg[("TOML config")]
    Rank --> Cfg
    AICmd --> CC["Claude Code (CLI)"]
```

- **Rust core.** App discovery, fuzzy search, frecency ranking, the clipboard store, snippet expansion, and AI commands all live in a single Rust static library linked into the app.
- **App discovery.** Apps are enumerated through Launch Services, then ordered by a frecency model (recency × frequency) so your most-used apps surface first.
- **Clipboard store.** Backed by SQLite. Images are written to disk and referenced by path rather than stored in the database, and every entry is deduplicated with an XXH3 content hash. Text and images keep independent retention limits, so heavy text copying never evicts your image history.
- **Clipboard list.** An `NSTableView` with cell reuse, fed by paginated and debounced SQLite queries — the list scrolls and searches smoothly however large the history grows.
- **Input.** A non-activating `NSPanel` that never steals focus from the app you're in. The global hotkey is a registered system hotkey, while inline snippet expansion is driven by a `CGEvent` tap that watches your keystrokes in any app.
- **Local-first.** Everything lives under `~/.config/ainto/` — SQLite for clipboard history, TOML for config, snippets, AI commands, and rankings. No telemetry.
- **Updates.** Builds are signed, notarized, and delivered over [Sparkle](https://sparkle-project.org/).

## Build

```bash
# Quick dev build
./build.sh

# Full build, run, and more
make help
```

## Requirements

- macOS 14.0+
- Xcode 15+
- Rust toolchain (`rustup`)

## License

[GPL-3.0-or-later](LICENSE) — Ainto is free software: any fork or derivative must remain open-source under the same license.

---

<p align="center">
  Built by <a href="https://github.com/ainto-labs">Ainto Labs</a>
</p>
