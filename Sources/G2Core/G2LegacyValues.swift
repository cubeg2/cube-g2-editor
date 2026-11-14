// G2LegacyValues.swift
// Pliki zapisane w formacie 18–21 niosą WARTOŚCI w skalach, których Nord 1.62 już nie używa:
// filtr górnoprzepustowy, tempa LFO i czasy Glide inaczej niż dziś, morfy 5 i 6 na odwrót.
// Oryginalny edytor przelicza je przy otwarciu, krok po kroku do bieżącej wersji formatu;
// tu robimy to samo jednym przejściem → [[Docs/parser/file-conversion]].
//
// Przeliczenie nie jest idempotentne, więc patch pamięta wersję pliku (`sourceFormatVersion`),
// po konwersji mówi 23, a `PatchParser.saveAll` wpisuje to do nagłówka pliku.
// Kroki starsze niż 18→19 nie są jeszcze obsłużone — takiego pliku nie ruszamy.

public extension G2Patch {
    /// Przelicza wartości do formatu 23. Plik w wersji 22 i nowszej oraz plik starszy niż 18
    /// zostają bez zmian.
    mutating func convertLegacyValues() {
        guard (13 ..< 22).contains(sourceFormatVersion) else { return }
        if sourceFormatVersion < 18 { convertEarlyLegacyValues() }
        if sourceFormatVersion < 19 { limitPadAndZeroDelayClock() }
        if sourceFormatVersion < 20 { rescaleHighPassFrequency() }
        if sourceFormatVersion < 21 {
            swapMorphGroups5And6()
            dropMorphsAndControllersNoLongerSupported()
            capRandomClockMode()
            reshapeParametersOfVersion21()
        }
        rescaleLegacyRates()
        if sourceFormatVersion < 15 { fillMissingNinthVariation() }
        syncParametersToActiveVariation()
        sourceFormatVersion = Self.currentFormatVersion
    }
}

public extension G2PerformanceSettings {
    /// Globalne gałki na parametrach, które krok 20→21 usuwa ze środka modułu (FreqShift, RndLfoB,
    /// RndClkC): gałka na usuniętym znika, a na wyższych numerach przesuwa się w dół — jak przypisania
    /// w samym patchu. Wołać PRZED `dropGlobalKnobs`, na patchach sprzed `upgradeLegacyModules`.
    mutating func shiftGlobalKnobsOfReshapedParameters(original: [G2Patch]) {
        for knob in globalKnobAssignments.indices {
            guard var assignment = globalKnobAssignments[knob], assignment.location <= 1,
                  original.indices.contains(assignment.slot),
                  (13 ..< 21).contains(original[assignment.slot].sourceFormatVersion),
                  let area = PatchArea(rawValue: assignment.location),
                  let module = original[assignment.slot].modules(in: area).first(where: { $0.id == assignment.moduleID }),
                  let change = LegacyReshape.byType[module.typeID],
                  module.parameterVariations.first?.count == LegacyReshape.oldParameterCount(ofType: module.typeID)
            else { continue }
            var dropped = false
            for position in change.removed {
                if assignment.paramIndex == position { dropped = true
                    break
                }
                if assignment.paramIndex > position { assignment.paramIndex -= 1 }
            }
            globalKnobAssignments[knob] = dropped ? nil : assignment
        }
    }

    /// Globalne gałki performance'u na dialu albo źródle morfu 5 i 6 (moduł 1 ustawień patcha,
    /// parametry 4↔5 i 12↔13) zamieniają cele razem z samymi morfami — dla slotów, których patch
    /// pochodził z pliku w wersji 13–20. `original` to patche sprzed `upgradeLegacyModules`.
    mutating func swapMorphGlobalKnobs(original: [G2Patch]) {
        for knob in globalKnobAssignments.indices {
            guard var assignment = globalKnobAssignments[knob], assignment.location == 2,
                  assignment.moduleID == 1, original.indices.contains(assignment.slot),
                  (13 ..< 21).contains(original[assignment.slot].sourceFormatVersion)
            else { continue }
            switch assignment.paramIndex {
            case 4: assignment.paramIndex = 5
            case 5: assignment.paramIndex = 4
            case 12: assignment.paramIndex = 13
            case 13: assignment.paramIndex = 12
            default: continue
            }
            globalKnobAssignments[knob] = assignment
        }
    }
}

/// Krok 20→21: moduły, które tracą parametry ze środka albo dostają nowy. Parametry znikają po kolei
/// (numeracja przesuwa się po każdym), nowy wchodzi na dane miejsce na końcu.
enum LegacyReshape {
    struct Change {
        var removed: [Int] = []
        var added: (position: Int, value: Int)?
    }

    /// FreqShift (98), RndLfoB (202), RndClkC (206) i moduł 140 (dochodzi ExpLin).
    static let byType: [Int: Change] = [
        98: Change(removed: [3, 1], added: (3, 1)),
        202: Change(removed: [8]),
        206: Change(removed: [5, 1]),
        140: Change(added: (8, 0)),
    ]

    /// Ile parametrów miał moduł przed zmianą: dzisiejsza liczba, plus usunięte, minus dodany.
    /// `nil`, gdy typ się nie zmienia. Zmianę stosujemy tylko do modułu o takiej liczbie —
    /// moduł w nowym kształcie zostaje, jak jest.
    static func oldParameterCount(ofType typeID: Int) -> Int? {
        guard let change = byType[typeID], let current = ModuleDatabase.module(id: typeID)?.paramNames.count
        else { return nil }
        return current + change.removed.count - (change.added == nil ? 0 : 1)
    }
}

private enum LegacyType {
    static let lfoC = 24
    static let lfoA = 26
    static let glide = 158
    static let highPassFilter = 134
}

private extension G2Patch {
    /// Moduły danego typu w obu obszarach, razem z obszarem.
    mutating func forEachModule(ofType typeID: Int, _ body: (inout Self, PatchArea, Int) -> Void) {
        for area in [PatchArea.voice, .fx] {
            let count = modules(in: area).count
            for index in 0 ..< count where modules(in: area)[index].typeID == typeID {
                body(&self, area, index)
            }
        }
    }

    // MARK: 18 → 19

    /// Parametry modułów opóźnienia (typ → numer), które nowy firmware zeruje.
    private static let zeroedParameters: [Int: Int] = [175: 8, 176: 5, 177: 4, 182: 6]

    /// Pad wyjść (typy 3 i 4, parametr 2) ma tylko dwie wartości, a zakres jego morfu — najwyżej ±1;
    /// wartość i zakresy tniemy tylko tam, gdzie stara wartość przekraczała limit.
    /// Parametr czasu opóźnienia z zegara (typy 175, 176, 177, 182) dostaje 0 we wszystkich wariacjach.
    mutating func limitPadAndZeroDelayClock() {
        for area in [PatchArea.voice, .fx] {
            for (index, module) in modules(in: area).enumerated() {
                if module.typeID == 3 || module.typeID == 4 {
                    limitPad(area: area, index: index)
                } else if let parameter = Self.zeroedParameters[module.typeID] {
                    updateModule(in: area, at: index) { module in
                        for variation in module.parameterVariations.indices
                            where module.parameterVariations[variation].indices.contains(parameter)
                        {
                            module.parameterVariations[variation][parameter] = 0
                        }
                    }
                }
            }
        }
    }

    private mutating func limitPad(area: PatchArea, index: Int) {
        let module = modules(in: area)[index]
        for variation in module.parameterVariations.indices
            where module.parameterVariations[variation].indices.contains(2)
            && module.parameterVariations[variation][2] > 1
        {
            updateModule(in: area, at: index) { $0.parameterVariations[variation][2] = 1 }
            guard morphAssignments.indices.contains(variation) else { continue }
            for slot in morphAssignments[variation].indices {
                let assignment = morphAssignments[variation][slot]
                guard assignment.location == area.rawValue, assignment.moduleID == module.id,
                      assignment.paramIndex == 2 else { continue }
                morphAssignments[variation][slot].range = min(max(assignment.range, -1), 1)
            }
        }
    }

    // MARK: 19 → 20

    /// FilterHP, parametr 0 (częstotliwość): poniżej 101 o 5 niżej, 101–110 o 3 niżej.
    mutating func rescaleHighPassFrequency() {
        forEachModule(ofType: LegacyType.highPassFilter) { patch, area, index in
            patch.updateModule(in: area, at: index) { module in
                for variation in module.parameterVariations.indices
                    where module.parameterVariations[variation].indices.contains(0)
                {
                    module.parameterVariations[variation][0] =
                        Self.shiftedFilterFrequency(module.parameterVariations[variation][0])
                }
            }
        }
    }

    // MARK: 20 → 21

    /// Morfy 5 i 6 (numery 4 i 5) zamieniają się miejscami: w przypisaniach, w dialach i źródłach
    /// (moduł 1 ustawień patcha: parametry 4↔5 i 12↔13) oraz w gałkach i CC, które na nie wskazują.
    mutating func swapMorphGroups5And6() {
        for variation in morphAssignments.indices {
            for index in morphAssignments[variation].indices {
                switch morphAssignments[variation][index].morph {
                case 4: morphAssignments[variation][index].morph = 5
                case 5: morphAssignments[variation][index].morph = 4
                default: break
                }
            }
        }
        for variation in variationSettings.indices {
            variationSettings[variation].morphDials.swapAt(4, 5)
            variationSettings[variation].morphModes.swapAt(4, 5)
        }
        func swapped(_ paramIndex: Int) -> Int {
            switch paramIndex {
            case 4: 5
            case 5: 4
            case 12: 13
            case 13: 12
            default: paramIndex
            }
        }
        for index in knobAssignments.indices {
            if knobAssignments[index]?.location == 2, knobAssignments[index]?.moduleID == 1,
               let current = knobAssignments[index]?.paramIndex
            {
                knobAssignments[index]?.paramIndex = swapped(current)
            }
        }
        for index in midiControllerAssignments.indices {
            if midiControllerAssignments[index]?.location == 2, midiControllerAssignments[index]?.moduleID == 1,
               let current = midiControllerAssignments[index]?.paramIndex
            {
                midiControllerAssignments[index]?.paramIndex = swapped(current)
            }
        }
    }

    /// Parametry znikają ze środka (z przesunięciem numerów w morfach, gałkach i CC) albo dochodzą —
    /// tak jak w oryginale, zamiast przycięcia końca (`trimmedToModuleDefinitions`), które dawało
    /// inne wartości. Tylko dla modułów w starym kształcie.
    mutating func reshapeParametersOfVersion21() {
        for module in moduleReferences {
            guard let change = LegacyReshape.byType[module.typeID],
                  modules(in: module.area)[module.index].parameterVariations.first?.count
                  == LegacyReshape.oldParameterCount(ofType: module.typeID)
            else { continue }
            for position in change.removed {
                removeParameter(area: module.area, index: module.index, moduleID: module.id, at: position)
            }
            if let added = change.added {
                addParameter(area: module.area, index: module.index, at: added.position, value: added.value)
            }
        }
    }

    /// Tryb RndClkC (206) ma teraz najwyżej 1.
    mutating func capRandomClockMode() {
        for area in [PatchArea.voice, .fx] {
            for index in modules(in: area).indices
                where modules(in: area)[index].typeID == 206 && (modules(in: area)[index].modes.first ?? 0) > 1
            {
                updateModule(in: area, at: index) { $0.modes[0] = 1 }
            }
        }
    }

    /// Parametry, które w nowym firmware nie przyjmują już morfu ani CC: typ → (morfy, CC).
    /// Same parametry zostają — znika tylko przypisanie.
    private static let unsupportedAssignments: [Int: (morphs: [Int], controllers: [Int])] = [
        43: ([1], []), 50: ([2], []), 84: ([4], []),
        141: ([2, 0], [1, 0]), 142: ([1], []), 143: ([2], []),
        144: ([1, 0], [0]), 145: ([1, 0], [0]), 146: ([34], []), 147: ([1, 0], [0]),
        148: ([1, 0], []), 149: ([5, 4, 3, 2, 1, 0], []),
        152: (Array(1 ... 13), []), 156: ([0], []), 157: ([1], []), 188: ([2], []),
    ]

    mutating func dropMorphsAndControllersNoLongerSupported() {
        for area in [PatchArea.voice, .fx] {
            for module in modules(in: area) {
                guard let dropped = Self.unsupportedAssignments[module.typeID] else { continue }
                for variation in morphAssignments.indices {
                    morphAssignments[variation].removeAll {
                        $0.location == area.rawValue && $0.moduleID == module.id
                            && dropped.morphs.contains($0.paramIndex)
                    }
                }
                for index in midiControllerAssignments.indices {
                    if let assignment = midiControllerAssignments[index],
                       assignment.location == area.rawValue, assignment.moduleID == module.id,
                       dropped.controllers.contains(assignment.paramIndex)
                    {
                        midiControllerAssignments[index] = nil
                    }
                }
            }
        }
    }

    // MARK: 21 → 22

    /// LfoA i LfoC (tempo wg zakresu) oraz Glide (czas) dostają nowe skale razem z zakresami morfów.
    mutating func rescaleLegacyRates() {
        forEachModule(ofType: LegacyType.lfoA) { patch, area, index in
            for variation in patch.modules(in: area)[index].parameterVariations.indices {
                let row = patch.modules(in: area)[index].parameterVariations[variation]
                guard row.count > 7, (4 ... 5).contains(row[4]) else { continue }
                patch.rescale(area: area, index: index, variation: variation, with: Self.rateFunction(forRange: row[7]))
            }
        }
        forEachModule(ofType: LegacyType.glide) { patch, area, index in
            for variation in patch.modules(in: area)[index].parameterVariations.indices {
                let row = patch.modules(in: area)[index].parameterVariations[variation]
                guard row.count > 2, row[2] == 1 else { continue }
                patch.rescale(area: area, index: index, variation: variation, with: Self.glideTime)
            }
        }
        forEachModule(ofType: LegacyType.lfoC) { patch, area, index in
            guard let mode = patch.modules(in: area)[index].modes.first, (4 ... 5).contains(mode) else { return }
            for variation in patch.modules(in: area)[index].parameterVariations.indices {
                let row = patch.modules(in: area)[index].parameterVariations[variation]
                guard row.count > 3 else { continue }
                patch.rescale(area: area, index: index, variation: variation, with: Self.rateFunction(forRange: row[3]))
            }
        }
    }

    /// Nowa wartość parametru 0 i nowe zakresy jego morfów: koniec zakresu przeliczony tą samą
    /// funkcją, a gdy wyszłoby zero — jeden krok w stronę starego znaku.
    mutating func rescale(area: PatchArea, index: Int, variation: Int, with convert: (Int) -> Int) {
        let module = modules(in: area)[index]
        let old = module.parameterVariations[variation][0]
        let new = convert(old)
        updateModule(in: area, at: index) { $0.parameterVariations[variation][0] = new }
        guard morphAssignments.indices.contains(variation) else { return }
        for slot in morphAssignments[variation].indices {
            let assignment = morphAssignments[variation][slot]
            guard assignment.location == area.rawValue, assignment.moduleID == module.id,
                  assignment.paramIndex == 0 else { continue }
            let reach = convert(min(max(old + assignment.range, 0), 127))
            var range = reach - new
            if range == 0 { range = assignment.range > 0 ? 1 : -1 }
            morphAssignments[variation][slot].range = range
        }
    }

    static func rateFunction(forRange range: Int) -> (Int) -> Int {
        switch range {
        case 0: { $0 < 0x40 ? $0 * 2 + 1 : 127 } // Sub
        case 1, 2: { $0 < 0x74 ? $0 + 12 : 127 } // Lo, Hi
        case 3: bpmRate
        default: { $0 < 0x30 ? $0 + 8 : ($0 < 0x74 ? $0 + 12 : 127) } // Clk
        }
    }

    static func bpmRate(_ value: Int) -> Int {
        switch value {
        case ..<11: value * 2 + 12
        case ..<27: value * 4 - 8
        case ..<33: value * 2 + 44
        case ..<52: value + 76
        default: 127
        }
    }

    static func glideTime(_ value: Int) -> Int {
        glideTable[min(max(value, 0), 127)]
    }

    static let glideTable: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 4, 5, 6, 6, 7, 8, 9, 10, 10, 11, 12, 12, 13,
        14, 15, 16, 16, 17, 18, 19, 19, 20, 21, 22, 22, 23, 24, 25, 25, 26, 27, 28, 28, 29, 30, 30, 31, 32,
        33, 33, 34, 35, 36, 37, 37, 38, 39, 40, 40, 41, 42, 43, 43, 44, 45, 45, 46, 47, 48, 48, 49, 50, 51,
        51, 52, 53, 54, 54, 55, 56, 57, 57, 58, 59, 60, 61, 61, 62, 63, 64, 65, 65, 66, 67, 68, 68, 69, 70,
        71, 71, 72, 73, 73, 74, 75, 76, 76, 77, 78, 79, 80, 81, 81, 82, 83, 84, 85, 85, 87,
    ]
}
