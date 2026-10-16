import Foundation

/// Geometria ekranów korektorów odtworzona z trzech klas Clavii:
/// Eq Mid Graph (GraphFunc 10 — EqPeak), Eq Hi Lo Graph (36 — Eq2Band)
/// i Eq Hi Mid Lo Graph (37 — Eq3Band).
///
/// Wszystkie trzy rysują krzywe Béziera na buforze `50×26` i mają linię 0 dB
/// dokładnie pośrodku (`Int((28 − 2) × 0,5 + 0,5) = 13`), a nie na 1/3 jak
/// wykresy filtrów. Punkty kontrolne leżą na poziomie sąsiedniego odcinka,
/// więc **wierzchołek pasma środkowego jest ostry** — styczne po obu jego
/// stronach nie są współliniowe. Wcześniejsze przybliżenie gaussowskie dawało
/// w tym miejscu łagodne zaokrąglenie.
///
/// Częstotliwości półek nie są zależnościami `GraphFunc` w żadnej z tych klas:
/// punkty załamania są stałe, a parametry zmieniają wyłącznie wysokości.
public enum EqGraphGeometry {
    // MARK: - Stałe źródłowe

    /// Szerokość ramki widoku (`CView::SetSize(0x34, 0x1c)`).
    public static let sourceWidth = 52.0
    /// Wysokość ramki widoku.
    public static let sourceHeight = 28.0
    /// Szerokość bufora po `CRect::Shrink(1)`.
    public static let innerWidth = 50.0
    /// Wysokość bufora po `CRect::Shrink(1)`.
    public static let innerHeight = 26.0

    /// Poziom 0 dB pośrodku ekranu: `Int((28 − 2) × 0,5 + 0,5)`.
    public static let baseline = 13.0
    /// Przelicznik wzmocnienia: `(28 − 2) × 0,45 × 0,015625`.
    static let gainScale = (sourceHeight - 2.0) * 0.45 * 0.015625
    /// Środek skali wzmocnienia — wartość `0x40`.
    static let gainCenter = 64.0

    public typealias SourcePoint = FilterGraphGeometry.SourcePoint
    public typealias Segment = FilterGraphGeometry.Segment

    /// Pojedynczy krok ścieżki. Oryginał przeplata `BorderLineTo`
    /// i `BorderPolyBezierTo`, więc kolejność kroków jest istotna.
    public enum Element: Equatable {
        case line(SourcePoint)
        case curve(Segment)
    }

    /// Kształt ekranu korektora: odcinki proste i krzywe w kolejności rysowania.
    public struct Shape: Equatable {
        public let start: SourcePoint
        public let elements: [Element]

        /// Ostatni punkt ścieżki — potrzebny do domknięcia wypełnienia.
        public var end: SourcePoint {
            switch elements.last {
            case let .line(point): point
            case let .curve(segment): segment.end
            case nil: start
            }
        }
    }

    static func rounded(_ value: Double) -> Double {
        FilterGraphGeometry.rounded(value)
    }

    static func truncated(_ value: Double) -> Double {
        FilterGraphGeometry.truncated(value)
    }

    /// Zamiana surowego wzmocnienia 0…127 na wysokość w buforze.
    static func level(_ gain: Int) -> Double {
        rounded(baseline - Double(min(127, max(0, gain)) - Int(gainCenter)) * gainScale)
    }

    // MARK: - GraphFunc 10 — EqPeak

    /// Eq Mid Graph (Draw). Pasmo dzwonowe zbudowane z dwóch krzywych,
    /// których wszystkie punkty kontrolne leżą na linii 0 dB.
    ///
    /// - Parameters:
    ///   - frequency: surowe `Freq` 0…127.
    ///   - gain: surowe `Gain` 0…127, bipolarne wokół 64.
    ///   - bandwidth: surowe `BW`; oryginał używa `|BW − 127|`, więc szerokość
    ///     pasma rośnie w miarę oddalania się od górnego krańca skali.
    public static func peak(frequency: Int, gain: Int, bandwidth: Int) -> Shape {
        // Skala osi X liczona od szerokości pomniejszonej o 6.
        let scaleX = (sourceWidth - 6.0) * 0.0078125
        let centerX = Double(min(127, max(0, frequency))) * scaleX + 2.0
        let span = scaleX * Double(abs(min(127, max(0, bandwidth)) - 127))

        let center = rounded(centerX)
        let leftX = rounded((centerX + span * -0.7) - 4.0)
        let rightX = rounded(span * 0.7 + centerX + 4.0)
        // Dzielenie przez dwa jest całkowitoliczbowe, tak jak w oryginale.
        let midLeft = rounded(leftX + truncated((center - leftX) / 2.0))
        let midRight = rounded(center + truncated((rightX - center) / 2.0))
        let peakY = level(gain)

        return Shape(
            start: SourcePoint(-1, baseline),
            elements: [
                .line(SourcePoint(leftX, baseline)),
                .curve(Segment(control1: SourcePoint(midLeft, baseline),
                               control2: SourcePoint(midLeft, baseline),
                               end: SourcePoint(center, peakY))),
                .curve(Segment(control1: SourcePoint(midRight, baseline),
                               control2: SourcePoint(midRight, baseline),
                               end: SourcePoint(rightX, baseline))),
                .line(SourcePoint(sourceWidth, baseline)),
            ]
        )
    }

    // MARK: - GraphFunc 36 — Eq2Band

    /// Eq Hi Lo Graph (Draw). Dwie niezależne półki o stałych punktach
    /// załamania; zależnościami są wyłącznie oba wzmocnienia.
    public static func twoBand(lowGain: Int, highGain: Int) -> Shape {
        let scaleX = ((sourceWidth - 2.0) - 20.0) * 0.0078125
        let lowCurve = scaleX * 25.0 + 10.0
        let highCurve = scaleX * 100.0 + 10.0

        let lowKnee = rounded(lowCurve)
        let highKnee = rounded(highCurve)
        let lowY = level(lowGain)
        let highY = level(highGain)
        let lowHandle = rounded(lowKnee - 8.0)
        let highHandle = rounded(highKnee + 8.0)

        return Shape(
            start: SourcePoint(-1, lowY),
            elements: [
                .line(SourcePoint(rounded(lowCurve - 16.0), lowY)),
                .curve(Segment(control1: SourcePoint(lowHandle, lowY),
                               control2: SourcePoint(lowHandle, baseline),
                               end: SourcePoint(lowKnee, baseline))),
                .line(SourcePoint(highKnee, baseline)),
                .curve(Segment(control1: SourcePoint(highHandle, baseline),
                               control2: SourcePoint(highHandle, highY),
                               end: SourcePoint(rounded(highCurve + 16.0), highY))),
                .line(SourcePoint(sourceWidth, highY)),
            ]
        )
    }

    // MARK: - GraphFunc 37 — Eq3Band

    /// Eq Hi Mid Lo Graph (Draw). Dwie półki i przesuwane pasmo środkowe.
    ///
    /// Pasmo środkowe sięga półek tylko na krańcach swojej skali: poniżej
    /// `Freq = 40` unosi lewą stronę, powyżej `Freq = 96` prawą. Pomiędzy tymi
    /// progami obie strony wracają na linię 0 dB.
    public static func threeBand(lowGain: Int, midGain: Int,
                                 midFrequency: Int, highGain: Int) -> Shape
    {
        let scaleX = ((sourceWidth - 2.0) - 20.0) * 0.0078125
        let lowCurve = scaleX * 10.0 + 10.0
        let highCurve = scaleX * 117.0 + 10.0
        let lowKnee = rounded(lowCurve)
        let highKnee = rounded(highCurve)

        let freq = min(127, max(0, midFrequency))
        let mid = min(127, max(0, midGain)) - Int(gainCenter)

        // Lewa i prawa strona pasma środkowego stykają się z półkami dopiero
        // przy skrajnych ustawieniach `Freq`; poza nimi zostają na 0 dB.
        var leftShoulder = baseline
        if freq < 40 {
            leftShoulder = rounded(baseline
                - (Double(freq) / -40.0 + 1.0) * Double(mid) * gainScale)
        }
        var rightShoulder = baseline
        if freq > 96 {
            rightShoulder = rounded(baseline
                - (Double(freq - 97) / 30.0) * Double(mid) * gainScale)
        }

        let midX = truncated(lowKnee + (highKnee - lowKnee) * (Double(freq) / 127.0))
        let midY = truncated(baseline - Double(mid) * gainScale + 0.5)
        let lowY = level(lowGain)
        let highY = level(highGain)

        var elements: [Element] = [
            .line(SourcePoint(rounded(lowCurve - 10.0), lowY)),
            .curve(Segment(control1: SourcePoint(rounded(lowKnee - 5.0), lowY),
                           control2: SourcePoint(rounded(lowKnee - 5.0), baseline),
                           end: SourcePoint(lowKnee, leftShoulder))),
        ]

        if lowKnee < midX {
            let handle: Double
            // Gdy lewa strona leży na 0 dB, a pasmo jest dostatecznie daleko,
            // oryginał dorysowuje najpierw prosty odcinek wzdłuż linii.
            if leftShoulder != baseline || midX - 12 <= lowKnee {
                handle = rounded(lowKnee + truncated((midX - lowKnee) / 2.0))
            } else {
                elements.append(.line(SourcePoint(midX - 12, baseline)))
                handle = midX - 6
            }
            elements.append(.curve(Segment(
                control1: SourcePoint(handle, leftShoulder),
                control2: SourcePoint(handle, leftShoulder),
                end: SourcePoint(midX, midY)
            )))
        }

        if midX < highKnee {
            let handle: Double
            let endX: Double
            if rightShoulder != baseline || highKnee <= midX + 12 {
                handle = rounded(midX + truncated((highKnee - midX) / 2.0))
                endX = highKnee
            } else {
                handle = midX + 6
                endX = midX + 12
            }
            elements.append(.curve(Segment(
                control1: SourcePoint(handle, rightShoulder),
                control2: SourcePoint(handle, rightShoulder),
                end: SourcePoint(endX, rightShoulder)
            )))
            if rightShoulder == baseline, midX + 12 < highKnee {
                elements.append(.line(SourcePoint(midX + 12, baseline)))
            }
        }

        elements.append(.line(SourcePoint(highKnee, rightShoulder)))
        elements.append(.curve(Segment(
            control1: SourcePoint(rounded(highKnee + 5.0), baseline),
            control2: SourcePoint(rounded(highKnee + 5.0), highY),
            end: SourcePoint(rounded(highCurve + 10.0), highY)
        )))
        elements.append(.line(SourcePoint(sourceWidth, highY)))

        return Shape(start: SourcePoint(-1, lowY), elements: elements)
    }
}
