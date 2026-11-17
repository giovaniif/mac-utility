# Changelog

Each `## <version>` section is that release's notes: CI copies it into the
GitHub release and into the update window. Add the next version's section
before tagging `v<version>`.

## 0.1.15

- Over-the-air updates: Mac Utility checks for a new version every 6 hours and offers to install it, then relaunches. No more downloading the DMG. "Check for Updates…" in the menu checks now. This is the last version you install by hand.

## 0.1.14

- Focus: native tabs (Ghostty, Terminal, Xcode…) no longer follow you to every set. A tab group holds one slot, and it now always goes to the tab that's showing, even when the app draws its tabs in the title bar. Switching or closing tabs hands the slot to the tab now showing.
- Focus: drag a window out of a shelf card onto the screen. Dropped on a window, the two trade places (with Undo). Dropped on the side of a lone window, it opens beside it. Dropped on an empty set, it takes the screen. Esc cancels.
- Capture: earlier screenshots and recordings in the corner hide while you take a new one, and come back with it.

## 0.1.13

- Focus: locking the screen no longer scrambles your sets. Windows macOS moves while the screen is locked stay in their sets, and apps that are slow to wake up after unlock aren't dropped from Focus.

## 0.1.12

- Focus: native tabs (Terminal, Finder and others) count as one window. New tabs no longer spill into another set.

## 0.1.11

- Focus: swipe sideways to change sets: 3 or 4 fingers on a trackpad, 2 on a Magic Mouse. Turn off "Swipe between full-screen applications" in System Settings so macOS does not switch Spaces too.
- Focus: swipes work on trackpads connected after launch.

## 0.1.10

- Focus: Finder, System Settings, app settings windows and sign-in or web popups open on top and never join a set. The float toggle tiles one anyway.
- Focus: keeps working after the screen locks or the Mac wakes.
