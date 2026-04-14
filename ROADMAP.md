# Clicky — Roadmap

## What Clicky already does (shipped)

- Push-to-talk voice → screenshot → Claude/LM Studio/Apple Intelligence → spoken response
- Blue cursor flies to and points at UI elements Claude references
- Multi-conversation text chat window with sidebar
- User profile card (name, goals, context) injected into every system prompt
- Apple Notes action tag: say "save this to my notes" → `[NOTE:title]content[/NOTE]` → note created silently
- Settings with Profile and General tabs
- AssemblyAI / Parakeet STT, ElevenLabs / Supertonic TTS

---

## Phase 1 — Action Tag System

> **The one-line pitch:** Clicky stops being a chatbot and starts being an agent that can *do things* on your Mac.

### How it works

Claude already embeds tags in responses — `[POINT:x,y:label]` flies the cursor to a UI element.
The action tag system uses the same pattern for macOS actions:

```
[COPY:the text to copy]
[OPEN:https://example.com]
[OPEN:Xcode]
[SHORTCUT:Morning Routine]
[REMIND:Fix that bug:tomorrow 10am]
[NOTE:title]content[/NOTE]   ← already shipped
```

Swift intercepts these tags, strips them from the spoken/displayed text, and executes the action silently. Zero friction — you just speak naturally and things happen.

### Concrete examples

| You say | Clicky does |
|---------|-------------|
| "Copy that error message" | OCR reads the error → copies to clipboard |
| "Open the Resolve docs" | Opens browser to the docs page |
| "Open my project in Xcode" | Launches Xcode with your project |
| "Remind me to practice Resolve tomorrow at 10" | Creates a macOS reminder |
| "Add this to my morning routine shortcut" | Runs an Apple Shortcut you built once |
| "Search YouTube for color grading tutorial" | Opens YouTube search in browser |
| "Play something chill" | Runs your Spotify shortcut |

### Why Apple Shortcuts is the unlock

You build a Shortcut once in the Shortcuts app (takes 2 minutes). Clicky can then run it by name with `[SHORTCUT:name]`. This gives Clicky access to:

- Spotify / Apple Music controls
- Calendar events
- Reminders
- Messages / email
- Home automation
- Any app with a Shortcuts integration
- Custom multi-step automations

No extra API keys. No extra code. The Shortcuts ecosystem does the work.

### What needs building

- `ActionTagParser.swift` — parse all action tags from response text in one pass (alongside existing NOTE + POINT parsers)
- `ActionExecutor.swift` — execute each action type:
  - `[COPY:]` → `NSPasteboard`
  - `[OPEN:]` → `NSWorkspace.shared.open(url)` or `NSWorkspace.shared.openApplication`
  - `[SHORTCUT:]` → `Process("shortcuts", ["run", name])`
  - `[REMIND:]` → EventKit or Shortcuts
- Add action tag instructions to both voice and chat system prompts
- Settings → General: toggle which action types are enabled

---

## Phase 2 — Learning Loop

> **The one-line pitch:** Clicky remembers what you learn and turns it into a personal knowledge base that grows with every conversation.

### How it works

Today: you ask a question → Clicky answers → conversation history lives for the session → gone.

With the learning loop:

1. **Passive logging** — after each exchange about an app or topic, Clicky silently appends to a local log:
   ```json
   { "app": "DaVinci Resolve", "topic": "color wheels", "date": "2026-04-14", "summary": "..." }
   ```
   No extra steps from you. It just builds up as you use Clicky normally.

2. **Active recall** — you can ask:
   - "What did I learn about Resolve this week?" → summary from the log
   - "Quiz me on color grading" → Claude generates 3 questions from your logged topics
   - "What do I know about Swift?" → knowledge map of everything you've asked

3. **Spaced repetition nudge** — Clicky can surface a quiz when you open it after a day away:
   "Yesterday you asked about LUTs in Resolve — want a quick question?"

### Connection to the Profile card

The Profile card says *what you want to learn* (goals). The learning log tracks *what you've actually covered*. Together:

- Profile: "I want to get better at DaVinci Resolve"
- Log: "You've asked about color wheels 3×, LUTs 2×, never asked about audio mixing"
- Clicky can then say: "you've covered color pretty well — want to explore audio next?"

### Settings tab: Learning

A new **Learning** tab in settings:

| Setting | What it does |
|---------|-------------|
| Track learning topics | Toggle passive logging on/off |
| Quiz frequency | Never / Daily nudge / On demand only |
| Topics learned | View the log, delete entries |
| Export knowledge | Export as markdown for Obsidian / Notion |

### What needs building

- `LearningLog.swift` — local JSON store per topic/app, append-only
- `LearningLogStore.swift` — load/query/search the log (by app, date range, topic)
- Hook into voice + chat pipelines: after each response, detect if a topic was taught and append to log
- Quiz generation: pass recent log entries to Claude as context, ask for questions
- Settings → Learning tab

---

## Phase 3 — Web Search

> **The one-line pitch:** Clicky stops having a knowledge cutoff. Ask about anything current.

### How it works (Pattern B — works with all models)

```
User asks question
       ↓
Is web search enabled? (Settings toggle)
       ↓ yes
Clicky calls Worker → /search → Tavily API
       ↓
Results prepended to context:

[Web search: "latest DaVinci Resolve update"]
1. Blackmagic blog: "Resolve 20 released..."
2. Reddit: "New color science in 20..."
[End search results]

       ↓
Sent to Claude / LM Studio / Apple Intelligence
       ↓
Model answers using live info
```

Works identically across all three model paths — no tool-calling support required.

### Why Tavily

- Purpose-built for AI — returns clean summaries, not raw HTML
- Free tier: 1000 req/month (plenty for personal use)
- Single REST call, returns structured JSON
- Handles news, docs, Reddit, blog posts well

### What needs building

- Worker `/search` route → Tavily
- `WebSearchClient.swift` — calls Worker, formats results as context block
- Wire into voice + chat pipelines (before sending to model)
- Settings → General: Web Search toggle + Tavily API key field
- Worker secret: `TAVILY_API_KEY`

---

## Phase 4 — App-Specific Intelligence

> **The one-line pitch:** Clicky becomes an expert in whatever app is on your screen.

Already works free today (screenshot + Claude): "what's this error?", "what keyboard shortcut does X?", "explain what I'm looking at"

Extensions:
- Xcode: read build errors via Accessibility API → suggest fix
- Terminal: read command output → diagnose
- Browser: summarize the page → explain concepts
- Figma: describe the selected component
- Any app: "what shortcut does X?" → reads menu bar via Accessibility API

---

## Build order rationale

```
Phase 1 (Action Tags)  →  immediate, tangible, daily-use value
       ↓
Phase 2 (Learning Loop) →  builds on conversations you're already having
       ↓
Phase 3 (Web Search)    →  unlocks current info for all model paths
       ↓
Phase 4 (App Intel)     →  deepens per-app value over time
```

Phase 1 first because every action tag ships value the moment it's built — you don't need a database of past conversations, you don't need a search API key, you just speak and your Mac does something. It also makes the learning loop better (you can say "save quiz for tomorrow" and it actually creates a reminder).

---

## Technical notes

### Action tag parsing (all phases share this)

All tags follow the same pattern already established by `[POINT:...]` and `[NOTE:...]`:

```swift
// Already shipped
[NOTE:title]content[/NOTE]    → Apple Notes
[POINT:x,y:label]             → cursor animation

// To add
[COPY:text]                   → NSPasteboard
[OPEN:url-or-app]             → NSWorkspace
[SHORTCUT:name]               → Process("shortcuts", ["run", name])
[REMIND:text:date]            → EventKit / Shortcuts
[SEARCH:query]                → web search (Phase 3)
[LOG:app:topic:summary]       → learning log (Phase 2)
```

One `ActionTagParser` handles all of them in one regex pass. Clean.

### Local storage (Phase 2)

Learning log lives in `~/Library/Application Support/Clicky/learning/` — same pattern as conversation storage. Each topic gets a JSON file. No database needed.

### Worker routes (Phase 3)

```
POST /search  → Tavily → { answer, results: [{title, url, content}] }
```

Secret to add: `TAVILY_API_KEY`
