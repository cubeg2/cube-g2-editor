// G2AssignmentChanges.swift
// Różnica przypisań między dwoma stanami patcha: gałki, CC, morfy i ustawienia patcha.
//
// Zmiana struktury jedzie do Norda jako `G2PatchDiff` — moduły, kable, podpisy — a tej części
// nie niesie. Po ⌘Z / ⇧⌘Z (np. ponowione wstawienie bloku) i po skasowaniu modułów
// przypisania jadą więc osobno, tymi samymi komendami co przy ręcznej zmianie.
// → Docs/Plan projektu/08-building-blocks.md

import Foundation

public struct G2AssignmentChanges: Equatable, Sendable {
    /// Gałka → nowe przypisanie; `nil` = gałka zwolniona.
    public var knobs: [Int: G2KnobAssignment?] = [:]
    /// Numer CC → nowe przypisanie; `nil` = CC zwolnione.
    public var midiControllers: [Int: G2MidiControllerAssignment?] = [:]
    /// Morfy z nowym zakresem; zakres 0 kasuje przypisanie.
    public var morphs: [G2BlockMorph] = []
    /// Ustawienia patcha i gałki morfów z nową wartością.
    public var settings: [G2BlockSetting] = []
    /// Strona gałek, którą Nord właśnie pokazuje, gdy zmiana dotyka jej gałek — po wysłaniu
    /// trzeba ją wybrać ponownie. Nord nie odświeża ekranu bieżącej strony po (od)pięciu gałki,
    /// dopiero po przełączeniu strony (sprawdzone na Nordzie 2026-10-24).
    public var refreshPage: Int?

    public var isEmpty: Bool {
        knobs.isEmpty && midiControllers.isEmpty && morphs.isEmpty && settings.isEmpty
    }

    /// Różnica rozdzielona wokół zmiany struktury. PRZED nią idzie zwolnienie gałek, CC i morfów
    /// modułów, których w `new` już nie ma — tak jak w oryginalnym edytorze, który przy każdym
    /// kasowaniu modułów najpierw zwalnia ich przypisania, a dopiero potem kasuje moduły.
    /// Skasowanie modułów z przypiętymi gałkami Nord zostawił bez potwierdzenia (2026-10-23),
    /// edytor uznał połączenie za zerwane i nic więcej już nie wysłał. Reszta idzie PO zmianie
    /// struktury, bo przypisanie do modułu, który dopiero wraca, wymaga tego modułu.
    public static func split(_ old: G2Patch, _ new: G2Patch)
        -> (beforeStructure: G2AssignmentChanges, afterStructure: G2AssignmentChanges)
    {
        var after = between(old, new)
        var before = G2AssignmentChanges()
        func gone(_ location: UInt8, _ moduleID: Int) -> Bool {
            guard let area = PatchArea(rawValue: location) else { return false }
            return !new.modules(in: area).contains { $0.id == moduleID }
        }
        for (knob, value) in after.knobs where value == nil {
            guard let was = old.knobAssignments[knob], gone(was.location, was.moduleID) else { continue }
            before.knobs[knob] = .some(nil)
            after.knobs[knob] = nil
        }
        for (cc, value) in after.midiControllers where value == nil {
            guard let was = old.midiControllerAssignments[cc], gone(was.location, was.moduleID) else { continue }
            before.midiControllers[cc] = .some(nil)
            after.midiControllers[cc] = nil
        }
        let goneMorph = { (morph: G2BlockMorph) in
            morph.assignment.range == 0 && gone(morph.assignment.location, morph.assignment.moduleID)
        }
        before.morphs = after.morphs.filter(goneMorph)
        after.morphs.removeAll(where: goneMorph)
        return (before, after)
    }

    /// Co trzeba wysłać, żeby urządzenie ze stanem `old` miało przypisania z `new`.
    public static func between(_ old: G2Patch, _ new: G2Patch) -> G2AssignmentChanges {
        var changes = G2AssignmentChanges()
        for knob in 0 ..< min(old.knobAssignments.count, new.knobAssignments.count)
            where old.knobAssignments[knob] != new.knobAssignments[knob]
        {
            changes.knobs[knob] = new.knobAssignments[knob]
        }
        for cc in 0 ..< min(old.midiControllerAssignments.count, new.midiControllerAssignments.count)
            where old.midiControllerAssignments[cc] != new.midiControllerAssignments[cc]
        {
            changes.midiControllers[cc] = new.midiControllerAssignments[cc]
        }

        func key(_ entry: G2MorphAssignment) -> [Int] {
            [Int(entry.location), entry.moduleID, entry.paramIndex, entry.morph]
        }
        let morphVariations = min(old.morphAssignments.count, new.morphAssignments.count,
                                  G2Patch.storedVariationCount)
        for variation in 0 ..< morphVariations {
            let before = old.morphAssignments[variation].filter { $0.range != 0 }
            let after = new.morphAssignments[variation].filter { $0.range != 0 }
            for entry in after where !before.contains(entry) {
                changes.morphs.append(G2BlockMorph(variation: variation, assignment: entry))
            }
            let kept = Set(after.map(key))
            for var entry in before where !kept.contains(key(entry)) {
                entry.range = 0
                changes.morphs.append(G2BlockMorph(variation: variation, assignment: entry))
            }
        }

        let settingVariations = min(old.variationSettings.count, new.variationSettings.count,
                                    G2Patch.storedVariationCount)
        for variation in 0 ..< settingVariations {
            let before = old.variationSettings[variation], after = new.variationSettings[variation]
            for field in G2PatchSetting.allCases where before[keyPath: field.keyPath] != after[keyPath: field.keyPath] {
                changes.settings.append(G2BlockSetting(variation: variation, module: field.module,
                                                       param: field.param, value: after[keyPath: field.keyPath]))
            }
            // Gałka morfu: obszar 2, moduł 1, parametr `morf` (pozycja) i `morf + 8` (źródło).
            for morph in 0 ..< G2Morph.count {
                for (param, keyPath) in [(morph, \G2VariationSettings.morphDials),
                                         (morph + G2Morph.count, \G2VariationSettings.morphModes)]
                    where before[keyPath: keyPath][morph] != after[keyPath: keyPath][morph]
                {
                    changes.settings.append(G2BlockSetting(variation: variation, module: 1,
                                                           param: param, value: after[keyPath: keyPath][morph]))
                }
            }
        }
        return changes
    }
}
