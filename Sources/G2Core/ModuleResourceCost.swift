// ModuleResourceCost.swift
//
// WYGENEROWANE przez `Tools/generate_module_cost.py` z `Docs/data/dsp-module-cost.csv`.
// Nie edytuj ręcznie — popraw pomiar albo generator.
//
// Skąd te liczby: 2026-10-28, raport `0x72` firmware'u 1.62, `swift run USBProbe --dspcal`
// (`Tools/generate_module_cost_extras.py` przepisuje je do CSV). Jeden moduł danego typu
// w pustym slocie, odczyt raportu `0x72` dopiero po potwierdzonym wyczyszczeniu slotu.
// Pomiar w obszarze **fx**, przy parametrach domyślnych, bez kabli. Pierwsza wersja
// (2026-09-08, Nord, `--dsptable`) zawyżała koszt 40 typów, prawie zawsze stronę zerową.
//
// Wolno tego użyć także dla obszaru voice: liczba głosów kosztu NIE mnoży (sprawdzone
// 2026-09-08 na froncie Norda, potwierdzone w ORYGINALNYM edytorze Clavii — kręcenie
// `Voices` nie rusza wskaźników). Zastrzeżenie zostaje jedno: dla modułów opóźniających
// koszt zależy od nastawionego czasu, więc dla nich to wartość przy nastawie domyślnej.
//
// Pełny opis i wnioski → [[Docs/data/dsp-module-cost]].

import Foundation

/// Ile zasobów obszaru zjada JEDEN moduł danego typu.
///
/// Pola są w tej samej kolejności i tych samych jednostkach co w `G2PatchLoad`,
/// bo służą do zsumowania w dokładnie taki sam odczyt.
public struct ModuleResourceCost: Sendable, Equatable {
    public let cyclesRed: Int
    public let cyclesBlue: Int
    public let xMemory: Int
    public let yMemory: Int
    public let programMemory: Int
    public let zeroPageMemory: Int
    public let ram: Int
    public let qMemory: Int
    public let rMemory: Int

    /// Zwięzły konstruktor dla wygenerowanej tabeli — kolejność pól jak w nagłówku CSV.
    /// Nazwane etykiety przy 168 wierszach po dziewięć liczb dałyby plik nie do czytania.
    init(_ cyclesRed: Int, _ cyclesBlue: Int, _ xMemory: Int, _ yMemory: Int,
         _ programMemory: Int, _ zeroPageMemory: Int, _ ram: Int, _ qMemory: Int,
         _ rMemory: Int)
    {
        self.cyclesRed = cyclesRed
        self.cyclesBlue = cyclesBlue
        self.xMemory = xMemory
        self.yMemory = yMemory
        self.programMemory = programMemory
        self.zeroPageMemory = zeroPageMemory
        self.ram = ram
        self.qMemory = qMemory
        self.rMemory = rMemory
    }
}

public enum ModuleResourceCostDatabase {
    /// Koszt jednego modułu tego typu; `nil`, gdy typ jest spoza katalogu.
    ///
    /// Zmierzone są wszystkie 168 typów, które zna `ModuleDatabase` — brak wpisu
    /// oznacza więc moduł nierozpoznany, a takie wyłapuje `PatchValidator`.
    public static func cost(typeID: Int) -> ModuleResourceCost? {
        table[typeID]
    }

    /// Ile typów jest wycenionych — pilnuje tego test razem z `ModuleDatabase`.
    public static var count: Int {
        table.count
    }

    private static let table: [Int: ModuleResourceCost] = [
        1: .init(0, 0, 0, 0, 0, 0, 0, 0, 0), // Keyboard
        3: .init(0, 0, 0, 0, 0, 0, 0, 0, 0), // 4-Out
        4: .init(23, 0, 3, 3, 23, 0, 0, 0, 0), // 2-Out
        5: .init(0, 10, 2, 0, 10, 2, 0, 0, 0), // Invert
        7: .init(66, 8, 9, 6, 186, 1, 0, 0, 0), // OscB
        8: .init(91, 8, 9, 6, 97, 1, 0, 0, 0), // OscShpB
        9: .init(22, 8, 9, 6, 30, 1, 0, 0, 0), // OscC
        12: .init(387, 0, 63, 12, 194, 2, 0, 65536, 3), // Reverb
        13: .init(221, 8, 9, 13, 150, 1, 0, 16000, 0), // OscString
        15: .init(0, 15, 5, 4, 15, 2, 0, 0, 0), // Sw8-1
        17: .init(0, 12, 1, 3, 12, 2, 0, 0, 0), // ValSw1-2
        18: .init(0, 14, 2, 1, 14, 1, 0, 0, 0), // X-Fade
        19: .init(0, 7, 0, 1, 7, 1, 0, 0, 0), // Mix4-1B
        20: .init(0, 37, 18, 5, 37, 1, 0, 0, 0), // EnvADSR
        21: .init(0, 52, 13, 7, 52, 8, 0, 0, 0), // Mux1-8
        22: .init(0, 18, 4, 32, 18, 1, 0, 0, 0), // PartQuant
        23: .init(0, 86, 40, 2, 86, 1, 0, 0, 0), // ModADSR
        24: .init(0, 38, 7, 4, 39, 1, 0, 0, 0), // LfoC
        25: .init(0, 259, 13, 12, 361, 2, 0, 0, 1), // LfoShpA
        26: .init(0, 104, 9, 10, 147, 1, 0, 0, 1), // LfoA
        27: .init(0, 8, 2, 2, 8, 1, 0, 0, 0), // OscMaster
        28: .init(0, 43, 2, 1, 43, 1, 0, 0, 0), // Saturate
        29: .init(87, 29, 24, 16, 116, 2, 0, 0, 0), // MetNoise
        30: .init(0, 0, 0, 0, 0, 0, 0, 0, 0), // Device
        31: .init(13, 0, 4, 2, 13, 1, 0, 0, 0), // Noise
        32: .init(35, 0, 5, 3, 35, 1, 0, 0, 4), // Eq2Band
        33: .init(58, 0, 9, 5, 58, 1, 0, 0, 7), // Eq3Band
        34: .init(0, 26, 1, 2, 26, 1, 0, 0, 0), // ShpExp
        35: .init(16, 0, 1, 1, 16, 1, 0, 0, 0), // Driver
        36: .init(0, 5, 1, 0, 5, 2, 0, 0, 0), // SwOnOffM
        38: .init(0, 43, 7, 6, 43, 1, 0, 0, 0), // Pulse
        40: .init(0, 7, 0, 1, 7, 1, 0, 0, 0), // Mix8-1B
        41: .init(0, 14, 3, 3, 14, 1, 0, 0, 0), // EnvH
        42: .init(0, 42, 7, 3, 42, 1, 0, 0, 0), // Delay
        43: .init(0, 0, 0, 0, 0, 1, 0, 0, 0), // Constant
        44: .init(0, 5, 0, 0, 5, 1, 0, 0, 0), // LevMult
        45: .init(43, 67, 28, 30, 110, 1, 0, 0, 3), // FltVoice
        46: .init(0, 55, 29, 6, 55, 1, 0, 0, 0), // EnvAHD
        47: .init(0, 14, 2, 1, 14, 2, 0, 0, 0), // Pan
        48: .init(0, 43, 14, 13, 43, 2, 0, 0, 0), // MixStereo
        49: .init(30, 16, 8, 6, 46, 3, 0, 0, 3), // FltMulti
        50: .init(0, 4, 1, 0, 4, 1, 0, 0, 0), // ConstSwT
        51: .init(39, 23, 10, 12, 62, 1, 0, 0, 3), // FltNord
        52: .init(0, 55, 36, 6, 55, 1, 0, 0, 0), // EnvMulti
        53: .init(0, 10, 1, 1, 10, 1, 0, 0, 0), // S&H
        54: .init(19, 0, 4, 4, 19, 1, 0, 0, 6), // FltStatic
        55: .init(0, 15, 5, 1, 15, 1, 0, 0, 0), // EnvD
        56: .init(219, 8, 13, 23, 184, 7, 0, 65542, 0), // Resonator
        57: .init(0, 1, 1, 0, 1, 0, 0, 0, 1), // Automate
        58: .init(72, 101, 35, 26, 173, 2, 0, 0, 0), // DrumSynth
        59: .init(0, 5, 1, 1, 5, 1, 0, 0, 0), // CompLev
        60: .init(15, 57, 14, 8, 72, 1, 0, 0, 0), // Mux8-1X
        61: .init(0, 13, 1, 2, 13, 1, 0, 0, 0), // Clip
        62: .init(0, 96, 12, 11, 96, 1, 0, 0, 0), // Overdrive
        63: .init(112, 43, 21, 14, 121, 1, 0, 9657, 0), // Scratch
        64: .init(0, 20, 0, 2, 20, 2, 0, 0, 0), // Gate
        66: .init(0, 6, 1, 1, 6, 1, 0, 0, 1), // Mix2-1B
        68: .init(0, 68, 13, 9, 68, 4, 0, 0, 0), // ClkGen
        69: .init(0, 19, 5, 2, 19, 1, 0, 0, 0), // ClkDiv
        71: .init(0, 17, 3, 2, 17, 1, 0, 0, 0), // EnvFollow
        72: .init(0, 4, 1, 1, 4, 1, 0, 0, 0), // NoteScaler
        74: .init(0, 48, 1, 2, 47, 1, 0, 0, 0), // WaveWrap
        75: .init(0, 13, 2, 1, 13, 1, 0, 0, 0), // NoteQuant
        76: .init(0, 5, 1, 0, 5, 2, 0, 0, 0), // SwOnOffT
        78: .init(0, 16, 5, 4, 16, 9, 0, 0, 0), // Sw1-8
        79: .init(0, 10, 3, 2, 10, 2, 0, 0, 0), // Sw4-1
        81: .init(0, 5, 1, 0, 5, 1, 0, 0, 0), // LevAmp
        82: .init(0, 7, 0, 0, 7, 1, 0, 0, 0), // Rect
        83: .init(0, 16, 3, 1, 16, 1, 0, 0, 0), // ShpStatic
        84: .init(0, 41, 14, 7, 41, 2, 0, 0, 0), // EnvADR
        85: .init(0, 11, 2, 1, 11, 2, 0, 0, 0), // WindSw
        86: .init(0, 34, 9, 3, 34, 8, 0, 0, 0), // 8Counter
        87: .init(8, 9, 3, 1, 17, 1, 0, 0, 0), // FltLP
        88: .init(0, 9, 3, 2, 9, 5, 0, 0, 0), // Sw1-4
        89: .init(43, 14, 521, 142, 57, 2, 0, 0, 0), // Flanger
        90: .init(0, 7, 1, 0, 7, 3, 0, 0, 0), // Sw1-2
        91: .init(0, 17, 2, 2, 17, 2, 0, 0, 0), // FlipFlop
        92: .init(34, 26, 8, 8, 59, 1, 0, 0, 0), // FltClassic
        94: .init(60, 53, 522, 158, 113, 2, 0, 0, 0), // StChorus
        96: .init(22, 8, 9, 6, 30, 1, 0, 0, 0), // OscD
        97: .init(51, 8, 9, 6, 133, 1, 0, 0, 0), // OscA
        98: .init(110, 16, 19, 22, 126, 4, 0, 0, 0), // FreqShift
        100: .init(0, 6, 1, 0, 6, 2, 0, 0, 0), // Sw2-1
        102: .init(102, 33, 15, 18, 135, 1, 0, 0, 0), // FltPhase
        103: .init(34, 0, 5, 3, 34, 1, 0, 0, 3), // EqPeak
        105: .init(0, 9, 2, 2, 9, 1, 0, 0, 0), // ValSw2-1
        106: .init(77, 37, 21, 20, 114, 1, 0, 0, 12), // OscNoise
        108: .init(98, 1156, 350, 393, 1254, 33, 0, 0, 0), // Vocoder
        112: .init(0, 4, 1, 0, 4, 1, 0, 0, 2), // LevAdd
        113: .init(0, 10, 1, 2, 10, 2, 0, 0, 0), // Fade1-2
        114: .init(0, 9, 1, 1, 9, 1, 0, 0, 0), // Fade2-1
        115: .init(0, 23, 4, 3, 23, 1, 0, 0, 0), // LevScaler
        116: .init(0, 7, 0, 1, 7, 1, 0, 0, 0), // Mix8-1A
        117: .init(0, 15, 1, 2, 15, 1, 0, 0, 0), // LevMod
        118: .init(0, 29, 4, 5, 29, 1, 0, 0, 0), // Digitizer
        119: .init(0, 55, 36, 6, 55, 1, 0, 0, 0), // EnvADDSR
        121: .init(0, 72, 15, 44, 72, 3, 0, 0, 5), // SeqNote
        123: .init(0, 7, 0, 1, 7, 1, 0, 0, 0), // Mix4-1C
        124: .init(15, 38, 13, 7, 53, 1, 0, 0, 0), // Mux8-1
        125: .init(34, 0, 6, 6, 34, 1, 0, 0, 0), // WahWah
        126: .init(0, 0, 0, 0, 0, 0, 0, 0, 0), // Name
        127: .init(19, 0, 1, 4, 19, 2, 0, 0, 2), // Fx-In
        128: .init(0, 7, 0, 0, 7, 2, 0, 0, 0), // MinMax
        130: .init(0, 36, 2, 3, 36, 8, 0, 0, 0), // BinCounter
        131: .init(0, 31, 1, 1, 31, 8, 0, 0, 0), // ADConv
        132: .init(0, 29, 1, 0, 29, 1, 0, 0, 0), // DAConv
        134: .init(12, 13, 5, 1, 25, 1, 0, 0, 0), // FltHP
        139: .init(0, 7, 1, 0, 7, 1, 0, 0, 0), // T&H
        140: .init(0, 13, 0, 2, 13, 2, 0, 0, 0), // Mix4-1S
        141: .init(0, 0, 0, 0, 0, 0, 0, 0, 0), // CtrlSend
        142: .init(0, 0, 0, 0, 0, 0, 0, 0, 0), // PCSend
        143: .init(0, 26, 5, 5, 26, 0, 0, 0, 0), // NoteSend
        144: .init(0, 72, 15, 44, 72, 3, 0, 0, 5), // SeqEvent
        145: .init(0, 72, 15, 44, 72, 3, 0, 0, 5), // SeqVal
        146: .init(0, 72, 15, 44, 72, 3, 0, 0, 5), // SeqLev
        147: .init(0, 4, 1, 1, 4, 2, 0, 0, 0), // CtrlRcv
        148: .init(0, 5, 2, 1, 5, 3, 0, 0, 0), // NoteRcv
        149: .init(0, 1, 0, 0, 1, 0, 0, 0, 0), // NoteZone
        150: .init(65, 0, 8, 8, 65, 2, 0, 0, 3), // Compress
        152: .init(0, 42, 15, 15, 42, 1, 0, 0, 0), // KeyQuant
        154: .init(0, 39, 8, 43, 38, 2, 0, 0, 5), // SeqCtr
        156: .init(0, 5, 2, 1, 5, 3, 0, 0, 0), // NoteDet
        157: .init(0, 5, 1, 1, 5, 1, 0, 0, 0), // LevConv
        158: .init(0, 18, 2, 6, 18, 1, 0, 0, 0), // Glide
        159: .init(0, 6, 1, 0, 6, 1, 0, 0, 0), // CompSig
        160: .init(0, 29, 8, 5, 29, 1, 0, 0, 0), // ZeroCnt
        161: .init(0, 7, 0, 1, 7, 1, 0, 0, 0), // MixFader
        162: .init(121, 8, 7, 13, 106, 1, 0, 32771, 0), // FltComb
        163: .init(160, 8, 11, 8, 588, 1, 0, 0, 0), // OscShpA
        164: .init(125, 8, 13, 8, 133, 1, 0, 0, 0), // OscDual
        165: .init(31, 0, 2, 3, 31, 7, 0, 0, 0), // DXRouter
        167: .init(112, 58, 20, 15, 136, 1, 0, 9657, 0), // PShift
        169: .init(0, 61, 21, 3, 61, 1, 0, 0, 0), // ModAHD
        170: .init(19, 0, 1, 4, 19, 2, 0, 0, 2), // 2-In
        171: .init(38, 0, 2, 8, 38, 4, 0, 0, 4), // 4-In
        172: .init(44, 0, 6, 6, 31, 1, 0, 513, 4), // DlySingleA
        173: .init(44, 0, 6, 6, 31, 1, 0, 513, 4), // DlySingleB
        174: .init(63, 0, 7, 9, 47, 2, 0, 513, 8), // DelayDual
        175: .init(107, 0, 9, 15, 81, 5, 0, 513, 16), // DelayQuad
        176: .init(85, 0, 14, 6, 71, 1, 0, 48011, 4), // DelayA
        177: .init(85, 0, 14, 6, 71, 1, 0, 48011, 4), // DelayB
        178: .init(47, 0, 4, 131, 42, 1, 0, 0, 0), // DlyClock
        179: .init(0, 40, 1, 8, 35, 8, 0, 0, 0), // DlyShiftReg
        180: .init(26, 119, 50, 18, 145, 1, 0, 0, 4), // Operator
        181: .init(105, 0, 6, 10, 71, 8, 0, 513, 0), // DlyEight
        182: .init(176, 0, 32, 14, 150, 4, 0, 96022, 8), // DlyStereo
        183: .init(22, 8, 9, 6, 30, 1, 0, 0, 0), // OscPM
        184: .init(0, 5, 1, 1, 5, 1, 0, 0, 1), // Mix1-1A
        185: .init(0, 8, 1, 0, 8, 2, 0, 0, 1), // Mix1-1S
        186: .init(0, 7, 1, 0, 7, 3, 0, 0, 0), // Sw1-2M
        187: .init(0, 6, 1, 0, 6, 2, 0, 0, 0), // Sw2-1M
        188: .init(0, 4, 1, 0, 4, 1, 0, 0, 0), // ConstSwM
        189: .init(23, 42, 19, 9, 65, 3, 0, 0, 0), // NoiseGate
        190: .init(0, 141, 13, 12, 194, 2, 0, 0, 1), // LfoB
        192: .init(56, 45, 16, 12, 101, 1, 0, 0, 0), // Phaser
        193: .init(0, 7, 0, 0, 7, 1, 0, 0, 0), // Mix4-1A
        194: .init(0, 6, 1, 1, 6, 1, 0, 0, 1), // Mix2-1A
        195: .init(0, 9, 1, 1, 9, 1, 0, 0, 2), // ModAmt
        196: .init(36, 8, 8, 6, 44, 1, 0, 0, 0), // OscPerc
        197: .init(0, 9, 3, 2, 9, 3, 0, 0, 0), // Status
        198: .init(0, 122, 29, 18, 122, 4, 0, 0, 0), // PitchTrack
        199: .init(0, 0, 0, 0, 0, 0, 0, 0, 0), // MonoKey
        200: .init(0, 106, 12, 10, 97, 1, 0, 0, 0), // RandomA
        202: .init(0, 106, 12, 10, 97, 1, 0, 0, 0), // RandomB
        204: .init(0, 74, 9, 7, 64, 1, 0, 0, 0), // RndClkA
        205: .init(0, 66, 10, 9, 55, 1, 0, 0, 0), // RndTrig
        206: .init(0, 74, 9, 7, 64, 1, 0, 0, 0), // RndClkB
        208: .init(0, 99, 11, 8, 84, 1, 0, 0, 0), // RndPattern
    ]
}
