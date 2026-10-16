// G2PatchAdjuster.swift
// Patch Adjuster — osiem gałek, które ruszają WSZYSTKIMI parametrami jednej kategorii
// naraz („wszystkie ataki", „wszystkie rezonanse"), względem tego, co w patchu już jest.
// Instrukcja Clavii, rozdział 8 (str. 113–114).
//
// Matematyka odpowiada 1:1 oryginalnemu edytorowi (`CPatch::ApplyDistribution(int, int)`
// i `CPatch::SetGlobal*Modifier`): gałka chodzi od −50 do +50, zero nic nie zmienia,
// dodatnia interpoluje wartość ku MAKSIMUM parametru, ujemna ku ZERU. Punktem odniesienia
// jest zawsze zdjęcie wartości sprzed ruszenia gałki (Module Param Data 11 w oryginale),
// więc powrót na środek przywraca patch co do bajtu.
//
// Które parametry siedzą pod którą gałką, mówi klasa parametru (`G2ParamClass.adjusterKnob`)
// — ta sama, która steruje krzywymi i kategoriami Quick Lock mutatora. Tabela w instrukcji
// (str. 113) opisuje to samo słowami → [[Docs/ui/patch-adjuster]].

import Foundation

// MARK: - Osiem gałek

/// Kategorie Patch Adjustera w kolejności z okna oryginału.
public enum G2AdjusterKnob: String, CaseIterable, Identifiable, Sendable {
    case attack
    case decay
    case sustain
    case release
    case modRate
    case timbre
    case resonance
    case effects

    public var id: String {
        rawValue
    }

    /// Podpis pod gałką — dokładnie jak w oknie oryginału.
    public var title: String {
        switch self {
        case .attack: "Attack"
        case .decay: "Decay"
        case .sustain: "Sustain"
        case .release: "Release"
        case .modRate: "Mod. Rate"
        case .timbre: "Timbre"
        case .resonance: "Resonance"
        case .effects: "Effects"
        }
    }

    /// Zdanie z instrukcji (str. 113) — w dymku nad gałką.
    public var summary: String {
        switch self {
        case .attack: "All envelope, compressor, noise gate and envelope follower Attack times"
        case .decay: "All envelope Decay times and the stage times of the multi-stage envelopes"
        case .sustain: "All envelope Sustain levels and the stage levels of the multi-stage envelopes"
        case .release: "All envelope, compressor, noise gate and envelope follower Release times"
        case .modRate: "All LFO and Random rates, and the rate of effects with an internal LFO"
        case .timbre: "Filter cutoffs, FM amounts and the waveshape parameters of oscillators and shapers"
        case .resonance: "All filter resonances, and Phaser and Flanger feedback"
        case .effects: "Dry/wet balance of the effect modules"
        }
    }
}

// MARK: - Parametr, który gałka rusza

/// Jeden parametr pod jedną gałką Adjustera, razem z górną granicą jego zakresu —
/// bez niej nie da się policzyć „ile brakuje do maksimum".
public struct G2AdjusterTarget: Sendable {
    public let area: PatchArea
    public let moduleID: Int
    public let paramIndex: Int
    public let maxValue: Int
    public let knob: G2AdjusterKnob

    public init(area: PatchArea, moduleID: Int, paramIndex: Int, maxValue: Int,
                knob: G2AdjusterKnob)
    {
        self.area = area
        self.moduleID = moduleID
        self.paramIndex = paramIndex
        self.maxValue = maxValue
        self.knob = knob
    }
}

// MARK: - Liczydło

public enum G2PatchAdjuster {
    /// Zakres gałki. `CPatch::ApplyDistribution` dzieli modyfikator przez 50, więc −50
    /// zbija parametr do zera, a +50 wypycha go na maksimum.
    public static let range = -50 ... 50

    /// Wartość parametru po ruchu gałką — wzór z `CPatch::ApplyDistribution`:
    ///
    /// * `modifier > 0` → `base + (max − base) · modifier/50` (w stronę maksimum),
    /// * `modifier < 0` → `base · (modifier + 50)/50` (w stronę zera),
    /// * `modifier == 0` → `base`.
    ///
    /// Oryginał obcina ułamek rzutowaniem na `int` (nie zaokrągla) i przycina wynik
    /// do `0…max` — tak samo tutaj.
    public static func adjusted(base: Int, maxValue: Int, modifier: Int) -> Int {
        guard modifier != 0 else { return min(max(0, base), maxValue) }
        let raw: Double = modifier > 0
            ? Double(base) + Double(maxValue - base) * Double(modifier) / 50.0
            : Double(base) * (Double(modifier + 50) / 50.0)
        return min(max(0, Int(raw)), maxValue)
    }

    /// Odwrotność `adjusted` — punkt odniesienia, który przy obecnym położeniu gałki
    /// dałby wartość `value`. Oryginał liczy to w `CPatch::HandleParamChange`, gdy ktoś
    /// **ręcznie** przestawi parametr przy odkręconej gałce: zdjęcie dostaje nową bazę,
    /// więc ruch gałki dalej liczy od tego, co użytkownik właśnie ustawił, a powrót
    /// na środek zostawia jego zmianę.
    ///
    /// * `modifier > 0` → `value − (max − value) · m/50 / (1 − m/50)`,
    /// * `modifier < 0` → `value / ((m + 50)/50)`,
    /// * `modifier == 0` → `value`.
    ///
    /// Na krańcach (±50) wzór dzieli przez zero — każda baza daje tam to samo, więc
    /// bazą zostaje sama wartość. Ułamek obcięty jak w `adjusted`, wynik w `0…max`.
    public static func base(value: Int, maxValue: Int, modifier: Int) -> Int {
        guard modifier != 0, abs(modifier) < 50 else { return min(max(0, value), maxValue) }
        let m = Double(modifier) / 50.0
        let raw: Double = modifier > 0
            ? Double(value) - Double(maxValue - value) * m / (1.0 - m)
            : Double(value) / (m + 1.0)
        return min(max(0, Int(raw)), maxValue)
    }

    /// Wszystkie parametry patcha, które któraś z ośmiu gałek rusza — oba obszary,
    /// moduły w kolejności numerów, jak Module Id Iterator oryginału.
    public static func targets(in patch: G2Patch) -> [G2AdjusterTarget] {
        var result: [G2AdjusterTarget] = []
        for area in [PatchArea.voice, PatchArea.fx] {
            for module in patch.modules(in: area).sorted(by: { $0.id < $1.id }) {
                for index in module.parameters.indices {
                    guard let knob = self.knob(module: module, paramIndex: index) else { continue }
                    // Baza zakresów trzyma wyłącznie WYJĄTKI; parametr ciągły, którego
                    // w niej nie ma, sięga 127 — ta sama reguła co w gałkach panelu
                    // stron parametrów (`knobMaxValue`) i w mutatorze.
                    let maxValue = ParameterRangeDatabase.range(
                        moduleTypeID: module.typeID, codeRef: index
                    )?.upperBound ?? 127
                    guard maxValue > 0 else { continue }
                    result.append(G2AdjusterTarget(area: area, moduleID: module.id,
                                                   paramIndex: index, maxValue: maxValue,
                                                   knob: knob))
                }
            }
        }
        return result
    }

    // MARK: Przypisanie parametru do gałki

    /// Gałka, pod którą siedzi parametr — z klasy parametru oryginalnego edytora.
    /// `ClkGen.Rate` nie ma klasy „rate" i słusznie: to tempo patcha (BPM) z własną
    /// kontrolką w górnej belce, a nie modulacja.
    public static func knob(moduleTypeID: Int, paramIndex: Int) -> G2AdjusterKnob? {
        G2ParamClass.of(moduleTypeID: moduleTypeID, paramIndex: paramIndex)?.adjusterKnob
    }

    /// Gałka dla parametru konkretnego modułu — jak wyżej, z jednym wyjątkiem, który
    /// oryginał robi w `ApplyDistribution`: czas `Release` modułu **EnvADR** jest „Decay"
    /// albo „Release" zależnie od przełącznika `DcyRel` (AD / AR), więc wędruje między
    /// gałkami Decay i Release razem z nim.
    public static func knob(module: G2Module, paramIndex: Int) -> G2AdjusterKnob? {
        if module.typeID == envADRTypeID, paramIndex == envADRDecayReleaseIndex,
           module.parameters.indices.contains(envADRModeIndex)
        {
            return module.parameters[envADRModeIndex] == 0 ? .decay : .release
        }
        return knob(moduleTypeID: module.typeID, paramIndex: paramIndex)
    }

    static let envADRTypeID = 84
    static let envADRDecayReleaseIndex = 3
    static let envADRModeIndex = 7
}
