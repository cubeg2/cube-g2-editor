// VariationTests.swift
// Wariacje: przełączanie (0x6A) i przepisywanie jednej na drugą (0x44).
// Reguły pochodzą z oryginału Clavii — patrz [[Docs/ui/variations]].

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class VariationTests: XCTestCase {
    /// Moduł z rozróżnialną wartością w każdej z dziewięciu wariacji: w wariacji `v`
    /// parametr ma wartość `v * 10`, więc widać, skąd dokąd kopia poszła.
    private func makeModule(id: Int, area: PatchArea) -> G2Module {
        var module = G2Module(id: id, typeID: 1, area: area)
        module.parameterVariations = (0 ... 8).map { [$0 * 10] }
        module.parameters = module.parameterVariations[0]
        return module
    }

    private func makePatch() -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = [makeModule(id: 1, area: .voice)]
        patch.fxModules = [makeModule(id: 2, area: .fx)]
        for variation in 0 ... 8 {
            patch.variationSettings[variation].glideTime = variation
        }
        return patch
    }

    private func makeState(_ patch: G2Patch) -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.slots = [patch]
        return state
    }

    /// `groupsByEvent = false` znaczy, że grupy trzeba otworzyć ręcznie — inaczej
    /// `registerUndo` rzuca wyjątkiem (tak samo w `PatchStateTests`).
    private func undoStep(on state: PatchState, _ action: () -> Void) {
        state.undoManager.beginUndoGrouping()
        action()
        state.undoManager.endUndoGrouping()
    }

    // MARK: - Kopiowanie (0x44)

    func testCopyVariationCopiesBothAreasAndPatchSettings() {
        var patch = makePatch()
        patch.copyVariation(from: 3, to: 5)

        XCTAssertEqual(patch.voiceModules[0].parameterVariations[5], [30])
        XCTAssertEqual(patch.fxModules[0].parameterVariations[5], [30])
        XCTAssertEqual(patch.variationSettings[5].glideTime, 3)
        // Źródło zostaje nietknięte, sąsiednie wariacje też.
        XCTAssertEqual(patch.voiceModules[0].parameterVariations[3], [30])
        XCTAssertEqual(patch.voiceModules[0].parameterVariations[4], [40])
    }

    /// „Init" w oryginale przywołuje zestaw init (wariacja 8) do bieżącej wariacji —
    /// Param Setting Copy(8, focused). Gałki muszą od razu pokazać nowe wartości.
    func testInitCopyRefreshesVisibleValues() {
        var patch = makePatch()
        patch.setActiveVariation(2)
        XCTAssertEqual(patch.voiceModules[0].parameters, [20])

        patch.copyVariation(from: 8, to: patch.activeVariation)

        XCTAssertEqual(patch.voiceModules[0].parameterVariations[2], [80])
        XCTAssertEqual(patch.voiceModules[0].parameters, [80], "widok gałek ma pokazać skopiowaną wariację")
    }

    /// Kopia do wariacji, której nie widać, nie może ruszyć tego, co pokazują gałki.
    func testCopyIntoHiddenVariationLeavesVisibleValuesAlone() {
        var patch = makePatch()
        patch.setActiveVariation(1)

        patch.copyVariation(from: 0, to: 7)

        XCTAssertEqual(patch.voiceModules[0].parameters, [10])
        XCTAssertEqual(patch.voiceModules[0].parameterVariations[7], [0])
    }

    func testCopyVariationIgnoresNonsenseArguments() {
        var patch = makePatch()
        patch.copyVariation(from: 2, to: 2)
        patch.copyVariation(from: 0, to: 9)
        patch.copyVariation(from: -1, to: 3)

        for variation in 0 ... 8 {
            XCTAssertEqual(patch.voiceModules[0].parameterVariations[variation], [variation * 10])
        }
    }

    // MARK: - Przełączanie (0x6A)

    func testSelectVariationChangesTheViewAndTellsTheDevice() {
        let state = makeState(makePatch())
        var reported: [(slot: Int, variation: Int)] = []
        state.onVariationChange = { slot, variation in reported.append((slot, variation)) }

        undoStep(on: state) { state.selectVariation(4) }

        XCTAssertEqual(state.patch.activeVariation, 4)
        XCTAssertEqual(state.patch.voiceModules[0].parameters, [40])
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.slot, 0)
        XCTAssertEqual(reported.first?.variation, 4)
    }

    /// Oryginał zapisuje przełączenie wariacji jako parę undo/redo
    /// (`CPatch::InternalSetFocusedParamSetting`) — u nas tak samo.
    func testSelectVariationIsUndoable() {
        let state = makeState(makePatch())
        undoStep(on: state) { state.selectVariation(6) }
        XCTAssertEqual(state.patch.activeVariation, 6)

        state.undoManager.undo()
        XCTAssertEqual(state.patch.activeVariation, 0)

        state.undoManager.redo()
        XCTAssertEqual(state.patch.activeVariation, 6)
    }

    /// Wariacja init jest dziewiąta i nie da się na niej grać — wybrać można 1…8.
    func testSelectVariationRefusesInitAndOutOfRange() {
        let state = makeState(makePatch())
        var reported = 0
        state.onVariationChange = { _, _ in reported += 1 }

        undoStep(on: state) {
            state.selectVariation(8)
            state.selectVariation(-1)
        }

        XCTAssertEqual(state.patch.activeVariation, 0)
        XCTAssertEqual(reported, 0)
    }

    func testStateCopyVariationAppliesLocallyAndTellsTheDevice() {
        let state = makeState(makePatch())
        var reported: [(slot: Int, from: Int, to: Int)] = []
        state.onVariationCopy = { slot, from, to in reported.append((slot, from, to)) }

        undoStep(on: state) { state.copyVariation(from: 8, to: 0) }

        XCTAssertEqual(state.patch.voiceModules[0].parameters, [80])
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.from, 8)
        XCTAssertEqual(reported.first?.to, 0)
    }

    /// Init wariacji da się cofnąć (oryginał nie umie): ⌘Z przywraca wartości sprzed kopii
    /// i odsyła cały slot do Norda, bo protokół nie ma komendy odwrotnej do `0x44`.
    func testVariationInitIsUndoableAndResendsTheSlot() {
        let state = makeState(makePatch())
        let before = state.patch
        var restored: [Int] = []
        state.onSlotRestore = { restored.append($0) }

        undoStep(on: state) { state.copyVariation(from: 8, to: 0) }
        XCTAssertEqual(state.undoManager.undoActionName, "Init Variation")

        state.undoManager.undo()
        XCTAssertEqual(state.patch, before)
        XCTAssertEqual(restored, [0])

        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceModules[0].parameters, [80])
    }

    // MARK: - Edit all (BVerhue `EditAllVariations`)

    /// Włączony „Edit all": ruch gałki trafia do wariacji 1–8, Init zostaje nietknięty,
    /// a do urządzenia idzie `SET_PARAM` z numerem każdej wariacji.
    func testEditAllWritesEveryPlayableVariationAndTellsTheDevice() {
        let state = makeState(makePatch())
        var sent: [Int] = []
        state.onLiveParameterChange = { _, _, _, _, value, variation in
            XCTAssertEqual(value, 55)
            sent.append(variation)
        }
        state.toggleEditAllVariations(slot: 0)

        undoStep(on: state) { state.setParameter(moduleID: 1, paramIndex: 0, value: 55, area: .voice) }

        for variation in 0 ... 7 {
            XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[variation], [55])
        }
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[8], [80], "Init zostaje")
        XCTAssertEqual(state.patch.voiceModules[0].parameters, [55])
        XCTAssertEqual(sent.sorted(), Array(0 ... 7))
    }

    /// Jedno ⌘Z po całym ruchu gałki przywraca każdej wariacji JEJ wartość sprzed ruchu.
    func testEditAllGestureUndoesToEachVariationsOwnValue() {
        let state = makeState(makePatch())
        state.toggleEditAllVariations(slot: 0)

        undoStep(on: state) {
            state.beginParameterGesture()
            state.setParameter(moduleID: 1, paramIndex: 0, value: 50, area: .voice)
            state.setParameter(moduleID: 1, paramIndex: 0, value: 60, area: .voice)
            state.endParameterGesture()
        }
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[3], [60])

        state.undoManager.undo()
        for variation in 0 ... 8 {
            XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[variation], [variation * 10])
        }
        XCTAssertEqual(state.patch.voiceModules[0].parameters, [0])

        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[5], [60])
    }

    /// Wyłączony — jak dotąd: zmienia się tylko grająca wariacja.
    func testWithoutEditAllOnlyTheActiveVariationChanges() {
        let state = makeState(makePatch())
        state.toggleEditAllVariations(slot: 0)
        state.toggleEditAllVariations(slot: 0)

        undoStep(on: state) { state.setParameter(moduleID: 1, paramIndex: 0, value: 55, area: .voice) }

        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[0], [55])
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[1], [10])
    }

    // MARK: - Bajty komend

    func testVariationPayloadsMatchTheOriginal() {
        // `[0x01][COMMAND_REQ|COMMAND_SLOT|slot][wersja][0x6A][wariacja]`
        XCTAssertEqual(
            G2UsbProtocol.selectVariationPayload(slot: 2, version: 0x12, variation: 3),
            [0x01, 0x2A, 0x12, 0x6A, 0x03]
        )
        // `[…][0x44][źródło][cel]` — kolejność jak w `AddMsgCopyVariation` i Param Setting Copy.
        XCTAssertEqual(
            G2UsbProtocol.copyVariationPayload(slot: 0, version: 0x08, from: 8, to: 1),
            [0x01, 0x28, 0x08, 0x44, 0x08, 0x01]
        )
    }
}
