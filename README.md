<img src="docs/images/logo.png" alt="Voidamp logo" width="96" />

# Voidamp

A small macOS menu bar mixer for your apps, speakers, and microphones. Adjust Safari, Brave, Spotify, and other playing apps individually without opening their settings.

**Requires an Apple silicon Mac and macOS 14.2 or newer.** Liquid Glass is available on macOS 26 and newer.

![A volume for every app: Voidamp's menu bar panel and its volume card](docs/images/mixer.png)

![Wire any app to any output: the Voidamp Suite](docs/images/suite.png)

## Install

1. Download the [latest release](https://github.com/lumen-xx/voidamp-releases/releases/latest), unzip it, and move **Voidamp.app** to **Applications**.
2. Open it. If blocked, go to **System Settings → Privacy & Security → Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/Voidamp.app"
open "/Applications/Voidamp.app"
```

3. Allow system audio access when prompted, then click the sound icon in the menu bar.

## What it does

- Control each playing app’s volume from **0–200%**, with a snap at **100%**. Click an app’s percentage to return it to 100%.
- Show or hide one **System Sounds** row for alerts and notifications with **Show System Sounds** in Settings.
- Mute sound or microphones from the top bar.
- Choose an output or input device and adjust its volume or microphone gain.
- Right-click a device to give it a custom name in Voidamp.
- Save your device selections, levels, mute states and which outputs each app is wired to as **profiles** from **More → Profiles**. Microphone wires aren't part of a profile.
- Click **Suite** in the panel (or **More → Open Voidamp Suite…**) for a node editor. Drag apps, microphones and outputs from the sidebar onto the board, then drag a wire from an app to any output to play it there. Wire one app to several outputs, send alerts to their own device, or wire a microphone to headphones to hear yourself. Apps without a wire play on the default output, and apps that pick their own output keep it; their dashed wire is labelled “default” or “app’s choice”. When one app plays on several outputs, Voidamp holds back the faster ones so they stay in sync (Bluetooth runs behind built-in speakers); if it still sounds early or late, click the metronome on that output and drag until both sound as one. Output nodes can be muted. Turn on **Patchbay** in the Suite's corner and apps on the board play only where they're wired: an app without a wire is silent, while apps not on the board play as usual. A microphone node draws a “mic in use” line to apps on the board that record from it; each app picks its microphone in its own settings. Select nodes with a click or ⌘A and remove them with Delete, which also removes their wires. **⌘Z** undoes any change on the board (adding, moving or removing nodes, connecting or disconnecting wires) and puts removed wires back too; ⇧⌘Z redoes it. The **Suite** switch in the corner pauses all wires without forgetting them; turning Mixing off in the panel pauses them too. In the panel, an app the Suite sends elsewhere shows a small icon of its output, and the Mic button gets an orange dot while you hear a microphone. Input nodes show which apps are recording from that microphone.
- **Virtual mics:** click **Add Virtual Mics…** at the bottom of the Suite's sidebar to install “Voidamp Mic 1” and “Voidamp Mic 2” (macOS asks for your password, and sound pauses for a moment while the audio system restarts). Pick one as the microphone in Discord, FL Studio or any app, then wire a real microphone, or an app such as Spotify, into it on the board. Only apps that chose that virtual mic hear what you wire in, so one mic can go to Discord while another goes to FL Studio. Right-click a virtual mic to **Rename…** it; apps such as Discord show the new name too (some after reopening), and an empty name restores “Voidamp Mic 1”. Right-click a virtual mic in the sidebar to remove them again. Quitting Voidamp while an app records from a virtual mic you feed asks first, because that app would hear silence; logging out, restarting and updates don't ask. The driver is built from `Driver/` and checked with `bash scripts/check-driver.sh`. The mouse wheel zooms from 50% to 150%; drag the empty board to move around.
- Volume and brightness keys show Voidamp’s own overlay at the top of the screen. Clicks pass through it to the window underneath; rest the pointer on it for a moment to drag the level or click the speaker to mute. Brightness keys only act on the built-in display while the pointer is on it. It needs Accessibility permission, which Voidamp explains before macOS asks, and can be turned off in Settings.
- **Settings** (More → Settings…, or ⌘, while the Suite is open) live in the Suite's sidebar: Start at Login, System Sounds, the overlay, Suite wiring, Patchbay, virtual mics, profiles and updates. The More menu (the ⋯ button, or right-click the menu bar icon) keeps the Suite, Settings, Profiles, Check for Updates and Quit.
- Muting survives a crash: Voidamp remembers what it muted and the levels to return to, also for devices unplugged while muted. Unmuting clears a mute set outside Voidamp too.

Voidamp stays in your menu bar with no Dock icon. Its icon follows the active output and mute state using native speaker and headphone symbols. Audio stays on your Mac; it isn’t recorded to disk or uploaded. Boosting above 100% can distort loud audio. Some devices have fixed hardware volume, and some protected audio cannot be mixed.

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

Core Audio process taps capture and mute the original app output while a private aggregate device plays the adjusted signal on the app’s outputs: the default output, the one the app chose itself, or the outputs it is wired to in the Suite. Disabling mixing or quitting removes the routes and restores original app playback. A System Sounds wire changes macOS’s own output for alerts, which stays when the Suite is off or Voidamp quits. Failed routes show an error and leave their controls disabled. Output changes rebuild routes. Browser helper processes are grouped with their parent app when macOS exposes a matching bundle identity or bundle path; otherwise they may appear separately. Protected audio and unsupported output formats may not be mixable.

## Devices and mute

Expand **Devices** for output selection, microphone selection, device volume, and input gain. Rows remain alphabetically ordered when selection changes. Device sliders use the hardware’s supported 0–100% range; boosting applies to app audio.

The top **Sound** and **Mic** buttons toggle mute across connected devices, using native hardware mute where available and zero gain otherwise. Unmuting restores previous settings. Devices that expose neither writable mute nor volume cannot be silenced through these controls. Microphone gain-based silencing is not a hardware privacy switch.

## Profiles

Use **More → Profiles → Save Current as Profile…** (or **Save Current Setup…** in Settings) to save output/input device selection, writable device levels, app levels/mutes, the Suite’s app wiring, global mute states, and whether app mixing is enabled. Profiles persist locally; saving under an existing name updates that profile, and **Delete Profile** removes any of them without applying it first. Device unique identifiers keep profiles usable after reconnecting hardware. Missing devices are skipped; saved app settings apply when those apps next play audio with mixing enabled. Restoring a profile with mixing enabled resumes its app routes; macOS still requires system audio permission.

## Validation

```sh
swift build
.build/debug/Voidamp --self-check
```

The read-only audio self-check also uses an isolated preferences domain to verify profile persistence/deletion, stable device ordering, gain bounds, the 100% snap behavior, undo and redo on the Suite's board with its wiring, and which volume and brightness keys Voidamp takes.

The README images come from sample data in development builds, never from this Mac's apps or devices: `.build/debug/Voidamp --suite-preview --demo` and `--panel-preview --demo` print a window number for `screencapture -l`, `--overlay-snapshot <png> --clear` renders the volume cards, and `swift scripts/marketing.swift <out.png> <headline> <subtitle> <icon.png> <image.png>...` puts them on the background. App playback routing requires separate live verification with system audio permission.

Open `Package.swift` in Xcode to edit. Uses Sparkle for signed app updates. See [updates/README.md](updates/README.md) for release preparation, signing, and publishing.

Apple reference: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
