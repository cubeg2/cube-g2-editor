import Foundation

/// Geometria ekranów filtrów odtworzona z Filter Graph ABC (Draw) (GraphFunc
/// 20/21/40 — FltClassic, FltNord, FltStatic).
///
/// Oryginał liczy wszystko na buforze `50×26` wewnątrz ramki `52×28`. Rezonans
/// nie skaluje całej charakterystyki: podnosi wyłącznie punkt kontrolny krzywej
/// Béziera przy częstotliwości granicznej, więc przy dużym `Res` powstaje
/// lokalny pik zamiast podniesienia całej linii. Osobny mnożnik
/// `resonanceScale` (Gain Compensation) przesuwa poziom całej linii i w
/// FltClassic jest stale wyłączony.
///
/// Renderer odpowiada wyłącznie za przeskalowanie tych punktów na ekran modułu
/// i przycięcie ich do ramki — dokładnie jak `fScratchPad` w oryginale.
public enum FilterGraphGeometry {
    // MARK: - Stałe źródłowe

    /// Szerokość ramki widoku (`CView::SetSize(0x34, 0x1c)`).
    public static let sourceWidth = 52.0
    /// Wysokość ramki widoku.
    public static let sourceHeight = 28.0
    /// Szerokość bufora po `CRect::Shrink(1)`.
    public static let innerWidth = 50.0
    /// Wysokość bufora po `CRect::Shrink(1)`.
    public static let innerHeight = 26.0

    /// Poziom 0 dB: `Int(Float(26 × 0.4) + 0.5)`.
    public static let baseline = 10.0
    /// Skala osi X: `50/128`.
    static let scaleX = innerWidth / 128.0
    /// Skala osi Y: `26/128`.
    static let scaleY = innerHeight / 128.0

    /// Typ charakterystyki. Wartości odpowiadają `this[0x87]` w oryginale,
    /// czyli indeksowi PartSelectora powiększonemu o jeden.
    public enum Kind: Int {
        case lowPass = 1
        case bandPass = 2
        case highPass = 3
        case bandReject = 4
    }

    /// Punkt w układzie bufora Clavii (`0…50` w poziomie, `0…26` w pionie).
    /// Wartości spoza tego zakresu są poprawne — oryginał przycina je ekranem.
    public struct SourcePoint: Equatable {
        public let x: Double
        public let y: Double

        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Jeden segment krzywej sześciennej odtworzonej z `BorderPolyBezier`.
    public struct Segment: Equatable {
        public let control1: SourcePoint
        public let control2: SourcePoint
        public let end: SourcePoint
    }

    /// Kompletny kształt jednego ekranu filtra.
    public struct Shape: Equatable {
        /// Punkt startowy krzywej (`pen` w oryginale).
        public let start: SourcePoint
        /// Odcinek prosty prowadzący do pierwszej krzywej — `BorderLineTo`.
        /// Typy `bandPass` i `bandReject` rysują wyłącznie krzywe.
        public let lineTo: SourcePoint?
        /// Segmenty Béziera w kolejności rysowania.
        public let segments: [Segment]
    }

    // MARK: - Konwersje liczbowe oryginału

    /// `(int)(x + 0.5)` — zaokrąglenie stosowane przy skalowaniu osi.
    /// Obcięcie idzie w stronę zera, więc `-11.22` daje `-11`, tak jak w C.
    static func rounded(_ value: Double) -> Double {
        Double(Int(value + 0.5))
    }

    /// `(int)x` — samo obcięcie, bez dodawania połowy. Oryginał używa go tam,
    /// gdzie wynik jest już całkowity; przy wartościach ujemnych różni się od
    /// `rounded`, dlatego rozróżnienie jest zachowane.
    static func truncated(_ value: Double) -> Double {
        Double(Int(value))
    }

    // MARK: - Geometria

    /// Odtwarza kształt ekranu dla podanych wartości zależności.
    ///
    /// - Parameters:
    ///   - frequency: surowa wartość `Freq` 0…127.
    ///   - resonance: surowa wartość `Res` 0…127.
    ///   - kind: typ charakterystyki.
    ///   - slope: nachylenie w dB/Oct (12, 18 albo 24) — w oryginale `this[0x88]`.
    ///   - resonanceScale: mnożnik podniesienia całej linii (Gain Compensation).
    ///     FltClassic przekazuje tu zawsze `0`.
    ///   - classicVariant: `true` dla FltClassic (`this[0x89] == 1`), które
    ///     skraca odcinek prowadzący i nie odejmuje nachylenia od uchwytów.
    ///   - active: `false` rysuje samą linię 0 dB.
    public static func shape(frequency: Int,
                             resonance: Int,
                             kind: Kind,
                             slope: Int,
                             resonanceScale: Int,
                             classicVariant: Bool,
                             active: Bool) -> Shape
    {
        let freq = Double(min(127, max(0, frequency)))
        let res = min(127, max(0, resonance))
        let slopeValue = max(0, slope)

        guard active else {
            return Shape(start: SourcePoint(0, baseline),
                         lineTo: SourcePoint(sourceWidth + 1.0, baseline),
                         segments: [])
        }

        // `local_8c` — pozycja częstotliwości granicznej w jednostkach parametru.
        let freqUnits = (freq / 127.0) * 107.0 + baseline
        // `dVar18` — podniesienie całej linii przez Gain Compensation.
        let resLift = rounded((Double(res) / 127.0) * Double(max(0, resonanceScale)) * baseline)
        // `this[0x85] / 0xc` — całkowitoliczbowe dzielenie przed zaokrągleniem.
        let resonancePeak = Double(res / 12)

        switch kind {
        case .lowPass:
            return lowPassShape(freqUnits: freqUnits, resLift: resLift,
                                resonancePeak: resonancePeak, slope: slopeValue,
                                classicVariant: classicVariant)
        case .bandPass:
            return bandPassShape(freqUnits: freqUnits, resLift: resLift,
                                 resonancePeak: resonancePeak, slope: slopeValue)
        case .highPass:
            return highPassShape(freqUnits: freqUnits, resLift: resLift,
                                 resonancePeak: resonancePeak, slope: slopeValue)
        case .bandReject:
            return bandRejectShape(freqUnits: freqUnits, resLift: resLift,
                                   resonance: res, slope: slopeValue)
        }
    }

    // MARK: - Typ 1: dolnoprzepustowy

    private static func lowPassShape(freqUnits: Double, resLift: Double,
                                     resonancePeak: Double, slope: Int,
                                     classicVariant: Bool) -> Shape
    {
        let halfRes = rounded(resLift * 0.5)
        let levelY = truncated(halfRes + baseline)
        let cutoffX = rounded((freqUnits - 49.0) * scaleX)

        let lineToX: Double
        let firstHandleX: Double
        let secondHandleX: Double
        if classicVariant {
            lineToX = cutoffX + 7
            firstHandleX = cutoffX + 15
            secondHandleX = cutoffX + 14
        } else {
            let halfSlope = Double(slope >> 1)
            let thirdSlope = Double(slope / 3)
            lineToX = cutoffX - halfSlope + 14
            firstHandleX = cutoffX - halfSlope + 24
            secondHandleX = cutoffX - thirdSlope + 20
        }

        let peakY = truncated(baseline - resonancePeak + halfRes)
        let quarterSlope = rounded(Double(slope) * 0.25)

        return Shape(
            start: SourcePoint(-1, levelY),
            lineTo: SourcePoint(lineToX, levelY),
            segments: [
                Segment(control1: SourcePoint(firstHandleX, levelY),
                        control2: SourcePoint(secondHandleX, levelY),
                        end: SourcePoint(cutoffX + 20, peakY)),
                Segment(control1: SourcePoint(cutoffX + 19 + quarterSlope, levelY),
                        control2: SourcePoint(cutoffX + 29,
                                              truncated(baseline + 5.0 + halfRes)),
                        end: SourcePoint(truncated(cutoffX + (sourceWidth + 1.0 - Double(slope))),
                                         truncated(halfRes + innerHeight))),
            ]
        )
    }

    // MARK: - Typ 3: górnoprzepustowy

    /// Oryginał liczy ten sam kształt co dolnoprzepustowy, ale odbija oś X
    /// względem szerokości ramki i startuje od prawej krawędzi.
    private static func highPassShape(freqUnits: Double, resLift: Double,
                                      resonancePeak: Double, slope: Int) -> Shape
    {
        let lift = rounded(resLift * 0.5)
        let levelY = truncated(baseline + lift)
        let cutoffX = rounded((90.0 - freqUnits) * scaleX)
        let halfSlope = Double(slope >> 1)
        let thirdSlope = Double(slope / 3)
        let quarterSlope = Double(slope >> 2)

        func mirrored(_ value: Double) -> Double {
            truncated(sourceWidth - value)
        }

        return Shape(
            start: SourcePoint(sourceWidth + 1.0, levelY),
            lineTo: SourcePoint(mirrored(cutoffX - halfSlope + 14), levelY),
            segments: [
                Segment(control1: SourcePoint(mirrored(cutoffX - halfSlope + 24), levelY),
                        control2: SourcePoint(mirrored(cutoffX - thirdSlope + 20), levelY),
                        end: SourcePoint(mirrored(cutoffX + 20),
                                         truncated(baseline - resonancePeak + lift))),
                Segment(control1: SourcePoint(mirrored(cutoffX + 19 + quarterSlope), levelY),
                        control2: SourcePoint(mirrored(cutoffX + 29),
                                              truncated(lift + baseline + 5.0)),
                        end: SourcePoint(mirrored(cutoffX + (sourceWidth + 1.0 - Double(slope))),
                                         truncated(lift + innerHeight))),
            ]
        )
    }

    // MARK: - Typ 2: pasmowoprzepustowy

    /// Jedyny typ rysowany w całości przez `BorderPolyBezier`: bez odcinka
    /// prostego, od lewego dołu przez pik przy `Freq` do prawego dołu.
    private static func bandPassShape(freqUnits: Double, resLift: Double,
                                      resonancePeak: Double, slope: Int) -> Shape
    {
        let leftX = rounded((90.0 - freqUnits) * scaleX)
        let halfRes = rounded(resLift * 0.5)
        let bottomY = truncated(halfRes + innerHeight)
        let midY = truncated(baseline + 5.0 + halfRes)
        let levelY = truncated(baseline + halfRes)
        let quarterSlope = Double(slope >> 2)
        let rightX = rounded((freqUnits - 49.0) * scaleX)
        let tail = sourceWidth + 1.0 - Double(slope)

        return Shape(
            start: SourcePoint(truncated(sourceWidth - (leftX + tail) - baseline), bottomY),
            lineTo: nil,
            segments: [
                Segment(control1: SourcePoint(truncated(sourceWidth - (leftX + 29) - baseline), midY),
                        control2: SourcePoint(truncated(sourceWidth - (leftX + 19 + quarterSlope)),
                                              levelY),
                        end: SourcePoint(rightX + 20,
                                         truncated(halfRes + baseline - resonancePeak))),
                Segment(control1: SourcePoint(rightX + 19 + quarterSlope, levelY),
                        control2: SourcePoint(rightX + 39, midY),
                        end: SourcePoint(truncated(tail + rightX + baseline), bottomY)),
            ]
        )
    }

    // MARK: - Typ 4: pasmowozaporowy

    /// Notch: dwie proste na poziomie linii i zjazd do dna, którego głębokość
    /// zależy od nachylenia, a szerokość od rezonansu.
    private static func bandRejectShape(freqUnits: Double, resLift: Double,
                                        resonance: Int, slope: Int) -> Shape
    {
        let levelY = truncated(baseline + rounded(resLift * 0.25))
        let leftX = rounded((freqUnits - (3.0 + sourceWidth)) * scaleX)
        let notchWidth = rounded(Double((resonance >> 2) + 30) * scaleX)
        let centerX = rounded(freqUnits * scaleX)
        let rightX = rounded((freqUnits + 60.0) * scaleX)

        // `sVar3` zachowuje tu wysokość ramki sprzed `Shrink`, więc dno notcha
        // wypada poniżej bufora i jest przycinane przez ekran.
        let notchBottomY = truncated(rounded(Double(slope * 2 - 24) * scaleY) + sourceHeight)
        let notchHandleY = notchBottomY - rounded(scaleY * 30.0)

        let start = SourcePoint(rounded(scaleX * -30.0), levelY)
        let leftShoulder = SourcePoint(leftX, levelY)
        let rightShoulder = SourcePoint(rightX, levelY)

        return Shape(
            start: start,
            lineTo: nil,
            segments: [
                Segment(control1: start, control2: start, end: leftShoulder),
                Segment(control1: SourcePoint(leftX + notchWidth, levelY),
                        control2: SourcePoint(centerX, notchHandleY),
                        end: SourcePoint(centerX, notchBottomY)),
                Segment(control1: SourcePoint(centerX, notchHandleY),
                        control2: SourcePoint(rightX - notchWidth, levelY),
                        end: rightShoulder),
                Segment(control1: rightShoulder, control2: rightShoulder,
                        end: SourcePoint(rounded(scaleX * 158.0), levelY)),
            ]
        )
    }
}
