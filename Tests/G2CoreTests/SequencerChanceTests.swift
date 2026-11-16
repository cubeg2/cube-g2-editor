import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class SequencerChanceTests: XCTestCase {
    private let seqEvent = 144

    private func makeState() -> (PatchState, seq: Int, clock: Int, target: Int) {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.undoManager.beginUndoGrouping()
        let clock = state.addModule(typeID: 7, area: .voice)!
        let seq = state.addModule(typeID: 144, area: .voice)!
        let target = state.addModule(typeID: 7, area: .voice)!
        // clock → seq.Clk (input 0), seq.Trig1 (output 1) → target input 0
        state.addCable(G2Cable(fromModule: clock, fromConnector: 0, toModule: seq, toConnector: 0,
                               color: .yellow, area: .voice))
        state.addCable(G2Cable(fromModule: seq, fromConnector: 1, toModule: target, toConnector: 0,
                               color: .yellow, area: .voice))
        state.undoManager.endUndoGrouping()
        state.undoManager.removeAllActions()
        return (state, seq, clock, target)
    }

    func testChanceOutputsOfEachSequencer() {
        XCTAssertEqual(PatchState.chanceOutputs(typeID: 144).map(\.title), ["Row 1", "Row 2"])
        XCTAssertEqual(PatchState.chanceOutputs(typeID: 121).map(\.title), ["Trig"])
        XCTAssertTrue(PatchState.chanceOutputs(typeID: 154).isEmpty) // SeqCtr has no clock
        XCTAssertTrue(PatchState.chanceOutputs(typeID: 7).isEmpty)
    }

    func testChanceLaneAddsTwoModulesAndMovesTheTrigCables() throws {
        let (state, seq, clock, target) = makeState()
        let lane = try XCTUnwrap(state.addChanceLane(slot: 0, area: .voice, sequencerID: seq, trigOutput: 1))
        let patch = state.patch
        let rnd = try XCTUnwrap(patch.voiceModules.first { $0.typeID == 205 })
        let cables = patch.voiceCables

        XCTAssertEqual(patch.voiceModules.count, 5)
        // the target is now fed by RndTrig, not by the sequencer
        XCTAssertTrue(cables.contains { $0.fromModule == rnd.id && $0.toModule == target })
        XCTAssertFalse(cables.contains { $0.fromModule == seq && $0.toModule == target })
        // sequencer trig → RndTrig.Clk, lane Val → RndTrig.Prob, clock → the lane's Clk
        XCTAssertTrue(cables.contains { $0.fromModule == seq && $0.fromConnector == 1 && $0.toModule == rnd.id })
        XCTAssertTrue(cables.contains { $0.fromModule == lane && $0.toModule == rnd.id })
        XCTAssertTrue(cables.contains { $0.fromModule == clock && $0.toModule == lane })
        // full bars in every variation, StepProb 0 and StepProbMod 100
        let level = try XCTUnwrap(patch.voiceModules.first { $0.id == lane })
        for variation in 0 ..< G2Patch.initVariation {
            XCTAssertEqual(Array(level.parameterVariations[variation][0 ..< 16]), Array(repeating: 127, count: 16))
        }
        XCTAssertEqual(rnd.parameterVariations[3][0], 0)
        XCTAssertEqual(rnd.parameterVariations[3][1], 127)
    }

    func testAccentLaneIsOneClockedSeqLevAndLeavesCablesAlone() throws {
        let (state, seq, clock, target) = makeState()
        let label = PatchState.accentLabel(sequencerName: "Seq")
        let lane = try XCTUnwrap(state.addAccentLane(slot: 0, area: .voice, sequencerID: seq, label: label))
        let patch = state.patch
        XCTAssertEqual(patch.voiceModules.count, 4)
        XCTAssertEqual(state.accentLaneID(slot: 0, area: .voice, label: label), lane)
        XCTAssertTrue(patch.voiceCables.contains { $0.fromModule == clock && $0.toModule == lane })
        XCTAssertTrue(patch.voiceCables.contains { $0.fromModule == seq && $0.toModule == target })
        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules.count, 3)
    }

    func testOneUndoTakesTheWholeLaneBack() {
        let (state, seq, _, target) = makeState()
        XCTAssertNotNil(state.addChanceLane(slot: 0, area: .voice, sequencerID: seq, trigOutput: 1))
        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules.count, 3)
        XCTAssertTrue(state.patch.voiceCables.contains { $0.fromModule == seq && $0.toModule == target })
        XCTAssertFalse(state.undoManager.canUndo)
    }

    func testChanceLaneIsRefusedWhenThePatchWouldPassFullDSP() throws {
        let (state, seq, _, _) = makeState()
        XCTAssertTrue(state.chanceLaneFits(slot: 0, area: .voice))
        let heavy = try XCTUnwrap(ModuleDatabase.all.max { lhs, rhs in
            (ModuleResourceCostDatabase.cost(typeID: lhs.id)?.cyclesRed ?? 0)
                < (ModuleResourceCostDatabase.cost(typeID: rhs.id)?.cyclesRed ?? 0)
        }?.id)
        state.undoManager.beginUndoGrouping()
        for _ in 0 ..< 60 { _ = state.addModule(typeID: heavy, area: .voice) }
        state.undoManager.endUndoGrouping()
        XCTAssertFalse(state.chanceLaneFits(slot: 0, area: .voice))
        XCTAssertNil(state.addChanceLane(slot: 0, area: .voice, sequencerID: seq, trigOutput: 1))
    }

    func testNothingHappensForAnUnknownSequencer() {
        let (state, _, clock, _) = makeState()
        XCTAssertNil(state.addChanceLane(slot: 0, area: .voice, sequencerID: clock, trigOutput: 0))
        XCTAssertEqual(state.patch.voiceModules.count, 3)
    }
}
