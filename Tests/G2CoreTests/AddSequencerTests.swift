// AddSequencerTests.swift
// "Add Sequencer": a patch without one gets a SeqNote that takes over the keyboard's Pitch and Gate.

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class AddSequencerTests: XCTestCase {
    /// Keyboard (1) → Pitch to an oscillator (OscB 28? any module with inputs), Gate to an EnvADSR (20).
    private func makeState(withKeyboard: Bool = true) -> PatchState {
        var patch = G2Patch()
        var modules = [G2Module(id: 2, typeID: 20, area: .voice), G2Module(id: 3, typeID: 20, area: .voice)]
        var cables = [G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 0, color: .blue, area: .voice),
                      G2Cable(fromModule: 1, fromConnector: 1, toModule: 3, toConnector: 1, color: .yellow, area: .voice)]
        if withKeyboard {
            modules.insert(G2Module(id: 1, typeID: 1, area: .voice), at: 0)
        } else {
            cables = []
        }
        patch.voiceModules = modules
        patch.voiceCables = cables
        let state = PatchState()
        state.loadFromDevice(patches: [patch])
        return state
    }

    private func keyboardCables(_ state: PatchState) throws -> [G2Cable] {
        let patch = state.slots[0]
        let keyboard = try XCTUnwrap(patch.modules(in: .voice).first { PatchState.sequencerKeyboardTypeIDs.contains($0.typeID) })
        return patch.cables(in: .voice).filter { $0.fromModule == keyboard.id && $0.sourceIsOutput && $0.fromConnector <= 1 }
    }

    func testSequencerTakesTheKeyboardsPlaceAndOneUndoRemovesIt() throws {
        let state = makeState()
        let before = state.slots[0]
        let fed = try keyboardCables(state)
        XCTAssertEqual(fed.count, 2)

        guard case let .added(sequencerID) = state.addSequencer(slot: 0) else {
            return XCTFail("a patch with a fed keyboard must accept a sequencer")
        }
        let patch = state.slots[0]
        let sequencer = try XCTUnwrap(patch.modules(in: .voice).first { $0.id == sequencerID })
        XCTAssertEqual(sequencer.typeID, PatchState.noteSequencerTypeID)
        XCTAssertTrue(patch.modules(in: .voice).contains { $0.typeID == PatchState.clockGeneratorTypeID }, "a clock is there")

        // The keyboard no longer feeds Pitch / Gate; the sequencer does, to the same inputs.
        XCTAssertTrue(try keyboardCables(state).isEmpty)
        let fromSequencer = patch.cables(in: .voice).filter { $0.fromModule == sequencerID && $0.sourceIsOutput }
        for cable in fed {
            XCTAssertTrue(fromSequencer.contains { $0.toModule == cable.toModule && $0.toConnector == cable.toConnector },
                          "the consumer of the keyboard's output is fed by the sequencer now")
        }
        // The starter pattern plays: notes in row 1, every Trig on in row 2.
        let layout = try XCTUnwrap(SequencerLayout(typeID: PatchState.noteSequencerTypeID))
        XCTAssertEqual(layout.row(0, in: sequencer.parameters), PatchState.sequencerStarterNotes)
        XCTAssertEqual(layout.row(1, in: sequencer.parameters), Array(repeating: 1, count: SequencerLayout.steps))

        state.undoManager.undo()
        XCTAssertEqual(state.slots[0].modules(in: .voice).count, before.modules(in: .voice).count, "one ⌘Z takes it all back")
        XCTAssertEqual(try keyboardCables(state).count, fed.count)
    }

    func testPatchWithNothingToDriveIsLeftAlone() throws {
        var patch = G2Patch()
        patch.voiceModules = try [module(1, def("LfoA"))]
        let state = PatchState()
        state.loadFromDevice(patches: [patch])
        XCTAssertEqual(state.addSequencerObstacle(slot: 0), .noSoundSource)
        XCTAssertEqual(state.addSequencer(slot: 0), .noSoundSource)
        XCTAssertFalse(state.slots[0].modules(in: .voice).contains { $0.typeID == PatchState.noteSequencerTypeID })
    }

    /// Envelopes alone are enough since v3: the sequencer can play the rhythm.
    func testEnvelopesAloneCanTakeARhythm() {
        let state = makeState(withKeyboard: false)
        XCTAssertNil(state.addSequencerObstacle(slot: 0))
        XCTAssertEqual(state.addSequencerChoices(slot: 0).envelopes.count, 2)
    }

    // MARK: - Patches without Keyboard cables (the usual case)

    private func def(_ name: String) throws -> ModuleDef { try XCTUnwrap(ModuleDatabase.module(shortName: name)) }

    private func input(_ module: ModuleDef, _ name: String) throws -> Int {
        try XCTUnwrap(module.inputs.firstIndex { $0.name == name })
    }

    private func module(_ id: Int, _ def: ModuleDef) -> G2Module {
        var module = G2Module(id: id, typeID: def.id, area: .voice)
        module.parameters = Array(repeating: 1, count: def.paramNames.count)
        return module
    }

    /// OscB 1 with a free Pitch; OscB 2 whose Pitch comes from Mix2-1A 3 (free Chain); EnvADSR 4 with nothing on its Gate.
    private func makeOscillatorState() throws -> PatchState {
        let osc = try def("OscB"), mixer = try def("Mix2-1A"), env = try def("EnvADSR")
        var patch = G2Patch()
        patch.voiceModules = [module(1, osc), module(2, osc), module(3, mixer), module(4, env)]
        patch.voiceCables = try [G2Cable(fromModule: 3, fromConnector: 0, toModule: 2, toConnector: input(osc, "Pitch"),
                                         color: .blue, area: .voice)]
        let state = PatchState()
        state.loadFromDevice(patches: [patch])
        return state
    }

    func testOscillatorsAreDrivenDirectlyOrThroughAMixersChain() throws {
        let osc = try def("OscB"), mixer = try def("Mix2-1A"), env = try def("EnvADSR")
        let state = try makeOscillatorState()
        guard case let .added(sequencerID) = state.addSequencer(slot: 0) else { return XCTFail("oscillators can be driven") }
        let patch = state.slots[0]
        let fromSequencer = patch.cables(in: .voice).filter { $0.fromModule == sequencerID && $0.sourceIsOutput }
        let pitch = try input(osc, "Pitch"), chain = try input(mixer, "Chain"), gate = try input(env, "Gate")
        XCTAssertTrue(fromSequencer.contains { $0.toModule == 1 && $0.toConnector == pitch }, "free Pitch is fed directly")
        XCTAssertTrue(fromSequencer.contains { $0.toModule == 3 && $0.toConnector == chain }, "a taken Pitch goes through the mixer's Chain")
        XCTAssertFalse(fromSequencer.contains { $0.toModule == 2 }, "the taken Pitch itself is left alone")
        XCTAssertTrue(fromSequencer.contains { $0.toModule == 4 && $0.toConnector == gate }, "an envelope that followed the key gets the trigger")
        let kbt = try XCTUnwrap(osc.paramNames.firstIndex(of: "Kbt"))
        for id in [1, 2] {
            let module = try XCTUnwrap(patch.modules(in: .voice).first { $0.id == id })
            XCTAssertEqual(module.parameters[kbt], 0, "the oscillator no longer follows the keys")
        }
    }

    // MARK: - v3: play modes, clock, step (2026-11-26)

    /// Poly patch (4 voices): OscB 1 (free Pitch), FltNord 2 (free Pitch), EnvADSR 3 (free Gate), no keyboard.
    private func makePolyState() throws -> PatchState {
        let osc = try def("OscB"), filter = try def("FltNord"), env = try def("EnvADSR")
        var patch = G2Patch()
        var oscillator = module(1, osc)
        try oscillator.parameters[XCTUnwrap(osc.paramNames.firstIndex(of: "Kbt"))] = 1
        oscillator.parameterVariations = Array(repeating: oscillator.parameters, count: 9)
        patch.voiceModules = [oscillator, module(2, filter), module(3, env)]
        patch.description.voices = 4
        let state = PatchState()
        state.loadFromDevice(patches: [patch])
        // Each change is its own ⌘Z (the app's event loop does this; a test has none).
        state.undoManager.groupsByEvent = false
        return state
    }

    private func cables(_ state: PatchState, from module: Int, _ output: String, to target: Int? = nil) throws -> [G2Cable] {
        let patch = state.slots[0]
        let source = try XCTUnwrap(patch.modules(in: .voice).first { $0.id == module })
        let out = try XCTUnwrap(ModuleDatabase.module(id: source.typeID)?.outputs.firstIndex { $0.name == output })
        return patch.cables(in: .voice).filter {
            $0.fromModule == module && $0.fromConnector == out && $0.sourceIsOutput && (target == nil || $0.toModule == target)
        }
    }

    private func moduleID(_ state: PatchState, type: Int) -> Int? {
        state.slots[0].modules(in: .voice).first { $0.typeID == type }?.id
    }

    private func parameter(_ state: PatchState, _ id: Int, _ name: String) throws -> Int {
        let module = try XCTUnwrap(state.slots[0].modules(in: .voice).first { $0.id == id })
        let index = try XCTUnwrap(ModuleDatabase.module(id: module.typeID)?.paramNames.firstIndex(of: name))
        return module.parameters[index]
    }

    func testPolyPatchRecommendsHeldKeysAndLeavesFiltersUnticked() throws {
        let state = try makePolyState()
        let choices = state.addSequencerChoices(slot: 0)
        XCTAssertTrue(choices.isPoly)
        XCTAssertEqual(choices.recommendedMode, .byItself, "held-key modes are not offered yet (Nord, 2026-11-26)")
        XCTAssertEqual(choices.oscillators.map(\.id), [1])
        XCTAssertEqual(choices.filters.map(\.id), [2])
        XCTAssertEqual(choices.envelopes.map(\.id), [3])
        let options = choices.defaultOptions
        XCTAssertEqual(options.pitchTargets, [1], "filters are offered, not ticked")
        XCTAssertEqual(options.clock, .newFollowingTopBar, "no clock in the patch: a new one on the top bar's Run")
    }

    func testHeldKeysWiresKeyAndStepThroughGateAndShiftsThePatternBySixteen() throws {
        let state = try makePolyState()
        let before = state.slots[0].modules(in: .voice).count
        var options = state.addSequencerChoices(slot: 0).defaultOptions
        options.mode = .heldKeys
        options.wholeStepGate = true
        guard case let .added(seq) = state.addSequencer(slot: 0, options: options) else { return XCTFail("added") }
        XCTAssertEqual(state.sequencerPlayMode(slot: 0, area: .voice, sequencerID: seq), .heldKeys)
        let keyboard = try XCTUnwrap(moduleID(state, type: 1), "a keyboard is added for the key's gate")
        let gate = try XCTUnwrap(moduleID(state, type: PatchState.logicGateTypeID))
        let shift = try XCTUnwrap(moduleID(state, type: PatchState.levelAddTypeID))
        let clock = try XCTUnwrap(moduleID(state, type: PatchState.clockGeneratorTypeID))
        // Key AND step → the envelope; the key restarts the clock.
        XCTAssertEqual(try cables(state, from: keyboard, "Gate", to: gate).count, 1)
        XCTAssertEqual(try cables(state, from: seq, "Trig", to: gate).count, 1)
        XCTAssertEqual(try cables(state, from: gate, "Out1", to: 3).count, 1)
        XCTAssertEqual(try cables(state, from: keyboard, "Gate", to: clock).count, 1)
        // Pattern + 16 semitones on top of the key: Kbt stays on, the filter is left alone.
        XCTAssertEqual(try cables(state, from: seq, "Note", to: shift).count, 1)
        XCTAssertEqual(try cables(state, from: shift, "Out", to: 1).count, 1)
        XCTAssertTrue(try cables(state, from: shift, "Out", to: 2).isEmpty)
        XCTAssertEqual(try parameter(state, shift, "Level"), PatchState.heldKeysLevAddLevel)
        XCTAssertEqual(try parameter(state, shift, "BipUni"), 1)
        XCTAssertEqual(try parameter(state, 1, "Kbt"), 1)
        // Clock on the top bar, restart every bar (16 × 1/16 = 4 beats), whole-step gate, voices untouched.
        XCTAssertEqual(try parameter(state, clock, "Source"), 1)
        XCTAssertEqual(try parameter(state, clock, "BeatSync"), 2)
        XCTAssertEqual(try cables(state, from: clock, "Sync", to: seq).count, 1)
        XCTAssertEqual(try parameter(state, seq, "TG"), 1)
        XCTAssertEqual(state.voiceModeIndex(slot: 0), 5)

        state.undoManager.undo()
        XCTAssertEqual(state.slots[0].modules(in: .voice).count, before, "one ⌘Z takes it all back")
    }

    func testByItselfMakesThePatchMonoAndSwitchingBackGivesTheVoicesAndKbtBack() throws {
        let state = try makePolyState()
        var options = state.addSequencerChoices(slot: 0).defaultOptions
        options.mode = .byItself
        guard case let .added(seq) = state.addSequencer(slot: 0, options: options) else { return XCTFail("added") }
        XCTAssertEqual(state.sequencerPlayMode(slot: 0, area: .voice, sequencerID: seq), .byItself)
        XCTAssertEqual(state.voiceModeIndex(slot: 0), 1, "Mono: one copy of the pattern")
        XCTAssertEqual(try parameter(state, 1, "Kbt"), 0)
        XCTAssertEqual(try cables(state, from: seq, "Note", to: 1).count, 1)
        XCTAssertEqual(try cables(state, from: seq, "Trig", to: 3).count, 1)
        XCTAssertNil(moduleID(state, type: PatchState.logicGateTypeID))

        state.setSequencerPlayMode(.heldKeys, slot: 0, sequencerID: seq)
        XCTAssertEqual(state.sequencerPlayMode(slot: 0, area: .voice, sequencerID: seq), .heldKeys)
        XCTAssertEqual(state.voiceModeIndex(slot: 0), 5, "the voices come back")
        XCTAssertNotEqual(try parameter(state, 1, "Kbt"), 0, "key tracking comes back")
        let shift = try XCTUnwrap(moduleID(state, type: PatchState.levelAddTypeID))
        XCTAssertEqual(try cables(state, from: shift, "Out", to: 1).count, 1, "the same oscillator gets the pattern")

        state.setSequencerPlayMode(.rhythmOnKeys, slot: 0, sequencerID: seq)
        XCTAssertEqual(state.sequencerPlayMode(slot: 0, area: .voice, sequencerID: seq), .rhythmOnKeys)
        XCTAssertTrue(try cables(state, from: seq, "Note").isEmpty, "the keys give the pitch")
        XCTAssertNil(moduleID(state, type: PatchState.levelAddTypeID))
        let gate = try XCTUnwrap(moduleID(state, type: PatchState.logicGateTypeID))
        XCTAssertEqual(try cables(state, from: gate, "Out1", to: 3).count, 1)

        state.undoManager.undo()
        XCTAssertEqual(state.sequencerPlayMode(slot: 0, area: .voice, sequencerID: seq), .heldKeys, "one ⌘Z per change")
    }

    func testStepLengthGoesThroughAClockDividerAndBack() throws {
        let state = try makePolyState()
        var options = state.addSequencerChoices(slot: 0).defaultOptions
        options.mode = .heldKeys
        options.step = .eighth
        guard case let .added(seq) = state.addSequencer(slot: 0, options: options) else { return XCTFail("added") }
        let divider = try XCTUnwrap(moduleID(state, type: PatchState.clockDividerTypeID))
        let clock = try XCTUnwrap(moduleID(state, type: PatchState.clockGeneratorTypeID))
        XCTAssertEqual(try parameter(state, divider, "Divider"), 11, "1/8 = 12 pulses of 1/96")
        XCTAssertEqual(try cables(state, from: clock, "1/96", to: divider).count, 1)
        XCTAssertEqual(try cables(state, from: divider, "Out", to: seq).count, 1)
        XCTAssertEqual(state.sequencerClock(slot: 0, area: .voice, sequencerID: seq)?.step, .eighth)
        XCTAssertEqual(try parameter(state, clock, "BeatSync"), 3, "16 × 1/8 = 8 beats")

        state.setSequencerStep(.sixteenth, slot: 0, sequencerID: seq)
        XCTAssertNil(moduleID(state, type: PatchState.clockDividerTypeID), "the divider goes")
        XCTAssertEqual(state.sequencerClock(slot: 0, area: .voice, sequencerID: seq)?.step, .sixteenth)
        XCTAssertEqual(try parameter(state, clock, "BeatSync"), 2)

        state.setSequencerRestart(false, slot: 0, sequencerID: seq)
        XCTAssertEqual(state.sequencerClock(slot: 0, area: .voice, sequencerID: seq)?.restartsEveryBar, false)
        let keyboard = try XCTUnwrap(moduleID(state, type: 1))
        XCTAssertEqual(try cables(state, from: keyboard, "Gate", to: seq).count, 1, "held keys: the key restarts the pattern")
    }

    func testOscillatorWithTakenPitchAndNoMixerKeepsFollowingTheKeys() throws {
        let osc = try def("OscB"), lfo = try def("LfoA")
        var patch = G2Patch()
        patch.voiceModules = [module(1, osc), module(2, lfo)]
        patch.voiceCables = try [G2Cable(fromModule: 2, fromConnector: 0, toModule: 1, toConnector: input(osc, "Pitch"),
                                         color: .blue, area: .voice)]
        let state = PatchState()
        state.loadFromDevice(patches: [patch])
        XCTAssertEqual(state.addSequencerObstacle(slot: 0), .noSoundSource, "nothing the sequencer can reach")
    }
}
