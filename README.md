# Voidamp

A compact, native macOS menu bar audio mixer. SwiftUI and AppKit controls, with Liquid Glass on macOS 26 and newer. Requires macOS 14.2 or newer; older versions use native material and bordered buttons.

## Build and run

```sh
bash scripts/build-app.sh
open dist/Voidamp.app
```

Drag `dist/Voidamp.app` into Applications if desired. Voidamp runs in the menu bar without a Dock icon or main window. Click the sliders icon to open the panel; quit from the ellipsis menu. The build is ad-hoc signed. Sharing with other Macs requires Developer ID signing and notarization.

## App mixing

Mixing is on by default at launch. The native **Mixing** switch turns it on or off. Play audio in an app to see its controls. macOS requires permission in **System Settings → Privacy & Security → Screen & System Audio Recording**. No audio is recorded to disk or transmitted.

Each playing app has a gain slider from 0% to 200% and its own mute button. While dragging, values within four percentage points of 100% snap to normal volume. Keyboard adjustment stays continuous. Boosting amplifies the app’s audio samples; loud material can distort at boosted levels. Samples are limited to the output’s range.

Core Audio process taps capture and mute the original app output while a private aggregate device plays the adjusted signal through the current default output. Disabling mixing or quitting removes the routes and restores original app playback. Failed routes show an error and leave their controls disabled. Output changes rebuild routes. Browser helper processes are grouped with their parent app when macOS exposes a matching bundle identity or bundle path; otherwise they may appear separately. Protected audio and unsupported output formats may not be mixable.

## Devices and mute

Expand **Devices** for output selection, microphone selection, device volume, and input gain. Rows remain alphabetically ordered when selection changes. Device sliders use the hardware’s supported 0–100% range; boosting applies to app audio.

The top **Sound** and **Mic** buttons toggle mute across connected devices, using native hardware mute where available and zero gain otherwise. Unmuting restores previous settings. Devices that expose neither writable mute nor volume cannot be silenced through these controls. Microphone gain-based silencing is not a hardware privacy switch.

## Profiles

Use **Profiles → Save current as profile…** to save output/input device selection, writable device levels, app levels/mutes, global mute states, and whether app mixing is enabled. Profiles persist locally. Device unique identifiers keep profiles usable after reconnecting hardware. Missing devices are skipped; saved app settings apply when those apps next play audio with mixing enabled. Restoring a profile with mixing enabled resumes its app routes; macOS still requires system audio permission.

## Validation

```sh
swift build
.build/debug/Voidamp --self-check
```

The read-only audio self-check also uses an isolated preferences domain to verify profile persistence/deletion, stable device ordering, gain bounds, and the 100% snap behavior. App playback routing requires separate live verification with system audio permission.

Open `Package.swift` in Xcode to edit. No dependencies.

Apple reference: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
