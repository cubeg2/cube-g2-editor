// ContextMenuCommandTests.swift
// Polecenia, które instrukcja Clavii wiesza pod prawym przyciskiem nad parametrem
// i nad modułem (str. 69–70) oraz w menu Tools (str. 130): przypisania gałek,
// przypisania MIDI CC, „Paste Params" i „Delete Unused Modules".

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class ContextMenuCommandTests: XCTestCase {
    /// EnvADSR (typ 20) — osiem parametrów, więc mieści się dokładnie na jednej stronie.
    private static let envADSR = 20
    /// 2-Out (typ 4) — trzy parametry, moduł z gniazdami.
    private static let output = 4

    private func makeModule(id: Int, typeID: Int, area: PatchArea) -> G2Module {
        var module = G2Module(id: id, typeID: typeID, area: area)
        let defaults = ModuleDefaultsDatabase.defaults(forTypeID: typeID)
        module.parameters = defaults
        module.parameterVariations = Array(repeating: defaults,
                                           count: G2Patch.runtimeVariationCount)
        module.hasParameterEntry = true
        return module
    }

    private func makeState() -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        var patch = G2Patch()
        patch.voiceModules = [
            makeModule(id: 1, typeID: Self.envADSR, area: .voice),
            makeModule(id: 2, typeID: Self.envADSR, area: .voice),
            makeModule(id: 3, typeID: Self.output, area: .voice),
        ]
        state.slots = [patch]
        return state
    }

    private func undoStep(on state: PatchState, _ action: () -> Void) {
        state.undoManager.beginUndoGrouping()
        action()
        state.undoManager.endUndoGrouping()
    }

    // MARK: - Assign ▸ Page X

    /// Parametr ląduje na PIERWSZEJ WOLNEJ gałce wskazanej strony.
    func testAssignToPagePicksTheFirstFreeKnob() {
        let state = makeState()
        undoStep(on: state) {
            state.assignKnob(toPage: 2, location: PatchArea.voice.rawValue,
                             moduleID: 1, paramIndex: 0)
        }
        XCTAssertEqual(state.knobIndex(location: PatchArea.voice.rawValue,
                                       moduleID: 1, paramIndex: 0),
                       G2KnobPages.knobIndex(page: 2, slot: 0))
    }

    func testClearKnobByParameterRemovesTheAssignment() {
        let state = makeState()
        let location = PatchArea.voice.rawValue
        undoStep(on: state) {
            state.assignKnob(toPage: 0, location: location, moduleID: 1, paramIndex: 0)
        }
        undoStep(on: state) {
            state.clearKnob(location: location, moduleID: 1, paramIndex: 0)
        }
        XCTAssertNil(state.knobIndex(location: location, moduleID: 1, paramIndex: 0))
    }

    /// „Assign ▸ Page X ▸ Multi Column" — wszystkie parametry modułu naraz, a gdy
    /// jedna strona nie starczy, następne (instrukcja, str. 91).
    func testAssignAllParametersSpillsOntoTheNextPage() {
        let state = makeState()
        let location = PatchArea.voice.rawValue
        // Strona A1 zajęta w połowie: cztery gałki idą na inny moduł.
        undoStep(on: state) {
            for index in 0 ..< 4 {
                state.assignKnob(index: G2KnobPages.knobIndex(page: 0, slot: index),
                                 location: location, moduleID: 2, paramIndex: index)
            }
        }

        var assigned = 0
        undoStep(on: state) {
            assigned = state.assignAllParameters(ofModule: 1, area: .voice,
                                                 toPage: 0, global: false)
        }

        XCTAssertEqual(assigned, 8, "EnvADSR ma osiem parametrów i wszystkie mają wylądować")
        let pages = Set((0 ..< 8).compactMap {
            state.knobIndex(location: location, moduleID: 1, paramIndex: $0)
        }.map { $0 / G2KnobPages.knobsPerPage })
        XCTAssertEqual(pages, [0, 1], "cztery na resztę A1, cztery na A2")
    }

    /// Globalne strony performance'u to osobna mapa — przypisanie na jednej nie
    /// pojawia się na drugiej.
    func testGlobalAssignUsesTheSeparatePerformanceMap() {
        let state = makeState()
        let location = PatchArea.voice.rawValue
        undoStep(on: state) {
            state.assignGlobalKnob(toPage: 1, location: location, moduleID: 1, paramIndex: 0)
        }
        XCTAssertEqual(state.globalKnobIndex(location: location, moduleID: 1, paramIndex: 0),
                       G2KnobPages.knobIndex(page: 1, slot: 0))
        XCTAssertNil(state.knobIndex(location: location, moduleID: 1, paramIndex: 0))
    }

    // MARK: - MIDI Controller ▸

    func testAssignAndRemoveMidiController() {
        let state = makeState()
        let location = PatchArea.voice.rawValue
        undoStep(on: state) {
            state.assignMidiController(cc: 20, location: location, moduleID: 1, paramIndex: 0)
        }
        XCTAssertEqual(state.midiController(location: location, moduleID: 1, paramIndex: 0), 20)

        undoStep(on: state) {
            state.clearMidiController(location: location, moduleID: 1, paramIndex: 0)
        }
        XCTAssertNil(state.midiController(location: location, moduleID: 1, paramIndex: 0))
    }

    /// Numery zarezerwowane (tu: Modwheel) odpadają — `G2MidiControllers.isValid`.
    func testReservedControllerNumbersAreRefused() {
        let state = makeState()
        let location = PatchArea.voice.rawValue
        undoStep(on: state) {
            state.assignMidiController(cc: 1, location: location, moduleID: 1, paramIndex: 0)
        }
        XCTAssertNil(state.midiController(location: location, moduleID: 1, paramIndex: 0))
    }

    /// „Assign MIDI to Selection" obsadza wszystkie parametry wskazanych modułów.
    func testAssignMidiToSelectionCoversEveryParameter() {
        let state = makeState()
        let location = PatchArea.voice.rawValue
        undoStep(on: state) {
            state.assignMidiControllers(toModules: [1], area: .voice)
        }
        for index in 0 ..< 8 {
            XCTAssertNotNil(state.midiController(location: location, moduleID: 1,
                                                 paramIndex: index),
                            "parametr \(index) miał dostać CC")
        }
        XCTAssertNil(state.midiController(location: location, moduleID: 2, paramIndex: 0),
                     "moduł spoza zaznaczenia zostaje bez CC")
    }

    func testDeassignAllMidiClearsTheWholeMap() {
        let state = makeState()
        undoStep(on: state) { state.assignMidiControllers(toModules: [1, 2], area: .voice) }
        undoStep(on: state) { state.clearAllMidiControllers() }
        XCTAssertTrue(state.patch.midiControllerAssignments.allSatisfy { $0 == nil })
    }

    // MARK: - Paste Params

    /// Wartości ze schowka lądują na module TEGO SAMEGO typu.
    func testPasteParamsCopiesValuesOntoTheSameType() {
        let state = makeState()
        let source = G2ClipboardContent.ClipModule(
            typeID: Self.envADSR, column: 0, row: 0,
            parameters: [11, 22, 33, 44, 55, 0, 1, 0],
            parameterVariations: [], modes: [], label: "", color: 0, originalID: 99
        )
        let content = G2ClipboardContent(modules: [source], cables: [])

        var pasted = 0
        undoStep(on: state) {
            pasted = state.pasteParameters(content, into: [1, 2], area: .voice)
        }

        XCTAssertEqual(pasted, 2, "jedno źródło obsadza całą zaznaczoną grupę tego typu")
        XCTAssertEqual(state.patch.voiceModules[0].parameters, source.parameters)
        XCTAssertEqual(state.patch.voiceModules[1].parameters, source.parameters)
    }

    /// Moduł innego typu zostaje nietknięty.
    func testPasteParamsSkipsOtherTypes() {
        let state = makeState()
        let before = state.patch.voiceModules[2].parameters
        let source = G2ClipboardContent.ClipModule(
            typeID: Self.envADSR, column: 0, row: 0,
            parameters: [11, 22, 33, 44, 55, 0, 1, 0],
            parameterVariations: [], modes: [], label: "", color: 0, originalID: 99
        )

        undoStep(on: state) {
            _ = state.pasteParameters(G2ClipboardContent(modules: [source], cables: []),
                                      into: [3], area: .voice)
        }

        XCTAssertEqual(state.patch.voiceModules[2].parameters, before)
    }

    func testPasteParamsIsUndoable() {
        let state = makeState()
        let before = state.patch.voiceModules[0].parameters
        let source = G2ClipboardContent.ClipModule(
            typeID: Self.envADSR, column: 0, row: 0,
            parameters: [11, 22, 33, 44, 55, 0, 1, 0],
            parameterVariations: [], modes: [], label: "", color: 0, originalID: 99
        )
        undoStep(on: state) {
            _ = state.pasteParameters(G2ClipboardContent(modules: [source], cables: []),
                                      into: [1], area: .voice)
        }
        state.undoManager.undo()

        XCTAssertEqual(state.patch.voiceModules[0].parameters, before)
    }

    // MARK: - Delete Unused Modules

    /// „Unused" to moduł bez jednego kabla — ale tylko taki, który W OGÓLE ma gniazda.
    func testUnusedModulesAreTheOnesWithoutCables() {
        let state = makeState()
        state.slots[0].voiceCables = [
            G2Cable(fromModule: 1, fromConnector: 0, toModule: 3, toConnector: 0,
                    color: .blue, area: .voice, sourceIsOutput: true),
        ]
        XCTAssertEqual(state.unusedModuleIDs(area: .voice), [2])

        undoStep(on: state) { state.deleteUnusedModules(area: .voice) }
        XCTAssertEqual(Set(state.patch.voiceModules.map(\.id)), [1, 3])
    }

    /// Moduł bez gniazd (Name, typ 126) nie jest „nieużywany" — nie da się go podłączyć.
    func testModulesWithoutConnectorsAreNeverUnused() {
        let state = makeState()
        state.slots[0].voiceModules.append(makeModule(id: 4, typeID: 126, area: .voice))
        XCTAssertFalse(state.unusedModuleIDs(area: .voice).contains(4))
    }
}
