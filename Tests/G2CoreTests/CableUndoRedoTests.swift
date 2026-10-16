// CableUndoRedoTests.swift
// ⌘Z i ⇧⌘Z dla kabli: wpięcie, wyrwanie i przepięcie (seria gestu) mają wracać
// i wracać z powrotem — zgłoszenie użytkownika 2026-09-24 („Redo dla zmiany kabli
// nie działa").

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class CableUndoRedoTests: XCTestCase {
    private static let envADSR = 20
    private static let output = 4

    private func makeModule(id: Int, typeID: Int) -> G2Module {
        var module = G2Module(id: id, typeID: typeID, area: .voice)
        let defaults = ModuleDefaultsDatabase.defaults(forTypeID: typeID)
        module.parameters = defaults
        module.parameterVariations = Array(repeating: defaults, count: G2Patch.runtimeVariationCount)
        module.hasParameterEntry = true
        return module
    }

    private func makeState() -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        var patch = G2Patch()
        patch.voiceModules = [
            makeModule(id: 1, typeID: Self.envADSR),
            makeModule(id: 2, typeID: Self.envADSR),
            makeModule(id: 3, typeID: Self.output),
        ]
        state.slots = [patch]
        return state
    }

    private func step(_ state: PatchState, _ action: () -> Void) {
        state.undoManager.beginUndoGrouping()
        action()
        state.undoManager.endUndoGrouping()
    }

    private func cable(from module: Int, to input: Int = 0) -> G2Cable {
        G2Cable(fromModule: module, fromConnector: 0, toModule: 3, toConnector: input,
                color: .red, area: .voice)
    }

    private func cables(_ state: PatchState) -> [G2Cable] {
        state.slots[0].voiceCables
    }

    func testAddCableUndoesAndRedoes() {
        let state = makeState()
        step(state) { state.addCable(cable(from: 1)) }
        XCTAssertEqual(cables(state).count, 1)

        state.undoManager.undo()
        XCTAssertEqual(cables(state).count, 0)
        XCTAssertTrue(state.undoManager.canRedo)

        state.undoManager.redo()
        XCTAssertEqual(cables(state).count, 1)
        XCTAssertTrue(state.undoManager.canUndo)

        state.undoManager.undo()
        XCTAssertEqual(cables(state).count, 0)
    }

    func testRemoveCableUndoesAndRedoes() {
        let state = makeState()
        step(state) { state.addCable(cable(from: 1)) }
        step(state) { state.removeCable(cable(from: 1)) }
        XCTAssertEqual(cables(state).count, 0)

        state.undoManager.undo()
        XCTAssertEqual(cables(state).count, 1)
        state.undoManager.redo()
        XCTAssertEqual(cables(state).count, 0)
        state.undoManager.undo()
        XCTAssertEqual(cables(state).count, 1)
    }

    /// Menu Edit czyta `undoRevision` — każdy ruch w historii ma go przesunąć, inaczej
    /// „Undo …/Redo …" stoją na starym stanie, a wyszarzone Redo połyka ⇧⌘Z.
    func testEveryHistoryMoveBumpsTheRevisionTheMenuWatches() {
        let state = makeState()
        var seen = state.undoRevision
        func moved() -> Bool {
            defer { seen = state.undoRevision }
            return state.undoRevision != seen
        }
        step(state) { state.addCable(cable(from: 1)) }
        XCTAssertTrue(moved(), "edycja")
        state.undoManager.undo()
        XCTAssertTrue(moved(), "undo")
        state.undoManager.redo()
        XCTAssertTrue(moved(), "redo")
        state.newPatch()
        XCTAssertTrue(moved(), "New")
    }

    /// Przepięcie: kanwa otwiera serię, wyrywa stary kabel, wpina nowy i zamyka serię.
    func testRewireGestureUndoesAndRedoes() {
        let state = makeState()
        step(state) { state.addCable(cable(from: 1)) }
        step(state) {
            state.beginStructureGesture("Move Cable")
            state.removeCable(cable(from: 1))
            state.addCable(cable(from: 2))
            state.endStructureGesture()
        }
        XCTAssertEqual(cables(state).map(\.fromModule), [2])

        state.undoManager.undo()
        XCTAssertEqual(cables(state).map(\.fromModule), [1])
        XCTAssertEqual(state.undoManager.redoActionName, "Move Cable")

        state.undoManager.redo()
        XCTAssertEqual(cables(state).map(\.fromModule), [2])
        XCTAssertEqual(state.undoManager.undoActionName, "Move Cable")
    }
}
