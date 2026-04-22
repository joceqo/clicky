# Playback Overlay Design (deferred)

Design notes for a SuperUtter-style playback overlay on top of Clicky's TTS
engine. Captures the intent so the feature can be picked up later — not
scheduled yet.

## What it is

A small, always-on-top, draggable control bar that appears while TTS is
playing and lets the user scrub, skip, adjust speed, and skip between
utterances. Inspired by SuperUtter's "Classic" overlay:

```
[-10s] [restart] [+10s]   00:12 / 01:04   [-] 1x [+]   [prev] [next]   [×]
────────────────────────────────────────────────────────────────────────
▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
```

Three display modes: **Classic** (full controls), **Mini** (just play/pause
+ progress + close), **Off** (no overlay — current behavior).

## Why we want it

The `clicky://` Claude Code hook shipped in this round means Clicky now
reads long assistant turns. Once a turn is a minute or two long, the user
needs real controls — pause, skip to the end, rewind 10 seconds if they
missed something. Fire-and-forget isn't enough for that use case.

Also raises TTS to a first-class in-app feature instead of a transparent
background process, which matches how users already think about it
("Clicky is reading to me").

## Controls to ship (Classic mode)

| Control | Behavior | Keyboard |
|---|---|---|
| Skip -10s | `currentTime -= 10` | ⌘⌥← |
| Restart | `currentTime = 0` | ⌘⌥↑ |
| Skip +10s | `currentTime += 10` | ⌘⌥→ |
| Time display | `mm:ss / mm:ss` | — |
| Speed - / 1× / + | `rate` stepping 0.75/1.0/1.25/1.5/1.75/2.0 | ⌘⌥- / ⌘⌥+ |
| Previous | Jump to previous utterance in queue | ⌘⌥↑ (long press?) |
| Next | Jump to next utterance in queue | ⌘⌥↓ |
| Close | Dismiss overlay (does not stop audio) | Esc |
| Progress bar | Seekable scrubber | drag |

Mini mode drops: skip ±10, speed controls, prev/next. Keeps play/pause,
progress, close.

## Backend constraints

The two current TTS backends differ in what they can support:

### ElevenLabs (cloud)
- Returns a complete MP3 blob from the proxy (`/tts`).
- Already played via `AVAudioPlayer`, which supports `currentTime`,
  `rate` (with `enableRate = true`), `pause`, `play`.
- **All controls supported out of the box.**

### Supertonic (on-device ONNX)
- Synthesizes text chunk-by-chunk via ONNX Runtime.
- Current `SupertonicTTSClient` synthesizes into a single buffer then plays.
  If we keep that pattern → same capabilities as ElevenLabs.
- If we switch to streaming playback (play chunk N while synthesizing N+1)
  → seek forward into unsynthesized territory is impossible; rewind is fine
  since past audio is buffered.
- **Decision:** for v1 keep the full-buffer pattern so seek works uniformly.
  Revisit if startup latency on long texts becomes an issue.

### Kokoro (read-aloud)
- Out of scope. Kokoro is already bound to the per-word highlight overlay
  (⌃⇧L read-aloud) which has its own UI and timing contract. The playback
  overlay targets chat + `clicky://` TTS only.

## State machine

```
         ┌──────── speakExternalText / chat response ────────┐
         ▼                                                    │
    [Queueing] ──► [Synthesizing] ──► [Playing] ◄──► [Paused]─┤
         ▲                                │     ┌──► [Seeking]┤
         └────────── queue advance ◄──────┘     │             │
                                                └──── done ───┘
```

Needs a new `TTSPlaybackController` (probably in a new file) that:

- Owns the active `AVAudioPlayer` reference (currently owned ad-hoc inside
  each client).
- Maintains a FIFO queue of pending utterances — new calls during playback
  enqueue rather than interrupt (matches SuperUtter's "no interruption
  mid-sentence" behavior).
- Publishes `@Published` state: `isPlaying`, `currentTime`, `duration`,
  `rate`, `queueLength`, `currentUtterance`.
- Is what the overlay view observes.

## Overlay host

Not the cursor overlay (`OverlayWindow.swift`). That one is full-screen,
non-interactive, and carries the blue cursor — wrong shape for a clickable
control bar.

Create a new `NSPanel`:
- `.nonactivatingPanel`, `.titled`, `.closable = false`, `.floating` level.
- Collects on all Spaces, stays visible when Clicky is not frontmost.
- Draggable by background (`isMovableByWindowBackground`).
- Remembers last position per screen in UserDefaults.
- SwiftUI content via `NSHostingView`.

File layout:
- `TTSPlaybackController.swift` — queue + state + AVAudioPlayer ownership.
- `TTSPlaybackOverlayWindow.swift` — the NSPanel + window-lifecycle.
- `TTSPlaybackOverlayView.swift` — SwiftUI Classic/Mini views.

## Settings

Add a "Playback overlay" section in `ChatSettingsView.swift` General tab:
- Mode: Classic / Mini / Off (default Classic).
- Auto-hide delay after playback ends: 0s, 2s, 5s, never (default 2s).
- Default playback speed: 0.75×–2×, step 0.25 (default 1×).
- Remember position across app restarts: toggle (default on).

## Open questions

- **Should the overlay also show the transcript?** SuperUtter's overlay is
  controls-only; they keep text in a separate History panel. For Clicky the
  chat window already shows text, so controls-only is probably right. Skip
  for v1.
- **Does the dock icon animate while playing?** Could be a nice ambient
  indicator — bounce once when a new utterance queues, subtle pulse while
  playing. Low priority, defer.
- **Global hotkeys?** SuperUtter ships seven. We already have ⌃⌥ (push to
  talk) and ⌥⌘R (read aloud). Pick a small set that doesn't collide —
  probably pause/resume and skip-next would be enough at first.
- **Queue dedup?** If the Claude Code hook fires twice for the same turn
  (retry, resume), we shouldn't speak it twice. Key off
  `session_id + message_id` from the Stop payload.

## Non-goals (for v1)

- Seeking *inside* Supertonic streaming synthesis. Full-buffer mode is
  enough.
- History tab. Existing chat window covers this.
- Multi-instance overlay (one per screen). One overlay is enough.
- Cloud sync of queue across devices. Out of scope, we're macOS-only.

## Rough effort

- `TTSPlaybackController` refactor: 1 day
- Overlay window + SwiftUI views: 1 day
- Settings wiring + persistence: half day
- Polish (dragging, multi-screen, auto-hide, keyboard): half day
- **Total:** ~3 days of focused work.
