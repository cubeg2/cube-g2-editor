// CableChainTests.swift
// Łańcuchy kabli i menu pod prawym przyciskiem nad kablem — „Cable popup"
// z instrukcji Clavii (str. 70–71): Disconnect, Break, Color, Delete,
// Delete Unused Cables.

import G2Core
@testable import G2EditorCore
import XCTest

/// Kabel wyjście→wejście.
private func fromOutput(_ from: Int, _ fromConn: Int, to: Int, _ toConn: Int,
                        color: CableColor = .red) -> G2Cable
{
    G2Cable(fromModule: from, fromConnector: fromConn, toModule: to, toConnector: toConn,
            color: color, area: .voice, sourceIsOutput: true)
}

/// Kabel wejście→wejście (szereg).
private func fromInput(_ from: Int, _ fromConn: Int, to: Int, _ toConn: Int,
                       color: CableColor = .white) -> G2Cable
{
    G2Cable(fromModule: from, fromConnector: fromConn, toModule: to, toConnector: toConn,
            color: color, area: .voice, sourceIsOutput: false)
}

final class CableChainTests: XCTestCase {
    // MARK: - Zasięg łańcucha

    /// Szereg out1 → in1 → in2 to JEDEN łańcuch: rozrost idzie przez wejścia.
    func testChainSpansSerialInputs() {
        var patch = G2Patch()
        let feeder = fromOutput(1, 0, to: 2, 0)
        let serial = fromInput(2, 0, to: 3, 0)
        patch.voiceCables = [feeder, serial]

        let chain = patch.cableChain(containing: serial, in: .voice)
        XCTAssertEqual(chain.count, 2)
        XCTAssertTrue(chain.contains { $0.connectsSameAs(feeder) })
    }

    /// Dwa kable z tego samego WYJŚCIA to dwa osobne łańcuchy — instrukcja każe
    /// kasować rozgałęzienie od źródła, nie od gałęzi.
    func testBranchesFromOneOutputStaySeparate() {
        var patch = G2Patch()
        let left = fromOutput(1, 0, to: 2, 0)
        let right = fromOutput(1, 0, to: 3, 0)
        patch.voiceCables = [left, right]

        XCTAssertEqual(patch.cableChain(containing: left, in: .voice).count, 1)
        XCTAssertEqual(patch.cableChain(containing: right, in: .voice).count, 1)
    }

    // MARK: - Disconnect / Break / Delete

    /// „Disconnect" odpina gniazdo docelowe i zszywa łańcuch: to, co szło dalej
    /// z tego gniazda, dostaje sygnał prosto ze źródła.
    func testDisconnectRewiresTheRestOfTheChain() {
        var patch = G2Patch()
        patch.voiceCables = [fromOutput(1, 0, to: 2, 0), fromInput(2, 0, to: 3, 0)]

        patch.disconnectCable(patch.voiceCables[0], in: .voice)

        XCTAssertEqual(patch.voiceCables.count, 1)
        let rerouted = patch.voiceCables[0]
        XCTAssertEqual(rerouted.fromModule, 1)
        XCTAssertEqual(rerouted.toModule, 3)
        XCTAssertTrue(rerouted.sourceIsOutput, "przepięty kabel wychodzi teraz z wyjścia")
    }

    /// „Break" nie zszywa niczego — ogon łańcucha zostaje wpięty, ale bez sygnału.
    func testBreakLeavesTheTailDangling() {
        var patch = G2Patch()
        let feeder = fromOutput(1, 0, to: 2, 0)
        patch.voiceCables = [feeder, fromInput(2, 0, to: 3, 0)]

        patch.breakCable(feeder)

        XCTAssertEqual(patch.voiceCables.count, 1)
        XCTAssertTrue(patch.isCableUnused(patch.voiceCables[0], in: .voice))
    }

    /// „Delete" zabiera cały łańcuch szeregowy.
    func testDeleteRemovesTheWholeChain() {
        var patch = G2Patch()
        patch.voiceCables = [fromOutput(1, 0, to: 2, 0), fromInput(2, 0, to: 3, 0)]

        patch.deleteCableChain(containing: patch.voiceCables[1], in: .voice)

        XCTAssertTrue(patch.voiceCables.isEmpty)
    }

    // MARK: - Kolor

    /// Kolor zmienia się dla CAŁEGO łańcucha — instrukcja: „Cables in a serial
    /// cable chain will always have the same color."
    func testColorAppliesToTheWholeChain() {
        var patch = G2Patch()
        patch.voiceCables = [fromOutput(1, 0, to: 2, 0), fromInput(2, 0, to: 3, 0)]

        patch.setCableColor(.green, forChainContaining: patch.voiceCables[0], in: .voice)

        XCTAssertEqual(patch.voiceCables.map(\.color), [.green, .green])
    }

    // MARK: - Kable bez sygnału

    func testUnusedCablesAreTheChainsWithoutAnOutput() {
        var patch = G2Patch()
        let live = fromOutput(1, 0, to: 2, 0)
        let dead = fromInput(5, 0, to: 6, 0)
        patch.voiceCables = [live, dead]

        let unused = patch.unusedCables(in: .voice)
        XCTAssertEqual(unused.count, 1)
        XCTAssertTrue(unused[0].connectsSameAs(dead))
    }

    func testRecolorUnusedChainsPaintsThemWhite() {
        var patch = G2Patch()
        patch.voiceCables = [fromInput(5, 0, to: 6, 0, color: .red)]

        patch.recolorUnusedChains(in: .voice)

        XCTAssertEqual(patch.voiceCables[0].color, .white)
    }

    // MARK: - Jedno wyjście na wejście (#142)

    /// Drugie wyjście w to samo wejście — oryginalny edytor odmawia, instrukcja
    /// mówi „an input can be connected to only one output".
    func testSecondOutputIntoOneInputIsRefused() {
        var patch = G2Patch()
        patch.voiceCables = [fromOutput(1, 0, to: 3, 0)]

        XCTAssertTrue(patch.cableWouldJoinTwoOutputs(fromOutput(2, 0, to: 3, 0), in: .voice))
    }

    /// Kabel wejście→wejście, który zszyłby dwa łańcuchy z różnymi wyjściami.
    func testInputChainJoiningTwoOutputsIsRefused() {
        var patch = G2Patch()
        patch.voiceCables = [fromOutput(1, 0, to: 3, 0), fromOutput(2, 0, to: 4, 0)]

        XCTAssertTrue(patch.cableWouldJoinTwoOutputs(fromInput(3, 0, to: 4, 0), in: .voice))
    }

    /// To, co instrukcja pozwala: jedno wyjście w wiele wejść, szereg wejść z jednym
    /// źródłem, a nawet to samo wyjście dwiema drogami w jeden łańcuch.
    func testSharingOneOutputIsAllowed() {
        var patch = G2Patch()
        patch.voiceCables = [fromOutput(1, 0, to: 3, 0), fromInput(3, 0, to: 4, 0)]

        XCTAssertFalse(patch.cableWouldJoinTwoOutputs(fromOutput(1, 0, to: 5, 0), in: .voice))
        XCTAssertFalse(patch.cableWouldJoinTwoOutputs(fromInput(4, 0, to: 6, 0), in: .voice))
        XCTAssertFalse(patch.cableWouldJoinTwoOutputs(fromOutput(1, 0, to: 4, 0), in: .voice))
        // Inne wejście tego samego modułu to inne gniazdo — osobny łańcuch.
        XCTAssertFalse(patch.cableWouldJoinTwoOutputs(fromOutput(2, 0, to: 3, 1), in: .voice))
    }

    /// Plik z zewnątrz może już mieć taki łańcuch — wtedy go wskazujemy, nie kasujemy.
    func testChainsWithSeveralOutputsAreFound() {
        var patch = G2Patch()
        patch.voiceCables = [fromOutput(1, 0, to: 3, 0), fromOutput(2, 0, to: 4, 0),
                             fromInput(3, 0, to: 4, 0), fromOutput(1, 0, to: 7, 0)]

        let chains = patch.chainsWithSeveralOutputs(in: .voice)
        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(chains.first?.count, 3)
    }
}

@MainActor
final class CableCommandStateTests: XCTestCase {
    private func makeState() -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        var patch = G2Patch()
        patch.voiceCables = [
            G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 0,
                    color: .red, area: .voice, sourceIsOutput: true),
            G2Cable(fromModule: 5, fromConnector: 0, toModule: 6, toConnector: 0,
                    color: .white, area: .voice, sourceIsOutput: false),
        ]
        state.slots = [patch]
        return state
    }

    private func undoStep(on state: PatchState, _ action: () -> Void) {
        state.undoManager.beginUndoGrouping()
        action()
        state.undoManager.endUndoGrouping()
    }

    func testDeleteUnusedCablesRemovesOnlyTheDeadChain() {
        let state = makeState()
        undoStep(on: state) { state.deleteUnusedCables(area: .voice) }

        XCTAssertEqual(state.patch.voiceCables.count, 1)
        XCTAssertEqual(state.patch.voiceCables[0].fromModule, 1)
    }

    func testCableOperationsAreUndoable() {
        let state = makeState()
        let before = state.patch.voiceCables
        undoStep(on: state) { state.deleteUnusedCables(area: .voice) }
        state.undoManager.undo()

        XCTAssertEqual(state.patch.voiceCables, before)
    }

    /// Kabel z wyjścia ożywia łańcuch, w który wpadł — biały szereg dostaje kolor źródła.
    func testAddingAnOutputCableRecolorsTheChain() {
        let state = makeState()
        let feeder = G2Cable(fromModule: 4, fromConnector: 0, toModule: 5, toConnector: 0,
                             color: .blue, area: .voice, sourceIsOutput: true)
        undoStep(on: state) { state.addCable(feeder) }

        let serial = state.patch.voiceCables.first { $0.fromModule == 5 }
        XCTAssertEqual(serial?.color, .blue)
    }

    /// Kabel wejście→wejście wpięty w łańcuch, który już ma źródło, przejmuje jego
    /// kolor — „kable jednego łańcucha mają zawsze ten sam kolor" (str. 71).
    func testInputToInputCableJoiningAFedChainTakesItsColor() {
        let state = makeState()
        let serial = G2Cable(fromModule: 2, fromConnector: 0, toModule: 7, toConnector: 1,
                             color: .white, area: .voice, sourceIsOutput: false)
        undoStep(on: state) { state.addCable(serial) }

        let added = state.patch.voiceCables.first { $0.toModule == 7 }
        XCTAssertEqual(added?.color, .red)
    }

    func testUnusedCableCountReportsTheDeadChain() {
        XCTAssertEqual(makeState().unusedCableCount(area: .voice), 1)
    }

    // MARK: - Disconnect Cables ▸ (kable zaznaczenia) i Disconnect All Cables

    /// Moduły 1 (źródło spoza grupy) → 2 → 3 w szeregu, 2 → 4 z wyjścia;
    /// zaznaczone są 2 i 3.
    private func groupPatch() -> G2Patch {
        var patch = G2Patch()
        patch.voiceCables = [
            fromOutput(1, 0, to: 2, 0),
            fromInput(2, 0, to: 3, 0, color: .red),
            fromOutput(2, 0, to: 4, 0),
        ]
        return patch
    }

    func testDisconnectAllCablesOfSelectionLeavesTheRest() {
        var patch = groupPatch()
        patch.voiceCables.append(fromOutput(5, 0, to: 6, 0))

        patch.disconnectCables(of: [2, 3], scope: .all, in: .voice)

        XCTAssertEqual(patch.voiceCables.count, 1)
        XCTAssertEqual(patch.voiceCables[0].fromModule, 5)
    }

    /// Szereg zewnętrzne wejście → wejście grupy → zewnętrzne wejście zszywa się
    /// ze źródłem, jak przy zwykłym „Disconnect".
    func testDisconnectAllRewiresAChainPassingThroughTheSelection() {
        var patch = G2Patch()
        patch.voiceCables = [fromOutput(1, 0, to: 2, 0), fromInput(2, 0, to: 3, 0, color: .red)]

        patch.disconnectCables(of: [2], scope: .all, in: .voice)

        XCTAssertEqual(patch.voiceCables.count, 1)
        XCTAssertEqual(patch.voiceCables[0].fromModule, 1)
        XCTAssertEqual(patch.voiceCables[0].toModule, 3)
        XCTAssertFalse(patch.isCableUnused(patch.voiceCables[0], in: .voice))
    }

    func testDisconnectInsideSelectionKeepsCablesToTheRest() {
        var patch = groupPatch()

        patch.disconnectCables(of: [2, 3], scope: .insideSelection, in: .voice)

        XCTAssertEqual(patch.voiceCables.count, 2)
        XCTAssertFalse(patch.voiceCables.contains { $0.fromModule == 2 && $0.toModule == 3 })
    }

    /// „To Rest of Patch" zostawia okablowanie w środku grupy; szereg, który stracił
    /// źródło, bieleje.
    func testDisconnectToRestOfPatchKeepsTheGroupWiredInside() {
        var patch = groupPatch()

        patch.disconnectCables(of: [2, 3], scope: .toRestOfPatch, in: .voice)

        XCTAssertEqual(patch.voiceCables.count, 1)
        let inside = patch.voiceCables[0]
        XCTAssertEqual(inside.fromModule, 2)
        XCTAssertEqual(inside.toModule, 3)
        XCTAssertEqual(inside.color, .white)
    }

    func testDisconnectModuleCablesIsOneUndoStep() {
        let state = makeState()
        state.slots = [groupPatch()]
        let before = state.patch.voiceCables
        XCTAssertEqual(state.cableCount(ofModules: [2, 3], scope: .all, area: .voice), 3)

        undoStep(on: state) { state.disconnectCables(ofModules: [2, 3], scope: .all, area: .voice) }
        XCTAssertTrue(state.patch.voiceCables.isEmpty)
        state.undoManager.undo()

        XCTAssertEqual(state.patch.voiceCables, before)
    }

    func testDisconnectAllCablesClearsVoiceAndFXInOneUndoStep() {
        let state = makeState()
        state.slots[0].fxCables = [
            G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 0,
                    color: .red, area: .fx, sourceIsOutput: true),
        ]
        let before = state.patch
        XCTAssertEqual(state.totalCableCount, 3)

        undoStep(on: state) { state.disconnectAllCables() }
        XCTAssertEqual(state.totalCableCount, 0)
        state.undoManager.undo()

        XCTAssertEqual(state.patch.voiceCables, before.voiceCables)
        XCTAssertEqual(state.patch.fxCables, before.fxCables)
    }
}
