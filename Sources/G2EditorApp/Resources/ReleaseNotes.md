## 0.1.9 — November 5, 2026
This release is mostly about the G2's own memory: you can now store patches and whole banks in the G2 and tidy its banks from the editor.
- **Save In Synth.** Synth ▸ Save In Synth… stores the patch in the active slot, or the whole performance, at a place you pick in one of the G2's banks. The window shows which banks are empty and lets you name the patch. The editor first sends what you see on screen, so the G2 stores exactly that.
- **Upload Banks to G2.** Synth ▸ Upload Banks to G2… sends a folder of patch (or performance) files into one bank of the G2 — in the order of the folder's .pchList if it has one, otherwise in Finder order. A bank that already holds patches is erased first, and the window warns you before it does.
- **Delete patches and banks in the G2.** Right-click a patch or a bank in the Banks list to delete it from the G2's memory (the editor asks first). ⌘-click and Shift-click select several patches.
- **Empty banks** are collected in a folded "Empty Banks" group at the end of the Banks list. Click one to open Save In Synth on that bank.
- **Get Active Slot from G2 (⌘U).** Synth ▸ Get Active Slot from G2 brings the patch from the slot that is active on the G2 into the editor. The command that sends a patch the other way is now called Patch ▸ Send to G2 Slot (⌘D), so the two directions can't be mixed up.
- **Notes come along from the G2.** Patches read from the G2 when you connect, when you change a patch on the G2's front panel or with Get Active Slot used to arrive without their notes (Textpad), and saving them lost the notes. The editor now asks the G2 for the notes of every slot.
- **Slot buttons are saved with the performance.** Slots switched on with Shift-click and keyboards switched on with Ctrl-click on the slot buttons were forgotten by Save Performance. They are now saved.
- **File ▸ Save Performance As…** saves the performance under a new name.
- **Knobs turned on the G2 are marked in the editor.** A knob you turn on the G2 gets the same focus frame as a clicked one, so the arrow keys fine-tune it next. Every knob turned in the last few seconds keeps its frame. The focus frame is now a moving dashed line, easier to see on a busy module.
- **Copy and paste modules with ⌘C and ⌘V.** ⌘C copies the selected modules (before, it only worked from the right-click menu). ⌘V hangs the copies at the pointer as outlines; click to place them, Esc to cancel. Before, pasted modules landed on top of the originals.
- **Modules dropped into a column make exactly enough room.** A module, a block or a dragged group dropped in the middle of a column now goes before or after the module it lands on, and the column below moves down by exactly its height — no more empty gap above it.
- **Select cables with Shift-click** (they light up in light blue) and press Delete to disconnect them, like Disconnect in the cable menu. One ⌘Z brings them back.
- **The window title shows the name of the performance on the G2** instead of "Nord G2".
- **Synth ▸ Send Controller Snapshot and Dump One work:** the G2 sends the current knob values as MIDI CCs, or the patch as SysEx, from its MIDI OUT.
- The File menu no longer shows greyed-out SysEx save items that don't work yet.

## 0.1.8 — November 4, 2026
Most of this release is about variations, and three of the new features come from the Wish List on the electro-music forum.
- **Variation fader (wish #13).** Under the eight variation buttons in the toolbar there is now a slider that fades smoothly from one variation to the next. Drag the green knob: every dot under a button is a stop, and between two stops you hear a mix of the two neighbouring variations. Knobs and faders glide; switches, waveforms and filter types can't be mixed, so they jump when the slider reaches the next stop. While you drag, the patch shows what is changing on the way to the next stop. Release on a dot and that variation plays as usual; release between two dots and you keep the in-between sound. To keep it, right-click the variation bar ▸ Store Fader Sound To ▸ Variation 1–8. One ⌘Z takes the whole move back. Variations that are identical to the one before them share a stop. The eight variations and the file stay unchanged until you store the sound.
- **The same fader in the Patch Mutator.** It sits under the eight Variations boxes; a box lights up when the slider stands on its dot. Right-click any box (a variation, Mother, Father, a child or Temporary Storage) ▸ Store Fader Sound Here to keep what you hear.
- **Compare Variations (wish #6).** Shift-click a variation button to see on the patch how it differs from the variation that is playing. The button turns turquoise. Everything that is the same in both fades under a light mist. Knobs get a second, turquoise pointer at the other variation's value, buttons and sliders a turquoise outline, and envelope and filter graphs a dashed turquoise curve. Hover a control to see both values, or hold ⌥ to see every difference at once. You can still turn knobs while you compare. Esc, the same Shift-click or a normal click on the compared variation ends it. You can also right-click the variation bar ▸ Compare Variation N With. In the Patch Mutator, Shift-click a Variations box does the same.
- **Lock Across Variations (wish #7).** Right-click a knob, slider or button ▸ Lock Across Variations, and it keeps one value in all eight variations: switching variations no longer moves it, on the G2 too. Locking copies the value of the playing variation to the other seven; Init is left alone. From then on, turning the locked control changes all eight. A small orange padlock marks every locked control. To lock a whole module (or every selected module), use Lock Across Variations in the module's menu. The Init button and Copy Variation leave locked values alone, and the Patch Mutator does not mutate them. The patch file stays a normal .pch2/.prf2 — the editor remembers the padlocks by file name when you save and puts them back when you open the file again. One ⌘Z unlocks and gives every variation its old value back.
- **Vol: one volume for all variations.** Right-click the Vol knob in the toolbar ▸ Set This Volume for All Variations copies the volume of the playing variation to all eight. One ⌘Z undoes it.
- **Voice calculator.** Tools ▸ DSP Load has a new Voices section. It shows how the G2 shares its DSPs between the four slots and how many voices each slot really gets: on a G2 without an expansion board (4 DSP) and with one (8 DSP). When a slot gets fewer voices than its Voices setting asks for, the number turns orange, and a line below says how many voices don't fit. Without a G2 connected the numbers are an estimate; with a G2 connected the Live column shows what the G2 reports.
- **Tell the editor if your G2 has an expansion board:** Settings ▸ General ▸ Your G2 ▸ Expansion board installed (8 DSPs). The G2 does not report it. DSP Load and the patch browser use it.
- **The patch browser warns about big patches.** A red bar next to a file means the patch or performance needs more than your G2 has. Hover a file to see how many voices each slot gets on your G2 and with an expansion board.
- **Voices shows what the G2 really gives you.** When the G2 can play fewer voices than you asked for, the toolbar shows it like the original editor, for example "7 (28)": 7 voices playing, 28 requested.
- **No more clicks when a patch is loaded.** The editor mutes the slot while the G2 loads a patch or a performance and switches it back on as soon as the G2 reports it is ready.
- **Patches from the G2's banks follow "Like the original editor"** (Settings ▸ Connection ▸ Opening a Single Patch): a patch clicked in the Banks list goes to slot A and slots B–D are cleared, as with patch files.
- **Dragging a knob shows one value bubble**, not a second one at the pointer.

## 0.1.7 — October 29, 2026
- **Old patches no longer freeze the G2.** Some patches made with early versions of the G2 OS — for example with a FreqShift module that still has five parameters — froze the G2 every time they were sent. The editor now sends each module only the parameters it has today, like the original editor. The file on disk stays as it is.
- **Old patch files are brought up to date when you open them, like in the original editor.** Retired modules (ClkDivFix) are removed with their cables, missing modes are added, and parameters and cables a module no longer has are dropped together with their knobs, morphs and MIDI CCs. A performance such as Rumbleinthejungl now loads all four slots instead of the G2 refusing one. The file changes only when you save it.
- **Mutator: Not silent really avoids silent children.** With Not silent lit, levels, amplifiers, filter cutoffs, crossfaders, amplitude envelopes and the switches that route the sound to the output move only half as far towards silence; turn the knob next to it up and they stop moving towards silence at all. Everything else mutates as before. With Randomize on patches from other G2 players, silent children dropped from about one in three to one in ten. The knob is greyed out while Not silent is off.
- **The DSP meters count like the G2.** Without a G2 connected, Cycles and Memory now include audio-rate (uprated) modules, connected inputs, module modes, the keyboard and the memory that LFOs, filters and other module groups share — the numbers match what the G2 reports after loading the patch.
- **DSP Load window: no numbers left over from the previous patch.** A slot that gets a new patch drops the old reading, and a slot that is switched off shows "estimated — not playing".
- **Sending a performance after the G2 refused one** no longer leaves slots with nothing but their names.
- **Save dialogs open in the folder of the opened file** — Save As, Save Performance As and Save From ▸ Slot.
- **Connecting the G2 while a single patch is open** switches it to Patch mode, following Settings ▸ Connection ▸ Opening a Single Patch, like the original editor.
- **Module names in the library match the original editor** — for example Mix2-1B is now "Mixer 2-1 B" instead of "Scratch".

## 0.1.6 — October 27, 2026
- **LEDs and meters keep moving after you open a patch from disk.** After switching the G2 on, the first patch opened from disk switches it from Performance to Patch mode. From then on the G2 stopped sending its LED and meter data, so LFO and envelope LEDs and sequencer steps stood still until the G2 was switched off and on. Patches loaded from the G2's own memory were fine. The editor now finishes the mode switch the way the original editor does.

## 0.1.5 — October 26, 2026
- **The Mutator keeps your edits.** If you change a parameter while you listen to a child, that child changes too, so the next Randomize no longer brings the old value back. A SeqNote length set to 8 now stays 8 instead of returning to 16.
- **Mutator: modules added later are mutated too.** Modules you add after breeding (for example SeqLev, SeqVal, ClkDiv or Pulse) now take part in Mutate and Randomize.
- **The Mutator uses the original value range of every parameter.** All 903 module parameters were checked against the original editor. LevConv's Output Type no longer gets values outside its six positions.
- **Clearer message when the G2 goes silent.** When the G2 stops responding during an upload, the bar now suggests switching it off and on (the editor reconnects by itself) instead of blaming a long Textpad note.
- **The tag menu in the Patches drawer is in English**, with a coloured dot next to every colour. Searching for "red" also finds patches tagged in another language in the Finder.

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
