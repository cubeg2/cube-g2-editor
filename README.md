# Cube G2 Editor

A modern, free and open-source patch editor for the **Clavia Nord Modular G2**,
made for macOS on Apple silicon.

Cube G2 Editor keeps the familiar layout and workflow of the original G2 editor,
so patches look and behave the way G2 players know them, and runs natively on
current Macs.

> **Public beta 0.1.1.** It is developed and tested on a real G2, but it is still
> beta software that sends patches to your synth. **Back up your banks first**
> (Synth ▸ Download Banks from G2…).
>
> This is an early beta. Please try everything you do with your G2 and
> report what doesn't work, looks wrong or feels awkward — see
> [Feedback and bug reports](#feedback-and-bug-reports).

## Download

**[Download the latest release](https://github.com/cubeg2/cube-g2-editor/releases/latest)**
(`Cube-G2-Editor-<version>-beta.dmg`)

Requirements:

- macOS 15 Sequoia or later
- A Mac with Apple silicon (M1 or newer). Intel Macs are not supported.
- Nord Modular G2 with OS 1.62, connected over USB. The G2X and G2 Engine have
  not been tested yet.

## Installing

1. Open the `.dmg` file and drag **Cube G2 Editor** to **Applications**.
2. Open the app. macOS says it can't check the app for malware. Click **Done**.
3. Open **System Settings ▸ Privacy & Security**, scroll down and click
   **Open Anyway**.

You only need to do this once for every new version. Your settings and patches
stay when you update.

*Why?* Cube G2 Editor is an independent app that isn't registered with Apple, so
macOS can't verify it automatically. This is common for free, independent
software.

The editor checks GitHub for new versions once a day (Settings ▸ Updates). It
only tells you; it never downloads or installs anything by itself.

## What it does

- Opens, edits and saves G2 patches (`.pch2`) and performances (`.prf2`).
- Edits the patch on the G2 live over USB: modules, cables, knobs, names and
  colors.
- Four slots and performances, variations, morphs, parameter pages and the
  global knobs.
- Module library with previews, cable chains, keyboard shortcuts.
- Patch Mutator and Patch Adjuster for exploring new sounds.
- Spectrum and X-Y plot from your audio interface inputs.
- Backup of the G2's memory banks to your Mac.
- On-screen keyboard to play the selected slot.

## Feedback and bug reports

The beta lives on the **Cube G2 Discord**: <https://discord.gg/2kUhfYRa2t>.
Post problems in `#bug-reports` and ideas in `#feedback`. You can also
[open an issue](https://github.com/cubeg2/cube-g2-editor/issues/new/choose) here.

Settings ▸ Feedback in the app lists what to include and shows how to save a
USB log.

## Support

Cube G2 Editor is free, and every feature stays free for everyone. If it makes
your G2 sessions better, you can buy me a coffee:
<https://ko-fi.com/cubeg2>.

## Building from source

You need Xcode (Swift 5.9 or later) and libusb from Homebrew:

```bash
brew install libusb
swift build
swift test
swift run G2EditorApp
```

`Tools/build_app.sh` builds `Cube G2 Editor.app` and the DMG into `dist/`.

## License

Original Cube G2 Editor code is licensed under
[`GPL-3.0-or-later`](LICENSE). Third-party components and data remain subject to
their respective licenses and rights. See [`NOTICE.md`](NOTICE.md) for
attribution, trademark and interface-compatibility notes.

This is an unofficial community project. Nord, Nord Modular and Clavia are
trademarks of Clavia DMI AB. Cube G2 Editor is not affiliated with, authorized,
sponsored or endorsed by Clavia DMI AB or Nord Keyboards. It is provided without
warranty; use it at your own risk.
