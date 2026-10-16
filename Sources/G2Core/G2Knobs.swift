// G2Knobs.swift
// Strony parametrów: 120 gałek panelu Norda i to, co jest do nich przypisane.
//
// Panel G2 ma osiem gałek i piętnaście STRON, po których się je przełącza:
// pięć grup (Osc, LFO, Env, Filter, Effect — u Clavii litery A…E) po trzy strony.
// 15 × 8 = 120 przypisań, dokładnie tyle trzyma sekcja `0x62` pliku i tyle
// obsługuje oryginalny edytor.
//
// Źródła: Clavia Knob Map, Knob Floater Overview (nazwy grup), Knob Assign;
// BVerhue `AddMessKnobAssign`; g2ools `KnobAssignments` → [[Docs/ui/parameter-pages]].

import Foundation

// MARK: - Tabela stron

public enum G2KnobPages {
    /// Ile gałek ma jedna strona — tyle, ile ma panel urządzenia.
    public static let knobsPerPage = 8
    /// Pięć grup po trzy strony.
    public static let pageCount = 15
    /// Wszystkie przypisania patcha.
    public static let knobCount = knobsPerPage * pageCount

    /// Nazwy grup w kolejności z panelu — Knob Floater Overview (Draw) rysuje je
    /// razem z literami A…E, a pod każdą trzy numerowane strony.
    public static let groupNames = ["Osc", "LFO", "Env", "Filter", "Effect"]

    /// Etykieta strony w postaci, jakiej używa oryginał: „A1", „C3"…
    /// Strona `p` leży w grupie `p / 3`, a jej numer to `p % 3 + 1`
    /// (`CParameterPages::SetFocusedParameterPage` liczy dokładnie tak samo).
    public static func pageLabel(_ page: Int) -> String {
        guard (0 ..< pageCount).contains(page) else { return "" }
        let letter = Character(UnicodeScalar(UInt8(65 + page / 3)))
        return "\(letter)\(page % 3 + 1)"
    }

    public static func groupName(ofPage page: Int) -> String {
        guard (0 ..< pageCount).contains(page) else { return "" }
        return groupNames[page / 3]
    }

    /// Numer gałki w sekcji 0x62 — strony leżą po kolei, po osiem gałek każda.
    public static func knobIndex(page: Int, slot: Int) -> Int {
        page * knobsPerPage + slot
    }
}

// MARK: - Jedno przypisanie

/// Parametr przypięty do jednej gałki panelu.
public struct G2KnobAssignment: Equatable, Sendable {
    /// 0 = FX, 1 = Voice, 2 = ustawienia patcha (te też da się przypiąć —
    /// w kolekcji referencyjnej 620 przypisań).
    public var location: UInt8
    public var moduleID: Int
    public var paramIndex: Int
    /// Dwubitowe pole `isLed` z pliku. W kolekcji referencyjnej niezerowe 92 razy
    /// na 47 727 przypisań; przepisujemy je bez zmian, żeby plik wracał bit w bit.
    public var isLed: Int

    public init(location: UInt8, moduleID: Int, paramIndex: Int, isLed: Int = 0) {
        self.location = location
        self.moduleID = moduleID
        self.paramIndex = paramIndex
        self.isLed = isLed
    }

    public var area: PatchArea? {
        PatchArea(rawValue: location)
    }
}

/// Parametr przypięty do jednej z 120 globalnych gałek performance'u.
/// Układ sekcji 0x5F jest taki jak dla gałki patcha, ale kończy go dwubitowy numer slotu.
public struct G2GlobalKnobAssignment: Equatable, Sendable {
    public var slot: Int
    public var location: UInt8
    public var moduleID: Int
    public var paramIndex: Int
    public var isLed: Int

    public init(slot: Int, location: UInt8, moduleID: Int, paramIndex: Int, isLed: Int = 0) {
        self.slot = slot
        self.location = location
        self.moduleID = moduleID
        self.paramIndex = paramIndex
        self.isLed = isLed
    }

    public var area: PatchArea? {
        PatchArea(rawValue: location)
    }
}

// MARK: - Operacje na stronach parametrów

public extension G2Patch {
    func knobAssignment(at index: Int) -> G2KnobAssignment? {
        knobAssignments.indices.contains(index) ? knobAssignments[index] : nil
    }

    func knobAssignment(page: Int, slot: Int) -> G2KnobAssignment? {
        knobAssignment(at: G2KnobPages.knobIndex(page: page, slot: slot))
    }

    /// Numer gałki, do której przypięty jest dany parametr — `nil`, gdy do żadnej.
    func knobIndex(location: UInt8, moduleID: Int, paramIndex: Int) -> Int? {
        knobAssignments.firstIndex {
            $0?.location == location && $0?.moduleID == moduleID && $0?.paramIndex == paramIndex
        }
    }

    /// Przypina parametr do gałki. Jeden parametr może wisieć tylko na jednej gałce
    /// i jedna gałka tylko na jednym parametrze — oryginał pilnuje obu warunków,
    /// wysyłając najpierw odpięcie (BVerhue `AddMessAssignKnob`).
    /// Zwraca numery gałek, które przy okazji zostały zwolnione.
    @discardableResult
    mutating func assignKnob(index: Int, location: UInt8, moduleID: Int,
                             paramIndex: Int, isLed: Int = 0) -> [Int]
    {
        guard knobAssignments.indices.contains(index) else { return [] }
        var freed: [Int] = []
        if let previous = knobIndex(location: location, moduleID: moduleID, paramIndex: paramIndex),
           previous != index
        {
            knobAssignments[previous] = nil
            freed.append(previous)
        }
        if knobAssignments[index] != nil { freed.append(index) }
        knobAssignments[index] = G2KnobAssignment(location: location, moduleID: moduleID,
                                                  paramIndex: paramIndex, isLed: isLed)
        return freed
    }

    @discardableResult
    mutating func clearKnob(index: Int) -> G2KnobAssignment? {
        guard knobAssignments.indices.contains(index) else { return nil }
        let previous = knobAssignments[index]
        knobAssignments[index] = nil
        return previous
    }

    /// Pierwsza wolna gałka na stronie — `nil`, gdy strona pełna.
    func firstFreeKnob(onPage page: Int) -> Int? {
        (0 ..< G2KnobPages.knobsPerPage)
            .map { G2KnobPages.knobIndex(page: page, slot: $0) }
            .first { knobAssignment(at: $0) == nil }
    }
}

public extension G2PerformanceSettings {
    func globalKnobIndex(slot: Int, location: UInt8, moduleID: Int, paramIndex: Int) -> Int? {
        globalKnobAssignments.firstIndex {
            $0?.slot == slot && $0?.location == location && $0?.moduleID == moduleID
                && $0?.paramIndex == paramIndex
        }
    }

    @discardableResult
    mutating func assignGlobalKnob(index: Int, slot: Int, location: UInt8,
                                   moduleID: Int, paramIndex: Int, isLed: Int = 0) -> [Int]
    {
        guard globalKnobAssignments.indices.contains(index), (0 ..< 4).contains(slot) else { return [] }
        var freed: [Int] = []
        if let previous = globalKnobIndex(slot: slot, location: location,
                                          moduleID: moduleID, paramIndex: paramIndex),
            previous != index
        {
            globalKnobAssignments[previous] = nil
            freed.append(previous)
        }
        if globalKnobAssignments[index] != nil { freed.append(index) }
        globalKnobAssignments[index] = G2GlobalKnobAssignment(
            slot: slot,
            location: location,
            moduleID: moduleID,
            paramIndex: paramIndex,
            isLed: isLed
        )
        return freed
    }

    @discardableResult
    mutating func clearGlobalKnob(index: Int) -> G2GlobalKnobAssignment? {
        guard globalKnobAssignments.indices.contains(index) else { return nil }
        let previous = globalKnobAssignments[index]
        globalKnobAssignments[index] = nil
        return previous
    }
}
