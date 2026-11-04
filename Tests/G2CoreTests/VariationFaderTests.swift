// VariationFaderTests.swift
// Fader wariacji (#13): przystanki, mieszanie dwóch sąsiadów, bufor odsłuchu,
// wysyłka do Norda i powrót do zwykłej wariacji na przystanku → [[Docs/ui/variations]].

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class VariationFaderTests: XCTestCase {
    /// OscA: ma i gałki (płynne), i przyciski (fala — skacze w połowie).
    private let oscA = 97

    /// Indeks pierwszego parametru gałkowego i pierwszego przyciskowego OscA.
    private func paramIndices() -> (knob: Int, button: Int) {
        let count = ModuleDatabase.module(id: oscA)?.paramNames.count ?? 0
        let indices = Array(0 ..< count)
        let button = indices.first { G2ParameterText.buttonOptions(moduleTypeID: oscA, paramIndex: $0) != nil }
        let knob = indices.first {
            G2ParameterText.buttonOptions(moduleTypeID: oscA, paramIndex: $0) == nil
                && (ParameterRangeDatabase.range(moduleTypeID: oscA, codeRef: $0)?.upperBound ?? 0) >= 100
        }
        return (knob ?? 0, button ?? 0)
    }

    /// Wariacja `v` ma gałkę na `v * 10`, przycisk na `v % 2`; `same` — lista wariacji,
    /// które mają być kopią poprzedniej.
    private func makePatch(same: Set<Int> = []) -> G2Patch {
        let (knob, button) = paramIndices()
        let count = ModuleDatabase.module(id: oscA)?.paramNames.count ?? 0
        var module = G2Module(id: 1, typeID: oscA, area: .voice)
        module.parameterVariations = (0 ..< G2Patch.runtimeVariationCount).map { variation in
            var values = Array(repeating: 0, count: count)
            values[knob] = variation * 10
            values[button] = variation % 2
            return values
        }
        for variation in same.sorted() {
            module.parameterVariations[variation] = module.parameterVariations[variation - 1]
        }
        module.parameters = module.parameterVariations[0]
        var patch = G2Patch()
        patch.voiceModules = [module]
        patch.ensureRuntimeVariations()
        return patch
    }

    private func makeState(_ patch: G2Patch) -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.slots = [patch]
        return state
    }

    private func value(_ state: PatchState, _ index: Int, variation: Int = G2Patch.mutatorVariation) -> Int {
        state.slots[0].voiceModules[0].parameterVariations[variation][index]
    }

    // MARK: - Przystanki

    func testIdenticalVariationIsSkippedAndBelongsToThePreviousStop() {
        let patch = makePatch(same: [3, 4])
        let stops = G2VariationFade.stops(of: patch)

        XCTAssertEqual(stops, [0, 1, 2, 5, 6, 7])
        XCTAssertEqual(G2VariationFade.stopIndex(of: 4, in: stops), 2)
        XCTAssertEqual(G2VariationFade.stopIndex(of: 5, in: stops), 3)
        // Para z porównania nie jest posortowana — liczy się sama obecność.
        XCTAssertEqual(G2VariationFade.stopIndex(of: 0, in: [4, 0]), 1)
        XCTAssertNil(G2VariationFade.stopIndex(of: 2, in: [4, 0]))
    }

    func testButtonsLightHalfAndHalfBetweenStops() {
        let stops = [0, 1, 2, 5]
        XCTAssertEqual(G2VariationFade.weight(of: 1, at: 1.5, stops: stops), 0.5)
        XCTAssertEqual(G2VariationFade.weight(of: 2, at: 1.5, stops: stops), 0.5)
        XCTAssertEqual(G2VariationFade.weight(of: 3, at: 2, stops: stops), 1) // kopia 3. wariacji
        XCTAssertEqual(G2VariationFade.weight(of: 0, at: 1.5, stops: stops), 0)
        // Para z porównania 1 ↔ 2: trójka nie jest kopią dwójki, nie świeci.
        XCTAssertEqual(G2VariationFade.weight(of: 2, at: 1, stops: [0, 1], pair: true), 0)
        XCTAssertEqual(G2VariationFade.weight(of: 1, at: 1, stops: [0, 1], pair: true), 1)
    }

    // MARK: - Mieszanie

    func testKnobsGlideAndButtonsJumpHalfway() {
        let patch = makePatch()
        let genome = G2MutatorGenome(patch: patch)
        let (knob, button) = paramIndices()
        let key = { G2Individual.Key(area: .voice, moduleID: 1, paramIndex: $0) }

        let quarter = G2VariationFade.sound(at: 2.25, stops: [0, 1, 2, 3], patch: patch, genome: genome)
        XCTAssertEqual(quarter[key(knob)], 22.5) // 20 → 30
        XCTAssertEqual(quarter[key(button)], 0) // fala wariacji 3 aż do połowy

        let past = G2VariationFade.sound(at: 2.75, stops: [0, 1, 2, 3], patch: patch, genome: genome)
        XCTAssertEqual(past[key(button)], 1) // za połową już fala wariacji 4
    }

    /// Decyzja Kuby 2026-11-04: przełączniki trzymają przystanek, z którego suwak ruszył,
    /// i skaczą dopiero na następnym — środek drogi jest w pełni płynny.
    func testSwitchesHoldTheDepartureStopUntilTheNextOne() {
        let patch = makePatch()
        let genome = G2MutatorGenome(patch: patch)
        let (knob, button) = paramIndices()
        let key = { G2Individual.Key(area: .voice, moduleID: 1, paramIndex: $0) }
        let stops = Array(0 ..< 8)

        let fromLeft = G2VariationFade.sound(at: 2.9, stops: stops, switchStop: 2, patch: patch, genome: genome)
        XCTAssertEqual(fromLeft[key(button)], 0) // fala „3” aż do samej „4”
        XCTAssertEqual(fromLeft[key(knob)] ?? 0, 29, accuracy: 0.001)
        let fromRight = G2VariationFade.sound(at: 2.1, stops: stops, switchStop: 3, patch: patch, genome: genome)
        XCTAssertEqual(fromRight[key(button)], 1) // wracając z „4” — fala „4”

        XCTAssertEqual(G2VariationFade.switchStop(held: 2, from: 2.2, to: 2.8), 2)
        XCTAssertEqual(G2VariationFade.switchStop(held: 2, from: 2.8, to: 3.4), 3) // minięta „4”
        XCTAssertEqual(G2VariationFade.switchStop(held: 3, from: 3.4, to: 3.0), 3)
        XCTAssertEqual(G2VariationFade.switchStop(held: 3, from: 3.0, to: 2.6), 3) // z powrotem bez skoku
        XCTAssertEqual(G2VariationFade.switchStop(held: 3, from: 3.2, to: 1.5), 2) // szybki ruch przez dwa
    }

    // MARK: - PatchState

    func testFaderPlaysTheBufferAndLeavesVariationsUntouched() {
        let state = makeState(makePatch())
        let (knob, _) = paramIndices()
        let before = state.slots[0].voiceModules[0].parameterVariations[0 ..< 8]
        var dumps: [Int] = []
        state.onMutatorAudition = { _, _, variation in dumps.append(variation) }

        state.undoManager.beginUndoGrouping()
        state.moveVariationFader(to: 1.5, slot: 0)
        state.endVariationFaderGesture(slot: 0)
        state.undoManager.endUndoGrouping()

        XCTAssertEqual(state.slots[0].activeVariation, G2Patch.mutatorVariation)
        XCTAssertEqual(value(state, knob), 15)
        XCTAssertEqual(state.slots[0].voiceModules[0].parameters[knob], 15) // gałki pokazują bufor
        XCTAssertEqual(state.slots[0].voiceModules[0].parameterVariations[0 ..< 8], before)
        XCTAssertEqual(dumps, [G2Patch.mutatorVariation, G2Patch.mutatorVariation]) // start i koniec gestu
        XCTAssertEqual(state.variationFaderPosition(slot: 0), 1.5)
        XCTAssertEqual(state.variationFaderWeight(of: 1, slot: 0), 0.5)
        XCTAssertNil(state.mutatorHighlight)
    }

    func testDuringTheGestureOnlyDifferencesGoAsOneBatch() async throws {
        let state = makeState(makePatch())
        let (knob, _) = paramIndices()
        var batches: [[G2ParameterChange]] = []
        state.onMutatorAudition = { _, _, _ in }
        state.onLiveParameterBatch = { _, changes, variation in
            XCTAssertEqual(variation, G2Patch.mutatorVariation)
            batches.append(changes)
        }

        state.undoManager.beginUndoGrouping()
        state.moveVariationFader(to: 0.2, slot: 0)
        try await Task.sleep(for: .milliseconds(60))
        state.moveVariationFader(to: 0.4, slot: 0)
        try await Task.sleep(for: .milliseconds(60))
        state.undoManager.endUndoGrouping()

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.map(\.paramIndex), [knob])
        XCTAssertEqual(batches.first?.first?.value, 4)
    }

    func testReleasingOnAStopSelectsThatVariationAndUndoReturns() {
        let state = makeState(makePatch())
        var selected: [Int] = []
        state.onMutatorAudition = { _, _, _ in }
        state.onVariationChange = { _, variation in selected.append(variation) }

        state.undoManager.beginUndoGrouping()
        state.moveVariationFader(to: 2.96, slot: 0) // przystanek przyciąga
        state.endVariationFaderGesture(slot: 0)
        state.undoManager.endUndoGrouping()

        XCTAssertEqual(state.slots[0].activeVariation, 3)
        XCTAssertNil(state.activeVariationFader(slot: 0))
        XCTAssertEqual(state.variationFaderPosition(slot: 0), 3)
        XCTAssertEqual(selected, [3])

        state.undoManager.undo()
        XCTAssertEqual(state.slots[0].activeVariation, 0)
    }

    func testCompareModeFadesBetweenThePlayingAndTheComparedVariation() {
        let state = makeState(makePatch())
        let (knob, _) = paramIndices()
        state.onMutatorAudition = { _, _, _ in }
        state.toggleCompare(with: 6, slot: 0)

        XCTAssertEqual(state.variationFaderStops(slot: 0), [0, 6])

        state.undoManager.beginUndoGrouping()
        state.moveVariationFader(to: 0.5, slot: 0)
        state.endVariationFaderGesture(slot: 0)
        state.undoManager.endUndoGrouping()

        XCTAssertEqual(value(state, knob), 30) // pół drogi 0 → 60
        XCTAssertEqual(state.comparedVariation(slot: 0), 6) // porównanie trwa
        XCTAssertEqual(state.variationFaderStops(slot: 0), [0, 6])
    }

    /// Kanwa porównuje grające brzmienie z przystankiem, do którego suwak jedzie —
    /// także bez Shift-kliku; na końcu drogi z tym za plecami.
    func testCanvasComparesWithTheStopTheFaderHeadsFor() async throws {
        let state = makeState(makePatch())
        state.onMutatorAudition = { _, _, _ in }
        XCTAssertNil(state.canvasComparedVariation(slot: 0))

        state.undoManager.beginUndoGrouping()
        // Bufor gra dopiero po pierwszej wysyłce (≤ 20 ms) — wtedy fader jest „grający”.
        state.moveVariationFader(to: 2.5, slot: 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.canvasComparedVariation(slot: 0), 3) // w prawo → „4”
        state.moveVariationFader(to: 2.3, slot: 0)
        XCTAssertEqual(state.canvasComparedVariation(slot: 0), 2) // w lewo → „3”
        state.moveVariationFader(to: 7, slot: 0)
        XCTAssertEqual(state.canvasComparedVariation(slot: 0), 6) // koniec drogi → „7”
        state.endVariationFaderGesture(slot: 0)
        state.undoManager.endUndoGrouping()
        XCTAssertNil(state.canvasComparedVariation(slot: 0)) // na przystanku gra wariacja 8
    }

    /// Decyzja Kuby 2026-11-04: po puszczeniu suwaka zmiany zostają na kanwie, aż kliknięcie
    /// w kanwę albo Esc je zgasi; brzmienie „pomiędzy” gra dalej. Kolejny ruch zapala je znowu.
    func testCanvasKeepsFaderChangesUntilClickOrEsc() async throws {
        let state = makeState(makePatch())
        state.onMutatorAudition = { _, _, _ in }

        state.undoManager.beginUndoGrouping()
        state.moveVariationFader(to: 2.5, slot: 0)
        try await Task.sleep(for: .milliseconds(50))
        state.endVariationFaderGesture(slot: 0)
        state.undoManager.endUndoGrouping()
        XCTAssertEqual(state.canvasComparedVariation(slot: 0), 3) // po puszczeniu — dalej widać

        XCTAssertTrue(state.hideVariationFaderChanges(slot: 0)) // klik w kanwę
        XCTAssertNil(state.canvasComparedVariation(slot: 0))
        XCTAssertNotNil(state.activeVariationFader(slot: 0)) // dalej gra brzmienie „pomiędzy”
        XCTAssertFalse(state.endCanvasComparison(slot: 0)) // Esc idzie dalej — nie było czego gasić

        state.undoManager.beginUndoGrouping()
        state.moveVariationFader(to: 2.4, slot: 0)
        XCTAssertEqual(state.canvasComparedVariation(slot: 0), 2) // ruch w lewo → „3”
        state.endVariationFaderGesture(slot: 0)
        state.undoManager.endUndoGrouping()
    }

    /// Kompromis Kuby 2026-11-04: klik w kanwę nie kończy porównania Shift-klikiem — da się
    /// kręcić gałkami i widzieć różnice; kończy je Esc.
    func testCanvasClickKeepsTheVariationCompareAndEscEndsIt() {
        let state = makeState(makePatch())
        state.toggleCompare(with: 6, slot: 0)
        XCTAssertEqual(state.canvasComparedVariation(slot: 0), 6)

        XCTAssertFalse(state.hideVariationFaderChanges(slot: 0)) // klik w kanwę
        XCTAssertEqual(state.canvasComparedVariation(slot: 0), 6)

        XCTAssertTrue(state.endCanvasComparison(slot: 0)) // Esc
        XCTAssertNil(state.comparedVariation(slot: 0))
        XCTAssertNil(state.canvasComparedVariation(slot: 0))
    }

    func testStoreFaderSoundWritesTheBufferIntoAVariation() {
        let state = makeState(makePatch())
        let (knob, _) = paramIndices()
        var dumped: [[Int]] = []
        state.onMutatorAudition = { _, _, _ in }
        state.onVariationDump = { _, _, variations in dumped.append(variations) }

        state.undoManager.beginUndoGrouping()
        state.moveVariationFader(to: 4.5, slot: 0)
        state.endVariationFaderGesture(slot: 0)
        state.storeVariationFaderSound(to: 7, slot: 0)
        state.undoManager.endUndoGrouping()

        XCTAssertEqual(value(state, knob, variation: 7), 45)
        XCTAssertEqual(dumped, [[7]])
        XCTAssertEqual(state.slots[0].activeVariation, G2Patch.mutatorVariation) // dalej gra to samo
    }

    /// Prośba Kuby 2026-11-04: kratka wariacji w Mutatorze świeci, gdy suwak stoi na jej
    /// kropce — już z wciśniętą myszą, nie dopiero po puszczeniu; kopia razem z nią.
    func testMutatorVariationBoxLightsOnItsStopWhileDragging() async throws {
        let state = makeState(makePatch(same: [3])) // przystanki 1 2 3 5 6 7 8, „4” = kopia „3”
        state.onMutatorAudition = { _, _, _ in }
        let lit = { (0 ..< 8).filter { state.mutatorLit(G2MutatorBox(.variations, $0)) } }

        state.undoManager.beginUndoGrouping()
        state.moveVariationFader(to: 1.5, slot: 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.slots[0].activeVariation, G2Patch.mutatorVariation)
        XCTAssertEqual(lit(), []) // pomiędzy — nic
        state.moveVariationFader(to: 1.97, slot: 0) // kropka przyciąga, mysz dalej wciśnięta
        XCTAssertEqual(lit(), [2, 3])
        state.endVariationFaderGesture(slot: 0)
        state.undoManager.endUndoGrouping()
        XCTAssertEqual(lit(), [2]) // po puszczeniu gra zwykła wariacja
    }

    /// Menu kratki Mutatora ▸ „Store Fader Sound Here”: magazyn i wariacja, każde cofalne.
    func testStoreFaderSoundIntoAMutatorBoxAndUndo() {
        let state = makeState(makePatch())
        let (knob, _) = paramIndices()
        let key = G2Individual.Key(area: .voice, moduleID: 1, paramIndex: knob)
        let storage = G2MutatorBox(.storage, 5)
        state.onMutatorAudition = { _, _, _ in }

        state.mutatorStoreFaderSound(in: storage) // fader nie gra — nie ma czego zapisać
        XCTAssertNil(state.mutatorIndividual(at: storage))

        state.undoManager.beginUndoGrouping()
        state.moveVariationFader(to: 2.5, slot: 0)
        state.endVariationFaderGesture(slot: 0)
        state.undoManager.endUndoGrouping()

        state.undoManager.beginUndoGrouping()
        state.mutatorStoreFaderSound(in: storage)
        state.undoManager.endUndoGrouping()
        XCTAssertEqual(state.mutatorIndividual(at: storage)?[key], 25)

        state.undoManager.beginUndoGrouping()
        state.mutatorStoreFaderSound(in: G2MutatorBox(.variations, 6))
        state.undoManager.endUndoGrouping()
        XCTAssertEqual(value(state, knob, variation: 6), 25)
        XCTAssertEqual(state.slots[0].activeVariation, G2Patch.mutatorVariation) // dalej gra to samo

        state.undoManager.undo()
        XCTAssertEqual(value(state, knob, variation: 6), 60)
        state.undoManager.undo()
        XCTAssertNil(state.mutatorIndividual(at: storage))
    }

    func testMutatorAuditionTakesTheBufferOver() {
        let state = makeState(makePatch())
        state.onMutatorAudition = { _, _, _ in }

        state.undoManager.beginUndoGrouping()
        state.moveVariationFader(to: 1.5, slot: 0)
        state.endVariationFaderGesture(slot: 0)
        state.audition(state.currentIndividual(), registerUndo: false)
        state.undoManager.endUndoGrouping()

        XCTAssertNil(state.activeVariationFader(slot: 0))
        XCTAssertNil(state.variationFaderPosition(slot: 0))
    }
}
