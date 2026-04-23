# Accessibility Comparison: Clicky vs TipTour-macOS

A side-by-side comparison of macOS Accessibility (AX) API usage, permission flows,
and assistive features between **Clicky** (this repo) and
**[tiptour-macos](https://github.com/milind-soni/tiptour-macos)**.

> Note: TipTour's README explicitly credits its foundation as built on Clicky
> (`farzaa/clicky`), so the two apps share DNA. The divergence below reflects
> where each project took that foundation.

---

## 1. At-a-Glance

| Dimension | Clicky | TipTour |
|---|---|---|
| Core purpose | Voice + chat companion (ask about anything on screen) | Voice-guided **tutor** for Mac apps (step-by-step workflows) |
| Primary LLM | Claude (Sonnet 4.6 / Opus 4.6) via Cloudflare Worker | Gemini Live (3.1 Flash) via single WebSocket |
| UI grounding strategy | Claude vision → pixel coords (`[POINT:x,y]`), AX used for **text** | AX tree → YOLO+Vision OCR → LLM coords fallback |
| STT | AssemblyAI / OpenAI / Apple Speech / Parakeet (on-device) | Gemini Live (integrated, no separate STT) |
| TTS | ElevenLabs / Supertonic (on-device ONNX) | Gemini Live (integrated) |
| Minimum macOS | 14.2+ (ScreenCaptureKit) | 14+ (with 15+ ScreenContent support) |
| Push-to-talk | `ctrl + option` via listen-only CGEvent tap | `ctrl + option` via CGEvent tap |

---

## 2. macOS Accessibility API (AX*) Usage

### Clicky — AX as a **text reader**

Clicky leans on the AX tree mostly to extract text and word-level bounds from
the frontmost app, so local models can reason about screen content without
image encoding.

| Use | File | APIs |
|---|---|---|
| Read focused element text | `TextExtractor.swift` | `AXUIElementCreateSystemWide`, `kAXFocusedUIElementAttribute`, `kAXValueAttribute`, `kAXTitleAttribute`, `kAXChildrenAttribute` |
| Per-word bounding boxes | `TextExtractor.swift:221` | `AXBoundsForRangeParameterizedAttribute`, `AXValueCreate(.cfRange/.cgRect)` |
| OCR fallback | `TextExtractor.swift` | Vision framework (for Chrome/Electron where AX bounds are zero) |
| Window manipulation | `WindowPositionManager.swift` | `kAXFocusedWindowAttribute`, `kAXPositionAttribute`, `kAXSizeAttribute`, `AXUIElementSetAttributeValue` |
| Permission gate | `WindowPositionManager.swift:36,54-55` | `AXIsProcessTrusted`, `AXIsProcessTrustedWithOptions` + `kAXTrustedCheckOptionPrompt` |

Pointing at UI elements is done **outside** AX: Claude's vision model returns
pixel coordinates in `[POINT:x,y:label:screenN]` tags, which the overlay maps
to the right monitor (`ElementLocationDetector.swift`, `OverlayWindow.swift`).

### TipTour — AX as a **targeting primitive**

TipTour treats the AX tree as the first-class way to locate UI elements
("File", "New", "Save") and only falls back when AX is empty.

| Layer | Latency | Notes |
|---|---|---|
| **AX tree (primary)** | ~30 ms | `AXUIElement`, `AXObserver`, `AXValue`, `NSAccessibility` for native apps |
| **CoreML YOLO + Vision OCR** | ~200 ms, on-device | For Blender, Unity, Electron apps w/ custom rendering |
| **LLM raw coords** | slowest | Last resort only |

Clever optimization: an **AX-empty-tree cache** flags apps that don't expose AX
on first probe and skips AX polling for 10 minutes (saves ~2.7 s per step and
keeps audio smooth). Clicky has no equivalent caching layer — it always tries
AX first in `TextExtractor`.

### Verdict

- **Text/content reading**: Clicky is richer — it actively extracts words + bounds for local LLM prompts.
- **Element targeting**: TipTour is substantially more sophisticated — three-tier fallback with on-device YOLO, tuned for latency, and cached per-app.
- **Window layout control**: Only Clicky uses AX to reposition/resize overlapping windows.

---

## 3. Permissions Required

| Permission | Clicky | TipTour | Notes |
|---|---|---|---|
| Accessibility (AX) | ✅ required | ✅ required | Both use `AXIsProcessTrusted` gating |
| Screen Recording | ✅ required | ✅ required | Both use `ScreenCaptureKit` |
| Screen Content (macOS 15+) | — | ✅ | TipTour opts in explicitly |
| Microphone | ✅ | ✅ | Same entitlement |
| Speech Recognition | ✅ (Apple provider only) | — | Clicky has a pluggable STT layer |
| Apple Events (Automation) | ✅ Notes/Reminders | — | Clicky writes Reminders via AppleScript |
| Reminders (EventKit) | ✅ | — | For `[REMIND:…]` action tags |
| Input Monitoring (CGEvent) | ✅ (listen-only tap) | ✅ (CGEvent tap) | Both for global hotkey |

Clicky's `Info.plist` declares `NSMicrophoneUsageDescription`,
`NSSpeechRecognitionUsageDescription`, `NSScreenCaptureUsageDescription`,
`NSAppleEventsUsageDescription`, and `NSRemindersUsageDescription` — a broader
surface than TipTour's four-permission set because Clicky also performs
automation actions (open apps, run Shortcuts, create reminders, control music).

### Permission UX

- **Clicky** — state machine in `WindowPositionManager.swift` (`.alreadyGranted`,
  `.systemPrompt`, `.systemSettings`) with an in-app reveal-in-Finder helper so
  users can drop the bundle into the Accessibility list manually.
  `CompanionManager` polls all four permissions and fires
  `trackPermissionGranted` analytics when state changes.
- **TipTour** — centralized `PermissionManager`; permissions are described as
  *only active while the hotkey is held*, reinforcing its "nothing in the
  background" stance.

---

## 4. Global Hotkey / Input Monitoring

Both apps converge on the same shortcut (`ctrl + option`) and both use
`CGEvent.tapCreate`. Clicky's implementation
(`GlobalPushToTalkShortcutMonitor.swift`) specifies `.listenOnly` —
intentional, per `CLAUDE.md`, because modifier-only shortcuts are detected
more reliably that way than with `NSEvent` global monitors.

Clicky adds a second hotkey: `ctrl + shift + L` for read-aloud toggle. TipTour
sticks with a single hotkey (voice-first UX; no menu navigation).

---

## 5. Cursor Overlay & Pointing

| Aspect | Clicky | TipTour |
|---|---|---|
| Overlay window | Transparent NSPanel at `.screenSaver` z-level, `ignoresMouseEvents`, `canJoinAllSpaces`, `hidesOnDeactivate=false` (`OverlayWindow.swift:14-53`) | Equivalent full-screen transparent layer |
| Cursor art | Blue triangle (`OverlayWindow.swift:55-71`); optional "Neko" pixel-cat mode | Blue triangle + optional Neko mode (oneko, BSD-2) |
| Animation | Bezier arc to target, states: `.followingCursor`, `.navigatingToTarget`, `.pointingAtTarget` | Cursor fly-to + speech-bubble narration |
| Click detection | — | **`ClickDetector`** global `CGEventTap` watches for mouse-down inside the resolved rect → auto-advances workflow |
| Multi-monitor | Yes, coordinate mapping in overlay | Yes |

TipTour's click detection on the resolved AX rectangle is a feature Clicky does
**not** have. It converts the overlay from passive indicator into an
interactive step-through tutor.

---

## 6. UI Accessibility (Assistive Tech Support)

Neither app currently ships meaningful in-UI accessibility affordances.

- ❌ No SwiftUI `.accessibilityLabel` / `.accessibilityHint` / `.accessibilityValue` in Clicky's views
- ❌ No VoiceOver testing or rotor support documented
- ❌ No reduced-motion, increased-contrast, or dynamic-type respect
- ❌ No keyboard-only navigation beyond the global push-to-talk

TipTour's public documentation is similarly silent on these. Both projects
treat "accessibility" almost exclusively as *the AX API* (a system integration)
rather than *making the app itself accessible to assistive tech users*.

---

## 7. Architectural Implications

1. **AX as input vs. AX as output.** Clicky primarily *reads* through AX to
   feed LLMs; TipTour primarily *acts* through AX to locate click targets. This
   drives nearly every downstream difference.
2. **Latency budget.** TipTour's three-tier grounding + empty-tree cache is
   built for sub-second step advancement. Clicky accepts higher latency
   because it's conversational, not tutorial.
3. **Single pipeline vs. pluggable providers.** TipTour uses one Gemini Live
   WebSocket for STT + vision + LLM + TTS. Clicky splits those across
   AssemblyAI/OpenAI/Apple/Parakeet, Claude, and ElevenLabs/Supertonic —
   more moving parts, more user choice, and the on-device options (Parakeet,
   Supertonic) are genuine differentiators for privacy.
4. **Automation surface.** Only Clicky acts on the system beyond pointing:
   `[OPEN:…]`, `[SHORTCUT:…]`, `[REMIND:…]`, `[MUSIC:…]` action tags require
   Apple Events / EventKit / Shortcuts CLI / media keys. TipTour intentionally
   stays observational — narrate + point + detect click.

---

## 8. Suggested Improvements for Clicky (drawn from TipTour)

If the goal is to close the accessibility gap, the cheapest high-value wins
would be:

1. **Promote AX to a pointing source, not just a text source.** Today Clicky
   points where Claude's vision says to point. Using the AX tree for known
   native apps would be faster and pixel-accurate, with the current vision
   approach as fallback — mirrors TipTour's hierarchy.
2. **Add an AX-empty-tree cache** in `TextExtractor` and any future
   AX-grounding code path. Current code re-probes every call; a per-bundle-ID
   TTL cache avoids repeated ~seconds-long stalls on AX-hostile apps.
3. **Add a `ClickDetector`** so pointed-at elements auto-advance / dismiss the
   overlay when actually clicked. Useful for Clicky's `[POINT:…]` flow too.
4. **SwiftUI accessibility modifiers** on chat bubbles, toolbar buttons, and
   settings — this is the one area where *both* apps are weak and Clicky could
   lead. `.accessibilityLabel`, `.accessibilityValue` for the waveform and
   streaming indicator, and a "Reduce Motion" path that skips the bezier
   cursor arc.
5. **Document required permissions in one place.** TipTour's README tabulates
   the four permissions up front. Clicky's equivalent is scattered across
   `Info.plist`, `WindowPositionManager.swift`, and `CompanionManager.swift`.

---

## 9. Source Reference

Clicky paths cited above (all under repo root):

- `TextExtractor.swift` — AX text + OCR extraction
- `WindowPositionManager.swift` — AX permission flow, window layout via AX
- `GlobalPushToTalkShortcutMonitor.swift` — CGEvent listen-only tap
- `BuddyDictationManager.swift` — mic + speech permission, dictation pipeline
- `CompanionScreenCaptureUtility.swift` — ScreenCaptureKit multi-monitor
- `ElementLocationDetector.swift` — vision-based (non-AX) element pointing
- `OverlayWindow.swift` / `CompanionResponseOverlay.swift` — cursor overlay
- `CompanionManager.swift` — permission state polling, analytics
- `leanring-buddy.entitlements` — sandbox=false, audio-input, mach lookup

TipTour references come from the public GitHub repo's README / `AGENTS.md`.
