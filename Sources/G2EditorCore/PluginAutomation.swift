// PluginAutomation.swift
// Automatyka DAW-a dla wtyczki (Etap 4, plan: Docs/Plan projektu/05-wtyczka-funkcje.md §2.2).
//
// Stała lista parametrów jednego slotu, numerowana raz na zawsze (numer = część ID parametru
// we wtyczce, więc zmiana zepsułaby automatykę zapisaną w projektach):
//
//   0          Variation (0…7)
//   1…8        Morph Groups (0…127)
//   11…18      Patch Adjuster (−50…50)
//   21…28      gałki bieżącej strony parametrów (0…1 × zakres przypisanego parametru)
//   100…219    wszystkie 120 gałek stron (strona × 8 + gałka), stały adres
//   300…331    Learn: parametry przypisane ruchem („dotknij, żeby przypisać"); mapę trzyma wtyczka
//              w projekcie i przysyła edytorowi (`learn_map`)
//
// Wtyczka wysyła wartości w tych jednostkach (`automate`), edytor odsyła stan (`automation`)
// z nazwami i napisami wartości. Automatyka nie jest edycją patcha: bez undo i bez
// „Save changes?" (decyzja użytkownika 2026-09-25) — `PatchState.automate`.

import Foundation
import G2Core

public enum PluginAutomation {
    public static let variation = 0
    public static let morphs = 1 ... 8
    public static let adjusters = 11 ... 18
    public static let pageKnobs = 21 ... 28
    public static let allKnobs = 100 ... 219
    public static let learned = 300 ... 331

    /// Wszystkie numery listy, po kolei.
    public static let ids: [Int] = [variation] + Array(morphs) + Array(adjusters) + Array(pageKnobs)
        + Array(allKnobs) + Array(learned)

    /// Stan jednego parametru listy, tak jak zobaczy go DAW. `value` w jednostkach listy
    /// (gałki: 0…1). `name` pusta = nazwa stała, zna ją wtyczka; dla gałki pusta = gałka wolna.
    public struct Entry: Equatable {
        public var value: Double
        public var text: String
        public var name: String

        public init(value: Double, text: String, name: String = "") {
            self.value = value
            self.text = text
            self.name = name
        }
    }

    // MARK: - Stan slotu dla wtyczki

    /// Cała lista jednego slotu. Gałki bieżącej strony liczą się od strony wybranej w edytorze
    /// (i na panelu Norda) — edytor pamięta jedną stronę, tę slotu na ekranie, i ona obowiązuje
    /// wszystkie sloty.
    @MainActor
    public static func snapshot(_ state: PatchState, slot: Int,
                                learn: [Int: G2KnobAssignment] = [:]) -> [Int: Entry]
    {
        guard state.slots.indices.contains(slot) else { return [:] }
        let patch = state.slots[slot]
        let active = patch.activeVariation
        var entries: [Int: Entry] = [:]
        entries[variation] = Entry(value: Double(active), text: "\(active + 1)")
        for morph in 0 ..< G2Morph.count {
            let value = patch.morphDial(morph, in: active)
            entries[morphs.lowerBound + morph] = Entry(value: Double(value), text: "\(value)")
        }
        for (offset, knob) in G2AdjusterKnob.allCases.enumerated() {
            let value = slot == state.selectedSlot ? state.adjusterValue(knob) : 0
            entries[adjusters.lowerBound + offset] = Entry(value: Double(value), text: value > 0 ? "+\(value)" : "\(value)")
        }
        let page = state.patchParameterPage
        for index in 0 ..< G2KnobPages.knobCount {
            let entry = knobEntry(state, slot: slot, knob: index)
            entries[allKnobs.lowerBound + index] = entry
            if index / G2KnobPages.knobsPerPage == page {
                entries[pageKnobs.lowerBound + index % G2KnobPages.knobsPerPage] = entry
            }
        }
        for id in learned {
            entries[id] = entry(target(state, slot: slot, assignment: learn[id]))
        }
        return entries
    }

    /// Gałka strony: nazwa „Moduł Parametr", wartość 0…1 i napis jak w oknie Parameter Pages.
    @MainActor
    static func knobEntry(_ state: PatchState, slot: Int, knob index: Int) -> Entry {
        entry(knobTarget(state, slot: slot, knob: index))
    }

    private static func entry(_ target: KnobTarget?) -> Entry {
        guard let target else { return Entry(value: 0, text: "", name: "") }
        let value = min(max(target.value, 0), target.maxValue)
        return Entry(value: target.maxValue > 0 ? Double(value) / Double(target.maxValue) : 0,
                     text: target.text, name: target.name)
    }

    /// Na co wskazuje gałka strony — ta sama rozpiska co w oknie Parameter Pages
    /// (`ParameterPagePresentationResolver`), bez przedrostka slotu.
    enum KnobKind {
        case parameter(PatchArea, moduleID: Int, paramIndex: Int)
        case morphDial(Int)
        case morphSource(Int)
        case setting(G2PatchSetting)
    }

    struct KnobTarget {
        let kind: KnobKind
        /// Moduł i parametr osobno — ekraniki stron w oknie wtyczki piszą je w dwóch miejscach.
        let module: String
        let parameter: String
        let value: Int
        let maxValue: Int
        let text: String

        var name: String {
            "\(module) \(parameter)"
        }
    }

    /// Numer obszaru ustawień, w którym siedzą morfy (`PATCH_MORPH`).
    private static let morphSettingsModule = 1

    @MainActor
    static func knobTarget(_ state: PatchState, slot: Int, knob index: Int) -> KnobTarget? {
        guard state.slots.indices.contains(slot) else { return nil }
        return target(state, slot: slot, assignment: state.slots[slot].knobAssignment(at: index))
    }

    /// Parametr wskazany tak, jak wskazuje go gałka strony — gałki i Learn mówią tym samym językiem.
    @MainActor
    static func target(_ state: PatchState, slot: Int, assignment: G2KnobAssignment?) -> KnobTarget? {
        guard state.slots.indices.contains(slot), let assignment else { return nil }
        let patch = state.slots[slot]
        if let area = assignment.area {
            guard let module = patch.modules(in: area).first(where: { $0.id == assignment.moduleID }),
                  module.parameters.indices.contains(assignment.paramIndex) else { return nil }
            let moduleName = module.label.isEmpty
                ? (ModuleDatabase.module(id: module.typeID)?.shortName ?? "Module \(module.id)") : module.label
            let parameter = G2ParameterText.name(moduleTypeID: module.typeID, paramIndex: assignment.paramIndex)
            let value = module.parameters[assignment.paramIndex]
            return KnobTarget(kind: .parameter(area, moduleID: module.id, paramIndex: assignment.paramIndex),
                              module: moduleName, parameter: parameter, value: value,
                              maxValue: G2ParameterText.maxValue(moduleTypeID: module.typeID,
                                                                 paramIndex: assignment.paramIndex),
                              text: G2ParameterText.value(paramIndex: assignment.paramIndex, value: value,
                                                          module: module))
        }
        let variation = patch.activeVariation
        if assignment.moduleID == morphSettingsModule {
            let morph = assignment.paramIndex % G2Morph.count
            if assignment.paramIndex < G2Morph.count {
                let value = patch.morphDial(morph, in: variation)
                return KnobTarget(kind: .morphDial(morph), module: "Morph", parameter: G2Morph.names[morph],
                                  value: value, maxValue: 127, text: "\(value)")
            }
            guard assignment.paramIndex < G2Morph.count * 2 else { return nil }
            let options = G2Morph.sourceOptions(morph: morph)
            let value = min(patch.morphMode(morph, in: variation), options.count - 1)
            return KnobTarget(kind: .morphSource(morph), module: "Morph", parameter: "\(G2Morph.names[morph]) Src",
                              value: value, maxValue: options.count - 1, text: options[value])
        }
        guard let setting = G2PatchSetting.allCases.first(where: {
            $0.module == assignment.moduleID && $0.param == assignment.paramIndex
        }) else { return nil }
        let value = state.patchSetting(setting, slot: slot)
        return KnobTarget(kind: .setting(setting), module: "Patch", parameter: setting.label, value: value,
                          maxValue: 127, text: "\(value)")
    }

    // MARK: - Zmiana z DAW-a

    /// Jedna wartość z automatyki DAW-a. Droga do Norda ta sama, co ruch gałki w edytorze.
    /// Patch Adjuster działa na slocie na ekranie — tak jak jego gałki w edytorze.
    @MainActor
    public static func apply(_ state: PatchState, slot: Int, id: Int, value: Double,
                             learn: [Int: G2KnobAssignment] = [:])
    {
        guard state.slots.indices.contains(slot), value.isFinite else { return }
        state.automate(slot: slot) {
            switch id {
            case variation:
                state.selectVariation(min(max(Int(value.rounded()), 0), 7), slot: slot)
            case morphs:
                state.setMorphDial(id - morphs.lowerBound, value: Int(value.rounded()), slot: slot)
            case adjusters:
                guard slot == state.selectedSlot else { return }
                state.setAdjuster(G2AdjusterKnob.allCases[id - adjusters.lowerBound], to: Int(value.rounded()))
            case pageKnobs:
                let knob = state.patchParameterPage * G2KnobPages.knobsPerPage + id - pageKnobs.lowerBound
                setKnob(state, slot: slot, knob: knob, value: value)
            case allKnobs:
                setKnob(state, slot: slot, knob: id - allKnobs.lowerBound, value: value)
            case learned:
                set(target(state, slot: slot, assignment: learn[id]), state: state, slot: slot, value: value)
            default:
                break
            }
        }
    }

    @MainActor
    private static func setKnob(_ state: PatchState, slot: Int, knob: Int, value: Double) {
        set(knobTarget(state, slot: slot, knob: knob), state: state, slot: slot, value: value)
    }

    @MainActor
    static func set(_ target: KnobTarget?, state: PatchState, slot: Int, value: Double) {
        guard let target else { return }
        let raw = Int((min(max(value, 0), 1) * Double(target.maxValue)).rounded())
        switch target.kind {
        case let .parameter(area, moduleID, paramIndex):
            state.setParameter(slot: slot, moduleID: moduleID, paramIndex: paramIndex, value: raw, area: area)
        case let .morphDial(morph):
            state.setMorphDial(morph, value: raw, slot: slot)
        case let .morphSource(morph):
            state.setMorphMode(morph, value: raw, slot: slot)
        case let .setting(setting):
            state.setPatchSetting(setting, value: raw, slot: slot)
        }
    }
}

// MARK: - Learn

public extension PluginAutomation {
    /// Pierwszy parametr modułu, który różni się między dwoma stanami slotu — to nim ktoś
    /// właśnie ruszył (w edytorze albo na Nordzie). Inna wariacja albo inny zestaw modułów to
    /// nie ruch gałki: `nil`.
    static func touchedParameter(before: G2Patch, after: G2Patch) -> G2KnobAssignment? {
        guard before.activeVariation == after.activeVariation else { return nil }
        for area in [PatchArea.voice, .fx] {
            let old = Dictionary(before.modules(in: area).map { ($0.id, $0) }) { first, _ in first }
            for module in after.modules(in: area) {
                guard let previous = old[module.id], previous.typeID == module.typeID,
                      previous.parameters.count == module.parameters.count else { continue }
                if let index = module.parameters.indices.first(where: { module.parameters[$0] != previous.parameters[$0] }) {
                    return G2KnobAssignment(location: area.rawValue, moduleID: module.id, paramIndex: index)
                }
            }
        }
        return nil
    }
}
