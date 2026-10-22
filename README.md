# Mac Utility

A small macOS menu bar app that bundles a few everyday tools: keyboard cleaning mode, clipboard history, CleanShot-style screenshots and screen recording, and moving windows between displays.

Native Swift (SwiftUI + AppKit), macOS 14 or later. Every feature can be switched off on its own.

## Features

### Keyboard cleaning mode — `⌃⌥⌘K`

Locks the keyboard so you can wipe it without typing into whatever is open.

- Blocks every key, including media, brightness and volume keys.
- Shows a full-screen overlay on every display with a countdown.
- The mouse and trackpad keep working. Flip the switch on the overlay to unlock.
- Unlocks by itself after 60 seconds, so you can never get stuck.
- The power/Touch ID button and the Globe key's hardware functions can't be blocked from user space.

### Clipboard history — `⇧⌘V`

Remembers what you copy and lets you paste it again.

- Keeps text, rich text, images and files, with the app each item came from.
- Opens as a strip of cards along the bottom of the screen without stealing focus from the app you're in.
- Type to search. `←`/`→` to move, `Return` to paste, `⇧Return` to paste as plain text, `⌘1`–`⌘9` for quick paste, `⌘P` to pin, `⌫` to delete, `Esc` to close.
- Copying the same thing again moves it to the top instead of adding a duplicate.
- Skips anything password managers mark as hidden, and never records 1Password or Keychain Access.
- Keeps the last 1,000 items or 30 days, whichever comes first. Pinned items never expire.
- Stored locally in SQLite (via [GRDB](https://github.com/groue/GRDB.swift)) with full-text search, in `~/Library/Application Support/MacUtility/`. Nothing leaves your Mac.

### Screen capture — `⇧⌘4` / `⇧⌘3` / `⇧⌘5`

Screenshots and screen recordings in the style of CleanShot. They take over the macOS screenshot shortcuts.

- `⇧⌘4` shows a crosshair. Drag to capture an area, with a live size label, or press `Space` and click a window. `Esc` cancels.
- `⇧⌘3` captures the whole screen under the pointer.
- `⇧⌘5` records the screen. Drag an area, or click or press `Return` for the full screen. A small floating bar shows the elapsed time and a Stop button, and stays out of the video. Press `⇧⌘5` again to stop.
- While recording you can add a round camera bubble you can drag around, your microphone, and a pill that shows the keys you press. Each one has a switch in the menu bar panel and in Settings.
- After each capture a thumbnail stacks in the bottom-left corner. Drag it into any app, or hover for Copy, Show in Finder, Open and Trash. It goes away by itself after a few seconds.
- macOS keeps its own screenshot shortcuts until you turn them off in System Settings → Keyboard → Keyboard Shortcuts → Screenshots. Settings shows a notice with a button to open that page while they're still on.
- Screenshots are saved as PNG (sharp on Retina displays) and recordings as H.264 MP4, on the Desktop.

### Window manager — `⌃⌘→` / `⌃⌘←`

Moves the focused window to the next or previous display, keeping its relative position and size.

## Menu bar and Settings

The menu bar panel holds on/off switches: one to start keyboard cleaning, one each to turn clipboard history, the window manager and screen capture on or off, and the camera, microphone and keystroke options for recordings.

Settings has the feature switches, launch at login, every shortcut (all of them can be changed) and the permission status.

## Permissions

| Permission | Used for |
| --- | --- |
| Accessibility | Moving windows and pasting from clipboard history |
| Input Monitoring | Blocking the keyboard in cleaning mode, showing keystrokes in recordings |
| Screen Recording | Screenshots and screen recordings |
| Camera, Microphone | The camera bubble and voice in recordings, only if you turn them on |

The app asks for each one when a feature first needs it. Settings shows what's granted.

## Building

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open MacUtility.xcodeproj
```

The project is generated from `project.yml`, so `MacUtility.xcodeproj` isn't checked in. Set `DEVELOPMENT_TEAM` in `project.yml` to your own team so macOS keeps permission grants across rebuilds.

To build from the command line:

```bash
xcodebuild -project MacUtility.xcodeproj -scheme MacUtility -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/MacUtility.app
```

## Tweaks

A few settings have no UI yet and can be changed with `defaults`:

```bash
defaults write com.giovani.MacUtility keyboardCleaningTimeout 30        # seconds before auto-unlock
defaults write com.giovani.MacUtility clipboardMaxItems 500             # history size
defaults write com.giovani.MacUtility clipboardMaxDays 7                # history age
defaults write com.giovani.MacUtility clipboardExcludedApps -array com.1password.1password
defaults write com.giovani.MacUtility captureFolder ~/Pictures/Captures # where captures are saved
```

## Project layout

```
MacUtility/
  App/        app entry point and menu bar panel
  Core/       features, hotkeys, permissions, Settings
  Features/
    KeyboardClean/   event tap and cleaning overlay
    Clipboard/       watcher, SQLite store and picker panel
    Capture/         area/window picker, screenshots, recorder, previews
    Windows/         window mover
DESIGN.md     design notes for each feature
```

Built with [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) and [GRDB](https://github.com/groue/GRDB.swift).
