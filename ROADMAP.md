# Clicky — Roadmap

## What Clicky already does (shipped)

- Push-to-talk voice → screenshot + OCR → Claude/LM Studio/Apple Intelligence → spoken response
- Blue cursor flies to and points at UI elements Claude references
- Multi-conversation text chat window with sidebar
- User profile card (name, goals, context) injected into every system prompt
- Apple Notes action tag: say "save this to my notes" → `[NOTE:title]content[/NOTE]` → note created silently
- Settings with Profile and General tabs (tabbed)
- AssemblyAI / Parakeet STT, ElevenLabs / Supertonic TTS

---

## Core insight (corrected)

The value is **not** moving raw text around. Raw copy/paste is a non-feature — the user can do that themselves in 2 seconds.

The value is the **intelligence layer on top of what's on screen**:

```
Screen (screenshot + OCR)
         ↓
   Claude processes
   (summarize / explain / extract key points / create flashcard)
         ↓
   Enhanced structured note → Apple Notes
         ↓
   Topic logged → Learning store
         ↓
   "Quiz me on this later"
```

You're reading a DaVinci Resolve tutorial. You say "I don't fully get this, save the key points." Clicky doesn't copy the text — it *understands* it, extracts what matters for someone at your level (it knows from your Profile), writes a clean structured note, saves it to Apple Notes, and logs the topic so it can quiz you tomorrow. That's the loop.

---

## Phase 1 — Screen → Understand → Remember

> **The one-line pitch:** Clicky reads what you're looking at, processes it intelligently, and builds your personal knowledge base automatically.

### The core flow

```
You say: "I don't get this — summarize it and save the key points"
              ↓
OCR reads the screen (already works)
              ↓
Claude gets: screenshot + OCR text + your Profile (goals, level)
              ↓
Claude writes a personalised explanation + extracts key points
              ↓
[NOTE:DaVinci Resolve — Color Wheels]
## What it is
Color wheels let you shift hue and luminance in shadows/mids/highlights independently...
## Key points
- Lift = shadows, Gamma = midtones, Gain = highlights
- Offset shifts all ranges together
## Why it matters for you
Since you're building colour grading skills, this is the foundation...
[/NOTE]
              ↓
[LOG:DaVinci Resolve:color wheels]   ← silent, goes to learning store
              ↓
Apple Note created + topic logged
```

### Voice commands that trigger this

| You say | What happens |
|---------|-------------|
| "Summarize this and save it" | Key points note → Apple Notes + log |
| "I don't get this, explain it for me" | Personalised explanation spoken + saved |
| "Save the key points from this page" | Structured note with bullet points |
| "Create a study note from what I'm reading" | Full enhanced note → Apple Notes |
| "What are the main concepts here?" | Spoken summary, optionally saved |
| "Make a flashcard from this" | Q&A format note for later review |
| "Add this to my Resolve notes" | Appends to existing Resolve Apple Note |

### Why the Profile makes this better

Without Profile: generic summary anyone might get.  
With Profile (`name: joce`, `goals: get better at coding, learn DaVinci Resolve`):
- Explanations pitched at your level
- Connections made to your goals ("since you're learning color grading...")
- Topics tracked against what you said you want to learn
- Gaps surfaced ("you've covered color but never asked about audio mixing")

### The learning log

A local JSON store that grows silently with every processed screen:

```json
[
  { "app": "DaVinci Resolve", "topic": "color wheels",   "date": "2026-04-14", "noteTitle": "DaVinci Resolve — Color Wheels" },
  { "app": "DaVinci Resolve", "topic": "LUTs",           "date": "2026-04-15", "noteTitle": "DaVinci Resolve — LUTs" },
  { "app": "Xcode",           "topic": "Swift closures",  "date": "2026-04-16", "noteTitle": "Swift — Closures" }
]
```

You never touch this file. It builds itself from your conversations.

### What you can do with the log

- "What did I learn about Resolve this week?" → Claude reads the log, gives a summary
- "Quiz me on color grading" → Claude generates 3 questions from logged topics
- "What do I know about Swift so far?" → knowledge map
- "What haven't I covered yet in Resolve?" → gaps against a curriculum Claude knows
- Daily nudge (optional): "Yesterday you learned about LUTs — quick question to lock it in?"

### Settings → Learning tab (new)

| Setting | What it does |
|---------|-------------|
| Track learning topics | Toggle silent logging on/off |
| Quiz me | On demand / Daily nudge / Off |
| Topics learned | View log, delete entries |
| Export notes | Dump all as markdown (for Obsidian) |

---

## Phase 2 — macOS Action Reach

> **The one-line pitch:** Clicky controls your Mac — opens apps, sets reminders, runs your automations.

Not raw clipboard copy (useless) but genuine macOS reach via the same tag pattern:

```
[OPEN:https://resolve-docs.com]      → opens browser
[OPEN:DaVinci Resolve]               → launches app
[SHORTCUT:Create Reminder]           → runs your Apple Shortcut
[REMIND:Practice audio mixing:tomorrow 9am]  → EventKit reminder
```

### Why Shortcuts is the real unlock

You build a Shortcut once (2 min). Clicky triggers it forever by name. Through Shortcuts:
- Spotify / Apple Music play/pause/queue
- Calendar events
- Reminders
- Messages
- Home automation
- Any app with Shortcuts support

| You say | Clicky does |
|---------|-------------|
| "Remind me to practice Resolve tomorrow" | `[REMIND:...]` → macOS reminder appears |
| "Open the Resolve manual" | `[OPEN:url]` → browser |
| "Play something to focus" | `[SHORTCUT:Focus Music]` → Spotify |
| "Set a 25-minute timer" | `[SHORTCUT:Pomodoro Timer]` |
| "Open my coding project" | `[SHORTCUT:Open Project]` |

### What needs building

- `ActionTagParser.swift` — parses `[OPEN:]`, `[SHORTCUT:]`, `[REMIND:]` alongside existing `[NOTE:]` and `[POINT:]`
- `ActionExecutor.swift` — executes each:
  - `[OPEN:]` → `NSWorkspace.shared.open(url)`
  - `[SHORTCUT:]` → `Process("shortcuts", ["run", name])`
  - `[REMIND:]` → EventKit or Shortcuts
- Add to system prompts
- Settings → General: toggles per action type

---

## Phase 3 — Web Search

> **The one-line pitch:** Clicky stops having a knowledge cutoff. Works with all three model paths.

### Pattern B — search-then-answer (no tool-calling required)

```
User asks anything
       ↓
Web Search toggle on in Settings?
       ↓ yes
Worker → /search → Tavily API → clean results
       ↓
Results prepended to model context
       ↓
Claude / LM Studio / Apple Intelligence answers with live info
```

### Why Tavily

- Purpose-built for AI — returns summaries not raw HTML
- Free tier: 1000 req/month
- Single REST call

### What needs building

- Worker `/search` route → Tavily (new Worker secret: `TAVILY_API_KEY`)
- `WebSearchClient.swift`
- Wire into voice + chat pipelines
- Settings → General: Web Search toggle + Tavily key field

---

## Build order

```
Phase 1a  Screen → Note → Log          core learning loop, highest daily value
Phase 1b  Learning tab in Settings      surfaces the log, quiz on demand
Phase 2   macOS Actions (OPEN/SHORTCUT) reach into the OS, makes Phase 1 actionable
Phase 3   Web Search                    live info for all model paths
```

Phase 1 first because:
- It uses what Clicky already has (OCR + screenshot + Claude) — no new APIs
- It produces Apple Notes (already shipped) + a new learning log
- Every day you use Clicky it gets smarter about what you know
- Phase 2 makes it more useful (reminders after a study session), not required first

---

## Technical implementation notes

### All action tags share one parser

```swift
// Already shipped
[NOTE:title]content[/NOTE]    → Apple Notes (CompanionManager.parseAndStripNoteTags)
[POINT:x,y:label]             → cursor animation

// Phase 1
[LOG:app:topic]               → learning store (silent, no user-visible output)

// Phase 2
[OPEN:url-or-app]             → NSWorkspace
[SHORTCUT:name]               → Process("shortcuts", ["run", name])
[REMIND:text:date]            → EventKit / Shortcuts
```

One `ActionTagParser` replaces the individual parsers. Handles all tags in a single regex pass. Clean, testable, extensible.

### Learning store location

`~/Library/Application Support/Clicky/learning/log.json`

Same pattern as conversation storage. Append-only, lightweight, private.

### Worker routes

```
POST /chat             → Anthropic (existing)
POST /tts              → ElevenLabs (existing)
POST /transcribe-token → AssemblyAI (existing)
POST /search           → Tavily (Phase 3)
```
