// G2BuildingBlock.swift
// Wstawianie całego patcha z pliku (Building Block) do innego patcha.
// Plan i decyzje → Docs/Plan projektu/08-building-blocks.md

import Foundation

/// Co z bloku może przyjść razem z modułami — pola okienka po upuszczeniu.
/// `patchSettings` i `morphKnobs` zmieniają to, co patch już ma (jego Glide, jego gałki
/// morfów), dlatego okienko proponuje je odznaczone.
public enum G2BlockAssignmentKind: CaseIterable, Sendable {
    case morphs, knobs, midiControllers
    /// Glide, Bend, Vibrato, Arpeggiator, Octave Shift, Sustain bloku — bez głośności
    /// i wyciszenia patcha — razem z gałkami, CC i morfami, które na nich wiszą.
    case patchSettings
    /// Pozycja i źródło gałek tych morfów, których blok używa, razem z gałkami i CC na nich.
    case morphKnobs
    /// Własne nazwy tych morfów, których blok używa (sekcja 0x5B obszaru 2).
    case morphNames

    /// Do którego rodzaju należy przypisanie do ustawień patcha (obszar 2) — po numerze
    /// modułu z `G2PatchSetting.module`; morfy to moduł 1.
    static func ofSetting(module: Int) -> Self? {
        switch module {
        case 1: .morphKnobs
        case 2 ... 7: .patchSettings
        default: nil
        }
    }
}

/// Jedna wartość ustawień patcha z bloku (obszar 2): adres jak w protokole, w swojej wariacji.
public struct G2BlockSetting: Equatable, Sendable {
    public var variation: Int
    public var module: Int
    public var param: Int
    public var value: Int
}

/// Wpis morfu przeniesiony z bloku — żyje w konkretnej wariacji.
public struct G2BlockMorph: Equatable, Sendable {
    public var variation: Int
    public var assignment: G2MorphAssignment
}

/// Wynik wstawienia bloku: nowe moduły i to, co przyszło z jego przypisań.
public struct G2BlockInsertion: Equatable, Sendable {
    /// Numery wstawionych modułów w każdym obszarze; pusty, gdy blok nie ma modułów.
    public var modules: [PatchArea: Set<Int>] = [:]
    /// Przeniesione gałki i CC według numeru, morfy według wariacji — dokładnie to,
    /// co trzeba dosłać do Norda.
    public var knobs: [Int: G2KnobAssignment] = [:]
    public var midiControllers: [Int: G2MidiControllerAssignment] = [:]
    public var morphs: [G2BlockMorph] = []
    /// Przeniesione wartości ustawień patcha i gałek morfów.
    public var settings: [G2BlockSetting] = []
    /// Strona gałek pokazana na Nordzie, do wybrania ponownie po wysyłce — jak w `G2AssignmentChanges`.
    public var refreshPage: Int?
    /// Nazwy morfów nadane przez blok — przeniesione albo (przy odznaczonym polu) do pokazania.
    public var morphNames: [Int: String] = [:]
    /// Ile przypisań danego rodzaju blok ma i ile z nich odpadło. Morfy liczone są
    /// w parametrach (parametr pod kilkoma morfami i w kilku wariacjach to jeden),
    /// gałki i CC w sztukach; przypisania do ustawień patcha się tu nie liczą. Ustawienia
    /// patcha — w polach różnych od patcha, gałki morfów — w morfach. Liczone także dla
    /// rodzajów, których nie przenoszono.
    public var offered: [G2BlockAssignmentKind: Int] = [:]
    public var skipped: [G2BlockAssignmentKind: Int] = [:]

    public var hasAssignments: Bool {
        !knobs.isEmpty || !midiControllers.isEmpty || !morphs.isEmpty || !settings.isEmpty
            || carriesMorphNames
    }

    /// Czy nazwy z `morphNames` weszły do patcha (pole zaznaczone).
    public var carriesMorphNames = false

    /// Nazwy ustawień, które blok zmieni („Glide", „Bend Range"…), bez powtórzeń.
    public var settingNames: [String] {
        unique(settings.filter { $0.module != 1 }.compactMap { setting in
            G2PatchSetting.allCases.first { $0.module == setting.module && $0.param == setting.param }?.label
        })
    }

    /// Nazwy morfów, których gałki blok przestawi („Wheel", „Vel"…).
    public var morphKnobNames: [String] {
        unique(settings.filter { $0.module == 1 }.map { G2Morph.names[$0.param % G2Morph.count] })
    }

    private func unique(_ names: [String]) -> [String] {
        var seen: [String] = []
        for name in names where !seen.contains(name) {
            seen.append(name)
        }
        return seen
    }
}

public extension G2Patch {
    /// Wstawia moduły i kable z `block` do tego patcha. Moduły przechodzą w całości
    /// (wartości we wszystkich wariacjach, tryby, nazwy, kolory) i dostają nowe numery,
    /// kable idą za nimi. Reszta tylko według `carrying`: morfy, gałki i CC przepięte na nowe
    /// numery modułów, ustawienia patcha i gałki morfów bloku nadpisują te tutaj.
    ///
    /// Obszar bloku trafia do tego samego obszaru tutaj. W obszarze upuszczenia lewy
    /// górny róg bloku ląduje w `column`/`row`, a moduły, na które blok spada, zjeżdżają
    /// pod niego. Drugi obszar bloku idzie do tej samej kolumny, pod wszystko, co już tam stoi.
    @discardableResult
    mutating func insertBlock(_ block: G2Patch, dropArea: PatchArea, column: Int, row: Int,
                              carrying kinds: Set<G2BlockAssignmentKind> = []) -> G2BlockInsertion
    {
        var source = block
        source.ensureRuntimeVariations()
        let variation = activeVariation
        var insertion = G2BlockInsertion()
        var idMaps: [PatchArea: [Int: Int]] = [:]

        for area in PatchArea.allCases {
            let blockModules = source.modules(in: area)
            guard !blockModules.isEmpty else { continue }
            let columnShift = max(0, column) - (blockModules.map(\.column).min() ?? 0)
            let targetRow = area == dropArea ? max(0, row) : bottomRow(in: area)
            let rowShift = targetRow - (blockModules.map(\.row).min() ?? 0)

            var usedIDs = Set(modules(in: area).map(\.id))
            var idMap: [Int: Int] = [:]
            var incoming: [G2Module] = []
            for var module in blockModules {
                var newID = 1
                while usedIDs.contains(newID) {
                    newID += 1
                }
                usedIDs.insert(newID)
                idMap[module.id] = newID
                module.id = newID
                module.area = area
                module.column += columnShift
                module.row += rowShift
                if module.parameterVariations.indices.contains(variation) {
                    module.parameters = module.parameterVariations[variation]
                }
                incoming.append(module)
            }

            makeRoom(for: incoming, in: area)
            incoming.forEach { add(module: $0) }
            for var cable in source.cables(in: area) {
                guard let from = idMap[cable.fromModule], let to = idMap[cable.toModule] else { continue }
                cable.fromModule = from
                cable.toModule = to
                cable.area = area
                add(cable: cable)
            }
            carryModuleLabels(of: source, area: area, idMap: idMap)
            insertion.modules[area] = Set(idMap.values)
            idMaps[area] = idMap
        }
        // Ustawienia przed przypisaniami — a przypisania do ustawień tylko z ich polem.
        carrySettings(of: source, kinds: kinds, into: &insertion)
        carryMorphNames(of: source, kinds: kinds, into: &insertion)
        let target = BlockTarget(idMaps: idMaps, kinds: kinds)
        carryKnobs(of: source, target, into: &insertion)
        carryMidiControllers(of: source, target, into: &insertion)
        carryMorphs(of: source, target, into: &insertion)
        return insertion
    }

    /// Co z przypisań bloku weszłoby do tego patcha — wszystkie rodzaje, bez zmiany patcha.
    /// Z tego okienko po upuszczeniu bierze liczby.
    func blockAssignmentPreview(_ block: G2Patch) -> G2BlockInsertion {
        var copy = self
        return copy.insertBlock(block, dropArea: .voice, column: 0, row: 0,
                                carrying: Set(G2BlockAssignmentKind.allCases))
    }

    /// Dodatkowe dane modułów (sekcja 0x5B: własne podpisy parametrów, widok SeqNote) jadą
    /// za modułami jak ich nazwy — zawsze, z nowymi numerami (`addModuleLabels`).
    private mutating func carryModuleLabels(of source: G2Patch, area: PatchArea, idMap: [Int: Int]) {
        guard let theirs = source.moduleLabels(in: area) else { return }
        addModuleLabels(theirs.entries, idMap: idMap, in: area)
    }

    /// Morfy, do których blok ma jakiekolwiek przypisanie (w wariacjach 0–8).
    private var usedMorphs: Set<Int> {
        Set((0 ..< min(morphAssignments.count, Self.storedVariationCount))
            .flatMap { morphAssignments[$0] }
            .filter { $0.range != 0 }
            .map(\.morph))
    }

    /// Własne nazwy używanych morfów bloku, tam gdzie różnią się od nazw patcha. Domyślne
    /// serie („Wheel"…, „Src Gr1"…, „Group 1"…) i podpisy na nieużywanych morfach
    /// (np. „blue hell" w kilku blokach) nie przechodzą.
    private mutating func carryMorphNames(of source: G2Patch, kinds: Set<G2BlockAssignmentKind>,
                                          into insertion: inout G2BlockInsertion)
    {
        guard let theirs = source.morphLabels, var ours = morphLabels else { return }
        for morph in source.usedMorphs.sorted() {
            let name = theirs.name(morph)
            guard !G2MorphLabelSection.isDefault(name, morph: morph), name != ours.name(morph) else { continue }
            insertion.morphNames[morph] = name
            if kinds.contains(.morphNames) { ours.setName(name, morph: morph) }
        }
        insertion.offered[.morphNames] = insertion.morphNames.count
        guard kinds.contains(.morphNames), !insertion.morphNames.isEmpty else { return }
        moduleCustomData[2] = ours.raw
        insertion.carriesMorphNames = true
    }

    /// Dokąd trafiają przypisania bloku.
    private struct BlockTarget {
        var idMaps: [PatchArea: [Int: Int]]
        var kinds: Set<G2BlockAssignmentKind>

        /// Nowy numer modułu dla przypisania z bloku. Ustawienia patcha (obszar 2) mają
        /// stałe numery — przechodzą bez zmiany, ale tylko z polem swojego rodzaju.
        func moduleID(location: UInt8, moduleID: Int) -> Int? {
            if let area = PatchArea(rawValue: location) { return idMaps[area]?[moduleID] }
            guard let kind = G2BlockAssignmentKind.ofSetting(module: moduleID), kinds.contains(kind)
            else { return nil }
            return moduleID
        }
    }

    /// Ustawienia patcha i gałki morfów bloku, w każdej wariacji tam, gdzie różnią się od
    /// patcha. Głośność i wyciszenie patcha nie przechodzą nigdy — blok z paczki testowej
    /// nie ma zmieniać głośności. Gałki morfów — tylko tych morfów, których blok używa.
    private mutating func carrySettings(of source: G2Patch, kinds: Set<G2BlockAssignmentKind>,
                                        into insertion: inout G2BlockInsertion)
    {
        let variations = min(source.variationSettings.count, variationSettings.count, Self.storedVariationCount)
        let fields = G2PatchSetting.allCases.filter { $0 != .patchVolume && $0 != .activeMuted }
        let usedMorphs = source.usedMorphs
        var changedFields = Set<Int>(), changedMorphs = Set<Int>()
        for variation in 0 ..< variations {
            let theirs = source.variationSettings[variation]
            for (index, field) in fields.enumerated() where theirs[keyPath: field.keyPath]
                != variationSettings[variation][keyPath: field.keyPath]
            {
                changedFields.insert(index)
                guard kinds.contains(.patchSettings) else { continue }
                let value = theirs[keyPath: field.keyPath]
                variationSettings[variation][keyPath: field.keyPath] = value
                insertion.settings.append(G2BlockSetting(variation: variation, module: field.module,
                                                         param: field.param, value: value))
            }
            for morph in usedMorphs.sorted() {
                for (param, keyPath) in [(morph, \G2VariationSettings.morphDials),
                                         (morph + G2Morph.count, \G2VariationSettings.morphModes)]
                    where theirs[keyPath: keyPath][morph] != variationSettings[variation][keyPath: keyPath][morph]
                {
                    changedMorphs.insert(morph)
                    guard kinds.contains(.morphKnobs) else { continue }
                    let value = theirs[keyPath: keyPath][morph]
                    variationSettings[variation][keyPath: keyPath][morph] = value
                    insertion.settings.append(G2BlockSetting(variation: variation, module: 1,
                                                             param: param, value: value))
                }
            }
        }
        insertion.offered[.patchSettings] = changedFields.count
        insertion.offered[.morphKnobs] = changedMorphs.count
    }

    /// Gałka bloku idzie na tę samą gałkę tutaj; zajęta zostaje przy swoim parametrze.
    private mutating func carryKnobs(of source: G2Patch, _ target: BlockTarget,
                                     into insertion: inout G2BlockInsertion)
    {
        var offered = 0, skipped = 0
        for (index, knob) in source.knobAssignments.enumerated() {
            guard let knob, let newID = target.moduleID(location: knob.location, moduleID: knob.moduleID)
            else { continue }
            let counted = knob.area != nil
            if counted { offered += 1 }
            guard knobAssignment(at: index) == nil, knobAssignments.indices.contains(index) else {
                if counted { skipped += 1 }
                continue
            }
            guard target.kinds.contains(.knobs) else { continue }
            var moved = knob
            moved.moduleID = newID
            knobAssignments[index] = moved
            insertion.knobs[index] = moved
        }
        insertion.offered[.knobs] = offered
        insertion.skipped[.knobs] = skipped
    }

    /// CC bloku idzie pod ten sam numer; numer zajęty w patchu zostaje przy swoim parametrze.
    private mutating func carryMidiControllers(of source: G2Patch, _ target: BlockTarget,
                                               into insertion: inout G2BlockInsertion)
    {
        var offered = 0, skipped = 0
        for (cc, entry) in source.midiControllerAssignments.enumerated() {
            guard let entry, let newID = target.moduleID(location: entry.location, moduleID: entry.moduleID)
            else { continue }
            let counted = PatchArea(rawValue: entry.location) != nil
            if counted { offered += 1 }
            guard midiControllerAssignments.indices.contains(cc), midiControllerAssignments[cc] == nil else {
                if counted { skipped += 1 }
                continue
            }
            guard target.kinds.contains(.midiControllers) else { continue }
            var moved = entry
            moved.moduleID = newID
            midiControllerAssignments[cc] = moved
            insertion.midiControllers[cc] = moved
        }
        insertion.offered[.midiControllers] = offered
        insertion.skipped[.midiControllers] = skipped
    }

    /// Morfy bloku w tych samych wariacjach i z tymi samymi zakresami. Moduły są nowe, więc
    /// kolizji nie ma — odpada tylko to, co przekracza limit 25 parametrów w wariacji.
    /// Wariacja mutatora (bufor edytora) nie przechodzi.
    private mutating func carryMorphs(of source: G2Patch, _ blockTarget: BlockTarget,
                                      into insertion: inout G2BlockInsertion)
    {
        let apply = blockTarget.kinds.contains(.morphs)
        var offered = Set<[Int]>(), skipped = Set<[Int]>()
        // Liczy się też to, czego nie przenosimy, więc wpisy idą zawsze — przy `apply == false`
        // na kopię. Limit 25 musi widzieć wcześniejsze wpisy bloku, stąd wpisywanie, nie samo liczenie.
        var target = self
        let variations = min(source.morphAssignments.count, Self.storedVariationCount)
        for variation in 0 ..< variations {
            // Zakres 0 to „przypisania nie ma" — bywa w plikach (spectral2 model, wariacja Init).
            for entry in source.morphAssignments[variation] where entry.range != 0 {
                guard let newID = blockTarget.moduleID(location: entry.location, moduleID: entry.moduleID)
                else { continue }
                let key = [Int(entry.location), newID, entry.paramIndex]
                let counted = entry.area != nil
                if counted { offered.insert(key) }
                guard target.setMorphRange(variation: variation, location: entry.location, moduleID: newID,
                                           paramIndex: entry.paramIndex, morph: entry.morph,
                                           range: entry.range)
                else {
                    if counted { skipped.insert(key) }
                    continue
                }
                var moved = entry
                moved.moduleID = newID
                if apply { insertion.morphs.append(G2BlockMorph(variation: variation, assignment: moved)) }
            }
        }
        if apply { morphAssignments = target.morphAssignments }
        insertion.offered[.morphs] = offered.count
        insertion.skipped[.morphs] = skipped.count
    }

    /// Zaznaczone moduły jednego obszaru jako osobny patch — blok do zapisania
    /// (Save Selection as Block…). Kable przechodzą tylko te, które biegną między
    /// zaznaczonymi modułami, jak przy ⌘C. Lewy górny róg zaznaczenia ląduje w kolumnie 0,
    /// wierszu 0. Dodatkowe dane zaznaczonych modułów (0x5B) idą z nimi, a także ich gałki,
    /// CC i morfy (`takeAssignments`). Ustawień patcha blok nie dostaje.
    ///
    /// - Returns: `nil`, gdy żaden z numerów nie należy do modułu tego obszaru.
    func block(from area: PatchArea, moduleIDs: Set<Int>) -> G2Patch? {
        let picked = modules(in: area).filter { moduleIDs.contains($0.id) }
        guard !picked.isEmpty else { return nil }
        let left = picked.map(\.column).min() ?? 0
        let top = picked.map(\.row).min() ?? 0

        var block = G2Patch()
        block.description.variation = description.variation
        for var module in picked {
            module.column -= left
            module.row -= top
            block.add(module: module)
        }
        for cable in cables(in: area) where moduleIDs.contains(cable.fromModule)
            && moduleIDs.contains(cable.toModule)
        {
            block.add(cable: cable)
        }
        if var labels = moduleLabels(in: area) {
            labels.entries.removeAll { !moduleIDs.contains($0.moduleID) }
            if !labels.entries.isEmpty { block.moduleCustomData[area.rawValue] = labels.raw }
        }
        block.takeAssignments(of: self, area: area, moduleIDs: moduleIDs)
        return block
    }

    /// Przypisania do zaznaczonych modułów — morfy w wariacjach 0–8, gałki i CC pod tymi
    /// samymi numerami — oraz to, co należy do morfów, których te moduły używają: pozycja
    /// i źródło ich gałek, gałki i CC przypięte do nich i ich własne nazwy. Numery modułów
    /// bez zmian, bo blok trzyma oryginalne.
    private mutating func takeAssignments(of source: G2Patch, area: PatchArea, moduleIDs: Set<Int>) {
        let morphVariations = min(source.morphAssignments.count, morphAssignments.count, Self.storedVariationCount)
        for variation in 0 ..< morphVariations {
            morphAssignments[variation] = source.morphAssignments[variation].filter {
                $0.range != 0 && $0.location == area.rawValue && moduleIDs.contains($0.moduleID)
            }
        }
        let morphs = usedMorphs
        /// Gałka morfu to obszar 2, moduł 1: parametr `morf` (pozycja) albo `morf + 8` (źródło).
        func picked(location: UInt8, moduleID: Int, paramIndex: Int) -> Bool {
            if location == area.rawValue { return moduleIDs.contains(moduleID) }
            return location == 2 && moduleID == 1 && morphs.contains(paramIndex % G2Morph.count)
        }
        for (index, knob) in source.knobAssignments.enumerated() where knobAssignments.indices.contains(index) {
            guard let knob, picked(location: knob.location, moduleID: knob.moduleID, paramIndex: knob.paramIndex)
            else { continue }
            knobAssignments[index] = knob
        }
        for (cc, entry) in source.midiControllerAssignments.enumerated()
            where midiControllerAssignments.indices.contains(cc)
        {
            guard let entry, picked(location: entry.location, moduleID: entry.moduleID, paramIndex: entry.paramIndex)
            else { continue }
            midiControllerAssignments[cc] = entry
        }
        let settingVariations = min(source.variationSettings.count, variationSettings.count,
                                    Self.storedVariationCount)
        for variation in 0 ..< settingVariations {
            for morph in morphs {
                variationSettings[variation].morphDials[morph] = source.variationSettings[variation].morphDials[morph]
                variationSettings[variation].morphModes[morph] = source.variationSettings[variation].morphModes[morph]
            }
        }
        guard let theirs = source.morphLabels else { return }
        var names = G2MorphLabelSection.standard
        for morph in morphs where !G2MorphLabelSection.isDefault(theirs.name(morph), morph: morph) {
            names.setName(theirs.name(morph), morph: morph)
        }
        if names != .standard { moduleCustomData[2] = names.raw }
    }

    /// Pierwszy wiersz pod wszystkimi modułami obszaru — tam File ▸ Insert Patch File… kładzie blok.
    func bottomRow(in area: PatchArea) -> Int {
        modules(in: area).map { $0.row + Self.blockHeight(of: $0) }.max() ?? 0
    }

    /// Robi miejsce na wstawiane moduły: każdy dotychczasowy moduł, na który nachodzą,
    /// zjeżdża pod nie, a za nim kaskadą to, na co on z kolei najedzie. Układ samego
    /// bloku się nie zmienia.
    private mutating func makeRoom(for incoming: [G2Module], in area: PatchArea) {
        var existing = modules(in: area)
        for column in Set(incoming.map(\.column)) {
            var occupied = incoming
                .filter { $0.column == column }
                .map { $0.row ..< $0.row + Self.blockHeight(of: $0) }
            let inColumn = existing.indices
                .filter { existing[$0].column == column }
                .sorted { existing[$0].row < existing[$1].row }
            for index in inColumn {
                let height = Self.blockHeight(of: existing[index])
                var top = existing[index].row
                while let hit = occupied.first(where: { $0.overlaps(top ..< top + height) }) {
                    top = hit.upperBound
                }
                existing[index].row = top
                occupied.append(top ..< top + height)
            }
        }
        if area == .voice { voiceModules = existing } else { fxModules = existing }
    }

    private static func blockHeight(of module: G2Module) -> Int {
        ModuleDatabase.module(id: module.typeID)?.height ?? 2
    }
}
