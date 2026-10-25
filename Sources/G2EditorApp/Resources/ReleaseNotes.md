## 0.1.4 — October 25, 2026
- **Big patch folders no longer slow the editor down.** With a folder of thousands of patches open in the Patches drawer, every click anywhere in the window could spin the wait cursor for several seconds, and restarting did not help because the editor reopens the last folder. With 6,500 patches in one folder a click took over 4 seconds; now clicks and stepping through patches are instant again.
- **The patch list appears much sooner after launch.** Reading a library of 45,000 files took almost 7 seconds; it now takes about 1.5. The editor no longer asks macOS about iCloud for every single file when the folder is not in iCloud, and reads the files on all processor cores.
- **Mutator: Exclude From Mutations protects the Power button too.** A module you excluded and switched off came back on with the next Mutate. Modules you exclude by hand now keep what they are playing.

## 0.1.3 — October 24, 2026
Almost everything here comes from the Wish List on the electro-music forum.
- **Building Blocks.** Pick a Building Blocks folder in Settings ▸ General ▸ Folders; the Patches drawer gets a Blocks tab. Drag a block onto the patch and it is inserted where you drop it — modules, cables, values in all variations, names, colours and mixer/switch labels — with everything selected and a single Undo. Any .pch2 works as a block. File ▸ Insert Patch File… does the same without the drawer.
- **Knobs, MIDI CCs and morphs come with a block if you want.** When a block has its own assignments, a small window asks what to bring along (Morphs, Knobs, MIDI CC, Patch settings, Morph knobs) and shows what won't fit.
- **Save your own blocks.** Select modules and choose Save Selection as Block…, or drag the selection onto the Blocks list. Their knobs, MIDI CCs, morphs and morph names are saved too.
- **Type a knob value.** Double-click a knob or choose Enter Value… and type e.g. 0.5s, 500ms, 1.2k, 880 or (64). The arrow keys now show the value tooltip as well.
- **Right-click a multi-value button for a list of all values** (LFO range, Step/Edge, keyboard tracking, the small P+/B−/B/P/N squares). On the small squares the tooltip spells the letter out (B → Bip).
- **Note names in the tooltip** for oscillator tuning, filter cutoff, FltComb and LFO in Rate Hi mode, e.g. "698Hz / F5 ±0 ct". Zero on the oscillator Coarse knob is E4, as the G2 counts.
- **Disconnect cables in bulk:** module menu ▸ Disconnect Cables ▸ All / Inside Selection / To Rest of Patch, and Disconnect All Cables in the background menu.
- **Morphs:** Clear All Morphs (this variation or all), Copy Morph To now copies like the original editor (before, it moved), and morphs can be renamed by double-clicking the name in the morph bar — the name goes to the G2 too.
- **Init 1 / Init 2 asks about unsaved changes** (can be switched off in Settings ▸ General).
- **Open patches from the Finder:** double-click a .pch2 or .prf2, use Open With, or drag it onto the editor window.
- **Fixes:** deleting a module also clears its knob, MIDI CC and morph assignments (a new module with the same number could inherit them), and Undo/Redo keep them in step on the G2; copy and paste keep mixer and switch labels; live LEDs and meters move with dragged modules; tooltips and parameter pages named the FltNord and DrumSynth filter type upside down (LP showed as BR); Download in Settings ▸ Updates now downloads the disk image instead of opening the release page.

## 0.1.2 — October 22, 2026
- **Patches loaded from disk reach the G2 reliably.** Sometimes the G2 kept playing the previous patch while the screen already showed the new one. The editor was dropping a reply from the G2 that arrived at the very moment a read timed out. It now keeps that reply and waits for data as long as the original editor does. If the G2 still stops sending data, the editor reconnects and sends the patch again instead of failing silently. Thanks to Kymeia for the report and the USB log.
- **The Mutator lights the right variation after you switch slots.** With several slots playing, it kept the variation of the previous slot lit, while the toolbar showed the right one.
- **Keys 1–8 (variations) and A–D (slots) work after clicking the Patches or Banks list.** Before, the list kept the keys until you clicked somewhere else.
- **Release notes in the app.** Settings ▸ Updates lists what changed in every version.

## 0.1.1 — October 21, 2026
- **Audio-rate modules sound clean again.** When an audio signal (red cable) goes into a module with blue/red inputs, such as an envelope, the editor switches that module to audio rate and tells the G2. Before, a sawtooth through an envelope in a new patch sounded gritty (aliasing). Patch files saved with 0.1 are corrected when you open them.
- **Cable colours follow the signal.** A cable from a blue/red output is blue while the module runs at control rate and red once it carries audio.
- **An input takes only one output**, as in the original editor and the G2 manual. You can still send one output to as many inputs as you like.
- **When the G2 rejects a patch, you see it.** A bar above the canvas explains what happened, and the next change sends the whole patch again. A very long text note (about 1000 characters or more) is a known cause.

## 0.1.0 — October 16, 2026
- **First public beta.**
