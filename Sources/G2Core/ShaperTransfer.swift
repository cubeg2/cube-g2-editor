import Foundation

/// Znormalizowane charakterystyki ekranów modułów z grupy Shaper.
///
/// Oś wejścia i wyjścia ma zakres `-1...1`. Renderer odpowiada wyłącznie za
/// zamianę tych wartości na współrzędne ekranu i przycięcie do jego ramki.
public enum ShaperTransfer {
    /// GraphFunc 15 — port dwóch gałęzi Dist B Graph (Draw).
    public static func overdrive(input: Double, symmetric: Bool, drive: Int) -> Double {
        let x = max(-1, min(1, input))
        let amount = Double(max(0, min(127, drive))) / 127

        // Clavia przełącza konstrukcję przy Drive=1/16. Dolna gałąź jest
        // algebraicznie tą samą krzywą, tylko bez odcinków ograniczających.
        if amount <= 1.0 / 16.0 {
            return clamp(x - (256.0 / 3.0) * pow(amount, 3) * pow(x, 3))
        }

        let scaledInput = max(-1, min(1, 4 * amount * x))
        let scale = max(3.0 / 8.0, 1.0 / (16 * amount))
        var output = 4 * scale * (scaledInput - pow(scaledInput, 3) / 3)

        // Wybrany w domyślnym panelu stan Sym ma w oryginalnym wykresie
        // podniesione ujemne ograniczenie. To widoczny, celowy asymetryczny
        // detal Dist B Graph, a nie zwykłe obcięcie tej samej funkcji.
        if symmetric {
            output = max(output, max(-1, -1.2 + 0.7 * amount))
        }
        return clamp(output)
    }

    /// GraphFunc 38 — Shape B Graph (Draw).
    public static func exponential(input: Double, amount: Int, curve: Int) -> Double {
        let x = max(-1, min(1, input))
        let mix = Double(max(0, min(127, amount))) / 127
        let exponent = max(0, min(3, curve)) + 2
        let powered = x.sign == .minus
            ? -pow(abs(x), Double(exponent))
            : pow(x, Double(exponent))
        let shaped = pow(2, Double(exponent - 1)) * powered
        return x * (1 - mix) + shaped * mix
    }

    /// GraphFunc 39 — Saturate Graph (Draw) w dziedzinie widocznego ekranu.
    public static func saturate(input: Double, amount: Int, curve: Int) -> Double {
        let x = max(-1, min(1, input))
        let mix = Double(max(0, min(127, amount))) / 127
        let exponent = Double(max(0, min(3, curve)) + 2)
        let saturatedMagnitude = 1 - pow(1 - abs(x), exponent)
        let saturated = x.sign == .minus ? -saturatedMagnitude : saturatedMagnitude
        return x * (1 - mix) + saturated * mix
    }

    /// Liczba odcinków trójkąta na każdej połowie ekranu GraphFunc 16.
    public static func waveWrapFactor(amount: Int) -> Double {
        1 + Double(max(0, min(127, amount))) / 8
    }

    private static func clamp(_ value: Double) -> Double {
        max(-1, min(1, value))
    }
}
