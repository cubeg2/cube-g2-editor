// G2SlotLevel.swift
// How loud a slot is — the meters under the slot buttons A–D. The G2 sends the level
// meters (`0x3A`) of every slot that has something to report, each tagged with its slot;
// the level of a slot is what its output modules show.

import Foundation

public extension G2VisualStream {
    /// 4-Out and 2-Out.
    static let outputModuleTypes: Set<Int> = [3, 4]

    /// Segments of a meter, as on the module panels (`segmentLevel`).
    static let meterSegments = 12

    /// The level a slot sends out (0…`meterSegments`) according to one `0x3A` packet: the
    /// loudest meter of its output modules that are switched on. `nil` when the packet says
    /// nothing about any of them, so the previous reading stands.
    ///
    /// An output feeding the FX area is an internal send: it counts only when the outputs
    /// that leave the slot lie beyond the 40 entries the G2 reports.
    static func slotLevel(_ readings: G2VisualReadings, patch: G2Patch) -> Int? {
        let variation = patch.activeVariation
        if patch.variationSettings.indices.contains(variation),
           patch.variationSettings[variation].activeMuted == 0
        {
            return 0
        }
        let outputs = (patch.voiceModules + patch.fxModules).filter { outputModuleTypes.contains($0.typeID) }
        let leaving = outputs.filter { isOn($0) && !feedsFXArea($0) }
        // Nothing leaves the slot: no output module, all switched off, or only FX sends.
        guard !leaving.isEmpty else { return 0 }

        var left: [Int] = []
        var sends: [Int] = []
        for reading in readings.meters {
            guard let module = outputs.first(where: { $0.area == reading.area && $0.id == reading.moduleID }),
                  isOn(module)
            else { continue }
            let level = reading.values.map { segmentLevel(forValue: $0, segments: meterSegments) }.max() ?? 0
            if feedsFXArea(module) { sends.append(level) } else { left.append(level) }
        }
        return left.max() ?? sends.max()
    }

    /// Parameter 1 of both output modules is Active.
    private static func isOn(_ module: G2Module) -> Bool {
        !module.parameters.indices.contains(1) || module.parameters[1] != 0
    }

    /// Parameter 0 is Destination: 2-Out Out 1/2, Out 3/4, Fx 1/2, Fx 3/4, Bus…; 4-Out Out,
    /// Fx, Bus.
    private static func feedsFXArea(_ module: G2Module) -> Bool {
        guard let destination = module.parameters.first else { return false }
        return module.typeID == 4 ? destination == 2 || destination == 3 : destination == 1
    }
}
