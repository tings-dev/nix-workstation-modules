# Kanata + XKB: German Umlauts on US Layout

Kanata handles tap-dance input detection and emits F13-F21. The graphical
host's XKB keymap maps those unused function keys to German characters, so the
compositor delivers Unicode characters consistently to every application.

## Keycode mapping

| Kanata key | XKB keycode | Character |
| --- | --- | --- |
| `f13` | `<FK13>` | ä |
| `f14` | `<FK14>` | Ä |
| `f15` | `<FK15>` | ö |
| `f16` | `<FK16>` | Ö |
| `f17` | `<FK17>` | ü |
| `f18` | `<FK18>` | Ü |
| `f19` | `<FK19>` | ß |
| `f20` | `<FK20>` | ẞ |
| `f21` | `<FK21>` | € |

The custom XKB keymap and its compositor configuration are separate dotfiles:
this profile owns only Kanata's input transformation and user service.

## Modifier and navigation keys

In the default layer, Caps Lock sends Super for desktop shortcuts. Windows and
Page Up activate the control layer when held, using the existing 200 ms tap/hold
timings; tapping either sends nothing. Print Screen passes through unchanged in
every layer, so the compositor's screenshot shortcuts work directly.

Holding backtick activates the arrows layer. In the control and arrows layers,
Caps Lock sends Escape when tapped and Super when held.
