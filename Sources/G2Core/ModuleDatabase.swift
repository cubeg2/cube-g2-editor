// ModuleDatabase.swift
//
// Originally generated from g2ools/nord/g2/modules.py (Matt Gerassimoff, GPL)
// by `Tools/generate_module_db.py`. The generator is still versioned in the
// repository, but this file is now maintained by hand: it carries corrections
// that a regeneration would drop (PM modules added to match the original editor,
// PitchTrack output order per Clavia panel P979 - see bug-history #56).
// Make changes here and verify with `.codex/scripts/audit-module-defs.py`, which
// compares this file against g2ools and knows the list of intentional deviations.

import Foundation

public enum ConnectorColor: String {
    case audio // red  — audio signal
    case control // blue — control signal
    case logic // yellow — gate/logic
    case pitchOrControl // blue_red
    case logicOrControl // yellow_orange
}

public struct ConnectorDef {
    public let name: String
    public let color: ConnectorColor
    public let horiz: Int
    public let vert: Int
}

public struct ModuleDef {
    public let id: Int
    public let shortName: String
    public let longName: String
    public let page: String
    public let height: Int // in grid units
    public let inputs: [ConnectorDef]
    public let outputs: [ConnectorDef]
    public let paramNames: [String]
    public let modeNames: [String]
}

public enum ModuleDatabase {
    // MARK: - Lookup

    public static func module(id: Int) -> ModuleDef? {
        byID[id]
    }

    public static func module(shortName: String) -> ModuleDef? {
        byShortName[shortName.lowercased()]
    }

    public static let all: [ModuleDef] = buildAll()

    private static let byID: [Int: ModuleDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static let byShortName: [String: ModuleDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.shortName.lowercased(), $0) })

    // MARK: - Module definitions

    private static func buildAll() -> [ModuleDef] {
        [
            ModuleDef(
                id: 1,
                shortName: "Keyboard",
                longName: "Keyboard",
                page: "In/Out",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "Pitch", color: .control, horiz: 2, vert: 1),
                    ConnectorDef(name: "Gate", color: .logic, horiz: 5, vert: 1),
                    ConnectorDef(name: "Lin", color: .control, horiz: 9, vert: 1),
                    ConnectorDef(name: "Release", color: .control, horiz: 12, vert: 1),
                    ConnectorDef(name: "Note", color: .control, horiz: 15, vert: 1),
                    ConnectorDef(name: "Exp", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 3,
                shortName: "4-Out",
                longName: "4 outputs",
                page: "In/Out",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .audio, horiz: 13, vert: 1),
                    ConnectorDef(name: "In2", color: .audio, horiz: 15, vert: 1),
                    ConnectorDef(name: "In3", color: .audio, horiz: 17, vert: 1),
                    ConnectorDef(name: "In4", color: .audio, horiz: 19, vert: 1),
                ],
                outputs: [],
                paramNames: ["Destination", "Active", "Pad"],
                modeNames: []
            ),
            ModuleDef(
                id: 4,
                shortName: "2-Out",
                longName: "2 outputs",
                page: "In/Out",
                height: 2,
                inputs: [
                    ConnectorDef(name: "InL", color: .audio, horiz: 17, vert: 1),
                    ConnectorDef(name: "InR", color: .audio, horiz: 19, vert: 1),
                ],
                outputs: [],
                paramNames: ["Destination", "Active", "Pad"],
                modeNames: []
            ),
            ModuleDef(
                id: 5,
                shortName: "Invert",
                longName: "Logic Inverter",
                page: "Logic",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .logicOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "In2", color: .logicOrControl, horiz: 15, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out1", color: .logicOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "Out2", color: .logicOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 7,
                shortName: "OscB",
                longName: "Osc B",
                page: "Osc",
                height: 5,
                inputs: [
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 3),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 4),
                    ConnectorDef(name: "Sync", color: .audio, horiz: 0, vert: 1),
                    ConnectorDef(name: "FmMod", color: .audio, horiz: 9, vert: 4),
                    ConnectorDef(name: "ShapeMod", color: .audio, horiz: 14, vert: 4),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 4),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "Kbt", "PitchMod", "FreqMode", "FmAmount", "Shape", "ShapeMod", "Waveform", "Active", "FmMode"],
                modeNames: []
            ),
            ModuleDef(
                id: 8,
                shortName: "OscShpB",
                longName: "Osc Shape B",
                page: "Osc",
                height: 4,
                inputs: [
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 2),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 3),
                    ConnectorDef(name: "Sync", color: .audio, horiz: 0, vert: 1),
                    ConnectorDef(name: "FmMod", color: .audio, horiz: 10, vert: 3),
                    ConnectorDef(name: "ShapeMod", color: .audio, horiz: 15, vert: 3),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 3),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "Kbt", "PitchMod", "FreqMode", "FmAmount", "Shape", "ShapeMod", "Active", "FmMode"],
                modeNames: ["Waveform"]
            ),
            ModuleDef(
                id: 9,
                shortName: "OscC",
                longName: "Osc C",
                page: "Osc",
                height: 3,
                inputs: [
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 2),
                    ConnectorDef(name: "Sync", color: .audio, horiz: 12, vert: 2),
                    ConnectorDef(name: "FmMod", color: .audio, horiz: 14, vert: 2),
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "Kbt", "FreqMode", "FmAmount", "Active", "FmMode", "PitchMod"],
                modeNames: ["Waveform"]
            ),
            ModuleDef(
                id: 12,
                shortName: "Reverb",
                longName: "reverb",
                page: "FX",
                height: 3,
                inputs: [
                    ConnectorDef(name: "InL", color: .audio, horiz: 17, vert: 0),
                    ConnectorDef(name: "InR", color: .audio, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "OutL", color: .audio, horiz: 17, vert: 2),
                    ConnectorDef(name: "OutR", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["Time", "Brightness", "DryWet", "Active"],
                modeNames: ["RoomType"]
            ),
            ModuleDef(
                id: 13,
                shortName: "OscString",
                longName: "Osc String",
                page: "Osc",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "Pitch", color: .control, horiz: 0, vert: 1),
                    ConnectorDef(name: "PitchVar", color: .control, horiz: 0, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "Kbt", "PitchMod", "FreqMode", "Decay", "Moisture", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 15,
                shortName: "Sw8-1",
                longName: "Switch 8-1",
                page: "Switch",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 6, vert: 0),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "In3", color: .pitchOrControl, horiz: 9, vert: 0),
                    ConnectorDef(name: "In4", color: .pitchOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "In5", color: .pitchOrControl, horiz: 13, vert: 0),
                    ConnectorDef(name: "In6", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "In7", color: .pitchOrControl, horiz: 15, vert: 0),
                    ConnectorDef(name: "In8", color: .pitchOrControl, horiz: 18, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 3),
                    ConnectorDef(name: "Control", color: .control, horiz: 9, vert: 3),
                ],
                paramNames: ["Sel"],
                modeNames: []
            ),
            ModuleDef(
                id: 17,
                shortName: "ValSw1-2",
                longName: "Value Switch 1-2",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Input", color: .pitchOrControl, horiz: 14, vert: 2),
                    ConnectorDef(name: "Ctrl", color: .pitchOrControl, horiz: 0, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "OutOn", color: .pitchOrControl, horiz: 16, vert: 2),
                    ConnectorDef(name: "OutOff", color: .pitchOrControl, horiz: 19, vert: 2),
                ],
                paramNames: ["Val"],
                modeNames: []
            ),
            ModuleDef(
                id: 18,
                shortName: "X-Fade",
                longName: "Cross Fader",
                page: "Mixer",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 14, vert: 2),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 16, vert: 2),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 6, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 2),
                ],
                paramNames: ["MixMod", "Mix", "LogLin"],
                modeNames: []
            ),
            ModuleDef(
                id: 19,
                shortName: "Mix4-1B",
                longName: "Mixer 4-1 B",
                page: "Mixer",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 8, vert: 1),
                    ConnectorDef(name: "In3", color: .pitchOrControl, horiz: 12, vert: 1),
                    ConnectorDef(name: "In4", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "Chain", color: .pitchOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Lev1", "Lev2", "Lev3", "Lev4", "ExpLin"],
                modeNames: []
            ),
            ModuleDef(
                id: 20,
                shortName: "EnvADSR",
                longName: "Envelop ADSR",
                page: "Env",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 19, vert: 0),
                    ConnectorDef(name: "Gate", color: .logic, horiz: 0, vert: 2),
                    ConnectorDef(name: "AM", color: .control, horiz: 0, vert: 3),
                ],
                outputs: [
                    ConnectorDef(name: "Env", color: .control, horiz: 18, vert: 3),
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 3),
                ],
                paramNames: ["Shape", "Attack", "Decay", "Sustain", "Release", "OutputType", "KB", "NR"],
                modeNames: []
            ),
            ModuleDef(
                id: 21,
                shortName: "Mux1-8",
                longName: "Multiplexer 1-8",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 6, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out1", color: .pitchOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "Out2", color: .pitchOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "Out3", color: .pitchOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "Out4", color: .pitchOrControl, horiz: 12, vert: 1),
                    ConnectorDef(name: "Out5", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "Out6", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Out7", color: .pitchOrControl, horiz: 18, vert: 1),
                    ConnectorDef(name: "Out8", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 22,
                shortName: "PartQuant",
                longName: "Partial Quantizer",
                page: "Note",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .control, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Range"],
                modeNames: []
            ),
            ModuleDef(
                id: 23,
                shortName: "ModADSR",
                longName: "Envelope Modulation ADSR",
                page: "Env",
                height: 5,
                inputs: [
                    ConnectorDef(name: "Gate", color: .logic, horiz: 0, vert: 4),
                    ConnectorDef(name: "AttackMod", color: .control, horiz: 2, vert: 4),
                    ConnectorDef(name: "DecayMod", color: .control, horiz: 5, vert: 4),
                    ConnectorDef(name: "SustainMod", color: .control, horiz: 8, vert: 4),
                    ConnectorDef(name: "ReleaseMod", color: .control, horiz: 11, vert: 4),
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 19, vert: 0),
                    ConnectorDef(name: "AM", color: .control, horiz: 0, vert: 4),
                ],
                outputs: [
                    ConnectorDef(name: "Env", color: .control, horiz: 19, vert: 4),
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 17, vert: 4),
                ],
                paramNames: ["Attack", "Decay", "Sustain", "Release", "AttackMod", "DecayMod", "SustainMod", "ReleaseMod", "OutputType", "KB"],
                modeNames: []
            ),
            ModuleDef(
                id: 24,
                shortName: "LfoC",
                longName: "LFO C",
                page: "LFO",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Rate", color: .control, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Rate", "PolyMono", "OutputType", "Range", "Active"],
                modeNames: ["Waveform"]
            ),
            ModuleDef(
                id: 25,
                shortName: "LfoShpA",
                longName: "LFO Shape A",
                page: "LFO",
                height: 5,
                inputs: [
                    ConnectorDef(name: "Rate", color: .control, horiz: 1, vert: 4),
                    ConnectorDef(name: "RateVar", color: .control, horiz: 2, vert: 4),
                    ConnectorDef(name: "Rst", color: .control, horiz: 0, vert: 1),
                    ConnectorDef(name: "ShapeMod", color: .control, horiz: 9, vert: 4),
                    ConnectorDef(name: "PhaseMod", color: .control, horiz: 12, vert: 4),
                    ConnectorDef(name: "Dir", color: .control, horiz: 1, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 4),
                    ConnectorDef(name: "Snc", color: .control, horiz: 0, vert: 4),
                ],
                paramNames: ["Rate", "Range", "Kbt", "RateMod", "Active", "Shape", "PhaseMod", "Phase", "ShapeMod", "PolyMono", "OutputType", "Waveform"],
                modeNames: []
            ),
            ModuleDef(
                id: 26,
                shortName: "LfoA",
                longName: "LFO A",
                page: "LFO",
                height: 3,
                inputs: [
                    ConnectorDef(name: "Rate", color: .control, horiz: 0, vert: 1),
                    ConnectorDef(name: "RateVar", color: .control, horiz: 0, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 2),
                ],
                paramNames: ["Rate", "PolyMono", "Kbt", "RateMod", "Waveform", "Active", "OutputType", "Range"],
                modeNames: []
            ),
            ModuleDef(
                id: 27,
                shortName: "OscMaster",
                longName: "Osc Master",
                page: "Osc",
                height: 3,
                inputs: [
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 2),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "Kbt", "FreqMode", "PitchMod"],
                modeNames: []
            ),
            ModuleDef(
                id: 28,
                shortName: "Saturate",
                longName: "Saturate",
                page: "Shaper",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 8, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Amount", "AmountMod", "Active", "Curve"],
                modeNames: []
            ),
            ModuleDef(
                id: 29,
                shortName: "MetNoise",
                longName: "Metallic Noise Oscillator",
                page: "Osc",
                height: 2,
                inputs: [
                    ConnectorDef(name: "FreqMod", color: .pitchOrControl, horiz: 4, vert: 1),
                    ConnectorDef(name: "ColorMod", color: .pitchOrControl, horiz: 11, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["Color", "Freq", "Active", "FreqMod", "ColorMod"],
                modeNames: []
            ),
            ModuleDef(
                id: 30,
                shortName: "Device",
                longName: "Device",
                page: "In/Out",
                height: 3,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "Wheel", color: .control, horiz: 0, vert: 2),
                    ConnectorDef(name: "AftTouch", color: .control, horiz: 3, vert: 2),
                    ConnectorDef(name: "ControlPedal", color: .control, horiz: 6, vert: 2),
                    ConnectorDef(name: "SustainPedal", color: .logic, horiz: 10, vert: 2),
                    ConnectorDef(name: "PitchStick", color: .control, horiz: 13, vert: 2),
                    ConnectorDef(name: "GlobalWheel1", color: .control, horiz: 16, vert: 2),
                    ConnectorDef(name: "GlobalWheel2", color: .control, horiz: 19, vert: 2),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 31,
                shortName: "Noise",
                longName: "Noise",
                page: "Osc",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["Color", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 32,
                shortName: "Eq2Band",
                longName: "Eq 2 Band",
                page: "Filter",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["LoSlope", "HiSlope", "Level", "Active", "LoFreq", "HiFreq"],
                modeNames: []
            ),
            ModuleDef(
                id: 33,
                shortName: "Eq3Band",
                longName: "Eq 3 Band",
                page: "Filter",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 3),
                ],
                paramNames: ["LoSlope", "MidGain", "MidFreq", "HiSlope", "Level", "Active", "LoFreq", "HiFreq"],
                modeNames: []
            ),
            ModuleDef(
                id: 34,
                shortName: "ShpExp",
                longName: "Shape Exp",
                page: "Shaper",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 8, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Amount", "AmountMod", "Active", "Curve"],
                modeNames: []
            ),
            ModuleDef(
                id: 36,
                shortName: "SwOnOffM",
                longName: "Switch On/Off Momentary",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 1),
                ],
                paramNames: ["On"],
                modeNames: []
            ),
            ModuleDef(
                id: 38,
                shortName: "Pulse",
                longName: "Pulse",
                page: "Logic",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .logicOrControl, horiz: 15, vert: 0),
                    ConnectorDef(name: "Time", color: .pitchOrControl, horiz: 4, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .logicOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Time", "TimeMod", "Range"],
                modeNames: ["PulseMode"] // g2ools: PulseMode (Pos/Neg edge trigger)
            ),
            ModuleDef(
                id: 40,
                shortName: "Mix8-1B",
                longName: "Mixer 8-1 B",
                page: "Mixer",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 3, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "In3", color: .pitchOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "In4", color: .pitchOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "In5", color: .pitchOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "In6", color: .pitchOrControl, horiz: 13, vert: 1),
                    ConnectorDef(name: "In7", color: .pitchOrControl, horiz: 15, vert: 1),
                    ConnectorDef(name: "In8", color: .pitchOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "Chain", color: .pitchOrControl, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 3),
                ],
                paramNames: ["Lev1", "Lev2", "Lev3", "Lev4", "Lev5", "Lev6", "Lev7", "Lev8", "ExpLin", "Pad"],
                modeNames: []
            ),
            ModuleDef(
                id: 41,
                shortName: "EnvH",
                longName: "Envelope Hold",
                page: "Env",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Trig", color: .logic, horiz: 0, vert: 1),
                    ConnectorDef(name: "AM", color: .control, horiz: 3, vert: 1),
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Env", color: .control, horiz: 15, vert: 1),
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Hold", "OutputType"],
                modeNames: []
            ),
            ModuleDef(
                id: 42,
                shortName: "Delay",
                longName: "Logic Delay",
                page: "Logic",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .logicOrControl, horiz: 15, vert: 0),
                    ConnectorDef(name: "TimeMod", color: .pitchOrControl, horiz: 4, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .logicOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Time", "TimeMod", "Range"],
                modeNames: ["LogicDelayMode"] // g2ools: LogicDelayMode (Pos/Neg/Cycle delay)
            ),
            ModuleDef(
                id: 43,
                shortName: "Constant",
                longName: "Constant Value",
                page: "Level",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Level", "BipUni"],
                modeNames: []
            ),
            ModuleDef(
                id: 44,
                shortName: "LevMult",
                longName: "Level Multiplier",
                page: "Level",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 14, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 45,
                shortName: "FltVoice",
                longName: "Filter Voice",
                page: "Filter",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "VowelMod", color: .control, horiz: 9, vert: 3),
                    ConnectorDef(name: "FreqMod", color: .audio, horiz: 0, vert: 3),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 3),
                ],
                paramNames: ["Vowel1", "Vowel2", "Vowel3", "Level", "Vowel", "VowelMod", "Freq", "FreqMod", "Res", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 46,
                shortName: "EnvAHD",
                longName: "Envelope AHD",
                page: "Env",
                height: 4,
                inputs: [
                    ConnectorDef(name: "Trig", color: .logic, horiz: 0, vert: 2),
                    ConnectorDef(name: "AM", color: .control, horiz: 0, vert: 3),
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Env", color: .control, horiz: 18, vert: 0),
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 0),
                ],
                paramNames: ["Shape", "Attack", "Hold", "NR", "Decay", "OutputType", "KB"],
                modeNames: []
            ),
            ModuleDef(
                id: 47,
                shortName: "Pan",
                longName: "Pan",
                page: "Mixer",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 6, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "OutL", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "OutR", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["PanMod", "Pan", "LogLin"],
                modeNames: []
            ),
            ModuleDef(
                id: 48,
                shortName: "MixStereo",
                longName: "Mixer Stereo",
                page: "Mixer",
                height: 5,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 0, vert: 2),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 2, vert: 2),
                    ConnectorDef(name: "In3", color: .pitchOrControl, horiz: 5, vert: 2),
                    ConnectorDef(name: "In4", color: .pitchOrControl, horiz: 8, vert: 2),
                    ConnectorDef(name: "In5", color: .pitchOrControl, horiz: 10, vert: 2),
                    ConnectorDef(name: "In6", color: .pitchOrControl, horiz: 13, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "OutL", color: .pitchOrControl, horiz: 17, vert: 4),
                    ConnectorDef(name: "OutR", color: .pitchOrControl, horiz: 19, vert: 4),
                ],
                paramNames: ["Lev1", "Lev2", "Lev3", "Lev4", "Lev5", "Lev6", "Pan1", "Pan2", "Pan3", "Pan4", "Pan5", "Pan6", "LevMaster"],
                modeNames: []
            ),
            ModuleDef(
                id: 49,
                shortName: "FltMulti",
                longName: "Filter Multi-mode",
                page: "Filter",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 2),
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 3),
                ],
                outputs: [
                    ConnectorDef(name: "LP", color: .audio, horiz: 19, vert: 1),
                    ConnectorDef(name: "BP", color: .audio, horiz: 19, vert: 2),
                    ConnectorDef(name: "HP", color: .audio, horiz: 19, vert: 3),
                ],
                paramNames: ["Freq", "PitchMod", "Kbt", "GC", "Res", "Slope", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 50,
                shortName: "ConstSwT",
                longName: "Constant Switch Toggling",
                page: "Level",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Lev", "On", "BipUni"],
                modeNames: []
            ),
            ModuleDef(
                id: 51,
                shortName: "FltNord",
                longName: "Filter Nord",
                page: "Filter",
                height: 5,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 4),
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 3),
                    ConnectorDef(name: "FMLin", color: .pitchOrControl, horiz: 3, vert: 4),
                    ConnectorDef(name: "Res", color: .pitchOrControl, horiz: 9, vert: 4),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 4),
                ],
                paramNames: ["Freq", "PitchMod", "Kbt", "GC", "Res", "Slope", "Active", "FM_Lin", "FilterType", "ResMod"],
                modeNames: []
            ),
            ModuleDef(
                id: 52,
                shortName: "EnvMulti",
                longName: "Envelope Multi",
                page: "Env",
                height: 6,
                inputs: [
                    ConnectorDef(name: "Gate", color: .logic, horiz: 0, vert: 2),
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 0),
                    ConnectorDef(name: "AM", color: .control, horiz: 2, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Env", color: .control, horiz: 19, vert: 1),
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 0),
                ],
                paramNames: ["Level1", "Level2", "Level3", "Level4", "Time1", "Time2", "Time3", "Time4", "NR", "SustainMode", "OutputType", "KB", "Shape"],
                modeNames: []
            ),
            ModuleDef(
                id: 53,
                shortName: "S&H",
                longName: "Sample & Hold",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 15, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .logicOrControl, horiz: 12, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 54,
                shortName: "FltStatic",
                longName: "Filter Static",
                page: "Filter",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["Freq", "Res", "FilterType", "Active", "GC"],
                modeNames: []
            ),
            ModuleDef(
                id: 55,
                shortName: "EnvD",
                longName: "Envelope Decay",
                page: "Env",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Trig", color: .logic, horiz: 0, vert: 1),
                    ConnectorDef(name: "AM", color: .control, horiz: 3, vert: 1),
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Env", color: .control, horiz: 15, vert: 1),
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Decay", "OutputType"],
                modeNames: []
            ),
            ModuleDef(
                id: 57,
                shortName: "Automate",
                longName: "MIDI Control Automate",
                page: "MIDI",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .logic, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .logic, horiz: 4, vert: 1),
                ],
                paramNames: ["Ctrl", "Val", "Ch", "Echo"],
                modeNames: []
            ),
            ModuleDef(
                id: 58,
                shortName: "DrumSynth",
                longName: "Drum Synthesizer",
                page: "Osc",
                height: 8,
                inputs: [
                    ConnectorDef(name: "Trig", color: .logic, horiz: 0, vert: 2),
                    ConnectorDef(name: "Vel", color: .control, horiz: 0, vert: 7),
                    ConnectorDef(name: "Pitch", color: .control, horiz: 0, vert: 4),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 8),
                ],
                paramNames: ["Masterfreq", "SlaveRatio", "MasterDecay", "SlaveDecay", "MasterLevel", "SlaveLevel", "NoiseFltFreq", "NoiseFltRes", "NoiseFltSweep", "NoiseFltDecay", "NoiseFltMode", "BendAmount", "BendDecay", "Click", "Noise", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 59,
                shortName: "CompLev",
                longName: "Compare to Level",
                page: "Level",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 9, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .logicOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["C"],
                modeNames: []
            ),
            ModuleDef(
                id: 60,
                shortName: "Mux8-1X",
                longName: "Multiplexer 8-1 with variable X-Fade",
                page: "Switch",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "In3", color: .pitchOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "In4", color: .pitchOrControl, horiz: 10, vert: 1),
                    ConnectorDef(name: "In5", color: .pitchOrControl, horiz: 12, vert: 1),
                    ConnectorDef(name: "In6", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "In7", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "In8", color: .pitchOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["XFade"],
                modeNames: []
            ),
            ModuleDef(
                id: 61,
                shortName: "Clip",
                longName: "Clip",
                page: "Shaper",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 5, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["ClipLevMod", "ClipLev", "Shape", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 62,
                shortName: "Overdrive",
                longName: "Overdrive",
                page: "Shaper",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 8, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["AmountMod", "Amount", "Active", "Type", "Shape"],
                modeNames: []
            ),
            ModuleDef(
                id: 63,
                shortName: "Scratch",
                longName: "Scratch",
                page: "FX",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "Mod", color: .control, horiz: 0, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["Ratio", "RatioMod", "Delay", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 64,
                shortName: "Gate",
                longName: "Gate",
                page: "Logic",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1_1", color: .logicOrControl, horiz: 6, vert: 0),
                    ConnectorDef(name: "In1_2", color: .logicOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "In2_1", color: .logicOrControl, horiz: 13, vert: 0),
                    ConnectorDef(name: "In2_2", color: .logicOrControl, horiz: 12, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out1", color: .logicOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "Out2", color: .logicOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: ["GateMode1", "GateMode2"]
            ),
            ModuleDef(
                id: 66,
                shortName: "Mix2-1B",
                longName: "Scratch",
                page: "Mixer",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 12, vert: 1),
                    ConnectorDef(name: "Chain", color: .pitchOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Inv1", "Lev1", "Inv2", "Lev2", "ExpLin"],
                modeNames: []
            ),
            ModuleDef(
                id: 68,
                shortName: "ClkGen",
                longName: "Clock Generator",
                page: "LFO",
                height: 4,
                inputs: [
                    ConnectorDef(name: "Rst", color: .logic, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "1/96", color: .logic, horiz: 19, vert: 1),
                    ConnectorDef(name: "1/16", color: .logic, horiz: 19, vert: 2),
                    ConnectorDef(name: "ClkActive", color: .logic, horiz: 19, vert: 0),
                    ConnectorDef(name: "Sync", color: .logic, horiz: 19, vert: 3),
                ],
                paramNames: ["Rate", "Active", "Source", "BeatSync", "Swing"],
                modeNames: []
            ),
            ModuleDef(
                id: 69,
                shortName: "ClkDiv",
                longName: "Clock Divider",
                page: "Logic",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 8, vert: 1),
                    ConnectorDef(name: "Rst", color: .logicOrControl, horiz: 5, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .logicOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Divider"],
                modeNames: ["DivMode"]
            ),
            ModuleDef(
                id: 71,
                shortName: "EnvFollow",
                longName: "Envelope Follower",
                page: "Level",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Attack", "Release"],
                modeNames: []
            ),
            ModuleDef(
                id: 72,
                shortName: "NoteScaler",
                longName: "Note Scaler",
                page: "Note",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .control, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Range"],
                modeNames: []
            ),
            ModuleDef(
                id: 74,
                shortName: "WaveWrap",
                longName: "Wave Wrapper",
                page: "Shaper",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 8, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["AmountMod", "Amount", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 75,
                shortName: "NoteQuant",
                longName: "Note Quantizer",
                page: "Note",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .control, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Range", "Notes"],
                modeNames: []
            ),
            ModuleDef(
                id: 76,
                shortName: "SwOnOffT",
                longName: "Switch On/Off Toggle",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 1),
                ],
                paramNames: ["On"],
                modeNames: []
            ),
            ModuleDef(
                id: 78,
                shortName: "Sw1-8",
                longName: "Switch 1-8",
                page: "Switch",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 3, vert: 3),
                ],
                outputs: [
                    ConnectorDef(name: "Out1", color: .pitchOrControl, horiz: 6, vert: 2),
                    ConnectorDef(name: "Out2", color: .pitchOrControl, horiz: 8, vert: 3),
                    ConnectorDef(name: "Out3", color: .pitchOrControl, horiz: 10, vert: 2),
                    ConnectorDef(name: "Out4", color: .pitchOrControl, horiz: 12, vert: 3),
                    ConnectorDef(name: "Out5", color: .pitchOrControl, horiz: 13, vert: 2),
                    ConnectorDef(name: "Out6", color: .pitchOrControl, horiz: 15, vert: 3),
                    ConnectorDef(name: "Out7", color: .pitchOrControl, horiz: 17, vert: 2),
                    ConnectorDef(name: "Out8", color: .pitchOrControl, horiz: 19, vert: 3),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 3),
                ],
                paramNames: ["Sel"],
                modeNames: []
            ),
            ModuleDef(
                id: 79,
                shortName: "Sw4-1",
                longName: "Switch 4-1",
                page: "Switch",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 6, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "In3", color: .pitchOrControl, horiz: 13, vert: 1),
                    ConnectorDef(name: "In4", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 2),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 2),
                ],
                paramNames: ["Sel"],
                modeNames: []
            ),
            ModuleDef(
                id: 81,
                shortName: "LevAmp",
                longName: "Level Amplifier",
                page: "Level",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Gain", "Type"],
                modeNames: []
            ),
            ModuleDef(
                id: 82,
                shortName: "Rect",
                longName: "Rectifier",
                page: "Shaper",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Mode", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 83,
                shortName: "ShpStatic",
                longName: "Shape Static",
                page: "Shaper",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Mode", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 84,
                shortName: "EnvADR",
                longName: "Envelope ADR",
                page: "Env",
                height: 3,
                inputs: [
                    ConnectorDef(name: "Gate", color: .logic, horiz: 0, vert: 2),
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 19, vert: 0),
                    ConnectorDef(name: "AM", color: .control, horiz: 3, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Env", color: .control, horiz: 17, vert: 2),
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 2),
                    ConnectorDef(name: "End", color: .logic, horiz: 16, vert: 2),
                ],
                paramNames: ["Shape", "Attack", "NR", "Release", "TG", "OutputType", "KB", "DcyRel"],
                modeNames: []
            ),
            ModuleDef(
                id: 85,
                shortName: "WindSw",
                longName: "Window Switch",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .pitchOrControl, horiz: 14, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                    ConnectorDef(name: "Gate", color: .logicOrControl, horiz: 0, vert: 1),
                ],
                paramNames: ["ValFrom", "ValTo"],
                modeNames: []
            ),
            ModuleDef(
                id: 86,
                shortName: "8Counter",
                longName: "8 Counter",
                page: "Logic",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "Rst", color: .logicOrControl, horiz: 3, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out1", color: .logicOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "Out2", color: .logicOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "Out3", color: .logicOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "Out4", color: .logicOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "Out5", color: .logicOrControl, horiz: 13, vert: 1),
                    ConnectorDef(name: "Out6", color: .logicOrControl, horiz: 15, vert: 1),
                    ConnectorDef(name: "Out7", color: .logicOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "Out8", color: .logicOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 87,
                shortName: "FltLP",
                longName: "Filter Lowpass",
                page: "Filter",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 16, vert: 1),
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 4, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["Freq", "FreqMod", "Kbt", "Active"],
                modeNames: ["SlopeMode"]
            ),
            ModuleDef(
                id: 88,
                shortName: "Sw1-4",
                longName: "Switch 1-4",
                page: "Switch",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 3, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out1", color: .pitchOrControl, horiz: 6, vert: 2),
                    ConnectorDef(name: "Out2", color: .pitchOrControl, horiz: 10, vert: 2),
                    ConnectorDef(name: "Out3", color: .pitchOrControl, horiz: 13, vert: 2),
                    ConnectorDef(name: "Out4", color: .pitchOrControl, horiz: 17, vert: 2),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 2),
                ],
                paramNames: ["Sel"],
                modeNames: []
            ),
            ModuleDef(
                id: 89,
                shortName: "Flanger",
                longName: "Flanger",
                page: "FX",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["Rate", "Range", "FeedBack", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 90,
                shortName: "Sw1-2",
                longName: "Switch 1-2",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 14, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out2", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Out1", color: .pitchOrControl, horiz: 19, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 1),
                ],
                paramNames: ["Sel"],
                modeNames: []
            ),
            ModuleDef(
                id: 91,
                shortName: "FlipFlop",
                longName: "Flip Flop",
                page: "Logic",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 8, vert: 1),
                    ConnectorDef(name: "In", color: .logicOrControl, horiz: 11, vert: 0),
                    ConnectorDef(name: "Rst", color: .logicOrControl, horiz: 5, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "NotQ", color: .logicOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "Q", color: .logicOrControl, horiz: 19, vert: 0),
                ],
                paramNames: [],
                modeNames: ["OperationMode"]
            ),
            ModuleDef(
                id: 92,
                shortName: "FltClassic",
                longName: "Filter Classic",
                page: "Filter",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 3),
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 3),
                ],
                paramNames: ["Freq", "PitchMod", "Kbt", "Res", "Slope", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 94,
                shortName: "StChorus",
                longName: "Stereo Chorus",
                page: "FX",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 18, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "OutL", color: .audio, horiz: 17, vert: 2),
                    ConnectorDef(name: "OutR", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["Detune", "Amount", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 96,
                shortName: "OscD",
                longName: "Osc D",
                page: "Osc",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "Kbt", "FreqMode", "Active"],
                modeNames: ["Waveform"]
            ),
            ModuleDef(
                id: 97,
                shortName: "OscA",
                longName: "Osc A",
                page: "Osc",
                height: 3,
                inputs: [
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "Kbt", "PitchMod", "Waveform", "Active", "FreqMode"],
                modeNames: []
            ),
            ModuleDef(
                id: 98,
                shortName: "FreqShift",
                longName: "Frequency Shifter",
                page: "FX",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 18, vert: 0),
                    ConnectorDef(name: "Shift", color: .control, horiz: 1, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Dn", color: .audio, horiz: 17, vert: 1),
                    ConnectorDef(name: "Up", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["FreqShift", "ShiftMod", "Range", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 100,
                shortName: "Sw2-1",
                longName: "Switch 2-1",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 14, vert: 0),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 16, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 1),
                ],
                paramNames: ["Sel"],
                modeNames: []
            ),
            ModuleDef(
                id: 102,
                shortName: "FltPhase",
                longName: "Filter Phase",
                page: "Filter",
                height: 5,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 4),
                    ConnectorDef(name: "Spr", color: .control, horiz: 6, vert: 4),
                    ConnectorDef(name: "FB", color: .control, horiz: 9, vert: 4),
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 3),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 4),
                ],
                paramNames: ["PitchMod", "Freq", "SpreadMod", "FB", "NotchCount", "Spread", "Active", "Level", "FBMod", "Type", "Kbt"],
                modeNames: []
            ),
            ModuleDef(
                id: 103,
                shortName: "EqPeak",
                longName: "Eq Peak",
                page: "Filter",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 3),
                ],
                paramNames: ["Freq", "Gain", "Bandwidth", "Active", "Level"],
                modeNames: []
            ),
            ModuleDef(
                id: 105,
                shortName: "ValSw2-1",
                longName: "Value Switch 2-1",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .pitchOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Val"],
                modeNames: []
            ),
            ModuleDef(
                id: 106,
                shortName: "OscNoise",
                longName: "Oscillator Noise",
                page: "Osc",
                height: 3,
                inputs: [
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 2),
                    ConnectorDef(name: "Width", color: .pitchOrControl, horiz: 12, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "Kbt", "PitchMod", "FreqMode", "Width", "WidthMod", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 108,
                shortName: "Vocoder",
                longName: "Vocoder",
                page: "Filter",
                height: 8,
                inputs: [
                    ConnectorDef(name: "Ctrl", color: .audio, horiz: 0, vert: 2),
                    ConnectorDef(name: "In", color: .audio, horiz: 16, vert: 7),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 7),
                ],
                paramNames: ["Band1", "Band2", "Band3", "Band4", "Band5", "Band6", "Band7", "Band8", "Band9", "Band10", "Band11", "Band12", "Band13", "Band14", "Band15", "Band16", "Emphasis", "Monitor"],
                modeNames: []
            ),
            ModuleDef(
                id: 112,
                shortName: "LevAdd",
                longName: "Level Add",
                page: "Level",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Level", "BipUni"],
                modeNames: []
            ),
            ModuleDef(
                id: 113,
                shortName: "Fade1-2",
                longName: "Fade 1-2",
                page: "Mixer",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 6, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out1", color: .pitchOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "Out2", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Mix", "MixMod"],
                modeNames: []
            ),
            ModuleDef(
                id: 114,
                shortName: "Fade2-1",
                longName: "Fade 2-1",
                page: "Mixer",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 6, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Mix", "MixMod"],
                modeNames: []
            ),
            ModuleDef(
                id: 115,
                shortName: "LevScaler",
                longName: "Level Scaler",
                page: "Note",
                height: 3,
                inputs: [
                    ConnectorDef(name: "Note", color: .control, horiz: 0, vert: 2),
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Level", color: .control, horiz: 16, vert: 2),
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 2),
                ],
                paramNames: ["L", "BP", "R", "Kbt"],
                modeNames: []
            ),
            ModuleDef(
                id: 116,
                shortName: "Mix8-1A",
                longName: "Mix 8-1 A",
                page: "Mixer",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "In3", color: .pitchOrControl, horiz: 8, vert: 1),
                    ConnectorDef(name: "In4", color: .pitchOrControl, horiz: 10, vert: 1),
                    ConnectorDef(name: "In5", color: .pitchOrControl, horiz: 12, vert: 1),
                    ConnectorDef(name: "In6", color: .pitchOrControl, horiz: 13, vert: 1),
                    ConnectorDef(name: "In7", color: .pitchOrControl, horiz: 15, vert: 1),
                    ConnectorDef(name: "In8", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Pad"],
                modeNames: []
            ),
            ModuleDef(
                id: 117,
                shortName: "LevMod",
                longName: "Level Modulator",
                page: "Level",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 2),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 16, vert: 0),
                    ConnectorDef(name: "ModDepth", color: .pitchOrControl, horiz: 6, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 2),
                ],
                paramNames: ["ModDepth", "ModType"],
                modeNames: []
            ),
            ModuleDef(
                id: 118,
                shortName: "Digitizer",
                longName: "Digitizer",
                page: "FX",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 19, vert: 0),
                    ConnectorDef(name: "Rate", color: .pitchOrControl, horiz: 19, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 1, vert: 2),
                ],
                paramNames: ["Bits", "Rate", "RateMod", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 119,
                shortName: "EnvADDSR",
                longName: "Envelope ADDSR",
                page: "Env",
                height: 5,
                inputs: [
                    ConnectorDef(name: "Gate", color: .logic, horiz: 0, vert: 2),
                    ConnectorDef(name: "AM", color: .control, horiz: 0, vert: 3),
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Env", color: .control, horiz: 17, vert: 3),
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 3),
                ],
                paramNames: ["KB", "Shape", "Attack", "Decay1", "Level1", "Decay2", "Level2", "Release", "SustainMode", "OutputType", "NR"],
                modeNames: []
            ),
            ModuleDef(
                id: 121,
                shortName: "SeqNote",
                longName: "Sequencer Note",
                page: "Seq",
                height: 9,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 2),
                    ConnectorDef(name: "Rst", color: .logicOrControl, horiz: 0, vert: 4),
                    ConnectorDef(name: "Loop", color: .logicOrControl, horiz: 0, vert: 6),
                    ConnectorDef(name: "Park", color: .logicOrControl, horiz: 16, vert: 0),
                    ConnectorDef(name: "Note", color: .pitchOrControl, horiz: 0, vert: 7),
                    ConnectorDef(name: "Trig", color: .logicOrControl, horiz: 0, vert: 8),
                    ConnectorDef(name: "RecVal", color: .pitchOrControl, horiz: 7, vert: 0),
                    ConnectorDef(name: "RecEnable", color: .logicOrControl, horiz: 8, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Link", color: .logicOrControl, horiz: 19, vert: 1),
                    ConnectorDef(name: "Note", color: .pitchOrControl, horiz: 19, vert: 7),
                    ConnectorDef(name: "Trig", color: .logicOrControl, horiz: 19, vert: 8),
                ],
                paramNames: ["Seq1Step1", "Seq1Step2", "Seq1Step3", "Seq1Step4", "Seq1Step5", "Seq1Step6", "Seq1Step7", "Seq1Step8", "Seq1Step9", "Seq1Step10", "Seq1Step11", "Seq1Step12", "Seq1Step13", "Seq1Step14", "Seq1Step15", "Seq1Step16", "Seq2Step1", "Seq2Step2", "Seq2Step3", "Seq2Step4", "Seq2Step5", "Seq2Step6", "Seq2Step7", "Seq2Step8", "Seq2Step9", "Seq2Step10", "Seq2Step11", "Seq2Step12", "Seq2Step13", "Seq2Step14", "Seq2Step15", "Seq2Step16", "Loop", "Length", "TG", "Clr_Or_Rnd", "Rnd_Or_Clr"],
                modeNames: []
            ),
            ModuleDef(
                id: 123,
                shortName: "Mix4-1C",
                longName: "Mixer 4-1 C",
                page: "Mixer",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 3, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "In3", color: .pitchOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "In4", color: .pitchOrControl, horiz: 15, vert: 1),
                    ConnectorDef(name: "Chain", color: .pitchOrControl, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 3),
                ],
                paramNames: ["Lev1", "Lev2", "Lev3", "Lev4", "On1", "On2", "On3", "On4", "Pad", "ExpLin"],
                modeNames: []
            ),
            ModuleDef(
                id: 124,
                shortName: "Mux8-1",
                longName: "Multiplexer 8-1",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 4, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "In3", color: .pitchOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "In4", color: .pitchOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "In5", color: .pitchOrControl, horiz: 12, vert: 1),
                    ConnectorDef(name: "In6", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "In7", color: .pitchOrControl, horiz: 15, vert: 1),
                    ConnectorDef(name: "In8", color: .pitchOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 125,
                shortName: "WahWah",
                longName: "Wah-Wah",
                page: "Filter",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 16, vert: 1),
                    ConnectorDef(name: "Sweep", color: .control, horiz: 7, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["SweepMod", "Sweep", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 126,
                shortName: "Name",
                longName: "Name Bar",
                page: "In/Out",
                height: 1,
                inputs: [],
                outputs: [],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 127,
                shortName: "Fx-In",
                longName: "Fx Input",
                page: "In/Out",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "OutL", color: .audio, horiz: 16, vert: 1),
                    ConnectorDef(name: "OutR", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["Source", "Active", "Pad"],
                modeNames: []
            ),
            ModuleDef(
                id: 128,
                shortName: "MinMax",
                longName: "Min/Max Compare",
                page: "Level",
                height: 2,
                inputs: [
                    ConnectorDef(name: "A", color: .pitchOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "B", color: .pitchOrControl, horiz: 11, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Min", color: .pitchOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "Max", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 130,
                shortName: "BinCounter",
                longName: "Binary Counter",
                page: "Logic",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "Rst", color: .logicOrControl, horiz: 2, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out001", color: .logicOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "Out002", color: .logicOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "Out004", color: .logicOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "Out008", color: .logicOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "Out016", color: .logicOrControl, horiz: 13, vert: 1),
                    ConnectorDef(name: "Out032", color: .logicOrControl, horiz: 15, vert: 1),
                    ConnectorDef(name: "Out064", color: .logicOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "Out128", color: .logicOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 131,
                shortName: "ADConv",
                longName: "A/D Converter",
                page: "Logic",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "D0", color: .logicOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "D1", color: .logicOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "D2", color: .logicOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "D3", color: .logicOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "D4", color: .logicOrControl, horiz: 13, vert: 1),
                    ConnectorDef(name: "D5", color: .logicOrControl, horiz: 15, vert: 1),
                    ConnectorDef(name: "D6", color: .logicOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "D7", color: .logicOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 132,
                shortName: "DAConv",
                longName: "D/A Converter",
                page: "Logic",
                height: 2,
                inputs: [
                    ConnectorDef(name: "D0", color: .logicOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "D1", color: .logicOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "D2", color: .logicOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "D3", color: .logicOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "D4", color: .logicOrControl, horiz: 12, vert: 1),
                    ConnectorDef(name: "D5", color: .logicOrControl, horiz: 13, vert: 1),
                    ConnectorDef(name: "D6", color: .logicOrControl, horiz: 15, vert: 1),
                    ConnectorDef(name: "D7", color: .logicOrControl, horiz: 17, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 134,
                shortName: "FltHP",
                longName: "Filter Highpass",
                page: "Filter",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 16, vert: 1),
                    ConnectorDef(name: "Pitch", color: .control, horiz: 4, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["Freq", "FreqMod", "Kbt", "Active"],
                modeNames: ["SlopeMode"]
            ),
            ModuleDef(
                id: 139,
                shortName: "T&H",
                longName: "Track & Hold",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 15, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .logicOrControl, horiz: 12, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 140,
                shortName: "Mix4-1S",
                longName: "Mixer 4-1 Stereo",
                page: "Mixer",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In1L", color: .pitchOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "In1R", color: .pitchOrControl, horiz: 1, vert: 1),
                    ConnectorDef(name: "In2L", color: .pitchOrControl, horiz: 4, vert: 1),
                    ConnectorDef(name: "In2R", color: .pitchOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "In3L", color: .pitchOrControl, horiz: 8, vert: 1),
                    ConnectorDef(name: "In3R", color: .pitchOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "In4L", color: .pitchOrControl, horiz: 13, vert: 1),
                    ConnectorDef(name: "In4R", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "ChainL", color: .pitchOrControl, horiz: 17, vert: 0),
                    ConnectorDef(name: "ChainR", color: .pitchOrControl, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "OutL", color: .pitchOrControl, horiz: 17, vert: 3),
                    ConnectorDef(name: "OutR", color: .pitchOrControl, horiz: 19, vert: 3),
                ],
                paramNames: ["Lev1", "Lev2", "Lev3", "Lev4", "On1", "On2", "On3", "On4", "ExpLin"],
                modeNames: []
            ),
            ModuleDef(
                id: 141,
                shortName: "CtrlSend",
                longName: "MIDI Control Send",
                page: "MIDI",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Send", color: .logic, horiz: 1, vert: 1),
                    ConnectorDef(name: "Value", color: .control, horiz: 11, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Send", color: .logic, horiz: 4, vert: 1),
                ],
                paramNames: ["Ctrl", "Val", "Ch"],
                modeNames: []
            ),
            ModuleDef(
                id: 142,
                shortName: "PCSend",
                longName: "MIDI Program Change Send",
                page: "MIDI",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Send", color: .logic, horiz: 1, vert: 1),
                    ConnectorDef(name: "Program", color: .control, horiz: 11, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Send", color: .logic, horiz: 4, vert: 1),
                ],
                paramNames: ["Program", "Ch"],
                modeNames: []
            ),
            ModuleDef(
                id: 143,
                shortName: "NoteSend",
                longName: "MIDI Note Send",
                page: "MIDI",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Gate", color: .logic, horiz: 0, vert: 1),
                    ConnectorDef(name: "Vel", color: .control, horiz: 4, vert: 1),
                    ConnectorDef(name: "Note", color: .control, horiz: 10, vert: 1),
                ],
                outputs: [],
                paramNames: ["Vel", "Note", "Ch"],
                modeNames: []
            ),
            ModuleDef(
                id: 144,
                shortName: "SeqEvent",
                longName: "Seq Event",
                page: "Seq",
                height: 5,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "Rst", color: .logic, horiz: 0, vert: 2),
                    ConnectorDef(name: "Loop", color: .logic, horiz: 0, vert: 4),
                    ConnectorDef(name: "Park", color: .logic, horiz: 16, vert: 0),
                    ConnectorDef(name: "Trig1", color: .logic, horiz: 1, vert: 3),
                    ConnectorDef(name: "Trig2", color: .logic, horiz: 1, vert: 4),
                ],
                outputs: [
                    ConnectorDef(name: "Link", color: .logic, horiz: 19, vert: 1),
                    ConnectorDef(name: "Trig1", color: .logicOrControl, horiz: 19, vert: 3),
                    ConnectorDef(name: "Trig2", color: .logicOrControl, horiz: 19, vert: 4),
                ],
                paramNames: ["Seq1Step1", "Seq1Step2", "Seq1Step3", "Seq1Step4", "Seq1Step5", "Seq1Step6", "Seq1Step7", "Seq1Step8", "Seq1Step9", "Seq1Step10", "Seq1Step11", "Seq1Step12", "Seq1Step13", "Seq1Step14", "Seq1Step15", "Seq1Step16", "Seq2Step1", "Seq2Step2", "Seq2Step3", "Seq2Step4", "Seq2Step5", "Seq2Step6", "Seq2Step7", "Seq2Step8", "Seq2Step9", "Seq2Step10", "Seq2Step11", "Seq2Step12", "Seq2Step13", "Seq2Step14", "Seq2Step15", "Seq2Step16", "Loop", "Length", "TG1", "TG2"],
                modeNames: []
            ),
            ModuleDef(
                id: 145,
                shortName: "SeqVal",
                longName: "Sequencer Values",
                page: "Seq",
                height: 8,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "Rst", color: .logic, horiz: 0, vert: 3),
                    ConnectorDef(name: "Loop", color: .logic, horiz: 0, vert: 4),
                    ConnectorDef(name: "Park", color: .logic, horiz: 16, vert: 0),
                    ConnectorDef(name: "Val", color: .pitchOrControl, horiz: 0, vert: 5),
                    ConnectorDef(name: "Trig", color: .logic, horiz: 0, vert: 7),
                ],
                outputs: [
                    ConnectorDef(name: "Link", color: .logic, horiz: 19, vert: 1),
                    ConnectorDef(name: "Val", color: .pitchOrControl, horiz: 19, vert: 5),
                    ConnectorDef(name: "Trig", color: .logicOrControl, horiz: 19, vert: 7),
                ],
                paramNames: ["Seq1Step1", "Seq1Step2", "Seq1Step3", "Seq1Step4", "Seq1Step5", "Seq1Step6", "Seq1Step7", "Seq1Step8", "Seq1Step9", "Seq1Step10", "Seq1Step11", "Seq1Step12", "Seq1Step13", "Seq1Step14", "Seq1Step15", "Seq1Step16", "Seq2Step1", "Seq2Step2", "Seq2Step3", "Seq2Step4", "Seq2Step5", "Seq2Step6", "Seq2Step7", "Seq2Step8", "Seq2Step9", "Seq2Step10", "Seq2Step11", "Seq2Step12", "Seq2Step13", "Seq2Step14", "Seq2Step15", "Seq2Step16", "Loop", "Length", "BipUni", "TG", "Clr_Or_Rnd", "Rnd_Or_Clr"],
                modeNames: []
            ),
            ModuleDef(
                id: 146,
                shortName: "SeqLev",
                longName: "Sequencer Level",
                page: "Seq",
                height: 8,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "Rst", color: .logicOrControl, horiz: 0, vert: 3),
                    ConnectorDef(name: "Loop", color: .logicOrControl, horiz: 0, vert: 4),
                    ConnectorDef(name: "Park", color: .logicOrControl, horiz: 16, vert: 0),
                    ConnectorDef(name: "Val", color: .pitchOrControl, horiz: 0, vert: 6),
                    ConnectorDef(name: "Trig", color: .logicOrControl, horiz: 0, vert: 7),
                ],
                outputs: [
                    ConnectorDef(name: "Link", color: .logicOrControl, horiz: 19, vert: 1),
                    ConnectorDef(name: "Val", color: .pitchOrControl, horiz: 19, vert: 6),
                    ConnectorDef(name: "Trig", color: .logicOrControl, horiz: 19, vert: 7),
                ],
                paramNames: ["Seq1Step1", "Seq1Step2", "Seq1Step3", "Seq1Step4", "Seq1Step5", "Seq1Step6", "Seq1Step7", "Seq1Step8", "Seq1Step9", "Seq1Step10", "Seq1Step11", "Seq1Step12", "Seq1Step13", "Seq1Step14", "Seq1Step15", "Seq1Step16", "Seq2Step1", "Seq2Step2", "Seq2Step3", "Seq2Step4", "Seq2Step5", "Seq2Step6", "Seq2Step7", "Seq2Step8", "Seq2Step9", "Seq2Step10", "Seq2Step11", "Seq2Step12", "Seq2Step13", "Seq2Step14", "Seq2Step15", "Seq2Step16", "Loop", "Length", "BipUni", "TG", "Clr_Or_Rnd", "Rnd_Or_Clr"],
                modeNames: []
            ),
            ModuleDef(
                id: 147,
                shortName: "CtrlRcv",
                longName: "MIDI Control Receive",
                page: "MIDI",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "Rcv", color: .logic, horiz: 16, vert: 1),
                    ConnectorDef(name: "Val", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Ctrl", "Ch"],
                modeNames: []
            ),
            ModuleDef(
                id: 148,
                shortName: "NoteRcv",
                longName: "MIDI Note Receive",
                page: "MIDI",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "Gate", color: .logic, horiz: 14, vert: 1),
                    ConnectorDef(name: "Vel", color: .control, horiz: 16, vert: 1),
                    ConnectorDef(name: "RelVel", color: .control, horiz: 18, vert: 1),
                ],
                paramNames: ["Note", "Ch"],
                modeNames: []
            ),
            ModuleDef(
                id: 149,
                shortName: "NoteZone",
                longName: "MIDI Note Zone",
                page: "MIDI",
                height: 3,
                inputs: [],
                outputs: [],
                paramNames: ["RcvCh", "RcvMin", "RcvMax", "SendTrans", "SendCh", "ThruMode"],
                modeNames: []
            ),
            ModuleDef(
                id: 150,
                // Clavia: Name:"Compress", Tooltip:"Compressor". Krótka nazwa MUSI być
                // zgodna z panelem, bo po niej szukamy pliku Gen1 (`uiDef(forName:)`) —
                // z „Compressor" moduł nie znajdował swojego panelu i rysował się awaryjnie.
                shortName: "Compress",
                longName: "Compressor",
                page: "FX",
                height: 5,
                inputs: [
                    ConnectorDef(name: "InL", color: .audio, horiz: 18, vert: 1),
                    ConnectorDef(name: "InR", color: .audio, horiz: 19, vert: 1),
                    ConnectorDef(name: "SideChain", color: .audio, horiz: 5, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "OutR", color: .audio, horiz: 18, vert: 4),
                    ConnectorDef(name: "OutL", color: .audio, horiz: 19, vert: 4),
                ],
                paramNames: ["Threshold", "Ratio", "Attack", "Release", "RefLevel", "SideChain", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 152,
                shortName: "KeyQuant",
                longName: "Key Quantizer",
                page: "Note",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .control, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Range", "Capture", "E", "F", "F#", "G", "G#", "A", "A#", "B", "C", "C#", "D", "D#"],
                modeNames: []
            ),
            ModuleDef(
                id: 154,
                shortName: "SeqCtr",
                longName: "Sequencer Controlled",
                page: "Seq",
                height: 8,
                inputs: [
                    ConnectorDef(name: "Ctrl", color: .pitchOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "Val", color: .pitchOrControl, horiz: 0, vert: 5),
                    ConnectorDef(name: "Trig", color: .logicOrControl, horiz: 0, vert: 7),
                ],
                outputs: [
                    ConnectorDef(name: "Val", color: .pitchOrControl, horiz: 19, vert: 5),
                    ConnectorDef(name: "Trig", color: .logicOrControl, horiz: 19, vert: 7),
                ],
                paramNames: ["Seq1Step1", "Seq1Step2", "Seq1Step3", "Seq1Step4", "Seq1Step5", "Seq1Step6", "Seq1Step7", "Seq1Step8", "Seq1Step9", "Seq1Step10", "Seq1Step11", "Seq1Step12", "Seq1Step13", "Seq1Step14", "Seq1Step15", "Seq1Step16", "Seq2Step1", "Seq2Step2", "Seq2Step3", "Seq2Step4", "Seq2Step5", "Seq2Step6", "Seq2Step7", "Seq2Step8", "Seq2Step9", "Seq2Step10", "Seq2Step11", "Seq2Step12", "Seq2Step13", "Seq2Step14", "Seq2Step15", "Seq2Step16", "TG", "BipUni", "XFade", "Clr_Or_Rnd", "Rnd_Or_Clr"],
                modeNames: []
            ),
            ModuleDef(
                id: 156,
                shortName: "NoteDet",
                longName: "Note Detector",
                page: "In/Out",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "Gate", color: .logic, horiz: 13, vert: 1),
                    ConnectorDef(name: "Vel", color: .control, horiz: 16, vert: 1),
                    ConnectorDef(name: "RelVel", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Note"],
                modeNames: []
            ),
            ModuleDef(
                id: 157,
                shortName: "LevConv",
                longName: "Level Converter",
                page: "Level",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["OutputType", "InputType"],
                modeNames: []
            ),
            ModuleDef(
                id: 158,
                shortName: "Glide",
                longName: "Glide",
                page: "Note",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "On", color: .logicOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Time", "Glide", "Shape"],
                modeNames: []
            ),
            ModuleDef(
                id: 159,
                shortName: "CompSig",
                longName: "Compare to Signal",
                page: "Level",
                height: 2,
                inputs: [
                    ConnectorDef(name: "A", color: .pitchOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "B", color: .pitchOrControl, horiz: 11, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .logicOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 160,
                shortName: "ZeroCnt",
                longName: "Zero Crossing Counter",
                page: "Note",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 161,
                shortName: "MixFader",
                longName: "Mixer 8-1 Fader",
                page: "Mixer",
                height: 9,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 1, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 2, vert: 1),
                    ConnectorDef(name: "In3", color: .pitchOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "In4", color: .pitchOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "In5", color: .pitchOrControl, horiz: 10, vert: 1),
                    ConnectorDef(name: "In6", color: .pitchOrControl, horiz: 12, vert: 1),
                    ConnectorDef(name: "In7", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "In8", color: .pitchOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "Chain", color: .pitchOrControl, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 8),
                ],
                paramNames: ["Lev1", "Lev2", "Lev3", "Lev4", "Lev5", "Lev6", "Lev7", "Lev8", "On1", "On2", "On3", "On4", "On5", "On6", "On7", "On8", "ExpLin", "Pad"],
                modeNames: []
            ),
            ModuleDef(
                id: 162,
                shortName: "FltComb",
                longName: "Filter Comb",
                page: "Filter",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 2),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 3),
                    ConnectorDef(name: "FB", color: .control, horiz: 9, vert: 3),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["Freq", "PitchMod", "Kbt", "FB", "FBMod", "Type", "Lev", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 163,
                shortName: "OscShpA",
                longName: "Osc Shape A",
                page: "Osc",
                height: 5,
                inputs: [
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 3),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 4),
                    ConnectorDef(name: "Sync", color: .audio, horiz: 0, vert: 1),
                    ConnectorDef(name: "FmMod", color: .audio, horiz: 8, vert: 3),
                    ConnectorDef(name: "ShapeMod", color: .audio, horiz: 14, vert: 3),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 4),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "Kbt", "PitchMod", "FreqMode", "FmAmount", "FmMode", "Shape", "ShapeMod", "Waveform", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 164,
                shortName: "OscDual",
                longName: "Osc Dual",
                page: "Osc",
                height: 5,
                inputs: [
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 3),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 4),
                    ConnectorDef(name: "Sync", color: .audio, horiz: 0, vert: 1),
                    ConnectorDef(name: "PW", color: .audio, horiz: 9, vert: 1),
                    ConnectorDef(name: "Phase", color: .audio, horiz: 9, vert: 4),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 4),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "Kbt", "PitchMod", "FreqMode", "SqrLevel", "PWMod", "SawLevel", "SawPhase", "SubOctLevel", "Active", "SqrPW", "PhaseMod", "Soft"],
                modeNames: []
            ),
            ModuleDef(
                id: 165,
                shortName: "DXRouter",
                longName: "DX Style Router",
                page: "Osc",
                height: 6,
                inputs: [
                    ConnectorDef(name: "In1", color: .audio, horiz: 0, vert: 5),
                    ConnectorDef(name: "In2", color: .audio, horiz: 2, vert: 5),
                    ConnectorDef(name: "In3", color: .audio, horiz: 5, vert: 5),
                    ConnectorDef(name: "In4", color: .audio, horiz: 9, vert: 5),
                    ConnectorDef(name: "In5", color: .audio, horiz: 12, vert: 5),
                    ConnectorDef(name: "In6", color: .audio, horiz: 15, vert: 5),
                ],
                outputs: [
                    ConnectorDef(name: "Out1", color: .audio, horiz: 1, vert: 5),
                    ConnectorDef(name: "Out2", color: .audio, horiz: 4, vert: 5),
                    ConnectorDef(name: "Out3", color: .audio, horiz: 7, vert: 5),
                    ConnectorDef(name: "Out4", color: .audio, horiz: 10, vert: 5),
                    ConnectorDef(name: "Out5", color: .audio, horiz: 13, vert: 5),
                    ConnectorDef(name: "Out6", color: .audio, horiz: 16, vert: 5),
                    ConnectorDef(name: "Main", color: .audio, horiz: 19, vert: 5),
                ],
                paramNames: ["Algorithm", "Feedback"],
                modeNames: []
            ),
            ModuleDef(
                id: 167,
                shortName: "PShift",
                longName: "Pitch Shifter",
                page: "FX",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "Pitch", color: .control, horiz: 1, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["ShiftSemi", "ShiftFine", "ShiftMod", "Delay", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 169,
                shortName: "ModAHD",
                longName: "Envelope Modulation AHD",
                page: "Env",
                height: 5,
                inputs: [
                    ConnectorDef(name: "Trig", color: .logic, horiz: 0, vert: 2),
                    ConnectorDef(name: "AttackMod", color: .control, horiz: 4, vert: 4),
                    ConnectorDef(name: "HoldMod", color: .control, horiz: 8, vert: 4),
                    ConnectorDef(name: "DecayMod", color: .control, horiz: 12, vert: 4),
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 19, vert: 0),
                    ConnectorDef(name: "AM", color: .control, horiz: 0, vert: 4),
                ],
                outputs: [
                    ConnectorDef(name: "Env", color: .control, horiz: 18, vert: 4),
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 4),
                ],
                paramNames: ["Attack", "Hold", "Decay", "AttackMod", "HoldMod", "DecayMod", "OutputType", "KB"],
                modeNames: []
            ),
            ModuleDef(
                id: 170,
                shortName: "2-In",
                longName: "2 inputs",
                page: "In/Out",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "OutL", color: .audio, horiz: 17, vert: 1),
                    ConnectorDef(name: "OutR", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["Source", "Active", "Pad"],
                modeNames: []
            ),
            ModuleDef(
                id: 171,
                shortName: "4-In",
                longName: "4 inputs",
                page: "In/Out",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "Out1", color: .audio, horiz: 12, vert: 1),
                    ConnectorDef(name: "Out2", color: .audio, horiz: 14, vert: 1),
                    ConnectorDef(name: "Out3", color: .audio, horiz: 17, vert: 1),
                    ConnectorDef(name: "Out4", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["Source", "Active", "Pad"],
                modeNames: []
            ),
            ModuleDef(
                id: 172,
                shortName: "DlySingleA",
                longName: "Delay Static",
                page: "Delay",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["Time"],
                modeNames: ["DelayRange3"] // g2ools: DelayRange_3 (7 opcji: 5ms…2.7s)
            ),
            ModuleDef(
                id: 173,
                shortName: "DlySingleB",
                longName: "Delay Single",
                page: "Delay",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 16, vert: 1),
                    ConnectorDef(name: "Time", color: .audio, horiz: 7, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["Time", "TimeMod"],
                modeNames: ["DelayRange3"] // g2ools: DelayRange_3
            ),
            ModuleDef(
                id: 174,
                shortName: "DelayDual",
                longName: "Delay Dual",
                page: "Delay",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "Time1", color: .audio, horiz: 7, vert: 2),
                    ConnectorDef(name: "Time2", color: .audio, horiz: 13, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out1", color: .audio, horiz: 10, vert: 2),
                    ConnectorDef(name: "Out2", color: .audio, horiz: 17, vert: 2),
                ],
                paramNames: ["Time1", "Time1Mod", "Time2", "Time2Mod"],
                modeNames: ["DelayRange3"] // g2ools: DelayRange_3
            ),
            ModuleDef(
                id: 175,
                shortName: "DelayQuad",
                longName: "Delay Quad",
                page: "Delay",
                height: 5,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "Time1", color: .audio, horiz: 3, vert: 4),
                    ConnectorDef(name: "Time2", color: .audio, horiz: 7, vert: 4),
                    ConnectorDef(name: "Time3", color: .audio, horiz: 11, vert: 4),
                    ConnectorDef(name: "Time4", color: .audio, horiz: 15, vert: 4),
                ],
                outputs: [
                    ConnectorDef(name: "OutMain", color: .audio, horiz: 19, vert: 4),
                    ConnectorDef(name: "Out1", color: .audio, horiz: 5, vert: 2),
                    ConnectorDef(name: "Out2", color: .audio, horiz: 9, vert: 2),
                    ConnectorDef(name: "Out3", color: .audio, horiz: 13, vert: 2),
                    ConnectorDef(name: "Out4", color: .audio, horiz: 17, vert: 2),
                ],
                paramNames: ["Time1", "Time1Mod", "Time2", "Time2Mod", "Time3", "Time3Mod", "Time4", "Time4Mod", "TimeClk"],
                modeNames: ["DelayRange3"] // g2ools: DelayRange_3
            ),
            ModuleDef(
                id: 176,
                shortName: "DelayA",
                longName: "Delay A",
                page: "Delay",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["Time", "FB", "Filter", "DryWet", "Active", "TimeClk"],
                modeNames: ["DelayRange"]
            ),
            ModuleDef(
                id: 177,
                shortName: "DelayB",
                longName: "Delay B",
                page: "Delay",
                height: 4,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                    ConnectorDef(name: "FBMod", color: .pitchOrControl, horiz: 9, vert: 3),
                    ConnectorDef(name: "DryWetMod", color: .pitchOrControl, horiz: 15, vert: 3),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 3),
                ],
                paramNames: ["Time", "FB", "LP", "DryWet", "TimeClk", "FBMod", "DryWetMod", "Active", "HP"],
                modeNames: ["DelayRange"]
            ),
            ModuleDef(
                id: 178,
                shortName: "DlyClock",
                longName: "Delay Clocked",
                page: "Delay",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Delay"],
                modeNames: []
            ),
            ModuleDef(
                id: 179,
                shortName: "DlyShiftReg",
                longName: "Shift Register",
                page: "Delay",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out1", color: .pitchOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "Out2", color: .pitchOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "Out3", color: .pitchOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "Out4", color: .pitchOrControl, horiz: 12, vert: 1),
                    ConnectorDef(name: "Out5", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "Out6", color: .pitchOrControl, horiz: 15, vert: 1),
                    ConnectorDef(name: "Out7", color: .pitchOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "Out8", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 180,
                shortName: "Operator",
                longName: "FM Operator",
                page: "Osc",
                height: 12,
                inputs: [
                    ConnectorDef(name: "Freq", color: .control, horiz: 0, vert: 3),
                    ConnectorDef(name: "FM", color: .audio, horiz: 19, vert: 1),
                    ConnectorDef(name: "Gate", color: .logic, horiz: 0, vert: 5),
                    ConnectorDef(name: "Note", color: .control, horiz: 0, vert: 6),
                    ConnectorDef(name: "AMod", color: .control, horiz: 0, vert: 9),
                    ConnectorDef(name: "Vel", color: .control, horiz: 0, vert: 11),
                    ConnectorDef(name: "Pitch", color: .control, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 11),
                ],
                paramNames: ["Kbt", "Sync", "RatioFixed", "FreqCoarse", "FreqFine", "FreqDetune", "Vel", "RateScale", "R1", "L1", "R2", "L2", "R3", "L3", "R4", "L4", "AMod", "BrPoint", "LDepthMode", "LDepth", "RDepthMode", "RDepth", "OutLevel", "Active", "EnvKB"],
                modeNames: []
            ),
            ModuleDef(
                id: 181,
                shortName: "DlyEight",
                longName: "Delay 8 Tap",
                page: "Delay",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out1", color: .audio, horiz: 7, vert: 2),
                    ConnectorDef(name: "Out2", color: .audio, horiz: 9, vert: 2),
                    ConnectorDef(name: "Out3", color: .audio, horiz: 10, vert: 2),
                    ConnectorDef(name: "Out4", color: .audio, horiz: 12, vert: 2),
                    ConnectorDef(name: "Out5", color: .audio, horiz: 14, vert: 2),
                    ConnectorDef(name: "Out6", color: .audio, horiz: 16, vert: 2),
                    ConnectorDef(name: "Out7", color: .audio, horiz: 17, vert: 2),
                    ConnectorDef(name: "Out8", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["Time"],
                modeNames: ["DelayRange3"] // g2ools: DelayRange_3
            ),
            ModuleDef(
                id: 182,
                shortName: "DlyStereo",
                longName: "Delay Stereo",
                page: "Delay",
                height: 5,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "OutL", color: .audio, horiz: 17, vert: 4),
                    ConnectorDef(name: "OutR", color: .audio, horiz: 19, vert: 4),
                ],
                paramNames: ["TimeLeft", "TimeRight", "FBLeft", "FBRight", "XFBLeft", "XFBRight", "TimeClk", "LP", "DryWet", "Active", "HP"],
                modeNames: ["DelayRange1"] // g2ools: DelayRange_1 (3 opcje: 500ms, 1.0s, 1.35s)
            ),
            ModuleDef(
                id: 183,
                shortName: "OscPM",
                longName: "Osc Phase Mod",
                page: "Osc",
                height: 3,
                inputs: [
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 2),
                    ConnectorDef(name: "Sync", color: .audio, horiz: 12, vert: 2),
                    ConnectorDef(name: "PhaseMod", color: .audio, horiz: 14, vert: 2),
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "Kbt", "FreqMode", "PhaseMod", "Active", "PitchVar"],
                modeNames: ["Waveform"]
            ),
            ModuleDef(
                id: 184,
                shortName: "Mix1-1A",
                longName: "Mixer 1-1 A",
                page: "Mixer",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Chain", color: .pitchOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Lev", "On", "ExpLin"],
                modeNames: []
            ),
            ModuleDef(
                id: 185,
                shortName: "Mix1-1S",
                longName: "Mixer 1-1 Stereo",
                page: "Mixer",
                height: 2,
                inputs: [
                    ConnectorDef(name: "InL", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "InR", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "LChain", color: .pitchOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "RChain", color: .pitchOrControl, horiz: 1, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "OutL", color: .pitchOrControl, horiz: 17, vert: 1),
                    ConnectorDef(name: "OutR", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Lev", "On", "ExpLin"],
                modeNames: []
            ),
            ModuleDef(
                id: 186,
                shortName: "Sw1-2M",
                longName: "Switch 1-2 Momentary",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 14, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "OutOn", color: .pitchOrControl, horiz: 19, vert: 1),
                    ConnectorDef(name: "OutOff", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 1),
                ],
                paramNames: ["Sel"],
                modeNames: []
            ),
            ModuleDef(
                id: 187,
                shortName: "Sw2-1M",
                longName: "Switch 2-1 Momentary",
                page: "Switch",
                height: 2,
                inputs: [
                    ConnectorDef(name: "InOff", color: .pitchOrControl, horiz: 14, vert: 1),
                    ConnectorDef(name: "InOn", color: .pitchOrControl, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                    ConnectorDef(name: "Ctrl", color: .control, horiz: 0, vert: 1),
                ],
                paramNames: ["Sel"],
                modeNames: []
            ),
            ModuleDef(
                id: 188,
                shortName: "ConstSwM",
                longName: "Constant Switch Momentary",
                page: "Level",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Lev", "On", "BipUni"],
                modeNames: []
            ),
            ModuleDef(
                id: 189,
                shortName: "NoiseGate",
                longName: "Noise Gate",
                page: "Level",
                height: 3,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 19, vert: 0),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 2),
                    ConnectorDef(name: "Env", color: .control, horiz: 17, vert: 2),
                ],
                paramNames: ["Threshold", "Attack", "Release", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 190,
                shortName: "LfoB",
                longName: "LFO B",
                page: "LFO",
                height: 4,
                inputs: [
                    ConnectorDef(name: "Rate", color: .control, horiz: 1, vert: 3),
                    ConnectorDef(name: "RateVar", color: .control, horiz: 3, vert: 3),
                    ConnectorDef(name: "Rst", color: .control, horiz: 0, vert: 1),
                    ConnectorDef(name: "Phase", color: .control, horiz: 10, vert: 3),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 3),
                    ConnectorDef(name: "Sync", color: .control, horiz: 0, vert: 3),
                ],
                paramNames: ["Rate", "RateMod", "Range", "Kbt", "Waveform", "PolyMono", "Phase", "Active", "OutputType", "PhaseMod"],
                modeNames: []
            ),
            ModuleDef(
                id: 192,
                shortName: "Phaser",
                longName: "Phaser",
                page: "FX",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .audio, horiz: 16, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 1),
                ],
                paramNames: ["Type", "Freq", "FeedBack", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 193,
                shortName: "Mix4-1A",
                longName: "Mixer 4-1 A",
                page: "Mixer",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 5, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 8, vert: 1),
                    ConnectorDef(name: "In3", color: .pitchOrControl, horiz: 11, vert: 1),
                    ConnectorDef(name: "In4", color: .pitchOrControl, horiz: 15, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 194,
                shortName: "Mix2-1A",
                longName: "Mixer 2-1 A",
                page: "Mixer",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In1", color: .pitchOrControl, horiz: 9, vert: 1),
                    ConnectorDef(name: "In2", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Chain", color: .pitchOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["Lev1", "On1", "Lev2", "On2", "ExpLin"],
                modeNames: []
            ),
            ModuleDef(
                id: 195,
                shortName: "ModAmt",
                longName: "Modulation Amount",
                page: "Level",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 16, vert: 1),
                    ConnectorDef(name: "Mod", color: .pitchOrControl, horiz: 15, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["ModDepth", "On", "ExpLin", "InvertMode"],
                modeNames: []
            ),
            ModuleDef(
                id: 196,
                shortName: "OscPerc",
                longName: "Osc Percussion",
                page: "Osc",
                height: 3,
                inputs: [
                    ConnectorDef(name: "Pitch", color: .pitchOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "PitchVar", color: .pitchOrControl, horiz: 0, vert: 2),
                    ConnectorDef(name: "Trig", color: .audio, horiz: 3, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 3),
                ],
                paramNames: ["FreqCoarse", "FreqFine", "FreqMode", "Kbt", "PitchMod", "Decay", "Click", "Punch", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 197,
                shortName: "Status",
                longName: "Status",
                page: "In/Out",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "PatchActive", color: .logic, horiz: 8, vert: 1),
                    ConnectorDef(name: "VarActive", color: .logic, horiz: 13, vert: 1),
                    ConnectorDef(name: "VoiceNo", color: .control, horiz: 18, vert: 1),
                ],
                paramNames: [],
                modeNames: []
            ),
            ModuleDef(
                id: 198,
                shortName: "PitchTrack",
                longName: "Pitch Tracker",
                page: "Note",
                height: 2,
                inputs: [
                    ConnectorDef(name: "In", color: .pitchOrControl, horiz: 0, vert: 1),
                ],
                outputs: [
                    // POPRAWKA WOBEC g2ools (2026-08-28) — nie regenerować z powrotem.
                    // g2ools wypisuje wyjścia w kolejności lewo→prawo, przez co Gate
                    // dostaje indeks 1, a Pitch 2. Panel Clavii P979 (00979_PitchDetect)
                    // podaje jawne CodeRef: Period 0 (XPos 173, Logic), Pitch 1 (XPos 240,
                    // Control), Gate 2 (XPos 199, Logic) — identycznie jak Gen1. Indeks
                    // gniazda jest kluczem kabla w patchu, więc kolejność g2ools wieszała
                    // kabel „Pitch" przy gnieździe „Gate". Szczegóły → bug-history #56.
                    ConnectorDef(name: "Period", color: .logicOrControl, horiz: 13, vert: 1),
                    ConnectorDef(name: "Pitch", color: .control, horiz: 19, vert: 1),
                    ConnectorDef(name: "Gate", color: .logicOrControl, horiz: 15, vert: 1),
                ],
                paramNames: ["Threshold"],
                modeNames: []
            ),
            ModuleDef(
                id: 199,
                shortName: "MonoKey",
                longName: "Monophonic Keyboard",
                page: "In/Out",
                height: 2,
                inputs: [],
                outputs: [
                    ConnectorDef(name: "Pitch", color: .control, horiz: 14, vert: 1),
                    ConnectorDef(name: "Gate", color: .logic, horiz: 16, vert: 1),
                    ConnectorDef(name: "Vel", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Mode"],
                modeNames: []
            ),
            ModuleDef(
                id: 200,
                shortName: "RandomA",
                longName: "Random A",
                page: "Rnd",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Rate", color: .control, horiz: 0, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 1),
                ],
                paramNames: ["Rate", "PolyMono", "OutputType", "Range", "Active", "Edge", "StepProb"],
                modeNames: []
            ),
            ModuleDef(
                id: 202,
                shortName: "RandomB",
                longName: "Random B",
                page: "Rnd",
                height: 3,
                inputs: [
                    ConnectorDef(name: "Rate", color: .control, horiz: 0, vert: 1),
                    ConnectorDef(name: "RateVar", color: .control, horiz: 0, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .control, horiz: 19, vert: 2),
                ],
                paramNames: ["Rate", "PolyMono", "Kbt", "RateMod", "StepProb", "Active", "OutputType", "Range", "Edge"],
                modeNames: []
            ),
            ModuleDef(
                id: 204,
                shortName: "RndClkA",
                longName: "Random Clock A",
                page: "Rnd",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "Rst", color: .logicOrControl, horiz: 4, vert: 1),
                    ConnectorDef(name: "Seed", color: .pitchOrControl, horiz: 7, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["StepProb", "PolyMono", "Dice", "OutputType", "Active"],
                modeNames: []
            ),
            ModuleDef(
                id: 205,
                shortName: "RndTrig",
                longName: "Random Trig",
                page: "Rnd",
                height: 2,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "Rst", color: .logicOrControl, horiz: 4, vert: 1),
                    ConnectorDef(name: "Seed", color: .pitchOrControl, horiz: 7, vert: 1),
                    ConnectorDef(name: "Prob", color: .pitchOrControl, horiz: 8, vert: 1),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .logicOrControl, horiz: 19, vert: 1),
                ],
                paramNames: ["StepProb", "StepProbMod", "Active", "PolyMono"],
                modeNames: []
            ),
            ModuleDef(
                id: 206,
                shortName: "RndClkB",
                longName: "Random Clock B",
                page: "Rnd",
                height: 3,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "Rst", color: .logicOrControl, horiz: 0, vert: 2),
                    ConnectorDef(name: "Seed", color: .pitchOrControl, horiz: 3, vert: 2),
                    ConnectorDef(name: "Step", color: .control, horiz: 11, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 2),
                ],
                paramNames: ["StepProb", "OutputType", "Active", "PolyMono", "StepProbMod"],
                modeNames: ["Character"]
            ),
            ModuleDef(
                id: 208,
                shortName: "RndPattern",
                longName: "Random Pattern",
                page: "Rnd",
                height: 3,
                inputs: [
                    ConnectorDef(name: "Clk", color: .logicOrControl, horiz: 0, vert: 1),
                    ConnectorDef(name: "Rst", color: .logicOrControl, horiz: 0, vert: 2),
                    ConnectorDef(name: "A", color: .control, horiz: 3, vert: 1),
                    ConnectorDef(name: "B", color: .control, horiz: 3, vert: 2),
                    ConnectorDef(name: "StepProb", color: .control, horiz: 9, vert: 2),
                ],
                outputs: [
                    ConnectorDef(name: "Out", color: .pitchOrControl, horiz: 19, vert: 2),
                ],
                paramNames: ["PatternA", "PatternB", "StepProb", "LoopCount", "StepProbMod", "OutputType", "Active"],
                modeNames: ["Waveform"]
            ),

            // MARK: - PM (Physical Modelling) — rozszerzenie firmware G2

            // Źródło: BVerhue Driver.txt (PMDriver) i Resonator.txt (PMResonator)
            // Nie ma w g2ools — dodane ręcznie na podstawie BVerhue .txt i binarnej analizy patchy.

            ModuleDef(
                id: 35,
                shortName: "Driver",
                longName: "PM Driver",
                page: "PM",
                height: 3,
                inputs: [
                    // CodeRef:0 = Drv (Audio, XPos:215), CodeRef:1 = Excitation (Audio, XPos:8)
                    ConnectorDef(name: "Drv", color: .audio, horiz: 17, vert: 2),
                    ConnectorDef(name: "Excitation", color: .audio, horiz: 1, vert: 2),
                ],
                outputs: [
                    // CodeRef:0 (Audio, XPos:239)
                    ConnectorDef(name: "Out", color: .audio, horiz: 19, vert: 2),
                ],
                paramNames: ["Stiffness", "Embouchure"],
                modeNames: ["Type"]
            ),
            ModuleDef(
                id: 56,
                shortName: "Resonator",
                longName: "PM Resonator",
                page: "PM",
                height: 5,
                inputs: [
                    // CodeRef:0 = Drv (Audio, XPos:239 YPos:5)
                    // CodeRef:1 = Pitch mod (Control, XPos:5 YPos:54)
                    // CodeRef:2 = Mod (Control, XPos:21 YPos:54)
                    ConnectorDef(name: "Drv", color: .audio, horiz: 19, vert: 1),
                    ConnectorDef(name: "Pitch", color: .control, horiz: 0, vert: 4),
                    ConnectorDef(name: "Mod", color: .control, horiz: 2, vert: 4),
                ],
                outputs: [
                    // CodeRef:0 = Out (Audio, XPos:215 YPos:5)
                    // CodeRef:1 = Out2 (Audio, XPos:239 YPos:57)
                    ConnectorDef(name: "Out", color: .audio, horiz: 17, vert: 1),
                    ConnectorDef(name: "Out2", color: .audio, horiz: 19, vert: 4),
                ],
                // Knobs CodeRef: 0=Pitch, 1=Cent, 3=Fine, 5=Decay, 6=Damp, 8=Pos
                // Buttons CodeRef: 2=KBT, 4=Type(Semi/Freq/Fac/Part), 7=M, 9=Algorithm
                // Wszystkie jako params (nModes=0 w binarnych patchach)
                paramNames: ["Pitch", "Cent", "KBT", "Fine", "Type", "Decay", "Damp", "M", "Pos", "Algorithm"],
                modeNames: []
            ),
        ]
    }
}
