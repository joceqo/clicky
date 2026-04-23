# Project Comparison: Clicky vs TipTour-macOS

A full-stack comparison between **Clicky** (this repo) and
**[tiptour-macos](https://github.com/milind-soni/tiptour-macos)** — two Swift
macOS voice companions that share a common ancestor (TipTour's README credits
`farzaa/clicky` as its foundation) but have diverged significantly.

> TL;DR — Clicky is a **multimodal conversational companion** (chat + voice +
> screenshots + automation actions). TipTour is a **voice-guided in-app tutor**
> (point, narrate, wait for click, advance). The AX/grounding stack is where
> they diverge most sharply; the UX positioning follows from that.

---

## 1. At-a-Glance

| Dimension | Clicky | TipTour |
|---|---|---|
| Core purpose | Voice + chat companion, ask about anything on screen, run actions | Step-by-step in-app tutor ("How do I render in Blender?") |
| Interaction surface | Menu-bar panel + Dock chat window + voice overlay | Voice only (hotkey-gated) |
| Primary LLM | Claude Sonnet 4.6 / Opus 4.6 via Cloudflare Worker | Gemini Live 3.1 Flash via single WebSocket |
| Streaming | SSE for chat text; PCM for audio | Single multimodal WebSocket (audio + vision + tool calls) |
| STT | AssemblyAI (default) / OpenAI / Apple Speech / **Parakeet on-device** | Integrated in Gemini Live (no separate STT) |
| TTS | ElevenLabs / **Supertonic on-device ONNX** | Integrated in Gemini Live |
| Multi-conversation | Yes — sidebar with separate JSON per conversation | No — ephemeral voice sessions |
| Persistence | Chat history, learning log, user profile | Keychain API key only |
| Automation actions | `[OPEN]`, `[SHORTCUT]`, `[REMIND]`, `[MUSIC]`, `[LOG]`, `[CLICK]` tags | None — observational |
| Distribution | Cloudflare Worker proxy hides API keys; self-build | Dev build; Worker proxy planned for DMG |
| Minimum macOS | 14.2+ | 14+ (15+ for ScreenContent) |
| License | — | MIT |

---

## 2. Where the two apps actually differ

### 2.1 Grounding stack (how pixels on screen become actions)

This is the biggest architectural divide.

| Stage | Clicky | TipTour |
|---|---|---|
| Label → pixel rect | **Claude vision** returns `[POINT:x,y:label:screenN]` tags directly | **AX tree** primary (~30 ms) → **CoreML YOLO + Vision OCR** fallback (~200 ms) → LLM coords last resort |
| Cursor animation to rect | ✅ Bezier arc, 3 states (`OverlayWindow.swift`) | ✅ Equivalent |
| Post-click behavior | Passive — overlay fades after TTS | **`ClickDetector` CGEventTap** auto-advances workflow step |
| Per-app AX cache | ❌ none | ✅ 10-minute AX-empty-tree cache |

**What Clicky already has that overlaps TipTour:**

Both of TipTour's primary building blocks have Clicky analogs — the pieces
exist, they just aren't composed for element pointing.

- **AX tree traversal** — `TextExtractor.swift` already walks the AX tree via
  `AXUIElementCreateSystemWide` + `kAXChildrenAttribute` + `kAXTitleAttribute`
  / `kAXValueAttribute`. Tuned for text, but the tree walk is generic.
- **Element position + size via AX** — `WindowPositionManager.swift:214-215`
  reads `kAXPositionAttribute` + `kAXSizeAttribute` on a window element. Same
  API works on *any* AX element; this is exactly what TipTour's ~30 ms fast
  path does.
- **Per-word rects via AX** — `TextExtractor.swift:221` uses
  `AXBoundsForRangeParameterizedAttribute` for text-range bounds.
- **Cursor-to-rect animation** — bezier arc in `OverlayWindow.swift`
  (`.navigatingToTarget` → `.pointingAtTarget`). Coordinates come from Claude
  vision today; swapping in AX-derived rects is a feed change, not a rewrite.
- **Vision framework OCR** — already a fallback in `TextExtractor.swift` for
  AX-empty apps like Chrome/Electron (half of TipTour's YOLO+OCR combiner).
- **On-device CoreML / ONNX model pattern** — FluidAudio/Parakeet (CoreML,
  ~600 MB) and Supertonic (ONNX, ~200 MB) both auto-download from HuggingFace
  and cache in `~/Library/Application Support/Clicky/models/`. Same pattern
  drops onto a YOLO model.

**What Clicky is actually missing:**

1. **A `resolve(label: String) → CGRect?` function** composed from the AX
   primitives above. TipTour has this; Clicky doesn't. Implementation = walk
   tree, fuzzy-match `kAXTitleAttribute` / `kAXDescriptionAttribute` /
   `kAXValueAttribute` against the label, read `kAXPositionAttribute` +
   `kAXSizeAttribute` on hit, return rect. One file; every API call needed
   already has a working example in the repo.
2. **A CoreML YOLO UI-element detector** as the AX-empty fallback. Clicky
   can't currently point accurately in Blender / Unity / Figma canvas /
   Electron apps. TipTour ships a YOLO model that returns UI-element bboxes,
   then runs Vision OCR inside each box and matches the label. Clicky has
   Vision OCR and the on-device model-loading pattern already — the missing
   piece is the model itself + a ~100-line combiner.
3. **Pipeline switch: labels instead of coordinates.** Today Clicky's prompt
   asks Claude to emit `[POINT:x,y:label:screenN]` — pixel coordinates that
   are a best-effort vision guess. Switching to `[POINT:label:screenN]` with
   Swift doing the resolution (AX → YOLO+OCR → fallback) is the architectural
   shift. That's a prompt change + resolver + wiring into `OverlayWindow`.

**What Clicky does not have but is less critical:**

- `ClickDetector` CGEventTap inside the resolved rect for auto-advance. Only
  matters if Clicky adds multi-step workflow plans; today the model sends one
  `[POINT]` per response, so there's no "next step" to advance to.

**Effort summary (rough):**

| Task | Effort | Blocker |
|---|---|---|
| AX `resolve(label) → CGRect` | small (~1 day) | none — all primitives in-repo |
| AX-empty-tree cache per bundle ID | trivial | none |
| CoreML YOLO + OCR combiner | medium (1–2 days) | need/pack a UI-element YOLO model |
| Prompt switch coords → labels | small | none |
| ClickDetector auto-advance | small | only useful with workflow plans |

### 2.2 Conversation model

- **Clicky** keeps a full multi-conversation chat history. Sidebar + per-convo
  JSON (`ConversationStore.swift`), titles auto-generated from the first
  message, voice exchanges append to the active conversation. Learning log
  (`LearningLog.swift`) and user profile (`UserProfile.swift`) also persist.
- **TipTour** has no persistent chat. Each hotkey session is ephemeral; the
  checklist UI shows workflow steps only while the plan is active.

### 2.3 AI pipeline

- **Clicky** — separate services: STT (4 providers, pluggable via
  `BuddyTranscriptionProvider`), LLM (Claude via SSE, or LM Studio local, or
  OpenAI), TTS (ElevenLabs or on-device Supertonic ONNX). More moving parts,
  more user choice, more on-device options.
- **TipTour** — one Gemini Live WebSocket does everything: speech in, vision
  in, tool calls out, narration audio out. Lower latency, less code, but
  single-provider lock-in.

### 2.4 Automation

Only Clicky acts on the system beyond pointing:

| Tag | File | What it does |
|---|---|---|
| `[OPEN:url-or-app]` | `ActionExecutor.swift` | NSWorkspace open |
| `[SHORTCUT:name]` | `ActionExecutor.swift` | `shortcuts run` CLI |
| `[REMIND:text:date]` | `ActionExecutor.swift` | NSAppleScript → Reminders.app |
| `[MUSIC:play\|pause\|next\|prev]` | `MusicController.swift` | NX_KEYTYPE media keys + `MPNowPlayingInfoCenter` |
| `[LOG:app:topic]` | `LearningLog.swift` | Append to local learning log |
| `[CLICK:x,y:label:screenN]` | overlay | Pointing (same as `[POINT]`) |

TipTour is deliberately observational — it points and narrates but never
clicks or automates. That's a different product philosophy (tutor vs. agent),
not a capability gap.

### 2.5 Accessibility API (AX*) usage

| Use | Clicky | TipTour |
|---|---|---|
| AX as **text reader** (focused-element text + word rects) | ✅ `TextExtractor.swift` (primary use) | Not documented |
| AX as **element-pointing primitive** | ❌ (uses Claude vision instead) | ✅ primary path |
| AX for **window layout** (resize overlapping windows) | ✅ `WindowPositionManager.swift` | ❌ |
| `AXIsProcessTrusted` gate + Settings deep-link | ✅ | ✅ |
| Empty-tree cache | ❌ | ✅ |

### 2.6 Permissions

| Permission | Clicky | TipTour |
|---|---|---|
| Accessibility | ✅ | ✅ |
| Screen Recording | ✅ | ✅ |
| Screen Content (15+) | — | ✅ |
| Microphone | ✅ | ✅ |
| Speech Recognition | ✅ (Apple provider only) | — |
| Apple Events (Notes/Reminders) | ✅ | — |
| Reminders (EventKit) | ✅ | — |
| Input Monitoring (CGEvent) | ✅ listen-only | ✅ |

Clicky's broader permission surface is a direct consequence of its
automation tags. TipTour's narrower surface matches its "nothing runs in the
background; permissions only active while hotkey is held" pitch.

### 2.7 Hotkey and input monitoring

Both apps converge on `ctrl + option` via `CGEvent.tapCreate`. Clicky uses
`.listenOnly` (per `CLAUDE.md`, modifier-only shortcuts are detected more
reliably this way than via `NSEvent` global monitors). Clicky adds
`ctrl + shift + L` for read-aloud toggle; TipTour sticks with a single hotkey.

### 2.8 UI architecture

| | Clicky | TipTour |
|---|---|---|
| App type | Menu bar + Dock (`LSUIElement=false`) | Menu bar (implied) |
| Menu-bar panel | Custom borderless `NSPanel`, non-activating, click-outside-dismiss | Not documented |
| Dock click target | Multi-conversation chat window (`ChatWindowController`) | N/A |
| Overlay | Full-screen transparent `NSPanel` at `.screenSaver` z-level, all spaces, `ignoresMouseEvents`, `hidesOnDeactivate=false` | Equivalent |
| Cursor art | Blue triangle + optional Neko pixel-cat | Blue triangle + optional Neko (oneko, BSD-2) |
| Pattern | MVVM, `@StateObject`/`@Published`, `@MainActor` isolation | SwiftUI + AppKit |
| Design system | `DesignSystem.swift` tokens (`DS.Colors`, `DS.CornerRadius`) | Not documented |

### 2.9 Privacy & on-device options

| | Clicky | TipTour |
|---|---|---|
| On-device STT | ✅ Parakeet (FluidAudio / CoreML) + Apple Speech | ❌ (Gemini cloud) |
| On-device TTS | ✅ Supertonic ONNX (66M params, ~167× realtime) | ❌ (Gemini cloud) |
| On-device LLM | ✅ LM Studio (OpenAI-compatible, 127.0.0.1:1234) | ❌ |
| On-device vision | OCR only (Vision framework in TextExtractor) | YOLO + Vision OCR |
| Screenshots leave device? | Yes, when using cloud Claude | Yes, when Gemini is called |
| Keys storage | Cloudflare Worker (secrets), Keychain for optional user keys | Keychain |

Clicky's on-device **audio** story is stronger (both STT and TTS). TipTour's
on-device **vision** story is stronger (YOLO grounding keeps element
detection local even when the LLM is cloud).

### 2.10 Assistive-tech UI (the thing both apps ignore)

Neither ships the "accessibility" that end-user assistive tech users care
about:

- ❌ No SwiftUI `.accessibilityLabel` / `.accessibilityHint` / `.accessibilityValue`
- ❌ No VoiceOver testing documented
- ❌ No Reduce Motion respect (both have bezier cursor animations)
- ❌ No Dynamic Type / Increase Contrast awareness
- ❌ No keyboard-only navigation beyond the push-to-talk hotkey

---

## 3. What Clicky could borrow from TipTour

Ordered by value-to-effort:

1. **CoreML YOLO + Vision OCR fallback for element detection.** The real
   capability gap. Would let Clicky point accurately inside Blender / Unity /
   Figma canvas / Electron apps where Claude's vision coordinates drift.
   Largest single lift on this list — needs a model, inference pipeline, and
   label-matching logic.
2. **Promote AX-tree label resolution to the pointing path.** Clicky already
   has `AXBoundsForRangeParameterizedAttribute` wired for text; extending it
   to resolve a label → rect for native apps gives the ~30 ms fast path for
   free in most cases. Claude vision becomes the fallback, not the default.
3. **AX-empty-tree cache** (per bundle ID, ~10 min TTL). Cheap. Stops
   repeated AX probes from stalling when the frontmost app is known
   AX-hostile.
4. **Reduce Motion path** for the cursor animation. One check, one branch —
   jumps the cursor instantly instead of arcing. Low effort, meaningful for
   users who toggle Reduce Motion.
5. **SwiftUI accessibility modifiers** on chat bubbles, waveform, streaming
   indicator, toolbar buttons. Where Clicky could lead; TipTour also lacks
   this.
6. **`ClickDetector` CGEventTap.** Optional, lower priority. Only useful if
   Clicky introduces multi-step workflow plans; not a fit for the current
   one-`[POINT]`-per-response model.

## 4. What TipTour could borrow from Clicky

Cleanly mirrored, since TipTour is Clicky-derived:

1. **Multi-conversation persistence** — users will eventually want to
   revisit a tutorial session or ask follow-ups.
2. **Pluggable provider layer** — `BuddyTranscriptionProvider` pattern for
   STT, same for TTS. Opens on-device alternatives (Parakeet, Supertonic,
   Apple Speech) that Gemini Live can't provide.
3. **Automation action tags** — `[OPEN]`, `[SHORTCUT]`, `[REMIND]`,
   `[MUSIC]` move the product from observational tutor to active agent when
   users want that.
4. **Cloudflare Worker proxy** for signed DMG distribution without shipping
   keys. TipTour's README already notes this is on the roadmap.
5. **Learning log + user profile** — closes the loop between tutorials and
   personalized recall.

---

## 5. Source Reference

Clicky files cited above (all under repo root):

- `TextExtractor.swift` — AX text + per-word rects + OCR fallback
- `ElementLocationDetector.swift` — Claude vision-based element pointing
- `WindowPositionManager.swift` — AX permission, window layout via AX
- `GlobalPushToTalkShortcutMonitor.swift` — CGEvent listen-only tap
- `BuddyDictationManager.swift` — mic + speech permission
- `BuddyTranscriptionProvider.swift` — pluggable STT providers
- `CompanionScreenCaptureUtility.swift` — ScreenCaptureKit multi-monitor
- `OverlayWindow.swift` / `CompanionResponseOverlay.swift` — cursor overlay
- `CompanionManager.swift` — state machine, permission polling
- `ChatView.swift` / `ChatContainerView.swift` / `ConversationSidebarView.swift` — chat UI
- `ConversationStore.swift` — multi-conversation persistence
- `ActionTagParser.swift` / `ActionExecutor.swift` — automation tag pipeline
- `MusicController.swift` — media-key music control
- `SupertonicTTSClient.swift` / `SupertonicEngine.swift` — on-device TTS
- `ParakeetTranscriptionProvider.swift` — on-device STT
- `ClaudeAPI.swift` / `OpenAIAPI.swift` — LLM clients
- `ElevenLabsTTSClient.swift` — cloud TTS
- `UserProfile.swift` / `LearningLog.swift` — persistence
- `DesignSystem.swift` — UI tokens
- `worker/src/index.ts` — Cloudflare Worker proxy
- `leanring-buddy.entitlements` — sandbox=false, audio-input, mach lookup

TipTour references come from the public GitHub repo's README / `AGENTS.md`.
