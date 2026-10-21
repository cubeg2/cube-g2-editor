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
