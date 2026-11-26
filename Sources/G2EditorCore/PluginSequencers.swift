// PluginSequencers.swift
// Sekwencery rysowane ołówkiem w oknie wtyczki DAW-a (Etap 5, plan: Docs/Plan projektu/
// 05-wtyczka-funkcje.md §2.5).
//
// Pięć modułów strony „Seq" ma ten sam układ kroków co w oryginalnym edytorze
// ([[Docs/ui/sequencer-group-audit]]): parametry 0–15 to tor 1 (nuta, poziom albo wł/wył),
// 16–31 tor 2 (wł/wył), a SeqNote, SeqEvent, SeqVal i SeqLev mają `Length` pod numerem 33
// (0…15 = 1…16 kroków). SeqCtr nie ma długości — gra zawsze 16.
//
// Rysowanie to zwykła edycja patcha (Undo, „Save changes?") — w odróżnieniu od automatyki
// DAW-a to użytkownik zmienia wzór sekwencji.

import Foundation
import G2Core

public enum PluginSequencers {
    /// Rodzaj toru 1: nuty (SeqNote), poziomy (SeqVal/SeqLev/SeqCtr) albo zdarzenia wł/wył (SeqEvent).
    public enum Kind: String {
        case note, level, event
    }

    static let kinds: [Int: Kind] = [121: .note, 144: .event, 145: .level, 146: .level, 154: .level]
    static let stepCount = 16
    static let lengthParam = 33
    /// `Loop` — parametr 32 (nie ma go SeqCtr).
    static let loopParam = 32
    /// `BipUni` — numer parametru w modułach, które go mają (0 = bipolarny).
    static let bipolarParams: [Int: Int] = [145: 34, 146: 34, 154: 33]

    /// Własny wzór użytkownika na liście okna wtyczki.
    public struct Mine: Equatable {
        public var id: String
        public var name: String
    }

    /// Sekwencer slotu tak, jak zobaczy go okno wtyczki.
    public struct Sequencer: Equatable {
        public var location: Int
        public var moduleID: Int
        public var kind: Kind
        public var name: String
        public var steps: [Int]
        public var texts: [String]
        public var gates: [Int]
        public var length: Int
        /// SeqCtr nie ma parametru długości.
        public var hasLength: Bool
        public var bipolar: Bool
        /// Własne wzory użytkownika (Presets ▸ My patterns w edytorze) pasujące do tego rodzaju: id i nazwa.
        public var mine: [Mine] = []
        /// Loop (parametr 32); `nil` = moduł go nie ma (SeqCtr gra zawsze w pętli).
        public var loop: Bool?
        /// Dokąd idą kable wyjściowe: „Moduł · Wejście” (pierwszy i licznik reszty), puste = brak kabla.
        public var target = ""
        /// Skąd idzie zegar: „Clock: nazwa” albo „No clock”.
        public var clock = ""

        var json: [String: Any] {
            var result: [String: Any] = [
                "location": location, "module": moduleID, "kind": kind.rawValue, "name": name, "steps": steps,
                "texts": texts, "gates": gates, "length": length, "hasLength": hasLength, "bipolar": bipolar,
                "presets": PluginSequencers.presetNames(kind),
                "mine": mine.map { ["id": $0.id, "name": $0.name] }, "target": target, "clock": clock,
            ]
            if let loop { result["loop"] = loop ? 1 : 0 }
            return result
        }
    }

    /// Nazwy gotowych wzorów dla rodzaju sekwencera (menu Presets w oknie wtyczki): figury nutowe, krzywe, rytmy.
    static func presets(_ kind: Kind) -> [SequencePresets.Preset] {
        switch kind {
        case .note: SequencePresets.figures
        case .level: SequencePresets.curves
        case .event: SequencePresets.rhythms
        }
    }

    static func presetNames(_ kind: Kind) -> [String] {
        presets(kind).map(\.name)
    }

    /// Gotowy wzór z okna wtyczki (Presets): figura nutowa od nuty `root` (MIDI), krzywa albo rytm — jak menu Presets
    /// w oknie Sequencers edytora. Jeden krok Undo; rytm (SeqEvent) wpisuje oba tory.
    @MainActor
    public static func preset(_ state: PatchState, slot: Int, location: Int, moduleID: Int, name: String, root: Int, locked: Set<Int> = []) {
        guard state.slots.indices.contains(slot), let area = PatchArea(rawValue: UInt8(clamping: location)),
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == moduleID }),
              let kind = kinds[module.typeID], module.parameters.count >= stepCount * 2,
              let preset = presets(kind).first(where: { $0.name == name }), (0 ... 127).contains(root)
        else { return }
        var writes: [(param: Int, value: Int)] = []
        switch kind {
        case .note:
            writes = SequencePresets.notes(of: preset, base: root).enumerated().map { ($0.offset, $0.element) }
        case .level:
            writes = preset.steps.enumerated().map { ($0.offset, $0.element) }
        case .event:
            writes = preset.steps.enumerated().map { ($0.offset, $0.element) }
                + preset.second.enumerated().map { ($0.offset + stepCount, $0.element) }
        }
        state.beginParameterGesture()
        for write in writes where write.param < module.parameters.count && write.value != module.parameters[write.param]
            && !locked.contains(write.param % stepCount)
        {
            draw(state, slot: slot, location: location, moduleID: moduleID, param: write.param, value: write.value)
        }
        state.endParameterGesture()
    }

    /// Wszystkie sekwencery slotu, głosy przed efektami, w kolejności modułów w patchu.
    @MainActor
    public static func snapshot(_ state: PatchState, slot: Int,
                                library: SequenceUserLibrary = SequenceUserLibrary()) -> [Sequencer]
    {
        guard state.slots.indices.contains(slot) else { return [] }
        let patch = state.slots[slot]
        var result: [Sequencer] = []
        for area in [PatchArea.voice, .fx] {
            let edges = G2SignalGraph(patch: patch, area: area).edges
            let groups = SequencerClockGroup.groups(in: patch, area: area)
            for module in patch.modules(in: area) {
                guard let kind = kinds[module.typeID], module.parameters.count >= stepCount * 2 else { continue }
                let steps = Array(module.parameters[0 ..< stepCount])
                let texts = steps.indices.map {
                    G2ParameterText.value(paramIndex: $0, value: steps[$0], module: module)
                }
                let hasLength = module.typeID != 154 && module.parameters.count > lengthParam
                let length = hasLength ? min(max(module.parameters[lengthParam] + 1, 1), stepCount) : stepCount
                let bipolar = bipolarParams[module.typeID].map {
                    module.parameters.indices.contains($0) && module.parameters[$0] == 0
                } ?? false
                let name = module.label.isEmpty
                    ? (ModuleDatabase.module(id: module.typeID)?.shortName ?? "Seq \(module.id)") : module.label
                let loop = module.typeID == 154 ? nil : Optional(module.parameters[loopParam] != 0)
                let clockID = groups.first { $0.sequencerIDs.contains(module.id) }?.clockModuleID
                let clockModule = clockID.flatMap { id in patch.modules(in: area).first { $0.id == id } }
                var sequencer = Sequencer(location: Int(area.rawValue), moduleID: module.id, kind: kind, name: name,
                                          steps: steps, texts: texts,
                                          gates: Array(module.parameters[stepCount ..< stepCount * 2]),
                                          length: length, hasLength: hasLength, bipolar: bipolar,
                                          mine: library.patterns(in: .init(kind: layoutKind(kind)))
                                              .map { Mine(id: $0.id.uuidString, name: $0.name) })
                sequencer.loop = loop
                sequencer.target = targetText(of: module.id, edges: edges, modules: patch.modules(in: area))
                sequencer.clock = clockModule.map { "Clock: " + displayName($0) } ?? "No clock"
                result.append(sequencer)
            }
        }
        return result
    }

    private static func displayName(_ module: G2Module) -> String {
        module.label.isEmpty ? (ModuleDatabase.module(id: module.typeID)?.shortName ?? "Module") : module.label
    }

    /// Jak w oknie edytora (chip pod nazwą ścieżki): „Moduł · Wejście” i „+N” dla pozostałych kabli.
    static func targetText(of id: Int, edges: [G2SignalGraph.Edge], modules: [G2Module]) -> String {
        let targets: [String] = edges.filter { $0.fromModule == id }.compactMap { edge in
            guard let destination = modules.first(where: { $0.id == edge.toModule }) else { return nil }
            let def = ModuleDatabase.module(id: destination.typeID)
            let input = def.flatMap { $0.inputs.indices.contains(edge.toInput) ? $0.inputs[edge.toInput].name : nil }
            return input.map { "\(displayName(destination)) · \($0)" } ?? displayName(destination)
        }
        guard let first = targets.first else { return "" }
        return targets.count == 1 ? first : "\(first) +\(targets.count - 1)"
    }

    /// Bieżący krok każdego sekwencera slotu ze strumienia diod (wartość 0…długość−1 = krok; inaczej −1 = stoi).
    @MainActor
    static func playheads(_ state: PatchState, slot: Int, ledGroups: [G2LedGroupReading])
        -> [(location: Int, module: Int, step: Int)]
    {
        guard state.slots.indices.contains(slot) else { return [] }
        let patch = state.slots[slot]
        var result: [(location: Int, module: Int, step: Int)] = []
        for area in [PatchArea.voice, .fx] {
            for module in patch.modules(in: area) where kinds[module.typeID] != nil {
                let hasLength = module.typeID != 154 && module.parameters.count > lengthParam
                let length = hasLength ? min(max(module.parameters[lengthParam] + 1, 1), stepCount) : stepCount
                let value = ledGroups.first { $0.area == area && $0.moduleID == module.id }?.value
                let step = value.flatMap { (0 ..< length).contains($0) ? $0 : nil } ?? -1
                result.append((Int(area.rawValue), module.id, step))
            }
        }
        return result
    }

    /// Rodzaj toru okna wtyczki → rodzaj układu sekwencera (kategoria własnych wzorów jak w oknie edytora).
    private static func layoutKind(_ kind: Kind) -> SequencerLayout.Kind {
        switch kind {
        case .note: .note
        case .level: .value
        case .event: .event
        }
    }

    /// Rhythm bank z okna wtyczki: wzór `index` z banku (122 rytmy) — SeqEvent: tor Trig 1, inne sekwencery: tor
    /// Gate (wartości zostają). Zablokowane kroki zostają. Jeden krok Undo.
    @MainActor
    public static func rhythm(_ state: PatchState, slot: Int, location: Int, moduleID: Int, index: Int,
                              locked: Set<Int> = [])
    {
        guard state.slots.indices.contains(slot), let area = PatchArea(rawValue: UInt8(clamping: location)),
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == moduleID }),
              let kind = kinds[module.typeID], module.parameters.count >= stepCount * 2
        else { return }
        let flags = SequenceRhythmBank.flags(at: index)
        guard flags.count == stepCount else { return }
        let start = kind == .event ? 0 : stepCount
        state.beginParameterGesture()
        for (step, flag) in flags.enumerated() where !locked.contains(step) && module.parameters[start + step] != flag {
            draw(state, slot: slot, location: location, moduleID: moduleID, param: start + step, value: flag)
        }
        state.endParameterGesture()
    }

    /// Zapisuje wzór, który trzyma moduł (tor 1, tor 2 i długość), na liście własnych wzorów; zwraca `false`, gdy
    /// nazwa jest pusta albo to nie jest sekwencer.
    @MainActor
    @discardableResult
    public static func saveUserPattern(_ state: PatchState, slot: Int, location: Int, moduleID: Int, name: String,
                                       into library: inout SequenceUserLibrary) -> Bool
    {
        guard state.slots.indices.contains(slot), let area = PatchArea(rawValue: UInt8(clamping: location)),
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == moduleID }),
              let kind = kinds[module.typeID], module.parameters.count >= stepCount * 2 else { return false }
        let hasLength = module.typeID != 154 && module.parameters.count > lengthParam
        let length = hasLength ? min(max(module.parameters[lengthParam] + 1, 1), stepCount) : nil
        return library.save(name: name, category: .init(kind: layoutKind(kind)),
                            values: Array(module.parameters[0 ..< stepCount]),
                            gates: Array(module.parameters[stepCount ..< stepCount * 2]), length: length) != nil
    }

    /// Wczytuje własny wzór: oba tory i długość w miejsce wzoru modułu (zablokowane kroki zostają). Wzór innego
    /// rodzaju sekwencera jest ignorowany. Jeden krok Undo.
    @MainActor
    public static func applyUserPattern(_ state: PatchState, slot: Int, location: Int, moduleID: Int,
                                        pattern: SequenceUserPattern, locked: Set<Int> = [])
    {
        guard state.slots.indices.contains(slot), let area = PatchArea(rawValue: UInt8(clamping: location)),
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == moduleID }),
              let kind = kinds[module.typeID], module.parameters.count >= stepCount * 2,
              pattern.category == .init(kind: layoutKind(kind)),
              pattern.values.count == stepCount, pattern.gates.count == stepCount else { return }
        var writes: [(param: Int, value: Int)] = []
        for step in 0 ..< stepCount where !locked.contains(step) {
            writes.append((step, pattern.values[step]))
            writes.append((stepCount + step, pattern.gates[step]))
        }
        if let length = pattern.length, module.typeID != 154, module.parameters.count > lengthParam {
            writes.append((lengthParam, length - 1))
        }
        state.beginParameterGesture()
        for write in writes where module.parameters[write.param] != write.value {
            draw(state, slot: slot, location: location, moduleID: moduleID, param: write.param, value: write.value)
        }
        state.endParameterGesture()
    }

    /// Arpeggio z okna wtyczki: akord `chord` zbudowany od nuty `root` (MIDI), kierunek i liczba oktaw,
    /// zapisane jako 16 nut toru 1 SeqNote — jeden krok Undo, tak jak generator w oknie Sequencers edytora.
    @MainActor
    public static func arpeggio(_ state: PatchState, slot: Int, location: Int, moduleID: Int, root: Int,
                                chord: String, direction: String, octaves: Int, scale: String = "major", locked: Set<Int> = [])
    {
        guard state.slots.indices.contains(slot), let area = PatchArea(rawValue: UInt8(clamping: location)),
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == moduleID }),
              kinds[module.typeID] == .note, module.parameters.count > lengthParam,
              let order = ArpeggioDirection(rawValue: direction), (0 ... 127).contains(root)
        else { return }
        let chordNotes: [Int]
        if chord == "pattern" {
            // The different notes the pattern already plays (its first Length steps).
            let length = min(max(module.parameters[lengthParam] + 1, 1), stepCount)
            chordNotes = Array(module.parameters[0 ..< length])
        } else if let type = ChordType(rawValue: chord) {
            chordNotes = SequenceArpeggio.notes(of: type, root: root)
        } else if chord.hasPrefix("degree"), let degree = Int(chord.split(separator: ":").last ?? ""),
                  let musicalScale = MusicalScale(rawValue: scale)
        {
            // Thirds stacked on a degree of the scale (three notes, "degree7:" four), counted from `root`.
            let top = SequenceArpeggio.degreeCount(of: musicalScale) - 1
            chordNotes = SequenceArpeggio.scaleChord(degree: min(max(degree, 0), top), seventh: chord.hasPrefix("degree7"),
                                                     scale: musicalScale, root: root % 12, base: root)
        } else {
            return
        }
        var generator = SystemRandomNumberGenerator()
        let notes = SequenceArpeggio.steps(chord: chordNotes, direction: order, octaves: octaves, using: &generator)
        guard notes.count == stepCount else { return }
        state.beginParameterGesture()
        for (step, note) in notes.enumerated() where !locked.contains(step) {
            draw(state, slot: slot, location: location, moduleID: moduleID, param: step, value: note)
        }
        state.endParameterGesture()
    }

    /// Random i Mutate z okna wtyczki dla SeqNote — jak w oknie Sequencers edytora: `random` losuje wszystkie
    /// 16 nut ze skali `scale` w zakresie `low…high`, `mutate` zmienia `percent` % kroków w długości sekwencera
    /// (nowe nuty z tej samej skali). Jeden krok Undo, bramki nietknięte.
    @MainActor
    public static func randomNotes(_ state: PatchState, slot: Int, location: Int, moduleID: Int, mode: String,
                                   root: Int, scale: String, range: ClosedRange<Int>, percent: Int, locked: Set<Int> = [])
    {
        guard state.slots.indices.contains(slot), let area = PatchArea(rawValue: UInt8(clamping: location)),
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == moduleID }),
              kinds[module.typeID] == .note, module.parameters.count > lengthParam,
              ["random", "mutate", "walk", "motif", "markov"].contains(mode), let musicalScale = MusicalScale(rawValue: scale),
              range.lowerBound >= 0, range.upperBound <= 127, range.lowerBound < range.upperBound
        else { return }
        let candidates = musicalScale.notes(in: range, root: root)
        guard !candidates.isEmpty else { return }
        var generator = SystemRandomNumberGenerator()
        let current = Array(module.parameters[0 ..< stepCount])
        let length = min(max(module.parameters[lengthParam] + 1, 1), stepCount)
        let notes: [Int]
        if mode == "random" {
            notes = (0 ..< stepCount).map { _ in candidates.randomElement(using: &generator) ?? 64 }
        } else if mode == "walk" || mode == "motif" || mode == "markov" {
            // Generate ▸ Walk (small steps along the scale), ▸ Motif (a short figure, repeated with variations)
            // and ▸ Markov (a new melody from the notes of the current pattern and the moves between them).
            let generate: SequenceGenerator = mode == "walk" ? .walk : (mode == "motif" ? .motif : .markov)
            notes = generate.notes(current: current, length: length, range: range,
                                   scale: musicalScale, root: root, using: &generator)
        } else {
            let steps = SequencePattern.mutationSteps(length: length, percent: min(max(percent, 0), 100),
                                                      locked: locked, using: &generator)
            notes = SequencePattern.replaced(current, at: steps) { candidates.randomElement(using: &generator) ?? 64 }
        }
        state.beginParameterGesture()
        for (step, note) in notes.enumerated() where note != current[step] && !locked.contains(step) {
            draw(state, slot: slot, location: location, moduleID: moduleID, param: step, value: note)
        }
        state.endParameterGesture()
    }

    /// Curve z okna wtyczki dla SeqVal / SeqLev / SeqCtr: kształt `shape` (rawValue SequenceCurve) rozłożony na
    /// kroki w długości sekwencera, `cycles` razy (1–4), między `low` a `high` % zakresu. Jeden krok Undo.
    @MainActor
    public static func curve(_ state: PatchState, slot: Int, location: Int, moduleID: Int, shape: String,
                             cycles: Int, low: Int, high: Int, locked: Set<Int> = [])
    {
        guard state.slots.indices.contains(slot), let area = PatchArea(rawValue: UInt8(clamping: location)),
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == moduleID }),
              kinds[module.typeID] == .level, module.parameters.count >= stepCount * 2,
              let curve = SequenceCurve(rawValue: shape)
        else { return }
        let hasLength = module.typeID != 154 && module.parameters.count > lengthParam
        let length = hasLength ? min(max(module.parameters[lengthParam] + 1, 1), stepCount) : stepCount
        var generator = SystemRandomNumberGenerator()
        let values = curve.values(length: length, cycles: min(max(cycles, 1), 4), phase: 0,
                                  low: min(max(low, 0), 100), high: min(max(high, 0), 100), using: &generator)
        let current = Array(module.parameters[0 ..< stepCount])
        guard values.count == stepCount else { return }
        state.beginParameterGesture()
        for (step, value) in values.enumerated() where value != current[step] && !locked.contains(step) {
            draw(state, slot: slot, location: location, moduleID: moduleID, param: step, value: value)
        }
        state.endParameterGesture()
    }

    /// Losowe włączanie kroków z okna wtyczki. SeqEvent: oba tory (Trig 1 i Trig 2); pozostałe sekwencery: tor
    /// „Gate” (wartości zostają). `random` = każdy krok gra z szansą `density` %, `mutate` (tylko SeqEvent) =
    /// odwraca `percent` % kroków w długości sekwencera, osobno w każdym torze. Jeden krok Undo.
    @MainActor
    public static func gates(_ state: PatchState, slot: Int, location: Int, moduleID: Int, mode: String,
                             density: Int, percent: Int, locked: Set<Int> = [])
    {
        guard state.slots.indices.contains(slot), let area = PatchArea(rawValue: UInt8(clamping: location)),
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == moduleID }),
              let kind = kinds[module.typeID], module.parameters.count >= stepCount * 2,
              mode == "random" || (mode == "mutate" && kind == .event)
        else { return }
        let rows = kind == .event ? [0, stepCount] : [stepCount]
        let hasLength = module.typeID != 154 && module.parameters.count > lengthParam
        let length = hasLength ? min(max(module.parameters[lengthParam] + 1, 1), stepCount) : stepCount
        var generator = SystemRandomNumberGenerator()
        state.beginParameterGesture()
        for start in rows {
            let current = Array(module.parameters[start ..< start + stepCount])
            let next: [Int]
            if mode == "random" {
                next = SequencePattern.randomGates(density: Double(min(max(density, 0), 100)) / 100, using: &generator)
            } else {
                let steps = SequencePattern.mutationSteps(length: length, percent: min(max(percent, 0), 100),
                                                          locked: locked, using: &generator)
                next = SequencePattern.flippedGates(current, at: steps)
            }
            for (step, value) in next.enumerated() where value != current[step] && !locked.contains(step) {
                draw(state, slot: slot, location: location, moduleID: moduleID, param: start + step, value: value)
            }
        }
        state.endParameterGesture()
    }

    /// Humanize z okna wtyczki dla SeqVal / SeqLev / SeqCtr: każdy grany krok dostaje drobne losowe drgnięcie
    /// wartości (do `amount` % zakresu), pauzy i kroki za długością zostają. Jeden krok Undo.
    @MainActor
    public static func humanize(_ state: PatchState, slot: Int, location: Int, moduleID: Int, amount: Int, locked: Set<Int> = []) {
        guard state.slots.indices.contains(slot), let area = PatchArea(rawValue: UInt8(clamping: location)),
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == moduleID }),
              kinds[module.typeID] == .level, module.parameters.count >= stepCount * 2
        else { return }
        let hasLength = module.typeID != 154 && module.parameters.count > lengthParam
        let length = hasLength ? min(max(module.parameters[lengthParam] + 1, 1), stepCount) : stepCount
        let current = Array(module.parameters[0 ..< stepCount])
        var generator = SystemRandomNumberGenerator()
        let jittered = SequenceHumanize.jittered(current, playing: module.parameters[stepCount ..< stepCount * 2].map { $0 != 0 },
                                                 length: length, amount: min(max(amount, 0), 100), using: &generator)
        state.beginParameterGesture()
        for (step, value) in jittered.enumerated() where value != current[step] && !locked.contains(step) {
            draw(state, slot: slot, location: location, moduleID: moduleID, param: step, value: value)
        }
        state.endParameterGesture()
    }

    /// Krok narysowany w oknie wtyczki. Tylko kroki (0–31) i długość — reszta modułu to nie ołówek.
    @MainActor
    public static func draw(_ state: PatchState, slot: Int, location: Int, moduleID: Int, param: Int, value: Int) {
        guard state.slots.indices.contains(slot), let area = PatchArea(rawValue: UInt8(clamping: location)),
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == moduleID }),
              kinds[module.typeID] != nil,
              (0 ..< stepCount * 2).contains(param) || ((param == lengthParam || param == loopParam) && module.typeID != 154)
        else { return }
        let maxValue = G2ParameterText.maxValue(moduleTypeID: module.typeID, paramIndex: param)
        state.setParameter(slot: slot, moduleID: moduleID, paramIndex: param,
                           value: min(max(value, 0), maxValue), area: area)
    }
}
