// PluginPages.swift
// Strony parametrów w oknie wtyczki DAW-a — ten sam widok co okno Parameter Pages edytora
// (ekraniki, osiem gałek, przyciski pod nimi, wybór A…E / 1…3 i Global Pages).
//
// Strona i przełącznik Global Pages są wspólne z edytorem i Nordem: wybór we wtyczce zmienia
// je tak samo jak kliknięcie w oknie edytora. Gałki stron patcha wtyczka kręci drogą automatyki
// (DAW może je nagrać, bez Undo); gałki Global Pages i przyciski to zwykła edycja z Undo —
// Global Pages potrafią wskazać parametr w innym slocie, a pisać wolno tylko do swoich.

import Foundation
import G2Core

public enum PluginPages {
    public struct Button: Equatable {
        public var name: String
        public var text: String
        public var active: Bool
    }

    public struct Knob: Equatable {
        public var module: String
        public var parameter: String
        public var text: String
        /// 0…1 zakresu parametru.
        public var value: Double
        public var assigned: Bool
        /// Parametr leży w slocie tej wtyczki — tylko wtedy wolno nim ruszyć.
        public var editable: Bool
        public var button: Button?

        var json: [String: Any] {
            var result: [String: Any] = ["module": module, "param": parameter, "text": text, "value": value,
                                         "assigned": assigned, "editable": editable]
            if let button { result["button"] = ["name": button.name, "text": button.text, "active": button.active] }
            return result
        }
    }

    public struct Page: Equatable {
        public var page: Int
        public var global: Bool
        public var knobs: [Knob]
        /// Patch Adjuster działa na tym slocie — edytor go pokazuje (`selectedSlot`).
        public var adjuster: Bool

        var json: [String: Any] {
            ["page": page, "global": global, "knobs": knobs.map(\.json), "adjuster": adjuster]
        }
    }

    /// Strona widoczna dla slotu: strona patcha tego slotu albo — przy Global Pages — wspólna
    /// strona performance'u. `owned` = sloty wtyczki.
    @MainActor
    public static func snapshot(_ state: PatchState, slot: Int, owned: Set<Int>) -> Page {
        let global = state.showsGlobalParameterPages
        let page = global ? state.focusedParameterPage : state.patchParameterPage
        let knobs = (0 ..< G2KnobPages.knobsPerPage).map { knob -> Knob in
            guard let (target, targetSlot, assignment) = resolve(state, slot: slot, global: global,
                                                                 index: G2KnobPages.knobIndex(page: page, slot: knob))
            else {
                return Knob(module: "", parameter: "", text: "", value: 0, assigned: false, editable: false)
            }
            let value = min(max(target.value, 0), target.maxValue)
            return Knob(module: global ? "\(PluginBridge.letter(targetSlot)) \(target.module)" : target.module,
                        parameter: target.parameter, text: target.text,
                        value: target.maxValue > 0 ? Double(value) / Double(target.maxValue) : 0,
                        assigned: true, editable: owned.contains(targetSlot),
                        button: button(state, slot: targetSlot, assignment: assignment))
        }
        return Page(page: page, global: global, knobs: knobs, adjuster: slot == state.selectedSlot)
    }

    /// Gałka Global Pages przekręcona w oknie wtyczki (0…1) — zwykła edycja, jak w edytorze.
    @MainActor
    public static func setGlobalKnob(_ state: PatchState, knob: Int, value: Double, owned: Set<Int>) {
        guard state.showsGlobalParameterPages, (0 ..< G2KnobPages.knobsPerPage).contains(knob),
              let (target, targetSlot, _) = resolve(state, slot: 0, global: true,
                                                    index: G2KnobPages.knobIndex(page: state.focusedParameterPage,
                                                                                 slot: knob)),
              owned.contains(targetSlot) else { return }
        PluginAutomation.set(target, state: state, slot: targetSlot, value: value)
    }

    /// Przycisk pod gałką: następny stan powiązanego parametru (jak `cycleLinkedButton` w edytorze).
    @MainActor
    public static func pressButton(_ state: PatchState, slot: Int, knob: Int, owned: Set<Int>) {
        let global = state.showsGlobalParameterPages
        let page = global ? state.focusedParameterPage : state.patchParameterPage
        guard (0 ..< G2KnobPages.knobsPerPage).contains(knob),
              let (_, targetSlot, assignment) = resolve(state, slot: slot, global: global,
                                                        index: G2KnobPages.knobIndex(page: page, slot: knob)),
              owned.contains(targetSlot), let area = assignment.area,
              let module = state.slots[targetSlot].modules(in: area).first(where: { $0.id == assignment.moduleID }),
              let param = ModuleParameterLinks.buttonParameter(moduleTypeID: module.typeID,
                                                               knobParameter: assignment.paramIndex),
              module.parameters.indices.contains(param) else { return }
        let count = max(2, G2ParameterText.buttonOptions(moduleTypeID: module.typeID, paramIndex: param)?.count ?? 2)
        state.setParameter(slot: targetSlot, moduleID: module.id, paramIndex: param,
                           value: (module.parameters[param] + 1) % count, area: area)
    }

    // MARK: - Pomocniki

    /// Na co wskazuje gałka strony i w którym slocie leży ten parametr.
    @MainActor
    private static func resolve(_ state: PatchState, slot: Int, global: Bool, index: Int)
        -> (PluginAutomation.KnobTarget, Int, G2KnobAssignment)?
    {
        let assignment: G2KnobAssignment
        let targetSlot: Int
        if global {
            guard state.performance.globalKnobAssignments.indices.contains(index),
                  let item = state.performance.globalKnobAssignments[index] else { return nil }
            targetSlot = item.slot
            assignment = G2KnobAssignment(location: item.location, moduleID: item.moduleID, paramIndex: item.paramIndex)
        } else {
            guard state.slots.indices.contains(slot), let item = state.slots[slot].knobAssignment(at: index) else {
                return nil
            }
            targetSlot = slot
            assignment = item
        }
        guard let target = PluginAutomation.target(state, slot: targetSlot, assignment: assignment) else { return nil }
        return (target, targetSlot, assignment)
    }

    /// Przycisk powiązany z gałką (np. przy częstotliwości oscylatora — tryb Semi/Freq).
    @MainActor
    private static func button(_ state: PatchState, slot: Int, assignment: G2KnobAssignment) -> Button? {
        guard let area = assignment.area,
              let module = state.slots[slot].modules(in: area).first(where: { $0.id == assignment.moduleID }),
              let param = ModuleParameterLinks.buttonParameter(moduleTypeID: module.typeID,
                                                               knobParameter: assignment.paramIndex),
              module.parameters.indices.contains(param) else { return nil }
        let value = module.parameters[param]
        let name = G2ParameterText.name(moduleTypeID: module.typeID, paramIndex: param)
        let text = G2ParameterText.buttonOptions(moduleTypeID: module.typeID, paramIndex: param)?.text(for: value)
            ?? name
        return Button(name: name, text: text, active: value != 0)
    }
}
