<p align="center">
  <img src="https://ainto.app/logo-256.png" width="128" alt="Ainto Logo">
</p>

<h1 align="center">Ainto</h1>

<p align="center">
  <strong>輕量、開源、內建 AI 整合的 macOS 啟動器。</strong><br>
  <em>為喜歡保持簡單的工程師打造的 Spotlight 與 Raycast 替代方案。</em>
</p>

<p align="center">
  <a href="https://ainto.app">官網</a> &middot;
  <a href="https://github.com/ainto-labs/ainto-app/issues">問題回報</a> &middot;
  <a href="#功能">功能</a> &middot;
  <a href="#建置">建置</a>
</p>

<p align="center">
  <a href="README.md">English</a> &middot; 正體中文
</p>

---

## 功能

| 功能 | 說明 |
|------|------|
| **AI** | 按 Tab 開始對話，或選取文字後執行並取代（修正文法、翻譯、摘要，或自訂指令） |
| **應用程式搜尋** | 模糊搜尋並即時啟動 macOS 應用程式 |
| **剪貼簿歷史** | 持久化的歷史記錄，支援文字、圖片與檔案 |
| **文字片段** | 在任何 app 中展開文字，支援動態佔位符（`{date}`、`{clipboard}`） |

> **AI 與計費：** Ainto 透過你 Mac 上的 Claude Code（`claude -p`）執行 AI，用量計入你自己的 Claude 帳號。Ainto 不儲存 API key，也不向你收費。計費方式請見 [Claude 對 Agent SDK 與 `claude -p` 用量的說明](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)。

## 技術架構

Ainto 是一個原生 macOS 應用程式，以 AppKit + SwiftUI 為前端，底層是 Rust 核心，兩者透過 C ABI 橋接。沒有 Electron，也沒有 web view。

```mermaid
flowchart TD
    User([使用者]) -->|全域快速鍵| HK["全域快速鍵（Carbon）"]
    User -->|片段關鍵字| Tap["CGEvent tap"]

    subgraph FE["前端 — AppKit + SwiftUI"]
        HK --> Panel["非啟動式 NSPanel"]
        Panel --> Views["搜尋 / 剪貼簿 / 片段 / AI 畫面"]
        Views --> Table["NSTableView（cell 重用）"]
        Tap --> Expand["行內文字片段展開"]
    end

    Views <-->|"C ABI / FFI"| Core
    Expand -->|讀取片段| Snip

    subgraph Core["Rust 核心 — 靜態函式庫"]
        Disc["應用程式探索"]
        Search["模糊搜尋"]
        Rank["frecency 排序"]
        Clip["剪貼簿儲存"]
        Snip["文字片段"]
        AICmd["AI 指令"]
    end

    Disc -->|Launch Services| OS["macOS"]
    Clip --> DB[("SQLite — clipboard.db")]
    Clip --> Img[["磁碟上的圖片"]]
    Snip --> Cfg[("TOML 設定")]
    Rank --> Cfg
    AICmd --> CC["Claude Code (CLI)"]
```

- **Rust 核心。** 應用程式探索、模糊搜尋、frecency 排序、剪貼簿儲存、文字片段展開與 AI 指令，全部位於一個連結進 app 的 Rust 靜態函式庫中。
- **應用程式探索。** 透過 Launch Services 列舉應用程式，再以 frecency 模型（最近使用乘以使用頻率）排序，讓最常用的 app 優先出現。
- **剪貼簿儲存。** 以 SQLite 為後端。圖片寫入磁碟並以路徑引用，而非存進資料庫；每一筆都以 XXH3 內容雜湊去除重複。文字與圖片各有獨立的保留上限，因此大量複製文字不會擠掉圖片歷史。
- **剪貼簿清單。** 採用會重用 cell 的 `NSTableView`，由分頁且經過 debounce 的 SQLite 查詢餵入資料；無論歷史成長到多大，捲動與搜尋都保持流暢。
- **輸入。** 一個非啟動式的 `NSPanel`，絕不從你正在使用的 app 搶走焦點。全域快速鍵是註冊的系統快速鍵，行內文字片段展開則由監看任意 app 鍵盤輸入的 `CGEvent` tap 驅動。
- **本地優先。** 所有資料都存在 `~/.config/ainto/` 之下：剪貼簿歷史用 SQLite，設定、片段、AI 指令與排序則用 TOML。無遙測。
- **更新。** 建置產物皆經簽署、公證，並透過 [Sparkle](https://sparkle-project.org/) 派送。

## 建置

```bash
# 快速開發建置
./build.sh

# 完整建置、執行與更多指令
make help
```

## 系統需求

- macOS 14.0+
- Xcode 15+
- Rust 工具鏈（`rustup`）

## 授權

[GPL-3.0-or-later](LICENSE)。Ainto 是自由軟體：任何分支或衍生作品都必須以相同授權維持開源。

---

<p align="center">
  由 <a href="https://github.com/ainto-labs">Ainto Labs</a> 打造
</p>
