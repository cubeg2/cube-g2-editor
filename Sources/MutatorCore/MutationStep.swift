// MutationStep.swift
// Pojedynczy krok mutacji jednej surowej wartości — wspólny dla wszystkich operatorów.
//
// Swoboda z `Mutability` mnoży wielkość kroku, więc zablokowany parametr (factor 0)
// nie drgnie nawet przy największej sile. Reguły zależne od rodzaju parametru
// (skala logarytmiczna, półtony, kategorie) dochodzą w kroku 3.5.

import Foundation

public enum MutationStep {
    /// Odchylenie standardowe kroku przy `magnitude == 1` i pełnej swobodzie,
    /// jako ułamek skali parametru.
    public static let fullScaleSigma = 0.25

    /// Gaussowskie drgnięcie w domenie surowej z odbiciem od krawędzi skali.
    public static func gaussian(raw: UInt8, maxRaw: UInt8, mutability: Mutability, magnitude: Double,
                                using rng: inout some RandomNumberGenerator) -> UInt8
    {
        guard !mutability.isLocked, magnitude > 0, maxRaw > 0 else { return raw }
        let sigma = fullScaleSigma * magnitude * mutability.factor * Double(maxRaw)
        let moved = Double(raw) + sigma * standardNormal(using: &rng)
        return UInt8(reflect(moved.rounded(), max: Double(maxRaw)))
    }

    /// Odbicie od 0 i od maksimum — jak Standard; wartość zawsze wraca do skali.
    static func reflect(_ value: Double, max: Double) -> Double {
        let period = 2 * max
        var folded = value.truncatingRemainder(dividingBy: period)
        if folded < 0 { folded += period }
        return folded > max ? period - folded : folded
    }

    /// Box–Muller; dwa losowania na wynik, żeby ciąg zależał tylko od ziarna.
    static func standardNormal(using rng: inout some RandomNumberGenerator) -> Double {
        let u1 = Double.random(in: Double.leastNonzeroMagnitude ..< 1, using: &rng)
        let u2 = Double.random(in: 0 ..< 1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
