// SequenceEditorPanel.swift
// Sequence Editor window — a second view of the steps of one Seq module.
//
// The window keeps no pattern of its own: it reads the module's parameters and writes
// ordinary parameter changes (`PatchState.setParameter(s)`), so the module on the canvas
// and the G2 change together with it, and the patch stays a plain patch. One drawing
// stroke or one button press = one ⌘Z.
// → [[Docs/roadmap]] "Sequence Editor", [[Docs/ui/sequence-editor-euclid]]

import AppKit
import G2Core
import G2EditorCore
import Observation
import SwiftUI

typealias SequenceTarget = PanelController.SequenceEditorTarget

// MARK: - Window-side memory

/// What the window remembers while the app runs: locked steps and Euclid settings per
/// sequencer, the scale and the pattern clipboard. Not stored in the patch yet (the
/// patch-note line `#g2seq:` is a later step).
@MainActor
@Observable
final class SequenceEditorMemory {
    static let shared = SequenceEditorMemory()

    /// One more Euclid generator added to the first (Euclid tab, layers).
    struct EuclidLayer: Equatable {
        var hits = 3
        var rotation = 0
    }

    struct Euclid: Equatable {
        var hits = 4
        var rotation = 0
        var invert = false
        /// Further generators (up to three): the rhythm is the sum of all of them, then Invert.
        var extra: [EuclidLayer] = []

        static let maxExtra = 3

        /// The steps this setting plays, for `steps` steps.
        func pattern(steps: Int) -> [Bool] {
            var sum = EuclideanRhythm.pattern(hits: hits, steps: steps, rotation: rotation)
            for layer in extra {
                let more = EuclideanRhythm.pattern(hits: min(layer.hits, steps), steps: steps,
                                                   rotation: min(layer.rotation, max(0, steps - 1)))
                sum = zip(sum, more).map { $0 || $1 }
            }
            return sum.map { $0 != invert }
        }
    }

    struct EuclidKey: Hashable {
        let target: SequenceTarget
        let row: Int
    }

    var locks: [SequenceTarget: Set<Int>] = [:]
    /// SeqEvent modules whose Row 2 follows Row 1 (plays where Row 1 rests); window only.
    var linkedRests: Set<SequenceTarget> = []
    /// Sequencers left out of the group actions of the Euclid tab (Lengths, Group Euclid); window only.
    var groupOut: Set<SequenceTarget> = []
    var euclid: [EuclidKey: Euclid] = [:]
    var root = 9 // A
    var scale: MusicalScale = .chromatic
    var snapDrawing = true
    var clipboard: [[Int]]?
    var lowNote: [SequenceTarget: Int] = [:]
    /// The G2 connection the playhead reads the playing step from; set by the panel.
    @ObservationIgnored weak var device: DeviceConnection?
    /// Random on/off: share of steps that play, in percent.
    var density = 50
    /// Piano roll zoom: rows shown (12 or 24), or 0 = fit the played notes.
    var noteZoom = 24
    /// Mutate: share of steps that change, in percent.
    var mutate = 25
    /// Arpeggio (SeqNote): where the chord comes from, the order it is played in, and how many octaves it spans.
    var arpChord: ArpeggioChord = .type(.major)
    var arpDirection: ArpeggioDirection = .up
    var arpOctaves = 1
    /// Curve (SeqVal / SeqLev / SeqCtr): the shape, how many times it repeats, its phase, and its low and high end (%).
    var curveShape: SequenceCurve = .sine
    var curveCycles = 1
    var curvePhase = 0
    var curveLow = 0
    var curveHigh = 100
    /// Humanize (SeqVal / SeqLev / SeqCtr): the largest nudge, in percent of the range.
    var humanizeAmount = 10
    /// The user's own patterns (Presets ▸ My patterns), read from the settings folder at start.
    var library = SequenceUserLibrary.load()

    /// Writes the library file; a failed write only means the patterns last until the app quits.
    func saveLibrary() {
        try? library.write()
    }

    /// The preset last stepped to with the arrows beside Presets, per sequencer (window only).
    var presetCursor: [SequenceTarget: Int] = [:]
    /// The Rhythm bank pattern last stepped to with its arrows, per sequencer (window only).
    var rhythmCursor: [SequenceTarget: Int] = [:]

    /// Mute / Solo of lanes (window only). A muted lane has its gate rows cleared in the patch;
    /// what they held is kept here in `silenced` and put back on unmute.
    var muted: Set<SequenceTarget> = []
    var soloed: Set<SequenceTarget> = []
    var silenced: [SequenceTarget: [Int: Int]] = [:]
    /// Prob % row: taller faders (window only).
    var probTall = false
    /// What the last Random / Mutate overwrote, per sequencer, for the Undo random button.
    var randomUndo: [SequenceTarget: [Int: Int]] = [:]
    /// Step under the pointer in the Edit grids, for the status bar; nil when the pointer is elsewhere.
    var hoverStep: Int?
}

/// Mute / Solo for the lanes of one clock group: a lane that must be silent has its gate rows
/// (both rows on SeqEvent, the trigger / on row elsewhere) cleared, the old steps are remembered
/// and written back when it may play again. One toggle = one ⌘Z. The values of the lane stay.
@MainActor
enum SequenceMixer {
    static func refresh(state: PatchState, slot: Int, area: PatchArea, ids: [Int]) {
        guard state.slots.indices.contains(slot) else { return }
        let memory = SequenceEditorMemory.shared
        let modules = Dictionary(uniqueKeysWithValues: state.slots[slot].modules(in: area).map { ($0.id, $0) })
        let anySolo = ids.contains { memory.soloed.contains(.init(slot: slot, area: area, moduleID: $0)) }
        state.beginParameterGesture()
        defer { state.endParameterGesture() }
        for id in ids {
            let target = SequenceTarget(slot: slot, area: area, moduleID: id)
            guard let module = modules[id], let layout = SequencerLayout(typeID: module.typeID) else { continue }
            let editor = SequenceEditing(state: state, target: target, module: module, layout: layout)
            let silent = memory.muted.contains(target) || (anySolo && !memory.soloed.contains(target))
            let indices = (layout.kind == .event ? [0, 1] : [1]).flatMap { layout.indices(ofRow: $0) }
            if silent {
                if memory.silenced[target] == nil {
                    memory.silenced[target] = Dictionary(uniqueKeysWithValues: indices.compactMap { index in
                        editor.parameters.indices.contains(index) ? (index, editor.parameters[index]) : nil
                    })
                }
                editor.write(Dictionary(uniqueKeysWithValues: indices.map { ($0, 0) }))
            } else if let saved = memory.silenced[target] {
                editor.write(saved)
                memory.silenced[target] = nil
            }
        }
    }
}

/// The cable hues of the top bar (`CableColor` in TopBarControls): green = a step that plays,
/// blue = values and the selection, orange = locked or hand-edited, red = reserved for the
/// step playing now and for destructive actions. Cells have a strong outline and a weak fill,
/// like the lit buttons of the bar (user's choice 2026-11-15, variant A).
enum SeqColor {
    static let green = Color(red: 0.18, green: 0.78, blue: 0.28)
    static let blue = Color(red: 0.20, green: 0.50, blue: 1.00)
    static let orange = Color(red: 0.98, green: 0.55, blue: 0.08)
    static let on = green
    static let trigger = green
    static let value = blue
    static let lock = orange
    static let red = Color(red: 0.92, green: 0.22, blue: 0.20)
    /// Solo (the yellow cable of the top bar).
    static let yellow = Color(red: 0.95, green: 0.88, blue: 0.10)
    /// Playhead: a cool, soft hue that stays apart from the green steps, the orange locks and the
    /// red of destructive buttons (user's choice 2026-11-15, option A2).
    /// Light mode: a deeper teal (`#0A8CA6`, user's choice A, 2026-11-17), because the ice blue vanished
    /// on the light window.
    static let ice = pair(light: rgb(0.039, 0.549, 0.651), dark: rgb(0.525, 0.827, 0.902))
    /// Length handle: the blue of the top bar and of the bars (option B1).
    static let handle = blue
    /// Light on dark, dark on light: white of the given opacity in dark mode, black in light mode.
    private static func adaptive(dark: Double, light: Double) -> Color {
        pair(light: NSColor.black.withAlphaComponent(light), dark: NSColor.white.withAlphaComponent(dark))
    }

    /// One colour for light mode, another for dark.
    private static func pair(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static let rim = adaptive(dark: 0.14, light: 0.22)
    static let empty = adaptive(dark: 0.05, light: 0.07)
    /// Lane cards and toolbar groups: a faint panel with a clear outline, so the sections read in both modes.
    static let card = adaptive(dark: 0.05, light: 0.05)
    static let cardBorder = adaptive(dark: 0.25, light: 0.32)
    /// Fader and piano-roll fields: near black in dark mode, light blue-grey in light mode (the dark
    /// fields stuck out of the light window — user's note 2026-11-17).
    static let field = pair(light: rgb(0.914, 0.922, 0.937), dark: NSColor(white: 0.09, alpha: 1))
    static let fieldBorder = adaptive(dark: 0, light: 0.18)
    static let grid = pair(light: rgb(0.855, 0.867, 0.894), dark: NSColor(white: 0.16, alpha: 1))
    static let gridAlt = pair(light: rgb(0.902, 0.910, 0.929), dark: NSColor(white: 0.19, alpha: 1))
    static let offScale = pair(light: rgb(0.788, 0.804, 0.839), dark: NSColor(white: 0.11, alpha: 1))
    /// Steps after Length: darkened in dark mode, faded towards white in light mode.
    static let muted = pair(light: NSColor.white.withAlphaComponent(0.6), dark: NSColor.black.withAlphaComponent(0.45))
    /// Value and note names drawn on the bars.
    static let labelStrong = adaptive(dark: 0.85, light: 0.75)
    static let labelWeak = adaptive(dark: 0.4, light: 0.4)
    static let noteLabelStrong = adaptive(dark: 0.8, light: 0.75)
    static let noteLabelWeak = adaptive(dark: 0.35, light: 0.4)
}

/// Colour dot of a lane, only to tell lanes apart (the same in All and the Edit title):
/// Chance lanes are always orange; the other lanes of the clock group take blue, yellow, white in order.
@MainActor
private func laneDotColor(state: PatchState, slot: Int, area: PatchArea, id: Int) -> Color {
    guard state.slots.indices.contains(slot) else { return SeqColor.blue }
    let chance = state.chanceLaneIDs(slot: slot, area: area)
    if chance.contains(id) { return SeqColor.orange }
    let group = SequencerClockGroup.groups(in: state.slots[slot], area: area)
        .first { $0.sequencerIDs.contains(id) }?.sequencerIDs ?? [id]
    let plain = group.filter { !chance.contains($0) }
    let palette = [SeqColor.blue, SeqColor.yellow, Color(white: 0.9)]
    return palette[(plain.firstIndex(of: id) ?? 0) % palette.count]
}

/// A lane's name with its colour dot in front.
private struct LaneName: View {
    let text: String
    let dot: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 8, height: 8)
                .help("Lane colour: only tells the lanes apart. Chance lanes are orange.")
            Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
    }
}

/// A lit cell: strong outline, weak fill. `strong: false` is the same cell with its gate off.
func drawCell(_ context: GraphicsContext, rect: CGRect, color: Color, strong: Bool, radius: CGFloat = 3) {
    let path = Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: radius)
    context.fill(path, with: .color(color.opacity(strong ? 0.2 : 0.07)))
    context.stroke(path, with: .color(color.opacity(strong ? 1 : 0.4)), lineWidth: 1.5)
}

/// A cell for a note outside the window: the outline only, no fill (`strong: false` is the gate off).
private func drawOutlineCell(_ context: GraphicsContext, rect: CGRect, color: Color, strong: Bool,
                             radius: CGFloat = 3)
{
    let path = Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: radius)
    context.stroke(path, with: .color(color.opacity(strong ? 1 : 0.4)), lineWidth: 1.5)
}

/// Scroll wheel and two-finger scrolling over a piano roll: reports how many semitones to move the
/// window (positive = higher notes, as the content moves down). Reads the events with a local monitor,
/// because the drawing view above it would swallow them; only events inside its own bounds count.
private struct NoteScrollWheel: NSViewRepresentable {
    let rowHeight: CGFloat
    let onScroll: (Int) -> Void

    final class Coordinator {
        var monitor: Any?
        weak var view: NSView?
        var accumulated: CGFloat = 0
        var rowHeight: CGFloat = 12
        var onScroll: (Int) -> Void = { _ in }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator] event in
            guard let coordinator, let view = coordinator.view, event.window === view.window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            // A trackpad reports points; a wheel reports lines — three rows to a click.
            let points = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY : event.scrollingDeltaY * 3 * coordinator.rowHeight
            coordinator.accumulated += points
            let rows = Int(coordinator.accumulated / coordinator.rowHeight)
            if rows != 0 {
                coordinator.accumulated -= CGFloat(rows) * coordinator.rowHeight
                coordinator.onScroll(rows)
            }
            return nil
        }
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.rowHeight = max(1, rowHeight)
        context.coordinator.onScroll = onScroll
    }
}

/// An empty cell: faint fill and rim.
private func drawEmptyCell(_ context: GraphicsContext, rect: CGRect, radius: CGFloat = 3) {
    let path = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius)
    context.fill(path, with: .color(SeqColor.empty))
    context.stroke(path, with: .color(SeqColor.rim), lineWidth: 1)
}

/// Thin divider between groups of buttons, as on the top bar.
private struct SeqDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1.5, height: 18)
    }
}

// MARK: - Panel

struct SequenceEditorPanel: View {
    let state: PatchState
    @Bindable var panels: PanelController
    let device: DeviceConnection
    @State private var tab = Tab.edit
    /// What the All tab wants from the window height — see `WindowHeightFitter`.
    @State private var allFit = WindowFit(delta: nil, token: 0, natural: 0)
    /// Edit tab: height of the toolbar as laid out (more rows when the window is narrow).
    @State private var editToolbarHeight: CGFloat = 0
    @AppStorage(SequenceToolLabels.key) private var showLabels = true
    /// The Add sequencer sheet (a slot without a sequencer).
    @State private var addingSequencer = false

    enum Tab: String, CaseIterable, Identifiable {
        case edit = "Edit", euclid = "Euclid", all = "All"
        var id: String {
            rawValue
        }
    }

    /// A patch without a sequencer: one click adds a note sequencer in the keyboard's place (see
    /// `PatchState.addSequencer`); without a keyboard to take over, the reason is shown instead.
    private var addSequencerOffer: some View {
        let slot = state.selectedSlot
        let obstacle = state.addSequencerObstacle(slot: slot)
        return VStack(spacing: 6) {
            Button("Add sequencer…") { addingSequencer = true }
                .disabled(obstacle == .noSoundSource)
                .sheet(isPresented: $addingSequencer) {
                    AddSequencerSheet(state: state, slot: slot) { sequencerID in
                        panels.sequenceTarget = .init(slot: slot, area: .voice, moduleID: sequencerID)
                    }
                }
            Text(addSequencerHint(obstacle))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func addSequencerHint(_ obstacle: PatchState.AddSequencerResult?) -> String {
        switch obstacle {
        case .noSoundSource: "No oscillator or keyboard cable here that a sequencer could drive."
        case .wontFit: "Not enough DSP left for a sequencer and a clock."
        default: "Choose how it plays, its clock and what it drives. A starter pattern is written in; one ⌘Z takes it all back."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let target = panels.sequenceTarget, let module = module(for: target),
               let layout = SequencerLayout(typeID: module.typeID)
            {
                header(module: module, target: target)
                if tab == .edit { SequencePlayStrip(state: state, target: target) }
                let editor = SequenceEditing(state: state, target: target, module: module, layout: layout)
                switch tab {
                case .edit: SequenceEditTab(editor: editor, panels: panels, onToolbarHeight: { editToolbarHeight = $0 })
                case .euclid: SequenceEuclidTab(state: state, target: target)
                case .all:
                    SequenceAllTab(state: state, slot: target.slot, area: target.area,
                                   currentID: target.moduleID,
                                   onFit: { allFit = $0 },
                                   open: { moduleID in
                                       panels.sequenceTarget = .init(slot: target.slot, area: target.area,
                                                                     moduleID: moduleID)
                                       tab = .edit
                                   })
                }
            } else {
                Spacer()
                Text("No sequencer in this slot. Click a sequencer module (SeqNote, SeqEvent, SeqVal, SeqLev, SeqCtr) on the patch, or choose Sequence Editor… from its right-click menu.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                addSequencerOffer
                Spacer()
            }
        }
        .padding(12)
        // All tab: the window fits the number of sequencers when it opens or the list changes
        // (user's note 2026-11-14), then the user can stretch it; Edit and Euclid get the
        // normal minimum back so the note grid fits.
        // The least height the content needs, in SwiftUI itself: the hosting controller turns it
        // into the window minimum, so the window cannot be dragged smaller and clip the rows
        // or rings (user's screenshot 2026-11-15).
        .frame(minHeight: minimumHeight, alignment: .top)
        .background(WindowHeightFitter(mode: fitMode))
        .onAppear {
            SequenceEditorMemory.shared.device = device
            // Nothing clicked yet (after a start): load the selected slot and show All, so the
            // window is useful at once (user's note 2026-11-16).
            if panels.sequenceTarget == nil {
                panels.sequenceTarget = firstSequencer(inSlot: state.selectedSlot)
                if panels.sequenceTarget != nil { tab = .all }
            } else if !panels.sequencePinned, panels.sequenceTarget?.slot != state.selectedSlot {
                // The slot was changed while the window was closed.
                panels.sequenceTarget = firstSequencer(inSlot: state.selectedSlot)
            }
            if panels.sequenceOpensOnAll {
                tab = .all
                panels.sequenceOpensOnAll = false
            }
        }
        // A patch was opened while the window was open: its sequencers are not the ones the window
        // pointed at (or it pointed at none). Load the first one and show All, as on the first
        // opening (user's note 2026-11-17).
        .onChange(of: sequencerToken) { _, _ in
            let current = panels.sequenceTarget.flatMap { module(for: $0) }
                .flatMap { SequencerLayout(typeID: $0.typeID) }
            guard current == nil else { return }
            let wasEmpty = panels.sequenceTarget == nil
            panels.sequenceTarget = firstSequencer(inSlot: state.selectedSlot)
            if wasEmpty, panels.sequenceTarget != nil { tab = .all }
        }
        // Another slot selected: the window follows it (unless pinned) — its first sequencer,
        // or the empty hint when the slot has none.
        .onChange(of: state.selectedSlot) { _, slot in
            guard !panels.sequencePinned, panels.sequenceTarget?.slot != slot else { return }
            panels.sequenceTarget = firstSequencer(inSlot: slot)
        }
    }

    /// The sequencers of the selected slot (number, type, area), to notice a patch being opened or a
    /// sequencer added or removed.
    private var sequencerToken: [Int] {
        guard state.slots.indices.contains(state.selectedSlot) else { return [] }
        let patch = state.slots[state.selectedSlot]
        return [PatchArea.voice, .fx].flatMap { area in
            patch.modules(in: area).filter { SequencerLayout(typeID: $0.typeID) != nil }
                .flatMap { [$0.id, $0.typeID, area == .voice ? 0 : 1] }
        }
    }

    /// First sequencer of a slot: Voice area before FX, in module order.
    private func firstSequencer(inSlot slot: Int) -> SequenceTarget? {
        guard state.slots.indices.contains(slot) else { return nil }
        for area in [PatchArea.voice, .fx] {
            if let module = state.slots[slot].modules(in: area).first(where: { SequencerLayout(typeID: $0.typeID) != nil }) {
                return .init(slot: slot, area: area, moduleID: module.id)
            }
        }
        return nil
    }

    /// Every sequencer of a slot in navigation order: Voice before FX, in module order.
    private func sequencerTargets(inSlot slot: Int) -> [SequenceTarget] {
        guard state.slots.indices.contains(slot) else { return [] }
        return [PatchArea.voice, .fx].flatMap { area in
            state.slots[slot].modules(in: area).filter { SequencerLayout(typeID: $0.typeID) != nil }
                .map { SequenceTarget(slot: slot, area: area, moduleID: $0.id) }
        }
    }

    /// The ‹ › arrows of the Edit tab: moves to the previous / next sequencer of the slot.
    private func step(from target: SequenceTarget, by delta: Int) {
        if let next = PanelController.neighbour(of: target, in: sequencerTargets(inSlot: target.slot), step: delta) {
            panels.sequenceTarget = next
        }
    }

    private var minimumHeight: CGFloat {
        switch fitMode {
        case let .fixed(height, floor): floor ?? height
        case .lanes: 160
        case .normal: PanelController.Panel.sequenceEditor.minWindowSize?.height ?? 460
        }
    }

    /// All: fits the lane list. Edit on SeqEvent: only two rows of steps, so a short window.
    /// Everything else keeps the normal minimum (note grid, bars, Euclid circles).
    private var fitMode: WindowHeightFitter.Mode {
        if tab == .all {
            return .lanes(delta: allFit.delta, token: allFit.token, natural: allFit.natural, toolbar: allFit.toolbar)
        }
        if tab == .edit, let target = panels.sequenceTarget, let module = module(for: target),
           SequencerLayout(typeID: module.typeID)?.kind == .event
        {
            return .fixed(height: 315, floor: 315 + editToolbarExtra)
        }
        // Edit on bars (SeqVal, SeqLev, SeqCtr): the bars are three squares tall at the default
        // width, as in All; the window can still be stretched.
        if tab == .edit, let target = panels.sequenceTarget, let module = module(for: target),
           let kind = SequencerLayout(typeID: module.typeID)?.kind, kind == .value || kind == .controlled
        {
            // The 405 was worked out for a toolbar of three rows; a narrow window wraps it into more, and the
            // window may then not be dragged lower than those rows need.
            let base: CGFloat = 405 + 8 + (SequenceEditorMemory.shared.probTall ? 120 : 44)
            return .fixed(height: base, floor: base + editToolbarExtra)
        }
        // One ring only (every sequencer except SeqEvent): a short window, the ring scales up.
        // The rings scale down with the window, to `SequenceEuclidTab.minRing` each.
        if tab == .euclid, let target = panels.sequenceTarget, let module = module(for: target) {
            // Several sequencers on the clock: a taller window with the list scrolling inside.
            let patch = state.slots.indices.contains(target.slot) ? state.slots[target.slot] : G2Patch()
            let ids = SequencerClockGroup.groups(in: patch, area: target.area)
                .first { $0.sequencerIDs.contains(target.moduleID) }?.sequencerIDs ?? []
            let kinds = ids.compactMap { id in
                patch.modules(in: target.area).first { $0.id == id }.flatMap { SequencerLayout(typeID: $0.typeID)?.kind }
            }
            if kinds.count > 1 {
                let rows = kinds.reduce(0) { $0 + ($1 == .event ? 2 : 1) }
                let combined = kinds.filter { $0 == .event }.count
                return .fixed(height: min(720, CGFloat(172 + 44 * kinds.count + 130 * rows + 50 * combined)), floor: 320)
            }
            return SequencerLayout(typeID: module.typeID)?.kind != .event
                ? .fixed(height: 240, floor: 195) : .fixed(height: 506, floor: 351)
        }
        return .normal
    }

    /// How much taller than the three rows the heights were worked out for the Edit toolbar is (a narrow window wraps
    /// it into more rows): the window may not be dragged lower than those rows need.
    private var editToolbarExtra: CGFloat {
        let threeRows: CGFloat = 3 * (15 + 4 + TopBarMetrics.controlSide + 8) + 2 * 8
        return editToolbarHeight > 0 ? max(0, editToolbarHeight - threeRows) : 0
    }

    private func header(module: G2Module, target: SequenceTarget) -> some View {
        HStack(spacing: 10) {
            Circle().fill(laneDotColor(state: state, slot: target.slot, area: target.area, id: target.moduleID))
                .frame(width: 8, height: 8)
                .help("Lane colour: only tells the lanes apart. Chance lanes are orange.")
            Text(title(of: module, target: target))
                .font(.system(size: 13, weight: .semibold))
            if tab == .edit, sequencerTargets(inSlot: target.slot).count > 1 {
                HStack(spacing: 4) {
                    TopBarButton(content: .icon("chevron.left"), isOn: false, tint: SeqColor.blue) {
                        step(from: target, by: -1)
                    }
                    .help("Previous sequencer in this slot (wraps around)")
                    TopBarButton(content: .icon("chevron.right"), isOn: false, tint: SeqColor.blue) {
                        step(from: target, by: 1)
                    }
                    .help("Next sequencer in this slot (wraps around)")
                }
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { item in
                    TopBarButton(content: .text(item.rawValue), isOn: tab == item, tint: SeqColor.blue) {
                        tab = item
                    }
                }
            }
            Toggle("Labels", isOn: $showLabels)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Names next to the toolbar icons; off for a narrow window")
            TopBarButton(content: .icon(panels.sequencePinned ? "pin.fill" : "pin"),
                         isOn: panels.sequencePinned, tint: SeqColor.blue)
            {
                panels.sequencePinned.toggle()
            }
            .help("Pin: keep this sequencer while clicking other modules")
        }
    }

    private func module(for target: SequenceTarget) -> G2Module? {
        guard state.slots.indices.contains(target.slot) else { return nil }
        return state.slots[target.slot].modules(in: target.area).first { $0.id == target.moduleID }
    }

    private func title(of module: G2Module, target: SequenceTarget) -> String {
        let type = ModuleDatabase.module(id: module.typeID)?.shortName ?? "Sequencer"
        let name = module.label.isEmpty ? type : module.label
        let slot = ["A", "B", "C", "D"][max(0, min(3, target.slot))]
        return "\(name) · \(type) · Slot \(slot) · \(target.area == .voice ? "Voice" : "FX")"
    }
}

// MARK: - Reading and writing one sequencer

/// The module's steps plus every operation the window offers. A value type rebuilt with
/// each render, so it always works on the module as it is now.
@MainActor
struct SequenceEditing {
    let state: PatchState
    let target: SequenceTarget
    let module: G2Module
    let layout: SequencerLayout
    var memory: SequenceEditorMemory {
        .shared
    }

    var parameters: [Int] {
        module.parameters
    }

    var values: [Int] {
        layout.row(0, in: parameters)
    }

    var gates: [Int] {
        layout.row(1, in: parameters)
    }

    var length: Int {
        layout.length(in: parameters)
    }

    var locks: Set<Int> {
        memory.locks[target] ?? []
    }

    var isLooping: Bool {
        guard let index = layout.loopIndex, index < parameters.count else { return true }
        return parameters[index] != 0
    }

    // MARK: Note window (SeqNote)

    /// Rows of the piano roll: the zoom setting (12 or 24), or on Fit (0) the played range plus a margin.
    var visibleNotes: Int {
        guard memory.noteZoom == 0 else { return memory.noteZoom }
        let played = values.prefix(length)
        guard let low = played.min(), let high = played.max() else { return 24 }
        return max(12, min(48, ((high - low + 1 + 4 + 11) / 12) * 12))
    }

    /// Lowest note row shown; follows the notes unless the user scrolled.
    var lowNote: Int {
        let span = visibleNotes
        let top = 127 - span + 1
        if let stored = memory.lowNote[target] { return max(0, min(top, stored)) }
        let played = values.prefix(length)
        guard let lo = played.min(), let hi = played.max() else { return max(0, min(top, 60 - span / 2)) }
        if memory.noteZoom == 0 { return max(0, min(top, lo - (span - (hi - lo + 1)) / 2)) }
        return max(0, min(top, ((lo + hi) / 2 / 12) * 12 - (span - 12) / 2))
    }

    var visibleRange: ClosedRange<Int> {
        lowNote ... lowNote + visibleNotes - 1
    }

    func scrollNotes(by semitones: Int) {
        setLowNote(lowNote + semitones)
    }

    /// Puts the lowest shown note at `low` (kept inside the range) — dragging the keyboard, the scroll wheel.
    func setLowNote(_ low: Int) {
        memory.lowNote[target] = max(0, min(127 - visibleNotes + 1, low))
    }

    // MARK: Writing

    func write(_ changes: [Int: Int]) {
        guard !changes.isEmpty else { return }
        var all = changes
        if layout.kind == .event, memory.linkedRests.contains(target) {
            if layout.indices(ofRow: 0).contains(where: { changes[$0] != nil }) {
                all.merge(restsOfFirstRow(applying: changes)) { $1 }
            } else if layout.indices(ofRow: 1).contains(where: { changes[$0] != nil }) {
                memory.linkedRests.remove(target) // Row 2 was edited by hand: the link ends
            }
        }
        state.setParameters(slot: target.slot, moduleID: target.moduleID, values: all, area: target.area)
    }

    /// Row 2 as the rests of Row 1 (after `changes`): on where Row 1 is off, within the played steps.
    func restsOfFirstRow(applying changes: [Int: Int] = [:]) -> [Int: Int] {
        let first = zip(layout.indices(ofRow: 0), layout.row(0, in: parameters)).map { changes[$0] ?? $1 }
        let played = layout.lengthIndex.flatMap { changes[$0] }.map { $0 + 1 } ?? length
        return self.changes(row: 1, first.enumerated().map { $0.offset < played && $0.element == 0 ? 1 : 0 })
    }

    /// A write by Random or Mutate: remembers the old values so Undo random can put them back.
    func writeRandom(_ changes: [Int: Int]) {
        guard !changes.isEmpty else { return }
        memory.randomUndo[target] = changes.keys.reduce(into: [:]) { saved, index in
            if parameters.indices.contains(index) { saved[index] = parameters[index] }
        }
        write(changes)
    }

    var canUndoRandom: Bool {
        memory.randomUndo[target] != nil
    }

    /// Puts back what the last Random / Mutate changed (one ⌘Z, like the operation itself).
    func undoRandom() {
        guard let saved = memory.randomUndo[target] else { return }
        memory.randomUndo[target] = nil
        write(saved)
    }

    func changes(row: Int, _ newValues: [Int], keepLocked: Bool = true) -> [Int: Int] {
        let old = layout.row(row, in: parameters)
        let final = keepLocked ? SequencePattern.respectingLocks(newValues, old: old, locked: locks) : newValues
        var result: [Int: Int] = [:]
        for (index, (parameter, value)) in zip(layout.indices(ofRow: row), final).enumerated()
            where value != old[index]
        {
            result[parameter] = value
        }
        return result
    }

    /// One value inside a drawing stroke (the stroke itself is the undo step).
    func setStep(row: Int, step: Int, value: Int) {
        guard !locks.contains(step) else { return }
        state.setParameter(slot: target.slot, moduleID: target.moduleID,
                           paramIndex: layout.rowStarts[row] + step, value: value, area: target.area)
    }

    /// Rows that hold the pattern: both gate rows on SeqEvent, values + gates elsewhere.
    private var rows: [Int] {
        [0, 1]
    }

    // MARK: Operations

    func shift(_ amount: Int) {
        var all: [Int: Int] = [:]
        for row in rows {
            all.merge(changes(row: row, SequencePattern.rotated(layout.row(row, in: parameters), by: amount, length: length),
                              keepLocked: false)) { $1 }
        }
        write(all)
    }

    func reverse() {
        var all: [Int: Int] = [:]
        for row in rows {
            all.merge(changes(row: row, SequencePattern.reversed(layout.row(row, in: parameters), length: length),
                              keepLocked: false)) { $1 }
        }
        write(all)
    }

    func invert() {
        switch layout.kind {
        case .event:
            var all: [Int: Int] = [:]
            for row in rows {
                all.merge(changes(row: row, SequencePattern.invertedGates(layout.row(row, in: parameters)))) { $1 }
            }
            write(all)
        case .note:
            write(changes(row: 0, SequencePattern.inverted(values, in: visibleRange)))
        case .value, .controlled:
            write(changes(row: 0, SequencePattern.inverted(values)))
        }
    }

    func doubleFirstHalf() {
        var all: [Int: Int] = [:]
        for row in rows {
            all.merge(changes(row: row, SequencePattern.doubledFirstHalf(layout.row(row, in: parameters)))) { $1 }
        }
        write(all)
    }

    func transpose(_ semitones: Int) {
        write(changes(row: 0, SequencePattern.transposed(values, by: semitones)))
    }

    func snapToScale() {
        write(changes(row: 0, values.map { memory.scale.snapped($0, root: memory.root) }))
    }

    func clear() {
        if layout.kind == .event {
            var all: [Int: Int] = [:]
            for row in rows {
                all.merge(changes(row: row, Array(repeating: 0, count: SequencerLayout.steps))) { $1 }
            }
            write(all)
        } else {
            let cleared = SequencePattern.clearedValue(kind: layout.kind, bipolar: layout.isBipolar(in: parameters))
            write(changes(row: 0, Array(repeating: cleared, count: SequencerLayout.steps)))
        }
    }

    func randomize() {
        var generator = SystemRandomNumberGenerator()
        switch layout.kind {
        case .event:
            var all: [Int: Int] = [:]
            for row in rows {
                all.merge(changes(row: row, randomGates())) { $1 }
            }
            writeRandom(all)
        case .note:
            let candidates = memory.scale.notes(in: visibleRange, root: memory.root)
            let notes = (0 ..< SequencerLayout.steps).map { _ in
                candidates.randomElement(using: &generator) ?? 64
            }
            writeRandom(changes(row: 0, notes))
        case .value, .controlled:
            writeRandom(changes(row: 0, SequencePattern.randomValues(using: &generator)))
        }
    }

    /// SeqNote: a new melody from the Generate ▸ Notes menu, inside the visible octaves and the chosen
    /// scale. Markov learns from the pattern as it is now. Locked steps stay; one ⌘Z, ↺ undoes it.
    func generate(_ kind: SequenceGenerator) {
        guard layout.kind == .note else { return }
        var generator = SystemRandomNumberGenerator()
        let notes = kind.notes(current: values, length: length, range: visibleRange,
                               scale: memory.scale, root: memory.root, using: &generator)
        writeRandom(changes(row: 0, notes))
    }

    /// SeqVal / SeqLev / SeqCtr: every step that plays gets a small random nudge of its value (up to the
    /// window's Human %); resting and locked steps stay. One ⌘Z, ↺ undoes it. Notes and rhythms are not touched.
    func humanize() {
        guard layout.kind == .value || layout.kind == .controlled else { return }
        var generator = SystemRandomNumberGenerator()
        let jittered = SequenceHumanize.jittered(values, playing: gates.map { $0 != 0 }, length: length,
                                                 amount: memory.humanizeAmount, using: &generator)
        writeRandom(changes(row: 0, jittered))
    }

    /// SeqVal / SeqLev / SeqCtr: the curve chosen in the Curve group over the played steps (Length). Locked
    /// steps stay; one ⌘Z, ↺ undoes it. Row 2 (the trigger row) is not touched.
    func generateCurve() {
        guard layout.kind == .value || layout.kind == .controlled else { return }
        var generator = SystemRandomNumberGenerator()
        let values = memory.curveShape.values(length: length, cycles: memory.curveCycles, phase: memory.curvePhase,
                                              low: memory.curveLow, high: memory.curveHigh, using: &generator)
        writeRandom(changes(row: 0, values))
    }

    /// SeqNote: the chord chosen in the Arpeggio group played over the steps in the chosen direction.
    /// Chord types start on the root (scale bar) in the lowest visible octave, like the note figures
    /// in Presets; scale chords start on the first degree there. Locked steps stay; one ⌘Z, ↺ undoes it.
    func arpeggiate() {
        guard layout.kind == .note else { return }
        let low = visibleRange.lowerBound
        let base = low + ((memory.root - low) % 12 + 12) % 12
        let chord: [Int]
        switch memory.arpChord {
        case let .type(type):
            chord = SequenceArpeggio.notes(of: type, root: base)
        case let .scaleDegree(degree, seventh):
            let top = SequenceArpeggio.degreeCount(of: memory.scale) - 1
            chord = SequenceArpeggio.scaleChord(degree: min(degree, top), seventh: seventh,
                                                scale: memory.scale, root: memory.root, base: base)
        case .pattern:
            chord = Array(values.prefix(length))
        }
        var generator = SystemRandomNumberGenerator()
        let notes = SequenceArpeggio.steps(chord: chord, direction: memory.arpDirection,
                                           octaves: memory.arpOctaves, using: &generator)
        guard !notes.isEmpty else { return }
        writeRandom(changes(row: 0, notes))
    }

    /// Random on/off for the step row of SeqNote / SeqVal / SeqLev / SeqCtr (values stay).
    func randomizeSteps() {
        writeRandom(changes(row: 1, randomGates()))
    }

    /// Presets menu: a curve, a note figure or a rhythm in place of the pattern (locked steps stay).
    func applyPreset(_ preset: SequencePresets.Preset) {
        switch layout.kind {
        case .event:
            memory.linkedRests.remove(target) // both rows are set: a link to Row 1 would overwrite Row 2
            var all = changes(row: 0, preset.steps)
            all.merge(changes(row: 1, preset.second)) { $1 }
            writeRandom(all)
        case .note:
            // The root note in the lowest visible octave leaves room above for arpeggios.
            let low = visibleRange.lowerBound
            let base = low + ((memory.root - low) % 12 + 12) % 12
            writeRandom(changes(row: 0, SequencePresets.notes(of: preset, base: base)))
        case .value, .controlled:
            writeRandom(changes(row: 0, preset.steps))
        }
    }

    /// Which of the user's pattern lists this sequencer uses: notes, rhythms or curves.
    var userCategory: SequenceUserPattern.Category {
        SequenceUserPattern.Category(kind: layout.kind)
    }

    /// Presets ▸ My patterns ▸ Save: the pattern the module holds now — Row 1, Row 2 and Length.
    func saveCurrentAsUserPattern(named name: String) {
        let memory = SequenceEditorMemory.shared
        memory.library.save(name: name, category: userCategory,
                            values: layout.row(0, in: parameters), gates: layout.row(1, in: parameters),
                            length: layout.lengthIndex == nil ? nil : length)
        memory.saveLibrary()
    }

    /// Presets ▸ My patterns ▸ a name: both rows and the Length in place of the pattern (locked steps
    /// stay). One ⌘Z; ↺ puts the old pattern back.
    func applyUserPattern(_ pattern: SequenceUserPattern) {
        var all = changes(row: 0, pattern.values)
        all.merge(changes(row: 1, pattern.gates)) { $1 }
        if let lengthIndex = layout.lengthIndex, let saved = pattern.length,
           parameters.indices.contains(lengthIndex), parameters[lengthIndex] != saved - 1
        {
            all[lengthIndex] = saved - 1
        }
        if layout.kind == .event { SequenceEditorMemory.shared.linkedRests.remove(target) } // both rows are set
        writeRandom(all)
    }

    func deleteUserPattern(_ pattern: SequenceUserPattern) {
        let memory = SequenceEditorMemory.shared
        memory.library.remove(id: pattern.id)
        memory.saveLibrary()
    }

    /// Presets ▸ Rhythm bank: one 16-step on/off pattern into Row 1 of a SeqEvent, or into the step
    /// on/off row of the other sequencers (their values stay). Locked steps stay; one ⌘Z, ↺ undoes it.
    func applyRhythmBank(_ index: Int) {
        let flags = SequenceRhythmBank.flags(at: index)
        guard !flags.isEmpty else { return }
        writeRandom(changes(row: layout.kind == .event ? 0 : 1, flags))
    }

    /// SeqNote: the notes of the chosen scale in the visible octaves, from the root upwards (or from
    /// the top downwards), repeated over the 16 steps.
    func applyScaleRun(descending: Bool) {
        guard layout.kind == .note else { return }
        let all = memory.scale.notes(in: visibleRange, root: memory.root)
        let run = descending ? all.sorted(by: >) : all.filter { $0 % 12 == memory.root }.first.map { root in
            all.filter { $0 >= root }
        } ?? all
        guard !run.isEmpty else { return }
        writeRandom(changes(row: 0, (0 ..< SequencerLayout.steps).map { run[$0 % run.count] }))
    }

    /// SeqNote: gives every step that plays (step on/off row) a note of the chosen scale inside the
    /// visible octaves; steps that rest and locked steps keep their notes. One ↺ undoes it.
    func fillNotesOnHits() {
        guard layout.kind == .note else { return }
        var generator = SystemRandomNumberGenerator()
        let candidates = memory.scale.notes(in: visibleRange, root: memory.root)
        let playing = gates
        let filled = values.enumerated().map { step, value in
            step < length && playing[step] != 0 && !locks.contains(step)
                ? (candidates.randomElement(using: &generator) ?? value) : value
        }
        writeRandom(changes(row: 0, filled))
    }

    /// On/off flags where each step plays with the window's Density.
    private func randomGates() -> [Int] {
        var generator = SystemRandomNumberGenerator()
        return SequencePattern.randomGates(density: Double(memory.density) / 100, using: &generator)
    }

    /// Mutate: changes only the window's Mutate share of the played, unlocked steps. SeqEvent
    /// flips on/off in both rows; the others draw new values (SeqNote: notes of the chosen scale
    /// inside the visible octaves) and keep the step row.
    func mutate() {
        var generator = SystemRandomNumberGenerator()
        switch layout.kind {
        case .event:
            var all: [Int: Int] = [:]
            for row in rows {
                let steps = SequencePattern.mutationSteps(length: length, percent: memory.mutate,
                                                          locked: locks, using: &generator)
                all.merge(changes(row: row, SequencePattern.flippedGates(layout.row(row, in: parameters), at: steps))) { $1 }
            }
            writeRandom(all)
        case .note:
            let candidates = memory.scale.notes(in: visibleRange, root: memory.root)
            let steps = SequencePattern.mutationSteps(length: length, percent: memory.mutate,
                                                      locked: locks, using: &generator)
            writeRandom(changes(row: 0, SequencePattern.replaced(values, at: steps) {
                candidates.randomElement(using: &generator) ?? 64
            }))
        case .value, .controlled:
            let steps = SequencePattern.mutationSteps(length: length, percent: memory.mutate,
                                                      locked: locks, using: &generator)
            writeRandom(changes(row: 0, SequencePattern.replaced(values, at: steps) {
                Int.random(in: 0 ... 127, using: &generator)
            }))
        }
    }

    func copy() {
        memory.clipboard = [values, gates]
    }

    func paste() {
        guard let clip = memory.clipboard else { return }
        var all: [Int: Int] = [:]
        for row in rows where row < clip.count {
            var incoming = clip[row]
            // A value row pasted into gates (or the other way) is read as on/off.
            if layout.isGateRow(row) { incoming = incoming.map { $0 > 0 ? 1 : 0 } }
            all.merge(changes(row: row, incoming)) { $1 }
        }
        write(all)
    }

    func setLength(_ newLength: Int) {
        guard let index = layout.lengthIndex else { return }
        write([index: max(1, min(SequencerLayout.steps, newLength)) - 1])
    }

    func setLooping(_ looping: Bool) {
        guard let index = layout.loopIndex else { return }
        write([index: looping ? 1 : 0])
    }

    func toggleLock(_ step: Int) {
        var set = locks
        if set.contains(step) { set.remove(step) } else { set.insert(step) }
        memory.locks[target] = set
    }
}

// MARK: - Toolbar groups

/// A caption over a group of controls — Shift, Clipboard, Generate, Pattern.
struct SeqGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: TopBarMetrics.captionSize)).foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(SeqColor.card))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SeqColor.cardBorder, lineWidth: 1))
    }
}

/// Lays children out left to right and starts a new row when the next one does not fit.
private struct SeqWrapLayout: Layout {
    var hSpacing: CGFloat
    var vSpacing: CGFloat

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        var positions: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - hSpacing)
        }
        return (positions, CGSize(width: width, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let layout = arrange(subviews, maxWidth: bounds.width)
        for (index, point) in layout.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  proposal: .unspecified)
        }
    }
}

// MARK: - Edit tab

private struct SequenceEditTab: View {
    let editor: SequenceEditing
    let panels: PanelController?
    /// Presets ▸ My patterns ▸ Save current pattern…: the name prompt.
    @State private var savingPattern = false
    @State private var patternName = ""

    /// Reports the toolbar's height as laid out: it wraps into more rows in a narrow window, and the panel raises
    /// the window's lowest height by the extra rows (the bars were squeezed to nothing — user's screenshots
    /// 2026-11-18). One fixed view structure: switching between two layouts while the window is dragged was jerky.
    var onToolbarHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
                .background(GeometryReader { inner in
                    Color.clear.onChange(of: inner.size.height, initial: true) { _, height in onToolbarHeight(height) }
                })
            if editor.layout.kind == .note { scaleBar }
            StepHeader(editor: editor)
            switch editor.layout.kind {
            case .note:
                VStack(spacing: 8) {
                    VStack(spacing: 8) {
                        NoteGrid(editor: editor).frame(minHeight: 120)
                        GateRow(editor: editor, row: 1, label: "Step on", color: SeqColor.on, fillColumns: true)
                    }
                    .stepOverlay(editor)
                    .stepHover()
                    ProbabilityRow(editor: editor)
                }
            case .value, .controlled:
                VStack(spacing: 8) {
                    VStack(spacing: 8) {
                        ValueGrid(editor: editor).frame(minHeight: 90)
                        GateRow(editor: editor, row: 1, label: "Trigger", color: SeqColor.trigger, fillColumns: true)
                    }
                    .stepOverlay(editor)
                    .stepHover()
                    ProbabilityRow(editor: editor)
                }
            case .event:
                VStack(spacing: 8) {
                    GateRow(editor: editor, row: 0, label: "Row 1", color: SeqColor.trigger, cell: 40)
                    GateRow(editor: editor, row: 1, label: "Row 2", color: SeqColor.trigger, cell: 40)
                }
                .stepOverlay(editor)
                .stepHover()
                Spacer(minLength: 0)
            }
            connectionsBar
            Divider().padding(.top, 2)
            StepStatusBar(editor: editor)
        }
    }

    /// Four labelled groups that wrap to a second row when the window is narrow: Shift, Clipboard,
    /// Generate (Random, Mutate and their settings — window-only, shared with the All tab) and Pattern.
    private var toolbar: some View {
        SeqWrapLayout(hSpacing: 10, vSpacing: 8) {
            SeqGroup(title: "Shift") { editGroup }
            SeqGroup(title: "Clipboard") { fileGroup }
            SeqGroup(title: "Generate") { generateGroup }
            if editor.layout.kind == .note {
                SeqGroup(title: "Arpeggio") { arpeggioGroup }
            }
            if editor.layout.kind == .value || editor.layout.kind == .controlled {
                SeqGroup(title: "Curve") { curveGroup }
            }
            SeqGroup(title: "Pattern") { lengthGroup }
            SeqGroup(title: "Rhythm bank") { rhythmStepper }
        }
    }

    /// Previous / next pattern of the Rhythm bank (all 122, in bank order — the numbers of the menu): auditioning
    /// rhythms one after the other. Sets Row 1 of a SeqEvent or the step on/off row of the others; locked steps
    /// stay; one ⌘Z, ↺ undoes it. The first step from nothing goes to pattern 1 (next) or the last (previous).
    private var rhythmStepper: some View {
        let total = SequenceRhythmBank.patterns.count
        let cursor = SequenceEditorMemory.shared.rhythmCursor[editor.target]
        return HStack(spacing: 4) {
            TopBarButton(content: .icon("chevron.left")) { stepRhythm(-1) }
                .help("Previous rhythm of the Rhythm bank")
            Menu(cursor.map { "\($0 + 1) / \(total)" } ?? "– / \(total)") {
                ForEach(SequenceRhythmBank.Role.allCases) { role in
                    rhythmBankMenu(role.title, indices: SequenceRhythmBank.indices(of: role))
                }
                Divider()
                rhythmBankMenu("All patterns", indices: Array(SequenceRhythmBank.patterns.indices))
            }
            .menuStyle(.button)
            .frame(width: 86)
            .help("Choose a rhythm from the Rhythm bank by role; the ticked one is the one chosen last")
            TopBarButton(content: .icon("chevron.right")) { stepRhythm(1) }
                .help("Next rhythm of the Rhythm bank")
        }
    }

    private func stepRhythm(_ delta: Int) {
        let total = SequenceRhythmBank.patterns.count
        let memory = SequenceEditorMemory.shared
        let next = memory.rhythmCursor[editor.target].map { (($0 + delta) % total + total) % total }
            ?? (delta > 0 ? 0 : total - 1)
        applyRhythmEntry(next)
    }

    /// Applies Rhythm bank pattern `index` and remembers it: the arrows go on from it and the menus tick it.
    private func applyRhythmEntry(_ index: Int) {
        SequenceEditorMemory.shared.rhythmCursor[editor.target] = index
        editor.applyRhythmBank(index)
    }

    private var editGroup: some View {
        HStack(spacing: 4) {
            TopBarButton(content: .icon("arrow.left")) { editor.shift(-1) }
                .help("Shift pattern one step left")
            TopBarButton(content: .icon("arrow.right")) { editor.shift(1) }
                .help("Shift pattern one step right")
            SeqToolButton(icon: "arrow.left.arrow.right", title: "Reverse") { editor.reverse() }
                .help("Reverse the pattern")
            SeqToolButton(icon: "arrow.up.arrow.down", title: "Invert") { editor.invert() }
                .help("Invert the pattern (high becomes low)")
            SeqToolButton(icon: "square.on.square", title: "Double 1–8") { editor.doubleFirstHalf() }
                .help("Copy steps 1–8 to 9–16")
            if editor.layout.kind == .note {
                SeqDivider()
                TopBarButton(content: .text("−12")) { editor.transpose(-12) }.help("Transpose one octave down")
                TopBarButton(content: .text("−1")) { editor.transpose(-1) }.help("Transpose one semitone down")
                TopBarButton(content: .text("+1")) { editor.transpose(1) }.help("Transpose one semitone up")
                TopBarButton(content: .text("+12")) { editor.transpose(12) }.help("Transpose one octave up")
            }
        }
    }

    private var fileGroup: some View {
        HStack(spacing: 4) {
            SeqToolButton(icon: "doc.on.doc", title: "Copy") { editor.copy() }
                .help("Copy the pattern")
            SeqToolButton(icon: "doc.on.clipboard", title: "Paste",
                          isEnabled: SequenceEditorMemory.shared.clipboard != nil) { editor.paste() }
                .help("Paste the copied pattern (locked steps stay)")
            SeqToolButton(icon: "trash", title: "Clear", tint: SeqColor.destructive, outline: SeqColor.red) { editor.clear() }
                .help("Clear the steps (locked steps stay)")
        }
    }

    private var generateGroup: some View {
        @Bindable var memory = SequenceEditorMemory.shared
        return HStack(spacing: 4) {
            SeqToolButton(icon: "dice", title: "Random", tint: SeqColor.generate) { editor.randomize() }
                .help(editor.layout.kind == .event ? "Randomise the steps" : "Randomise the values")
            if editor.layout.kind != .event {
                SeqToolButton(icon: "die.face.4", title: "Random steps", tint: SeqColor.generate) { editor.randomizeSteps() }
                    .help("Randomise which steps play (values stay)")
            }
            if editor.layout.kind == .note {
                Menu("Notes") {
                    ForEach(SequenceGenerator.allCases) { kind in
                        Button(kind.title) { editor.generate(kind) }
                            .help(kind.help)
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Generate a new melody in the chosen scale — one ⌘Z, ↺ puts the old notes back")
            }
            SeqNumberControl(title: "Density %", value: memory.density, range: 0 ... 100,
                             state: editor.state, patchGesture: false) { memory.density = $0 }
                .help(editor.layout.kind == .event
                    ? "Random: share of steps that play"
                    : "Random steps: share of steps that play")
                .padding(.leading, 6)
            SeqNumberControl(title: "Mutate %", value: memory.mutate, range: 0 ... 100,
                             state: editor.state, patchGesture: false) { memory.mutate = $0 }
                .padding(.leading, 6)
            SeqToolButton(icon: "wand.and.stars", title: "Mutate", tint: SeqColor.generate) { editor.mutate() }
                .help(editor.layout.kind == .event
                    ? "Flip this share of the steps, keep the rest"
                    : "Draw new values for this share of the steps, keep the rest")
            if editor.layout.kind == .value || editor.layout.kind == .controlled {
                SeqNumberControl(title: "Human %", value: memory.humanizeAmount, range: 0 ... 100,
                                 state: editor.state, patchGesture: false) { memory.humanizeAmount = $0 }
                    .help("Humanize: the largest nudge, in percent of the range (100 % = ±63)")
                    .padding(.leading, 6)
                SeqToolButton(icon: "hand.draw", title: "Humanize", tint: SeqColor.generate) { editor.humanize() }
                    .help("Nudge the value of every step that plays by a small random amount — accents and "
                        + "modulation that breathe. Resting and locked steps stay. Values only: a G2 step has no timing.")
            }
            TopBarButton(content: .icon("arrow.counterclockwise"), isEnabled: editor.canUndoRandom) {
                editor.undoRandom()
            }
            .help("Undo the last Random or Mutate")
        }
    }

    /// Shape, cycles, phase, low and high end, and the button that writes the curve into the steps
    /// (SeqVal, SeqLev, SeqCtr). Low and High are percentages of the whole range; for a bipolar SeqVal
    /// 0 % is −64 and 100 % is +63.
    private var curveGroup: some View {
        @Bindable var memory = SequenceEditorMemory.shared
        return HStack(spacing: 4) {
            Menu(memory.curveShape.title) {
                ForEach(SequenceCurve.allCases) { shape in
                    Button(shape.title) { memory.curveShape = shape }
                        .help(shape.help)
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .help(memory.curveShape.help)
            SeqNumberControl(title: "Cycles", value: memory.curveCycles, range: 1 ... 4,
                             state: editor.state, patchGesture: false) { memory.curveCycles = $0 }
                .help("How many times the shape repeats over the played steps")
                .padding(.leading, 6)
            SeqNumberControl(title: "Phase", value: memory.curvePhase, range: 0 ... 15,
                             state: editor.state, patchGesture: false) { memory.curvePhase = $0 }
                .help("Moves the shape along by this many steps")
                .padding(.leading, 6)
            SeqNumberControl(title: "Low %", value: memory.curveLow, range: 0 ... 100,
                             state: editor.state, patchGesture: false)
            {
                memory.curveLow = min($0, memory.curveHigh)
            }
            .help("The lowest value the curve reaches, in percent of the range")
            .padding(.leading, 6)
            SeqNumberControl(title: "High %", value: memory.curveHigh, range: 0 ... 100,
                             state: editor.state, patchGesture: false)
            {
                memory.curveHigh = max($0, memory.curveLow)
            }
            .help("The highest value the curve reaches, in percent of the range")
            .padding(.leading, 6)
            SeqToolButton(icon: "point.topleft.down.curvedto.point.bottomright.up", title: "Curve",
                          tint: SeqColor.generate) { editor.generateCurve() }
                .help("Write the curve into the values — one ⌘Z, ↺ puts the old values back")
        }
    }

    /// Chord, direction, octaves and the button that writes the arpeggio into the steps (SeqNote).
    private var arpeggioGroup: some View {
        @Bindable var memory = SequenceEditorMemory.shared
        let root = NoteName.pitchClass(memory.root)
        let scale = SequenceArpeggio.degreeScale(memory.scale)
        let degrees = SequenceArpeggio.degreeCount(of: memory.scale)
        func degreeName(_ degree: Int, seventh: Bool) -> String {
            SequenceArpeggio.scaleChordName(degree: degree, seventh: seventh, scale: memory.scale,
                                            root: memory.root) { NoteName.pitchClass($0) }
        }
        let chordTitle: String = switch memory.arpChord {
        case let .type(type): root + type.suffix
        case let .scaleDegree(degree, seventh): degreeName(min(degree, degrees - 1), seventh: seventh)
        case .pattern: "Pattern notes"
        }
        return HStack(spacing: 4) {
            Menu(chordTitle) {
                Section("Chord on \(root)") {
                    ForEach(ChordType.allCases) { type in
                        Button("\(root)\(type.suffix) — \(type.title)") { memory.arpChord = .type(type) }
                    }
                }
                Section("Triads of \(scale.title)") {
                    ForEach(0 ..< degrees, id: \.self) { degree in
                        Button("\(degree + 1) — \(degreeName(degree, seventh: false))") {
                            memory.arpChord = .scaleDegree(degree, seventh: false)
                        }
                    }
                }
                Section("Seventh chords of \(scale.title)") {
                    ForEach(0 ..< degrees, id: \.self) { degree in
                        Button("\(degree + 1) — \(degreeName(degree, seventh: true))") {
                            memory.arpChord = .scaleDegree(degree, seventh: true)
                        }
                    }
                }
                Divider()
                Button("Notes of the pattern") { memory.arpChord = .pattern }
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Chord to play: a type on the root, a chord of the scale, or the notes the pattern already has")
            Menu(memory.arpDirection.title) {
                ForEach(ArpeggioDirection.allCases) { direction in
                    Button(direction.title) { memory.arpDirection = direction }
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Order the chord notes are played in")
            SeqNumberControl(title: "Oct", value: memory.arpOctaves, range: 1 ... 3,
                             state: editor.state, patchGesture: false) { memory.arpOctaves = $0 }
                .help("How many octaves the chord spans")
                .padding(.leading, 6)
            SeqToolButton(icon: "stairs", title: "Arpeggio", tint: SeqColor.generate) { editor.arpeggiate() }
                .help("Write the chord into the steps — one ⌘Z, ↺ puts the old notes back")
        }
    }

    /// What the module's jacks are wired to — the Clk, Rst, Loop, Park (and on SeqNote Rec and Rec
    /// Enable) inputs and the Link output. Read from the cables, as on the module itself; the cables
    /// are made on the canvas. Park stops the sequencer on a step, Rec records on the fly, Link
    /// passes the end of the pattern to the next sequencer in a chain.
    private var connectionsBar: some View {
        let patch = editor.state.slots.indices.contains(editor.target.slot)
            ? editor.state.slots[editor.target.slot] : G2Patch()
        let modules = Dictionary(uniqueKeysWithValues: patch.modules(in: editor.target.area).map { ($0.id, $0) })
        let edges = G2SignalGraph(patch: patch, area: editor.target.area).edges
        let def = ModuleDatabase.module(id: editor.module.typeID)
        func name(_ id: Int) -> String {
            guard let module = modules[id] else { return "?" }
            return module.label.isEmpty ? (ModuleDatabase.module(id: module.typeID)?.shortName ?? "Module") : module.label
        }
        func edge(of input: String) -> G2SignalGraph.Edge? {
            guard let index = def?.inputs.firstIndex(where: { $0.name == input }) else { return nil }
            return edges.first { $0.toModule == editor.module.id && $0.toInput == index }
        }
        func source(of input: String) -> JackLink? {
            guard let edge = edge(of: input) else { return nil }
            let output = modules[edge.fromModule].flatMap { ModuleDatabase.module(id: $0.typeID) }
                .flatMap { $0.outputs.indices.contains(edge.fromOutput) ? $0.outputs[edge.fromOutput].name : nil }
            return JackLink(text: output.map { "\(name(edge.fromModule)) · \($0)" } ?? name(edge.fromModule),
                            moduleID: edge.fromModule)
        }
        var items: [(String, JackLink?, String)] = [
            ("Clk", source(of: "Clk"), "Clock input"),
            ("Rst", source(of: "Rst"), "Reset input: back to step 1"),
            ("Loop", source(of: "Loop"), "Loop input"),
            ("Park", source(of: "Park"), "Park input: stops the sequencer on its step"),
        ]
        if editor.layout.kind == .note {
            items.append(("Rec", source(of: "RecVal"), "Rec input: the value recorded on each Clk while Rec Enable is high"))
            items.append(("Rec En", source(of: "RecEnable"), "Rec Enable input: high = record instead of play"))
        }
        let linkIndex = def?.outputs.firstIndex(where: { $0.name == "Link" })
        let linked = edges.filter { $0.fromModule == editor.module.id && $0.fromOutput == linkIndex }
            .compactMap { edge -> JackLink? in
                let input = modules[edge.toModule].flatMap { ModuleDatabase.module(id: $0.typeID) }
                    .flatMap { $0.inputs.indices.contains(edge.toInput) ? $0.inputs[edge.toInput].name : nil }
                return input.map { JackLink(text: "\(name(edge.toModule)) · \($0)", moduleID: edge.toModule) }
            }
        items.append(("Link", linked.first.map { JackLink(text: linked.count > 1 ? "\($0.text) +\(linked.count - 1)" : $0.text,
                                                          moduleID: $0.moduleID) },
                      "Link output: end of the pattern, for chaining sequencers"))
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ForEach(items.indices, id: \.self) { chip(items[$0]) }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) { ForEach(items.indices.prefix(4), id: \.self) { chip(items[$0]) }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) { ForEach(items.indices.dropFirst(4), id: \.self) { chip(items[$0]) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// A jack as a label, not a button: a dot (grey = nothing connected, blue = connected), the jack's
    /// name and where the cable goes. A connected jack can be clicked: the module on the other end is
    /// selected on the canvas. An empty one only explains itself.
    private func chip(_ item: (title: String, link: JackLink?, help: String)) -> some View {
        JackLabel(title: item.title, link: item.link, help: item.help) { moduleID in
            panels?.onSelectModule?(editor.target.area, moduleID)
        }
    }

    private var lengthGroup: some View {
        HStack(spacing: 4) {
            if editor.layout.lengthIndex != nil {
                SeqNumberControl(title: "Length", value: editor.length, range: 1 ... 16, state: editor.state) {
                    editor.setLength($0)
                }
            }
            if editor.layout.loopIndex != nil {
                SeqToolButton(icon: "repeat", title: "Loop", isOn: editor.isLooping) {
                    editor.setLooping(!editor.isLooping)
                }
                .help("Loop, or play once (1-Cycle, used in chains)")
            }
            TopBarButton(content: .icon("chevron.left")) { stepPreset(-1) }
                .help("Previous preset: the same list as the Presets menu, and your own patterns after it")
            presetsMenu
            TopBarButton(content: .icon("chevron.right")) { stepPreset(1) }
                .help("Next preset: the same list as the Presets menu, and your own patterns after it")
        }
    }

    /// What the arrows step through, in the order of the Presets menu: scale runs (SeqNote), the ready-made
    /// patterns of this kind, then the user's own patterns of this kind.
    /// The style submenus of this kind's presets, in the order they first appear.
    private var presetGroups: [String] {
        let list = SequencePresets.figures
        guard editor.layout.kind == .note else { return [] }
        var seen: [String] = []
        for group in list.compactMap(\.group) where !seen.contains(group) {
            seen.append(group)
        }
        return seen
    }

    /// How many ready-made patterns (not scale runs, not My patterns) the Presets menu holds for this kind.
    private var presetListCount: Int {
        switch editor.layout.kind {
        case .note: SequencePresets.figures.count
        case .event: SequencePresets.rhythms.count
        case .value, .controlled: SequencePresets.curves.count
        }
    }

    private var presetEntries: [(name: String, apply: () -> Void)] {
        var entries: [(name: String, apply: () -> Void)] = []
        switch editor.layout.kind {
        case .note:
            entries.append(("Scale up", { editor.applyScaleRun(descending: false) }))
            entries.append(("Scale down", { editor.applyScaleRun(descending: true) }))
            entries += SequencePresets.figures.map { preset in (preset.name, { editor.applyPreset(preset) }) }
        case .event:
            entries += SequencePresets.rhythms.map { preset in (preset.name, { editor.applyPreset(preset) }) }
        case .value, .controlled:
            entries += SequencePresets.curves.map { preset in (preset.name, { editor.applyPreset(preset) }) }
        }
        let mine = SequenceEditorMemory.shared.library.patterns(in: editor.userCategory)
        entries += mine.map { pattern in ("My: \(pattern.name)", { editor.applyUserPattern(pattern) }) }
        return entries
    }

    /// Previous / next preset: applies it like a pick from the menu (one ⌘Z, ↺ undoes it). The first step
    /// from nothing goes to the first preset (next) or the last (previous), and the list wraps round.
    private func stepPreset(_ delta: Int) {
        let entries = presetEntries
        guard !entries.isEmpty else { return }
        let memory = SequenceEditorMemory.shared
        let count = entries.count
        let next = memory.presetCursor[editor.target].map { (($0 + delta) % count + count) % count }
            ?? (delta > 0 ? 0 : count - 1)
        applyPresetEntry(next)
    }

    /// Applies entry `index` of the preset list and remembers it: the arrows go on from it and the menu
    /// ticks it.
    private func applyPresetEntry(_ index: Int) {
        let entries = presetEntries
        guard entries.indices.contains(index) else { return }
        SequenceEditorMemory.shared.presetCursor[editor.target] = index
        entries[index].apply()
    }

    /// A menu item that shows a tick when it is the pattern last chosen (menu or arrows).
    private func tickedItem(_ title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isCurrent }, set: { _ in action() }))
    }

    /// Ready-made patterns: curves (SeqVal / SeqLev / SeqCtr), note figures and scale runs (SeqNote),
    /// drum rhythms (SeqEvent). One undo step; ↺ also puts the old pattern back; locked steps stay.
    private var presetsMenu: some View {
        let kind = editor.layout.kind
        let list = switch kind {
        case .event: SequencePresets.rhythms
        case .note: SequencePresets.figures
        case .value, .controlled: SequencePresets.curves
        }
        let entries = presetEntries
        let cursor = SequenceEditorMemory.shared.presetCursor[editor.target]
        let current = cursor.flatMap { entries.indices.contains($0) ? entries[$0].name : nil }
        // Entry numbers of `presetEntries`: the two scale runs (SeqNote), the ready-made patterns, then My patterns.
        let first = kind == .note ? 2 : 0
        return Menu(current ?? "Presets") {
            if kind == .note {
                tickedItem("Scale up", isCurrent: cursor == 0) { applyPresetEntry(0) }
                tickedItem("Scale down", isCurrent: cursor == 1) { applyPresetEntry(1) }
                Divider()
            }
            // The main list, then one submenu per style (note figures only; the arrows step through all of them
            // in this order).
            ForEach(Array(list.enumerated()).filter { $0.element.group == nil }, id: \.element.id) { offset, preset in
                tickedItem(preset.name, isCurrent: cursor == first + offset) { applyPresetEntry(first + offset) }
            }
            ForEach(presetGroups, id: \.self) { group in
                Menu(group) {
                    ForEach(Array(list.enumerated()).filter { $0.element.group == group }, id: \.element.id) { offset, preset in
                        tickedItem(preset.name, isCurrent: cursor == first + offset) { applyPresetEntry(first + offset) }
                    }
                }
            }
            Divider()
            Menu("Rhythm bank") {
                ForEach(SequenceRhythmBank.Role.allCases) { role in
                    rhythmBankMenu(role.title, indices: SequenceRhythmBank.indices(of: role))
                }
                Divider()
                rhythmBankMenu("All patterns", indices: Array(SequenceRhythmBank.patterns.indices))
            }
            myPatternsMenu
        }
        .menuStyle(.button)
        .frame(width: 120)
        .alert("Save pattern", isPresented: $savingPattern) {
            TextField("Name", text: $patternName)
            Button("Save") { editor.saveCurrentAsUserPattern(named: patternName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved under Presets ▸ My patterns, among your \(editor.userCategory.title) patterns. "
                + "Same name replaces the old one.")
        }
        .help(kind == .note
            ? "Ready-made note figures from the root note (set in the scale bar); Rhythm bank sets which steps play"
            : kind == .event
            ? "Ready-made rhythms — one ⌘Z, ↺ puts the old pattern back; Rhythm bank sets Row 1"
            : "Ready-made patterns — one ⌘Z, ↺ puts the old pattern back; Rhythm bank sets which steps play")
    }

    /// The user's own patterns for this kind of sequencer (notes, rhythms or curves — kept apart), with
    /// Save and Delete. One undo step to load one; ↺ puts the old pattern back.
    private var myPatternsMenu: some View {
        let mine = SequenceEditorMemory.shared.library.patterns(in: editor.userCategory)
        return Menu("My patterns (\(mine.count))") {
            Button("Save current pattern…") {
                patternName = ""
                savingPattern = true
            }
            if !mine.isEmpty {
                Divider()
                let first = (editor.layout.kind == .note ? 2 : 0) + presetListCount
                let cursor = SequenceEditorMemory.shared.presetCursor[editor.target]
                ForEach(Array(mine.enumerated()), id: \.element.id) { offset, pattern in
                    tickedItem(pattern.name, isCurrent: cursor == first + offset) { applyPresetEntry(first + offset) }
                }
                Divider()
                Menu("Delete") {
                    ForEach(mine) { pattern in
                        Button(pattern.name) { editor.deleteUserPattern(pattern) }
                    }
                }
            }
        }
    }

    /// One entry of Presets ▸ Rhythm bank: the patterns of a role (or all), in pages of 20 named by
    /// their first and last pattern number.
    private func rhythmBankMenu(_ title: String, indices: [Int]) -> some View {
        Menu("\(title) (\(indices.count))") {
            ForEach(SequenceRhythmBank.pages(of: indices), id: \.first) { page in
                Menu("\(page[0] + 1)–\(page[page.count - 1] + 1)") {
                    ForEach(page, id: \.self) { index in
                        tickedItem(SequenceRhythmBank.label(at: index),
                                   isCurrent: SequenceEditorMemory.shared.rhythmCursor[editor.target] == index)
                        {
                            applyRhythmEntry(index)
                        }
                    }
                }
            }
        }
    }

    private var scaleBar: some View {
        @Bindable var memory = SequenceEditorMemory.shared
        return HStack(spacing: 8) {
            Text("Scale").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Root", selection: $memory.root) {
                ForEach(0 ..< 12, id: \.self) { Text(NoteName.pitchClass($0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 60)
            Picker("Scale", selection: $memory.scale) {
                ForEach(MusicalScale.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            TopBarButton(content: .text("Snap drawing"), isOn: memory.snapDrawing && memory.scale != .chromatic,
                         tint: SeqColor.blue, isEnabled: memory.scale != .chromatic)
            {
                memory.snapDrawing.toggle()
            }
            TopBarButton(content: .text("Snap notes"), isEnabled: memory.scale != .chromatic) {
                editor.snapToScale()
            }
            Spacer()
            Text("Zoom").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach([(12, "12"), (24, "24"), (0, "Fit")], id: \.0) { zoom, title in
                TopBarButton(content: .text(title), isOn: memory.noteZoom == zoom, tint: SeqColor.blue) {
                    memory.noteZoom = zoom
                    memory.lowNote[editor.target] = nil
                }
                .help(zoom == 0 ? "Show the played notes with a margin" : "Show \(zoom) semitones")
            }
            // Octave selector of the module: the highest note of the piano roll (module: C0–C7).
            Text("Top").font(.system(size: 11)).foregroundStyle(.secondary)
            TopBarValueField(text: NoteName.name(editor.lowNote + editor.visibleNotes - 1), width: 40)
            TopBarStepper(canIncrement: editor.lowNote + editor.visibleNotes - 1 + 12 <= 127,
                          canDecrement: editor.lowNote - 12 >= 0,
                          onIncrement: { editor.scrollNotes(by: 12) },
                          onDecrement: { editor.scrollNotes(by: -12) })
                .help("Highest note shown — one octave per click")
        }
        .controlSize(.small)
    }
}

enum NoteName {
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func pitchClass(_ index: Int) -> String {
        names[((index % 12) + 12) % 12]
    }

    /// Same octave numbering as the module's note display (64 = E4).
    static func name(_ note: Int) -> String {
        pitchClass(note) + "\(note / 12 - 1)"
    }

    static func isBlack(_ note: Int) -> Bool {
        pitchClass(note).count > 1
    }
}

/// Label column width shared by every row, so step columns line up.
private let labelWidth: CGFloat = 46

/// Step numbers with lock toggles above them.
private struct StepHeader: View {
    let editor: SequenceEditing

    var body: some View {
        HStack(spacing: 0) {
            Text("Lock").font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(0 ..< SequencerLayout.steps, id: \.self) { step in
                let locked = editor.locks.contains(step)
                Button { editor.toggleLock(step) } label: {
                    VStack(spacing: 1) {
                        Image(systemName: locked ? "lock.fill" : "lock.open")
                            .font(.system(size: 9))
                            .foregroundStyle(locked ? SeqColor.lock : Color.secondary.opacity(0.35))
                        Text("\(step + 1)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(step < editor.length ? Color.secondary : Color.secondary.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(locked ? "Unlock step \(step + 1)" : "Lock step \(step + 1)")
            }
        }
    }
}

/// Drawing stroke shared by the grids: one stroke = one undo step.
/// Hold ⇧ while dragging a bar: the grabbed step then moves by exactly one unit per few points
/// from where it was (user's idea 2026-11-16) instead of jumping to the pointer.
private struct FineDrag {
    let step: Int
    let startValue: Int
    let startY: CGFloat

    func value(at y: CGFloat) -> Int {
        startValue + Int(((startY - y) / 2.5).rounded())
    }
}

private struct Stroke {
    var active = false
    var gateValue = 1
}

/// SeqNote piano roll — one cell per step, rows set by the zoom (12 / 24 semitones, or Fit). A drawn
/// keyboard on the left, and a readout of the note under the pointer ("A3 (57)") as in the module.
private struct NoteGrid: View {
    let editor: SequenceEditing
    @State private var stroke = Stroke()
    @State private var pointer: CGPoint?
    /// Lowest note shown when a drag on the keyboard began.
    @State private var dragStartLow: Int?

    var body: some View {
        let low = editor.lowNote
        let rows = editor.visibleNotes
        let memory = SequenceEditorMemory.shared
        HStack(spacing: 0) {
            // Grab the keyboard and drag it up or down, or use the scroll wheel — the piano roll shows
            // 12 or 24 of the 128 notes, and notes outside it are outlined at the top or bottom edge.
            GeometryReader { geometry in
                let rowHeight = geometry.size.height / CGFloat(max(1, rows))
                keyboard(low: low, rows: rows)
                    .gesture(scrollDrag(rowHeight: rowHeight))
                    .background(NoteScrollWheel(rowHeight: rowHeight) { editor.scrollNotes(by: $0) })
                    .help("Drag up or down to scroll the notes; the scroll wheel works over the whole piano roll")
            }
            .frame(width: labelWidth - 4)
            .padding(.trailing, 4)

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let columnWidth = size.width / CGFloat(SequencerLayout.steps)
                        let rowHeight = size.height / CGFloat(rows)
                        for index in 0 ..< rows {
                            let note = low + rows - 1 - index
                            let inScale = memory.scale.contains(note, root: memory.root)
                            let rect = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: size.width, height: rowHeight)
                            context.fill(Path(rect.insetBy(dx: 0, dy: 0.5)),
                                         with: .color(!inScale ? SeqColor.offScale : (NoteName.isBlack(note) ? SeqColor.grid : SeqColor.gridAlt)))
                        }
                        for step in 0 ..< SequencerLayout.steps {
                            let note = editor.values[step]
                            let strong = editor.gates[step] != 0
                            // A note outside the window is an outline on the top or bottom row, as the
                            // module draws it — scroll the keyboard to see it.
                            let inside = visible(note, low: low, rows: rows)
                            let index = inside ? low + rows - 1 - note : (note >= low + rows ? 0 : rows - 1)
                            let rect = CGRect(x: CGFloat(step) * columnWidth, y: CGFloat(index) * rowHeight,
                                              width: columnWidth, height: rowHeight).insetBy(dx: 1, dy: 1)
                            if inside {
                                drawCell(context, rect: rect, color: SeqColor.on, strong: strong, radius: 2)
                            } else {
                                drawOutlineCell(context, rect: rect, color: SeqColor.on, strong: strong, radius: 2)
                            }
                        }
                        shadeBeyondLength(context: context, size: size, columnWidth: columnWidth, length: editor.length)
                        drawBeatLines(context: context, size: size, columnWidth: columnWidth)
                    }
                    .gesture(drawGesture(size: geometry.size, low: low, rows: rows))
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(point): pointer = point
                        case .ended: pointer = nil
                        }
                    }
                    readout(in: geometry.size, low: low, rows: rows)
                }
                .background(NoteScrollWheel(rowHeight: geometry.size.height / CGFloat(max(1, rows))) {
                    editor.scrollNotes(by: $0)
                })
            }
            .background(SeqColor.field)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SeqColor.fieldBorder, lineWidth: 1))
        }
    }

    /// The keys: white keys full width, black keys shorter and darker, as on a keyboard turned on its
    /// side. A key is tinted green while the pattern plays that note. C keys carry their name.
    private func keyboard(low: Int, rows: Int) -> some View {
        let played = Set((0 ..< editor.length).filter { editor.gates[$0] != 0 }.map { editor.values[$0] })
        return Canvas { context, size in
            let rowHeight = size.height / CGFloat(rows)
            for index in 0 ..< rows {
                let note = low + rows - 1 - index
                let black = NoteName.isBlack(note)
                let y = CGFloat(index) * rowHeight
                let white = CGRect(x: 0, y: y, width: size.width, height: rowHeight)
                if !black {
                    context.fill(Path(white.insetBy(dx: 0, dy: 0.5)), with: .color(Color(white: 0.84)))
                } else {
                    // a black key sits on the white strip behind it, so the gap between white keys stays
                    context.fill(Path(white.insetBy(dx: 0, dy: 0.5)), with: .color(Color(white: 0.84)))
                    context.fill(Path(roundedRect: CGRect(x: 0, y: y + 0.5, width: size.width * 0.62, height: rowHeight - 1),
                                      cornerRadius: 1.5),
                                 with: .color(Color(white: 0.10)))
                }
                if played.contains(note) {
                    let tint = black ? CGRect(x: 0, y: y + 0.5, width: size.width * 0.62, height: rowHeight - 1) : white.insetBy(dx: 0, dy: 0.5)
                    context.fill(Path(roundedRect: tint, cornerRadius: 1.5), with: .color(SeqColor.green.opacity(0.75)))
                }
                // Black keys carry their names too (white on the dark key), when the rows are tall enough to read.
                if black, rowHeight >= 10 {
                    context.draw(Text(NoteName.name(note)).font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85)),
                        at: CGPoint(x: size.width * 0.62 - 4, y: white.midY), anchor: .trailing)
                }
                if note % 12 == 0 || (!black && rowHeight >= 11) {
                    context.draw(Text(NoteName.name(note)).font(.system(size: 8, weight: note % 12 == 0 ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(Color.black),
                        at: CGPoint(x: size.width - 3, y: white.midY), anchor: .trailing)
                }
            }
        }
    }

    /// "A3 (57)" next to the pointer — the note a click would write (after Snap drawing).
    @ViewBuilder
    private func readout(in size: CGSize, low: Int, rows: Int) -> some View {
        if let pointer, let note = note(at: pointer, size: size, low: low, rows: rows) {
            Text("\(NoteName.name(note)) (\(note))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.82)))
                .offset(x: min(max(pointer.x + 12, 0), size.width - 70), y: max(pointer.y - 26, 0))
                .allowsHitTesting(false)
        }
    }

    private func note(at point: CGPoint, size: CGSize, low: Int, rows: Int) -> Int? {
        let index = Int(point.y / (size.height / CGFloat(rows)))
        guard (0 ..< rows).contains(index), (0 ..< size.width).contains(point.x) else { return nil }
        var note = low + rows - 1 - index
        let memory = SequenceEditorMemory.shared
        if memory.snapDrawing, memory.scale != .chromatic { note = memory.scale.snapped(note, root: memory.root) }
        return note
    }

    private func visible(_ note: Int, low: Int, rows: Int) -> Bool {
        note >= low && note < low + rows
    }

    /// Dragging the keyboard moves the notes with the pointer: down shows higher notes, up lower ones.
    private func scrollDrag(rowHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                let start = dragStartLow ?? editor.lowNote
                dragStartLow = start
                guard rowHeight > 0 else { return }
                editor.setLowNote(start + Int((drag.translation.height / rowHeight).rounded()))
            }
            .onEnded { _ in dragStartLow = nil }
    }

    private func drawGesture(size: CGSize, low: Int, rows: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                pointer = drag.location
                if !stroke.active {
                    stroke.active = true
                    editor.state.beginParameterGesture()
                }
                let step = Int(drag.location.x / (size.width / CGFloat(SequencerLayout.steps)))
                guard (0 ..< SequencerLayout.steps).contains(step),
                      let note = note(at: drag.location, size: size, low: low, rows: rows) else { return }
                editor.setStep(row: 0, step: step, value: note)
            }
            .onEnded { _ in
                stroke.active = false
                editor.state.endParameterGesture()
            }
    }
}

/// Probability of each step: the bars of the Chance lane that gates this sequencer's trigger
/// (a SeqLev feeding the Prob input of the RndTrig that the trigger passes through). Without a
/// Chance lane a button adds one. SeqEvent (two trigger rows) uses Add lane in the All tab.
private struct ProbabilityRow: View {
    let editor: SequenceEditing
    private var memory: SequenceEditorMemory {
        SequenceEditorMemory.shared
    }

    private var chance: SequenceEditing? {
        let state = editor.state, target = editor.target
        guard state.slots.indices.contains(target.slot),
              let output = PatchState.chanceOutputs(typeID: editor.module.typeID).first?.output,
              let probInput = ModuleDatabase.module(id: PatchState.chanceTriggerTypeID)?.inputs
              .firstIndex(where: { $0.name == "Prob" }) else { return nil }
        let patch = state.slots[target.slot]
        let modules = Dictionary(uniqueKeysWithValues: patch.modules(in: target.area).map { ($0.id, $0) })
        let edges = G2SignalGraph(patch: patch, area: target.area).edges
        guard let trigger = edges.first(where: {
            $0.fromModule == target.moduleID && $0.fromOutput == output
                && modules[$0.toModule]?.typeID == PatchState.chanceTriggerTypeID
        })?.toModule,
            let levelID = edges.first(where: {
                $0.toModule == trigger && $0.toInput == probInput
                    && modules[$0.fromModule]?.typeID == PatchState.chanceLevelTypeID
            })?.fromModule,
            let level = modules[levelID], let layout = SequencerLayout(typeID: level.typeID) else { return nil }
        return SequenceEditing(state: state, target: .init(slot: target.slot, area: target.area, moduleID: levelID),
                               module: level, layout: layout)
    }

    var body: some View {
        if let chance {
            // MiniValues leaves the label column free itself — the caption goes into it.
            MiniValues(editor: chance, alwaysStrong: true).frame(height: memory.probTall ? 120 : 44)
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prob %").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        TopBarButton(content: .icon("arrow.up.and.down"), isOn: memory.probTall, tint: SeqColor.blue) {
                            memory.probTall.toggle()
                        }
                        .help("Taller faders for the probability row — hold ⇧ while dragging for steps of exactly 1")
                    }
                    .frame(width: labelWidth, alignment: .leading)
                }
                // Its own piece of the playhead, so the column does not run over the Add button below.
                .overlay(alignment: .topLeading) {
                    PlayheadColumn(target: editor.target, length: editor.length).padding(.leading, labelWidth)
                }
        } else if PatchState.chanceOutputs(typeID: editor.module.typeID).count == 1 {
            HStack(spacing: 0) {
                Text("Prob %").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .leading)
                let fits = editor.state.chanceLaneFits(slot: editor.target.slot, area: editor.target.area)
                TopBarButton(content: .text("Add step probability"),
                             isEnabled: editor.target.slot == editor.state.selectedSlot && fits) { add() }
                    .help(fits
                        ? "Adds a SeqLev and a RndTrig (about 2.5 % cycles): the bars set how likely each step plays. One ⌘Z removes them."
                        : "Not enough DSP left in this area: a SeqLev and a RndTrig would push the patch over 100 %.")
                Spacer()
            }
            .frame(height: 44)
        }
    }

    private func add() {
        guard let output = PatchState.chanceOutputs(typeID: editor.module.typeID).first?.output else { return }
        editor.state.addChanceLane(slot: editor.target.slot, area: editor.target.area,
                                   sequencerID: editor.target.moduleID, trigOutput: output, label: "Chance")
    }
}

/// Bars for SeqVal / SeqLev / SeqCtr.
private struct ValueGrid: View {
    let editor: SequenceEditing
    @State private var stroke = Stroke()
    @State private var fine: FineDrag?

    var body: some View {
        let bipolar = editor.layout.isBipolar(in: editor.parameters)
        HStack(spacing: 0) {
            VStack {
                Text(bipolar ? "+63" : "100")
                Spacer()
                Text(bipolar ? "−64" : "0")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: labelWidth, alignment: .leading)

            GeometryReader { geometry in
                Canvas { context, size in
                    let columnWidth = size.width / CGFloat(SequencerLayout.steps)
                    for step in 0 ..< SequencerLayout.steps {
                        let value = CGFloat(editor.values[step]) / 127
                        let x = CGFloat(step) * columnWidth
                        context.fill(Path(CGRect(x: x + 2, y: 0, width: columnWidth - 4, height: size.height)),
                                     with: .color(SeqColor.grid))
                        let base = bipolar ? size.height * (1 - 64.0 / 127) : size.height
                        let top = size.height * (1 - value)
                        let bar = CGRect(x: x + 2, y: min(top, base), width: columnWidth - 4, height: max(4, abs(base - top)))
                        drawCell(context, rect: bar, color: SeqColor.value, strong: editor.gates[step] != 0, radius: 2)
                        if step < editor.length {
                            drawValueLabel(context, text: editor.layout.displayValue(editor.values[step], bipolar: bipolar),
                                           x: x, columnWidth: columnWidth, barTop: min(top, base),
                                           strong: editor.gates[step] != 0)
                        }
                    }
                    if bipolar {
                        let y = size.height * (1 - 64.0 / 127)
                        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y))
                            $0.addLine(to: CGPoint(x: size.width, y: y))
                        },
                        with: .color(.gray.opacity(0.6)), lineWidth: 1)
                    }
                    shadeBeyondLength(context: context, size: size, columnWidth: columnWidth, length: editor.length)
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !stroke.active {
                            stroke.active = true
                            editor.state.beginParameterGesture()
                        }
                        let size = geometry.size
                        let step = Int(drag.location.x / (size.width / CGFloat(SequencerLayout.steps)))
                        guard (0 ..< SequencerLayout.steps).contains(step) else { return }
                        if FineAdjust.isHeld {
                            if fine == nil {
                                fine = FineDrag(step: step, startValue: editor.values[step], startY: drag.location.y)
                            }
                            if let fine {
                                editor.setStep(row: 0, step: fine.step,
                                               value: max(0, min(127, fine.value(at: drag.location.y))))
                            }
                            return
                        }
                        fine = nil
                        let value = Int(((1 - drag.location.y / size.height) * 127).rounded())
                        editor.setStep(row: 0, step: step, value: max(0, min(127, value)))
                    }
                    .onEnded { _ in
                        stroke.active = false
                        fine = nil
                        editor.state.endParameterGesture()
                    })
            }
            .background(SeqColor.field)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SeqColor.fieldBorder, lineWidth: 1))
        }
    }
}

/// One row of on/off steps; dragging paints the value set by the first cell touched.
private struct GateRow: View {
    let editor: SequenceEditing
    let row: Int
    let label: String
    let color: Color
    /// Side of the square step cells. They never stretch with the window — extra height goes
    /// to the value lanes (user's note 2026-11-15: no tall green rectangles).
    var cell: CGFloat = 20
    /// Edit tab: the square is as wide as the bars above it (column width − 4) and the row is as
    /// tall as the square — user's note 2026-11-15.
    var fillColumns = false
    /// All tab: the row is exactly one column tall (the list knows its width). Without it the
    /// height comes from the aspect ratio, which only works when nothing squeezes the row.
    var rowHeight: CGFloat?
    @State private var stroke = Stroke()
    /// Width of the whole row as laid out, to give the squares their height from it (see `exactHeight`).
    @State private var rowWidth: CGFloat = 0

    /// The row's height: given by the caller (All tab), or — with `fillColumns` — one column of the grid
    /// above, measured from the row's own width. An aspect ratio did the same until the window was too
    /// low for it: then the whole row shrank sideways instead of keeping its size (user's screenshot
    /// 2026-11-17).
    private var exactHeight: CGFloat? {
        if let rowHeight { return rowHeight }
        guard fillColumns, rowWidth > labelWidth else { return nil }
        return (rowWidth - labelWidth) / CGFloat(SequencerLayout.steps)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { geometry in
                let gates = editor.layout.row(row, in: editor.parameters)
                Canvas { context, size in
                    let columnWidth = size.width / CGFloat(SequencerLayout.steps)
                    for step in 0 ..< SequencerLayout.steps {
                        let side = fillColumns ? columnWidth - 4 : min(cell, columnWidth - 4)
                        let rect = CGRect(x: CGFloat(step) * columnWidth + (columnWidth - side) / 2,
                                          y: (size.height - side) / 2, width: side, height: side)
                        if gates[step] != 0 {
                            drawCell(context, rect: rect, color: color, strong: true)
                        } else {
                            drawEmptyCell(context, rect: rect)
                        }
                    }
                    shadeBeyondLength(context: context, size: size, columnWidth: columnWidth, length: editor.length)
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let step = Int(drag.location.x / (geometry.size.width / CGFloat(SequencerLayout.steps)))
                        guard (0 ..< SequencerLayout.steps).contains(step) else { return }
                        if !stroke.active {
                            stroke.active = true
                            stroke.gateValue = gates[step] == 0 ? 1 : 0
                            editor.state.beginParameterGesture()
                        }
                        editor.setStep(row: row, step: step, value: stroke.gateValue)
                    }
                    .onEnded { _ in
                        stroke.active = false
                        editor.state.endParameterGesture()
                    })
            }
            .modifier(RowHeight(fillColumns: fillColumns, cell: cell, exact: exactHeight))
        }
        .background(GeometryReader { geometry in
            Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in rowWidth = width }
        })
    }
}

/// Height of a gate row: the squares' side plus a point either way, or one column wide.
private struct RowHeight: ViewModifier {
    let fillColumns: Bool
    let cell: CGFloat
    let exact: CGFloat?

    func body(content: Content) -> some View {
        if let exact {
            content.frame(height: exact)
        } else if fillColumns {
            content.aspectRatio(CGFloat(SequencerLayout.steps), contentMode: .fit)
        } else {
            content.frame(height: cell + 2)
        }
    }
}

// MARK: - All tab

/// Every sequencer of the slot area at once, grouped by the clock behind its Clk input.
/// Rhythm rows and value rows are edited in place; the name opens the module in the Edit
/// tab. Shift, Reverse and Clear act on all ticked lanes as one undo step. The lanes
/// stretch with the window, so dragging the corner makes them taller.
private struct SequenceAllTab: View {
    let state: PatchState
    let slot: Int
    let area: PatchArea
    /// The sequencer the window follows: Add lane works on it while no lane is selected.
    let currentID: Int?
    /// Height the lane list needs, so the window can be fitted to it once.
    let onFit: (WindowFit) -> Void
    let open: (Int) -> Void
    @State private var selected: Set<Int> = []
    /// The lane a ⇧-click counts from (the last one clicked).
    @State private var anchor: Int?
    @State private var viewportHeight: CGFloat = 0
    /// Width of the lane list as laid out — the step squares are as wide as a column of the
    /// bars (user's note 2026-11-15), so lane heights follow the window width.
    @State private var listWidth: CGFloat = 0
    /// Height of the toolbar as laid out: more rows in a narrow window, and the window is fitted to it.
    @State private var toolbarHeight: CGFloat = 0

    /// One line of the lane list: a clock header or a sequencer.
    private enum Row: Hashable {
        case header(Int?, first: Bool)
        case lane(Int)
    }

    var body: some View {
        let patch = state.slots.indices.contains(slot) ? state.slots[slot] : G2Patch()
        let modules = Dictionary(uniqueKeysWithValues: patch.modules(in: area).map { ($0.id, $0) })
        let groups = SequencerClockGroup.groups(in: patch, area: area)
        let rows = rows(of: groups)
        let valueRows = fittedValueRows(rows, modules: modules, column: column)
        let natural = naturalHeight(rows, modules: modules, column: column, valueRows: valueRows)
        let token = laneToken(rows, modules: modules)
        let edges = G2SignalGraph(patch: patch, area: area).edges
        VStack(alignment: .leading, spacing: 8) {
            toolbar(modules: modules, edges: edges)
                .background(GeometryReader { inner in
                    Color.clear.onChange(of: inner.size.height, initial: true) { _, height in toolbarHeight = height }
                })
            GeometryReader { geometry in
                ScrollView {
                    // One flat list: every lane gets the same share of extra height, whatever
                    // group it belongs to.
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows, id: \.self) { row in
                            switch row {
                            case let .header(clock, first):
                                if let group = groups.first(where: { $0.clockModuleID == clock }) {
                                    header(group, modules: modules).padding(.top, first ? 0 : 8)
                                }
                            case let .lane(id):
                                if let module = modules[id], let layout = SequencerLayout(typeID: module.typeID) {
                                    lane(SequenceEditing(state: state, target: .init(slot: slot, area: area, moduleID: id),
                                                         module: module, layout: layout),
                                         targets: targets(of: id, edges: edges, modules: modules),
                                         valueRows: valueRows)
                                }
                            }
                        }
                    }
                    .frame(height: max(geometry.size.height, natural + 6), alignment: .top)
                    .background(GeometryReader { inner in
                        Color.clear.onChange(of: inner.size.width, initial: true) { _, width in
                            listWidth = width
                        }
                    })
                }
                .onChange(of: geometry.size.height, initial: true) { _, height in
                    viewportHeight = height
                    report(natural: natural, token: token)
                }
                .onChange(of: natural) { _, newValue in report(natural: newValue, token: token) }
                .onChange(of: listWidth) { report(natural: natural, token: token) }
                .onChange(of: toolbarHeight) { report(natural: natural, token: token) }
            }
        }
    }

    /// The same four groups as in Edit, acting on the selected lanes — one action on all of them
    /// is one ⌘Z. Copy takes the first selected lane; Paste writes it into every selected one.
    private func toolbar(modules: [Int: G2Module], edges: [G2SignalGraph.Edge]) -> some View {
        @Bindable var memory = SequenceEditorMemory.shared
        let on = !selected.isEmpty
        // Add lane works on the one selected lane, or on the sequencer the window follows while nothing is selected.
        let addTarget = selected.count == 1 ? selected.first : (selected.isEmpty ? currentID : nil)
        let first = selected.sorted().first.flatMap { editor(for: $0, modules: modules) }
        let allLooping = on && selected.allSatisfy { editor(for: $0, modules: modules)?.isLooping == true }
        return SeqWrapLayout(hSpacing: 10, vSpacing: 8) {
            SeqGroup(title: "Lanes") {
                HStack(spacing: 8) {
                    Text(on ? "\(selected.count) selected" : "None selected")
                        .font(.system(size: TopBarMetrics.labelSize)).foregroundStyle(.secondary)
                        .frame(height: TopBarMetrics.controlSide)
                        .help("Click a lane to select it, ⌘-click to add or remove one, ⇧-click to select a range. "
                            + "Double-click a lane to open it in Edit.")
                    addLaneMenu(sequencerID: addTarget, modules: modules, edges: edges)
                }
            }
            SeqGroup(title: "Shift") {
                HStack(spacing: 4) {
                    TopBarButton(content: .icon("arrow.left"), isEnabled: on) { apply(modules) { $0.shift(-1) } }
                        .help("Shift the selected lanes one step left")
                    TopBarButton(content: .icon("arrow.right"), isEnabled: on) { apply(modules) { $0.shift(1) } }
                        .help("Shift the selected lanes one step right")
                    SeqToolButton(icon: "arrow.left.arrow.right", title: "Reverse", isEnabled: on) { apply(modules) { $0.reverse() } }
                    SeqToolButton(icon: "arrow.up.arrow.down", title: "Invert", isEnabled: on) { apply(modules) { $0.invert() } }
                    SeqToolButton(icon: "square.on.square", title: "Double 1–8", isEnabled: on) { apply(modules) { $0.doubleFirstHalf() } }
                }
            }
            SeqGroup(title: "Clipboard") {
                HStack(spacing: 4) {
                    SeqToolButton(icon: "doc.on.doc", title: "Copy", isEnabled: on) { first?.copy() }
                        .help("Copy the first selected lane")
                    SeqToolButton(icon: "doc.on.clipboard", title: "Paste", isEnabled: on && memory.clipboard != nil) {
                        apply(modules) { $0.paste() }
                    }
                    SeqToolButton(icon: "trash", title: "Clear", tint: SeqColor.destructive, isEnabled: on, outline: SeqColor.red) {
                        apply(modules) { $0.clear() }
                    }
                }
            }
            SeqGroup(title: "Generate") {
                HStack(spacing: 4) {
                    SeqToolButton(icon: "dice", title: "Random", tint: SeqColor.generate, isEnabled: on) { apply(modules) { $0.randomize() } }
                        .help("Randomise the selected lanes (locked steps stay)")
                    SeqToolButton(icon: "die.face.4", title: "Random steps", tint: SeqColor.generate, isEnabled: on) {
                        apply(modules) { $0.randomizeSteps() }
                    }
                    SeqNumberControl(title: "Density %", value: memory.density, range: 0 ... 100,
                                     state: state, patchGesture: false) { memory.density = $0 }
                        .padding(.leading, 6)
                    SeqNumberControl(title: "Mutate %", value: memory.mutate, range: 0 ... 100,
                                     state: state, patchGesture: false) { memory.mutate = $0 }
                        .padding(.leading, 6)
                    SeqToolButton(icon: "wand.and.stars", title: "Mutate", tint: SeqColor.generate, isEnabled: on) { apply(modules) { $0.mutate() } }
                        .help("Change a share of the steps of the selected lanes")
                    SeqNumberControl(title: "Human %", value: memory.humanizeAmount, range: 0 ... 100,
                                     state: state, patchGesture: false) { memory.humanizeAmount = $0 }
                        .padding(.leading, 6)
                    SeqToolButton(icon: "hand.draw", title: "Humanize", tint: SeqColor.generate, isEnabled: on) { apply(modules) { $0.humanize() } }
                        .help("Nudge the values of the steps that play in the selected value lanes (SeqVal, SeqLev, "
                            + "SeqCtr); notes and rhythms are left alone")
                }
            }
            SeqGroup(title: "Pattern") {
                HStack(spacing: 4) {
                    SeqNumberControl(title: "Length", value: first?.length ?? 16, range: 1 ... 16, state: state,
                                     isEnabled: on) { length in apply(modules) { $0.setLength(length) } }
                    SeqToolButton(icon: "repeat", title: "Loop", isOn: allLooping, isEnabled: on) {
                        apply(modules) { $0.setLooping(!allLooping) }
                    }
                    .help("Loop, or play once (1-Cycle, used in chains)")
                }
            }
        }
    }

    /// "Add lane": Chance for each trigger output of the sequencer (SeqEvent: both rows) and Accent. The
    /// output that already feeds a RndTrig is marked. Modulation comes later.
    private func addLaneMenu(sequencerID: Int?, modules: [Int: G2Module],
                             edges: [G2SignalGraph.Edge]) -> some View
    {
        let module = sequencerID.flatMap { modules[$0] }
        let outputs = module.map { PatchState.chanceOutputs(typeID: $0.typeID) } ?? []
        let canAdd = slot == state.selectedSlot
        let fits = state.chanceLaneFits(slot: slot, area: area)
        return Menu {
            ForEach(outputs, id: \.output) { item in
                let done = edges.contains { edge in
                    edge.fromModule == sequencerID && edge.fromOutput == item.output
                        && modules[edge.toModule]?.typeID == PatchState.chanceTriggerTypeID
                }
                Button("Chance — \(item.title)\(done ? " (already added)" : "")") {
                    if let sequencerID {
                        state.addChanceLane(slot: slot, area: area, sequencerID: sequencerID,
                                            trigOutput: item.output,
                                            label: outputs.count > 1 ? "Chance \(item.title.suffix(1))" : "Chance")
                    }
                }
                .disabled(done || !canAdd || !fits)
            }
            let accentName = module.map { PatchState.accentLabel(sequencerName: sequencerName($0)) }
            let accentDone = accentName.flatMap { state.accentLaneID(slot: slot, area: area, label: $0) } != nil
            Button("Accent\(accentDone ? " (already added)" : "")") {
                if let accentName, let sequencerID {
                    state.addAccentLane(slot: slot, area: area, sequencerID: sequencerID, label: accentName)
                }
            }
            .disabled(accentDone || !canAdd || !state.accentLaneFits(slot: slot, area: area))
            .help("A SeqLev that walks with this sequencer; its bars are the strength of each step. "
                + "Cable its Val output where you want it (VCA, filter…). Euclid can fill it.")
            Divider()
            Text(fits
                ? "Adds a SeqLev and a RndTrig (about 2.5 % cycles), wired to the same clock. One ⌘Z removes them."
                : "Not enough DSP left in this area for a Chance lane (it would pass 100 %).")
        } label: {
            Label("Add lane", systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(outputs.isEmpty)
        .help(sequencerID == nil
            ? "Click one lane first, then add a lane to it"
            : "Add a lane to the selected sequencer (or to the one the window follows, while none is selected)")
    }

    /// Where the module's output cables go: "Module · Input", the first one and a count of the rest.
    private func targets(of id: Int, edges: [G2SignalGraph.Edge], modules: [Int: G2Module]) -> [String] {
        edges.filter { $0.fromModule == id }.compactMap { edge in
            guard let destination = modules[edge.toModule] else { return nil }
            let def = ModuleDatabase.module(id: destination.typeID)
            let input = def.flatMap { $0.inputs.indices.contains(edge.toInput) ? $0.inputs[edge.toInput].name : nil }
            let label = destination.label.isEmpty ? (def?.shortName ?? "Module") : destination.label
            return input.map { "\(label) · \($0)" } ?? label
        }
    }

    /// Under the lane's name: where its output goes ("→ Note · In2 +1"), or "no cable out".
    private func targetChip(_ targets: [String]) -> some View {
        let text = targets.isEmpty ? "no cable out"
            : (targets.count == 1 ? "→ \(targets[0])" : "→ \(targets[0]) +\(targets.count - 1)")
        return Text(text)
            .font(.system(size: 10))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(targets.isEmpty ? Color.secondary : SeqColor.blue)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(targets.isEmpty ? SeqColor.cardBorder : SeqColor.blue.opacity(0.6)))
            .frame(maxWidth: 130, alignment: .leading)
            .help(targets.joined(separator: "\n"))
    }

    private func editor(for id: Int, modules: [Int: G2Module]) -> SequenceEditing? {
        guard let module = modules[id], let layout = SequencerLayout(typeID: module.typeID) else { return nil }
        return SequenceEditing(state: state, target: .init(slot: slot, area: area, moduleID: id),
                               module: module, layout: layout)
    }

    /// A click on a lane, selected the way files are in the Finder (`SequenceLaneSelection`): a click selects
    /// one, ⌘-click adds or removes one, ⇧-click selects the range from the last lane clicked. A double
    /// click opens the sequencer in Edit, like the pencil button.
    private func tap(_ id: Int) {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            open(id)
            return
        }
        guard state.slots.indices.contains(slot) else { return }
        let order = SequencerClockGroup.groups(in: state.slots[slot], area: area).flatMap(\.sequencerIDs)
        let flags = NSEvent.modifierFlags
        var model = SequenceLaneSelection(selected: selected, anchor: anchor)
        model.click(id, order: order, shift: flags.contains(.shift), command: flags.contains(.command))
        selected = model.selected
        anchor = model.anchor
    }

    private func rows(of groups: [SequencerClockGroup]) -> [Row] {
        groups.enumerated().flatMap { index, group in
            [Row.header(group.clockModuleID, first: index == 0)] + group.sequencerIDs.map(Row.lane)
        }
    }

    // MARK: Sizes

    private static let laneChrome: CGFloat = 17 // vertical padding of a lane frame: 10 above (the length pointer), 7 below
    /// Everything left of the step grid in a lane: frame padding 16, name column 130,
    /// the gap of 8, row label 46.
    private static let beforeGrid: CGFloat = 16 + 130 + 8 + 46
    private static let headerHeight: CGFloat = 29
    /// The bars are at least this many green squares tall (user's note 2026-11-15: 4 was too much).
    private static let valueRows: CGFloat = 3
    private static let minValueRows: CGFloat = 1.5

    /// One step column of the grid: gate squares are as wide as the bars, so a gate row is
    /// exactly this tall.
    private var column: CGFloat {
        listWidth > 0 ? max(12, (listWidth - Self.beforeGrid) / CGFloat(SequencerLayout.steps)) : 30
    }

    private func minLaneHeight(_ kind: SequencerLayout.Kind, column: CGFloat, valueRows: CGFloat) -> CGFloat {
        // The left column (name, target chip, Len/Loop, M/S) is about 104 pt tall.
        let left = Self.laneChrome + 104
        return switch kind {
        case .event: max(left, Self.laneChrome + 2 * column + 2)
        case .note, .value, .controlled: max(left, Self.laneChrome + valueRows * column + 2 + column)
        }
    }

    /// How many squares tall the bars are: three, as the user wanted, but fewer (down to 1.5) when the
    /// lanes would not fit the screen — then all of them show without scrolling (user's note 2026-11-17).
    private func fittedValueRows(_ rows: [Row], modules: [Int: G2Module], column: CGFloat) -> CGFloat {
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let available = screen - 60 - WindowHeightFitter.laneChrome - 6
        var tall = Self.valueRows
        while tall > Self.minValueRows,
              naturalHeight(rows, modules: modules, column: column, valueRows: tall) > available
        {
            tall -= 0.25
        }
        return tall
    }

    /// Height of the list with every lane at its minimum — what the window is fitted to.
    private func naturalHeight(_ rows: [Row], modules: [Int: G2Module], column: CGFloat,
                               valueRows: CGFloat) -> CGFloat
    {
        var total: CGFloat = 0
        for row in rows {
            switch row {
            case let .header(_, first): total += Self.headerHeight + (first ? 0 : 8)
            case let .lane(id):
                let kind = modules[id].flatMap { SequencerLayout(typeID: $0.typeID)?.kind } ?? .event
                total += minLaneHeight(kind, column: column, valueRows: valueRows)
            }
        }
        return total + 8 * CGFloat(max(0, rows.count - 1))
    }

    /// Same lanes in the same order = same token, whatever the window width: the window is fitted
    /// once per set of lanes, and widening it only raises the floor (below), never moves it.
    private func laneToken(_ rows: [Row], modules: [Int: G2Module]) -> Int {
        var hasher = Hasher()
        for row in rows {
            hasher.combine(row)
            if case let .lane(id) = row { hasher.combine(modules[id]?.typeID) }
        }
        return hasher.finalize()
    }

    private func report(natural: CGFloat, token: Int) {
        // Not before the width is known: the lane heights depend on it.
        let ready = viewportHeight > 0 && listWidth > 0 && toolbarHeight > 0
        onFit(WindowFit(delta: ready ? natural + 6 - viewportHeight : nil, token: token, natural: natural,
                        toolbar: toolbarHeight > 0 ? toolbarHeight : WindowHeightFitter.toolbarHeight))
    }

    // MARK: Pieces

    private func header(_ group: SequencerClockGroup, modules: [Int: G2Module]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TopBarButton(content: .text("Select group")) {
                    var model = SequenceLaneSelection()
                    model.select(group.sequencerIDs)
                    selected = model.selected
                    anchor = model.anchor
                }
                Circle().fill(group.clockModuleID == nil ? Color.gray : SeqColor.blue).frame(width: 8, height: 8)
                Text(clockTitle(group, modules: modules)).font(.system(size: 12, weight: .semibold))
                Text("\(group.sequencerIDs.count) sequencer\(group.sequencerIDs.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let clockID = group.clockModuleID, let clock = modules[clockID] {
                    Spacer(minLength: 8)
                    ClockControls(state: state, slot: slot, area: area, module: clock)
                }
            }
            Divider()
        }
    }

    private func lane(_ editor: SequenceEditing, targets: [String], valueRows: CGFloat) -> some View {
        let id = editor.module.id
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    LaneName(text: name(editor.module),
                             dot: laneDotColor(state: state, slot: slot, area: area, id: id))
                    Text(typeName(editor.module))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(width: 130, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { tap(id) }
                .help("Click to select, ⌘-click to add or remove, ⇧-click to select a range, double-click to open in Edit")
                targetChip(targets)
                LengthLoopControls(editor: editor, title: "Len")
                HStack(spacing: 4) {
                    MuteSoloControls(editor: editor, ids: groupIDs(of: id))
                    TopBarButton(content: .icon("pencil")) { open(id) }
                        .help("Open this sequencer in Edit")
                }
            }
            VStack(spacing: 2) {
                switch editor.layout.kind {
                case .event:
                    GateRow(editor: editor, row: 0, label: "Row 1", color: SeqColor.trigger,
                            fillColumns: true, rowHeight: column)
                    GateRow(editor: editor, row: 1, label: "Row 2", color: SeqColor.trigger,
                            fillColumns: true, rowHeight: column)
                case .note, .value, .controlled:
                    MiniValues(editor: editor).frame(minHeight: valueRows * column, maxHeight: .infinity)
                    GateRow(editor: editor, row: 1, label: editor.layout.kind == .note ? "On" : "Trig",
                            color: editor.layout.kind == .note ? SeqColor.on : SeqColor.trigger,
                            fillColumns: true, rowHeight: column)
                }
            }
            .stepOverlay(editor)
        }
        // Each sequencer in its own frame — without it the lanes ran into one block and it
        // was hard to see where one module ends (user's note 2026-11-14).
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 7)
        // Event lanes are only squares — they keep their height, value lanes take the rest.
        .frame(maxWidth: .infinity, maxHeight: editor.layout.kind == .event ? nil : .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected.contains(id) ? SeqColor.blue.opacity(0.12) : SeqColor.card)
                .onTapGesture { tap(id) }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected.contains(id) ? SeqColor.blue.opacity(0.8) : SeqColor.cardBorder,
                              lineWidth: 1)
        )
    }

    /// The sequencers on the same clock as this one — what Solo silences.
    private func groupIDs(of id: Int) -> [Int] {
        guard state.slots.indices.contains(slot) else { return [id] }
        return SequencerClockGroup.groups(in: state.slots[slot], area: area)
            .first { $0.sequencerIDs.contains(id) }?.sequencerIDs ?? [id]
    }

    /// One action on all ticked lanes = one ⌘Z.
    private func apply(_ modules: [Int: G2Module], _ operation: (SequenceEditing) -> Void) {
        state.beginParameterGesture()
        for id in selected.sorted() {
            guard let module = modules[id], let layout = SequencerLayout(typeID: module.typeID) else { continue }
            operation(SequenceEditing(state: state, target: .init(slot: slot, area: area, moduleID: id),
                                      module: module, layout: layout))
        }
        state.endParameterGesture()
    }

    private func clockTitle(_ group: SequencerClockGroup, modules: [Int: G2Module]) -> String {
        guard let id = group.clockModuleID else { return "No clock" }
        guard let clock = modules[id] else { return "Clock" }
        return "Clock: \(name(clock))"
    }

    private func typeName(_ module: G2Module) -> String {
        ModuleDatabase.module(id: module.typeID)?.shortName ?? "Sequencer"
    }

    private func name(_ module: G2Module) -> String {
        module.label.isEmpty ? typeName(module) : module.label
    }
}

/// What the All tab asks of the window: grow or shrink by `delta` (nil until the lane list
/// has been measured), once per `token` — the token changes when the lanes change, so the
/// window is not fitted again while the user stretches it by hand.
private struct WindowFit: Equatable {
    var delta: CGFloat?
    var token: Int
    /// Height the lanes need at the current width.
    var natural: CGFloat
    /// Height of the toolbar as laid out at the current width (it wraps into more rows in a narrow window).
    var toolbar: CGFloat = WindowHeightFitter.toolbarHeight
}

/// Resizes the Sequence Editor window from inside its content. `.lanes`: fits the window to
/// the lane list once per token (up to the screen height); `.normal`: back to the usual
/// minimum so the note grid fits. The top edge stays put.
private struct WindowHeightFitter: NSViewRepresentable {
    enum Mode: Equatable {
        case normal
        case lanes(delta: CGFloat?, token: Int, natural: CGFloat, toolbar: CGFloat)
        /// Content that has a natural height (SeqEvent in Edit): fitted once, then free.
        /// `floor`: the least the window may be dragged to, when lower than the fitted height.
        case fixed(height: CGFloat, floor: CGFloat? = nil)
    }

    let mode: Mode

    final class Coordinator {
        var token: Int?
        var pending = false
        var mode: Mode?
        /// All tab: the least the window may be dragged to — the bar and about one lane; below the
        /// height that shows every lane the list scrolls.
        var laneMinimum: CGFloat = 160
        var observer: NSObjectProtocol?
        var enforcing = false

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Tells the coordinator when the view reaches its window — the first `updateNSView` can
    /// come earlier, and a window reopened at a remembered, wrong height was never fitted.
    final class FitView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = FitView()
        let coordinator = context.coordinator
        view.onWindow = { window in
            Self.enforceFloor(on: window, coordinator: coordinator)
            Task { @MainActor in
                guard let mode = coordinator.mode else { return }
                Self.apply(mode, to: window, coordinator: coordinator)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let mode = mode
        let coordinator = context.coordinator
        coordinator.mode = mode
        Task { @MainActor in
            guard let window = view.window else { return }
            Self.apply(mode, to: window, coordinator: coordinator)
        }
    }

    /// Backstop for the floor: whatever resizes the window (the corner drag included), a window
    /// smaller than `minimumContentHeight` is put back — SwiftUI's hosting controller keeps
    /// resetting `contentMinSize`, and the delegate alone did not hold.
    private static func enforceFloor(on window: NSWindow, coordinator: Coordinator) {
        guard coordinator.observer == nil else { return }
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak window, weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let window, let coordinator, !coordinator.enforcing,
                      let floor = (window as? FloatingPanel)?.minimumContentHeight else { return }
                let content = window.contentRect(forFrameRect: window.frame)
                guard content.height < floor - 0.5 else { return }
                coordinator.enforcing = true
                var frame = window.frameRect(forContentRect: NSRect(
                    origin: content.origin, size: NSSize(width: content.width, height: floor)
                ))
                frame.origin.y = window.frame.maxY - frame.height
                window.setFrame(frame, display: true)
                coordinator.enforcing = false
            }
        }
    }

    /// Window content around the lane list in the All tab: panel padding 2 × 12, header and toolbar
    /// rows (one control tall each) and the two 8 pt gaps between them and the list.
    /// The grouped toolbar is two rows of caption + control at the usual window width; each group box
    /// adds its 4 pt padding top and bottom and the 4 pt gap under the caption (they were missing, and the
    /// last lane was cut — user's screenshot 2026-11-17).
    static let toolbarHeight: CGFloat = 2 * (15 + 4 + TopBarMetrics.controlSide + 8) + 8
    static let laneChrome: CGFloat = chrome(toolbar: toolbarHeight)

    /// Everything around the lane list: panel padding, the gaps, the header row and the toolbar as measured.
    static func chrome(toolbar: CGFloat) -> CGFloat {
        24 + 16 + TopBarMetrics.controlSide + toolbar
    }

    private static func apply(_ mode: Mode, to window: NSWindow, coordinator: Coordinator) {
        let normal = PanelController.Panel.sequenceEditor.minWindowSize ?? CGSize(width: 720, height: 460)
        enforceFloor(on: window, coordinator: coordinator)
        let content = window.contentRect(forFrameRect: window.frame)
        // Hard floor for dragging the window smaller — see `WindowDelegate.windowWillResize`.
        (window as? FloatingPanel)?.minimumContentHeight = switch mode {
        case .normal: normal.height
        case let .fixed(wanted, floor): floor ?? wanted
        case .lanes: coordinator.laneMinimum
        }
        let height: CGFloat
        switch mode {
        case .normal:
            coordinator.token = nil
            window.contentMinSize = normal
            guard content.height < normal.height else { return }
            height = normal.height
        case let .fixed(wanted, floor):
            // The natural height is also the least the content needs: no clipped rings or rows.
            window.contentMinSize = NSSize(width: normal.width, height: floor ?? wanted)
            guard coordinator.token != Int(wanted) else { return }
            coordinator.token = Int(wanted)
            height = wanted
        case let .lanes(delta, token, natural, toolbar):
            let chrome = Self.chrome(toolbar: toolbar)
            window.contentMinSize = NSSize(width: normal.width, height: 160)
            let screen = (window.screen?.visibleFrame.height ?? 900) - 60
            if coordinator.token != token {
                coordinator.token = token
                coordinator.pending = true
            }
            // Height the lanes need = the list at its minimum + the part of the window around it
            // (padding, header, toolbar). That part is a layout constant, NOT read from the
            // viewport: readings taken while the window was moving gave a wrong figure, and the
            // floor stuck at the screen height (user's screenshot 2026-11-15, window could not be
            // made even slightly lower). It follows the lanes as they grow with the window width.
            let needed = min(max(natural + 6 + chrome, 160), screen)
            // The window opens at `needed`, but may be dragged lower: the lane list scrolls (user's note
            // 2026-11-17). The floor keeps the bar and about one lane in view.
            let floor = min(needed, chrome + 160)
            coordinator.laneMinimum = floor
            (window as? FloatingPanel)?.minimumContentHeight = floor
            // Fit once per set of lanes, as soon as the list has been measured (`delta` is nil
            // until it has a width), then the user can stretch the window.
            guard coordinator.pending, delta != nil else { return }
            coordinator.pending = false
            height = needed
        }
        guard abs(height - content.height) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(
            origin: content.origin, size: NSSize(width: content.width, height: height)
        ))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true)
    }
}

/// Value row of a lane (note positions on SeqNote, bars elsewhere) — drawn and edited in
/// place: click or drag across steps. The note range is frozen while a stroke is drawn, so
/// the picture does not jump under the mouse.
private struct MiniValues: View {
    let editor: SequenceEditing
    /// Draw every bar in the full colour — for a row whose gates mean nothing (Prob %).
    var alwaysStrong = false
    @State private var stroke = Stroke()
    @State private var fine: FineDrag?
    @State private var frozenRange: ClosedRange<Int>?

    /// Notes: a little above and below what is played; values: the whole range.
    private var liveRange: ClosedRange<Int> {
        guard editor.layout.kind == .note else { return 0 ... 127 }
        let played = editor.values.prefix(editor.length)
        let low = max(0, (played.min() ?? 0) - 2)
        let high = min(127, (played.max() ?? 127) + 2)
        return low ... max(low + 1, high)
    }

    var body: some View {
        let range = frozenRange ?? liveRange
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth)
            GeometryReader { geometry in
                Canvas { context, size in
                    draw(context: context, size: size, range: range)
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !stroke.active {
                            stroke.active = true
                            frozenRange = liveRange
                            editor.state.beginParameterGesture()
                        }
                        if FineAdjust.isHeld {
                            let step = Int(drag.location.x / (geometry.size.width / CGFloat(SequencerLayout.steps)))
                            if fine == nil, (0 ..< SequencerLayout.steps).contains(step) {
                                fine = FineDrag(step: step, startValue: editor.values[step], startY: drag.location.y)
                            }
                            if let fine {
                                editor.setStep(row: 0, step: fine.step,
                                               value: max(0, min(127, fine.value(at: drag.location.y))))
                            }
                            return
                        }
                        fine = nil
                        edit(at: drag.location, size: geometry.size, range: frozenRange ?? range)
                    }
                    .onEnded { _ in
                        stroke.active = false
                        fine = nil
                        frozenRange = nil
                        editor.state.endParameterGesture()
                    })
            }
        }
    }

    private func edit(at point: CGPoint, size: CGSize, range: ClosedRange<Int>) {
        let step = Int(point.x / (size.width / CGFloat(SequencerLayout.steps)))
        guard (0 ..< SequencerLayout.steps).contains(step), size.height > 0 else { return }
        let level = max(0, min(1, 1 - point.y / size.height))
        var value = range.lowerBound + Int((level * CGFloat(range.upperBound - range.lowerBound)).rounded())
        let memory = SequenceEditorMemory.shared
        if editor.layout.kind == .note, memory.snapDrawing, memory.scale != .chromatic {
            value = memory.scale.snapped(value, root: memory.root)
        }
        editor.setStep(row: 0, step: step, value: max(0, min(127, value)))
    }

    private func draw(context: GraphicsContext, size: CGSize, range: ClosedRange<Int>) {
        let values = editor.values
        let span = CGFloat(max(1, range.upperBound - range.lowerBound))
        let columnWidth = size.width / CGFloat(SequencerLayout.steps)
        for step in 0 ..< SequencerLayout.steps {
            let x = CGFloat(step) * columnWidth
            context.fill(Path(CGRect(x: x + 2, y: 0, width: columnWidth - 4, height: size.height)),
                         with: .color(SeqColor.grid))
            let level = max(0, min(1, CGFloat(values[step] - range.lowerBound) / span))
            let y = size.height * (1 - level)
            let strong = alwaysStrong || editor.gates[step] != 0
            if editor.layout.kind == .note {
                drawCell(context, rect: CGRect(x: x + 2, y: min(size.height - 5, max(0, y - 2.5)),
                                               width: columnWidth - 4, height: 5),
                         color: SeqColor.on, strong: strong, radius: 1.5)
                // The note's name next to its bar (above it, or below near the top), so a lane can be
                // read without opening Edit.
                if columnWidth >= 20, step < editor.length {
                    let cellY = min(size.height - 5, max(0, y - 2.5))
                    context.draw(Text(NoteName.name(values[step]))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(strong ? SeqColor.noteLabelStrong : SeqColor.noteLabelWeak),
                        at: CGPoint(x: x + columnWidth / 2, y: cellY >= 11 ? cellY - 6 : cellY + 11), anchor: .center)
                }
            } else {
                drawCell(context, rect: CGRect(x: x + 2, y: min(y, size.height - 4), width: columnWidth - 4,
                                               height: max(4, size.height - y)),
                         color: SeqColor.value, strong: strong, radius: 2)
                if step < editor.length {
                    drawValueLabel(context,
                                   text: editor.layout.displayValue(values[step],
                                                                    bipolar: editor.layout.isBipolar(in: editor.parameters)),
                                   x: x, columnWidth: columnWidth, barTop: min(y, size.height - 4), strong: strong)
                }
            }
        }
        shadeBeyondLength(context: context, size: size, columnWidth: columnWidth, length: editor.length)
    }
}

/// The clock's own settings in the header of a group of sequencers: Tempo and Swing (as the module
/// shows them) and its On/Off. Only for a ClkGen; with Source = Master the tempo is the patch's.
private struct ClockControls: View {
    let state: PatchState
    let slot: Int
    let area: PatchArea
    let module: G2Module

    var body: some View {
        if module.typeID == ClockGenSettings.typeID, module.parameters.count > ClockGenSettings.swing {
            let values = module.parameters
            HStack(spacing: 8) {
                if values[ClockGenSettings.source] == 0 {
                    SeqNumberControl(title: "Tempo", value: values[ClockGenSettings.rate], range: 0 ... 127,
                                     state: state, display: bpmText, valueWidth: 36)
                    {
                        write(ClockGenSettings.rate, $0)
                    }
                } else {
                    Text("Master clock").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                SeqNumberControl(title: "Swing", value: values[ClockGenSettings.swing], range: 0 ... 127,
                                 state: state, display: ClockGenSettings.swingText, valueWidth: 48)
                {
                    write(ClockGenSettings.swing, $0)
                }
                TopBarButton(content: .text("On"), isOn: values[ClockGenSettings.active] != 0, tint: SeqColor.blue) {
                    write(ClockGenSettings.active, values[ClockGenSettings.active] != 0 ? 0 : 1)
                }
                .help("Clock on / off")
            }
        }
    }

    private func bpmText(_ value: Int) -> String {
        "\(ClockGenSettings.bpm(forRate: value))"
    }

    private func write(_ index: Int, _ value: Int) {
        state.setParameter(slot: slot, moduleID: module.id, paramIndex: index, value: value, area: area)
    }
}

/// M and S of a lane in the All tab.
private struct MuteSoloControls: View {
    let editor: SequenceEditing
    let ids: [Int]
    private var memory: SequenceEditorMemory {
        SequenceEditorMemory.shared
    }

    var body: some View {
        HStack(spacing: 4) {
            TopBarButton(content: .text("M"), isOn: memory.muted.contains(editor.target), tint: SeqColor.orange) {
                toggle(\.muted)
            }
            .help("Mute: silences this lane's steps. The steps come back when you unmute — save the patch while muted and they are gone from the file.")
            TopBarButton(content: .text("S"), isOn: memory.soloed.contains(editor.target), tint: SeqColor.yellow) {
                toggle(\.soloed)
            }
            .help("Solo: silences the other lanes of this clock until you switch Solo off")
        }
    }

    /// Works on a copy: `refresh` reads the same sets, so passing them in-out was a simultaneous
    /// access and crashed (user's Xcode screenshot 2026-11-16).
    private func toggle(_ keyPath: ReferenceWritableKeyPath<SequenceEditorMemory, Set<SequenceTarget>>) {
        var set = memory[keyPath: keyPath]
        if set.contains(editor.target) { set.remove(editor.target) } else { set.insert(editor.target) }
        memory[keyPath: keyPath] = set
        SequenceMixer.refresh(state: editor.state, slot: editor.target.slot, area: editor.target.area, ids: ids)
    }
}

/// Length and Loop of one sequencer, for the lane cards of the All tab (Edit has its own
/// toolbar). Loop on = the pattern repeats; off = it plays once (1-Cycle, used in chains).
private struct LengthLoopControls: View {
    let editor: SequenceEditing
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            if editor.layout.lengthIndex != nil {
                SeqNumberControl(title: title, value: editor.length, range: 1 ... 16, state: editor.state) {
                    editor.setLength($0)
                }
            }
            if editor.layout.loopIndex != nil {
                SeqToolButton(icon: "repeat", title: "Loop", isOn: editor.isLooping) {
                    editor.setLooping(!editor.isLooping)
                }
                .help("Loop, or play once (1-Cycle, used in chains)")
            }
        }
    }
}

/// Where a jack's cable leads: text for the label and the module on the other end.
private struct JackLink {
    let text: String
    let moduleID: Int
}

private struct JackLabel: View {
    let title: String
    let link: JackLink?
    let help: String
    let select: (Int) -> Void
    @State private var hovering = false

    var body: some View {
        let label = HStack(spacing: 4) {
            Circle().fill(link == nil ? SeqColor.cardBorder : SeqColor.blue).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10, weight: .medium))
            if let link {
                Text(link.text).font(.system(size: 10)).lineLimit(1).underline(hovering)
            }
        }
        .foregroundStyle(link == nil ? Color.secondary : SeqColor.blue)
        if let link {
            Button { select(link.moduleID) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                .help("\(help) — from/to \(link.text). Click to select that module on the patch.")
        } else {
            label.help("\(help) — not connected. Connect a cable to this jack on the patch.")
        }
    }
}

// MARK: - Playhead

/// Red outline around the step the module is playing now, over one column of a step grid. The
/// step comes from the same LED-group stream that lights the sequencer on the canvas (value
/// 0…15 = step; 16 or more = parked), so it shows only with a G2 (or the virtual one)
/// connected and this slot being the one streamed. Reads the stream in this small view only,
/// so the rest of the window does not redraw with every packet.
private struct PlayheadColumn: View {
    let target: SequenceTarget
    let length: Int

    var body: some View {
        GeometryReader { geometry in
            if let step = playingStep {
                let column = geometry.size.width / CGFloat(SequencerLayout.steps)
                RoundedRectangle(cornerRadius: 4)
                    .fill(SeqColor.ice.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SeqColor.ice, lineWidth: 2))
                    .frame(width: column, height: geometry.size.height)
                    .offset(x: CGFloat(step) * column)
            }
        }
        .allowsHitTesting(false)
    }

    private var playingStep: Int? {
        SequencePlayhead.step(of: target, length: length)
    }
}

/// The step a sequencer is playing now, from the LED-group stream; nil when nothing streams.
private enum SequencePlayhead {
    @MainActor
    static func step(of target: SequenceTarget, length: Int) -> Int? {
        guard let device = SequenceEditorMemory.shared.device, device.status == .connected,
              device.meterSlot == target.slot,
              let reading = device.ledGroups.first(where: { $0.area == target.area && $0.moduleID == target.moduleID }),
              (0 ..< min(length, SequencerLayout.steps)).contains(reading.value) else { return nil }
        return reading.value
    }
}

/// Everything drawn over a sequencer's step grids on top of the steps: the playhead and, on modules that have
/// a Length, a vertical line at the end of the played steps that can be dragged left or right
/// to change it (user's idea 2026-11-15). One drag = one ⌘Z.
private extension View {
    /// One playhead and one length line across all the grids of a sequencer (not one per row);
    /// `labelWidth` is the label column to the left of every grid.
    func stepOverlay(_ editor: SequenceEditing) -> some View {
        overlay(alignment: .topLeading) { StepOverlay(editor: editor).padding(.leading, labelWidth) }
    }
}

private extension View {
    /// Tells the status bar which step the pointer is over (Edit tab).
    func stepHover() -> some View {
        modifier(StepHover())
    }
}

private struct StepHover: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { width = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, new in width = new }
            })
            .onContinuousHover { phase in
                let memory = SequenceEditorMemory.shared
                switch phase {
                case let .active(point):
                    let column = (width - labelWidth) / CGFloat(SequencerLayout.steps)
                    let step = column > 0 ? Int(((point.x - labelWidth) / column).rounded(.down)) : -1
                    let next = (0 ..< SequencerLayout.steps).contains(step) ? step : nil
                    if memory.hoverStep != next { memory.hoverStep = next }
                case .ended:
                    memory.hoverStep = nil
                }
            }
    }
}

/// Bottom line of the Edit tab: the step under the pointer, or the one playing now.
private struct StepStatusBar: View {
    let editor: SequenceEditing

    var body: some View {
        let hover = SequenceEditorMemory.shared.hoverStep
        let playing = SequencePlayhead.step(of: editor.target, length: editor.length)
        HStack(spacing: 14) {
            // Fixed width, so the hint on the right stays put while the readout changes length.
            HStack(spacing: 14) {
                if let step = hover ?? playing {
                    HStack(spacing: 6) {
                        Circle().fill(hover != nil ? SeqColor.blue : SeqColor.ice).frame(width: 7, height: 7)
                        Text(hover != nil ? "Step" : "Playing step").foregroundStyle(.secondary)
                        Text("\(step + 1)").fontWeight(.semibold)
                    }
                    ForEach(fields(step), id: \.0) { title, value in
                        HStack(spacing: 4) {
                            Text(title).foregroundStyle(.secondary)
                            Text(value).fontWeight(.semibold)
                        }
                    }
                } else {
                    Text("Hover a step to read it").foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(width: 290, alignment: .leading)
            Text("Click or drag across steps to draw · locked steps keep their value in Clear, Random and Paste · one action = one ⌘Z")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
        .font(.system(size: 11).monospacedDigit())
    }

    private func fields(_ step: Int) -> [(String, String)] {
        let layout = editor.layout
        func onOff(_ row: Int) -> String {
            layout.row(row, in: editor.parameters)[step] != 0 ? "on" : "off"
        }
        switch layout.kind {
        case .event:
            return [("Row 1", onOff(0)), ("Row 2", onOff(1))]
        case .note:
            let note = editor.values[step]
            return [("Value", "\(note)"), ("Note", NoteName.name(note)), ("Gate", onOff(1))]
        case .value, .controlled:
            let bipolar = layout.isBipolar(in: editor.parameters)
            return [("Value", layout.displayValue(editor.values[step], bipolar: bipolar)), ("Gate", onOff(1))]
        }
    }
}

private struct StepOverlay: View {
    let editor: SequenceEditing
    @State private var dragging = false
    @State private var hovering = false
    private static let space = "seqLengthSpace"

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlayheadColumn(target: editor.target, length: editor.length)
            if editor.layout.lengthIndex != nil { lengthHandle }
        }
    }

    /// An invisible area that grabs the length line. `position`, not `offset`: an offset view keeps
    /// its hit area where it was laid out (the left edge, next to step 1), so a click there
    /// shortened the sequence to one step (user's note 2026-11-17). The gesture sits on the view
    /// before it is moved.
    private func grabZone(width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat, column: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                // An open hand over the handle, a closed one while it is dragged.
                if inside { (dragging ? NSCursor.closedHand : NSCursor.openHand).set() } else { NSCursor.arrow.set() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { drag in
                    if !dragging {
                        dragging = true
                        editor.state.beginParameterGesture()
                    }
                    NSCursor.closedHand.set()
                    let steps = max(1, min(SequencerLayout.steps, Int((drag.location.x / column).rounded())))
                    if steps != editor.length { editor.setLength(steps) }
                }
                .onEnded { _ in
                    dragging = false
                    (hovering ? NSCursor.openHand : NSCursor.arrow).set()
                    editor.state.endParameterGesture()
                })
            .help("Drag to change the length")
            .position(x: x, y: y)
    }

    private var lengthHandle: some View {
        GeometryReader { geometry in
            let column = geometry.size.width / CGFloat(SequencerLayout.steps)
            let edge = CGFloat(editor.length) * column
            // Two hit zones: a wide one only ABOVE the bars, around the pointer (nothing to cover
            // there), and a narrow strip along the line — at length 16 the line is the right edge
            // and a wide strip covered the last fader (user's screenshot 2026-11-17).
            let strip: CGFloat = 10
            let top: CGFloat = 26
            let above: CGFloat = 14
            let stripX = min(max(edge, strip / 2), geometry.size.width - strip / 2)
            let topX = min(max(edge, top / 2), geometry.size.width - top / 2)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(SeqColor.handle.opacity(hovering || dragging ? 0.38 : 0.18))
                    .frame(width: strip, height: geometry.size.height)
                    .offset(x: stripX - strip / 2)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(SeqColor.handle)
                    .frame(width: 3, height: geometry.size.height)
                    .offset(x: edge - 1.5)
                    .allowsHitTesting(false)
                // Pointer centred over the line, in the gap above the squares (user's note
                // 2026-11-15): 7 pt high, tip on the top of the line.
                Path { path in
                    path.move(to: CGPoint(x: edge - 5, y: -7))
                    path.addLine(to: CGPoint(x: edge + 5, y: -7))
                    path.addLine(to: CGPoint(x: edge, y: 0))
                    path.closeSubpath()
                }
                .fill(SeqColor.handle)
                .allowsHitTesting(false)
                grabZone(width: strip, height: geometry.size.height, x: stripX, y: geometry.size.height / 2,
                         column: column)
                grabZone(width: top, height: above, x: topX, y: -above / 2, column: column)
            }
        }
        .coordinateSpace(name: Self.space)
    }
}

// MARK: - Number control in the top-bar style

/// Caption, value box and ▲▼ arrows — the same controls as Master Clock on the top bar,
/// so the window looks like the rest of the editor. Drag the value up/down or hold an
/// arrow; a whole drag is one ⌘Z.
struct SeqNumberControl: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let state: PatchState
    var isEnabled = true
    /// False for window-only settings (Density, Mutate %): they never touch the patch, so a
    /// drag is not an undo step.
    var patchGesture = true
    /// How the value is written (Tempo in BPM…); `nil` = the number itself.
    var display: ((Int) -> String)?
    var valueWidth: CGFloat = 30
    let set: (Int) -> Void
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            TopBarValueField(text: display?(value) ?? "\(value)", width: valueWidth, isEnabled: isEnabled)
                .topBarDragAdjust(value: value, range: range, pointsPerStep: 6, isEnabled: isEnabled,
                                  onChange: { next in
                                      if !dragging {
                                          dragging = true
                                          if patchGesture { state.beginParameterGesture() }
                                      }
                                      set(next)
                                  },
                                  onEnd: {
                                      dragging = false
                                      if patchGesture { state.endParameterGesture() }
                                  })
            TopBarStepper(canIncrement: isEnabled && value < range.upperBound,
                          canDecrement: isEnabled && value > range.lowerBound,
                          onIncrement: { set(value + 1) },
                          onDecrement: { set(value - 1) })
        }
    }
}

// MARK: - Drawing helpers

/// The step's value as a number on its bar, as on the module (SeqVal: +9, −64…). Above the bar, or
/// inside it when the bar reaches the top; skipped when the column is too narrow to read.
private func drawValueLabel(_ context: GraphicsContext, text: String, x: CGFloat, columnWidth: CGFloat,
                            barTop: CGFloat, strong: Bool)
{
    guard columnWidth >= 20 else { return }
    context.draw(Text(text).font(.system(size: 8, design: .monospaced))
        .foregroundStyle(strong ? SeqColor.labelStrong : SeqColor.labelWeak),
        at: CGPoint(x: x + columnWidth / 2, y: barTop >= 11 ? barTop - 6 : barTop + 8), anchor: .center)
}

/// Steps after Length are not played — darken them.
private func shadeBeyondLength(context: GraphicsContext, size: CGSize, columnWidth: CGFloat, length: Int) {
    guard length < SequencerLayout.steps else { return }
    let x = CGFloat(length) * columnWidth
    context.fill(Path(CGRect(x: x, y: 0, width: size.width - x, height: size.height)), with: .color(SeqColor.muted))
}

private func drawBeatLines(context: GraphicsContext, size: CGSize, columnWidth: CGFloat) {
    for beat in stride(from: 4, to: SequencerLayout.steps, by: 4) {
        let x = CGFloat(beat) * columnWidth
        context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0))
            $0.addLine(to: CGPoint(x: x, y: size.height))
        },
        with: .color(.gray.opacity(0.35)), lineWidth: 1)
    }
}

// MARK: - Euclid tab

/// Euclid for every sequencer on the clock of the one being edited (like All): one card each, its
/// rings and controls inside. A lone sequencer fills the window as before; with several the rings
/// shrink (down to `minRing`) and the list scrolls.
private struct SequenceEuclidTab: View {
    let state: PatchState
    let target: SequenceTarget

    static let minRing: CGFloat = 100
    /// Smallest ring when several sequencers share the window.
    static let minRingMany: CGFloat = 72

    /// Rows that take a rhythm: both rows of SeqEvent, the trigger row elsewhere.
    private static func rows(of editor: SequenceEditing) -> [(row: Int, name: String)] {
        switch editor.layout.kind {
        case .event: [(0, "Row 1"), (1, "Row 2")]
        case .note: [(1, "Step on/off")]
        case .value, .controlled: [(1, "Trigger row")]
        }
    }

    /// The sequencers of the clock group, in the order of All.
    private var editors: [SequenceEditing] {
        guard state.slots.indices.contains(target.slot) else { return [] }
        let patch = state.slots[target.slot]
        let modules = Dictionary(uniqueKeysWithValues: patch.modules(in: target.area).map { ($0.id, $0) })
        let ids = SequencerClockGroup.groups(in: patch, area: target.area)
            .first { $0.sequencerIDs.contains(target.moduleID) }?.sequencerIDs ?? [target.moduleID]
        return ids.compactMap { id in
            guard let module = modules[id], let layout = SequencerLayout(typeID: module.typeID) else { return nil }
            return SequenceEditing(state: state, target: .init(slot: target.slot, area: target.area, moduleID: id),
                                   module: module, layout: layout)
        }
    }

    var body: some View {
        let list = editors
        let total = list.reduce(0) { $0 + Self.rows(of: $1).count }
        VStack(alignment: .leading, spacing: 10) {
            if list.count == 1, let editor = list.first {
                // The rings take the height the window gives them (100 pt at least).
                let rows = Self.rows(of: editor)
                GeometryReader { geometry in
                    let gaps = 10 * CGFloat(rows.count - 1)
                    let ring = min(max(Self.minRing, (geometry.size.height - gaps) / CGFloat(rows.count)), 340)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows, id: \.row) { item in
                            EuclidRowEditor(editor: editor, row: item.row, name: item.name, ringSize: ring)
                        }
                    }
                }
                .frame(minHeight: Self.minRing * CGFloat(rows.count) + 10 * CGFloat(rows.count - 1))
                if editor.layout.kind == .event { combined(for: editor) }
            } else {
                polyrhythmBar(list)
                GeometryReader { geometry in
                    // Per card: name line (about 30 pt) and padding; per row: the gap between rows.
                    let overhead = CGFloat(list.count) * 44 + 10 * CGFloat(total)
                    let ring = min(max(Self.minRingMany, (geometry.size.height - overhead) / CGFloat(max(1, total))), 200)
                    ScrollView(.vertical) {
                        VStack(spacing: 8) {
                            ForEach(list, id: \.module.id) { editor in card(editor, ring: ring) }
                        }
                    }
                }
            }
            Text("Writes only step on/off and Length — the patch stays a normal patch. Click a dot to toggle one step.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private enum GroupMode: String, CaseIterable, Identifiable {
        case same = "Same on all"
        case canon = "Canon"
        case spread = "Spread"
        case interlock = "Interlock"
        var id: String { rawValue }
    }

    @State private var groupHits = 5
    @State private var groupOffset = 2
    @State private var groupMode: GroupMode = .spread

    /// Length sets (longest first) for the Lengths menu. Coprime lengths never share a divisor, so the
    /// whole pattern takes long to come round; ratios (4:3:2) come round soon; phasing (16, 15, 14…)
    /// drifts slowly apart; halves nest inside each other.
    static let coprimeLengths = [16, 15, 13, 11, 7, 5, 3]
    static let ratioLengths = [16, 12, 8, 4, 2]
    static let phasingLengths = [16, 15, 14, 13, 12, 11, 10]
    static let halvesLengths = [16, 8, 4, 2]
    static let repeatTargets = [32, 48, 60, 96, 120]

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return a / x * b
    }

    /// After how many steps every sequencer of the group is back at its first step.
    private func repeatLength(_ list: [SequenceEditing]) -> Int {
        list.reduce(1) { Self.lcm($0, $1.layout.lengthIndex == nil ? SequencerLayout.steps : $1.length) }
    }

    /// The sequencers the group actions work on: those whose box on the card is ticked.
    private func participants(_ list: [SequenceEditing]) -> [SequenceEditing] {
        list.filter { !SequenceEditorMemory.shared.groupOut.contains($0.target) }
    }

    private func polyrhythmBar(_ list: [SequenceEditing]) -> some View {
        let repeats = repeatLength(list)
        let chosen = participants(list)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Menu("Lengths") {
                    Button("Coprime (16, 15, 13, 11…)") { setLengths(chosen, from: Self.coprimeLengths) }
                    Button("Ratio 4:3:2 (16, 12, 8, 4…)") { setLengths(chosen, from: Self.ratioLengths) }
                    Button("Phasing (16, 15, 14, 13…)") { setLengths(chosen, from: Self.phasingLengths) }
                    Button("Halves (16, 8, 4, 2)") { setLengths(chosen, from: Self.halvesLengths) }
                    Divider()
                    ForEach(Self.repeatTargets, id: \.self) { target in
                        Button("Repeat after \(target) steps") { setLengths(chosen, forRepeat: target) }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Give the ticked sequencers their own lengths so the rhythms drift against each other. "
                    + "Hits are kept in proportion. One ⌘Z undoes it.")
                Text("Pattern repeats after \(repeats) steps")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(repeats > 64 ? SeqColor.on : .secondary)
                    .help("When all sequencers of this clock are back at step 1 together (at the same clock speed)")
                Spacer()
                Text("\(chosen.count) of \(list.count) ticked")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("The box on each card: left unticked, a sequencer is not touched by Lengths and Group Euclid")
            }
            HStack(spacing: 8) {
                Text("Group Euclid").font(.system(size: 13, weight: .semibold))
                Picker("Mode", selection: $groupMode) {
                    ForEach(GroupMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                .help("Same on all: the same rhythm on every ticked sequencer. Canon: each next one shifted by Offset. "
                    + "Spread: one rhythm shared out — hit 1 to the first, hit 2 to the second… "
                    + "Interlock: the first plays the rhythm, the others fill its gaps.")
                SeqNumberControl(title: "Hits", value: groupHits, range: 0 ... 16, state: state, patchGesture: false) {
                    groupHits = $0
                }
                SeqNumberControl(title: "Offset", value: groupOffset, range: 0 ... 15, state: state, patchGesture: false) {
                    groupOffset = $0
                }
                .help(groupMode == .spread ? "Rotate the shared rhythm"
                    : groupMode == .interlock ? "Rotate the rhythm of the first sequencer"
                    : "Canon: shift of each next sequencer")
                .disabled(groupMode == .same)
                TopBarButton(content: .text("Apply")) { applyGroupEuclid(chosen) }
                    .help("Write the rhythm into the ticked sequencers (their own Steps stay). One ⌘Z.")
                Menu("Kit") {
                    ForEach(EuclidKit.all) { kit in
                        Button("\(kit.name) — \(kit.summary)") { applyKit(kit, chosen) }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .help("A ready set of rhythms for the ticked sequencers, in the order of the cards: part 1 to the first "
                    + "row, part 2 to the next… (a SeqEvent takes two). Sets their Steps too. One ⌘Z.")
                SeqToolButton(icon: "dice", title: "Random", tint: SeqColor.generate) { applyRandomGroup(chosen) }
                    .help("A new Euclidean rhythm for every ticked row: the share of steps that play rises from the first "
                        + "(sparse, a kick) to the last (busy, a hat), and the second row never plays with the first. "
                        + "Their own Steps stay. One ⌘Z.")
                Spacer()
            }
            meetingPoints(chosen)
        }
    }

    private func setLengths(_ chosen: [SequenceEditing], from pool: [Int]) {
        applyLengths(chosen, (0 ..< chosen.count).map { pool[min($0, pool.count - 1)] })
    }

    /// Lengths that divide `target`, longest first: the whole group comes round within `target` steps.
    private func setLengths(_ chosen: [SequenceEditing], forRepeat target: Int) {
        let divisors = (2 ... 16).filter { target % $0 == 0 }.sorted(by: >)
        setLengths(chosen, from: divisors.isEmpty ? Self.coprimeLengths : divisors)
    }

    /// Gives each sequencer with a Length one of `lengths` (in order), keeping about the same share of
    /// hits. The others stay as they are.
    private func applyLengths(_ chosen: [SequenceEditing], _ lengths: [Int]) {
        let adjustable = chosen.filter { $0.layout.lengthIndex != nil }
        guard adjustable.count > 1 else { return }
        state.beginParameterGesture()
        defer { state.endParameterGesture() }
        for (position, editor) in adjustable.enumerated() {
            guard let lengthIndex = editor.layout.lengthIndex else { continue }
            let newSteps = lengths[min(position, lengths.count - 1)]
            let oldSteps = max(1, editor.length)
            var all: [Int: Int] = [lengthIndex: newSteps - 1]
            for item in Self.rows(of: editor) {
                let current = editor.layout.row(item.row, in: editor.parameters).prefix(oldSteps)
                let hits = current.filter { $0 != 0 }.count
                let scaled = min(newSteps, max(hits > 0 ? 1 : 0, Int((Double(hits) * Double(newSteps) / Double(oldSteps)).rounded())))
                let pattern = EuclideanRhythm.pattern(hits: scaled, steps: newSteps, rotation: 0).map { $0 ? 1 : 0 }
                let padded = pattern + Array(repeating: 0, count: SequencerLayout.steps - pattern.count)
                all.merge(editor.changes(row: item.row, padded)) { $1 }
            }
            editor.write(all)
        }
    }

    /// A row of the group: the sequencer, which row of it, and the steps it plays.
    private typealias GroupSlot = (editor: SequenceEditing, row: Int, steps: Int)

    private func groupSlots(_ chosen: [SequenceEditing]) -> [GroupSlot] {
        chosen.flatMap { editor in
            Self.rows(of: editor).map { item in
                (editor: editor, row: item.row,
                 steps: editor.layout.lengthIndex == nil ? SequencerLayout.steps : editor.length)
            }
        }
    }

    /// Writes one pattern into each row, as one undo step; the sequencers keep their own Steps.
    private func writeGroup(_ slots: [GroupSlot], _ patterns: [[Bool]]) {
        state.beginParameterGesture()
        defer { state.endParameterGesture() }
        var perEditor: [Int: (editor: SequenceEditing, changes: [Int: Int])] = [:]
        for (index, slot) in slots.enumerated() where index < patterns.count {
            let flags = patterns[index].map { $0 ? 1 : 0 }
            let padded = flags + Array(repeating: 0, count: SequencerLayout.steps - flags.count)
            var entry = perEditor[slot.editor.module.id] ?? (slot.editor, [:])
            entry.changes.merge(slot.editor.changes(row: slot.row, padded)) { $1 }
            perEditor[slot.editor.module.id] = entry
        }
        for entry in perEditor.values { entry.editor.write(entry.changes) }
    }

    /// Interlock: the first row plays E(Hits) rotated by Offset; the rows after it deal out its rests.
    private func applyInterlock(_ chosen: [SequenceEditing]) {
        let slots = groupSlots(chosen)
        guard !slots.isEmpty else { return }
        let reference = slots.map(\.steps).max() ?? SequencerLayout.steps
        let lanes = EuclidGroup.interlock(hits: min(groupHits, reference), steps: reference,
                                          rotation: groupOffset % max(1, reference), lanes: slots.count)
        writeGroup(slots, slots.indices.map { Array(lanes[$0].prefix(slots[$0].steps)) })
    }

    /// Random group: see `EuclidGroup.randomLanes`.
    private func applyRandomGroup(_ chosen: [SequenceEditing]) {
        let slots = groupSlots(chosen)
        guard !slots.isEmpty else { return }
        var generator = SystemRandomNumberGenerator()
        writeGroup(slots, EuclidGroup.randomLanes(steps: slots.map(\.steps), using: &generator))
    }

    /// Meeting points: for each step of the time the ticked rows take to start over together (32 at most),
    /// how many of them hit there. Blue = two or more meet, solid blue = every row.
    private func meetingPoints(_ chosen: [SequenceEditing]) -> some View {
        let lanes: [[Bool]] = groupSlots(chosen).map { slot in
            Array(slot.editor.layout.row(slot.row, in: slot.editor.parameters).prefix(slot.steps)).map { $0 != 0 }
        }
        let counts = EuclidGroup.meetingCounts(lanes: lanes, span: EuclidGroup.span(ofLengths: lanes.map(\.count)))
        let meets = counts.filter { $0 >= 2 }.count
        return HStack(spacing: 8) {
            Text("Meeting points").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 2) {
                ForEach(counts.indices, id: \.self) { step in
                    let count = counts[step]
                    let all = lanes.count >= 2 && count == lanes.count
                    RoundedRectangle(cornerRadius: 3)
                        .fill(all ? SeqColor.blue.opacity(0.55) : (count >= 2 ? SeqColor.blue.opacity(0.22)
                                : (count == 1 ? SeqColor.green.opacity(0.18) : SeqColor.empty)))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(
                            count >= 2 ? SeqColor.blue : (count == 1 ? SeqColor.green.opacity(0.6) : SeqColor.rim),
                            lineWidth: 1
                        ))
                        .overlay(Text(count >= 2 ? "\(count)" : "").font(.system(size: 9, design: .monospaced)))
                        .frame(minWidth: 8, maxWidth: 22, minHeight: 18, maxHeight: 18)
                }
            }
            Text("\(meets) of \(counts.count) steps")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
        }
        .help("Steps where two or more ticked rows hit together (the number is how many). With different lengths the "
            + "row shows the time until they all start over, 32 steps at most.")
    }

    /// Group Euclid: one rhythm over all rows of the ticked sequencers, each keeping its own Steps.
    private func applyGroupEuclid(_ chosen: [SequenceEditing]) {
        if groupMode == .interlock {
            applyInterlock(chosen)
            return
        }
        let slots = chosen.flatMap { editor in
            Self.rows(of: editor).map { item in
                (editor: editor, row: item.row, steps: editor.layout.lengthIndex == nil ? SequencerLayout.steps : editor.length)
            }
        }
        guard !slots.isEmpty else { return }
        var patterns: [[Bool]] = []
        var rotations: [Int] = []
        switch groupMode {
        case .interlock:
            return // handled above
        case .same, .canon:
            for (index, slot) in slots.enumerated() {
                let rotation = groupMode == .canon ? (groupOffset * index) % max(1, slot.steps) : 0
                rotations.append(rotation)
                patterns.append(EuclideanRhythm.pattern(hits: min(groupHits, slot.steps), steps: slot.steps, rotation: rotation))
            }
        case .spread:
            let reference = slots.map(\.steps).max() ?? SequencerLayout.steps
            let base = EuclideanRhythm.pattern(hits: min(groupHits, reference), steps: reference,
                                               rotation: groupOffset % max(1, reference))
            let hitSteps = base.enumerated().filter(\.element).map(\.offset)
            for index in slots.indices {
                var pattern = Array(repeating: false, count: slots[index].steps)
                for (hit, step) in hitSteps.enumerated() where hit % slots.count == index && step < pattern.count {
                    pattern[step] = true
                }
                patterns.append(pattern)
            }
        }
        state.beginParameterGesture()
        defer { state.endParameterGesture() }
        var perEditor: [Int: (editor: SequenceEditing, changes: [Int: Int])] = [:]
        for (index, slot) in slots.enumerated() {
            let flags = patterns[index].map { $0 ? 1 : 0 }
            let padded = flags + Array(repeating: 0, count: SequencerLayout.steps - flags.count)
            var entry = perEditor[slot.editor.module.id] ?? (slot.editor, [:])
            entry.changes.merge(slot.editor.changes(row: slot.row, padded)) { $1 }
            perEditor[slot.editor.module.id] = entry
            if groupMode == .same || groupMode == .canon {
                // So the card reads "E(h,n) rN" instead of "edited".
                SequenceEditorMemory.shared.euclid[.init(target: slot.editor.target, row: slot.row)] =
                    .init(hits: min(groupHits, slot.steps), rotation: rotations[index], invert: false)
            }
        }
        for entry in perEditor.values { entry.editor.write(entry.changes) }
    }

    /// Kit: the parts of the kit go to the rows of the ticked sequencers in card order, each row taking
    /// the steps of its part. A SeqEvent has one Length for both rows, so its second row follows the
    /// steps of its first. Rows without a part, and parts without a row, are left out. One ⌘Z.
    private func applyKit(_ kit: EuclidKit, _ chosen: [SequenceEditing]) {
        let slots = chosen.flatMap { editor in Self.rows(of: editor).map { (editor: editor, row: $0.row) } }
        guard !slots.isEmpty else { return }
        state.beginParameterGesture()
        defer { state.endParameterGesture() }
        var stepsOf: [Int: Int] = [:]
        var perEditor: [Int: (editor: SequenceEditing, changes: [Int: Int])] = [:]
        for (index, slot) in slots.enumerated() where index < kit.parts.count {
            let part = kit.parts[index]
            let id = slot.editor.module.id
            let hasLength = slot.editor.layout.lengthIndex != nil
            let steps = stepsOf[id] ?? (hasLength ? part.steps : SequencerLayout.steps)
            stepsOf[id] = steps
            let flags = part.pattern(steps: steps).map { $0 ? 1 : 0 }
            let padded = flags + Array(repeating: 0, count: SequencerLayout.steps - flags.count)
            var entry = perEditor[id] ?? (slot.editor, [:])
            entry.changes.merge(slot.editor.changes(row: slot.row, padded)) { $1 }
            if let lengthIndex = slot.editor.layout.lengthIndex { entry.changes[lengthIndex] = steps - 1 }
            perEditor[id] = entry
            // So the card reads "E(h,n) rN" instead of "edited".
            SequenceEditorMemory.shared.euclid[.init(target: slot.editor.target, row: slot.row)] =
                .init(hits: min(part.hits, steps), rotation: part.rotation % steps, invert: false)
        }
        for entry in perEditor.values { entry.editor.write(entry.changes) }
    }

    /// The Accent lane (a SeqLev called "Accent <name>") of a sequencer, when it has one.
    private func accentEditor(for editor: SequenceEditing) -> SequenceEditing? {
        let label = PatchState.accentLabel(sequencerName: sequencerName(editor.module))
        guard let id = state.accentLaneID(slot: target.slot, area: target.area, label: label),
              let module = state.slots[target.slot].modules(in: target.area).first(where: { $0.id == id }),
              let layout = SequencerLayout(typeID: module.typeID) else { return nil }
        return SequenceEditing(state: state, target: .init(slot: target.slot, area: target.area, moduleID: id),
                               module: module, layout: layout)
    }

    private func card(_ editor: SequenceEditing, ring: CGFloat) -> some View {
        let def = ModuleDatabase.module(id: editor.module.typeID)
        let type = def?.shortName ?? "Sequencer"
        let selected = editor.module.id == target.moduleID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { !SequenceEditorMemory.shared.groupOut.contains(editor.target) },
                    set: { on in
                        if on {
                            SequenceEditorMemory.shared.groupOut.remove(editor.target)
                        } else {
                            SequenceEditorMemory.shared.groupOut.insert(editor.target)
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Takes part in Lengths and Group Euclid")
                LaneName(text: editor.module.label.isEmpty ? type : editor.module.label,
                         dot: laneDotColor(state: state, slot: target.slot, area: target.area, id: editor.module.id))
                Text(type).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(Self.rows(of: editor), id: \.row) { item in
                EuclidRowEditor(editor: editor, row: item.row, name: item.name, ringSize: ring)
            }
            if editor.layout.kind == .event { combined(for: editor) }
            if let accent = accentEditor(for: editor) { EuclidAccentBar(source: editor, accent: accent) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(SeqColor.card))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(selected ? SeqColor.blue.opacity(0.8) : SeqColor.cardBorder, lineWidth: 1))
    }

    /// SeqEvent: both rows as the one rhythm that comes out — green = Row 1 only, blue = Row 2 only,
    /// split = both on the same step. Display only.
    private func combined(for editor: SequenceEditing) -> some View {
        let first = editor.layout.row(0, in: editor.parameters)
        let second = editor.layout.row(1, in: editor.parameters)
        let playing = SequencePlayhead.step(of: editor.target, length: editor.length)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Combined").font(.system(size: 13, weight: .semibold))
                Text("Row 1 + Row 2, one rhythm").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                ForEach(0 ..< editor.length, id: \.self) { step in
                    let one = first[step] != 0
                    let two = second[step] != 0
                    ZStack {
                        RoundedRectangle(cornerRadius: 3).fill(SeqColor.empty)
                        if one || two {
                            HStack(spacing: 0) {
                                Rectangle().fill(one ? SeqColor.green.opacity(0.4) : SeqColor.blue.opacity(0.4))
                                Rectangle().fill(two ? SeqColor.blue.opacity(0.4) : SeqColor.green.opacity(0.4))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(playing == step ? SeqColor.ice
                                : (one && two ? Color(white: 0.65) : (one ? SeqColor.green : (two ? SeqColor.blue : SeqColor.rim))),
                                lineWidth: playing == step ? 2 : 1)
                    }
                    .frame(width: 22, height: 22)
                }
            }
        }
    }
}

/// The name a sequencer goes by in lane names: its label, else its module type.
@MainActor private func sequencerName(_ module: G2Module) -> String {
    module.label.isEmpty ? (ModuleDatabase.module(id: module.typeID)?.shortName ?? "Sequencer") : module.label
}

/// Euclid for the Accent lane of a sequencer: every n-th hit loud, the other steps soft.
private struct EuclidAccentBar: View {
    let source: SequenceEditing
    let accent: SequenceEditing
    @State private var every = 2

    var body: some View {
        HStack(spacing: 12) {
            Text("Accent").font(.system(size: 13, weight: .semibold))
            SeqNumberControl(title: "Every", value: every, range: 1 ... 8, state: source.state) { every = $0 }
                .help("Every n-th hit is loud (1 = all hits)")
            TopBarButton(content: .text("Apply")) { apply() }
                .help("Fill the bars of the Accent lane: the 1st, then every n-th hit loud, the rest soft. ⌘Z undoes it.")
            Text("→ lane “\(accent.module.label)”").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func apply() {
        let rows = source.layout.kind == .event ? [0, 1] : [1]
        let played = rows.map { source.layout.row($0, in: source.parameters) }
        var bars = Array(repeating: 70, count: SequencerLayout.steps)
        var hit = 0
        for step in 0 ..< source.length where played.contains(where: { $0[step] != 0 }) {
            if hit % every == 0 { bars[step] = 127 }
            hit += 1
        }
        accent.write(accent.changes(row: 0, bars))
    }
}

private struct EuclidRowEditor: View {
    let editor: SequenceEditing
    let row: Int
    let name: String
    let ringSize: CGFloat

    private var key: SequenceEditorMemory.EuclidKey {
        .init(target: editor.target, row: row)
    }

    /// Layer the Hits / Rotate / Random controls act on: 0 = the first generator, 1... = the added ones.
    @State private var layer = 0

    private var chosenLayer: Int {
        min(layer, settings.extra.count)
    }

    private var layerHits: Int {
        chosenLayer == 0 ? settings.hits : settings.extra[chosenLayer - 1].hits
    }

    private var layerRotation: Int {
        chosenLayer == 0 ? settings.rotation : settings.extra[chosenLayer - 1].rotation
    }

    private func setLayer(hits: Int? = nil, rotation: Int? = nil) {
        var new = settings
        if chosenLayer == 0 {
            new.hits = hits ?? new.hits
            new.rotation = rotation ?? new.rotation
        } else {
            new.extra[chosenLayer - 1].hits = hits ?? new.extra[chosenLayer - 1].hits
            new.extra[chosenLayer - 1].rotation = rotation ?? new.extra[chosenLayer - 1].rotation
        }
        apply(new, steps: steps)
    }

    /// Layers: 1, 2, 3, 4 pick the generator the controls act on; + adds one (up to four), − removes
    /// the chosen one. The rhythm is the sum of all layers (steps that any layer plays).
    private var layerChips: some View {
        HStack(spacing: 3) {
            ForEach(0 ... settings.extra.count, id: \.self) { index in
                TopBarButton(content: .text("\(index + 1)"), isOn: chosenLayer == index, tint: SeqColor.blue) {
                    layer = index
                }
                .help("Edit layer \(index + 1) — Hits, Rotate and Random act on it")
            }
            TopBarButton(content: .icon("plus"), isEnabled: settings.extra.count < SequenceEditorMemory.Euclid.maxExtra) {
                var new = settings
                new.extra.append(.init())
                layer = new.extra.count
                apply(new, steps: steps)
            }
            .help("Add a layer: another Euclid rhythm played together with this one")
            // Always there (grey on layer 1), so the row does not change width with the choice.
            TopBarButton(content: .icon("minus"), isEnabled: chosenLayer > 0) {
                var new = settings
                new.extra.remove(at: chosenLayer - 1)
                layer = max(0, chosenLayer - 1)
                apply(new, steps: steps)
            }
            .help(chosenLayer > 0 ? "Remove layer \(chosenLayer + 1)" : "Remove the chosen layer (not the first)")
        }
        .fixedSize()
        .padding(.leading, 6)
    }

    private var currentGates: [Bool] {
        editor.layout.row(row, in: editor.parameters).prefix(steps).map { $0 != 0 }
    }

    /// What the steps are, read from the steps themselves. A remembered setting counts only
    /// while it still produces exactly these steps (Invert cannot be read back from the steps
    /// alone); otherwise the rhythm is recognised, or marked as edited by hand.
    private var reading: (settings: SequenceEditorMemory.Euclid, isEuclidean: Bool) {
        let gates = currentGates
        if let remembered = SequenceEditorMemory.shared.euclid[key], remembered.pattern(steps: steps) == gates {
            return (remembered, true)
        }
        if let found = EuclideanRhythm.recognize(gates) {
            return (.init(hits: found.hits, rotation: found.rotation, invert: false), true)
        }
        return (.init(hits: gates.filter { $0 }.count), false)
    }

    private var settings: SequenceEditorMemory.Euclid {
        reading.settings
    }

    private var steps: Int {
        editor.layout.lengthIndex == nil ? SequencerLayout.steps : editor.length
    }

    var body: some View {
        let gates = editor.layout.row(row, in: editor.parameters)
        HStack(alignment: .top, spacing: 16) {
            EuclidRing(gates: Array(gates.prefix(steps)), color: SeqColor.trigger, target: editor.target) { step in
                toggle(step, in: gates)
            }
            .frame(width: ringSize, height: ringSize)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    if reading.isEuclidean {
                        if settings.extra.isEmpty {
                            Text("E(\(settings.hits),\(steps))" + (settings.rotation > 0 ? " r\(settings.rotation)" : ""))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(SeqColor.on)
                        } else {
                            Text("sum of \(settings.extra.count + 1) · \(gates.prefix(steps).filter { $0 != 0 }.count) hits")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(SeqColor.on)
                                .help("The steps of all layers together")
                        }
                    } else {
                        Text("edited · \(settings.hits) hits")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(SeqColor.lock)
                            .help("Not an exact Euclidean rhythm — a step was toggled by hand")
                        TopBarButton(content: .text("Make Euclidean")) { apply(settings, steps: steps) }
                            .help("Spread the same number of hits evenly")
                    }
                    layerChips
                    Spacer()
                    Menu("Presets") {
                        ForEach(EuclideanRhythm.Category.allCases) { category in
                            Menu(category.title) {
                                ForEach(EuclideanRhythm.presets(in: category)) { preset in
                                    Button("\(preset.name)  \(preset.hits)/\(preset.steps)") {
                                        apply(.init(hits: preset.hits, rotation: preset.rotation, invert: false),
                                              steps: preset.steps)
                                    }
                                    .disabled(editor.layout.lengthIndex == nil && preset.steps != SequencerLayout.steps)
                                }
                            }
                        }
                    }
                    .frame(width: 100)
                }
                HStack(spacing: 14) {
                    SeqNumberControl(title: "Steps", value: steps, range: 2 ... 16, state: editor.state,
                                     isEnabled: editor.layout.lengthIndex != nil)
                    {
                        apply(settings, steps: $0)
                    }
                    .help("Steps of the rhythm — the same as the module's Length")
                    SeqNumberControl(title: "Hits", value: layerHits, range: 0 ... steps, state: editor.state) {
                        setLayer(hits: $0)
                    }
                    .help(settings.extra.isEmpty ? "Number of hits" : "Hits of the chosen layer")
                    SeqNumberControl(title: "Rotate", value: layerRotation, range: 0 ... max(0, steps - 1),
                                     state: editor.state, isEnabled: steps > 1)
                    {
                        setLayer(rotation: $0)
                    }
                    .help(settings.extra.isEmpty ? "Shift the pattern right" : "Rotation of the chosen layer")
                    TopBarButton(content: .text("Invert"), isOn: settings.invert) {
                        var new = settings
                        new.invert.toggle()
                        apply(new, steps: steps)
                    }
                    .help("Invert: play the rests instead of the hits")
                    TopBarButton(content: .text("Random")) {
                        setLayer(hits: Int.random(in: 1 ... max(1, steps - 1)),
                                 rotation: Int.random(in: 0 ... max(0, steps - 1)))
                    }
                    .help(settings.extra.isEmpty ? "Random number of hits and rotation"
                        : "Random hits and rotation for the chosen layer")
                    if editor.layout.kind == .event, row == 1 {
                        let linked = SequenceEditorMemory.shared.linkedRests.contains(editor.target)
                        TopBarButton(content: .text("Rests of Row 1"), isOn: linked, tint: SeqColor.blue) {
                            if linked {
                                SequenceEditorMemory.shared.linkedRests.remove(editor.target)
                            } else {
                                editor.write(editor.restsOfFirstRow())
                                SequenceEditorMemory.shared.linkedRests.insert(editor.target)
                            }
                        }
                        .help("Row 2 plays exactly where Row 1 rests (kick and snare never together) and follows "
                            + "every change of Row 1 made in this window. Editing Row 2 by hand, or a click here, ends it.")
                    }
                    if editor.layout.kind == .note {
                        TopBarButton(content: .text("Fill notes")) { editor.fillNotesOnHits() }
                            .help("Give every hit a note of the chosen scale (Edit tab: Scale, Root, octaves). "
                                + "Rests and locked steps keep theirs. ↺ in Edit undoes it.")
                    }
                }
                stepStrip(gates)
            }
        }
    }

    /// The rhythm as a line of steps under the controls: a lit square is a hit.
    private func stepStrip(_ gates: [Int]) -> some View {
        HStack(spacing: 3) {
            ForEach(0 ..< steps, id: \.self) { step in
                let on = step < gates.count && gates[step] != 0
                RoundedRectangle(cornerRadius: 3)
                    .fill(on ? SeqColor.trigger.opacity(0.26) : SeqColor.empty)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? SeqColor.trigger : SeqColor.rim, lineWidth: 1))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(step, in: gates) }
            }
        }
        .help("Click a square to toggle that step")
    }

    /// One step on or off — from the ring and from the strip.
    private func toggle(_ step: Int, in gates: [Int]) {
        editor.write(editor.changes(row: row, gates.enumerated().map { $0.offset == step ? 1 - $0.element : $0.element }))
    }

    /// Writes the rhythm (and Length) as one undo step.
    private func apply(_ new: SequenceEditorMemory.Euclid, steps newSteps: Int) {
        var settings = new
        settings.hits = min(settings.hits, newSteps)
        settings.rotation = min(settings.rotation, max(0, newSteps - 1))
        SequenceEditorMemory.shared.euclid[key] = settings
        let pattern = settings.pattern(steps: newSteps).map { $0 ? 1 : 0 }
        let padded = pattern + Array(repeating: 0, count: SequencerLayout.steps - pattern.count)
        var all = editor.changes(row: row, padded)
        if let lengthIndex = editor.layout.lengthIndex, newSteps != editor.length {
            all[lengthIndex] = newSteps - 1
        }
        editor.write(all)
    }
}

/// A hand from the centre of the ring to the step the module is playing now (ice, like the playhead).
private struct EuclidHand: View {
    let target: SequenceTarget
    let steps: Int
    let center: CGPoint
    let radius: CGFloat

    var body: some View {
        Canvas { context, _ in
            guard let step = SequencePlayhead.step(of: target, length: steps), steps > 0 else { return }
            let angle = -CGFloat.pi / 2 + CGFloat(step) * 2 * .pi / CGFloat(steps)
            var hand = Path()
            hand.move(to: center)
            hand.addLine(to: CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
            context.stroke(hand, with: .color(SeqColor.ice), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)),
                         with: .color(SeqColor.ice))
        }
        .allowsHitTesting(false)
    }
}

/// Steps on a circle, step 1 at the top, clockwise.
private struct EuclidRing: View {
    let gates: [Int]
    let color: Color
    let target: SequenceTarget
    let toggle: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Dots grow a little with the ring.
            let scale = max(0.8, size.width / 150)
            let half = 7 * scale
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 10 * scale
            Canvas { context, _ in
                context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                      width: radius * 2, height: radius * 2)),
                               with: .color(.gray.opacity(0.4)), lineWidth: 1)
                // The polygon through the hits — the shape of the rhythm.
                let hits = gates.indices.filter { gates[$0] != 0 }.map { position($0, center: center, radius: radius) }
                if hits.count >= 2 {
                    var shape = Path()
                    shape.move(to: hits[0])
                    for point in hits.dropFirst() { shape.addLine(to: point) }
                    shape.closeSubpath()
                    context.fill(shape, with: .color(color.opacity(0.10)))
                    context.stroke(shape, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
                for (step, gate) in gates.enumerated() {
                    let point = position(step, center: center, radius: radius)
                    let dot = CGRect(x: point.x - half, y: point.y - half, width: half * 2, height: half * 2)
                    if gate != 0 {
                        context.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.2)))
                        context.stroke(Path(ellipseIn: dot.insetBy(dx: 1, dy: 1)), with: .color(color), lineWidth: 1.5)
                    } else {
                        context.stroke(Path(ellipseIn: dot.insetBy(dx: 1, dy: 1)), with: .color(.gray), lineWidth: 1.5)
                    }
                }
            }
            .overlay { EuclidHand(target: target, steps: gates.count, center: center, radius: radius - 10 * scale) }
            .onTapGesture(coordinateSpace: .local) { location in
                guard !gates.isEmpty else { return }
                let nearest = gates.indices.min { lhs, rhs in
                    distance(position(lhs, center: center, radius: radius), location)
                        < distance(position(rhs, center: center, radius: radius), location)
                }
                if let nearest, distance(position(nearest, center: center, radius: radius), location) < half * 2 {
                    toggle(nearest)
                }
            }
        }
    }

    private func position(_ step: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = -CGFloat.pi / 2 + CGFloat(step) * 2 * .pi / CGFloat(max(1, gates.count))
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
