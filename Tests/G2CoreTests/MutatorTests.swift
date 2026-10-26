// MutatorTests.swift
// Patch Mutator: cztery operacje hodowli, blokady kategorii, chromosom i kratki okna.
// Liczby (0,3721 / 0,189 / 0,15, krzywa `Link`, krok interpolacji (i+1)/7) pochodzą
// z oryginalnego edytora Clavii → [[Docs/ui/mutator]].

import G2Core
@testable import G2EditorCore
import XCTest

/// Powtarzalny generator — bez niego test „ten sam wynik dla tego samego ziarna"
/// nie miałby czego sprawdzać. Zwykły LCG, wystarczy do losowania w teście.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@MainActor
final class MutatorTests: XCTestCase {
    private func fixturePatch(_ name: String = "test_3osc.pch2") throws -> G2Patch {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .standardized
        return try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
    }

    private func makeState(_ patch: G2Patch) -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.slots = [patch]
        return state
    }

    private func undoStep(on state: PatchState, _ action: () -> Void) {
        state.undoManager.beginUndoGrouping()
        action()
        state.undoManager.endUndoGrouping()
    }

    /// Genom, rodzic i wszystkie blokady zdjęte — punkt wyjścia większości testów.
    private func fixture() throws -> (patch: G2Patch, genome: G2MutatorGenome, parent: G2Individual) {
        let patch = try fixturePatch()
        let genome = G2MutatorGenome(patch: patch)
        return (patch, genome, G2Mutator.individual(from: patch, variation: 0, genome: genome))
    }

    private let allOpen = G2MutatorLocks(enabled: 0xFF, solo: 0)

    // MARK: - Genom

    /// Genom obejmuje WSZYSTKIE parametry (chromosom rysuje się z całości), ale
    /// ruszać wolno tylko te, których klasa nie jest na liście wyciętych w `IsEnabled`.
    func testGenomeCoversEveryParameterButOnlyTouchableClassesAreMutable() throws {
        let (patch, genome, _) = try fixture()
        let total = patch.voiceModules.reduce(0) { $0 + $1.parameters.count }
            + patch.fxModules.reduce(0) { $0 + $1.parameters.count }
        XCTAssertEqual(genome.genes.count, total)

        let mutable = genome.genes.filter(\.isMutable)
        XCTAssertFalse(mutable.isEmpty)
        XCTAssertLessThan(mutable.count, genome.genes.count, "przełączniki zostają nietknięte")

        for gene in genome.genes {
            let module = try XCTUnwrap(patch.modules(in: gene.area).first { $0.id == gene.moduleID })
            let paramClass = try XCTUnwrap(G2ParamClass.of(moduleTypeID: module.typeID, paramIndex: gene.paramIndex))
            XCTAssertEqual(gene.isMutable, paramClass.curve != .none,
                           "parametr \(gene.paramIndex) modułu \(module.typeID)")
        }
    }

    /// Tabela klas zna każdy moduł z bazy, który ma parametry — poza dwoma modułami PM
    /// (Driver, Resonator), których oryginalny edytor nie ma — i podaje dokładnie tyle
    /// klas, ile moduł ma parametrów.
    func testParamClassTableCoversTheModuleDatabase() {
        let unknownToTheOriginal: Set = [35, 56]
        for def in ModuleDatabase.all where !def.paramNames.isEmpty {
            var count = 0
            while G2ParamClass.of(moduleTypeID: def.id, paramIndex: count) != nil {
                count += 1
            }
            if unknownToTheOriginal.contains(def.id) {
                XCTAssertEqual(count, 0, "\(def.shortName) nie powinien mieć wpisu")
            } else {
                XCTAssertEqual(count, def.paramNames.count, def.shortName)
            }
        }
    }

    /// Moduły wejścia/wyjścia i MIDI są wyłączone z mutacji z góry — instrukcja
    /// wymienia je wprost.
    func testInputOutputModulesAreExcludedByDefault() {
        XCTAssertTrue(G2Module.isExcludedFromMutationByDefault(typeID: 4)) // 2-Out
        XCTAssertTrue(G2Module.isExcludedFromMutationByDefault(typeID: 1)) // Keyboard
        XCTAssertTrue(G2Module.isExcludedFromMutationByDefault(typeID: 143)) // NoteSend
        XCTAssertTrue(G2Module.isExcludedFromMutationByDefault(typeID: 108)) // Vocoder
        XCTAssertFalse(G2Module.isExcludedFromMutationByDefault(typeID: 97)) // OscA
    }

    // MARK: - Kategorie Quick Lock

    /// Parametr po nazwie z bazy modułów — w kodzie decyduje numer typu i indeks.
    private func category(_ shortName: String, _ param: String) -> G2MutatorCategory? {
        guard let def = ModuleDatabase.module(shortName: shortName),
              let index = def.paramNames.firstIndex(of: param)
        else {
            XCTFail("brak parametru \(shortName).\(param) w bazie modułów")
            return nil
        }
        var module = G2Module(id: 1, typeID: def.id, area: .voice)
        module.parameters = Array(repeating: 0, count: def.paramNames.count)
        return G2MutatorGenome.category(of: module, paramIndex: index)
    }

    private func curve(_ shortName: String, _ param: String) -> G2ParamClass.Curve? {
        guard let def = ModuleDatabase.module(shortName: shortName),
              let index = def.paramNames.firstIndex(of: param)
        else {
            XCTFail("brak parametru \(shortName).\(param) w bazie modułów")
            return nil
        }
        return G2ParamClass.of(moduleTypeID: def.id, paramIndex: index)?.curve
    }

    /// Kategorie `Delays` i `Effects` rozpoznajemy po numerze typu modułu, pozostałe
    /// pięć po klasie parametru — obie listy z Muta Synth Data (IsEnabled).
    func testCategoriesMatchTheOriginalLists() {
        XCTAssertEqual(category("Reverb", "Time"), .effects)
        XCTAssertEqual(category("Phaser", "Type"), .effects)
        XCTAssertEqual(category("Compress", "Attack"), .effects, "typ modułu bije klasę parametru")
        XCTAssertEqual(category("DelayA", "Time"), .delays)
        XCTAssertEqual(category("DlyStereo", "TimeRight"), .delays)
        XCTAssertNotEqual(category("Operator", "R1"), .delays, "FM Operator nie jest modułem opóźnienia")
        XCTAssertEqual(category("OscA", "FreqCoarse"), .oscFreq)
        XCTAssertEqual(category("OscA", "FreqFine"), .oscFine)
        XCTAssertEqual(category("EnvADSR", "Attack"), .envelope)
        XCTAssertEqual(category("EnvADSR", "Sustain"), .envelope)
        XCTAssertEqual(category("SeqVal", "Seq1Step1"), .seqValue)
        XCTAssertEqual(category("SeqEvent", "Seq1Step1"), .seqEvent)
        XCTAssertNil(category("OscA", "Waveform"))
        XCTAssertNil(category("MixStereo", "Pan1"), "bit 0x04 nie ma przycisku")
    }

    /// Klasa zależy od modułu i parametru, nie od samej nazwy — dlatego kategorie
    /// różnią się od tych, które dawała nazwa (celowo, zgodnie z oryginałem).
    func testCategoriesFollowTheClassNotTheName() {
        XCTAssertEqual(category("SeqVal", "Seq2Step1"), .seqEvent, "wiersz zdarzeń sekwencera wartości")
        XCTAssertEqual(category("SeqNote", "Seq2Step16"), .seqEvent)
        XCTAssertEqual(category("OscA", "PitchMod"), .oscFreq)
        XCTAssertEqual(category("Operator", "FreqFine"), .oscFreq)
        XCTAssertEqual(category("Operator", "FreqDetune"), .oscFine)
        XCTAssertNil(category("MetNoise", "Freq"))
        XCTAssertEqual(category("EnvADSR", "Shape"), .envelope)
        XCTAssertEqual(category("DrumSynth", "BendAmount"), .envelope)
        XCTAssertEqual(category("NoiseGate", "Release"), .envelope)
        XCTAssertEqual(category("Operator", "R1"), .envelope)
        XCTAssertNil(category("Operator", "L4"))
    }

    /// Krzywe losowania z klasy parametru — `Decay` w EnvD i EnvADSR to dwie różne krzywe.
    func testCurvesFollowTheOriginalClasses() {
        XCTAssertEqual(curve("EnvADSR", "Attack"), .oneSided)
        XCTAssertEqual(curve("EnvADSR", "Decay"), .twoSided)
        XCTAssertEqual(curve("EnvD", "Decay"), .oneSided)
        XCTAssertEqual(curve("EnvADSR", "Sustain"), .linear)
        XCTAssertEqual(curve("OscA", "FreqCoarse"), .twoSided)
        XCTAssertEqual(curve("OscA", "FreqFine"), .twoSided)
        XCTAssertEqual(curve("Operator", "FreqFine"), .linear)
        XCTAssertEqual(curve("OscDual", "SawLevel"), .oneSidedInverse)
        XCTAssertEqual(curve("Compress", "Ratio"), .oneSided)
        XCTAssertEqual(curve("OscA", "Waveform"), .linear, "selektor fali mutuje się w oryginale")
        XCTAssertEqual(curve("OscA", "Kbt"), Optional(.none))
        XCTAssertEqual(curve("EnvADSR", "OutputType"), Optional(.none))
        XCTAssertNil(curve("Driver", "Stiffness"), "modułu nie ma w oryginale")
    }

    /// Domyślnie zamknięta jest jedna kategoria — `OscFreq` (maska 0xFE
    /// z konstruktora Muta Synth Data).
    func testDefaultLocksCloseOscFreqOnly() {
        let locks = G2MutatorLocks()
        XCTAssertTrue(locks.isLocked(.oscFreq))
        for category in G2MutatorCategory.allCases where category != .oscFreq {
            XCTAssertFalse(locks.isLocked(category))
        }
    }

    /// Solo przesłania wszystkie zwykłe blokady — i wycina parametry bez kategorii.
    func testSoloOverridesEverythingElse() {
        var locks = G2MutatorLocks()
        locks.toggleSolo(.envelope)
        XCTAssertTrue(locks.allows(.envelope))
        XCTAssertFalse(locks.allows(.oscFine))
        XCTAssertFalse(locks.allows(nil), "parametry bez kategorii też stoją")
    }

    /// Zablokowana kategoria zostaje nietknięta przez `Mutate`.
    func testLockedCategoryIsCopiedFromTheParent() throws {
        let (_, genome, parent) = try fixture()
        var locks = G2MutatorLocks(enabled: 0xFF, solo: 0)
        locks.toggleLock(.oscFreq)
        var generator = SeededGenerator(seed: 5)
        let child = G2Mutator.mutateOnce(parent: parent, genome: genome,
                                         settings: G2MutatorSettings(probability: 1, range: 0.5),
                                         locks: locks, using: &generator)
        var checked = 0
        for gene in genome.genes where gene.category == .oscFreq && gene.isMutable {
            XCTAssertEqual(child[gene.key], parent[gene.key])
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "fixture ma oscylatory")
    }

    // MARK: - Mutate

    func testMutateMakesSixChildren() throws {
        let (_, genome, parent) = try fixture()
        var generator = SeededGenerator(seed: 1)
        let children = G2Mutator.mutate(parent: parent, genome: genome,
                                        settings: G2MutatorSettings(), locks: allOpen,
                                        using: &generator)
        XCTAssertEqual(children.count, 6, "tyle samo co w oryginale")
        XCTAssertFalse(children[0].isEmpty)
    }

    /// Prawdopodobieństwo 0 = dziecko jest kopią rodzica.
    func testZeroProbabilityChangesNothing() throws {
        let (_, genome, parent) = try fixture()
        var generator = SeededGenerator(seed: 2)
        let child = G2Mutator.mutateOnce(parent: parent, genome: genome,
                                         settings: G2MutatorSettings(probability: 0, range: 0.5),
                                         locks: allOpen, using: &generator)
        XCTAssertEqual(child, parent)
    }

    /// Przy prawdopodobieństwie 1 zmienia się (prawie) wszystko, ale nic nie wychodzi
    /// poza zakres parametru — krawędź odbija, nie przycina. Parametry, których
    /// mutator nie rusza, zostają na swoim.
    func testMutationStaysInsideParameterRange() throws {
        let (_, genome, parent) = try fixture()
        var generator = SeededGenerator(seed: 3)
        let child = G2Mutator.mutateOnce(parent: parent, genome: genome,
                                         settings: G2MutatorSettings(probability: 1, range: 0.5),
                                         locks: allOpen, using: &generator)
        var moved = 0
        var mutableCount = 0
        for gene in genome.genes {
            let value = try XCTUnwrap(child[gene.key])
            if gene.isMutable, !gene.moduleExcluded {
                mutableCount += 1
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, Double(gene.maxValue))
                if value != parent[gene.key] { moved += 1 }
            } else {
                XCTAssertEqual(value, parent[gene.key])
            }
        }
        XCTAssertGreaterThan(moved, mutableCount / 2, "przy pewności ruszyć się ma większość")
    }

    func testSameSeedGivesTheSameChildren() throws {
        let (_, genome, parent) = try fixture()
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        let first = G2Mutator.mutate(parent: parent, genome: genome,
                                     settings: G2MutatorSettings(), locks: allOpen, using: &a)
        let second = G2Mutator.mutate(parent: parent, genome: genome,
                                      settings: G2MutatorSettings(), locks: allOpen, using: &b)
        XCTAssertEqual(first, second)
    }

    /// Odbicie od krawędzi: wartość ponad maksimum wraca tyle samo w dół, ujemna
    /// odbija się od zera — inaczej mutacja przy krańcu skali zbijałaby wszystkie
    /// dzieci w tę samą wartość.
    func testReflectionBouncesOffBothEdges() {
        XCTAssertEqual(G2Mutator.reflect(-10, max: 127), 10, accuracy: 0.001)
        XCTAssertEqual(G2Mutator.reflect(137.5, max: 127), 116.5, accuracy: 0.001)
        XCTAssertEqual(G2Mutator.reflect(64, max: 127), 64, accuracy: 0.001)
        let far = G2Mutator.reflect(600, max: 127)
        XCTAssertGreaterThanOrEqual(far, 0)
        XCTAssertLessThanOrEqual(far, 127)
    }

    // MARK: - Krzywe 2–4

    /// Gen liniowy nie wie o krzywych: `applyCurve(.linear)` losuje dokładnie tym
    /// samym wzorem i tą samą jedną liczbą co `applyCurve1`, więc wyniki
    /// z ustalonym ziarnem nie ruszają się bit w bit.
    func testLinearCurveIsTheOldFormulaBitForBit() {
        for seed in UInt64(1) ... 20 {
            var a = SeededGenerator(seed: seed)
            var b = SeededGenerator(seed: seed)
            let plain = G2Mutator.applyCurve1(max: 127, value: 40, range: 0.19, using: &a)
            let routed = G2Mutator.applyCurve(.linear, max: 127, value: 40, range: 0.19, using: &b)
            XCTAssertEqual(plain, routed)
            XCTAssertEqual(a.next(), b.next(), "obie drogi zużyły tyle samo losowań")
        }
    }

    /// Krzywa w tę i z powrotem oddaje wartość wejściową — wykładniki oryginału
    /// (`p + 1` i `−1/(p − 1)`) są parą wzajemnie odwrotną.
    func testCurvesRoundTrip() {
        for curve in [G2ParamClass.Curve.oneSided, .oneSidedInverse, .twoSided] {
            for value in stride(from: 0.0, through: 127.0, by: 7.5) {
                let there = G2Mutator.warp(value, curve: curve, max: 127, inverse: false)
                let back = G2Mutator.warp(there, curve: curve, max: 127, inverse: true)
                XCTAssertEqual(back, value, accuracy: 1e-9, "\(curve) przy \(value)")
            }
        }
    }

    /// Liczby wprost ze wzorów `ApplySingleCurve` / `ApplyDualCurve` oryginału:
    /// skala to `maks + 0,99`, środek dwustronnej stoi w miejscu, koniec skali też.
    func testCurveFormulasMatchTheOriginal() {
        let span = 127.99
        XCTAssertEqual(G2Mutator.singleCurve(-1.5, span / 2, max: 127), pow(0.5, 0.4) * span, accuracy: 1e-9)
        XCTAssertEqual(G2Mutator.singleCurve(1.5, span / 2, max: 127), pow(0.5, 2.5) * span, accuracy: 1e-9)
        XCTAssertEqual(G2Mutator.singleCurve(1.5, span, max: 127), span, accuracy: 1e-9)
        XCTAssertEqual(G2Mutator.singleCurve(1.5, -span / 2, max: 127), -pow(0.5, 2.5) * span, accuracy: 1e-9)
        XCTAssertEqual(G2Mutator.dualCurve(low: 2, high: 2, span / 2, max: 127), span / 2, accuracy: 1e-9)
        XCTAssertEqual(G2Mutator.dualCurve(low: 2, high: 2, span, max: 127), span, accuracy: 1e-9)
        XCTAssertEqual(G2Mutator.dualCurve(low: 2, high: 2, 0, max: 127), 0, accuracy: 1e-9)
        // ćwierć skali w górę od środka: offset 0,5 → 0,5³ + 1 → połowa z tego razy skala
        XCTAssertEqual(G2Mutator.dualCurve(low: 2, high: 2, span * 0.75, max: 127),
                       0.5 * (pow(0.5, 3) + 1) * span, accuracy: 1e-9)
    }

    /// Rozkład 4000 dzieci jednego parametru: jaka część spadła poniżej rodzica
    /// i jaka została w promieniu ±2 od niego.
    private func spread(_ curve: G2ParamClass.Curve, from value: Double, seed: UInt64) -> (below: Double, near: Double) {
        var generator = SeededGenerator(seed: seed)
        let trials = 4000
        var below = 0
        var near = 0
        for _ in 0 ..< trials {
            let moved = G2Mutator.applyCurve(curve, max: 127, value: value, range: 0.1, using: &generator)
            let child = G2Mutator.reflect(moved, max: 127)
            if child < value { below += 1 }
            if abs(child - value) <= 2 { near += 1 }
        }
        return (Double(below) / Double(trials), Double(near) / Double(trials))
    }

    /// Liniowa: połowa dzieci poniżej rodzica, w promieniu ±2 mniej więcej
    /// 4/25,4 — punkt odniesienia dla trzech krzywych niżej.
    func testLinearCurveIsSymmetricAroundTheParent() {
        let linear = spread(.linear, from: 64, seed: 10)
        XCTAssertEqual(linear.below, 0.5, accuracy: 0.05)
        XCTAssertEqual(linear.near, 0.16, accuracy: 0.05)
    }

    /// Jednostronna (Attack): krótki czas rodzi przede wszystkim jeszcze krótsze
    /// dzieci — rozkład wykładniczy ściąga w dół skali; przy długim czasie krzywa
    /// jest już prawie liniowa.
    func testOneSidedCurvePullsShortTimesShorter() {
        XCTAssertGreaterThan(spread(.oneSided, from: 10, seed: 11).below, 0.7)
        XCTAssertEqual(spread(.oneSided, from: 100, seed: 12).below, 0.5, accuracy: 0.06)
    }

    /// Odwrotna jednostronna (poziomy OscDual): to samo w drugą stronę — dzieci
    /// częściej głośniejsze od rodzica.
    func testInverseCurvePullsLevelsUp() {
        XCTAssertLessThan(spread(.oneSidedInverse, from: 30, seed: 21).below, 0.4)
    }

    /// Dwustronna (strój, panorama): rodzic w środku skali trzyma większość dzieci
    /// w promieniu ±2 (liniowa: ok. 16 %); z dala od środka rozkład wraca do zwykłego.
    func testTwoSidedCurveKeepsTheMiddleTight() {
        XCTAssertGreaterThan(spread(.twoSided, from: 64, seed: 31).near, 0.45)
        XCTAssertLessThan(spread(.twoSided, from: 20, seed: 32).near, 0.25)
    }

    /// Przedział wystający poza skalę wraca odbiciem także po krzywej — żadne
    /// dziecko nie ląduje poza `0…maks`.
    func testCurvedMutationStaysInsideTheRangeAtTheEdges() {
        for curve in [G2ParamClass.Curve.oneSided, .oneSidedInverse, .twoSided] {
            var generator = SeededGenerator(seed: 41)
            for value in [0.0, 1.0, 126.0, 127.0] {
                for _ in 0 ..< 200 {
                    let moved = G2Mutator.applyCurve(curve, max: 127, value: value, range: 0.5, using: &generator)
                    let child = G2Mutator.reflect(moved, max: 127)
                    XCTAssertGreaterThanOrEqual(child, 0, "\(curve) z \(value)")
                    XCTAssertLessThanOrEqual(child, 127, "\(curve) z \(value)")
                    XCTAssertFalse(child.isNaN, "\(curve) z \(value)")
                }
            }
        }
    }

    // MARK: - Randomize

    func testRandomizeIgnoresTheParentValues() throws {
        let (_, genome, parent) = try fixture()
        var generator = SeededGenerator(seed: 7)
        let children = G2Mutator.randomize(base: parent, genome: genome,
                                           locks: allOpen, using: &generator)
        XCTAssertEqual(children.count, 6)
        XCTAssertNotEqual(children[0], children[1], "każde dziecko losowane osobno")
        for gene in genome.genes where !gene.isMutable {
            XCTAssertEqual(children[0][gene.key], parent[gene.key],
                           "nieruchome parametry przepisane z rodzica")
        }
    }

    /// Randomize losuje w skali WŁASNEJ parametru. Przyciski `Evnt` sekwencerów mają
    /// dwa stany; losowanie z pełnej skali 0…127 dawało „włączony" w 127 przypadkach
    /// na 128, więc po Randomize wszystkie kroki wychodziły zapalone jednakowo,
    /// podczas gdy wartości kroków (pełna skala) losowały się poprawnie.
    func testRandomizeStaysInsideTheParameterScale() {
        var patch = G2Patch()
        var sequencer = G2Module(id: 1, typeID: 146, area: .voice) // SeqLev
        sequencer.parameters = Array(repeating: 0, count: 38)
        sequencer.parameterVariations = Array(repeating: sequencer.parameters,
                                              count: G2Patch.runtimeVariationCount)
        sequencer.hasParameterEntry = true
        patch.add(module: sequencer)

        let genome = G2MutatorGenome(patch: patch)
        let base = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        var generator = SeededGenerator(seed: 7)
        let children = G2Mutator.randomize(base: base, genome: genome,
                                           locks: allOpen, using: &generator)

        let steps = (16 ..< 32).map { G2Individual.Key(area: .voice, moduleID: 1, paramIndex: $0) }
        let values = children.flatMap { child in steps.compactMap { child[$0] } }
        XCTAssertEqual(values.count, 6 * 16)
        XCTAssertTrue(values.allSatisfy { $0 <= 1 }, "krok Evnt ma dwa stany, nie 128")
        XCTAssertTrue(values.contains(0), "wszystkie kroki zapalone to nie jest losowanie")
        XCTAssertTrue(values.contains(1))
    }

    /// Patch z jednym SeqNote o długości 16 (`Length` = 15).
    private func seqNotePatch() -> G2Patch {
        var patch = G2Patch()
        var sequencer = G2Module(id: 1, typeID: 121, area: .voice) // SeqNote
        sequencer.parameters = Array(repeating: 64, count: 37)
        sequencer.parameters[33] = 15
        sequencer.parameterVariations = Array(repeating: sequencer.parameters,
                                              count: G2Patch.runtimeVariationCount)
        sequencer.hasParameterEntry = true
        patch.add(module: sequencer)
        return patch
    }

    /// Zgłoszenie 2026-10-26: długość SeqNote ustawiona na 8 przy słuchanym dziecku
    /// wracała po Randomize do 16. Randomize losuje z kratki z focusem, a ręczna zmiana
    /// szła tylko do bufora odsłuchu — kratka pamiętała 16. Oryginał
    /// (`SetParamValue`) wpisuje taką zmianę także do kratki z focusem.
    func testEditWhileAuditioningGoesIntoTheFocusedBox() {
        let state = makeState(seqNotePatch())
        undoStep(on: state) { state.mutatorRandomize() }
        XCTAssertTrue(state.isAuditioningMutation)

        undoStep(on: state) { state.setParameter(moduleID: 1, paramIndex: 33, value: 7, area: .voice) }
        let length = G2Individual.Key(area: .voice, moduleID: 1, paramIndex: 33)
        XCTAssertEqual(state.mutatorParents[0]?[length], 7, "kratka z focusem gra 8 kroków")

        undoStep(on: state) { state.mutatorRandomize() }
        let children = state.mutatorParents.prefix(G2Mutator.childCount).compactMap(\.self)
        XCTAssertEqual(children.count, G2Mutator.childCount)
        XCTAssertTrue(children.allSatisfy { $0[length] == 7 }, "Length nie jest losowany — zostaje 8")

        state.undoManager.undo() // drugi Randomize
        state.undoManager.undo() // zmiana Length
        XCTAssertEqual(state.mutatorParents[0]?[length], 15, "undo cofa też kratkę")
    }

    /// Zgłoszenie 2026-10-26: SeqLev dodany po pierwszym Randomize nie losował się wcale
    /// — kratki go nie znały, a operacje pomijają parametry, których rodzic nie ma.
    /// Oryginał (`AddModule`) dopisuje nowy moduł do wszystkich kratek.
    func testModuleAddedAfterBreedingIsRandomizedToo() throws {
        let state = makeState(seqNotePatch())
        undoStep(on: state) { state.mutatorRandomize() }
        var added: Int?
        undoStep(on: state) { added = state.addModule(typeID: 146, area: .voice) } // SeqLev
        let id = try XCTUnwrap(added)

        undoStep(on: state) { state.mutatorRandomize() }
        let steps = (0 ..< 16).map { G2Individual.Key(area: .voice, moduleID: id, paramIndex: $0) }
        let children = state.mutatorParents.prefix(G2Mutator.childCount).compactMap(\.self)
        let rows = children.map { child in steps.map { child[$0] } }
        XCTAssertTrue(rows.allSatisfy { $0.allSatisfy { $0 != nil } }, "dzieci znają SeqLev")
        XCTAssertGreaterThan(Set(rows).count, 1, "kroki SeqLev się losują")
    }

    /// Patch z jednym modułem każdego typu, który oryginał zna — parametry na zerze.
    private func everyModulePatch() -> G2Patch {
        var patch = G2Patch()
        for (index, def) in ModuleDatabase.all.enumerated()
            where G2ParamClass.maximum(moduleTypeID: def.id, paramIndex: 0) != nil
        {
            var module = G2Module(id: index + 1, typeID: def.id, area: .voice)
            module.parameters = Array(repeating: 0, count: def.paramNames.count)
            module.parameterVariations = Array(repeating: module.parameters,
                                               count: G2Patch.runtimeVariationCount)
            patch.add(module: module)
        }
        return patch
    }

    /// Skala każdego parametru = maksimum z opisu parametru w oryginale (bajt +0x0B),
    /// z którego losuje `CopyRandomizeContext`. Przegląd 2026-10-26: na 903 parametry
    /// różniło się 16, w tym `LevConv.OutputType` (6 pozycji) losowany z 0…127.
    func testGenomeScaleMatchesTheOriginalForEveryParameter() {
        let patch = everyModulePatch()
        let types = Dictionary(uniqueKeysWithValues: patch.modules(in: .voice).map { ($0.id, $0.typeID) })
        let genome = G2MutatorGenome(patch: patch)
        var mismatches: [String] = []
        for gene in genome.genes {
            guard let typeID = types[gene.moduleID],
                  let maximum = G2ParamClass.maximum(moduleTypeID: typeID, paramIndex: gene.paramIndex)
            else { continue }
            if gene.maxValue != max(1, maximum) {
                mismatches.append("\(typeID).\(gene.paramIndex): \(gene.maxValue) ≠ \(maximum)")
            }
        }
        XCTAssertGreaterThan(genome.genes.count, 900)
        XCTAssertEqual(mismatches, [])
    }

    /// Randomize i Mutate przy zdjętych blokadach: każdy parametr, który wolno ruszać,
    /// dostaje różne wartości i nigdy nie wychodzi poza swoją skalę; pozostałe zostają
    /// — także w modułach wyłączonych z mutacji z góry (wejścia, wyjścia, MIDI…).
    func testRandomizeAndMutateReachEveryMutableParameterInsideItsScale() {
        let patch = everyModulePatch()
        let genome = G2MutatorGenome(patch: patch)
        let base = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        var generator = SeededGenerator(seed: 26)
        var children: [G2Individual] = []
        for _ in 0 ..< 20 {
            children += G2Mutator.randomize(base: base, genome: genome, locks: allOpen, using: &generator)
            children += G2Mutator.mutate(parent: base, genome: genome, settings: G2MutatorSettings(),
                                         locks: allOpen, using: &generator)
        }
        var problems: [String] = []
        for gene in genome.genes {
            let values = Set(children.compactMap { $0[gene.key] })
            let name = "\(gene.moduleID).\(gene.paramIndex)"
            if values.contains(where: { $0 < 0 || $0 > Double(gene.maxValue) }) {
                problems.append("\(name) poza 0…\(gene.maxValue): \(values.sorted())")
            }
            let enabled = G2Mutator.isEnabled(gene, locks: allOpen)
            if enabled, values.count < 2 { problems.append("\(name) się nie zmienia") }
            if !enabled, values != [0] { problems.append("\(name) zablokowany, a ruszony") }
        }
        XCTAssertEqual(problems, [])
    }

    /// Gen z fixture o zadanej krzywej — do testów rozkładu Randomize.
    private func gene(_ curve: G2ParamClass.Curve, in genome: G2MutatorGenome) throws -> G2MutatorGenome.Gene {
        try XCTUnwrap(genome.genes.first { $0.curve == curve && $0.maxValue == 127 && !$0.moduleExcluded })
    }

    /// Rozkład losowań z całej skali: część poniżej połowy i część w promieniu ±16
    /// od środka. Liniowa: 0,5 i 0,25 — punkt odniesienia.
    private func randomSpread(_ gene: G2MutatorGenome.Gene, base: G2Individual, seed: UInt64) -> (low: Double, middle: Double, min: Double) {
        var generator = SeededGenerator(seed: seed)
        let trials = 4000
        var low = 0
        var middle = 0
        var lowest = Double.infinity
        for _ in 0 ..< trials {
            let value = G2Mutator.randomValue(for: gene, base: base, using: &generator)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 127)
            if value < 64 { low += 1 }
            if abs(value - 64) <= 16 { middle += 1 }
            lowest = min(lowest, value)
        }
        return (Double(low) / Double(trials), Double(middle) / Double(trials), lowest)
    }

    /// Liniowy gen losuje równomiernie z całej skali — jak dotąd; wynik jest
    /// przycięty do `0…maks`, nie odbity, i obcięty w dół do pełnej wartości
    /// (zapas `+0,999` daje równe przedziały tylko przy obcinaniu).
    func testRandomizeLinearIsUniformAndClipped() throws {
        let (_, genome, parent) = try fixture()
        let linear = try gene(.linear, in: genome)
        let spread = randomSpread(linear, base: parent, seed: 51)
        XCTAssertEqual(spread.low, 0.5, accuracy: 0.05)
        XCTAssertEqual(spread.middle, 0.25, accuracy: 0.05)
        for seed in UInt64(1) ... 10 {
            var a = SeededGenerator(seed: seed)
            var b = SeededGenerator(seed: seed)
            let plain = min(127, Double.random(in: 0 ..< 1, using: &a) * 127.999).rounded(.down)
            XCTAssertEqual(G2Mutator.randomValue(for: linear, base: parent, using: &b), plain)
        }
    }

    /// Jednostronna (Attack, FM): losowanie z całej skali też idzie krzywą —
    /// większość wyników w dolnej części (`0,5^0,4 ≈ 76 %` poniżej połowy).
    func testRandomizeOneSidedFavoursTheLowerHalf() throws {
        let (_, genome, parent) = try fixture()
        let spread = try randomSpread(gene(.oneSided, in: genome), base: parent, seed: 52)
        XCTAssertEqual(spread.low, 0.76, accuracy: 0.05)
    }

    /// Dwustronna (strój): losowanie zbija się do środka skali
    /// (`0,25^⅓ ≈ 63 %` w promieniu ±16; liniowa 25 %).
    func testRandomizeTwoSidedFavoursTheMiddle() throws {
        let (_, genome, parent) = try fixture()
        let spread = try randomSpread(gene(.twoSided, in: genome), base: parent, seed: 53)
        XCTAssertEqual(spread.middle, 0.63, accuracy: 0.05)
    }

    /// Oscylator w trybie Partials: `FreqCoarse` losuje się tylko z górnej części
    /// skali (od 49 w górę) — w innych trybach z całej.
    func testRandomizePartialsCoarseNeverGoesBelow49() throws {
        let (_, genome, parent) = try fixture()
        let coarse = try XCTUnwrap(genome.genes.first { $0.freqModeKey != nil })
        let modeKey = try XCTUnwrap(coarse.freqModeKey)
        XCTAssertEqual(coarse.curve, .twoSided, "wyjątek dotyczy tylko FreqCoarse oscylatorów")

        var semitones = parent
        semitones[modeKey] = 0
        XCTAssertLessThan(randomSpread(coarse, base: semitones, seed: 61).min, 20)

        var partials = parent
        partials[modeKey] = 3
        let spread = randomSpread(coarse, base: partials, seed: 62)
        XCTAssertGreaterThanOrEqual(spread.min, 49)
        XCTAssertLessThan(spread.low, 0.55, "mediana wokół 64")
        XCTAssertGreaterThan(spread.low, 0.35)

        var generator = SeededGenerator(seed: 63)
        let child = G2Mutator.randomize(base: partials, genome: genome, locks: allOpen, using: &generator)[0]
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(child[coarse.key]), 49)
        XCTAssertEqual(child[modeKey], 3, "FreqMode jest klasą nieruchomą — zostaje")
    }

    // MARK: - Interpolate

    /// Dziecko `i` leży w (i+1)/7 drogi z Mother do Father — `GetInterpolatedChildrenMolecules`.
    func testInterpolationStepsSeventhsFromMotherToFather() throws {
        let (patch, genome, mother) = try fixture()
        var father = mother
        let gene = try XCTUnwrap(genome.genes.first { $0.isMutable })
        for key in father.values.keys {
            father[key] = 0
        }
        father[gene.key] = 70
        var motherAtZero = mother
        for key in motherAtZero.values.keys {
            motherAtZero[key] = 0
        }
        motherAtZero[gene.key] = 0

        let children = G2Mutator.interpolate(mother: motherAtZero, father: father, genome: genome)
        XCTAssertEqual(children.count, 6)
        for (index, child) in children.enumerated() {
            XCTAssertEqual(try XCTUnwrap(child[gene.key]), 70.0 * Double(index + 1) / 7.0, accuracy: 0.0001)
        }
        XCTAssertFalse(patch.voiceModules.isEmpty)
    }

    /// Interpolacja rusza WSZYSTKIE parametry, także te w kategoriach zablokowanych
    /// — inaczej przejście nie byłoby płynne. Tak jest w oryginale i tak mówi instrukcja.
    func testInterpolationIgnoresLocks() throws {
        let (_, genome, mother) = try fixture()
        var father = mother
        let locked = try XCTUnwrap(genome.genes.first { $0.category == .oscFreq })
        father[locked.key] = (mother[locked.key] ?? 0) + 20
        let children = G2Mutator.interpolate(mother: mother, father: father, genome: genome)
        XCTAssertNotEqual(children[2][locked.key], mother[locked.key])
    }

    // MARK: - Cross

    /// Krzyżowanie nie wymyśla wartości — każdy parametr dziecka pochodzi od
    /// któregoś z rodziców.
    func testCrossOnlyTakesParentValues() throws {
        let (_, genome, mother) = try fixture()
        var father = mother
        for key in father.values.keys {
            father[key] = 13
        }
        var generator = SeededGenerator(seed: 9)
        let children = G2Mutator.cross(mother: mother, father: father, genome: genome,
                                       settings: G2MutatorSettings(crossProbability: 0.3),
                                       using: &generator)
        XCTAssertEqual(children.count, 6)
        for child in children {
            for gene in genome.genes {
                let value = try XCTUnwrap(child[gene.key])
                XCTAssertTrue(value == mother[gene.key] || value == 13)
            }
        }
    }

    /// Prawdopodobieństwo 0 = kopiowanie nigdy nie przeskakuje, więc każdy obszar
    /// dziecka jest wiernym odbiciem jednego z rodziców. Moduły i ustawienia patcha
    /// startują od osobno losowanego rodzica — jak trzy `RecombineContext` oryginału.
    func testZeroCrossProbabilityGivesWholeAreas() throws {
        let (_, genome, mother) = try fixture()
        var father = mother
        for key in father.values.keys {
            father[key] = 13
        }
        var generator = SeededGenerator(seed: 4)
        let children = G2Mutator.cross(mother: mother, father: father, genome: genome,
                                       settings: G2MutatorSettings(crossProbability: 0),
                                       using: &generator)
        for child in children {
            let modules = Set(genome.genes.map { child[$0.key] == mother[$0.key] })
            let settings = Set(G2Mutator.settingKeys.map { child[$0] == mother[$0] })
            XCTAssertEqual(modules.count, 1, "wszystkie moduły od jednego rodzica")
            XCTAssertEqual(settings.count, 1, "wszystkie ustawienia od jednego rodzica")
        }
    }

    // MARK: - Morfy w osobniku

    /// Patch bez żadnych morfów poza jednym: pierwszy mutowalny parametr idzie
    /// w wariacji 0 za morfem 2 z zakresem 40.
    private func morphFixture() throws -> (patch: G2Patch, genome: G2MutatorGenome, key: G2Individual.Key) {
        var patch = try fixturePatch()
        for variation in patch.morphAssignments.indices {
            patch.morphAssignments[variation] = []
        }
        patch.setActiveVariation(0)
        let genome = G2MutatorGenome(patch: patch)
        let gene = try XCTUnwrap(genome.genes.first { $0.isMutable && !$0.moduleExcluded })
        XCTAssertTrue(patch.setMorphRange(variation: 0, location: gene.area.rawValue, moduleID: gene.moduleID,
                                          paramIndex: gene.paramIndex, morph: 2, range: 40))
        return (patch, genome, gene.key)
    }

    func testIndividualCarriesTheMorphsOfItsVariation() throws {
        let (patch, genome, key) = try morphFixture()
        let sound = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        XCTAssertEqual(sound.morphRange(key, morph: 2), 40)
        XCTAssertEqual(sound.morphRange(key, morph: 0), 0)
        XCTAssertEqual(sound.morphAssignments.count, 1)
        XCTAssertTrue(G2Mutator.individual(from: patch, variation: 1, genome: genome).morphs.isEmpty)
    }

    /// Mutate i Randomize nie ruszają morfów — dziecko dziedziczy je po rodzicu w całości.
    func testMutateAndRandomizeCopyTheParentsMorphs() throws {
        let (patch, genome, _) = try morphFixture()
        let parent = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        var generator = SeededGenerator(seed: 3)
        let mutated = G2Mutator.mutate(parent: parent, genome: genome,
                                       settings: G2MutatorSettings(probability: 1, range: 0.5),
                                       locks: allOpen, using: &generator)
        let random = G2Mutator.randomize(base: parent, genome: genome, locks: allOpen, using: &generator)
        for child in mutated + random {
            XCTAssertEqual(child.morphs, parent.morphs)
        }
    }

    /// Cross: morf zawsze od tego samego rodzica co wartość — i bez limitu 25.
    func testCrossTakesTheMorphWithTheValue() throws {
        let (_, genome, base) = try fixture()
        var mother = base
        var father = base
        for key in base.values.keys {
            mother[key] = 5
            mother.morphs[key] = [0: 20]
            father[key] = 13
            father.morphs[key] = [1: -30]
        }
        var generator = SeededGenerator(seed: 9)
        let children = G2Mutator.cross(mother: mother, father: father, genome: genome,
                                       settings: G2MutatorSettings(crossProbability: 0.3),
                                       using: &generator)
        var sawMother = false
        var sawFather = false
        for child in children {
            for gene in genome.genes {
                if child[gene.key] == 5 {
                    XCTAssertEqual(child.morphs[gene.key], [0: 20])
                    sawMother = true
                } else {
                    XCTAssertEqual(child[gene.key], 13)
                    XCTAssertEqual(child.morphs[gene.key], [1: -30])
                    sawFather = true
                }
            }
            XCTAssertGreaterThan(child.morphAssignments.count, G2Morph.maxAssignmentsPerVariation,
                                 "dziecko może nieść więcej niż 25 przypisań")
        }
        XCTAssertTrue(sawMother && sawFather)
    }

    /// Interpolate: zakres = a + (b − a)·t obcięty w stronę zera; zero znaczy „bez morfu".
    func testInterpolateBlendsMorphRangesTowardZero() throws {
        let (_, genome, base) = try fixture()
        let key = try XCTUnwrap(genome.genes.first?.key)
        var mother = base
        var father = base
        mother.setMorphRange(key, morph: 0, range: 70)
        mother.setMorphRange(key, morph: 2, range: 3)
        father.setMorphRange(key, morph: 1, range: 35)
        let children = G2Mutator.interpolate(mother: mother, father: father, genome: genome)
        for (index, child) in children.enumerated() {
            let t = (Double(index) + 1.0) / 7.0
            XCTAssertEqual(child.morphRange(key, morph: 0), Int(70 + (0 - 70) * t))
            XCTAssertEqual(child.morphRange(key, morph: 1), Int(0 + (35 - 0) * t))
        }
        XCTAssertEqual(children[0].morphRange(key, morph: 2), 2, "blisko matki morf 2 jeszcze jest")
        XCTAssertEqual(children[5].morphRange(key, morph: 2), 0, "blisko ojca zakres spadł do zera")
        XCTAssertNil(children[5].morphs[key]?[2], "zerowego zakresu nie trzymamy")
        XCTAssertGreaterThan(children[0].morphRange(key, morph: 0), children[5].morphRange(key, morph: 0))
        XCTAssertLessThan(children[0].morphRange(key, morph: 1), children[5].morphRange(key, morph: 1))
    }

    /// Zapis do wariacji wymienia jej morfy na morfy dźwięku: pierwsze 25 w porządku
    /// klucza, stare przypisania znikają — także te z obszaru ustawień patcha, bo
    /// dźwięk niesie i je.
    func testWritingASoundReplacesTheMorphsAndKeepsTheFirst25() throws {
        var (patch, genome, key) = try morphFixture()
        patch.setMorphRange(variation: 3, location: 2, moduleID: 1, paramIndex: 0, morph: 0, range: 10)
        patch.setMorphRange(variation: 3, location: key.location, moduleID: key.moduleID,
                            paramIndex: key.paramIndex, morph: 5, range: 7)
        var sound = G2Individual()
        for gene in genome.genes.prefix(30) {
            sound.setMorphRange(gene.key, morph: 0, range: 12)
        }
        sound.setMorphRange(.setting(module: 3, param: 1), morph: 1, range: -20)
        XCTAssertEqual(sound.morphAssignments.count, 31)

        let changes = patch.apply(sound, variation: 3)

        let written = patch.morphs(in: 3)
        XCTAssertEqual(written, Array(sound.morphAssignments.prefix(25)))
        XCTAssertTrue(written.allSatisfy { $0.area != nil }, "obszar 2 jest ostatni w porządku klucza — nie zmieścił się")
        XCTAssertTrue(changes.morphs.contains { $0.morph == 5 && $0.range == 0 }, "stare przypisanie zdjęte")
        XCTAssertTrue(changes.morphs.contains { $0.location == 2 && $0.range == 0 }, "stary morf obszaru 2 zdjęty")
        XCTAssertEqual(changes.morphs.filter { $0.range != 0 }.count, 25)
        XCTAssertEqual(patch.morphs(in: 0).count, 1, "inna wariacja nietknięta")
    }

    /// Cała droga w edytorze: dziecko dziedziczy morf, odsłuch wysyła go do bufora,
    /// przeciągnięcie na wariację zapisuje go w niej, undo zdejmuje.
    func testCopyToVariationCarriesTheMorphs() throws {
        let (patch, _, key) = try morphFixture()
        let state = makeState(patch)
        var dumped: [G2MorphAssignment] = []
        state.onMutatorAudition = { _, patch, variation in
            dumped = patch.morphs(in: variation)
        }

        undoStep(on: state) { state.mutatorMutate() }
        let buffer = G2Patch.mutatorVariation
        XCTAssertEqual(state.patch.morphRange(variation: buffer, location: key.location,
                                              moduleID: key.moduleID, paramIndex: key.paramIndex, morph: 2), 40)
        XCTAssertTrue(dumped.contains { $0.morph == 2 && $0.range == 40 },
                      "morf jedzie w zrzucie bufora, nie osobną komendą 0x43")

        undoStep(on: state) { state.mutatorDrag(from: .child(0), to: G2MutatorBox(.variations, 3)) }
        XCTAssertEqual(state.patch.morphRange(variation: 3, location: key.location,
                                              moduleID: key.moduleID, paramIndex: key.paramIndex, morph: 2), 40)
        XCTAssertTrue(state.patch.morphs(in: 1).isEmpty, "inne wariacje nietknięte")

        state.undoManager.undo()
        XCTAssertTrue(state.patch.morphs(in: 3).isEmpty)
    }

    // MARK: - Ustawienia patcha w osobniku

    /// Osobnik niesie obszar 2: gałki i źródła morfów, Glide, Bend, Vibrato, Arp…
    func testIndividualCarriesThePatchSettings() throws {
        var patch = try fixturePatch()
        patch.setMorphDial(3, in: 0, value: 77)
        patch.variationSettings[0].glideTime = 51
        let genome = G2MutatorGenome(patch: patch)
        let sound = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        XCTAssertEqual(sound[.setting(module: 1, param: 3)], 77)
        XCTAssertEqual(sound[.setting(module: G2PatchSetting.glideTime.module, param: G2PatchSetting.glideTime.param)], 51)
        XCTAssertEqual(G2Mutator.settingKeys.count, 16 + G2PatchSetting.allCases.count)
        XCTAssertTrue(G2Mutator.settingKeys.allSatisfy { sound[$0] != nil })
    }

    /// Mutate i Randomize przepisują ustawienia patcha bez zmian (`CopyContext`).
    func testMutateAndRandomizeLeaveThePatchSettingsAlone() throws {
        let (_, genome, parent) = try fixture()
        var generator = SeededGenerator(seed: 5)
        let settings = G2MutatorSettings(probability: 1, range: 0.5)
        let mutated = G2Mutator.mutate(parent: parent, genome: genome, settings: settings,
                                       locks: allOpen, using: &generator)
        let randomized = G2Mutator.randomize(base: parent, genome: genome, locks: allOpen, using: &generator)
        for child in mutated + randomized {
            for key in G2Mutator.settingKeys {
                XCTAssertEqual(child[key], parent[key])
            }
        }
    }

    /// Cross bierze ustawienie od jednego z rodziców, Interpolate uśrednia — jak dla
    /// parametrów modułów.
    func testCrossAndInterpolateBlendThePatchSettings() throws {
        let (_, genome, mother) = try fixture()
        let glide = G2Individual.Key.setting(module: G2PatchSetting.glideTime.module,
                                             param: G2PatchSetting.glideTime.param)
        var father = mother
        for key in G2Mutator.settingKeys {
            father[key] = (mother[key] ?? 0) + 14
        }
        var generator = SeededGenerator(seed: 11)
        let crossed = G2Mutator.cross(mother: mother, father: father, genome: genome,
                                      settings: G2MutatorSettings(crossProbability: 0.5), using: &generator)
        var sawBoth: Set<Bool> = []
        for child in crossed {
            for key in G2Mutator.settingKeys {
                let value = try XCTUnwrap(child[key])
                XCTAssertTrue(value == mother[key] || value == father[key])
                sawBoth.insert(value == mother[key])
            }
        }
        XCTAssertEqual(sawBoth.count, 2, "przy 50% skoków dzieci biorą od obojga")

        let blended = G2Mutator.interpolate(mother: mother, father: father, genome: genome)
        let base = try XCTUnwrap(mother[glide])
        for (index, child) in blended.enumerated() {
            XCTAssertEqual(try XCTUnwrap(child[glide]), base + 14 * (Double(index) + 1) / 7, accuracy: 1e-9)
        }
    }

    /// Zapis dźwięku wpisuje ustawienia patcha do wariacji, a odsłuch wysyła je do
    /// bufora jako ustawienia obszaru 2 (`onPatchSettingChange`).
    func testWritingASoundCarriesThePatchSettings() throws {
        var (patch, genome, _) = try fixture()
        var sound = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        let glide = G2Individual.Key.setting(module: G2PatchSetting.glideTime.module,
                                             param: G2PatchSetting.glideTime.param)
        sound[glide] = 99
        sound[.setting(module: 1, param: 6)] = 42
        sound[.setting(module: 1, param: 8 + 6)] = 1
        let changes = patch.apply(sound, variation: 2)
        XCTAssertEqual(patch.variationSettings[2].glideTime, 99)
        XCTAssertEqual(patch.morphDial(6, in: 2), 42)
        XCTAssertEqual(patch.morphMode(6, in: 2), 1)
        XCTAssertTrue(changes.settings.contains { $0.moduleID == 3 && $0.paramIndex == 1 && $0.value == 99 })
        XCTAssertEqual(patch.variationSettings[0].glideTime, patch.variationSettings[1].glideTime, "inne wariacje nietknięte")

        patch.variationSettings[3].glideTime = 17
        XCTAssertNotEqual(patch.variationSettings[0].glideTime, 17)
        let state = makeState(patch)
        var single = 0
        var dumped: [Int] = []
        state.onPatchSettingChange = { _, _, _, _, _ in single += 1 }
        state.onMutatorAudition = { _, patch, variation in
            dumped.append(patch.variationSettings[variation].glideTime)
        }
        undoStep(on: state) { state.mutatorMutate() }
        let buffer = G2Patch.mutatorVariation
        undoStep(on: state) { state.mutatorDrag(from: G2MutatorBox(.variations, 3), to: .mother) }
        undoStep(on: state) { state.mutatorSetFocus(.mother) }
        XCTAssertEqual(single, 0, "obszar 2 nie idzie osobnymi komendami")
        XCTAssertEqual(dumped.last, 17, "zrzut niesie ustawienia obszaru 2")
        XCTAssertEqual(state.patch.variationSettings[buffer].glideTime, 17)
    }

    // MARK: - Prawdopodobieństwo, zasięg, Link

    /// Krzywa sprzężenia jest odwracalna i ma dokładnie te punkty zaczepienia, co
    /// stałe z oryginału: (prob 1,0 ↔ range 0,0289) i (prob 0,0484 ↔ range 0,49).
    func testLinkCurveMatchesTheOriginal() {
        XCTAssertEqual(G2MutatorSettings.probability(fromRange: 0.49), 0.0484, accuracy: 0.0001)
        XCTAssertEqual(G2MutatorSettings.range(fromProbability: 0.0484), 0.49, accuracy: 0.0001)
        XCTAssertEqual(G2MutatorSettings.range(fromProbability: 1.0), 0.0289, accuracy: 0.0001)
        // Duże prawdopodobieństwo = mały zasięg. To sedno przycisku `Link`.
        XCTAssertLessThan(G2MutatorSettings.range(fromProbability: 0.9),
                          G2MutatorSettings.range(fromProbability: 0.1))
    }

    /// Domyślne wartości z konstruktora Muta Synth Data i ich odczyt procentowy.
    func testDefaultsMatchTheOriginal() {
        let settings = G2MutatorSettings()
        XCTAssertEqual(settings.probability, 0.3721, accuracy: 0.0001)
        XCTAssertEqual(settings.range, 0.189, accuracy: 0.0001)
        XCTAssertEqual(settings.crossProbability, 0.15, accuracy: 0.0001)
        XCTAssertTrue(settings.link)
        XCTAssertEqual(G2MutatorSettings.percent(settings.probability), 37)
        XCTAssertEqual(G2MutatorSettings.percent(settings.range), 19)
        XCTAssertEqual(G2MutatorSettings.percent(settings.crossProbability), 15)
        // Para domyślna leży dokładnie na krzywej `Link`.
        XCTAssertEqual(G2MutatorSettings.range(fromProbability: settings.probability),
                       settings.range, accuracy: 0.0005)
    }

    func testLinkMovesTheOtherKnob() {
        var settings = G2MutatorSettings()
        settings.setProbability(0.8)
        XCTAssertEqual(settings.range, G2MutatorSettings.range(fromProbability: 0.8), accuracy: 0.0001)
        settings.link = false
        let range = settings.range
        settings.setProbability(0.2)
        XCTAssertEqual(settings.range, range, "bez Link gałki chodzą osobno")
    }

    // MARK: - Chromosom

    /// Rysunek powstaje ze WSZYSTKICH parametrów, więc zmiana czegokolwiek go zmienia,
    /// a dwa różne dźwięki dają dwie różne krzywe.
    func testChromosomeFollowsTheParameterValues() throws {
        let (patch, genome, parent) = try fixture()
        let points = G2Mutator.chromosome(of: parent, genome: genome)
        XCTAssertGreaterThan(points.count, 4)
        // Ta sama krzywa liczona wprost z patcha.
        let fromPatch = G2Mutator.chromosome(of: patch, variation: 0, genome: genome)
        XCTAssertEqual(points.count, fromPatch.count)
        XCTAssertEqual(points.last?.x ?? 0, fromPatch.last?.x ?? 1, accuracy: 0.0001)

        var other = parent
        let gene = try XCTUnwrap(genome.genes.first { $0.isMutable })
        other[gene.key] = ((parent[gene.key] ?? 0) == 0) ? 100 : 0
        XCTAssertNotEqual(points, G2Mutator.chromosome(of: other, genome: genome))
    }

    // MARK: - Stan edytora

    func testMutateFillsChildrenAndFocusesTheFirst() throws {
        let state = try makeState(fixturePatch())
        var dumps = 0
        state.onMutatorAudition = { _, _, _ in dumps += 1 }
        state.mutatorLocks = G2MutatorLocks(enabled: 0xFF, solo: 0)
        state.mutatorSettings.setProbability(1)
        state.mutatorSettings.link = false
        state.mutatorSettings.setRange(0.4)

        let before = state.patch.voiceModules.map(\.parameters)
        undoStep(on: state) { state.mutatorMutate() }

        XCTAssertEqual(state.mutatorParents.compactMap { $0 }.count, 7, "sześcioro dzieci i Mother")
        XCTAssertEqual(state.mutatorFocus, .child(0), "focus ląduje na pierwszym dziecku")
        XCTAssertEqual(state.mutatorParentCount, 1)
        XCTAssertNotEqual(state.patch.voiceModules.map(\.parameters), before, "dziecko od razu słychać")
        XCTAssertEqual(dumps, 1, "dziecko słychać — jeden zrzut bufora")

        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules.map(\.parameters), before,
                       "jedno ⌘Z wraca do patcha sprzed mutacji")
    }

    /// `Cross` i `Interpolate` potrzebują dwojga rodziców i malują dzieci „na dwoje".
    func testCrossNeedsBothParents() throws {
        let state = try makeState(fixturePatch())
        XCTAssertFalse(state.mutatorHasBothParents)
        undoStep(on: state) { state.mutatorCross() }
        XCTAssertNil(state.mutatorFocus, "bez rodziców nic się nie dzieje")

        undoStep(on: state) {
            state.mutatorCopyToParent(G2MutatorBox(.variations, 0), mother: true)
            state.mutatorCopyToParent(G2MutatorBox(.variations, 1), mother: false)
        }
        XCTAssertTrue(state.mutatorHasBothParents)

        undoStep(on: state) { state.mutatorCross() }
        XCTAssertEqual(state.mutatorParentCount, 2)
        XCTAssertEqual(state.mutatorParents.compactMap { $0 }.count, 8)
    }

    /// Przeciągnięcie w magazynie PRZENOSI, z kratki dziecka KOPIUJE — `EndDrag`.
    func testDragMovesInsideStorageAndCopiesFromElsewhere() throws {
        let state = try makeState(fixturePatch())
        undoStep(on: state) { state.mutatorMutate() }
        undoStep(on: state) { state.mutatorDrag(from: .child(0), to: G2MutatorBox(.storage, 0)) }
        XCTAssertNotNil(state.mutatorStorage[0])
        XCTAssertNotNil(state.mutatorParents[0], "kopia, nie przeniesienie")

        undoStep(on: state) { state.mutatorDrag(from: G2MutatorBox(.storage, 0), to: G2MutatorBox(.storage, 9)) }
        XCTAssertNil(state.mutatorStorage[0], "w magazynie dźwięk się przenosi")
        XCTAssertNotNil(state.mutatorStorage[9])
    }

    /// Przycisk „v" rzędu magazynu rozkłada osiem dźwięków po ośmiu wariacjach.
    func testStorageRowGoesToTheEightVariations() throws {
        let state = try makeState(fixturePatch())
        state.mutatorLocks = G2MutatorLocks(enabled: 0xFF, solo: 0)
        state.mutatorSettings.link = false
        state.mutatorSettings.setProbability(1)
        state.mutatorSettings.setRange(0.4)
        undoStep(on: state) { state.mutatorMutate() }
        for index in 0 ..< 6 {
            undoStep(on: state) { state.mutatorDrag(from: .child(index), to: G2MutatorBox(.storage, index)) }
        }
        // Pierwszy moduł patcha bywa wyjściem, a te są wyłączone z mutacji z góry —
        // patrzymy więc na moduł, który mutator faktycznie rusza.
        let watched = try XCTUnwrap(state.patch.voiceModules.first { !$0.excludedFromMutation }?.id)
        func variations() throws -> [[Int]] {
            try XCTUnwrap(state.patch.voiceModules.first { $0.id == watched }?.parameterVariations)
        }
        let before = try variations()

        undoStep(on: state) { state.mutatorCopyStorageRowToVariations(0) }

        let after = try variations()
        XCTAssertEqual(after.count, G2Patch.runtimeVariationCount)
        XCTAssertNotEqual(after[1], before[1])
        XCTAssertNotEqual(after[5], before[5])
        XCTAssertEqual(after[6], before[6], "rząd miał sześć dźwięków, więc dwie wariacje zostają")
        XCTAssertEqual(after[8], before[8], "wariacja init zostaje nietknięta")

        state.undoManager.undo()
        XCTAssertEqual(try variations(), before)
    }

    /// #135: po „v" i kliknięciu kratki wariacji (gra dziecko → wariacja) cofnięcie zapisu
    /// wymagało dwóch ⌘Z — pierwsze cofało wybór wariacji do bufora 9, czego
    /// `selectVariation` nie przyjmuje, więc nic się nie działo. Cofnięcie zapisu nie
    /// może też przełączać grającej wariacji.
    func testOneUndoRevertsStorageRowAfterClickingAVariation() throws {
        let state = try makeState(fixturePatch())
        state.mutatorLocks = G2MutatorLocks(enabled: 0xFF, solo: 0)
        state.mutatorSettings.link = false
        state.mutatorSettings.setProbability(1)
        state.mutatorSettings.setRange(0.4)
        undoStep(on: state) { state.mutatorMutate() }
        undoStep(on: state) { state.mutatorDrag(from: .child(0), to: G2MutatorBox(.storage, 0)) }
        XCTAssertTrue(state.isAuditioningMutation, "gra dziecko z bufora")
        let watched = try XCTUnwrap(state.patch.voiceModules.first { !$0.excludedFromMutation }?.id)
        func variation0() throws -> [Int] {
            try XCTUnwrap(state.patch.voiceModules.first { $0.id == watched }?.parameterVariations[0])
        }
        let before = try variation0()

        undoStep(on: state) { state.mutatorCopyStorageRowToVariations(0) }
        XCTAssertNotEqual(try variation0(), before)
        // Bez własnej grupy: krok, który nic nie rejestruje, nie może trafić na stos
        // (`registerUndo` poza grupą przy `groupsByEvent = false` rzuciłby wyjątek).
        state.mutatorSetFocus(G2MutatorBox(.variations, 0))
        XCTAssertEqual(state.patch.activeVariation, 0)
        XCTAssertEqual(state.undoManager.undoActionName, "Copy Row To Variations",
                       "klik w wariację z bufora nie zostawia pustego kroku cofania")

        state.undoManager.undo()
        XCTAssertEqual(try variation0(), before, "jedno ⌘Z cofa zapis rzędu")
        XCTAssertEqual(state.patch.activeVariation, 0, "cofnięcie zapisu nie przełącza wariacji")
    }

    /// #129: dziecko upuszczone na wariację brzmiało w Nordzie po staremu, bo zapis szedł
    /// drogą zmian STRUKTURY — a ta wartości nie niesie. Teraz urządzenie dostaje zrzut tej
    /// jednej wariacji z nowymi wartościami, a ⌘Z — zrzut z dawnymi (jak oryginał).
    func testChildDroppedOnVariationSendsItsValuesAndUndoSendsTheOldOnes() throws {
        let state = try makeState(fixturePatch())
        state.mutatorLocks = G2MutatorLocks(enabled: 0xFF, solo: 0)
        state.mutatorSettings.link = false
        state.mutatorSettings.setProbability(1)
        state.mutatorSettings.setRange(0.4)
        undoStep(on: state) { state.mutatorMutate() }
        var structureReports = 0
        var dumps: [(slot: Int, patch: G2Patch, variations: [Int])] = []
        state.onLiveStructureChange = { _, _ in structureReports += 1 }
        state.onVariationDump = { dumps.append(($0, $1, $2)) }
        let before = state.patch

        undoStep(on: state) { state.mutatorDrag(from: .child(0), to: G2MutatorBox(.variations, 3)) }

        XCTAssertEqual(structureReports, 0, "zapis do wariacji nie rusza struktury")
        XCTAssertEqual(dumps.map(\.variations), [[3]])
        let sent = try PatchParser.writeMutatorParamDump(XCTUnwrap(dumps.last).patch, variation: 3)
        XCTAssertEqual(sent, try PatchParser.writeMutatorParamDump(state.patch, variation: 3))
        XCTAssertNotEqual(sent, try PatchParser.writeMutatorParamDump(before, variation: 3),
                          "zrzut ma nieść dźwięk dziecka, nie dawną wariację")

        state.undoManager.undo()
        XCTAssertEqual(dumps.map(\.variations), [[3], [3]])
        XCTAssertEqual(try PatchParser.writeMutatorParamDump(XCTUnwrap(dumps.last).patch, variation: 3),
                       try PatchParser.writeMutatorParamDump(before, variation: 3))

        state.undoManager.redo()
        XCTAssertEqual(try PatchParser.writeMutatorParamDump(XCTUnwrap(dumps.last).patch, variation: 3), sent)
        XCTAssertEqual(structureReports, 0)
    }

    func testClearRowEmptiesTheStorageRow() throws {
        let state = try makeState(fixturePatch())
        undoStep(on: state) { state.mutatorMutate() }
        undoStep(on: state) { state.mutatorDrag(from: .child(0), to: G2MutatorBox(.storage, 3)) }
        XCTAssertNotNil(state.mutatorStorage[3])
        undoStep(on: state) { state.mutatorClearStorageRow(0) }
        XCTAssertTrue(state.mutatorStorage[0 ..< 8].allSatisfy { $0 == nil })
    }

    // MARK: - Bufor mutatora (dziesiąty zestaw parametrów)

    /// Sedno tej wersji: przesłuchiwanie dziecka NIE rusza ośmiu zapisanych wariacji.
    /// Dźwięk ląduje w dziesiątym zestawie (`G2Patch.mutatorVariation`), a patch
    /// przełącza się na niego — dokładnie jak `GetFocusIndividMolecules` oryginału,
    /// która zrzuca wartości do zestawu 9 i wysyła Param Setting Focus(9).
    func testAuditioningLeavesTheEightVariationsAlone() throws {
        let state = try makeState(fixturePatch())
        state.mutatorLocks = G2MutatorLocks(enabled: 0xFF, solo: 0)
        state.mutatorSettings.link = false
        state.mutatorSettings.setProbability(1)
        state.mutatorSettings.setRange(0.4)

        let before = state.patch.voiceModules.map(\.parameterVariations)
        undoStep(on: state) { state.mutatorMutate() }

        XCTAssertEqual(state.patch.activeVariation, G2Patch.mutatorVariation)
        XCTAssertTrue(state.isAuditioningMutation)
        let after = state.patch.voiceModules.map(\.parameterVariations)
        for (moduleIndex, variations) in after.enumerated() {
            for variation in 0 ... G2Patch.initVariation where variations.indices.contains(variation) {
                XCTAssertEqual(variations[variation], before[moduleIndex][variation],
                               "wariacja \(variation) miała zostać nietknięta")
            }
        }
        let buffer = G2Patch.mutatorVariation
        XCTAssertNotEqual(after.compactMap { $0.indices.contains(buffer) ? $0[buffer] : nil },
                          before.compactMap { $0.indices.contains(buffer) ? $0[buffer] : nil },
                          "dziecko siedzi w buforze")
    }

    /// Numer wariacji, na której gra bufor, nie ma prawa trafić do pliku — inaczej
    /// patch otwierałby się na zestawie, którego w pliku nie ma. Instrukcja opisuje
    /// dokładnie ten przypadek: patch wraca na pierwszą wariację.
    func testSavedFileNeverPointsAtTheBuffer() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("test_3osc.pch2")
            .standardized
        let original = try Data(contentsOf: url)
        var patch = try XCTUnwrap(PatchParser.parse(data: original).first)
        patch.setActiveVariation(G2Patch.mutatorVariation)
        XCTAssertEqual(patch.activeVariation, G2Patch.mutatorVariation)

        let saved = try PatchParser.saveAll(originalData: original, patches: [patch])
        let reloaded = try XCTUnwrap(PatchParser.parse(data: saved).first)
        XCTAssertEqual(reloaded.activeVariation, 0)
    }

    /// Zgłoszenie użytkownika 2026-09-22: wariacja przeciągnięta do Mother brzmi
    /// na emulatorze inaczej niż ta sama wariacja grana wprost. Po stronie EDYTORA
    /// bufor odsłuchu musi być jej dokładną kopią — wartości modułów, obszar 2
    /// i morfy. Gdy ten test przechodzi, różnicy trzeba szukać w tym, co dociera
    /// (albo nie dociera) do urządzenia → [[Docs/usb/mutator-dump]].
    func testVariationCopiedToMotherFillsTheBufferExactly() throws {
        var patch = try fixturePatch()
        let module = try XCTUnwrap(patch.voiceModules.first { $0.parameters.count > 1 })
        patch.setParameter(moduleID: module.id, paramIndex: 1, value: 77, in: .voice, variation: 2)
        patch.variationSettings[2].glideTime = 42
        patch.setMorphRange(variation: 2, location: 1, moduleID: module.id,
                            paramIndex: 0, morph: 3, range: 25)
        let state = makeState(patch)

        undoStep(on: state) { state.mutatorDrag(from: G2MutatorBox(.variations, 2), to: .mother) }
        undoStep(on: state) { state.mutatorSetFocus(.mother) }
        XCTAssertTrue(state.isAuditioningMutation)

        let buffer = G2Patch.mutatorVariation
        for module in state.patch.voiceModules + state.patch.fxModules
            where module.parameterVariations.indices.contains(buffer)
        {
            XCTAssertEqual(module.parameterVariations[buffer], module.parameterVariations[2],
                           "moduł \(module.id)")
        }
        XCTAssertEqual(state.patch.variationSettings[buffer], state.patch.variationSettings[2])
        XCTAssertEqual(state.patch.morphs(in: buffer), state.patch.morphs(in: 2))
    }

    /// Klik w kratkę wariacji kończy przesłuchiwanie — patch wraca na tę wariację.
    func testPickingAVariationLeavesTheBuffer() throws {
        let state = try makeState(fixturePatch())
        undoStep(on: state) { state.mutatorMutate() }
        XCTAssertTrue(state.isAuditioningMutation)

        undoStep(on: state) { state.mutatorSetFocus(G2MutatorBox(.variations, 2)) }
        XCTAssertFalse(state.isAuditioningMutation)
        XCTAssertEqual(state.patch.activeVariation, 2)
        XCTAssertEqual(state.mutatorFocus, G2MutatorBox(.variations, 2))
    }

    /// Zgłoszenie użytkownika 2026-09-23: świeżo otwarte okno mutatora nie zapalało
    /// żadnej kratki, choć patch grał na którejś wariacji — dopiero przełączenie na
    /// inną coś zapalało. Bez kliknięcia podświetlenie ma iść za górnym paskiem.
    func testVariationIsLitBeforeAnythingIsClicked() throws {
        var patch = try fixturePatch()
        patch.setActiveVariation(3)
        let state = makeState(patch)
        XCTAssertNil(state.mutatorFocus)
        XCTAssertEqual(state.mutatorHighlight, G2MutatorBox(.variations, 3))

        // Przesłuchiwanie mutacji gasi wszystkie kratki wariacji, tak jak przyciski w belce.
        undoStep(on: state) { state.mutatorMutate() }
        XCTAssertTrue(state.isAuditioningMutation)
        XCTAssertEqual(state.mutatorHighlight, state.mutatorFocus)
    }

    /// Zgłoszenie użytkownika 2026-10-21 (#145): performance z kilkoma slotami, w A
    /// wariacja 2, przejście do B, który gra wariację 1 — belka pokazywała 1, a mutator
    /// dalej zapalał kratkę ze slotu A. Podświetlenie ma iść za oglądanym slotem.
    func testHighlightFollowsTheSelectedSlot() throws {
        let patch = try fixturePatch()
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.slots = [patch, patch]

        undoStep(on: state) { state.selectVariation(1) }
        XCTAssertEqual(state.mutatorHighlight, G2MutatorBox(.variations, 1))

        state.selectedSlot = 1
        XCTAssertEqual(state.patch.activeVariation, 0)
        XCTAssertEqual(state.mutatorHighlight, G2MutatorBox(.variations, 0))

        // Slot A przesłuchuje dziecko — po powrocie do A kratka dziecka znów świeci.
        state.selectedSlot = 0
        undoStep(on: state) { state.mutatorMutate() }
        let child = try XCTUnwrap(state.mutatorFocus)
        state.selectedSlot = 1
        XCTAssertEqual(state.mutatorHighlight, G2MutatorBox(.variations, 0))
        state.selectedSlot = 0
        XCTAssertEqual(state.mutatorHighlight, child)
    }

    /// Każde przesłuchanie to **jeden zrzut całego bufora** do zestawu 9 — i tyle.
    /// Żadnych pojedynczych `0x40`, `0x43` ani ustawień obszaru 2 osobno, i żadnych
    /// „tylko różnic": zrzut niesie komplet, więc zgubiona paczka naprawia się sama
    /// przy następnym kliknięciu → [[Docs/usb/mutator-dump]].
    func testAuditionSendsTheWholeBufferEveryTime() throws {
        let state = try makeState(fixturePatch())
        var dumps: [(variation: Int, first: [Int])] = []
        var singles = 0
        state.onLiveParameterChange = { _, _, _, _, _, _ in singles += 1 }
        state.onMorphRangeChange = { _, _, _, _, _, _, _ in singles += 1 }
        state.onPatchSettingChange = { _, _, _, _, _ in singles += 1 }
        state.onMutatorAudition = { _, patch, variation in
            let values = patch.voiceModules
                .filter { $0.parameterVariations.indices.contains(variation) }
                .flatMap { $0.parameterVariations[variation] }
            dumps.append((variation, values))
        }

        undoStep(on: state) { state.mutatorMutate() }
        XCTAssertEqual(dumps.count, 1)

        undoStep(on: state) { state.mutatorSetFocus(.child(1)) }
        XCTAssertEqual(dumps.count, 2, "drugie przesłuchanie to znowu pełny zrzut")
        XCTAssertTrue(dumps.allSatisfy { $0.variation == G2Patch.mutatorVariation })
        XCTAssertNotEqual(dumps[0].first, dumps[1].first, "każdy zrzut niesie swój dźwięk")
        XCTAssertEqual(singles, 0, "nic nie idzie parametr po parametrze")
    }

    /// Wyłączenie modułu z mutacji zamraża jego parametry.
    func testExcludedModuleIsLeftAlone() throws {
        let state = try makeState(fixturePatch())
        let moduleID = try XCTUnwrap(state.patch.voiceModules.first { !$0.excludedFromMutation }?.id)
        undoStep(on: state) { state.setModulesExcludedFromMutation([moduleID], excluded: true) }
        XCTAssertTrue(state.isModuleExcludedFromMutation(moduleID))
        for gene in state.mutatorGenome.genes where gene.moduleID == moduleID && gene.area == .voice {
            XCTAssertFalse(G2Mutator.isEnabled(gene, locks: G2MutatorLocks(enabled: 0xFF)))
        }
    }

    /// Power (`Active`) modułu wyłączonego z mutacji, zgaszony już PO zrobieniu Mother,
    /// wracał przy następnym Mutate: kratki pamiętają dźwięk z chwili powstania, więc
    /// dzieci niosły Power z Mother. Moduł wyłączony ma zostać taki, jaki gra.
    func testExcludedModulePowerSwitchedOffAfterMotherStaysOff() throws {
        let state = try makeState(fixturePatch())
        state.mutatorLocks = G2MutatorLocks(enabled: 0xFF, solo: 0)
        let (moduleID, active) = try XCTUnwrap(state.patch.voiceModules.lazy.compactMap { module -> (Int, Int)? in
            guard !module.excludedFromMutation,
                  let index = ModuleDatabase.module(id: module.typeID)?.paramNames.firstIndex(of: "Active")
            else { return nil }
            return (module.id, index)
        }.first)
        func power(_ variation: Int? = nil) throws -> Int {
            let module = try XCTUnwrap(state.patch.voiceModules.first { $0.id == moduleID })
            return module.parameterVariations[variation ?? state.patch.activeVariation][active]
        }
        undoStep(on: state) { state.setModulesExcludedFromMutation([moduleID], excluded: true) }
        undoStep(on: state) { state.mutatorMutate() }
        XCTAssertEqual(try power(), 1, "Mother powstała z włączonym Power")

        undoStep(on: state) { state.setParameter(moduleID: moduleID, paramIndex: active, value: 0, area: .voice) }
        undoStep(on: state) { state.mutatorMutate() }
        XCTAssertEqual(try power(), 0, "Mutate nie włącza Power modułu wyłączonego z mutacji")

        undoStep(on: state) { state.mutatorSetFocus(.mother) }
        XCTAssertEqual(try power(), 0, "kliknięcie Mother też nie")

        undoStep(on: state) { state.mutatorDrag(from: .child(0), to: G2MutatorBox(.storage, 0)) }
        undoStep(on: state) { state.mutatorDrag(from: G2MutatorBox(.storage, 0), to: G2MutatorBox(.variations, 3)) }
        XCTAssertEqual(try power(3), 0, "wariacja dostaje to, co było słychać")

        undoStep(on: state) { state.mutatorCopyStorageRowToVariations(0) }
        XCTAssertEqual(try power(0), 0, "rząd magazynu do wariacji tak samo")
    }

    /// Kopia wariacji na wariację bierze moduł wyłączony z mutacji z wariacji źródłowej
    /// — tam nic nie jest stare, więc nie ma czego podmieniać na to, co gra.
    func testVariationToVariationCopiesExcludedModuleAsIs() throws {
        let state = try makeState(fixturePatch())
        let (moduleID, active) = try XCTUnwrap(state.patch.voiceModules.lazy.compactMap { module -> (Int, Int)? in
            guard !module.excludedFromMutation,
                  let index = ModuleDatabase.module(id: module.typeID)?.paramNames.firstIndex(of: "Active")
            else { return nil }
            return (module.id, index)
        }.first)
        undoStep(on: state) { state.setModulesExcludedFromMutation([moduleID], excluded: true) }
        undoStep(on: state) { state.selectVariation(2) }
        undoStep(on: state) { state.setParameter(moduleID: moduleID, paramIndex: active, value: 0, area: .voice) }
        undoStep(on: state) { state.selectVariation(0) }

        undoStep(on: state) { state.mutatorDrag(from: G2MutatorBox(.variations, 2), to: G2MutatorBox(.variations, 5)) }

        let module = try XCTUnwrap(state.patch.voiceModules.first { $0.id == moduleID })
        XCTAssertEqual(module.parameterVariations[5][active], 0)
        XCTAssertEqual(module.parameterVariations[0][active], 1)
    }
}
