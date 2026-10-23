// G2ValueEntry.swift
// Wartość wpisana z klawiatury („0.5 s", „1.2k", „Off") → pozycja gałki.
//
// Nie odwracamy funkcji tekstu parametru — przechodzimy po wszystkich pozycjach gałki,
// formatujemy każdą tak samo jak kanwa i bierzemy tę, której tekst leży najbliżej
// wpisanego. Wynik zawsze zgadza się więc z tym, co widać na module. Życzenie z forum
// electro-music, wątek 6195.

import Foundation

public enum G2ValueEntry {
    /// Pozycja gałki z `range`, która najlepiej odpowiada wpisanemu tekstowi.
    ///
    /// - `(64)` — surowa pozycja, tak jak pokazuje ją dymek gałki.
    /// - Tekst identyczny z napisem którejś pozycji (bez spacji i wielkości liter) — ta pozycja.
    /// - Liczba z jednostką — najbliższa pozycja w tej samej jednostce („500ms" trafi w „0.5s").
    /// - Sama liczba — w jednostce, którą gałka pokazuje teraz (`current`).
    ///
    /// `nil`, gdy tekst nie pasuje do niczego.
    public static func value(for input: String, current: Int, in range: ClosedRange<Int>,
                             text: (Int) -> String) -> Int?
    {
        let typed = input.trimmingCharacters(in: .whitespaces)
        if typed.hasPrefix("("), typed.hasSuffix(")"),
           let raw = Int(typed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces))
        {
            return min(range.upperBound, max(range.lowerBound, raw))
        }

        let texts = range.map { (value: $0, text: text($0)) }
        let key = compact(typed)
        if let exact = texts.first(where: { compact($0.text) == key }) {
            return exact.value
        }

        guard var wanted = Reading(typed) else { return nil }
        if wanted.unit == .none, let shown = Reading(text(current)) {
            wanted = Reading(number: wanted.number * shown.scale, unit: shown.unit, scale: shown.scale)
        }
        var best: (value: Int, distance: Double)?
        for candidate in texts {
            guard let reading = Reading(candidate.text), reading.unit == wanted.unit else { continue }
            let distance = abs(reading.number - wanted.number)
            if distance < best?.distance ?? .infinity { best = (candidate.value, distance) }
        }
        return best?.value
    }

    private static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }

    /// Rodzaj jednostki — porównujemy tylko pozycje tego samego rodzaju.
    private enum Unit: Equatable {
        case none, time, frequency, other(String)
    }

    /// Liczba z tekstu w jednostce podstawowej (sekundy, herce) i rodzaj tej jednostki.
    /// Liczy się pierwsza liczba: oscylator pisze „-12  +0" (półtony i odstrojenie).
    private struct Reading {
        let number: Double
        let unit: Unit
        /// Mnożnik, którym napis przeszedł na jednostkę podstawową („m" = 0.001).
        let scale: Double

        init(number: Double, unit: Unit, scale: Double) {
            self.number = number
            self.unit = unit
            self.scale = scale
        }

        init?(_ text: String) {
            let pattern = #"([-+]?\d*\.?\d+)\s*([A-Za-z%]*)"#
            guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
            let found = String(text[match])
            let digits = found.prefix { "+-.0123456789".contains($0) }
            guard let number = Double(digits) else { return nil }
            let suffix = found.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
            // Wyświetlacze modułów piszą milisekundy jako „m", a kiloherce jako „k" albo „kHz".
            let (unit, scale): (Unit, Double) = switch suffix {
            case "": (.none, 1)
            case "m", "ms": (.time, 0.001)
            case "s": (.time, 1)
            case "hz": (.frequency, 1)
            case "k", "khz": (.frequency, 1000)
            default: (.other(suffix), 1)
            }
            self.init(number: number * scale, unit: unit, scale: scale)
        }
    }
}
