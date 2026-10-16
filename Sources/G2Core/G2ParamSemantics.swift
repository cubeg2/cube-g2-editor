// G2ParamSemantics.swift
// Klasa parametru G2 → semantyka silnika `MutatorCore` (rodzaj, grupa, waga, „nie ruszać").
//
// To rozszerzenie tej samej funkcji co krzywe Standardu, kategorie Quick Locks i gałki
// Patch Adjustera: wszystkie cztery czytają klasę parametru, żadne nie trzyma
// własnej listy nazw → Docs/mutator/plan-architecture §12.
//
// Semantyka powstaje LENIWIE. Ręcznie opisane są klasy modułów z §12 (OscA/B, FltLP,
// FltMulti, FltNord, EnvADSR/AHD, LFO, Mix4-1B, DlySingle) i klasy, które dzielą
// z nimi inne moduły; każda pozostała klasa dostaje bezpieczny domyślny opis
// (liniowy, waga 0,5, wolno ruszać). Wagi ustawione raz, ręcznie, uchem — orientacyjnie
// z §7: filtr ~3, fala ~2,5, FM ~2, poziom ~1,5, panorama ~0,8, fine ~0,4.

import MutatorCore

public extension G2ParamClass {
    /// Semantyka parametru z klasą `self` i zakresem 0…`maxRaw`.
    func semantics(maxRaw: UInt8) -> ParameterSemantics {
        // Klasy, których Standard nie rusza, są „krytyczne" także dla silnika.
        if curve == .none {
            return ParameterSemantics(maxRaw: maxRaw, kind: maxRaw <= 1 ? .boolean : .categorical,
                                      weight: 0, critical: true)
        }
        let (kind, group, weight) = Self.described[rawValue] ?? (.continuousLinear, nil, 0.5)
        return ParameterSemantics(maxRaw: maxRaw, kind: kind, group: group, weight: weight)
    }

    /// Grupa brzmieniowa z ręcznego opisu klasy; `nil` dla klas bez opisu.
    var describedGroup: SemanticGroup? {
        Self.described[rawValue]?.1
    }

    /// Semantyka parametru modułu. `nil`, gdy oryginalny edytor modułu nie zna.
    static func semantics(moduleTypeID: Int, paramIndex: Int, maxRaw: UInt8) -> ParameterSemantics? {
        of(moduleTypeID: moduleTypeID, paramIndex: paramIndex)?.semantics(maxRaw: maxRaw)
    }

    private static let described: [UInt8: (ParameterKind, SemanticGroup?, Double)] = [
        // Oscylatory
        0x01: (.categorical, .timbre, 2.5), // Waveform
        0x02: (.pitchSemitone, .pitch, 2.0), // FreqCoarse
        0x03: (.bipolar, .pitch, 0.4), // FreqFine
        0x04: (.continuousLinear, .pitch, 1.0), // PitchMod
        0x05: (.continuousLog, .timbre, 2.0), // FmAmount, FltNord.FM_Lin
        0x06: (.continuousLinear, .timbre, 1.5), // Shape
        0x07: (.continuousLinear, .timbre, 1.0), // ShapeMod
        // Obwiednie
        0x0B: (.timeMs, .envelope, 1.5), // Attack
        0x0C: (.timeMs, .envelope, 1.5), // Decay
        0x0D: (.continuousLinear, .envelope, 1.2), // Sustain
        0x0E: (.timeMs, .envelope, 1.5), // Release
        0x47: (.categorical, .envelope, 0.8), // Shape (kształt segmentów)
        0x49: (.timeMs, .envelope, 1.2), // Hold
        // Filtry
        0x11: (.continuousLinear, .timbre, 3.0), // Freq
        0x12: (.resonance, .timbre, 2.0), // Res
        0x1B: (.categorical, .timbre, 1.5), // Slope
        0x1C: (.continuousLinear, .timbre, 1.0), // PitchMod / FreqMod
        0x1D: (.continuousLinear, .timbre, 0.8), // ResMod
        0x8F: (.categorical, .timbre, 2.5), // FilterType
        // LFO
        0x41: (.continuousLinear, .motion, 1.5), // Rate
        0x42: (.categorical, .motion, 1.5), // Waveform
        0x43: (.continuousLinear, .motion, 1.0), // RateMod
        0x4D: (.continuousLinear, .motion, 0.8), // Phase
        0x96: (.continuousLinear, .motion, 0.8), // PhaseMod, ShapeMod
        // Miksery
        0x3A: (.level, .timbre, 1.5), // Lev1…Lev8
        0x3F: (.bipolar, .space, 0.8), // Pan
        // Opóźnienia
        0x26: (.timeMs, .space, 1.5), // Time
        0x27: (.continuousLog, .space, 1.5), // FB
        0x28: (.continuousLinear, .motion, 0.8), // TimeMod
        0x29: (.continuousLinear, .space, 1.5), // DryWet
    ]
}
