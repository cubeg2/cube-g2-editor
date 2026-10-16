// ParameterTarget.swift
// Cel, na którym pracuje silnik mutacji — abstrakcja zamiast G2.
//
// `MutatorCore` nie zna patcha, kabli ani USB. Widzi tylko zbiór adresów parametrów
// z wartościami 0…maksimum i umie je odczytać albo zapisać w warstwie (wariacji).
// G2 jest pierwszą implementacją (`G2Adapter`, Etap 4); druga — generyczny cel
// MIDI CC albo host DAW — ma móc powstać bez zmiany silnika
// → Docs/mutator/plan-architecture §3.

/// Adres jednego parametru celu. Trzy bajty wystarczają G2 (obszar, moduł, parametr)
/// i celom MIDI (kanał, kontroler).
public struct ParameterAddress: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    /// Obszar celu — w G2: 0 = FX, 1 = VA, 2 = ustawienia patcha.
    public var area: UInt8
    public var module: UInt8
    public var parameter: UInt8

    public init(area: UInt8, module: UInt8, parameter: UInt8) {
        self.area = area
        self.module = module
        self.parameter = parameter
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.area, lhs.module, lhs.parameter) < (rhs.area, rhs.module, rhs.parameter)
    }

    public var description: String {
        "\(area):\(module):\(parameter)"
    }
}

/// Jak parametr zachowuje się przy mutacji — reguły w Docs/mutator/plan-engine §5.
public enum ParameterKind: String, Codable, Sendable, CaseIterable {
    /// Gauss w domenie surowej.
    case continuousLinear
    /// Jak liniowy, ale środek skali jest wartością neutralną (panorama, fine, wzmocnienie EQ).
    case bipolar
    /// Gauss w domenie logarytmicznej (FM, sprzężenia).
    case continuousLog
    /// Czasy — też w domenie logarytmicznej.
    case timeMs
    /// Krok w półtonach, zawsze na siatce.
    case pitchSemitone
    /// Krok o pozycje w siatce podziałów rytmicznych, nie ciągły.
    case syncedDivision
    /// Jak liniowy, z hamulcem przy samooscylacji.
    case resonance
    /// Poziom głośności (miksery) — liniowy; osobny rodzaj dla ankera głośności.
    case level
    /// Skok do innej wartości, nigdy średnia (fale, typy filtra, selektory).
    case categorical
    /// Przełącznik — flip z bardzo małym prawdopodobieństwem.
    case boolean
    /// Krok sekwencera — operatory wzorców, nie gauss per krok.
    case sequencerStep
}

/// Grupa brzmieniowa — osobna waga w sekcji Profile & Groups.
public enum SemanticGroup: String, Codable, Sendable, CaseIterable {
    case pitch, timbre, envelope, motion, space
}

/// Co silnik wie o parametrze.
public struct ParameterSemantics: Hashable, Codable, Sendable {
    /// Największa wartość surowa (0…`maxRaw`). W G2 wiele parametrów ma mniej niż 127.
    public var maxRaw: UInt8
    public var kind: ParameterKind
    /// `nil` = parametr poza grupami (wagi grup go nie ruszają).
    public var group: SemanticGroup?
    /// Waga w metryce różnic: jak mocno słychać zmianę (filtr ~3, fine ~0,4).
    public var weight: Double
    /// Parametr, którego ruszanie psuje patch — domyślnie zablokowany.
    public var critical: Bool

    /// Bezpieczny domyślny opis dla parametru bez ręcznej semantyki: liniowy, waga 0,5,
    /// wolno ruszać — lepiej mutować przeciętnie niż blokować cały Mutator.
    public init(maxRaw: UInt8, kind: ParameterKind = .continuousLinear, group: SemanticGroup? = nil,
                weight: Double = 0.5, critical: Bool = false)
    {
        self.maxRaw = maxRaw
        self.kind = kind
        self.group = group
        self.weight = weight
        self.critical = critical
    }
}

/// Cel mutacji. Zapis dostaje wyłącznie różnice — nigdy cały stan.
///
/// Analiza słyszalności (`graph` w planie) dojdzie razem z `AudibilityMap` w kroku 4.2;
/// dziś nie ma jej kto używać.
public protocol ParameterTarget: AnyObject, Sendable {
    var fingerprint: TargetFingerprint { get }
    var space: [ParameterAddress: ParameterSemantics] { get }
    func snapshot(layer: UInt8) async throws -> [ParameterAddress: UInt8]
    func write(_ diff: [ParameterAddress: UInt8], layer: UInt8) async throws
}
