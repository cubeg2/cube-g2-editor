// PatchState+Chance.swift
// "Add lane ▸ Chance" of the Sequence Editor: gives one trigger output of a step sequencer a
// probability per step, played by the G2 itself (no computer needed once the patch is on it).
//
// How it is wired (all of it ordinary modules and cables, so the patch opens in any editor):
//
//     sequencer Trig ──▶ RndTrig.Clk        RndTrig passes each pulse with a probability
//     SeqLev.Val     ──▶ RndTrig.Prob       set per step by the bars of a new SeqLev
//     RndTrig.Out    ──▶ everything the sequencer's Trig used to feed
//
// The new SeqLev gets the same Clk / Rst as the sequencer (its cables are copied) and the same
// Length and Loop, so both walk through the steps together. RndTrig has StepProb = 0 and
// StepProbMod = 100, so the SeqLev bars alone decide: full bar = always, empty = never.
// New bars start at full, which leaves the patch playing exactly as before.
// → [[Docs/roadmap]] "Rzędy (lanes)"

import Foundation
import G2Core

public extension PatchState {
    /// Module types used by a Chance lane.
    static let chanceLevelTypeID = 146 // SeqLev
    static let chanceTriggerTypeID = 205 // RndTrig

    /// Trigger outputs of a sequencer that a Chance lane can gate: a title for the menu and
    /// the output connector index. SeqEvent has two (its rows); the others have one.
    static func chanceOutputs(typeID: Int) -> [(title: String, output: Int)] {
        guard let layout = SequencerLayout(typeID: typeID), layout.loopIndex != nil,
              let def = ModuleDatabase.module(id: typeID) else { return [] }
        let names = layout.kind == .event ? [("Row 1", "Trig1"), ("Row 2", "Trig2")] : [("Trig", "Trig")]
        return names.compactMap { title, name in
            def.outputs.firstIndex { $0.name == name }.map { (title, $0) }
        }
    }

    /// The bar lanes of Chance pairs in an area: sequencers whose Val output feeds the Prob input of a
    /// RndTrig. The Sequence Editor shows them in their own colour.
    func chanceLaneIDs(slot: Int, area: PatchArea) -> Set<Int> {
        guard slots.indices.contains(slot),
              let levelDef = ModuleDatabase.module(id: Self.chanceLevelTypeID),
              let triggerDef = ModuleDatabase.module(id: Self.chanceTriggerTypeID),
              let val = levelDef.outputs.firstIndex(where: { $0.name == "Val" }),
              let prob = triggerDef.inputs.firstIndex(where: { $0.name == "Prob" }) else { return [] }
        let patch = slots[slot]
        let triggers = Set(patch.modules(in: area).filter { $0.typeID == Self.chanceTriggerTypeID }.map(\.id))
        let levels = Set(patch.modules(in: area).filter { $0.typeID == Self.chanceLevelTypeID }.map(\.id))
        return Set(G2SignalGraph(patch: patch, area: area).edges
            .filter { levels.contains($0.fromModule) && $0.fromOutput == val
                && triggers.contains($0.toModule) && $0.toInput == prob
            }
            .map(\.fromModule))
    }

    /// Whether the two modules of a Chance lane still fit the area: the estimate of the patch plus a
    /// SeqLev and a RndTrig must stay within 100 % of the cycles and of the critical memory. Over
    /// that the G2 stops the patch (the sequencer froze at 101 % — user's screenshot 2026-11-17).
    func chanceLaneFits(slot: Int, area: PatchArea) -> Bool {
        guard slots.indices.contains(slot) else { return false }
        let load = G2PatchLoad.estimate(area: area, patch: slots[slot])
            .adding(typeID: Self.chanceLevelTypeID)
            .adding(typeID: Self.chanceTriggerTypeID)
        return load.cyclesPercent <= 100 && load.memoryPercent <= 100
    }

    /// Adds the Chance lane of `trigOutput` of the sequencer `sequencerID` in the watched slot:
    /// two modules, their cables, and the sequencer's old Trig cables moved to RndTrig. One ⌘Z
    /// takes it all back. Returns the number of the new SeqLev (the lane), `nil` when nothing
    /// was done.
    @discardableResult
    func addChanceLane(slot: Int, area: PatchArea, sequencerID: Int, trigOutput: Int,
                       label: String = "Chance") -> Int?
    {
        guard slot == selectedSlot, slots.indices.contains(slot), chanceLaneFits(slot: slot, area: area),
              let sequencer = slots[slot].modules(in: area).first(where: { $0.id == sequencerID }),
              let layout = SequencerLayout(typeID: sequencer.typeID),
              let sequencerDef = ModuleDatabase.module(id: sequencer.typeID),
              sequencerDef.outputs.indices.contains(trigOutput),
              let levelDef = ModuleDatabase.module(id: Self.chanceLevelTypeID),
              let triggerDef = ModuleDatabase.module(id: Self.chanceTriggerTypeID),
              let seqClk = sequencerDef.inputs.firstIndex(where: { $0.name == "Clk" }),
              let seqRst = sequencerDef.inputs.firstIndex(where: { $0.name == "Rst" }),
              let levelClk = levelDef.inputs.firstIndex(where: { $0.name == "Clk" }),
              let levelRst = levelDef.inputs.firstIndex(where: { $0.name == "Rst" }),
              let levelVal = levelDef.outputs.firstIndex(where: { $0.name == "Val" }),
              let triggerClk = triggerDef.inputs.firstIndex(where: { $0.name == "Clk" }),
              let triggerProb = triggerDef.inputs.firstIndex(where: { $0.name == "Prob" }),
              let triggerOut = triggerDef.outputs.firstIndex(where: { $0.name == "Out" })
        else { return nil }

        let cables = slots[slot].cables(in: area)
        undoManager.beginUndoGrouping()
        defer {
            undoManager.setActionName("Add Chance Lane")
            undoManager.endUndoGrouping()
        }
        guard let levelID = addModule(typeID: Self.chanceLevelTypeID, area: area),
              let triggerID = addModule(typeID: Self.chanceTriggerTypeID, area: area) else { return nil }

        renameModule(moduleID: levelID, label: label, area: area, slot: slot)
        // Bars full (= always plays), same length and loop as the sequencer.
        var level: [Int: Int] = [:]
        for step in 0 ..< SequencerLayout.steps { level[step] = 127 }
        if let loop = layout.loopIndex, loop < sequencer.parameters.count { level[loop] = sequencer.parameters[loop] }
        if let length = layout.lengthIndex, length < sequencer.parameters.count {
            level[length] = sequencer.parameters[length]
        }
        writeEverywhere(slot: slot, area: area, moduleID: levelID, values: level)
        // StepProb 0 %, StepProbMod 100: the bars alone decide.
        writeEverywhere(slot: slot, area: area, moduleID: triggerID, values: [0: 0, 1: 127])

        // The new SeqLev listens to the same clock and reset as the sequencer.
        for cable in cables where cable.toModule == sequencerID && (cable.toConnector == seqClk || cable.toConnector == seqRst) {
            addCable(G2Cable(fromModule: cable.fromModule, fromConnector: cable.fromConnector,
                             toModule: levelID, toConnector: cable.toConnector == seqClk ? levelClk : levelRst,
                             color: cable.color, area: area, sourceIsOutput: cable.sourceIsOutput), slot: slot)
        }
        // Everything the sequencer's trigger fed now comes from RndTrig.
        let moved = cables.filter { $0.fromModule == sequencerID && $0.fromConnector == trigOutput && $0.sourceIsOutput }
        for cable in moved {
            removeCable(cable)
            var rerouted = cable
            rerouted.fromModule = triggerID
            rerouted.fromConnector = triggerOut
            addCable(rerouted, slot: slot)
        }
        addCable(G2Cable(fromModule: sequencerID, fromConnector: trigOutput, toModule: triggerID,
                         toConnector: triggerClk, color: moved.first?.color ?? .yellow, area: area), slot: slot)
        addCable(G2Cable(fromModule: levelID, fromConnector: levelVal, toModule: triggerID,
                         toConnector: triggerProb, color: .blue, area: area), slot: slot)
        return levelID
    }

    /// A value in all eight variations — a new lane must not be silent in the ones that are not
    /// playing. Goes to the G2 too, like any knob move.
    func writeEverywhere(slot: Int, area: PatchArea, moduleID: Int, values: [Int: Int]) {
        for (index, value) in values.sorted(by: { $0.key < $1.key }) {
            for variation in 0 ..< G2Patch.initVariation {
                slots[slot].setParameter(moduleID: moduleID, paramIndex: index, value: value,
                                         in: area, variation: variation)
                onLiveParameterChange?(slot, area, moduleID, index, value, variation)
            }
        }
    }
}
