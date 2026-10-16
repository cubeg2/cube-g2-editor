// OriginalEditorObservationTests.swift
//
// Behaviour measured in the original Nord Modular G2 editor on 2026-09-02 and
// pinned here, so the observations never have to be repeated.
//
// Every case below was performed by hand in the original editor: build the patch,
// swap the module, read where the cables and knobs ended up. The expectations are
// what the original did, not what this project happens to do - if an assertion
// ever fails, the editor stopped matching the original, and the fix belongs in the
// implementation rather than in the numbers here.
//
// The cases were chosen because they are the ones where replacement is least
// obvious: knob folding when a mono pair collapses into one stereo channel, and the
// cases where a cable does not come back to the socket it left from. They cover the
// mixer, logic, switch, delay, effect, random and input/output families, which
// between them hold every role whose entry order can change the outcome. Agreeing
// on all of them is evidence, not proof.
//
// Sockets are named as the panels label them. Note that on the Pulse and Delay
// panels the leftmost socket is the control input (`Time`, `TimeMod`), not `In`,
// which sits on the right - the source of one misreading during this session.

@testable import G2Core
import XCTest

final class OriginalEditorObservationTests: XCTestCase {
    // MARK: - Helpers

    private func typeID(_ shortName: String) throws -> Int {
        try XCTUnwrap(ModuleDatabase.module(shortName: shortName)?.id, "unknown module \(shortName)")
    }

    /// Names the sockets a plan moves, so a failure reads like the panel rather
    /// than like a pair of numbers.
    private func cableMoves(
        from source: String, to target: String,
        patched inputs: Set<Int>
    ) throws -> [String] {
        let sourceID = try typeID(source), targetID = try typeID(target)
        let sourceDef = try XCTUnwrap(ModuleDatabase.module(id: sourceID))
        let targetDef = try XCTUnwrap(ModuleDatabase.module(id: targetID))
        let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
            from: sourceID, to: targetID,
            connectedInputs: inputs, connectedOutputs: []
        ))
        return plan.inputMap.sorted { $0.key < $1.key }.map {
            "\(sourceDef.inputs[$0.key].name)>\(targetDef.inputs[$0.value].name)"
        }
    }

    private func socketIndex(_ shortName: String, _ socket: String) throws -> Int {
        let module = try XCTUnwrap(ModuleDatabase.module(shortName: shortName))
        return try XCTUnwrap(
            module.inputs.firstIndex { $0.name == socket },
            "\(shortName) has no socket \(socket)"
        )
    }

    // MARK: - Knobs

    /// Mixer 8-1 Fader with channels 2, 3, 6 and 7 switched on becomes a Mixer 4-1
    /// Stereo with channels 1 and 3 on. Each stereo channel takes the even channel
    /// of the mono pair it folds, so the higher source index wins.
    func testFoldedChannelSwitchesTakeTheHigherSourceChannel() throws {
        let faderID = try typeID("MixFader"), stereoID = try typeID("Mix4-1S")
        let fader = try XCTUnwrap(ModuleDatabase.module(id: faderID))

        var module = G2Module(id: 1, typeID: faderID, area: .voice)
        var values = Array(repeating: 0, count: fader.paramNames.count)
        for (offset, on) in [0, 1, 1, 0, 0, 1, 1, 0].enumerated() {
            try values[XCTUnwrap(fader.paramNames.firstIndex(of: "On\(offset + 1)"))] = on
        }
        module.parameters = values
        module.parameterVariations = Array(repeating: values, count: 9)

        var patch = G2Patch()
        patch.voiceModules = [module]
        XCTAssertTrue(patch.replaceModule(moduleID: 1, with: stereoID, in: .voice))

        let stereo = try XCTUnwrap(ModuleDatabase.module(id: stereoID))
        let result = try patch.voiceModules[0].parameters
        let switches = try (1 ... 4).map { channel -> Int in
            try result[XCTUnwrap(stereo.paramNames.firstIndex(of: "On\(channel)"))]
        }
        XCTAssertEqual(switches, [1, 0, 1, 0], "channels 1 and 3 should be on")
    }

    /// The Exp/dB setting does not travel: a Fader set to dB became a Stereo mixer
    /// showing Exp again.
    func testExpLinSettingIsNotCarriedOver() throws {
        let faderID = try typeID("MixFader"), stereoID = try typeID("Mix4-1S")
        let fader = try XCTUnwrap(ModuleDatabase.module(id: faderID))
        let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
            from: faderID, to: stereoID, connectedInputs: [], connectedOutputs: []
        ))
        let expLin = try XCTUnwrap(fader.paramNames.firstIndex(of: "ExpLin"))
        XCTAssertNil(plan.parameterMap[expLin])
    }

    // MARK: - Cables that move to a different socket

    /// A cable in Gate's upper-left socket reappears on the Inverter's right-hand
    /// input, and swapping back puts it in Gate's lower-left socket - one socket
    /// down from where it started.
    func testGateAndInverterExchangeIsNotSymmetric() throws {
        XCTAssertEqual(
            try cableMoves(from: "Gate", to: "Invert",
                           patched: [socketIndex("Gate", "In1_1")]),
            ["In1_1>In2"]
        )
        XCTAssertEqual(
            try cableMoves(from: "Invert", to: "Gate",
                           patched: [socketIndex("Invert", "In2")]),
            ["In2>In1_2"]
        )
    }

    /// The Inverter has two signal inputs and Pulse only one, so exactly one cable
    /// survives: the one in the left-hand input.
    func testOnlyTheLeftInverterCableSurvivesTheMoveToPulse() throws {
        XCTAssertEqual(
            try cableMoves(from: "Invert", to: "Pulse", patched: [0, 1]),
            ["In1>In"]
        )
    }

    /// A lone cable in the Inverter's right-hand input still reaches Pulse.
    func testALoneRightInverterCableReachesPulse() throws {
        XCTAssertEqual(
            try cableMoves(from: "Invert", to: "Pulse",
                           patched: [socketIndex("Invert", "In2")]),
            ["In2>In"]
        )
    }

    /// Coming back from Pulse, the cable lands on the Inverter's right-hand input.
    func testPulseSignalInputReturnsToTheRightInverterInput() throws {
        XCTAssertEqual(
            try cableMoves(from: "Pulse", to: "Invert",
                           patched: [socketIndex("Pulse", "In")]),
            ["In>In2"]
        )
    }

    // MARK: - Cables that are dropped

    /// Pulse's `Time` input is a timing control that neither the Inverter nor the
    /// Gate has, so a cable in it is dropped rather than moved somewhere plausible.
    func testPulseTimeCableIsDroppedBecauseNoLogicModuleHasThatInput() throws {
        let time = try socketIndex("Pulse", "Time")
        XCTAssertEqual(try cableMoves(from: "Pulse", to: "Invert", patched: [time]), [])
        XCTAssertEqual(try cableMoves(from: "Pulse", to: "Gate", patched: [time]), [])
    }

    // MARK: - Stereo pairing

    /// Three cables on a mono 8-channel mixer fill the first stereo channel's left
    /// and right sockets, then the second channel's left.
    func testMonoCablesFillStereoChannelsInPairs() throws {
        XCTAssertEqual(
            try cableMoves(from: "Mix8-1A", to: "Mix4-1S", patched: [0, 1, 2]),
            ["In1>In1L", "In2>In1R", "In3>In2L"]
        )
    }

    // MARK: - Switch outputs

    /// Switch 1-4 patched on all four outputs keeps the first two and drops the
    /// rest. Switch 1-2 numbers its sockets right to left, so `Out1` is the
    /// rightmost one and the surviving cables cross on the way over.
    func testSwitchOutputsKeepTheFirstTwoAndCrossOver() throws {
        let wide = try XCTUnwrap(ModuleDatabase.module(shortName: "Sw1-4"))
        let narrow = try XCTUnwrap(ModuleDatabase.module(shortName: "Sw1-2"))
        let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
            from: wide.id, to: narrow.id,
            connectedInputs: [], connectedOutputs: [0, 1, 2, 3]
        ))

        XCTAssertEqual(
            plan.outputMap.sorted { $0.key < $1.key }.map {
                "\(wide.outputs[$0.key].name)>\(narrow.outputs[$0.value].name)"
            },
            ["Out1>Out1", "Out2>Out2"],
            "only the first two taps survive"
        )
        XCTAssertGreaterThan(
            try narrow.outputs[XCTUnwrap(plan.outputMap[0])].horiz,
            try narrow.outputs[XCTUnwrap(plan.outputMap[1])].horiz,
            "the leftmost source output should land on the rightmost target socket"
        )
    }

    /// Swapping Switch 1-4 for Switch 1-2 and straight back does not put the cables
    /// where they started: the one that left output 1 comes back on output 2. Both
    /// halves are ordinary first-match steps; the shuffle is what they compose to.
    func testSwitchRoundTripSwapsTheTwoSurvivingCables() throws {
        let wide = try XCTUnwrap(ModuleDatabase.module(shortName: "Sw1-4"))
        let narrow = try XCTUnwrap(ModuleDatabase.module(shortName: "Sw1-2"))

        let out = try XCTUnwrap(ModuleReplacementDatabase.plan(
            from: wide.id, to: narrow.id,
            connectedInputs: [], connectedOutputs: [0, 1, 2, 3]
        ))
        let back = try XCTUnwrap(ModuleReplacementDatabase.plan(
            from: narrow.id, to: wide.id,
            connectedInputs: [], connectedOutputs: Set(out.outputMap.values)
        ))

        let landed = try XCTUnwrap(back.outputMap[XCTUnwrap(out.outputMap[0])])
        XCTAssertEqual(wide.outputs[landed].name, "Out2", "output 1 comes back on output 2")
    }

    // MARK: - Delay time slots

    /// DelayQuad's four Time inputs, four outputs (plus OutMain) and eight Time
    /// knobs collapse onto DelayDual's two of each. The model predicted a plain
    /// cut - Time1/Time2 and Out1/Out2 survive untouched, everything else is
    /// dropped - with no higher-index folding the way Mixer channels fold. The
    /// original editor confirmed it exactly.
    func testDelayQuadToDelayDualKeepsOnlyTheFirstTwoTimeSlots() throws {
        let quad = try XCTUnwrap(ModuleDatabase.module(shortName: "DelayQuad"))
        let dual = try XCTUnwrap(ModuleDatabase.module(shortName: "DelayDual"))
        let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
            from: quad.id, to: dual.id,
            connectedInputs: [1, 2, 3, 4], connectedOutputs: [0, 1, 2, 3, 4]
        ))

        XCTAssertEqual(
            plan.inputMap.sorted { $0.key < $1.key }.map {
                "\(quad.inputs[$0.key].name)>\(dual.inputs[$0.value].name)"
            },
            ["Time1>Time1", "Time2>Time2"],
            "Time3 and Time4 cables are dropped, not folded onto Time1/Time2"
        )
        XCTAssertEqual(
            plan.outputMap.sorted { $0.key < $1.key }.map {
                "\(quad.outputs[$0.key].name)>\(dual.outputs[$0.value].name)"
            },
            ["Out1>Out1", "Out2>Out2"],
            "OutMain, Out3 and Out4 cables are dropped"
        )
        XCTAssertEqual(
            plan.parameterMap.sorted { $0.key < $1.key }.map {
                "\(quad.paramNames[$0.key])>\(dual.paramNames[$0.value])"
            },
            ["Time1>Time1", "Time1Mod>Time1Mod", "Time2>Time2", "Time2Mod>Time2Mod"],
            "Time3/Time3Mod, Time4/Time4Mod and TimeClk values have no home on DelayDual"
        )
    }

    // MARK: - Effect output crossing

    /// Compress's panel labels its physically-left output socket "OutR" - reversed
    /// from the usual left-then-right convention every other stereo FX module uses
    /// (Reverb included). Swapping Compress for Reverb keeps each cable on its
    /// physical side rather than following the name: the cable in Compress's
    /// physically-left socket (named OutR) reappears in Reverb's physically-left
    /// socket (named OutL). The model predicted this before the measurement; the
    /// original editor confirmed it.
    func testCompressReversedOutputLabelsKeepPhysicalPositionOnReverb() throws {
        let compress = try XCTUnwrap(ModuleDatabase.module(shortName: "Compress"))
        let reverb = try XCTUnwrap(ModuleDatabase.module(shortName: "Reverb"))
        let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
            from: compress.id, to: reverb.id,
            connectedInputs: [0, 1], connectedOutputs: [0, 1]
        ))

        XCTAssertEqual(
            plan.outputMap.sorted { $0.key < $1.key }.map {
                "\(compress.outputs[$0.key].name)>\(reverb.outputs[$0.value].name)"
            },
            ["OutR>OutL", "OutL>OutR"],
            "the name appears to swap because Compress's physically-left socket is named OutR"
        )
        XCTAssertLessThan(
            try reverb.outputs[XCTUnwrap(plan.outputMap[0])].horiz,
            try reverb.outputs[XCTUnwrap(plan.outputMap[1])].horiz,
            "physical left-to-right order is preserved regardless of the name change"
        )
        XCTAssertEqual(
            plan.inputMap.sorted { $0.key < $1.key }.map {
                "\(compress.inputs[$0.key].name)>\(reverb.inputs[$0.value].name)"
            },
            ["InL>InL", "InR>InR"],
            "Compress's inputs are not reversed, so this side is not a discriminating case"
        )
    }

    // MARK: - Random seed slots

    /// RndPattern has two seed-like inputs, A and B, where every other module in
    /// the family has only one Seed. Swapping to RndClkB, the earlier one (A)
    /// keeps the socket and B's cable is dropped - first-in-order wins, not the
    /// higher-index rule Mixer channels fold by, because this is an ordinary
    /// single-socket claim rather than the Mixer's value-folding logic. The model
    /// predicted this before the measurement; the original editor confirmed it.
    func testRndPatternSeedAWinsOverSeedBOnRndClkB() throws {
        let pattern = try XCTUnwrap(ModuleDatabase.module(shortName: "RndPattern"))
        let clkB = try XCTUnwrap(ModuleDatabase.module(shortName: "RndClkB"))
        let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
            from: pattern.id, to: clkB.id,
            connectedInputs: [0, 1, 2, 3, 4], connectedOutputs: [0]
        ))

        XCTAssertEqual(
            plan.inputMap.sorted { $0.key < $1.key }.map {
                "\(pattern.inputs[$0.key].name)>\(clkB.inputs[$0.value].name)"
            },
            ["Clk>Clk", "Rst>Rst", "A>Seed", "StepProb>Step"],
            "A claims the only Seed socket; B's cable has nowhere left to go"
        )
    }

    // MARK: - Input/Output socket count

    /// 4-In has four outputs and 2-In only two. The cables in the first two
    /// sockets survive - plain positional truncation, the same rule DelayQuad
    /// follows when it loses its extra Time sockets, with no crossing since
    /// neither panel reverses its left-to-right labelling the way Compress does.
    /// The model predicted this before the measurement; the original editor
    /// confirmed it.
    func testFourInToTwoInKeepsOnlyTheFirstTwoOutputs() throws {
        let fourIn = try XCTUnwrap(ModuleDatabase.module(shortName: "4-In"))
        let twoIn = try XCTUnwrap(ModuleDatabase.module(shortName: "2-In"))
        let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
            from: fourIn.id, to: twoIn.id,
            connectedInputs: [], connectedOutputs: [0, 1, 2, 3]
        ))

        XCTAssertEqual(
            plan.outputMap.sorted { $0.key < $1.key }.map {
                "\(fourIn.outputs[$0.key].name)>\(twoIn.outputs[$0.value].name)"
            },
            ["Out1>OutL", "Out2>OutR"],
            "Out3 and Out4 cables are dropped, not folded onto OutL/OutR"
        )
    }

    /// 4-Out's four inputs collapse onto 2-Out's two the same way 4-In's outputs
    /// collapse onto 2-In's - plain positional truncation, no crossing. This is
    /// the mirror role (on inputs instead of outputs) of the previous case, and
    /// the last of the families with an order-sensitive role. The model predicted
    /// it before the measurement; the original editor confirmed it.
    func testFourOutToTwoOutKeepsOnlyTheFirstTwoInputs() throws {
        let fourOut = try XCTUnwrap(ModuleDatabase.module(shortName: "4-Out"))
        let twoOut = try XCTUnwrap(ModuleDatabase.module(shortName: "2-Out"))
        let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
            from: fourOut.id, to: twoOut.id,
            connectedInputs: [0, 1, 2, 3], connectedOutputs: []
        ))

        XCTAssertEqual(
            plan.inputMap.sorted { $0.key < $1.key }.map {
                "\(fourOut.inputs[$0.key].name)>\(twoOut.inputs[$0.value].name)"
            },
            ["In1>InL", "In2>InR"],
            "In3 and In4 cables are dropped, not folded onto InL/InR"
        )
    }
}
