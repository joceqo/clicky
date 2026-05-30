# PLAN — Persistent agent brain (OpenCode server) for joceclicky

**Audience:** a remote coding LLM working in this repo, unattended. Follow steps in order.
**Goal:** replace the slow spawn-per-turn agent brain (`claude -p` = ~18.6s cold start every turn)
with a **persistent agent session** via `opencode serve` (HTTP). No cold start, multi-turn context.
This is "Couche 1" toward matching the paid Clicky's agent engine.

---

## 0. Repo facts you MUST respect
- macOS SwiftUI app. Xcode project `leanring-buddy.xcodeproj`, scheme `leanring-buddy`, sources in `leanring-buddy/`.
- **Xcode 16 file-system-synchronized groups**: any `.swift` you add under `leanring-buddy/` is auto-included. **Do NOT edit `project.pbxproj` to add source files.**
- Deployment target is **macOS 26** (Permiso requires it). App is **NOT sandboxed** (`leanring-buddy.entitlements` has `app-sandbox=false`) → spawning processes is allowed.
- **Build + sign + verify** with EXACTLY this (must print `** BUILD SUCCEEDED **`):
  ```
  xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=VS3FLTY94C build
  ```
- **Run + capture logs** (the app mirrors stdout to a file):
  ```
  pkill -f "Debug/joceclicky.app"; sleep 1
  open build/Build/Products/Debug/joceclicky.app
  # then read: tail -n 40 ~/Library/Logs/joceclicky.log
  ```
- **SourceKit lies**: ignore "Cannot find type X / No such module PostHog" diagnostics — they're cross-file false positives. ONLY trust `xcodebuild`.
- `opencode` binary: `/opt/homebrew/bin/opencode`. GUI apps don't inherit shell PATH, so always resolve absolute paths or augment PATH (see existing `CLIAgentBrainAdapter.swift` which prepends `/opt/homebrew/bin:/usr/local/bin:~/.local/bin`).

## 1. The code path you are extending (READ THESE FIRST)
- `leanring-buddy/BrainClient.swift` — the protocol the voice flow actually uses. Two methods:
  `analyzeImageStreaming(images, systemPrompt, conversationHistory, userPrompt, onTextChunk) -> (text, duration)`
  and `analyzeImage(...)`. `var model: String { get set }`.
- `leanring-buddy/BrainProviderSettings.swift` — `BrainProviderType` enum + `BrainProviderSettings` struct +
  `BrainProviderFactory.makeClient(settings:claudeProxyURL:) -> any BrainClient`. **This is where you add the new provider.**
- `leanring-buddy/CLIAgentBrainAdapter.swift` — existing spawn-per-turn agent adapter (your reference for Process/PATH handling). KEEP it as a fallback.
- `leanring-buddy/CompanionManager.swift` — builds `brainClient` from `BrainProviderFactory`, calls it in `sendTranscriptToClaudeWithScreenshot`. Do NOT rewire this; just add a new provider type the factory can return.
- `leanring-buddy/SettingsView.swift` — `brainSection` switch over `BrainProviderType`. Add a UI case.
- IGNORE `RuntimeHarness.swift` / `RuntimeCoordinator.swift` / `RuntimeStore.swift` — they are NOT wired into the voice flow. Do not use them for this task.

## 2. Discover the OpenCode server API (DON'T GUESS)
`opencode serve` exposes an HTTP API whose exact paths can change by version. Discover them before coding:
```
/opt/homebrew/bin/opencode serve --port 7777 --print-logs &
sleep 2
curl -s http://127.0.0.1:7777/doc | head -c 4000          # OpenAPI spec (or try /openapi.json)
curl -s http://127.0.0.1:7777/ | head -c 1000
```
Identify the endpoints for: **create session**, **send a message/prompt to a session (with streaming/SSE)**,
and how the **assistant text** comes back. Also check `opencode models` for a default model id, and
`opencode providers` (auth) — the server may need a provider configured (e.g. a free model). Record what you find
in a comment at the top of the new adapter file.

## 3. Build `OpenCodeServerManager.swift` (new file)
A `@MainActor` singleton that owns the `opencode serve` lifecycle:
- `static let shared`.
- `func ensureRunning() async throws -> URL` — if not already running, spawn `opencode serve --port 0 --print-logs`
  via `Process` (executableURL `/usr/bin/env`, args `["opencode","serve",...]`, augmented PATH like `CLIAgentBrainAdapter`),
  parse the **chosen port** from its stdout/stderr (it logs the listening URL), health-check `GET /` until ready
  (timeout ~15s), and cache the base `URL`. Return it.
- Keep the `Process` retained so the server stays alive across turns. Terminate it on app quit (hook into
  `CompanionManager.stop()` or an app-terminate notification).
- Log clearly: `print("🤖 opencode serve → \(url)")`.

## 4. Build `OpenCodeServerBrainClient.swift` (new file, conforms to `BrainClient`)
- `init(model: String, binaryPath: String?)`. Store the model; default to whatever `opencode models` shows.
- Lazily hold a **session id** (create one on first turn via the discovered "create session" endpoint, reuse it
  afterwards → this is the persistence win).
- `analyzeImageStreaming(...)`:
  1. `let baseURL = try await OpenCodeServerManager.shared.ensureRunning()`.
  2. Ensure a session id exists (create if nil).
  3. Compose the prompt = `systemPrompt` + conversation framing + `userPrompt`. For images: write each screenshot
     to a temp PNG/JPG (reuse the temp-file approach in `CLIAgentBrainAdapter.writeImagesToTemp`) and reference the
     path(s) in the prompt text (OpenCode reads files by path). If the discovered API supports image attachments
     directly, prefer that.
  4. POST the message to the session endpoint. If the API streams (SSE), parse chunks and call
     `await onTextChunk(accumulatedText)` on the MainActor; else call it once with the full text.
  5. Return `(text, duration)`.
- `analyzeImage(...)`: same without streaming.
- `var model: String` settable (no-op effect is fine; OpenCode model is server/config-driven).
- Robust logging: `print("🤖 opencode session \(id): turn \(prompt.count) chars → \(text.count) chars in \(elapsed)s")`
  and log HTTP status / error bodies on failure.

## 5. Wire it into the brain selector
In `BrainProviderSettings.swift`:
- Add `case openCodeServer = "opencode_server"` to `BrainProviderType` (+ `displayName` "OpenCode (persistent server)").
- In `BrainProviderFactory.makeClient`, add:
  ```swift
  case .openCodeServer:
      return OpenCodeServerBrainClient(model: settings.openCodeModel, binaryPath: settings.openCodeBinaryPath)
  ```
- Add fields to `BrainProviderSettings`: `var openCodeModel: String = ""` (empty = server default) and
  `var openCodeBinaryPath: String = "opencode"`. Add a preset `static var openCodeServer`.

In `SettingsView.swift` `brainSection` switch: add a `.openCodeServer` case with a TextField for model + a short note
("Runs `opencode serve` in the background and reuses a persistent session — no per-turn cold start").

## 6. Build, run, verify (ACCEPTANCE CRITERIA)
- `xcodebuild ...` (section 0) prints `** BUILD SUCCEEDED **`.
- Launch, open Settings → Brain → "OpenCode (persistent server)".
- Push-to-talk twice. In `~/Library/Logs/joceclicky.log`:
  - first turn: `🤖 opencode serve → http://127.0.0.1:PORT` then a response;
  - **second turn is much faster than the first** (session reused, no re-spawn) — this is the whole point.
- No crash; Escape still stops audio; response is spoken via TTS.

## 7. Follow-ups (DO NOT do now — note only)
- **Codex app-server transport** (same idea, JSON-RPC): `codex app-server` (check `codex app-server --help`).
  This is the transport the paid Clicky uses (`swift-codex-app-server-bridge` seen in its `runtime.sqlite`).
  Add `BrainProviderType.codexServer` + a JSON-RPC client. Methods mirror the spawn/send/completed taxonomy.
- **Computer Use / Actions (Couche 2)**: a layer the agent can call to `click(x,y)`, `type`, `scroll`, `keyCombo`
  via `CGEvent`/Accessibility (permission already granted). Paid Clicky uses SkyLight focus-without-raise +
  a local HTTP control server (private API, risky — keep optional).
- **Sessions UI (Couche 3)**: surface running agents (reuse the `runtime.sqlite`-style schema already in `RuntimeStore.swift`).

## Constraints recap (don't break these)
- Don't add files to pbxproj. Don't touch the unsandboxed entitlements. Keep `CLIAgentBrainAdapter` as fallback.
- Commit on a new branch `feature/opencode-persistent-brain`, message ending with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Open a PR vs `main`.
- If the OpenCode API can't be made to work, STOP and write findings in the PR description rather than hacking.
