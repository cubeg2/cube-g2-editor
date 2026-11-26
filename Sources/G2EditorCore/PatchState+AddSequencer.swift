// PatchState+AddSequencer.swift
// "Add Sequencer" (v3, 2026-11-26): a note sequencer, a clock and the cables for one of three ways of
// playing, chosen in the Sequence Editor's sheet and changeable later in the Edit tab. One ⌘Z each.
//
// Measured in the silent emulator 2026-11-26 (→ [[Docs/ui/sequence-editor-add-sequencer]]):
// • a voice-area sequencer runs once per voice, so in a poly patch every voice played its own copy
//   (+6 dB, a wash) → "By itself" turns the patch Mono;
// • the two held-key modes open the envelopes with Keyboard.Gate AND SeqNote.Trig (module Gate): silence
//   without a key; the key restarts the clock (ClkGen.Rst), whose Sync pulse restarts the pattern;
// • "Follows held keys" keeps the oscillators' Kbt and adds the pattern through LevAdd (Uni, Level 32 = +16
//   semitones): a held C3 plays the pattern as written (261.7 Hz with and without the sequencer);
// • a short trigger (TG = T) lets slow envelopes close at once (−41 dB), a whole-step gate (TG = G) ties steps in
//   a row into one note → short by default, whole step on request, slow envelopes can be left on the keys;
// • the note also went into filters and changed their tone in 66 % of 534 patches → filters are offered,
//   not ticked.
// The wiring of an oscillator whose Pitch is taken by a mixer goes into the mixer's free Chain (measured on
// leeddd, 2026-11-18). An oscillator whose Pitch is taken otherwise keeps following the keys.

import Foundation
import G2Core

/// How a note sequencer added by the editor plays.
public enum SequencerPlayMode: String, CaseIterable, Identifiable, Sendable {
    case byItself, heldKeys, rhythmOnKeys

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .byItself: "By itself"
        case .heldKeys: "Follows held keys"
        case .rhythmOnKeys: "Rhythm on held keys"
        }
    }

    public var summary: String {
        switch self {
        case .byItself: "Plays on its own. One voice."
        case .heldKeys: "A key starts the pattern and moves it."
        case .rhythmOnKeys: "Keys pick the notes, steps play them."
        }
    }

    public var systemImage: String {
        switch self {
        case .byItself: "play.circle"
        case .heldKeys: "pianokeys"
        case .rhythmOnKeys: "music.quarternote.3"
        }
    }

    /// Modes the Sequence Editor offers. The held-key modes are wired and tested in code, but on the Nord the
    /// key's gate did not open the steps (2026-11-26: one note per key press, through Gate AND and through the
    /// envelope's AM) — they stay hidden until that is understood on the hardware.
    public static let offered: [SequencerPlayMode] = [.byItself]

    var usesKeys: Bool {
        self != .byItself
    }

    var drivesPitch: Bool {
        self != .rhythmOnKeys
    }
}

/// Length of one step. 1/16 comes straight from ClkGen; the others from a ClkDiv on its 1/96 output.
/// The raw value is the number of 1/96 pulses per step (= the ClkDiv divider).
public enum SequencerStep: Int, CaseIterable, Identifiable, Sendable {
    case thirtySecond = 3, sixteenth = 6, eighthTriplet = 8, eighth = 12, quarter = 24

    public var id: Int {
        rawValue
    }

    public var title: String {
        switch self {
        case .thirtySecond: "1/32"
        case .sixteenth: "1/16"
        case .eighthTriplet: "1/8T"
        case .eighth: "1/8"
        case .quarter: "1/4"
        }
    }

    /// Quarter notes one step lasts.
    public var beats: Double {
        Double(rawValue) / 24
    }
}

public enum SequencerClockChoice: Hashable, Sendable {
    /// A new ClkGen with Source = Master: Run and tempo come from the top bar.
    case newFollowingTopBar
    /// A new ClkGen with its own tempo; it runs whatever Run says.
    case newOwnTempo
    /// A ClkGen already in the patch.
    case existing(Int)
}

/// Something the new sequencer can drive, as the sheet lists it.
public struct AddSequencerTarget: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case oscillator, filter, envelope }
    public let id: Int
    public let kind: Kind
    public let name: String
    /// How it is reached ("Pitch", "via P-Mod1") or what it is ("EnvADSR").
    public let detail: String
    /// Slow attack, e.g. "10.4s (var. 1)": a short step cannot open it.
    public let slowAttack: String?
}

public struct AddSequencerOptions: Equatable, Sendable {
    public var mode: SequencerPlayMode
    public var clock: SequencerClockChoice
    public var step: SequencerStep = .sixteenth
    public var restartEveryBar = true
    /// Short trigger by default: every step starts the envelope again. A whole-step gate ties steps in a row
    /// into one note (measured 2026-11-26: Welcome v8 played one decaying note instead of the pattern).
    public var wholeStepGate = false
    /// Oscillators (and filters) that get the note.
    public var pitchTargets: Set<Int>
    /// Envelopes that get the step.
    public var gateTargets: Set<Int>

    public init(mode: SequencerPlayMode, clock: SequencerClockChoice, pitchTargets: Set<Int>, gateTargets: Set<Int>) {
        self.mode = mode
        self.clock = clock
        self.pitchTargets = pitchTargets
        self.gateTargets = gateTargets
    }
}

/// What the sheet offers for one slot.
public struct AddSequencerChoices: Equatable, Sendable {
    public struct Clock: Identifiable, Equatable, Sendable {
        public let id: Int
        public let name: String
    }

    public var oscillators: [AddSequencerTarget] = []
    public var filters: [AddSequencerTarget] = []
    public var envelopes: [AddSequencerTarget] = []
    public var clocks: [Clock] = []
    public var isPoly = false
    public var voiceModeLabel = ""
    public var hasKeyboard = false

    public var recommendedMode: SequencerPlayMode {
        isPoly && SequencerPlayMode.offered.contains(.heldKeys) ? .heldKeys : .byItself
    }

    public var defaultOptions: AddSequencerOptions {
        AddSequencerOptions(mode: recommendedMode,
                            clock: clocks.first.map { .existing($0.id) } ?? .newFollowingTopBar,
                            pitchTargets: Set(oscillators.map(\.id)),
                            gateTargets: Set(envelopes.map(\.id)))
    }
}

/// The clock of one sequencer, as the Edit tab shows it.
public struct SequencerClockInfo: Equatable, Sendable {
    /// The ClkGen behind the sequencer; `nil` when something else clocks it (an LFO, another sequencer).
    public var clockID: Int?
    public var clockName: String
    public var followsTopBar: Bool
    public var step: SequencerStep?
    public var restartsEveryBar: Bool
}

public extension PatchState {
    /// Why nothing was added, or `added` with the number of the new SeqNote.
    enum AddSequencerResult: Equatable {
        case added(sequencerID: Int)
        /// No oscillator, envelope or keyboard cable the sequencer could take over.
        case noSoundSource
        /// The estimate of the patch plus the new modules would pass 100 % of the cycles or the memory.
        case wontFit
    }

    static let noteSequencerTypeID = 121 // SeqNote
    static let clockGeneratorTypeID = 68 // ClkGen
    static let clockDividerTypeID = 69 // ClkDiv
    static let logicGateTypeID = 64 // Gate (AND / OR …)
    static let levelAddTypeID = 112 // LevAdd
    /// Keyboard and Monophonic Keyboard: both have Pitch = output 0 and Gate = output 1.
    static let sequencerKeyboardTypeIDs = [1, 199]

    /// The starter pattern: a C-major arpeggio up and down, then the same on A minor (MIDI note numbers).
    /// With "Follows held keys" a held C3 plays it as written.
    static let sequencerStarterNotes = [48, 52, 55, 60, 64, 60, 55, 52, 45, 48, 52, 57, 60, 57, 52, 48]

    /// LevAdd Level 32 (Uni) adds 16 semitones: the pattern's C3 (48) against the keyboard's E4 (64) centre.
    static let heldKeysLevAddLevel = 32
    /// Attack from which an envelope counts as slow (raw 54 ≈ 0.45 s on the ADSR scale).
    static let slowAttackRaw = 54

    // MARK: - What can be driven

    /// Oscillator or filter → the input that gets the note: its own Pitch, or a mixer's free Chain.
    private struct PitchRoute {
        var module: Int
        var connector: Int
    }

    private static func input(_ typeID: Int, _ name: String) -> Int? {
        ModuleDatabase.module(id: typeID)?.inputs.firstIndex { $0.name == name }
    }

    private static func output(_ typeID: Int, _ name: String) -> Int? {
        ModuleDatabase.module(id: typeID)?.outputs.firstIndex { $0.name == name }
    }

    private static func param(_ typeID: Int, _ name: String) -> Int? {
        ModuleDatabase.module(id: typeID)?.paramNames.firstIndex(of: name)
    }

    private static func isFilter(_ typeID: Int) -> Bool {
        ModuleDatabase.module(id: typeID)?.shortName.hasPrefix("Flt") == true
    }

    private static func isEnvelope(_ typeID: Int) -> Bool {
        ModuleDatabase.module(id: typeID)?.shortName.hasPrefix("Env") == true
    }

    private static func name(of module: G2Module) -> String {
        module.label.isEmpty ? (ModuleDatabase.module(id: module.typeID)?.shortName ?? "Module") : module.label
    }

    /// Every module with a Pitch input and a Kbt parameter whose Pitch the sequencer can reach.
    private func pitchRoutes(in patch: G2Patch) -> [Int: PitchRoute] {
        let modules = patch.modules(in: .voice)
        let cables = patch.cables(in: .voice)
        let keyboards = Set(modules.filter { Self.sequencerKeyboardTypeIDs.contains($0.typeID) }.map(\.id))
        var routes: [Int: PitchRoute] = [:]
        var usedChain = Set<Int>()
        for module in modules {
            guard let pitch = Self.input(module.typeID, "Pitch"), Self.param(module.typeID, "Kbt") != nil else { continue }
            let into = cables.filter { $0.toModule == module.id && $0.toConnector == pitch }
            if into.isEmpty {
                routes[module.id] = PitchRoute(module: module.id, connector: pitch)
            } else if into.count == 1, let feeder = into.first, feeder.sourceIsOutput,
                      !keyboards.contains(feeder.fromModule),
                      let mixer = modules.first(where: { $0.id == feeder.fromModule }),
                      let chain = Self.input(mixer.typeID, "Chain"),
                      !usedChain.contains(mixer.id),
                      !cables.contains(where: { $0.toModule == mixer.id && $0.toConnector == chain }),
                      cables.filter({ $0.fromModule == mixer.id && $0.sourceIsOutput && $0.fromConnector == feeder.fromConnector }).count == 1
            {
                usedChain.insert(mixer.id)
                routes[module.id] = PitchRoute(module: mixer.id, connector: chain)
            }
        }
        return routes
    }

    /// Envelopes that follow the key today: nothing on their Gate, or the keyboard's Gate.
    private func keyEnvelopes(in patch: G2Patch) -> [G2Module] {
        let cables = patch.cables(in: .voice)
        let keyboards = Set(patch.modules(in: .voice).filter { Self.sequencerKeyboardTypeIDs.contains($0.typeID) }.map(\.id))
        return patch.modules(in: .voice).filter { module in
            guard Self.isEnvelope(module.typeID), let gate = Self.input(module.typeID, "Gate") else { return false }
            let into = cables.filter { $0.toModule == module.id && $0.toConnector == gate }
            return into.isEmpty || into.allSatisfy { keyboards.contains($0.fromModule) && $0.fromConnector == 1 }
        }
    }

    private func slowAttack(of module: G2Module) -> String? {
        guard let attack = Self.param(module.typeID, "Attack") else { return nil }
        var slowest: (variation: Int, value: Int)?
        for variation in 0 ..< G2Patch.initVariation {
            let values = module.parameterVariations.indices.contains(variation) ? module.parameterVariations[variation] : module.parameters
            guard values.indices.contains(attack) else { continue }
            if values[attack] >= Self.slowAttackRaw, values[attack] > (slowest?.value ?? -1) {
                slowest = (variation, values[attack])
            }
        }
        guard let slowest else { return nil }
        return "\(G2ParameterText.value(paramIndex: attack, value: slowest.value, module: module)) (var. \(slowest.variation + 1))"
    }

    /// What the sheet lists for a slot.
    func addSequencerChoices(slot: Int) -> AddSequencerChoices {
        guard slots.indices.contains(slot) else { return AddSequencerChoices() }
        let patch = slots[slot]
        let modules = patch.modules(in: .voice)
        let routes = pitchRoutes(in: patch)
        var choices = AddSequencerChoices()
        for module in modules {
            guard let route = routes[module.id] else { continue }
            let mixerName = modules.first { $0.id == route.module }.map(Self.name(of:)) ?? ""
            let target = AddSequencerTarget(id: module.id, kind: Self.isFilter(module.typeID) ? .filter : .oscillator,
                                            name: Self.name(of: module),
                                            detail: route.module == module.id ? "Pitch" : "via \(mixerName)",
                                            slowAttack: nil)
            if target.kind == .filter { choices.filters.append(target) } else { choices.oscillators.append(target) }
        }
        choices.envelopes = keyEnvelopes(in: patch).map { module in
            AddSequencerTarget(id: module.id, kind: .envelope, name: Self.name(of: module),
                               detail: ModuleDatabase.module(id: module.typeID)?.shortName ?? "",
                               slowAttack: slowAttack(of: module))
        }
        choices.clocks = modules.filter { $0.typeID == Self.clockGeneratorTypeID }
            .map { AddSequencerChoices.Clock(id: $0.id, name: Self.name(of: $0)) }
        let voiceMode = voiceModeIndex(slot: slot)
        choices.isPoly = voiceMode >= 2
        choices.voiceModeLabel = G2VoiceMode.label(index: voiceMode)
        choices.hasKeyboard = modules.contains { Self.sequencerKeyboardTypeIDs.contains($0.typeID) }
        return choices
    }

    /// The module types the options add, for the DSP estimate.
    private func addedTypes(slot: Int, options: AddSequencerOptions) -> [Int] {
        var types = [Self.noteSequencerTypeID]
        if case .existing = options.clock {} else { types.append(Self.clockGeneratorTypeID) }
        if options.step != .sixteenth { types.append(Self.clockDividerTypeID) }
        if options.mode.usesKeys {
            types.append(Self.logicGateTypeID)
            if !addSequencerChoices(slot: slot).hasKeyboard { types.append(Self.sequencerKeyboardTypeIDs[0]) }
        }
        if options.mode == .heldKeys { types.append(Self.levelAddTypeID) }
        return types
    }

    /// Voice area load now and with the new modules.
    func addSequencerLoad(slot: Int, options: AddSequencerOptions) -> (before: G2PatchLoad, after: G2PatchLoad) {
        let patch = slots.indices.contains(slot) ? slots[slot] : G2Patch()
        let before = G2PatchLoad.estimate(area: .voice, patch: patch)
        let after = addedTypes(slot: slot, options: options).reduce(before) { $0.adding(typeID: $1) }
        return (before, after)
    }

    /// Why the default options cannot be added, `nil` = they can.
    func addSequencerObstacle(slot: Int) -> AddSequencerResult? {
        addSequencerObstacle(slot: slot, options: addSequencerChoices(slot: slot).defaultOptions)
    }

    func addSequencerObstacle(slot: Int, options: AddSequencerOptions) -> AddSequencerResult? {
        guard slots.indices.contains(slot) else { return .noSoundSource }
        let choices = addSequencerChoices(slot: slot)
        let keyboardCables = slots[slot].cables(in: .voice).contains { cable in
            cable.sourceIsOutput && cable.fromConnector <= 1
                && slots[slot].modules(in: .voice).contains { $0.id == cable.fromModule && Self.sequencerKeyboardTypeIDs.contains($0.typeID) }
        }
        if choices.oscillators.isEmpty, choices.filters.isEmpty, choices.envelopes.isEmpty, !keyboardCables {
            return .noSoundSource
        }
        let after = addSequencerLoad(slot: slot, options: options).after
        return after.cyclesPercent <= 100 && after.memoryPercent <= 100 ? nil : .wontFit
    }

    // MARK: - Adding

    /// The default options of the slot (the plugin bridge uses this).
    @discardableResult
    func addSequencer(slot: Int) -> AddSequencerResult {
        addSequencer(slot: slot, options: addSequencerChoices(slot: slot).defaultOptions)
    }

    /// Adds a note sequencer to the watched slot and wires it as `options` say. One ⌘Z takes it all back.
    @discardableResult
    func addSequencer(slot: Int, options: AddSequencerOptions) -> AddSequencerResult {
        if let obstacle = addSequencerObstacle(slot: slot, options: options) { return obstacle }
        guard slot == selectedSlot, let layout = SequencerLayout(typeID: Self.noteSequencerTypeID) else { return .noSoundSource }

        undoManager.beginUndoGrouping()
        defer {
            undoManager.setActionName("Add Sequencer")
            undoManager.endUndoGrouping()
        }
        var clockID: Int?
        switch options.clock {
        case let .existing(id): clockID = id
        case .newFollowingTopBar, .newOwnTempo:
            clockID = addModule(typeID: Self.clockGeneratorTypeID, area: .voice)
            if let clockID {
                writeEverywhere(slot: slot, area: .voice, moduleID: clockID,
                                values: [ClockGenSettings.source: options.clock == .newFollowingTopBar ? 1 : 0])
            }
        }
        guard let clockID, let sequencerID = addModule(typeID: Self.noteSequencerTypeID, area: .voice) else {
            return .wontFit
        }

        // Starter pattern in every variation (a variation that is not playing must not be silent): notes in
        // row 1, every step's Trig on in row 2; a gate as long as the step unless asked otherwise.
        var values: [Int: Int] = [:]
        for step in 0 ..< SequencerLayout.steps {
            values[layout.rowStarts[0] + step] = Self.sequencerStarterNotes[step]
            values[layout.rowStarts[1] + step] = 1
        }
        if let tg = Self.param(Self.noteSequencerTypeID, "TG") { values[tg] = options.wholeStepGate ? 1 : 0 }
        writeEverywhere(slot: slot, area: .voice, moduleID: sequencerID, values: values)

        connectClock(slot: slot, clockID: clockID, sequencerID: sequencerID, step: options.step)
        if options.restartEveryBar {
            setRestart(true, slot: slot, clockID: clockID, sequencerID: sequencerID,
                       updateBeatSync: options.clock != .existing(clockID), keysReset: false)
        }
        wire(slot: slot, sequencerID: sequencerID, clockID: clockID, mode: options.mode,
             pitchTargets: options.pitchTargets, gateTargets: options.gateTargets, extraGateConsumers: [])
        applyVoiceMode(for: options.mode, slot: slot)
        return .added(sequencerID: sequencerID)
    }

    // MARK: - Wiring

    private func keyboard(in slot: Int) -> G2Module? {
        slots[slot].modules(in: .voice).first { Self.sequencerKeyboardTypeIDs.contains($0.typeID) }
    }

    /// Cables, Kbt and helper modules of one play mode. `extraGateConsumers` are inputs that followed the
    /// sequencer's step before a mode change (they follow it again).
    private func wire(slot: Int, sequencerID: Int, clockID: Int?, mode: SequencerPlayMode,
                      pitchTargets: Set<Int>, gateTargets: Set<Int>, extraGateConsumers: [(module: Int, connector: Int)])
    {
        guard let noteOut = Self.output(Self.noteSequencerTypeID, "Note"),
              let trigOut = Self.output(Self.noteSequencerTypeID, "Trig"),
              let seqRst = Self.input(Self.noteSequencerTypeID, "Rst") else { return }
        let before = slots[slot]
        let routes = pitchRoutes(in: before)

        // Key tracking: off when the pattern alone sets the pitch, back to the module's default otherwise.
        for id in pitchTargets {
            guard let module = before.modules(in: .voice).first(where: { $0.id == id }),
                  let kbt = Self.param(module.typeID, "Kbt"), module.parameters.indices.contains(kbt) else { continue }
            if mode == .byItself {
                writeEverywhere(slot: slot, area: .voice, moduleID: id, values: [kbt: 0])
            } else if module.parameters[kbt] == 0 {
                let defaults = ModuleDefaultsDatabase.defaults(forTypeID: module.typeID)
                writeEverywhere(slot: slot, area: .voice, moduleID: id,
                                values: [kbt: defaults.indices.contains(kbt) ? defaults[kbt] : 1])
            }
        }

        // What followed the keyboard's Pitch / Gate before (Glide, logic delays, envelopes on Keyboard.Gate).
        let keyboardCables: [G2Cable] = keyboard(in: slot).map { kb in
            before.cables(in: .voice).filter { $0.fromModule == kb.id && $0.sourceIsOutput && $0.fromConnector <= 1 }
        } ?? []

        var keyboardID = keyboard(in: slot)?.id
        if mode.usesKeys, keyboardID == nil {
            keyboardID = addModule(typeID: Self.sequencerKeyboardTypeIDs[0], area: .voice)
        }

        // Where the envelopes' gate comes from.
        var gateSource = (module: sequencerID, connector: trigOut)
        if mode.usesKeys, let keyboardID,
           let andID = addModule(typeID: Self.logicGateTypeID, area: .voice),
           let in1 = Self.input(Self.logicGateTypeID, "In1_1"), let in2 = Self.input(Self.logicGateTypeID, "In1_2"),
           let out1 = Self.output(Self.logicGateTypeID, "Out1")
        {
            addCable(G2Cable(fromModule: keyboardID, fromConnector: 1, toModule: andID, toConnector: in1,
                             color: .yellow, area: .voice), slot: slot)
            addCable(G2Cable(fromModule: sequencerID, fromConnector: trigOut, toModule: andID, toConnector: in2,
                             color: .yellow, area: .voice), slot: slot)
            gateSource = (andID, out1)
            // The key restarts the clock, and through its Sync pulse the pattern; without that cable, the pattern itself.
            let cables = slots[slot].cables(in: .voice)
            if let clockID, let clockRst = Self.input(Self.clockGeneratorTypeID, "Rst"),
               !cables.contains(where: { $0.toModule == clockID && $0.toConnector == clockRst })
            {
                addCable(G2Cable(fromModule: keyboardID, fromConnector: 1, toModule: clockID, toConnector: clockRst,
                                 color: .yellow, area: .voice), slot: slot)
            }
            if !slots[slot].cables(in: .voice).contains(where: { $0.toModule == sequencerID && $0.toConnector == seqRst }) {
                addCable(G2Cable(fromModule: keyboardID, fromConnector: 1, toModule: sequencerID, toConnector: seqRst,
                                 color: .yellow, area: .voice), slot: slot)
            }
        }

        // Envelopes: the step (or key AND step) instead of the key.
        for id in gateTargets {
            guard let module = before.modules(in: .voice).first(where: { $0.id == id }),
                  let gate = Self.input(module.typeID, "Gate") else { continue }
            for cable in slots[slot].cables(in: .voice) where cable.toModule == id && cable.toConnector == gate {
                removeCable(cable)
            }
            addCable(G2Cable(fromModule: gateSource.module, fromConnector: gateSource.connector, toModule: id,
                             toConnector: gate, color: .yellow, area: .voice), slot: slot)
        }
        // Whatever else followed the keyboard's Gate follows the step now.
        for cable in keyboardCables where cable.fromConnector == 1 && !gateTargets.contains(cable.toModule) {
            removeCable(cable)
            var rerouted = cable
            rerouted.fromModule = gateSource.module
            rerouted.fromConnector = gateSource.connector
            addCable(rerouted, slot: slot)
        }
        for input in extraGateConsumers {
            addCable(G2Cable(fromModule: gateSource.module, fromConnector: gateSource.connector, toModule: input.module,
                             toConnector: input.connector, color: .yellow, area: .voice), slot: slot)
        }

        // Pitch: the pattern, or the pattern on top of the key.
        guard mode.drivesPitch else { return }
        var noteSource = (module: sequencerID, connector: noteOut)
        if mode == .heldKeys, let levelID = addModule(typeID: Self.levelAddTypeID, area: .voice),
           let levelIn = Self.input(Self.levelAddTypeID, "In"), let levelOut = Self.output(Self.levelAddTypeID, "Out"),
           let level = Self.param(Self.levelAddTypeID, "Level"), let bipUni = Self.param(Self.levelAddTypeID, "BipUni")
        {
            writeEverywhere(slot: slot, area: .voice, moduleID: levelID, values: [level: Self.heldKeysLevAddLevel, bipUni: 1])
            addCable(G2Cable(fromModule: sequencerID, fromConnector: noteOut, toModule: levelID, toConnector: levelIn,
                             color: .blue, area: .voice), slot: slot)
            noteSource = (levelID, levelOut)
        }
        for id in pitchTargets.sorted() {
            guard let route = routes[id] else { continue }
            addCable(G2Cable(fromModule: noteSource.module, fromConnector: noteSource.connector, toModule: route.module,
                             toConnector: route.connector, color: .blue, area: .voice), slot: slot)
        }
        // By itself: what the keyboard's Pitch fed (Glide, note scalers) listens to the pattern.
        if mode == .byItself {
            for cable in keyboardCables where cable.fromConnector == 0 {
                removeCable(cable)
                var rerouted = cable
                rerouted.fromModule = sequencerID
                rerouted.fromConnector = noteOut
                addCable(rerouted, slot: slot)
            }
        }
    }

    /// By itself makes a poly patch Mono (one copy of the pattern); leaving it gives the voices back.
    private func applyVoiceMode(for mode: SequencerPlayMode, slot: Int) {
        let current = voiceModeIndex(slot: slot)
        if mode == .byItself, current >= 2 {
            voiceModeBeforeSequencer[slot] = current
            setVoiceMode(index: 1, slot: slot)
        } else if mode != .byItself, current == 1, let previous = voiceModeBeforeSequencer[slot] {
            voiceModeBeforeSequencer[slot] = nil
            setVoiceMode(index: previous, slot: slot)
        }
    }

    // MARK: - Clock

    private func connectClock(slot: Int, clockID: Int, sequencerID: Int, step: SequencerStep) {
        guard let seqClk = Self.input(Self.noteSequencerTypeID, "Clk"),
              let out16 = Self.output(Self.clockGeneratorTypeID, "1/16"),
              let out96 = Self.output(Self.clockGeneratorTypeID, "1/96"),
              let sync = Self.output(Self.clockGeneratorTypeID, "Sync") else { return }
        if step == .sixteenth {
            addCable(G2Cable(fromModule: clockID, fromConnector: out16, toModule: sequencerID, toConnector: seqClk,
                             color: .yellow, area: .voice), slot: slot)
            return
        }
        guard let dividerID = addModule(typeID: Self.clockDividerTypeID, area: .voice),
              let divClk = Self.input(Self.clockDividerTypeID, "Clk"), let divRst = Self.input(Self.clockDividerTypeID, "Rst"),
              let divOut = Self.output(Self.clockDividerTypeID, "Out"),
              let divider = Self.param(Self.clockDividerTypeID, "Divider") else { return }
        writeEverywhere(slot: slot, area: .voice, moduleID: dividerID, values: [divider: step.rawValue - 1])
        addCable(G2Cable(fromModule: clockID, fromConnector: out96, toModule: dividerID, toConnector: divClk,
                         color: .yellow, area: .voice), slot: slot)
        addCable(G2Cable(fromModule: clockID, fromConnector: sync, toModule: dividerID, toConnector: divRst,
                         color: .yellow, area: .voice), slot: slot)
        addCable(G2Cable(fromModule: dividerID, fromConnector: divOut, toModule: sequencerID, toConnector: seqClk,
                         color: .yellow, area: .voice), slot: slot)
    }

    /// Sync → Rst (the pattern restarts every bar) or off. ClkGen's "Sync every" is set to the pattern's length
    /// in beats when that is one of its choices (1, 2, 4 … 32).
    private func setRestart(_ on: Bool, slot: Int, clockID: Int, sequencerID: Int, updateBeatSync: Bool, keysReset: Bool) {
        guard let seqRst = Self.input(Self.noteSequencerTypeID, "Rst"),
              let sync = Self.output(Self.clockGeneratorTypeID, "Sync") else { return }
        for cable in slots[slot].cables(in: .voice) where cable.toModule == sequencerID && cable.toConnector == seqRst {
            removeCable(cable)
        }
        if on {
            addCable(G2Cable(fromModule: clockID, fromConnector: sync, toModule: sequencerID, toConnector: seqRst,
                             color: .yellow, area: .voice), slot: slot)
            if updateBeatSync, let beatSync = Self.param(Self.clockGeneratorTypeID, "BeatSync"),
               let raw = beatSyncRaw(slot: slot, sequencerID: sequencerID)
            {
                writeEverywhere(slot: slot, area: .voice, moduleID: clockID, values: [beatSync: raw])
            }
        } else if keysReset, let keyboardID = keyboard(in: slot)?.id {
            addCable(G2Cable(fromModule: keyboardID, fromConnector: 1, toModule: sequencerID, toConnector: seqRst,
                             color: .yellow, area: .voice), slot: slot)
        }
    }

    /// ClkGen BeatSync choice (0…5 = 1, 2, 4, 8, 16, 32 beats) for the sequencer's pattern, `nil` when the pattern
    /// does not last a whole number of those beats.
    private func beatSyncRaw(slot: Int, sequencerID: Int) -> Int? {
        guard let module = slots[slot].modules(in: .voice).first(where: { $0.id == sequencerID }),
              let layout = SequencerLayout(typeID: module.typeID),
              let step = sequencerClock(slot: slot, area: .voice, sequencerID: sequencerID)?.step else { return nil }
        let length = layout.lengthIndex.flatMap { module.parameters.indices.contains($0) ? module.parameters[$0] + 1 : nil } ?? 16
        let beats = Double(length) * step.beats
        return [1.0, 2, 4, 8, 16, 32].firstIndex(of: beats)
    }

    /// The clock behind a sequencer: ClkGen 1/16, or ClkGen 1/96 through a ClkDiv.
    func sequencerClock(slot: Int, area: PatchArea, sequencerID: Int) -> SequencerClockInfo? {
        guard slots.indices.contains(slot),
              let sequencer = slots[slot].modules(in: area).first(where: { $0.id == sequencerID }),
              let seqClk = Self.input(sequencer.typeID, "Clk") else { return nil }
        let modules = slots[slot].modules(in: area)
        let cables = slots[slot].cables(in: area)
        guard let feed = cables.first(where: { $0.toModule == sequencerID && $0.toConnector == seqClk && $0.sourceIsOutput }),
              let source = modules.first(where: { $0.id == feed.fromModule }) else { return nil }
        var clock: G2Module?
        var step: SequencerStep?
        if source.typeID == Self.clockGeneratorTypeID {
            clock = source
            step = feed.fromConnector == Self.output(Self.clockGeneratorTypeID, "1/16") ? .sixteenth : nil
        } else if source.typeID == Self.clockDividerTypeID,
                  let divClk = Self.input(Self.clockDividerTypeID, "Clk"),
                  let into = cables.first(where: { $0.toModule == source.id && $0.toConnector == divClk && $0.sourceIsOutput }),
                  let generator = modules.first(where: { $0.id == into.fromModule && $0.typeID == Self.clockGeneratorTypeID }),
                  into.fromConnector == Self.output(Self.clockGeneratorTypeID, "1/96"),
                  let divider = Self.param(Self.clockDividerTypeID, "Divider"), source.parameters.indices.contains(divider)
        {
            clock = generator
            step = SequencerStep(rawValue: source.parameters[divider] + 1)
        }
        guard let clock else {
            return SequencerClockInfo(clockID: nil, clockName: Self.name(of: source), followsTopBar: false,
                                      step: nil, restartsEveryBar: false)
        }
        let seqRst = Self.input(sequencer.typeID, "Rst")
        let restarts = cables.contains {
            $0.toModule == sequencerID && $0.toConnector == seqRst && $0.fromModule == clock.id
                && $0.fromConnector == Self.output(Self.clockGeneratorTypeID, "Sync")
        }
        let master = clock.parameters.indices.contains(ClockGenSettings.source) && clock.parameters[ClockGenSettings.source] != 0
        return SequencerClockInfo(clockID: clock.id, clockName: Self.name(of: clock), followsTopBar: master,
                                  step: step, restartsEveryBar: restarts)
    }

    /// The step length of a SeqNote clocked by a ClkGen. One ⌘Z.
    func setSequencerStep(_ step: SequencerStep, slot: Int, sequencerID: Int) {
        guard slot == selectedSlot, let info = sequencerClock(slot: slot, area: .voice, sequencerID: sequencerID),
              let clockID = info.clockID, info.step != step,
              let seqClk = Self.input(Self.noteSequencerTypeID, "Clk") else { return }
        undoManager.beginUndoGrouping()
        defer {
            undoManager.setActionName("Change Step Length")
            undoManager.endUndoGrouping()
        }
        let cables = slots[slot].cables(in: .voice)
        if let feed = cables.first(where: { $0.toModule == sequencerID && $0.toConnector == seqClk && $0.sourceIsOutput }) {
            removeCable(feed)
            // A divider that clocked only this sequencer goes too.
            let isDivider = slots[slot].modules(in: .voice).contains { $0.id == feed.fromModule && $0.typeID == Self.clockDividerTypeID }
            if isDivider, !cables.contains(where: { $0.fromModule == feed.fromModule && $0.sourceIsOutput && $0 != feed }) {
                deleteModule(moduleID: feed.fromModule, area: .voice)
            }
        }
        connectClock(slot: slot, clockID: clockID, sequencerID: sequencerID, step: step)
        if info.restartsEveryBar, let beatSync = Self.param(Self.clockGeneratorTypeID, "BeatSync"),
           let raw = beatSyncRaw(slot: slot, sequencerID: sequencerID)
        {
            writeEverywhere(slot: slot, area: .voice, moduleID: clockID, values: [beatSync: raw])
        }
    }

    /// Restart every bar on or off. With a held-key mode and restart off, the key restarts the pattern itself.
    func setSequencerRestart(_ on: Bool, slot: Int, sequencerID: Int) {
        guard slot == selectedSlot, let info = sequencerClock(slot: slot, area: .voice, sequencerID: sequencerID),
              let clockID = info.clockID, info.restartsEveryBar != on else { return }
        undoManager.beginUndoGrouping()
        defer {
            undoManager.setActionName(on ? "Restart Every Bar" : "Free-Running Pattern")
            undoManager.endUndoGrouping()
        }
        let usesKeys = sequencerPlayMode(slot: slot, area: .voice, sequencerID: sequencerID)?.usesKeys == true
        setRestart(on, slot: slot, clockID: clockID, sequencerID: sequencerID, updateBeatSync: true, keysReset: usesKeys)
    }

    /// Moves the sequencer to another ClkGen of the patch, or to a new one that follows the top bar. Keeps the step
    /// length and the restart. One ⌘Z.
    func setSequencerClock(_ choice: SequencerClockChoice, slot: Int, sequencerID: Int) {
        guard slot == selectedSlot, let info = sequencerClock(slot: slot, area: .voice, sequencerID: sequencerID),
              let seqClk = Self.input(Self.noteSequencerTypeID, "Clk") else { return }
        if case let .existing(id) = choice, id == info.clockID { return }
        undoManager.beginUndoGrouping()
        defer {
            undoManager.setActionName("Change Clock")
            undoManager.endUndoGrouping()
        }
        var newClock: Int?
        switch choice {
        case let .existing(id): newClock = id
        case .newFollowingTopBar, .newOwnTempo:
            newClock = addModule(typeID: Self.clockGeneratorTypeID, area: .voice)
            if let newClock {
                writeEverywhere(slot: slot, area: .voice, moduleID: newClock,
                                values: [ClockGenSettings.source: choice == .newFollowingTopBar ? 1 : 0])
            }
        }
        guard let newClock else { return }
        let cables = slots[slot].cables(in: .voice)
        if let feed = cables.first(where: { $0.toModule == sequencerID && $0.toConnector == seqClk && $0.sourceIsOutput }) {
            removeCable(feed)
            let isDivider = slots[slot].modules(in: .voice).contains { $0.id == feed.fromModule && $0.typeID == Self.clockDividerTypeID }
            if isDivider, !cables.contains(where: { $0.fromModule == feed.fromModule && $0.sourceIsOutput && $0 != feed }) {
                deleteModule(moduleID: feed.fromModule, area: .voice)
            }
        }
        connectClock(slot: slot, clockID: newClock, sequencerID: sequencerID, step: info.step ?? .sixteenth)
        if info.restartsEveryBar {
            setRestart(true, slot: slot, clockID: newClock, sequencerID: sequencerID, updateBeatSync: false, keysReset: false)
        }
        // A held-key mode: the key restarts the new clock.
        if sequencerPlayMode(slot: slot, area: .voice, sequencerID: sequencerID)?.usesKeys == true,
           let keyboardID = keyboard(in: slot)?.id, let clockRst = Self.input(Self.clockGeneratorTypeID, "Rst"),
           !slots[slot].cables(in: .voice).contains(where: { $0.toModule == newClock && $0.toConnector == clockRst })
        {
            addCable(G2Cable(fromModule: keyboardID, fromConnector: 1, toModule: newClock, toConnector: clockRst,
                             color: .yellow, area: .voice), slot: slot)
        }
    }

    // MARK: - Play mode of an existing sequencer

    /// The logic Gate fed by this sequencer's Trig and the keyboard's Gate (the held-key modes), if any.
    private func keyAndGate(slot: Int, sequencerID: Int) -> G2Module? {
        guard let trigOut = Self.output(Self.noteSequencerTypeID, "Trig") else { return nil }
        let patch = slots[slot]
        let cables = patch.cables(in: .voice)
        let keyboards = Set(patch.modules(in: .voice).filter { Self.sequencerKeyboardTypeIDs.contains($0.typeID) }.map(\.id))
        return patch.modules(in: .voice).first { module in
            guard module.typeID == Self.logicGateTypeID else { return false }
            let into = cables.filter { $0.toModule == module.id && $0.sourceIsOutput }
            return into.contains { $0.fromModule == sequencerID && $0.fromConnector == trigOut }
                && into.contains { keyboards.contains($0.fromModule) && $0.fromConnector == 1 }
        }
    }

    /// How a SeqNote plays, read from its cables; `nil` when it is wired some other way (Custom).
    func sequencerPlayMode(slot: Int, area: PatchArea, sequencerID: Int) -> SequencerPlayMode? {
        guard area == .voice, slots.indices.contains(slot),
              slots[slot].modules(in: .voice).contains(where: { $0.id == sequencerID && $0.typeID == Self.noteSequencerTypeID }),
              let noteOut = Self.output(Self.noteSequencerTypeID, "Note"),
              let trigOut = Self.output(Self.noteSequencerTypeID, "Trig") else { return nil }
        let cables = slots[slot].cables(in: .voice)
        let modules = slots[slot].modules(in: .voice)
        let noteUsed = cables.contains { $0.fromModule == sequencerID && $0.fromConnector == noteOut && $0.sourceIsOutput }
        if keyAndGate(slot: slot, sequencerID: sequencerID) != nil {
            return noteUsed ? .heldKeys : .rhythmOnKeys
        }
        let gatesEnvelope = cables.contains { cable in
            cable.fromModule == sequencerID && cable.fromConnector == trigOut && cable.sourceIsOutput
                && modules.contains { $0.id == cable.toModule && Self.isEnvelope($0.typeID) && Self.input($0.typeID, "Gate") == cable.toConnector }
        }
        return noteUsed && gatesEnvelope ? .byItself : nil
    }

    /// Rewires a sequencer for another play mode, keeping what it drives. One ⌘Z.
    func setSequencerPlayMode(_ mode: SequencerPlayMode, slot: Int, sequencerID: Int) {
        guard slot == selectedSlot, let current = sequencerPlayMode(slot: slot, area: .voice, sequencerID: sequencerID),
              current != mode,
              let noteOut = Self.output(Self.noteSequencerTypeID, "Note"),
              let trigOut = Self.output(Self.noteSequencerTypeID, "Trig"),
              let seqRst = Self.input(Self.noteSequencerTypeID, "Rst") else { return }
        let patch = slots[slot]
        let modules = patch.modules(in: .voice)
        let cables = patch.cables(in: .voice)
        let andGate = keyAndGate(slot: slot, sequencerID: sequencerID)
        let levelAdd = modules.first { module in
            module.typeID == Self.levelAddTypeID
                && cables.contains { $0.fromModule == sequencerID && $0.fromConnector == noteOut && $0.toModule == module.id }
        }
        // What the note reached: an oscillator's own Pitch, or a mixer whose output goes into one.
        let noteSources = Set([sequencerID, levelAdd?.id].compactMap(\.self))
        var pitchTargets = Set<Int>()
        for cable in cables where noteSources.contains(cable.fromModule) && cable.sourceIsOutput && cable.toModule != levelAdd?.id {
            guard cable.fromModule != sequencerID || cable.fromConnector == noteOut,
                  let destination = modules.first(where: { $0.id == cable.toModule }) else { continue }
            if Self.input(destination.typeID, "Pitch") == cable.toConnector, Self.param(destination.typeID, "Kbt") != nil {
                pitchTargets.insert(destination.id)
            } else {
                for out in cables where out.fromModule == destination.id && out.sourceIsOutput {
                    if let osc = modules.first(where: { $0.id == out.toModule }),
                       Self.input(osc.typeID, "Pitch") == out.toConnector, Self.param(osc.typeID, "Kbt") != nil
                    {
                        pitchTargets.insert(osc.id)
                    }
                }
            }
        }
        if pitchTargets.isEmpty { pitchTargets = Set(addSequencerChoices(slot: slot).oscillators.map(\.id)) }
        // What the step reached: envelopes' Gate and anything else.
        let gateFrom = andGate.map { ($0.id, Self.output(Self.logicGateTypeID, "Out1") ?? 0) } ?? (sequencerID, trigOut)
        var gateTargets = Set<Int>()
        var extra: [(module: Int, connector: Int)] = []
        for cable in cables where cable.fromModule == gateFrom.0 && cable.fromConnector == gateFrom.1 && cable.sourceIsOutput {
            if cable.toModule == andGate?.id { continue }
            if let destination = modules.first(where: { $0.id == cable.toModule }), Self.isEnvelope(destination.typeID),
               Self.input(destination.typeID, "Gate") == cable.toConnector
            {
                gateTargets.insert(destination.id)
            } else {
                extra.append((cable.toModule, cable.toConnector))
            }
        }

        undoManager.beginUndoGrouping()
        defer {
            undoManager.setActionName("Change Play Mode")
            undoManager.endUndoGrouping()
        }
        // Take the old wiring apart: helpers, the note and step cables, the key's restart cables.
        let helpers = Set([andGate?.id, levelAdd?.id].compactMap(\.self))
        if !helpers.isEmpty { deleteModules(moduleIDs: helpers, area: .voice) }
        let info = sequencerClock(slot: slot, area: .voice, sequencerID: sequencerID)
        let keyboardID = keyboard(in: slot)?.id
        for cable in slots[slot].cables(in: .voice) {
            let fromSequencer = cable.fromModule == sequencerID && cable.sourceIsOutput
                && (cable.fromConnector == noteOut || cable.fromConnector == trigOut)
            let keyRestart = current.usesKeys && cable.fromModule == keyboardID && cable.fromConnector == 1
                && ((cable.toModule == info?.clockID && cable.toConnector == Self.input(Self.clockGeneratorTypeID, "Rst"))
                    || (cable.toModule == sequencerID && cable.toConnector == seqRst))
            if fromSequencer || keyRestart { removeCable(cable) }
        }
        wire(slot: slot, sequencerID: sequencerID, clockID: info?.clockID, mode: mode,
             pitchTargets: pitchTargets, gateTargets: gateTargets, extraGateConsumers: extra)
        applyVoiceMode(for: mode, slot: slot)
    }
}
