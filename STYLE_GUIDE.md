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
