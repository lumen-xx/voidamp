<img src="docs/images/logo.png" alt="Voidamp logo" width="96" />

# Voidamp

A small macOS menu bar mixer for your apps, speakers, and microphones. Adjust Safari, Brave, Spotify, and other playing apps individually without opening their settings.

**Requires an Apple silicon Mac and macOS 14.2 or newer.** Liquid Glass is available on macOS 26 and newer.

## What it does

- Control each playing app’s volume from **0–200%**, with a snap at **100%**.
- Mute sound or microphones from the top bar.
- Choose an output or input device and adjust its volume or microphone gain.
- Right-click a device to give it a custom name in Voidamp.
- Save your device selections, levels, and mute states as **profiles**.
- Check for signed updates from **More → Check for Updates…**.

Voidamp stays in your menu bar with no Dock icon. Audio stays on your Mac; it isn’t recorded to disk or uploaded. Boosting above 100% can distort loud audio. Some devices have fixed hardware volume, and some protected audio cannot be mixed.

## Screenshots

![Voidamp compact toolbar](docs/images/toolbar.png)

*Development screenshots; the current release uses native checkboxes, a Mixing switch, and a combined Profiles/More island.*

## Install

1. Download the ZIP from the [latest release](https://github.com/lumen-xx/voidmap-releases/releases/latest) and unzip it.
2. Drag **Voidamp.app** into **Applications**, then open it.
3. Allow system audio access when prompted. You can also enable it in **System Settings → Privacy & Security → Screen & System Audio Recording**.
4. Click the sliders icon in the menu bar. Play audio in an app to see its volume control.

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

This repository contains public releases and the update feed. The source repository is private.
