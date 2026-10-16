@testable import G2Core
import XCTest

/// Regresja geometrii Filter Graph ABC (Draw) (GraphFunc 20/21/40).
/// Wartości oczekiwane pochodzą z podstawienia stałych
/// oryginalnego edytora Clavii, a nie z dopasowania do obrazu.
final class FilterGraphGeometryTests: XCTestCase {
    private func lowPass(frequency: Int, resonance: Int, slope: Int = 12,
                         resonanceScale: Int = 0, classicVariant: Bool = true)
        -> FilterGraphGeometry.Shape
    {
        FilterGraphGeometry.shape(frequency: frequency, resonance: resonance,
                                  kind: .lowPass, slope: slope,
                                  resonanceScale: resonanceScale,
                                  classicVariant: classicVariant, active: true)
    }

    // MARK: - Stałe źródłowe

    func testSourceGridMatchesShrunkViewRect() {
        XCTAssertEqual(FilterGraphGeometry.sourceWidth, 52)
        XCTAssertEqual(FilterGraphGeometry.sourceHeight, 28)
        XCTAssertEqual(FilterGraphGeometry.innerWidth, 50)
        XCTAssertEqual(FilterGraphGeometry.innerHeight, 26)
        // Int(Float(26 × 0.4) + 0.5) = 10
        XCTAssertEqual(FilterGraphGeometry.baseline, 10)
    }

    /// Obcięcie w stronę zera, tak jak `(int)` w C — kluczowe dla punktów o
    /// ujemnym X, które oryginał wypuszcza poza lewą krawędź bufora.
    func testRoundingMatchesClaviaForNegativeValues() {
        XCTAssertEqual(FilterGraphGeometry.rounded(-11.71875), -11)
        XCTAssertEqual(FilterGraphGeometry.rounded(10.4), 10)
        XCTAssertEqual(FilterGraphGeometry.truncated(-11.0), -11)
        XCTAssertEqual(FilterGraphGeometry.truncated(15.9), 15)
    }

    // MARK: - Rezonans jako lokalny pik

    /// Sedno naprawy: przy `resonanceScale = 0` (FltClassic) poziom linii musi
    /// zostać na 0 dB, a rosnący `Res` może podnosić wyłącznie punkt kontrolny.
    func testResonanceRaisesOnlyLocalPeakNotWholeLine() {
        let quiet = lowPass(frequency: 64, resonance: 0)
        let loud = lowPass(frequency: 64, resonance: 127)

        XCTAssertEqual(quiet.lineTo?.y, FilterGraphGeometry.baseline)
        XCTAssertEqual(loud.lineTo?.y, FilterGraphGeometry.baseline,
                       "Res nie może podnosić poziomu linii przy wyłączonym GC")

        let quietPeak = quiet.segments[0].end.y
        let loudPeak = loud.segments[0].end.y
        XCTAssertEqual(quietPeak, FilterGraphGeometry.baseline)
        // Res=127 → 127/12 = 10 (dzielenie całkowite) → pik na 10 − 10 = 0.
        XCTAssertEqual(loudPeak, 0)
        XCTAssertLessThan(loudPeak, quietPeak, "większy Res = wyżej na ekranie")
    }

    /// Pik rośnie skokowo co 12 jednostek `Res`, bo oryginał dzieli całkowicie.
    func testResonancePeakUsesIntegerDivisionByTwelve() {
        XCTAssertEqual(lowPass(frequency: 64, resonance: 11).segments[0].end.y, 10)
        XCTAssertEqual(lowPass(frequency: 64, resonance: 12).segments[0].end.y, 9)
        XCTAssertEqual(lowPass(frequency: 64, resonance: 23).segments[0].end.y, 9)
        XCTAssertEqual(lowPass(frequency: 64, resonance: 24).segments[0].end.y, 8)
    }

    /// Gain Compensation to osobny mechanizm: podnosi poziom całej linii.
    func testGainCompensationLiftsWholeLine() {
        let off = lowPass(frequency: 64, resonance: 127, resonanceScale: 0,
                          classicVariant: false)
        let on = lowPass(frequency: 64, resonance: 127, resonanceScale: 1,
                         classicVariant: false)
        XCTAssertEqual(off.start.y, FilterGraphGeometry.baseline)
        // Int((127/127) × 1 × 10 + 0.5) = 10 → połowa = 5 → poziom 10 + 5.
        XCTAssertEqual(on.start.y, 15)
        XCTAssertEqual(on.lineTo?.y, 15)
    }

    // MARK: - Oś częstotliwości

    /// `local_8c = 10 + 107·Freq/127`, przeskalowane przez 50/128.
    func testCutoffFollowsSourceFrequencyAxis() {
        let low = lowPass(frequency: 0, resonance: 0)
        let high = lowPass(frequency: 127, resonance: 0)
        // Freq=0 → (10 − 49) × 0.390625 = −15.234 → Int(−14.734) = −14 → +20.
        XCTAssertEqual(low.segments[0].end.x, 6)
        // Freq=127 → (117 − 49) × 0.390625 = 26.5625 → Int(27.0625) = 27 → +20.
        XCTAssertEqual(high.segments[0].end.x, 47)
        XCTAssertLessThan(low.segments[0].end.x, high.segments[0].end.x)
    }

    func testCutoffIsMonotonicAcrossFullRange() {
        var previous = -Double.infinity
        for value in stride(from: 0, through: 127, by: 1) {
            let x = lowPass(frequency: value, resonance: 64).segments[0].end.x
            XCTAssertGreaterThanOrEqual(x, previous, "oś Freq nie może się cofać")
            previous = x
        }
    }

    // MARK: - Warianty i typy

    /// FltClassic skraca uchwyty; FltNord/FltStatic odejmują od nich nachylenie.
    func testClassicVariantUsesShorterLeadIn() {
        let classic = lowPass(frequency: 64, resonance: 0, slope: 24,
                              classicVariant: true)
        let normal = lowPass(frequency: 64, resonance: 0, slope: 24,
                             classicVariant: false)
        let cutoff = classic.segments[0].end.x - 20
        XCTAssertEqual(classic.lineTo?.x, cutoff + 7)
        // 24 dB/Oct → 24 >> 1 = 12 → cutoff − 12 + 14.
        XCTAssertEqual(normal.lineTo?.x, cutoff + 2)
    }

    /// Nachylenie zmienia kształt zbocza, a nie tylko podpis na ekranie.
    func testSlopeChangesTailOfLowPass() {
        let shallow = lowPass(frequency: 64, resonance: 0, slope: 12)
        let steep = lowPass(frequency: 64, resonance: 0, slope: 24)
        XCTAssertNotEqual(shallow.segments[1].end.x, steep.segments[1].end.x)
        XCTAssertLessThan(steep.segments[1].end.x, shallow.segments[1].end.x,
                          "stromsze zbocze kończy się bliżej częstotliwości granicznej")
    }

    func testHighPassMirrorsLowPassAcrossFrame() {
        let shape = FilterGraphGeometry.shape(frequency: 64, resonance: 127,
                                              kind: .highPass, slope: 12,
                                              resonanceScale: 0,
                                              classicVariant: false, active: true)
        XCTAssertEqual(shape.start.x, FilterGraphGeometry.sourceWidth + 1)
        XCTAssertEqual(shape.segments.count, 2)
        // Zbocze biegnie w lewo, więc kolejne punkty mają malejące X.
        XCTAssertLessThan(shape.segments[1].end.x, shape.segments[0].end.x)
        XCTAssertEqual(shape.segments[0].end.y, 0, "pik rezonansu przy Freq")
    }

    /// Pasmowoprzepustowy nie ma odcinka prostego — sam `BorderPolyBezier`.
    func testBandPassIsDrawnWithoutLeadingLine() {
        let shape = FilterGraphGeometry.shape(frequency: 64, resonance: 127,
                                              kind: .bandPass, slope: 12,
                                              resonanceScale: 0,
                                              classicVariant: false, active: true)
        XCTAssertNil(shape.lineTo)
        XCTAssertEqual(shape.segments.count, 2)
        // Start i koniec leżą na dole bufora, pik pośrodku.
        XCTAssertEqual(shape.start.y, FilterGraphGeometry.innerHeight)
        XCTAssertEqual(shape.segments[1].end.y, FilterGraphGeometry.innerHeight)
        XCTAssertLessThan(shape.segments[0].end.y, shape.start.y)
    }

    /// Notch ma cztery segmenty: dwie proste i zjazd do dna poniżej bufora.
    func testBandRejectDepthFollowsSlope() {
        func notch(slope: Int) -> FilterGraphGeometry.Shape {
            FilterGraphGeometry.shape(frequency: 64, resonance: 64,
                                      kind: .bandReject, slope: slope,
                                      resonanceScale: 0,
                                      classicVariant: false, active: true)
        }
        let shallow = notch(slope: 12)
        let steep = notch(slope: 24)
        XCTAssertEqual(shallow.segments.count, 4)
        XCTAssertNil(shallow.lineTo)
        // 12 dB/Oct → (24 − 24) × 26/128 = 0 → dno na wysokości ramki 28.
        XCTAssertEqual(shallow.segments[1].end.y, 28)
        XCTAssertEqual(steep.segments[1].end.y, 33)
        XCTAssertGreaterThan(steep.segments[1].end.y, shallow.segments[1].end.y)
    }

    /// Szerokość notcha zależy od `Res`, przez całkowite `(Res >> 2) + 30`.
    func testBandRejectWidthFollowsResonance() {
        func width(resonance: Int) -> Double {
            let shape = FilterGraphGeometry.shape(frequency: 64, resonance: resonance,
                                                  kind: .bandReject, slope: 12,
                                                  resonanceScale: 0,
                                                  classicVariant: false, active: true)
            return shape.segments[1].control1.x - shape.segments[0].end.x
        }
        XCTAssertLessThan(width(resonance: 0), width(resonance: 127))
    }

    // MARK: - Stan nieaktywny

    func testInactiveFilterDrawsFlatLineOnly() {
        let shape = FilterGraphGeometry.shape(frequency: 100, resonance: 127,
                                              kind: .bandPass, slope: 24,
                                              resonanceScale: 1,
                                              classicVariant: false, active: false)
        XCTAssertTrue(shape.segments.isEmpty)
        XCTAssertEqual(shape.start.y, FilterGraphGeometry.baseline)
        XCTAssertEqual(shape.lineTo?.y, FilterGraphGeometry.baseline)
    }

    // MARK: - Granice zakresu

    func testOutOfRangeValuesAreClamped() {
        let below = lowPass(frequency: -5, resonance: -5)
        let atZero = lowPass(frequency: 0, resonance: 0)
        XCTAssertEqual(below.segments[0].end, atZero.segments[0].end)

        let above = lowPass(frequency: 999, resonance: 999)
        let atMax = lowPass(frequency: 127, resonance: 127)
        XCTAssertEqual(above.segments[0].end, atMax.segments[0].end)
    }

    /// Żaden typ nie może zwrócić wartości nieliczbowej na całym zakresie.
    func testAllTypesProduceFiniteCoordinates() {
        for kind in [FilterGraphGeometry.Kind.lowPass, .bandPass, .highPass, .bandReject] {
            for freq in stride(from: 0, through: 127, by: 7) {
                for res in stride(from: 0, through: 127, by: 7) {
                    let shape = FilterGraphGeometry.shape(
                        frequency: freq, resonance: res, kind: kind, slope: 18,
                        resonanceScale: 1, classicVariant: false, active: true
                    )
                    var points = [shape.start]
                    if let lineTo = shape.lineTo { points.append(lineTo) }
                    for segment in shape.segments {
                        points.append(contentsOf: [segment.control1, segment.control2, segment.end])
                    }
                    for point in points {
                        XCTAssertTrue(point.x.isFinite && point.y.isFinite,
                                      "typ \(kind) Freq=\(freq) Res=\(res)")
                    }
                }
            }
        }
    }
}
