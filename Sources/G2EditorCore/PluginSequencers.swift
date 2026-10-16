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
    /// `BipUni` — numer parametru w modułach, które go mają (0 = bipolarny).
    static let bipolarParams: [Int: Int] = [145: 34, 146: 34, 154: 33]

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

        var json: [String: Any] {
            ["location": location, "module": moduleID, "kind": kind.rawValue, "name": name, "steps": steps,
             "texts": texts, "gates": gates, "length": length, "hasLength": hasLength, "bipolar": bipolar]
        }
    }

    /// Wszystkie sekwencery slotu, głosy przed efektami, w kolejności modułów w patchu.
    @MainActor
    public static func snapshot(_ state: PatchState, slot: Int) -> [Sequencer] {
        guard state.slots.indices.contains(slot) else { return [] }
        let patch = state.slots[slot]
        var result: [Sequencer] = []
        for area in [PatchArea.voice, .fx] {
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
                result.append(Sequencer(location: Int(area.rawValue), moduleID: module.id, kind: kind, name: name,
                                        steps: steps, texts: texts,
                                        gates: Array(module.parameters[stepCount ..< stepCount * 2]),
                                        length: length, hasLength: hasLength, bipolar: bipolar))
            }
        }
        return result
    }

    /// Krok narysowany w oknie wtyczki. Tylko kroki (0–31) i długość — reszta modułu to nie ołówek.
    @MainActor
    public static func draw(_ state: PatchState, slot: Int, location: Int, moduleID: Int, param: Int, value: Int) {
        guard state.slots.indices.contains(slot), let area = PatchArea(rawValue: UInt8(clamping: location)),
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == moduleID }),
              kinds[module.typeID] != nil,
              (0 ..< stepCount * 2).contains(param) || (param == lengthParam && module.typeID != 154)
        else { return }
        let maxValue = G2ParameterText.maxValue(moduleTypeID: module.typeID, paramIndex: param)
        state.setParameter(slot: slot, moduleID: moduleID, paramIndex: param,
                           value: min(max(value, 0), maxValue), area: area)
    }
}
