// G2Morph.swift
// Morfy: model przypisań, tabela ośmiu morfów i operacje na nich.
//
// Morf to jeden z ośmiu „makro-suwaków" patcha. Każdy ma własną gałkę (wartość
// 0–127, osobną w każdej wariacji) i własne źródło sterujące (koło modulacji,
// velocity, klawiatura…). Do morfu przypisuje się parametry modułów: parametr
// dostaje wtedy ZAKRES (`range`) — liczbę dodawaną do wartości bazowej, gdy morf
// jest wykręcony do końca. Zakres bywa ujemny.
//
// Źródła: oryginalny edytor Clavii (Morph Map / Morph Container / Morph Knob),
// BVerhue `TMorphParameters` + `TG2Param.AddMessSetMorph`, g2ools `MorphParameters`.
// Pełny opis i pomiary na kolekcji referencyjnej → [[Docs/ui/morphs]].

import Foundation

// MARK: - Tabela morfów

public enum G2Morph {
    /// Osiem morfów — tyle ma każdy patch, w pliku i w urządzeniu.
    public static let count = 8

    /// Nazwy morfów, czyli ich domyślne źródła sterujące. Kolejność jest stała
    /// (BVerhue `AddParam(197, …)` dla parametrów 0–7 modułu `PATCH_MORPH`).
    /// Nazwę można w oryginale zmienić — etykiety siedzą w sekcji nazw parametrów
    /// obszaru ustawień, której jeszcze nie modelujemy → [[Docs/roadmap]].
    public static let names = ["Wheel", "Vel", "Keyb", "Aft.Tch",
                               "Sust.Pd", "Ctrl.Pd", "P.Stick", "G.Wh2"]

    /// Pozycje przełącznika źródła pod gałką morfu. Zawsze „Knob" (morfem rusza tylko
    /// gałka) albo nazwane źródło; morf 5 (Sust.Pd) ma trzecią pozycję „G Wh 1" — to
    /// jedyny wyjątek w całej grupie i występuje wyłącznie na G2X
    /// (BVerhue `AddParam(202, …, 'Knob;Sust.Pd;G Wh 1')`, Clavia Morph Container
    /// dokleja `",G.Wh.1"` przy indeksie 4).
    public static func sourceOptions(morph: Int) -> [String] {
        guard morph >= 0, morph < count else { return ["Knob"] }
        return morph == 4 ? ["Knob", names[4], "G Wh 1"] : ["Knob", names[morph]]
    }

    /// Ile **parametrów** da się przypisać do morfów w jednej wariacji. Liczą się
    /// parametry, nie wpisy: parametr pod trzema morfami to jeden. Parametr, który już
    /// idzie za jakimkolwiek morfem, dostanie kolejny nawet przy komplecie
    /// (`GetNumberOfMorphedParams(…) < 0x19 || IsParamMorphed(…)` w
    /// `GetAssignMorphToParamMolecules`). Limit jest **edytora**, nie pliku:
    /// w kolekcji referencyjnej 100 z 32 652 wariacji ma więcej (rekord: 50),
    /// więc przy wczytywaniu pliku niczego nie przycinamy.
    public static let maxAssignmentsPerVariation = 25
}

// MARK: - Przypisanie morfu do parametru

/// Jedno przypisanie: „parametr X modułu Y idzie za morfem Z o `range`".
/// Żyje w konkretnej wariacji — ta sama gałka może mieć w innej wariacji inny
/// zakres albo żadnego.
public struct G2MorphAssignment: Equatable, Sendable {
    /// Obszar parametru: 0 = FX, 1 = Voice, 2 = ustawienia patcha (Glide, Bend…).
    /// Trzymamy surowy numer, a nie `PatchArea`, bo obszar 2 też bywa morfowany —
    /// w kolekcji referencyjnej 119 przypisań.
    public var location: UInt8
    public var moduleID: Int
    public var paramIndex: Int
    /// 0…7. W pliku i w protokole numeracja jest **od zera** — g2ools czyta tu
    /// `morphs[morph-1]`, co jest jego pomyłką: w 3 628 sekcjach kolekcji
    /// referencyjnej wartość nigdy nie przekracza 7.
    public var morph: Int
    /// Zakres morfu: −128…127, w pliku bajt w kodzie uzupełnieniowym do dwóch.
    /// Zero znaczy „przypisania nie ma" i tak też je kasuje urządzenie.
    public var range: Int

    public init(location: UInt8, moduleID: Int, paramIndex: Int, morph: Int, range: Int) {
        self.location = location
        self.moduleID = moduleID
        self.paramIndex = paramIndex
        self.morph = morph
        self.range = range
    }

    public init(area: PatchArea, moduleID: Int, paramIndex: Int, morph: Int, range: Int) {
        self.init(location: area == .voice ? 1 : 0, moduleID: moduleID,
                  paramIndex: paramIndex, morph: morph, range: range)
    }

    /// Obszar patcha, jeśli to parametr modułu; `nil` dla ustawień patcha (obszar 2).
    public var area: PatchArea? {
        PatchArea(rawValue: location)
    }
}

// MARK: - Operacje na mapie morfów patcha

public extension G2Patch {
    /// Przypisania morfów jednej wariacji.
    func morphs(in variation: Int) -> [G2MorphAssignment] {
        morphAssignments.indices.contains(variation) ? morphAssignments[variation] : []
    }

    /// Zakres morfu dla konkretnego parametru — 0, gdy przypisania nie ma.
    func morphRange(variation: Int, location: UInt8, moduleID: Int,
                    paramIndex: Int, morph: Int) -> Int
    {
        morphs(in: variation).first {
            $0.location == location && $0.moduleID == moduleID
                && $0.paramIndex == paramIndex && $0.morph == morph
        }?.range ?? 0
    }

    /// Wszystkie morfy przypięte do jednego parametru w danej wariacji.
    /// Parametr może iść naraz za kilkoma morfami — urządzenie sumuje ich wpływ.
    func morphs(variation: Int, location: UInt8, moduleID: Int,
                paramIndex: Int) -> [G2MorphAssignment]
    {
        morphs(in: variation).filter {
            $0.location == location && $0.moduleID == moduleID && $0.paramIndex == paramIndex
        }
    }

    /// Ustawia zakres morfu dla parametru. `range == 0` usuwa przypisanie — tak samo
    /// robi oryginał (BVerhue `AddMessClearMorph` wysyła zakres 0, urządzenie kasuje wpis).
    ///
    /// Zwraca `false`, gdy przypisania nie dało się dodać, bo wariacja ma już komplet
    /// parametrów (`G2Morph.maxAssignmentsPerVariation`), a ten parametr nie idzie
    /// jeszcze za żadnym morfem — dokładnie ten warunek ma Clavia.
    @discardableResult
    mutating func setMorphRange(variation: Int, location: UInt8, moduleID: Int,
                                paramIndex: Int, morph: Int, range: Int) -> Bool
    {
        guard morphAssignments.indices.contains(variation),
              (0 ..< G2Morph.count).contains(morph) else { return false }
        let clamped = max(-128, min(127, range))
        let index = morphAssignments[variation].firstIndex {
            $0.location == location && $0.moduleID == moduleID
                && $0.paramIndex == paramIndex && $0.morph == morph
        }
        if clamped == 0 {
            if let index { morphAssignments[variation].remove(at: index) }
            return true
        }
        if let index {
            morphAssignments[variation][index].range = clamped
            return true
        }
        guard morphedParameterCount(in: variation) < G2Morph.maxAssignmentsPerVariation
            || !morphs(variation: variation, location: location, moduleID: moduleID,
                       paramIndex: paramIndex).isEmpty
        else { return false }
        let new = G2MorphAssignment(location: location, moduleID: moduleID,
                                    paramIndex: paramIndex, morph: morph, range: clamped)
        // Wstawiamy na miejsce wynikające z porządku pliku — (obszar, moduł, parametr,
        // morf), czyli klucz Morph Spec oryginału. Dzięki temu sekcja 0x65 zapisuje
        // się dokładnie tak, jak zapisałby ją Nord → [[Docs/ui/morphs]].
        let key = { (a: G2MorphAssignment) in (a.location, a.moduleID, a.paramIndex, a.morph) }
        let position = morphAssignments[variation].firstIndex { key($0) > key(new) }
        morphAssignments[variation].insert(new, at: position ?? morphAssignments[variation].endIndex)
        return true
    }

    /// Zdejmuje z wariacji wszystkie parametry przypisane do jednego morfu
    /// (Clavia: „Clear Group" z menu pod prawym przyciskiem nad gałką morfu).
    /// Zwraca zdjęte przypisania — dzwoniący musi je odesłać do urządzenia pojedynczo.
    @discardableResult
    mutating func clearMorph(_ morph: Int, in variation: Int) -> [G2MorphAssignment] {
        guard morphAssignments.indices.contains(variation) else { return [] }
        let removed = morphAssignments[variation].filter { $0.morph == morph }
        morphAssignments[variation].removeAll { $0.morph == morph }
        return removed
    }

    /// Ile różnych parametrów idzie w wariacji za morfami (Clavia
    /// `GetNumberOfMorphedParams`) — tym liczy się limit przypisań.
    func morphedParameterCount(in variation: Int) -> Int {
        Set(morphs(in: variation).map { [Int($0.location), $0.moduleID, $0.paramIndex] }).count
    }

    /// Kopiuje przypisania jednego morfu na inny z tymi samymi zakresami
    /// (Clavia: „Copy To ▸ Group N"). Źródło zostaje — oryginał tylko przypisuje
    /// grupę docelową, niczego nie zdejmuje. Parametr, który morf docelowy już miał,
    /// dostaje zakres ze źródła. Zwraca przypisania, które się udały.
    @discardableResult
    mutating func copyMorph(from source: Int, to destination: Int, in variation: Int) -> [G2MorphAssignment] {
        guard morphAssignments.indices.contains(variation), source != destination,
              (0 ..< G2Morph.count).contains(source), (0 ..< G2Morph.count).contains(destination)
        else { return [] }
        var copied: [G2MorphAssignment] = []
        for entry in morphs(in: variation) where entry.morph == source {
            guard setMorphRange(variation: variation, location: entry.location, moduleID: entry.moduleID,
                                paramIndex: entry.paramIndex, morph: destination, range: entry.range)
            else { continue }
            copied.append(G2MorphAssignment(location: entry.location, moduleID: entry.moduleID,
                                            paramIndex: entry.paramIndex, morph: destination,
                                            range: entry.range))
        }
        return copied
    }

    /// Wartość gałki morfu w danej wariacji (0–127).
    func morphDial(_ morph: Int, in variation: Int) -> Int {
        guard variationSettings.indices.contains(variation),
              variationSettings[variation].morphDials.indices.contains(morph) else { return 0 }
        return variationSettings[variation].morphDials[morph]
    }

    mutating func setMorphDial(_ morph: Int, in variation: Int, value: Int) {
        guard variationSettings.indices.contains(variation),
              variationSettings[variation].morphDials.indices.contains(morph) else { return }
        variationSettings[variation].morphDials[morph] = max(0, min(127, value))
    }

    /// Źródło morfu: 0 = tylko gałka, 1 = nazwane źródło, 2 = „G Wh 1" (tylko morf 5).
    func morphMode(_ morph: Int, in variation: Int) -> Int {
        guard variationSettings.indices.contains(variation),
              variationSettings[variation].morphModes.indices.contains(morph) else { return 0 }
        return variationSettings[variation].morphModes[morph]
    }

    mutating func setMorphMode(_ morph: Int, in variation: Int, value: Int) {
        guard variationSettings.indices.contains(variation),
              variationSettings[variation].morphModes.indices.contains(morph) else { return }
        let limit = G2Morph.sourceOptions(morph: morph).count - 1
        variationSettings[variation].morphModes[morph] = max(0, min(limit, value))
    }
}
