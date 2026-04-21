//
//  MusicController.swift
//  leanring-buddy
//
//  Controls system-wide music playback via media key simulation.
//  Works with any app that holds media focus: Spotify (free or premium),
//  Apple Music, YouTube in Chrome/Safari, Tidal, etc. — no app-specific
//  API or extra permission required beyond what the app already has.
//
//  Also reads MPNowPlayingInfoCenter so Claude can tell the user what's
//  currently playing without needing a screen capture.
//
//  Supported [MUSIC:] actions:
//    play     → media play key (starts playback)
//    pause    → media pause key (same physical key as play on most hardware)
//    toggle   → media play/pause toggle key
//    next     → media next-track key
//    prev     → media previous-track key
//

import AppKit
import MediaPlayer

enum MusicController {

    // NX_KEYTYPE_* constants from IOKit/hidsystem/ev_keymap.h, reproduced here
    // so we don't need to bridge C headers. These are stable across macOS versions.
    private static let mediaKeyCodePlayPause: Int32 = 16  // NX_KEYTYPE_PLAY
    private static let mediaKeyCodeNextTrack: Int32  = 17  // NX_KEYTYPE_FAST
    private static let mediaKeyCodePrevTrack: Int32  = 18  // NX_KEYTYPE_REWIND

    // MARK: - Action dispatcher

    /// Routes a [MUSIC:action] tag emitted by Claude to the correct media key.
    /// Called by CompanionManager after stripping the tag from the spoken text.
    static func handleMusicAction(_ action: String) {
        switch action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "play", "pause", "toggle":
            // macOS media keys don't distinguish play from pause — the OS sends
            // a single play/pause toggle to whichever app holds media focus.
            sendMediaKey(mediaKeyCodePlayPause)
        case "next":
            sendMediaKey(mediaKeyCodeNextTrack)
        case "prev", "previous":
            sendMediaKey(mediaKeyCodePrevTrack)
        default:
            print("⚠️ MusicController: unrecognized action '\(action)'")
        }
    }

    // MARK: - Now playing context

    /// Returns a human-readable description of what's currently playing,
    /// e.g. "Bohemian Rhapsody by Queen", or nil if nothing is active.
    ///
    /// Injected into the Claude system prompt so the user can ask
    /// "what's this song?" or "skip this" without needing a screenshot.
    static func currentlyPlayingDescription() -> String? {
        guard let nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            return nil
        }

        let trackTitle  = nowPlayingInfo[MPMediaItemPropertyTitle]  as? String
        let artistName  = nowPlayingInfo[MPMediaItemPropertyArtist] as? String
        let albumTitle  = nowPlayingInfo[MPMediaItemPropertyAlbumTitle] as? String

        if let trackTitle, let artistName, !trackTitle.isEmpty, !artistName.isEmpty {
            return "\(trackTitle) by \(artistName)"
        } else if let trackTitle, let albumTitle, !trackTitle.isEmpty {
            return "\(trackTitle) (\(albumTitle))"
        } else if let trackTitle, !trackTitle.isEmpty {
            return trackTitle
        }
        return nil
    }

    // MARK: - Media key simulation

    /// Posts a media key event (key-down immediately followed by key-up) to
    /// the HID event system. The OS routes it to whichever app currently
    /// holds media focus — Spotify, Apple Music, Safari, Chrome, etc.
    ///
    /// The NX_SUBTYPE_AV_SYSTEM_DEFINED_KEYBOARD_KEY events (subtype 8) are the
    /// correct mechanism for media keys on macOS; they match what the physical
    /// keyboard sends and are handled by all conforming media apps.
    ///
    /// data1 encoding (from IOKit ev_keymap.h):
    ///   bits 23–16 → key code (NX_KEYTYPE_*)
    ///   bits 11–8  → NX_KEYTYPE_AV_SYSTEM_DEFINED (0xa)
    ///   bit 11     → 0 = key down, 1 = key up
    private static func sendMediaKey(_ keyCode: Int32) {
        let keyDownData1 = (Int(keyCode) << 16) | (0xa << 8)
        let keyUpData1   = (Int(keyCode) << 16) | (0xa << 8) | (1 << 11)

        func makeSystemDefinedEvent(data1: Int) -> NSEvent? {
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo().systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8, // NX_SUBTYPE_AV_SYSTEM_DEFINED_KEYBOARD_KEY
                data1: data1,
                data2: -1
            )
        }

        makeSystemDefinedEvent(data1: keyDownData1)?.cgEvent?.post(tap: .cghidEventTap)
        makeSystemDefinedEvent(data1: keyUpData1)?.cgEvent?.post(tap: .cghidEventTap)

        print("🎵 MusicController: sent media key \(keyCode) (\(actionNameForKeyCode(keyCode)))")
    }

    private static func actionNameForKeyCode(_ keyCode: Int32) -> String {
        switch keyCode {
        case mediaKeyCodePlayPause: return "play/pause"
        case mediaKeyCodeNextTrack:  return "next"
        case mediaKeyCodePrevTrack:  return "prev"
        default:                     return "unknown"
        }
    }
}
