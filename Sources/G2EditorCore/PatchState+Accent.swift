// PatchState+Accent.swift
// "Add lane ▸ Accent" of the Sequence Editor: one more SeqLev that walks through the steps together
// with a sequencer (same clock, reset, Length and Loop). Its bars say how strong each step is;
// what they control (a VCA level, a filter, velocity…) is up to the patch — the lane's Val output is
// left unconnected, so the patch sounds exactly as before until you cable it.
// The Euclid tab can fill the bars: every n-th hit loud, the rest soft.
// → [[Docs/roadmap]] "Rzędy (lanes)"

import Foundation
import G2Core

public extension PatchState {
    /// Name of the Accent lane of a sequencer: the lane belongs to the module of that name.
    static func accentLabel(sequencerName: String) -> String {
        "Accent \(sequencerName)"
    }

    /// The SeqLev that is the Accent lane called `label` in an area.
    func accentLaneID(slot: Int, area: PatchArea, label: String) -> Int? {
        guard slots.indices.contains(slot) else { return nil }
        return slots[slot].modules(in: area).first { $0.typeID == Self.chanceLevelTypeID && $0.label == label }?.id
    }

    /// Whether one more SeqLev still fits the area (cycles and memory within 100 %).
    func accentLaneFits(slot: Int, area: PatchArea) -> Bool {
        guard slots.indices.contains(slot) else { return false }
        let load = G2PatchLoad.estimate(area: area, patch: slots[slot]).adding(typeID: Self.chanceLevelTypeID)
        return load.cyclesPercent <= 100 && load.memoryPercent <= 100
    }

    /// Adds the Accent lane of sequencer `sequencerID`: a SeqLev with the sequencer's clock, reset,
    /// Length and Loop, bars at full. One ⌘Z takes it back. Returns the new module's number.
    @discardableResult
    func addAccentLane(slot: Int, area: PatchArea, sequencerID: Int, label: String) -> Int? {
        guard slot == selectedSlot, slots.indices.contains(slot), accentLaneFits(slot: slot, area: area),
              let sequencer = slots[slot].modules(in: area).first(where: { $0.id == sequencerID }),
              let layout = SequencerLayout(typeID: sequencer.typeID),
              let sequencerDef = ModuleDatabase.module(id: sequencer.typeID),
              let levelDef = ModuleDatabase.module(id: Self.chanceLevelTypeID),
              let seqClk = sequencerDef.inputs.firstIndex(where: { $0.name == "Clk" }),
              let seqRst = sequencerDef.inputs.firstIndex(where: { $0.name == "Rst" }),
              let levelClk = levelDef.inputs.firstIndex(where: { $0.name == "Clk" }),
              let levelRst = levelDef.inputs.firstIndex(where: { $0.name == "Rst" })
        else { return nil }

        let cables = slots[slot].cables(in: area)
        undoManager.beginUndoGrouping()
        defer {
            undoManager.setActionName("Add Accent Lane")
            undoManager.endUndoGrouping()
        }
        guard let levelID = addModule(typeID: Self.chanceLevelTypeID, area: area) else { return nil }
        renameModule(moduleID: levelID, label: label, area: area, slot: slot)
        var level: [Int: Int] = [:]
        for step in 0 ..< SequencerLayout.steps { level[step] = 127 }
        if let loop = layout.loopIndex, loop < sequencer.parameters.count { level[loop] = sequencer.parameters[loop] }
        if let length = layout.lengthIndex, length < sequencer.parameters.count {
            level[length] = sequencer.parameters[length]
        }
        writeEverywhere(slot: slot, area: area, moduleID: levelID, values: level)
        for cable in cables where cable.toModule == sequencerID && (cable.toConnector == seqClk || cable.toConnector == seqRst) {
            addCable(G2Cable(fromModule: cable.fromModule, fromConnector: cable.fromConnector,
                             toModule: levelID, toConnector: cable.toConnector == seqClk ? levelClk : levelRst,
                             color: cable.color, area: area, sourceIsOutput: cable.sourceIsOutput), slot: slot)
        }
        return levelID
    }
}
