# Clicky Plugin & Integration Architecture — Research Document

> Research compiled 2026-04-15. Covers extension strategies, middleware tools, IPC mechanisms, and real-world patterns for extending Clicky without polluting its core codebase.

---

## Table of Contents

- [Context & Goals](#context--goals)
- [Current State](#current-state)
- [Extension Vectors](#extension-vectors)
- [Architecture Options](#architecture-options)
- [IPC Mechanisms on macOS](#ipc-mechanisms-on-macos)
- [Middleware Tools Ecosystem](#middleware-tools-ecosystem)
- [Real-World URL Scheme Examples](#real-world-url-scheme-examples)
- [The Proxy Pattern (PR #6)](#the-proxy-pattern-pr-6)
- [Modern Best Practices](#modern-best-practices)
- [Open Questions](#open-questions)
- [References](#references)

---

## Context & Goals

Clicky is a macOS companion app (menu bar + dock) with voice interaction, multi-conversation chat, screen capture, and AI-powered responses. The core is well-structured with pluggable providers for TTS, STT, and LLM backends.

**Goal:** Extend Clicky's capabilities (app integrations, text reading, new backends) without bloating the core codebase. Find the cleanest architecture for plugins/integrations.

**Constraints:**
- Must not pollute Clicky's Swift codebase with integration-specific code
- Should work for users who don't have Raycast or other power-user tools
- Error handling matters — fire-and-forget is insufficient for robust integrations
- Each integration should be independently installable/runnable

---

## Current State

### What Clicky Already Has

Clicky's codebase already implements several pluggable patterns:

| Pattern | How it works | Examples |
|---------|-------------|----------|
| **STT provider factory** | `BuddyTranscriptionProvider` protocol, resolved at runtime | AssemblyAI, OpenAI, Apple Speech, Parakeet |
| **TTS client abstraction** | Shared interface, user toggles cloud vs local | ElevenLabs (cloud), Supertonic (local ONNX) |
| **LLM client abstraction** | Multiple API clients, model selection at runtime | Claude, OpenAI/LM Studio, Apple Intelligence |
| **API proxy (Cloudflare Worker)** | One server, multiple routes, holds all API keys | `/chat`, `/tts`, `/transcribe-token` |

### PR #6 — OpenRouter Proxy (Proven Pattern)

A ~22-line Python proxy on `localhost:8976` that translates Anthropic API format to OpenRouter format. Clicky doesn't know it's not talking to Claude. Zero changes to Clicky's code.

```
Clicky → HTTP POST → proxy (localhost:8976) → OpenRouter → response back → Clicky
```

Key properties:
- **Request-response** — proper error handling, not fire-and-forget
- **Zero Clicky changes** — the adapter is entirely external
- **Transparent** — Clicky's existing ClaudeAPI.swift works unchanged
- **~22 lines** — minimal, maintainable

### Related Projects

| Project | What it is | Relevance |
|---------|-----------|-----------|
| **Lector** (`github.com/joceqo/lector`) | macOS menu bar text reader with word-level highlighting, ~3,800 lines Swift | Shares DNA with Clicky (NSPanel, DesignSystem, GlobalHotkey, TextExtractor). Has clean `TTSProvider` protocol. Candidate for feature merge. |
| **Machia** (`github.com/joceqo/machia`) | Claude Code sidecar — Rust+TypeScript monorepo with session replay, local TTS, multi-agent orchestration, tool approval UI | Demonstrates Claude Code subprocess integration via `claude -p --output-format stream-json` NDJSON parsing. Different runtime (Rust). |

---

## Extension Vectors

Three distinct ways to extend Clicky:

### 1. App Integrations (PR #6 Style)

External adapters/proxies that translate between Clicky and other services. Clicky's code doesn't change.

**Examples:**
- OpenRouter proxy (done — PR #6)
- Future: Ollama proxy, Google Gemini adapter, local whisper proxy

**Architecture:** External process, HTTP adapter pattern.

### 2. Text Reading / Lector Features

Reading on-screen text aloud with visual highlighting. Most code already exists in both Clicky and Lector (TextExtractor, overlay system, TTS clients).

**Architecture:** Feature merge into Clicky or Swift package shared between both apps. Shares overlay system.

### 3. Claude Code Backend

Use Claude Code itself as the LLM backend instead of calling the Anthropic API directly. Benefits: no API key management, tool use comes free, Claude Code handles auth/caching/compaction.

**Architecture:** New `ClaudeCodeAPI.swift` alongside existing `ClaudeAPI.swift`. Spawns `claude -p --output-format stream-json`, parses NDJSON events. Becomes another model option in the picker.

---

## Architecture Options

### Option A: Internal Swift Plugin Protocol

Define `ClickyPlugin` protocol. Each plugin is a separate Swift package linked at build time.

```swift
protocol ClickyPlugin {
    var name: String { get }
    func activate(context: ClickyContext)
    func deactivate()
}
```

| Pro | Con |
|-----|-----|
| Type-safe, compile-time checks | Tight coupling to Clicky's build |
| Access to Clicky's internal state | Every plugin must be Swift |
| Fast (in-process) | Plugins can crash the host app |

### Option B: External Proxy/Adapter Pattern (PR #6 Style)

Each capability runs as its own process. Clicky talks to them through HTTP.

| Pro | Con |
|-----|-----|
| Zero Clicky changes per integration | Multiple processes to manage |
| Any language (Python, Rust, Go, JS) | Operational overhead |
| Independent deployment | Extra network hop |
| Can't crash Clicky | |

**Scaling concern:** Many separate scripts become messy. Solution: **one local server with multiple routes** (same pattern as the Cloudflare Worker).

### Option C: URL Scheme + App Intents

Clicky registers `clicky://` and exposes App Intents. Other apps trigger Clicky through these universal interfaces.

| Pro | Con |
|-----|-----|
| Universal — works with any tool | URL schemes are fire-and-forget (no response) |
| App Intents integrate with Shortcuts, Siri, Spotlight | App Intents API can be finicky |
| No extra apps to install | Limited to what URL params can express |
| Apple's blessed path | |

### Option D: Local HTTP API in Clicky

Clicky runs a small HTTP server (like Obsidian's Local REST API plugin). True request-response semantics.

| Pro | Con |
|-----|-----|
| Real API (request-response, status codes, JSON) | Adds a server to Clicky |
| Works from any language/tool/script | Port conflicts possible |
| MCP servers can connect to it | Security (localhost exposure) |
| No size limits, binary data support | |

### Option E: Hybrid (Recommended Direction)

- **In-process** for features needing tight UI integration (Lector's word highlighting needs Clicky's overlay system)
- **External proxies** for API translation (PR #6 pattern, one server with multiple routes)
- **URL scheme + App Intents** as universal hooks for external automation
- **Local HTTP API** if MCP/AI integration becomes a priority

---

## IPC Mechanisms on macOS

### Comparison Table

| Mechanism | Direction | Response? | Binary? | Size Limit | Setup Effort | Best For |
|-----------|-----------|-----------|---------|------------|-------------|----------|
| **URL scheme** (`clicky://`) | One-way in | No (x-callback-url is janky) | No (base64 workaround) | ~2GB app-to-app | Low | Deep linking, simple triggers |
| **App Intents** | Bidirectional | Yes (typed) | Yes | No practical limit | Medium | Shortcuts, Siri, Spotlight |
| **Local HTTP server** | Bidirectional | Yes (full HTTP) | Yes | No practical limit | Medium | Structured APIs, MCP, scripts |
| **AppleScript dictionary** | Bidirectional | Yes | Limited | Practical ~MB | Medium | Legacy automation, scripting |
| **XPC** | Bidirectional | Yes | Yes | No practical limit | High | Own helper processes only |
| **Distributed Notifications** | Broadcast | No | No | Small payloads only | Low | Lightweight signaling |
| **File-based (watched folders)** | Async | Via file | Yes | Disk limit | Low | Drop-to-process workflows |
| **Unix Domain Sockets** | Bidirectional | Yes | Yes | No practical limit | High | High-performance local IPC |

### URL Scheme Technical Details

- **Max length on macOS:** ~2 GB for app-to-app (tested). Browser limit is ~2MB but irrelevant for app IPC.
- **Multi-line text:** Works. Newlines encoded as `%0A`.
- **Binary data:** Must be base64-encoded (+33% overhead). Bear and OmniFocus do this for file attachments.
- **Response:** Standard URL schemes are fire-and-forget. x-callback-url adds `x-success`/`x-error`/`x-cancel` callback URLs but causes visible app-switching. Ugly UX.
- **Security:** Any app can register any scheme. No ownership verification. Scheme hijacking is a real attack vector (CWE-939).

### x-callback-url Pattern

Format: `[scheme]://x-callback-url/[action]?[x-callback params]&[action params]`

| Parameter | Purpose |
|-----------|---------|
| `x-source` | Friendly name of calling app |
| `x-success` | URL opened on success, result data as query params |
| `x-error` | URL opened on error, with `errorCode` and `errorMessage` |
| `x-cancel` | URL opened if user cancels |

Still widely used (Bear, Things, Drafts, Shortcuts) but aging. App Intents is Apple's replacement. x-callback-url spec has been at "1.0 DRAFT" for over a decade with no updates.

---

## Middleware Tools Ecosystem

### Primary Tier (Recommended)

#### Raycast
- **What:** App launcher + extensions platform + AI chat with MCP support
- **Relevant extensions that already exist:**
  - `elevenlabs-tts` — select text, hotkey to read aloud with ElevenLabs
  - `say` — macOS system TTS, no network needed
  - ScreenOCR — offline screen text extraction via VisionKit
  - ClaudeCast — bridges Claude Code CLI with Raycast UI
  - Built-in AI with BYOK (Anthropic, OpenAI, Google)
  - Built-in Ollama/local model support (v1.99+)
  - MCP server support in AI chat
- **IPC:** Extensions can run AppleScript (`runAppleScript()`), open URL schemes, trigger deeplinks (`raycast://extensions/...`)
- **Limitation:** Not everyone has Raycast. Paid for AI features.

#### Hammerspoon
- **What:** Lua-scriptable macOS automation with the deepest OS API access
- **Key capabilities:**
  - `hs.httpserver` — receive webhooks from any app on localhost
  - `hs.urlevent` — register `hammerspoon://` URL handlers + open URL schemes in other apps
  - `hs.axuielement` / `hs.axuielement.observer` — full Accessibility API (AXObserver, UI tree traversal, text extraction)
  - `hs.eventtap` — intercept, modify, suppress, forward keyboard/mouse events system-wide
  - `hs.osascript` — execute AppleScript/JXA from Lua
  - `hs.ipc` — CLI tool (`hs -c "lua code"`) for external processes to execute Lua in Hammerspoon
  - `hs.screen:snapshot()` / `hs.window:snapshot()` — screen/window capture
  - `hs.application.watcher` — app lifecycle events (launched, terminated, activated)
  - `hs.distributednotifications` — listen to NSDistributedNotificationCenter
- **Inbound IPC (5 channels):** HTTP server, `hammerspoon://` URL, AppleScript, CLI (`hs -c`), distributed notifications
- **Outbound IPC:** AppleScript, URL schemes, HTTP requests, key event synthesis, AX element manipulation
- **Limitation:** Single-threaded Lua. Not for heavy processing.

### Secondary Tier (Useful for Specific Needs)

#### Phoenix (~4.5k stars)
- JavaScript-based macOS scripting alternative to Hammerspoon
- Rich event system (app/window/mouse/space/screen/sleep)
- Shell command execution via Task API
- **No inbound IPC** (no HTTP server, no URL handler)
- Narrower API than Hammerspoon but JS/TS is appealing
- Maintenance concern — last release Jun 2024

#### yabai + skhd.zig (~29k + ~500 stars)
- yabai: tiling WM with **signal system** (event bus for window events → shell commands)
- skhd.zig: keyboard-to-shell-command bridge with vim-style modal keybinding
- yabai returns JSON from queries, has full CLI message passing
- Best combo for window-event-driven automation
- Limitation: only knows about windows, spaces, displays

#### SketchyBar (~11.6k stars)
- Status bar replacement with hidden superpower: **NSDistributedNotificationCenter bridge**
- Custom events pushable from any app via CLI (`sketchybar --trigger`)
- Can listen to any app's distributed notifications (e.g., Spotify playback state)
- Surprisingly good event router despite being "just a status bar"

#### AeroSpace (~20.3k stars)
- i3-like tiling WM, CLI-first, TOML config
- `on-window-detected` callbacks, `exec-on-workspace-change`
- Good for window-event-driven automation, less capable than yabai for middleware

#### Karabiner-Elements (~22k stars)
- Keyboard remapper that can execute shell commands on key events
- App-specific rules via JSON config
- One-way only (keyboard in → shell command out). No inbound IPC.

#### macos-automator-mcp (~758 stars)
- MCP server giving AI agents access to 200+ AppleScript/JXA automation recipes
- Safari, Finder, Terminal, Mail, Calendar control
- Directly relevant: Claude (via Clicky) could use this to control macOS apps
- Request-response only (no event system)

### Not Useful for Middleware

| Tool | Why not |
|------|---------|
| **Amethyst** (~16k stars) | Auto-tiling WM only. No scripting, no IPC, no event bus. |
| **Shortcat** | Closed source. UI navigation aid, not scriptable. |
| **Sol** (~2.8k stars) | Open source launcher. AppleScript support but no event system. |

---

## Real-World URL Scheme Examples

### Most Sophisticated Implementations

#### Drafts (`drafts://`) — 19 actions
- `/runAction` — execute any Drafts Action on arbitrary text **without saving a draft** (turns Drafts into a text processing engine)
- `/replaceRange` — surgical character-range replacement
- `/create`, `/open`, `/get`, `/prepend`, `/append`, `/search`
- `||clipboard||` special markup auto-expands to clipboard contents
- `/dictate` — open voice dictation with locale selection
- Full x-callback-url support with data return

#### Things 3 (`things://`) — 8 commands
- `json` command — encode entire project hierarchy as JSON array, import in one shot
- `add`, `add-project`, `update`, `update-project`, `show`, `search`, `version`
- Auth tokens required for update operations
- Rate limit: 250 items per 10 seconds

#### Bear (`bear://`) — 16 actions
- `/add-file` — attach base64-encoded files to notes
- `/open-note` — returns content, tags, dates via x-callback-url
- `/rename-tag`, `/delete-tag` — tag management across all notes
- API tokens for authentication
- Interactive URL builder at bear.app/xurl/

#### Obsidian (`obsidian://`)
- Built-in: `/open`, `/search`, `/new`
- **Advanced URI plugin** extends massively: frontmatter read/write, search-and-replace, command execution, canvas manipulation, workspace navigation
- **Local REST API plugin** (separate): full HTTP server on `localhost:27124` with CRUD, Dataview search, command execution. This is what MCP servers connect to.

#### OmniFocus (`omnifocus://`)
- `/add` with base64 attachments, RFC 2445 repeat rules, defer/due dates
- `/paste` — import TaskPaper-formatted text with precise position control
- Navigation to perspectives, projects, tags, forecast

#### Shortcuts.app (`shortcuts://`)
- `shortcuts://run-shortcut?name=Name&input=text&text=Hello`
- x-callback-url support — `x-success` receives `result` parameter with shortcut output
- Apple's own app validates x-callback-url pattern remains relevant

---

## The Proxy Pattern (PR #6)

### Why It Works

PR #6's adapter proxy is the cleanest integration pattern because:

1. **Request-response** — HTTP with status codes, proper error handling
2. **Zero Clicky changes** — adapter is entirely external
3. **Language-agnostic** — proxy can be Python, Go, Rust, anything
4. **Composable** — proxies can chain (Clicky → auth proxy → OpenRouter)
5. **Independently deployable** — run only what you need

### Scaling the Pattern

One proxy per integration becomes messy. Two solutions:

**A. One local server, multiple routes** (mirrors the Cloudflare Worker pattern):
```
localhost:8976/openrouter  → OpenRouter translation
localhost:8976/read-aloud  → Lector text reading
localhost:8976/integrate   → App integration endpoints
```

**B. Keep separate, add a process manager:**
Each proxy is independent. A simple launcher script or launchd plist starts/stops them.

Option A is cleaner operationally. The Cloudflare Worker already proves the pattern (one server, three routes: `/chat`, `/tts`, `/transcribe-token`).

### Error Handling

The proxy pattern handles errors properly because it's HTTP:
- Proxy returns 4xx/5xx status codes to Clicky
- Clicky's existing `ClaudeAPI.swift` already handles HTTP errors
- Proxy can add retries, circuit breakers, logging externally
- Compare to URL schemes which are fire-and-forget with no error channel

---

## Modern Best Practices

### 2025-2026 macOS App-to-App Communication

| Need | Best Approach |
|------|--------------|
| Expose features to Shortcuts/Siri/Spotlight | **App Intents** — Apple's clear investment direction |
| Deep linking ("open this specific thing") | **URL scheme** — simplest, universal |
| Structured request-response | **Local HTTP server** — true API semantics, MCP compatible |
| Bidirectional simple exchange | **x-callback-url** — still works, aging but widely supported |
| CLI/script automation | **AppleScript** or `shortcuts run "Name"` |
| AI/MCP integration | **Local HTTP server** — dominant pattern (Obsidian, DEVONthink, etc.) |
| Lightweight app signaling | **Distributed Notifications** — near-zero setup |
| Own helper processes | **XPC** — sandboxed, fault-isolated |

### Recommended Stack for Clicky

```
Layer 1 (Universal, in Clicky):
  - clicky:// URL scheme     → deep linking, simple triggers
  - App Intents              → Shortcuts, Siri, Spotlight
  - Local HTTP API (optional) → structured request-response, MCP

Layer 2 (External proxies, PR #6 pattern):
  - One local server, multiple routes
  - API translation adapters (OpenRouter, Ollama, etc.)
  - Feature proxies (text reading, app control)

Layer 3 (User's choice of middleware):
  - Raycast extensions (wraps Layer 1)
  - Hammerspoon configs (wraps Layer 1)
  - Shell scripts (wraps Layer 1)
  - Shortcuts workflows (wraps Layer 1)
```

Layer 1 is the universal foundation. Layer 2 is the adapter pattern from PR #6. Layer 3 is whatever the user already has — Clicky doesn't need to know or care.

---

## Open Questions

1. **One server or many?** Should all proxies/adapters consolidate into one local server (like the Cloudflare Worker) or stay independent?

2. **Local HTTP API in Clicky?** Should Clicky itself run a small HTTP server for true request-response, or is the URL scheme + App Intents sufficient?

3. **MCP server for Clicky?** If Clicky exposes a local HTTP API, it could also expose an MCP server — letting any AI tool (Claude Code, Raycast AI, etc.) control Clicky programmatically.

4. **Process management:** If running external proxies, who starts/stops them? launchd plists? A launcher script? The Clicky app itself?

5. **Discovery:** How does Clicky know which proxies/adapters are available? Hardcoded endpoints? A registry? mDNS/Bonjour?

6. **Auth between Clicky and local proxies:** Is localhost sufficient security, or should there be token-based auth?

---

## References

### Repos
- Clicky PR #6 (OpenRouter proxy): `github.com/joceqo/clicky/pull/6`
- Lector (text reader): `github.com/joceqo/lector`
- Machia (Claude Code sidecar): `github.com/joceqo/machia`
- Obsidian Local REST API: `github.com/coddingtonbear/obsidian-local-rest-api`
- macos-automator-mcp: `github.com/steipete/macos-automator-mcp`

### Tools
- Raycast: `raycast.com`
- Hammerspoon: `hammerspoon.org`
- Phoenix: `github.com/kasper/phoenix`
- yabai: `github.com/koekeishiya/yabai`
- skhd.zig: `github.com/jackielii/skhd.zig`
- SketchyBar: `github.com/FelixKratz/SketchyBar`
- AeroSpace: `github.com/nikitabobko/AeroSpace`
- Karabiner-Elements: `github.com/pqrs-org/Karabiner-Elements`

### Documentation
- Apple App Intents: `developer.apple.com/documentation/appintents`
- x-callback-url spec: `x-callback-url.com/specification/`
- Bear URL scheme: `bear.app/faq/x-callback-url-scheme-documentation/`
- Things 3 URL scheme: `culturedcode.com/things/support/articles/2803573/`
- Drafts URL scheme: `docs.getdrafts.com/docs/automation/urlschemes`
- Obsidian URI: `help.obsidian.md/Extending+Obsidian/Obsidian+URI`
- Shortcuts URL scheme: `support.apple.com/guide/shortcuts-mac/run-a-shortcut-from-a-url-apd624386f42/mac`
