## Install

1. Download the [latest release](https://github.com/lumen-xx/voidamp-releases/releases/latest), unzip it, and move **Voidamp.app** to **Applications**.
2. Open it. If blocked, go to **System Settings → Privacy & Security → Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/Voidamp.app"
open "/Applications/Voidamp.app"
```

3. Allow system audio access when prompted, then click the sound icon in the menu bar.

<img src="docs/images/logo.png" alt="Voidamp logo" width="96" />

# Voidamp

A small macOS menu bar mixer for your apps, speakers, and microphones. Adjust Safari, Brave, Spotify, and other playing apps individually without opening their settings.

**Requires an Apple silicon Mac and macOS 14.2 or newer.** Liquid Glass is available on macOS 26 and newer.

## What it does

- Control each playing app’s volume from **0–200%**, with a snap at **100%**. Click an app’s percentage to return it to 100%.
- Show or hide one **System Sounds** row for alerts and notifications with **More → Show System Sounds in Mixing**.
- Mute sound or microphones from the top bar.
- Choose an output or input device and adjust its volume or microphone gain.
- Right-click a device to give it a custom name in Voidamp.
- Save your device selections, levels, and mute states as **profiles**.
- Volume and brightness keys show Voidamp’s own overlay at the top of the screen. Hover over it to drag the level or click the speaker to mute. It needs Accessibility permission and can be turned off with **More → Volume & Brightness Overlay**.
- Check for signed updates from **More → Check for Updates…**. Right-click the menu bar icon for the same More menu.
- Enable **More → Start at Login** to launch Voidamp automatically. If macOS asks for approval, use **Approve Start at Login…**.

Voidamp stays in your menu bar with no Dock icon. Its icon follows the active output and mute state using native speaker and headphone symbols. Audio stays on your Mac; it isn’t recorded to disk or uploaded. Boosting above 100% can distort loud audio. Some devices have fixed hardware volume, and some protected audio cannot be mixed.

## Screenshots

![Voidamp compact toolbar](docs/images/toolbar.png)

*Development screenshots; the current release uses native checkboxes, a Mixing switch, and a combined Profiles/More island.*

## If macOS blocks the app

Voidamp is not Apple notarized, so the first installation may be blocked. Use either method below for the Voidamp app downloaded from this repository.

### Open through System Settings

1. Try opening **Voidamp.app** once and dismiss the warning.
2. Open **System Settings → Privacy & Security** and scroll to **Security**.
3. Click **Open Anyway** beside the Voidamp warning, then confirm **Open**. Enter your Mac password if asked.

This approves Voidamp without changing your Mac’s general security settings. [Apple’s instructions](https://support.apple.com/en-us/102445).

### Remove quarantine through Terminal

After moving the app into Applications, open **Terminal** and run:

```sh
xattr -dr com.apple.quarantine "/Applications/Voidamp.app"
open "/Applications/Voidamp.app"
```

The first command removes the download quarantine flag from **Voidamp.app only**; the second opens it. If you installed it somewhere else, replace the path with its actual location.

## Updates

Use **More → Check for Updates…**. Voidamp also checks automatically and lets you choose whether to install. Sparkle verifies signed update archives and the update feed. Older builds without Sparkle need this updater-enabled version installed once.

## Development

## Build and run

```sh
bash scripts/build-app.sh
open dist/Voidamp.app
```

Drag `dist/Voidamp.app` into Applications if desired. Voidamp runs in the menu bar without a Dock icon or main window. Click the sound icon to open the panel; quit from the ellipsis menu. Builds are signed with a stable local identity, **Voidamp Local Signing**, which `scripts/signing-identity.sh` creates once in `~/Library/Keychains/voidamp-signing.keychain-db` (password in `~/.config/voidamp/signing-password`). Because the identity never changes, macOS keeps the Screen & System Audio Recording permission across updates. Back up both files: with a new identity, users must allow audio access once more. It isn't an Apple Developer ID, so first installs still need **Open Anyway**.

## App mixing

Mixing is on by default at launch. The native **Mixing** switch turns it on or off. Play audio in an app to see its controls. An app only runs through Voidamp once its level or mute differs from normal; untouched apps play directly. Levels are remembered per app. macOS requires permission in **System Settings → Privacy & Security → Screen & System Audio Recording**. If nothing can be captured, Voidamp leaves every app playing normally and shows a notice with **Open Settings** and **Retry** instead of an alert. Builds up to 1.1.18 were ad-hoc signed and lost this permission after each update; after updating from them, turn Voidamp off and on again there once. No audio is recorded to disk or transmitted.

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

Open `Package.swift` in Xcode to edit. Uses Sparkle for signed app updates. See [updates/README.md](updates/README.md) for release preparation, signing, and publishing.

Apple reference: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
