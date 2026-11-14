// G2LegacyEarlySteps.swift
// Kroki 13→14 … 17→18 przeliczania starych plików → [[Docs/parser/file-conversion]].
// Te kroki wstawiają i usuwają parametry (z przesunięciem numerów), odwracają Mute→Active,
// przeliczają poziomy i częstotliwości na skalę sześcienną i przycinają zakresy.
// `G2Patch.convertLegacyValues` woła je dla plików w wersji 13–17.

extension G2Patch {
    /// Częstotliwość filtra przesunięta w dół: poniżej 101 o 5, 101–110 o 3 (kroki 15→16 i 19→20).
    static func shiftedFilterFrequency(_ value: Int) -> Int {
        if value < 101 { return max(value - 5, 0) }
        if value < 111 { return value - 3 }
        return value
    }

    /// Pliki w wersjach 13 i 14 mają osiem wariacji. Dziewiątą oryginał dopełnia domyślnymi
    /// wartościami modułów (z bieżących definicji) i domyślnymi ustawieniami patcha, bez morfów;
    /// bufor Mutatora (dziesiąty zestaw) dostaje jej kopię. Wołane po wszystkich krokach.
    mutating func fillMissingNinthVariation() {
        let ninth = 8
        for area in [PatchArea.voice, .fx] {
            for index in modules(in: area).indices {
                let module = modules(in: area)[index]
                guard module.parameterVariations.count > ninth else { continue }
                let current = module.parameterVariations[ninth]
                let defaults = ModuleDefaultsDatabase.defaults(forTypeID: module.typeID)
                let filled = (0 ..< current.count).map { $0 < defaults.count ? defaults[$0] : current[$0] }
                if area == .voice {
                    voiceModules[index].setNinthVariation(filled)
                } else {
                    fxModules[index].setNinthVariation(filled)
                }
            }
        }
        for slot in ninth ..< variationSettings.count {
            variationSettings[slot] = .filledForMissingVariation
        }
        for slot in ninth ..< morphAssignments.count {
            morphAssignments[slot] = []
        }
    }

    mutating func convertEarlyLegacyValues() {
        if sourceFormatVersion < 14 { addParametersOfVersion14() }
        if sourceFormatVersion < 15 { invertMuteParameters() }
        if sourceFormatVersion < 16 { cubifyLevelsAndFrequencies() }
        if sourceFormatVersion < 17 { trimRangesOfVersion17() }
        if sourceFormatVersion < 18 { removeParametersOfVersion18() }
    }
}

private extension G2VariationSettings {
    /// Ustawienia patcha, którymi oryginalny edytor dopełnia brakującą wariację: głośność 100,
    /// glide 28, bend 1, semiton 1, vibrato 50 / 64, arpeggiator 3, oktawa 2, sustain 1.
    static var filledForMissingVariation: G2VariationSettings {
        var settings = G2VariationSettings()
        settings.patchVolume = 100
        settings.glideTime = 28
        settings.bend = 1
        settings.semitone = 1
        settings.vibratoCents = 50
        settings.vibratoRate = 64
        settings.arpTime = 3
        settings.octaveShift = 2
        settings.sustain = 1
        return settings
    }
}

private extension G2Module {
    /// Wpisuje dziewiątą wariację i jej kopię w buforze Mutatora (dziesiąty zestaw, jeśli jest).
    mutating func setNinthVariation(_ values: [Int]) {
        for slot in 8 ..< parameterVariations.count {
            parameterVariations[slot] = values
        }
    }
}

private enum Early {
    /// Krok 14→15: numer parametru → typy modułów, w których jego wartość się odwraca (Mute → Active).
    static let inverted: [Int: [Int]] = [
        1: [3, 4, 31, 82, 95, 127, 170, 171], 9: [7, 45, 182], 8: [8, 177, 196],
        5: [9, 26, 33, 97, 118, 183], 3: [12, 32, 61, 87, 89, 103, 134, 189, 192],
        7: [13, 162, 190], 4: [24, 25, 96, 176], 6: [49, 51, 102, 150], 15: [58],
        2: [62, 74, 94, 125], 10: [163, 164],
    ]

    /// Krok 15→16: parametry przeliczane tablicą sześcienną. `conditional` — tylko gdy parametr
    /// `condition` nie ma wartości 1.
    struct CubifyRule {
        var always: [Int] = []
        var conditional: [Int] = []
        var condition = 0
    }

    static let cubify: [Int: CubifyRule] = [
        7: .init(always: [3, 5]), 8: .init(always: [3, 5]), 13: .init(always: [3, 5]), 163: .init(always: [3, 5]),
        9: .init(always: [7, 4]), 19: .init(conditional: [0, 1, 2, 3], condition: 4),
        25: .init(always: [3]), 26: .init(always: [3]), 45: .init(always: [3]), 97: .init(always: [3]),
        164: .init(always: [3]), 27: .init(always: [4]), 33: .init(always: [4]), 103: .init(always: [4]),
        196: .init(always: [4]), 32: .init(always: [2]), 40: .init(conditional: Array(0 ... 7), condition: 8),
        48: .init(always: [0, 1, 2, 3, 4, 5]), 58: .init(always: [4, 5, 13, 14, 11]),
        66: .init(conditional: [1, 3], condition: 4), 95: .init(always: [0]), 102: .init(always: [7]),
        123: .init(conditional: [0, 1, 2, 3], condition: 9), 140: .init(always: [0, 1, 2, 3]),
        161: .init(conditional: Array(0 ... 7), condition: 16), 162: .init(always: [1, 6]),
        183: .init(always: [4, 6]), 184: .init(conditional: [0], condition: 2),
        185: .init(conditional: [0], condition: 2), 195: .init(conditional: [0], condition: 2),
        190: .init(always: [1]), 194: .init(conditional: [0, 2], condition: 4),
    ]

    /// Krok 16→17: typ → (parametr, górna granica wartości).
    static let truncated: [Int: (parameter: Int, limit: Int)] = [
        25: (1, 3), 24: (3, 3), 26: (7, 3), 190: (2, 3), 177: (4, 1), 175: (8, 1), 176: (5, 1), 182: (6, 1),
    ]

    static let cubicTable: [Int] = [
        0, 2, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6, 6, 7, 8, 8, 9, 9, 10, 11, 11, 12, 13, 14, 14, 15, 16, 16, 17, 18, 19, 20,
        20, 21, 22, 23, 24, 24, 25, 26, 27, 28, 29, 30, 31, 32, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 45,
        46, 47, 48, 49, 50, 51, 52, 53, 54, 56, 57, 58, 59, 60, 61, 63, 64, 65, 66, 67, 68, 70, 71, 72, 73, 75, 76,
        77, 78, 79, 81, 82, 83, 84, 86, 87, 88, 89, 91, 92, 93, 94, 96, 97, 98, 99, 100, 102, 103, 104, 105, 107,
        108, 109, 110, 112, 113, 114, 115, 116, 118, 119, 120, 121, 122, 123, 125, 126, 127,
    ]
}

extension G2Patch {
    // MARK: Narzędzia (wspólne dla wszystkich kroków)

    /// Wszystkie moduły obu obszarów: obszar, indeks w tablicy, numer i typ.
    var moduleReferences: [(area: PatchArea, index: Int, id: Int, typeID: Int)] {
        [PatchArea.voice, .fx].flatMap { area in
            modules(in: area).enumerated().map {
                (area: area, index: $0.offset, id: $0.element.id, typeID: $0.element.typeID)
            }
        }
    }

    mutating func updateModule(in area: PatchArea, at index: Int, _ change: (inout G2Module) -> Void) {
        if area == .voice { change(&voiceModules[index]) } else { change(&fxModules[index]) }
    }

    /// Wstawia wartość na dane miejsce w każdym wariancie. Przypisań morfów, gałek i CC nie rusza.
    mutating func addParameter(area: PatchArea, index: Int, at position: Int, value: Int) {
        updateModule(in: area, at: index) { module in
            for variation in module.parameterVariations.indices {
                let count = module.parameterVariations[variation].count
                module.parameterVariations[variation].insert(value, at: min(position, count))
            }
        }
    }

    /// Usuwa parametr: jego wartość z każdego wariantu, przypisania na nim (morfy, gałki, CC),
    /// a przypisania na wyższych numerach przesuwa o jeden w dół.
    mutating func removeParameter(area: PatchArea, index: Int, moduleID: Int, at position: Int) {
        updateModule(in: area, at: index) { module in
            for variation in module.parameterVariations.indices
                where module.parameterVariations[variation].indices.contains(position)
            {
                module.parameterVariations[variation].remove(at: position)
            }
        }
        let location = area.rawValue
        for variation in morphAssignments.indices {
            morphAssignments[variation] = morphAssignments[variation].compactMap { assignment in
                guard assignment.location == location, assignment.moduleID == moduleID else { return assignment }
                if assignment.paramIndex == position { return nil }
                var shifted = assignment
                if shifted.paramIndex > position { shifted.paramIndex -= 1 }
                return shifted
            }
        }
        for slot in knobAssignments.indices {
            guard var knob = knobAssignments[slot], knob.location == location, knob.moduleID == moduleID else { continue }
            if knob.paramIndex == position { knobAssignments[slot] = nil
                continue
            }
            if knob.paramIndex > position { knob.paramIndex -= 1
                knobAssignments[slot] = knob
            }
        }
        for slot in midiControllerAssignments.indices {
            guard var cc = midiControllerAssignments[slot], cc.location == location, cc.moduleID == moduleID
            else { continue }
            if cc.paramIndex == position { midiControllerAssignments[slot] = nil
                continue
            }
            if cc.paramIndex > position { cc.paramIndex -= 1
                midiControllerAssignments[slot] = cc
            }
        }
    }
}

private extension G2Patch {
    // MARK: 13 → 14

    /// FltPhase (102): trzy parametry odpadają (9, 1, 0), trzy nowe wchodzą na końcu; Out Pad (3, 4),
    /// ExpLin w Mix4-1C (123) i InvertMode w ModAmt (195) dochodzą jako nowe parametry.
    mutating func addParametersOfVersion14() {
        for module in moduleReferences {
            switch module.typeID {
            case 102:
                for position in [9, 1, 0] {
                    removeParameter(area: module.area, index: module.index, moduleID: module.id, at: position)
                }
                for position in [8, 9, 10] {
                    addParameter(area: module.area, index: module.index, at: position, value: 0)
                }
            case 3, 4: addParameter(area: module.area, index: module.index, at: 2, value: 0)
            case 123: addParameter(area: module.area, index: module.index, at: 9, value: 0)
            case 195: addParameter(area: module.area, index: module.index, at: 3, value: 1)
            default: break
            }
        }
    }

    // MARK: 14 → 15

    /// Mute stało się Active: wartości zero i jeden zamieniają się miejscami — w ok. 50 typach
    /// modułów i w ustawieniach patcha (Active w bloku Volume).
    mutating func invertMuteParameters() {
        for module in moduleReferences {
            for (parameter, types) in Early.inverted where types.contains(module.typeID) {
                updateModule(in: module.area, at: module.index) { module in
                    for variation in module.parameterVariations.indices
                        where module.parameterVariations[variation].indices.contains(parameter)
                    {
                        module.parameterVariations[variation][parameter] =
                            module.parameterVariations[variation][parameter] == 0 ? 1 : 0
                    }
                }
            }
        }
        for variation in variationSettings.indices {
            variationSettings[variation].activeMuted = variationSettings[variation].activeMuted == 0 ? 1 : 0
        }
    }

    // MARK: 15 → 16

    /// Poziomy i częstotliwości na skali sześciennej, razem z zakresami morfów. Dotyczy też
    /// głośności patcha. FilterLP dostaje to samo przesunięcie co FilterHP w kroku 19→20;
    /// Vocoder (108) traci parametr 16, a typ 177 parametr 5.
    mutating func cubifyLevelsAndFrequencies() {
        for module in moduleReferences {
            if module.typeID == 87 {
                updateModule(in: module.area, at: module.index) { module in
                    for variation in module.parameterVariations.indices
                        where module.parameterVariations[variation].indices.contains(0)
                    {
                        module.parameterVariations[variation][0] =
                            Self.shiftedFilterFrequency(module.parameterVariations[variation][0])
                    }
                }
            } else if module.typeID == 108 {
                removeParameter(area: module.area, index: module.index, moduleID: module.id, at: 16)
            } else if module.typeID == 177 {
                removeParameter(area: module.area, index: module.index, moduleID: module.id, at: 5)
            } else if let rule = Early.cubify[module.typeID] {
                for variation in modules(in: module.area)[module.index].parameterVariations.indices {
                    let row = modules(in: module.area)[module.index].parameterVariations[variation]
                    let conditional = row.indices.contains(rule.condition) && row[rule.condition] != 1
                    for parameter in rule.always + (conditional ? rule.conditional : []) {
                        cubify(area: module.area, index: module.index, moduleID: module.id,
                               variation: variation, parameter: parameter)
                    }
                }
            }
        }
        for variation in variationSettings.indices {
            let old = variationSettings[variation].patchVolume
            let new = Early.cubicTable[min(max(old, 0), 127)]
            variationSettings[variation].patchVolume = new
            rescaleMorphs(variation: variation, location: 2, moduleID: 2, parameter: 0, old: old, new: new)
        }
    }

    mutating func cubify(area: PatchArea, index: Int, moduleID: Int, variation: Int, parameter: Int) {
        let row = modules(in: area)[index].parameterVariations[variation]
        guard row.indices.contains(parameter) else { return }
        let old = row[parameter]
        let new = Early.cubicTable[min(max(old, 0), 127)]
        updateModule(in: area, at: index) { $0.parameterVariations[variation][parameter] = new }
        rescaleMorphs(variation: variation, location: area.rawValue, moduleID: moduleID,
                      parameter: parameter, old: old, new: new)
    }

    /// Zakresy morfów parametru po przeliczeniu: koniec zakresu tą samą tablicą. Zakres zerowy
    /// znaczy „brak przypisania”, więc takie przypisanie znika.
    mutating func rescaleMorphs(variation: Int, location: UInt8, moduleID: Int, parameter: Int, old: Int, new: Int) {
        guard morphAssignments.indices.contains(variation) else { return }
        morphAssignments[variation] = morphAssignments[variation].compactMap { assignment in
            guard assignment.location == location, assignment.moduleID == moduleID,
                  assignment.paramIndex == parameter else { return assignment }
            var rescaled = assignment
            rescaled.range = Early.cubicTable[min(max(old + assignment.range, 0), 127)] - new
            return rescaled.range == 0 ? nil : rescaled
        }
    }

    // MARK: 16 → 17

    /// Zakresy przycięte, StChorus (94) o połowę, Glide (158) traci parametr 2, a tryb
    /// oscylatorów (9, 96) dostaje nową numerację.
    mutating func trimRangesOfVersion17() {
        for module in moduleReferences {
            if let rule = Early.truncated[module.typeID] {
                updateModule(in: module.area, at: module.index) { module in
                    for variation in module.parameterVariations.indices
                        where module.parameterVariations[variation].indices.contains(rule.parameter)
                        && module.parameterVariations[variation][rule.parameter] > rule.limit
                    {
                        module.parameterVariations[variation][rule.parameter] = rule.limit
                    }
                }
            }
            switch module.typeID {
            case 94: halveChorusAmount(area: module.area, index: module.index, moduleID: module.id)
            case 158: removeParameter(area: module.area, index: module.index, moduleID: module.id, at: 2)
            case 9, 96:
                updateModule(in: module.area, at: module.index) { module in
                    guard let mode = module.modes.first, mode > 1 else { return }
                    module.modes[0] = mode == 5 ? 2 : mode + 1
                }
            default: break
            }
        }
    }

    mutating func halveChorusAmount(area: PatchArea, index: Int, moduleID: Int) {
        for variation in modules(in: area)[index].parameterVariations.indices {
            let row = modules(in: area)[index].parameterVariations[variation]
            guard let old = row.first else { continue }
            updateModule(in: area, at: index) { $0.parameterVariations[variation][0] = (old + 1) >> 1 }
            guard morphAssignments.indices.contains(variation) else { continue }
            morphAssignments[variation] = morphAssignments[variation].compactMap { assignment in
                guard assignment.location == area.rawValue, assignment.moduleID == moduleID,
                      assignment.paramIndex == 0 else { return assignment }
                var halved = assignment
                halved.range = (assignment.range < 1 ? assignment.range - 1 : assignment.range + 1) / 2
                return halved.range == 0 ? nil : halved
            }
        }
    }

    // MARK: 17 → 18

    /// Digitizer (118) traci parametry 4 i 3, PitchTrack (198) parametr 0.
    mutating func removeParametersOfVersion18() {
        for module in moduleReferences {
            let removed: [Int] = switch module.typeID {
            case 118: [4, 3]
            case 198: [0]
            default: []
            }
            for position in removed {
                removeParameter(area: module.area, index: module.index, moduleID: module.id, at: position)
            }
        }
    }
}
