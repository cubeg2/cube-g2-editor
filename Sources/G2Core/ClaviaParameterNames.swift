// ClaviaParameterNames.swift
// Krótkie nazwy parametrów, które oryginał wpisuje w ekrany Parameter Pages
// i Parameter Overview — te same, które są nadrukowane na panelu modułu
// ("Pitch M", "Tune Md", "OutType"), nie kodowe nazwy g2ools z ModuleDatabase
// ("PitchMod", "FreqMode", "OutputType"). Clavia czyta je w CModule::GetParamName.
//
// Plik jest generowany: `python3 Tools/generate_clavia_param_names.py`
// ze źródła `reference/nord_g2_editor/Gen1/Bin/ModuleDef.xml`. Nie edytuj ręcznie.
//
// Moduł 35 (Driver) ma wpis nadpisany ręcznie: XML podaje Embouch/Stiffn
// w odwrotnej kolejności niż panel, a kanwa rysuje z panelu. Poprawiona jest
// też literówka Clavii „Course" → „Coarse" (moduł 56). Szczegóły w
// [[Docs/ui/parameter-pages]].

import Foundation

public enum ClaviaParameterNames {
    /// Krótka nazwa parametru albo `nil`, gdy tabela nie zna modułu lub indeksu —
    /// wtedy dzwoniący spada na `ModuleDef.paramNames`.
    public static func name(moduleTypeID: Int, paramIndex: Int) -> String? {
        guard let names = names[moduleTypeID], names.indices.contains(paramIndex) else {
            return nil
        }
        let name = names[paramIndex]
        return name.isEmpty ? nil : name
    }

    private static let names: [Int: [String]] = [
        3: ["Dest", "On/Off", "Pad"], // 4-Out
        4: ["Dest", "On/OFF", "Pad"], // 2-Out
        7: [ // OscB
            "Coarse",
            "Fine",
            "KBT",
            "Pitch M",
            "Tune Md",
            "Fm M",
            "Shape",
            "Shape M",
            "Wave",
            "On/OFF",
            "Fm PTrk",
        ],
        8: [ // OscShpB
            "Coarse",
            "Fine",
            "KBT",
            "Pitch M",
            "Tune Md",
            "Fm M",
            "Shape",
            "Shape M",
            "On/OFF",
            "Fm PTrk",
            "Wave",
        ],
        9: ["Coarse", "Fine", "KBT", "Tune Md", "Fm M", "On/OFF", "Fm PTrk", "Pitch M", "Wave"], // OscC
        12: ["Time", "Brightness", "DryWet", "On/OFF", "RoomType"], // Reverb
        13: ["Coarse", "Fine", "KBT", "Pitch M", "Tune Md", "Decay", "Moisture", "On/OFF"], // OscString
        15: ["Sel"], // Sw8-1
        17: ["Val"], // ValSw1-2
        18: ["MixMod", "Mix", "LogLin"], // X-Fade
        19: ["Lev1", "Lev2", "Lev3", "Lev4", "ExpLin"], // Mix4-1B
        20: ["Shape", "Attack", "Decay", "Sustain", "Release", "OutType", "KB", "Reset"], // EnvADSR
        22: ["Range"], // PartQuant
        23: ["Attack", "Decay", "Sustain", "Release", "Atk M", "Dcy M", "Sust M", "Rel M", "OutType", "KB"], // ModADSR
        24: ["Rate", "Mode", "OutType", "Range", "On/OFF", "Wave"], // LfoC
        25: [ // LfoShpA
            "Rate",
            "Range",
            "KBT",
            "Rate M",
            "On/OFF",
            "Shape",
            "Phase M",
            "Phase",
            "Shape M",
            "Mode",
            "OutType",
            "Wave",
        ],
        26: ["Rate", "Mode", "KBT", "Rate M", "Wave", "On/OFF", "OutType", "Range"], // LfoA
        27: ["Coarse", "Fine", "KBT", "Tune Md", "Pitch M"], // OscMaster
        28: ["Amount", "AmountMod", "On/OFF", "Curve"], // Saturate
        29: ["Color", "Freq", "On/OFF", "FreqMod", "ColorMod"], // MetNoise
        31: ["Color", "On/OFF"], // Noise
        32: ["LoSlope", "HiSlope", "Level", "On/OFF", "LoFreq", "HiFreq"], // Eq2Band
        33: ["LoSlope", "MidGain", "MidFreq", "HiSlope", "Level", "On/OFF", "LoFreq", "HiFreq"], // Eq3Band
        34: ["Amount", "AmountMod", "On/OFF", "Curve"], // ShpExp
        36: ["On"], // SwOnOffM
        38: ["Time", "TimeMod", "Range", "PulseMode"], // Pulse
        40: ["Lev1", "Lev2", "Lev3", "Lev4", "Lev5", "Lev6", "Lev7", "Lev8", "ExpLin", "Pad"], // Mix8-1B
        41: ["Hold", "OutType"], // EnvH
        42: ["Time", "TimeMod", "Range", "DelayMode"], // Delay
        43: ["Level", "BipUni"], // Constant
        45: [ // FltVoice
            "Vowel1",
            "Vowel2",
            "Vowel3",
            "Level",
            "Vowel",
            "VowelMod",
            "Freq",
            "FreqMod",
            "Res",
            "On/OFF",
        ],
        46: ["Shape", "Attack", "Hold", "Reset", "Decay", "OutType", "KB"], // EnvAHD
        47: ["PanMod", "Pan", "LogLin"], // Pan
        48: [ // MixStereo
            "Lev1",
            "Lev2",
            "Lev3",
            "Lev4",
            "Lev5",
            "Lev6",
            "Pan1",
            "Pan2",
            "Pan3",
            "Pan4",
            "Pan5",
            "Pan6",
            "LevMaster",
        ],
        49: ["Freq", "Freq M", "KBT", "GComp", "Res", "dB/Oct", "On/OFF"], // FltMulti
        50: ["Lev", "On", "BipUni"], // ConstSwT
        51: ["Freq", "Freq M", "KBT", "GComp", "Res", "dB/Oct", "On/OFF", "FM_Lin", "FilterType", "ResMod"], // FltNord
        52: [ // EnvMulti
            "Level1",
            "Level2",
            "Level3",
            "Level4",
            "Time1",
            "Time2",
            "Time3",
            "Time4",
            "Reset",
            "SusPlac",
            "OutType",
            "KBG",
            "Shape",
        ],
        54: ["Freq", "Res", "FilterType", "On/OFF", "GComp"], // FltStatic
        55: ["Decay", "OutType"], // EnvD
        57: ["Ctrl", "Val", "Ch", "Echo"], // Automate
        58: [ // DrumSynth
            "Masterfreq",
            "SlaveRatio",
            "MasterDecay",
            "SlaveDecay",
            "MasterLevel",
            "SlaveLevel",
            "NoiseFltFreq",
            "NoiseFltRes",
            "NoiseFltSweep",
            "NoiseFltDecay",
            "NoiseFltMode",
            "BendAmount",
            "BendDecay",
            "Click",
            "Noise",
            "On/OFF",
        ],
        59: ["C"], // CompLev
        60: ["XFade"], // Mux8-1X
        61: ["ClipLevMod", "ClipLev", "Shape", "On/OFF"], // Clip
        62: ["AmountMod", "Amount", "On/OFF", "Type", "Shape"], // Overdrive
        63: ["Ratio", "RatioMod", "Delay", "On/OFF"], // Scratch
        64: ["GateMode1", "GateMode2"], // Gate
        66: ["Inv1", "Lev1", "Inv2", "Lev2", "ExpLin"], // Mix2-1B
        68: ["Tempo", "On/OFF", "Source", "BeatSync", "Swing"], // ClkGen
        69: ["Divider", "DivMode"], // ClkDiv
        71: ["Attack", "Release"], // EnvFollow
        72: ["Range"], // NoteScaler
        74: ["AmountMod", "Amount", "On/OFF"], // WaveWrap
        75: ["Range", "Notes"], // NoteQuant
        76: ["On"], // SwOnOffT
        78: ["Sel"], // Sw1-8
        79: ["Sel"], // Sw4-1
        81: ["Gain", "Type"], // LevAmp
        82: ["Mode", "On/OFF"], // Rect
        83: ["Mode", "On/OFF"], // ShpStatic
        84: ["Shape", "Attack", "Reset", "Release", "TG", "OutType", "KB", "DcyRel"], // EnvADR
        85: ["ValFrom", "ValTo"], // WindSw
        87: ["Freq", "FreqMod", "KBT", "On/OFF", "SlopeMode"], // FltLP
        88: ["Sel"], // Sw1-4
        89: ["Rate", "Range", "FeedBack", "On/OFF"], // Flanger
        90: ["Sel"], // Sw1-2
        91: ["OperationMode"], // FlipFlop
        92: ["Freq", "Freq M", "KBT", "Res", "dB/Oct", "On/OFF"], // FltClassic
        94: ["Detune", "Amount", "On/OFF"], // StChorus
        96: ["Coarse", "Fine", "KBT", "Tune Md", "On/OFF", "Wave"], // OscD
        97: ["Coarse", "Fine", "KBT", "Pitch M", "Wave", "On/OFF", "Tune Md"], // OscA
        98: ["FreqShift", "ShiftMod", "Range", "On/OFF"], // FreqShift
        100: ["Sel"], // Sw2-1
        102: [ // FltPhase
            "Freq M",
            "Freq",
            "SpreadMod",
            "FB",
            "NotchCount",
            "Spread",
            "On/OFF",
            "Level",
            "FBMod",
            "Type",
            "KBT",
        ],
        103: ["Freq", "Gain", "BandWidth", "On/OFF", "Level"], // EqPeak
        105: ["Val"], // ValSw2-1
        106: ["Coarse", "Fine", "KBT", "Pitch M", "Tune Md", "Width", "WidthMod", "On/OFF"], // OscNoise
        108: [ // Vocoder
            "BandSel_01",
            "BandSel_02",
            "BandSel_03",
            "BandSel_04",
            "BandSel_05",
            "BandSel_06",
            "BandSel_07",
            "BandSel_08",
            "BandSel_09",
            "BandSel_10",
            "BandSel_11",
            "BandSel_12",
            "BandSel_13",
            "BandSel_14",
            "BandSel_15",
            "BandSel_16",
            "Emphasis",
            "Monitor",
        ],
        112: ["Level", "BipUni"], // LevAdd
        113: ["Mix", "MixMod"], // Fade1-2
        114: ["Mix", "MixMod"], // Fade2-1
        115: ["L", "BP", "R", "KBT"], // LevScaler
        116: ["Pad"], // Mix8-1A
        117: ["ModDepth", "ModType"], // LevMod
        118: ["Bits", "Rate", "Rate M", "On/OFF"], // Digitizer
        119: [ // EnvADDSR
            "KB",
            "Shape",
            "Attack",
            "Decay1",
            "Level1",
            "Decay2",
            "Level2",
            "Release",
            "SustainMode",
            "OutType",
            "Reset",
        ],
        121: [ // SeqNote
            "Step 1",
            "Step 2",
            "Step 3",
            "Step 4",
            "Step 5",
            "Step 6",
            "Step 7",
            "Step 8",
            "Step 9",
            "Step 10",
            "Step 11",
            "Step 12",
            "Step 13",
            "Step 14",
            "Step 15",
            "Step 16",
            "Evnt 1",
            "Evnt 2",
            "Evnt 3",
            "Evnt 4",
            "Evnt 5",
            "Evnt 6",
            "Evnt 7",
            "Evnt 8",
            "Evnt 9",
            "Evnt 10",
            "Evnt 11",
            "Evnt 12",
            "Evnt 13",
            "Evnt 14",
            "Evnt 15",
            "Evnt 16",
            "Cycles",
            "Length",
            "Pulse",
            "Clear",
            "Random",
        ],
        123: ["Lev1", "Lev2", "Lev3", "Lev4", "On1", "On2", "On3", "On4", "Pad", "ExpLin"], // Mix4-1C
        125: ["SweepMod", "Sweep", "On/OFF"], // WahWah
        127: ["Source", "On/OFF", "Pad"], // Fx-In
        134: ["Freq", "FreqMod", "KBT", "On/OFF", "SlopeMode"], // FltHP
        140: ["Lev1", "Lev2", "Lev3", "Lev4", "On1", "On2", "On3", "On4", "ExpLin"], // Mix4-1S
        141: ["Ctrl", "Val", "Ch"], // CtrlSend
        142: ["Program", "Ch"], // PCSend
        143: ["Vel", "Note", "Ch"], // NoteSend
        144: [ // SeqEvent
            "Step 1",
            "Step 2",
            "Step 3",
            "Step 4",
            "Step 5",
            "Step 6",
            "Step 7",
            "Step 8",
            "Step 9",
            "Step 10",
            "Step 11",
            "Step 12",
            "Step 13",
            "Step 14",
            "Step 15",
            "Step 16",
            "Evnt 1",
            "Evnt 2",
            "Evnt 3",
            "Evnt 4",
            "Evnt 5",
            "Evnt 6",
            "Evnt 7",
            "Evnt 8",
            "Evnt 9",
            "Evnt 10",
            "Evnt 11",
            "Evnt 12",
            "Evnt 13",
            "Evnt 14",
            "Evnt 15",
            "Evnt 16",
            "Cycles",
            "Length",
            "PulseUp",
            "PulseLo",
        ],
        145: [ // SeqVal
            "Step 1",
            "Step 2",
            "Step 3",
            "Step 4",
            "Step 5",
            "Step 6",
            "Step 7",
            "Step 8",
            "Step 9",
            "Step 10",
            "Step 11",
            "Step 12",
            "Step 13",
            "Step 14",
            "Step 15",
            "Step 16",
            "Evnt 1",
            "Evnt 2",
            "Evnt 3",
            "Evnt 4",
            "Evnt 5",
            "Evnt 6",
            "Evnt 7",
            "Evnt 8",
            "Evnt 9",
            "Evnt 10",
            "Evnt 11",
            "Evnt 12",
            "Evnt 13",
            "Evnt 14",
            "Evnt 15",
            "Evnt 16",
            "Cycles",
            "Length",
            "Pol",
            "Pulse",
            "Clear",
            "Random",
        ],
        146: [ // SeqLev
            "Step 1",
            "Step 2",
            "Step 3",
            "Step 4",
            "Step 5",
            "Step 6",
            "Step 7",
            "Step 8",
            "Step 9",
            "Step 10",
            "Step 11",
            "Step 12",
            "Step 13",
            "Step 14",
            "Step 15",
            "Step 16",
            "Evnt 1",
            "Evnt 2",
            "Evnt 3",
            "Evnt 4",
            "Evnt 5",
            "Evnt 6",
            "Evnt 7",
            "Evnt 8",
            "Evnt 9",
            "Evnt 10",
            "Evnt 11",
            "Evnt 12",
            "Evnt 13",
            "Evnt 14",
            "Evnt 15",
            "Evnt 16",
            "Cycles",
            "Length",
            "Pol",
            "Pulse",
            "Clear",
            "Random",
        ],
        147: ["Ctrl", "Ch"], // CtrlRcv
        148: ["Note", "Ch"], // NoteRcv
        149: ["RcvCh", "RcvMin", "RcvMax", "SendTrans", "SendCh", "ThruMode"], // NoteZone
        150: ["Treshold", "Ratio", "Attack", "Release", "RefLevel", "SideChain", "On/OFF"], // Compressor
        152: [ // KeyQuant
            "Range",
            "Capture",
            "Note E",
            "Note F",
            "Note F#",
            "Note G",
            "Note G#",
            "Note A",
            "Note A#",
            "Note B",
            "Note C",
            "Note C#",
            "Note D",
            "Note D#",
        ],
        154: [ // SeqCtr
            "Step 1",
            "Step 2",
            "Step 3",
            "Step 4",
            "Step 5",
            "Step 6",
            "Step 7",
            "Step 8",
            "Step 9",
            "Step 10",
            "Step 11",
            "Step 12",
            "Step 13",
            "Step 14",
            "Step 15",
            "Step 16",
            "Evnt 1",
            "Evnt 2",
            "Evnt 3",
            "Evnt 4",
            "Evnt 5",
            "Evnt 6",
            "Evnt 7",
            "Evnt 8",
            "Evnt 9",
            "Evnt 10",
            "Evnt 11",
            "Evnt 12",
            "Evnt 13",
            "Evnt 14",
            "Evnt 15",
            "Evnt 16",
            "Pulse",
            "Pol",
            "XFade",
            "Random",
            "Clear",
        ],
        156: ["Note"], // NoteDet
        157: ["OutType", "InputType"], // LevConv
        158: ["Time", "Glide", "Shape"], // Glide
        161: [ // MixFader
            "Lev1",
            "Lev2",
            "Lev3",
            "Lev4",
            "Lev5",
            "Lev6",
            "Lev7",
            "Lev8",
            "On1",
            "On2",
            "On3",
            "On4",
            "On5",
            "On6",
            "On7",
            "On8",
            "ExpLin",
            "Pad",
        ],
        162: ["Freq", "Freq M", "KBT", "FB", "FBMod", "Type", "Lev", "On/OFF"], // FltComb
        163: [ // OscShpA
            "Coarse",
            "Fine",
            "KBT",
            "Pitch M",
            "Tune Md",
            "Fm M",
            "Fm PTrk",
            "Shape",
            "Shape M",
            "Wave",
            "On/OFF",
        ],
        164: [ // OscDual
            "Coarse",
            "Fine",
            "KBT",
            "Pitch M",
            "Tune Md",
            "SqrLevel",
            "PWMod",
            "SawLevel",
            "SawPhase",
            "SubOctLevel",
            "On/OFF",
            "SqrPW",
            "Phase M",
            "Soft",
        ],
        165: ["Algorithm", "Feedback"], // DXRouter
        167: ["ShiftSemi", "ShiftFine", "ShiftMod", "Delay", "On/OFF"], // PShift
        169: ["Attack", "Hold", "Decay", "Atk M", "Hold M", "Dcy M", "OutType", "KB"], // ModAHD
        170: ["Source", "On/OFF", "Pad"], // 2-In
        171: ["Source", "On/OFF", "Pad"], // 4-In
        172: ["Time", "DelayRange"], // DlySingleA
        173: ["Time", "TimeMod", "DelayRange"], // DlySingleB
        174: ["Time1", "Time1Mod", "Time2", "Time2Mod", "DelayRange"], // DelayDual
        175: [ // DelayQuad
            "Time1",
            "Time1Mod",
            "Time2",
            "Time2Mod",
            "Time3",
            "Time3Mod",
            "Time4",
            "Time4Mod",
            "TimeClk",
            "DelayRange",
        ],
        176: ["Time", "FB", "Filter", "DryWet", "On/OFF", "TimeClk", "DelayRange"], // DelayA
        177: ["Time", "FB", "LP", "DryWet", "TimeClk", "FBMod", "DryWetMod", "On/OFF", "HP", "DelayRange"], // DelayB
        178: ["Delay"], // DlyClock
        180: [ // Operator
            "KBT",
            "Sync",
            "RatioFixed",
            "Coarse",
            "Fine",
            "FreqDetune",
            "Vel",
            "RateScale",
            "R1",
            "L1",
            "R2",
            "L2",
            "R3",
            "L3",
            "R4",
            "L4",
            "AMod",
            "BrPoint",
            "LDepthMode",
            "LDepth",
            "RDepthMode",
            "RDepth",
            "OutLevel",
            "On/OFF",
            "EnvKB",
        ],
        181: ["Time", "DelayRange"], // DlyEight
        182: [ // DlyStereo
            "TimeLeft",
            "TimeRight",
            "FBLeft",
            "FBRight",
            "XFBLeft",
            "XFBRight",
            "TimeClk",
            "LP",
            "DryWet",
            "On/OFF",
            "HP",
            "DelayRange",
        ],
        183: ["Coarse", "Fine", "KBT", "Tune Md", "Phase M", "On/OFF", "FreqMod", "Wave"], // OscPM
        184: ["Lev", "On", "ExpLin"], // Mix1-1A
        185: ["Lev", "On", "ExpLin"], // Mix1-1S
        186: ["Sel"], // Sw1-2M
        187: ["Sel"], // Sw2-1M
        188: ["Lev", "On", "BipUni"], // ConstSwM
        189: ["Treshold", "Attack", "Release", "On/OFF"], // NoiseGate
        190: ["Rate", "Rate M", "Range", "KBT", "Wave", "Mode", "Phase", "On/OFF", "OutType", "Phase M"], // LfoB
        192: ["Type", "Freq", "FeedBack", "On/OFF"], // Phaser
        194: ["Lev1", "On1", "Lev2", "On2", "ExpLin"], // Mix2-1A
        195: ["ModDepth", "On", "ExpLin", "InvertMode"], // ModAmt
        196: ["Coarse", "Fine", "Tune Md", "KBT", "Pitch M", "Decay", "Click", "Punch", "On/OFF"], // OscPerc
        198: ["Treshold"], // PitchTrack
        199: ["Priorty"], // MonoKey
        200: ["Rate", "Mode", "OutType", "Range", "On/OFF", "Edge", "Step"], // RandomA
        202: ["Rate", "Mode", "KBT", "Rate M", "Step", "On/OFF", "OutType", "Range", "Edge"], // RandomB
        204: ["Step", "Mode", "Dice", "OutType", "On/OFF"], // RndClkA
        205: ["Step", "Step M", "On/OFF", "Mode"], // RndTrig
        206: ["Step", "OutType", "On/OFF", "Mode", "Step M", "Character"], // RndClkB
        208: ["PatternA", "PatternB", "Step", "LoopCount", "Step M", "OutType", "On/OFF", "Wave"], // RndPattern
        35: ["Stiffn", "Embouch", "Driver T"], // Driver
        56: ["Coarse", "Fine", "KBT", "Pitch M", "Tune Md", "Decay", "Damp", "On/Off", "Pos", "Algorithm"], // Resonator
    ]
}
