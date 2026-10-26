// G2ParamClass.swift
// Klasa parametru — jeden bajt w opisie każdego parametru typu modułu w oryginalnym
// edytorze. Trzy okna czytają go zamiast nazwy parametru:
//
//   Patch Mutator   — czy parametr wolno ruszać i jaką krzywą losować (`CopyMutateContext`,
//                     `CopyRandomizeContext`) oraz kategoria Quick Lock (`IsEnabled`)
//   Patch Adjuster  — pod którą z ośmiu gałek parametr siedzi (`CPatch::HandleParamChange`)
//
// Klasa zależy od modułu I parametru, nie od samej nazwy: `Decay` w EnvD ma krzywą
// jednostronną (klasa 0x0E, jak Release), w EnvADSR dwustronną (0x0C); `FreqFine`
// oscylatorów jest dwustronny, a Operatora — liniowy. Dlatego tabela idzie po numerze
// typu i indeksie parametru → `G2ParamClassTable.swift` (wygenerowany).

import Foundation

public struct G2ParamClass: Hashable, Sendable {
    /// Krzywa losowania w Mutate i Randomize.
    public enum Curve: Sendable {
        /// Parametr zostaje nietknięty: przełączniki, selektory trybu, `Kbt`, `Active`…
        case none
        /// Równomiernie po całej skali.
        case linear
        /// Zagęszczenie przy dole skali — czasy obwiedni, FM, sprzężenia, Glide.
        case oneSided
        /// Zagęszczenie przy górze skali — poziomy OscDual i DrumSynth.
        case oneSidedInverse
        /// Zagęszczenie po obu stronach środka — strój, panorama, wzmocnienie EQ.
        case twoSided

        /// Czy losowanie idzie przez krzywą wykładniczą (2–4 oryginału), czy wprost.
        public var isExponential: Bool {
            switch self {
            case .none, .linear: false
            case .oneSided, .oneSidedInverse, .twoSided: true
            }
        }
    }

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Klasa parametru albo `nil`, gdy oryginalny edytor tego modułu nie zna
    /// (Driver, Resonator) — taki parametr zostaje nietknięty, bo oryginał też
    /// nie miałby czym go ruszyć.
    public static func of(moduleTypeID: Int, paramIndex: Int) -> G2ParamClass? {
        guard let classes = table[moduleTypeID], paramIndex < classes.count else { return nil }
        return G2ParamClass(rawValue: classes[paramIndex])
    }

    /// Górna granica skali parametru w oryginalnym edytorze (bajt +0x0B opisu) albo
    /// `nil`, gdy oryginał tego modułu nie zna.
    public static func maximum(moduleTypeID: Int, paramIndex: Int) -> Int? {
        guard let values = maxima[moduleTypeID], paramIndex < values.count else { return nil }
        return Int(values[paramIndex])
    }

    // MARK: Mutator

    /// Klasy, których mutator nie rusza — lista z Muta Synth Data (IsEnabled),
    /// ta sama w `CopyMutateContext` i `CopyRandomizeContext`.
    static let untouched: Set<UInt8> = [
        0x00, 0x08, 0x09, 0x0A, 0x14, 0x15, 0x18, 0x19, 0x1E, 0x1F, 0x20, 0x24, 0x2C, 0x31,
        0x32, 0x34, 0x37, 0x3B, 0x3D, 0x3E, 0x40, 0x45, 0x46, 0x48, 0x4A, 0x4B, 0x55, 0x5B,
        0x5D, 0x5E, 0x5F, 0x60, 0x63, 0x67, 0x6A, 0x6F, 0x70, 0x72, 0x74, 0x75, 0x7B, 0x7C,
        0x7D, 0x7E, 0x80, 0x81, 0x84, 0x85, 0x90, 0x91, 0x9F,
    ]
    /// `FreqCoarse` oscylatorów — jedyna klasa z wyjątkiem w Randomize (tryb Partials).
    static let oscillatorCoarse: UInt8 = 0x02
    /// `FreqMode` oscylatorów (Semi / Freq / Factor / Partial); wartość 3 = Partials.
    static let oscillatorFreqMode: UInt8 = 0x90
    static let partialsMode = 3

    static let twoSided: Set<UInt8> = [0x02, 0x03, 0x0C, 0x10, 0x25, 0x2D, 0x3F, 0x58, 0x79, 0x8A, 0x9B, 0x9C]
    static let oneSided: Set<UInt8> = [0x05, 0x0B, 0x0E, 0x27, 0x36, 0x49, 0x51, 0x52, 0x65, 0x76, 0x99]
    static let oneSidedInverse: Set<UInt8> = [0x0F]

    public var curve: Curve {
        if Self.untouched.contains(rawValue) { return .none }
        if Self.twoSided.contains(rawValue) { return .twoSided }
        if Self.oneSided.contains(rawValue) { return .oneSided }
        if Self.oneSidedInverse.contains(rawValue) { return .oneSidedInverse }
        return .linear
    }

    /// Kategoria Quick Lock z samej klasy — bez `Effects` i `Delays`, które oryginał
    /// rozpoznaje po typie modułu, zanim w ogóle spojrzy na klasę
    /// (`G2MutatorGenome.category(of:paramIndex:)`).
    ///
    /// Klasy 0x3A, 0x3C, 0x3F i 0x64 (poziomy mikserów, `Pan`, `Mix` fade'ów) zapalają
    /// w oryginale bit 0x04, który nie ma przycisku — w praktyce zachowują się jak
    /// parametry bez kategorii, więc dostają `nil`.
    public var category: G2MutatorCategory? {
        switch rawValue {
        case 0x02, 0x04, 0x4F, 0x50, 0x56, 0x57: .oscFreq
        case 0x03, 0x58: .oscFine
        case 0x0B, 0x0C, 0x0D, 0x0E, 0x10, 0x47, 0x49, 0x52, 0x9D, 0x9E: .envelope
        case 0x2F: .seqEvent
        case 0x30, 0x33: .seqValue
        default: nil
        }
    }

    // MARK: Adjuster

    /// Gałka Patch Adjustera — klasy z `CPatch::HandleParamChange`.
    public var adjusterKnob: G2AdjusterKnob? {
        switch rawValue {
        case 0x0B: .attack
        case 0x0C, 0x10: .decay
        case 0x0D: .sustain
        case 0x0E: .release
        case 0x16, 0x41, 0x88: .modRate
        case 0x05, 0x06, 0x11, 0x22, 0x8B: .timbre
        case 0x12, 0x87: .resonance
        case 0x29, 0x83: .effects
        default: nil
        }
    }
}
