# Voidamp interface

Use native SwiftUI and AppKit components, with system Liquid Glass on macOS 26 and native material on earlier versions. Respect the system appearance and accent color.

## Typography

All text uses San Francisco through the shared `MixerStyle` font definitions.

- Body and control labels: 12 pt, regular.
- Section labels and primary controls: 12 pt, medium.
- Supporting text and volume values: 11 pt, regular.
- Volume values use monospaced digits within the same system font, preventing layout movement as percentages change.

## Layout and states

The panel is 340 pt wide with 14 pt outer padding, 12 pt section spacing, and 8 pt row spacing. Sound and Mic share equal widths, icon widths, and label typography. Neutral glass means unmuted; red prominent glass plus a slashed icon means muted. State is also announced through accessibility labels.

Devices is a full-width plain button without a visible button surface. Its chevron indicates expansion. Audio content determines panel height; content above 380 pt scrolls with no visible scrollbar. The panel closes when the app or panel loses focus.

Each device is a rounded row with a device icon and name; tapping it selects the device, and the active one gets an accent tint and a checkmark. The volume slider sits beneath the name.

The output level above Apps follows Control Centre’s Sound slider: a 24 pt capsule track, a white fill with the speaker symbol at its start, and a round white knob. Clicking the track jumps to that level.

Each app row ends with its percentage, which resets the app to 100% when clicked. An app Voidamp couldn’t mix shows an orange warning in place of the percentage; clicking it retries. When no app audio can be captured at all, an orange notice under Apps offers Open Settings and Retry instead of an alert.

In the menu bar popover, the popover's own Liquid Glass is the panel's surface; the panel adds no second glass, which frosted it grey. The menu bar icon uses 14 pt symbols, the size of Control Centre's Sound icon.

## Smart mode

Smart mode follows Control Centre's Sound module. A bold 13 pt “Sound” title sits above the output level. When a microphone is muted, a “Mic Muted” capsule beside the title unmutes it; otherwise the header has nothing else. Below a divider, with no section label, come only the apps playing right now, each with its icon, name and a 16 pt version of the output level with no symbol or percentage; with nothing playing they and their divider are hidden. Clicking an app's icon mutes it, and a muted app's slider dims; clicking its name returns it to 100%. Output lists outputs only: a 26 pt circle with the device symbol, filled with the accent color and a white symbol for the active output, then the name. Rows highlight under the pointer like menu items. There is no Mic, Mixing, Suite or Devices control, and no footer. Moving the level unmutes sound.
