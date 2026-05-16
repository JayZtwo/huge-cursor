# Implementation Notes

## Public API Boundary

macOS can visually enlarge the pointer when users shake the mouse, but this app does not read that state.

The implementation intentionally avoids private APIs and instead treats shaking as a gesture that can be inferred from mouse movement:

- `NSEvent.addGlobalMonitorForEvents`
- `NSEvent.addLocalMonitorForEvents`
- `NSEvent.mouseLocation`

This makes the prototype easier to reason about and more portable as an open-source reference.

## Detector Shape

The detector keeps cursor samples in a short rolling time window.

Each update calculates:

- current movement speed
- peak speed
- total travel distance
- direction turns from trend vectors

The gesture triggers only when direction turns, distance, and peak speed cross their thresholds.

## Why Trend Vectors

Directly comparing every adjacent mouse segment can make the detector feel dull because high-frequency mouse events produce many tiny movements that do not individually represent the user's intent.

Huge Cursor accumulates small movements into short trend vectors before comparing direction. This keeps full-direction detection responsive without going back to horizontal-only logic.

## Overlay Shape

The floating input is an `NSPanel` hosting a SwiftUI view.

That split lets the app keep most UI code in SwiftUI while still using AppKit for desktop-level window placement, focus, and floating behavior.
