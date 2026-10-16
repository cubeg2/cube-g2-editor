@testable import G2Core
import XCTest

/// Regresja geometrii ekranów korektorów: Eq Mid Graph (GraphFunc 10),
/// Eq Hi Lo Graph (36) i Eq Hi Mid Lo Graph (37). Wartości oczekiwane
/// wynikają ze stałych oryginalnego edytora Clavii, nie z dopasowania do obrazu.
final class EqGraphGeometryTests: XCTestCase {
    private func curves(_ shape: EqGraphGeometry.Shape) -> [EqGraphGeometry.Segment] {
        shape.elements.compactMap {
            if case let .curve(segment) = $0 { return segment }
            return nil
        }
    }

    private func points(_ shape: EqGraphGeometry.Shape) -> [EqGraphGeometry.SourcePoint] {
        var result = [shape.start]
        for element in shape.elements {
            switch element {
            case let .line(point):
                result.append(point)
            case let .curve(segment):
                result.append(contentsOf: [segment.control1, segment.control2, segment.end])
            }
        }
        return result
    }

    // MARK: - Wspólne stałe

    /// Ekrany EQ mają linię 0 dB pośrodku, w odróżnieniu od filtrów (1/3).
    func testBaselineSitsInTheMiddleUnlikeFilters() {
        XCTAssertEqual(EqGraphGeometry.baseline, 13)
        XCTAssertNotEqual(EqGraphGeometry.baseline, FilterGraphGeometry.baseline)
        XCTAssertEqual(EqGraphGeometry.innerWidth, 50)
        XCTAssertEqual(EqGraphGeometry.innerHeight, 26)
    }

    /// Wzmocnienie jest bipolarne wokół 64 i symetryczne względem linii.
    func testGainIsBipolarAroundCenter() {
        XCTAssertEqual(EqGraphGeometry.level(64), EqGraphGeometry.baseline)
        let boosted = EqGraphGeometry.level(127)
        let cut = EqGraphGeometry.level(1)
        XCTAssertLessThan(boosted, EqGraphGeometry.baseline, "wzmocnienie idzie w górę")
        XCTAssertGreaterThan(cut, EqGraphGeometry.baseline, "tłumienie idzie w dół")
        XCTAssertEqual(EqGraphGeometry.baseline - boosted, cut - EqGraphGeometry.baseline,
                       accuracy: 1.0)
    }

    // MARK: - EqPeak (GraphFunc 10)

    /// Sedno poprawki zgłoszonej przy Eq3Band, wspólne dla obu pasm dzwonowych:
    /// punkty kontrolne leżą na linii 0 dB, więc styczne po obu stronach
    /// wierzchołka nie są współliniowe i szczyt pozostaje ostry.
    func testPeakApexIsSharpNotRounded() {
        let shape = EqGraphGeometry.peak(frequency: 64, gain: 127, bandwidth: 0)
        let segments = curves(shape)
        XCTAssertEqual(segments.count, 2)

        let apex = segments[0].end
        XCTAssertEqual(segments[0].control1.y, EqGraphGeometry.baseline)
        XCTAssertEqual(segments[0].control2.y, EqGraphGeometry.baseline)
        XCTAssertEqual(segments[1].control1.y, EqGraphGeometry.baseline)
        XCTAssertEqual(segments[1].control2.y, EqGraphGeometry.baseline)
        XCTAssertLessThan(apex.y, EqGraphGeometry.baseline)

        // Styczna wchodząca biegnie w górę, wychodząca w dół — stąd ostry kąt.
        let incoming = apex.y - segments[0].control2.y
        let outgoing = segments[1].control1.y - apex.y
        XCTAssertLessThan(incoming, 0)
        XCTAssertGreaterThan(outgoing, 0)
    }

    func testPeakFollowsFrequencyAndGain() {
        let low = EqGraphGeometry.peak(frequency: 0, gain: 100, bandwidth: 40)
        let high = EqGraphGeometry.peak(frequency: 127, gain: 100, bandwidth: 40)
        XCTAssertLessThan(curves(low)[0].end.x, curves(high)[0].end.x)

        let quiet = EqGraphGeometry.peak(frequency: 64, gain: 70, bandwidth: 40)
        let loud = EqGraphGeometry.peak(frequency: 64, gain: 127, bandwidth: 40)
        XCTAssertLessThan(curves(loud)[0].end.y, curves(quiet)[0].end.y)
    }

    /// Oryginał liczy szerokość jako `|BW − 127|`, więc pasmo jest najwęższe
    /// przy górnym krańcu skali.
    func testPeakWidthUsesMirroredBandwidth() {
        func width(_ bandwidth: Int) -> Double {
            let shape = EqGraphGeometry.peak(frequency: 64, gain: 100, bandwidth: bandwidth)
            let segments = curves(shape)
            return segments[1].end.x - (segments[0].end.x - (segments[0].end.x - segments[0].control1.x))
        }
        XCTAssertGreaterThan(width(0), width(127))
        let atMax = EqGraphGeometry.peak(frequency: 64, gain: 100, bandwidth: 127)
        let segments = curves(atMax)
        XCTAssertEqual(segments[0].end.x, segments[0].control1.x + 2, accuracy: 3)
    }

    func testPeakStartsAndEndsOnBaseline() {
        let shape = EqGraphGeometry.peak(frequency: 30, gain: 20, bandwidth: 60)
        XCTAssertEqual(shape.start.y, EqGraphGeometry.baseline)
        XCTAssertEqual(shape.end.y, EqGraphGeometry.baseline)
        XCTAssertEqual(shape.end.x, EqGraphGeometry.sourceWidth)
    }

    // MARK: - Eq2Band (GraphFunc 36)

    /// Punkty załamania obu półek są w oryginale stałe — zależnościami są
    /// wyłącznie wzmocnienia, więc przełączniki częstotliwości nic nie zmieniają.
    func testTwoBandKneesAreFixedRegardlessOfGain() {
        let flat = EqGraphGeometry.twoBand(lowGain: 64, highGain: 64)
        let tilted = EqGraphGeometry.twoBand(lowGain: 127, highGain: 0)
        let flatCurves = curves(flat)
        let tiltedCurves = curves(tilted)
        XCTAssertEqual(flatCurves[0].end.x, tiltedCurves[0].end.x)
        XCTAssertEqual(flatCurves[1].end.x, tiltedCurves[1].end.x)
    }

    func testTwoBandShelvesMoveIndependently() {
        let shape = EqGraphGeometry.twoBand(lowGain: 127, highGain: 0)
        XCTAssertLessThan(shape.start.y, EqGraphGeometry.baseline, "Lo podbite")
        XCTAssertGreaterThan(shape.end.y, EqGraphGeometry.baseline, "Hi stłumione")

        let flat = EqGraphGeometry.twoBand(lowGain: 64, highGain: 64)
        XCTAssertEqual(flat.start.y, EqGraphGeometry.baseline)
        XCTAssertEqual(flat.end.y, EqGraphGeometry.baseline)
    }

    /// Każda półka schodzi na linię 0 dB pomiędzy sobą.
    func testTwoBandReturnsToBaselineBetweenShelves() {
        let shape = EqGraphGeometry.twoBand(lowGain: 127, highGain: 127)
        let segments = curves(shape)
        XCTAssertEqual(segments[0].end.y, EqGraphGeometry.baseline)
        XCTAssertEqual(segments[1].control1.y, EqGraphGeometry.baseline)
    }

    // MARK: - Eq3Band (GraphFunc 37)

    func testThreeBandMidMovesWithFrequency() {
        func midX(_ frequency: Int) -> Double {
            let shape = EqGraphGeometry.threeBand(lowGain: 64, midGain: 127,
                                                  midFrequency: frequency, highGain: 64)
            return curves(shape)[1].end.x
        }
        XCTAssertLessThan(midX(20), midX(64))
        XCTAssertLessThan(midX(64), midX(110))
    }

    /// Pasmo środkowe unosi lewą półkę tylko poniżej `Freq = 40`.
    func testThreeBandLeftShoulderEngagesOnlyBelowThreshold() {
        func leftShoulder(_ frequency: Int) -> Double {
            let shape = EqGraphGeometry.threeBand(lowGain: 64, midGain: 127,
                                                  midFrequency: frequency, highGain: 64)
            return curves(shape)[0].end.y
        }
        XCTAssertLessThan(leftShoulder(0), EqGraphGeometry.baseline)
        XCTAssertEqual(leftShoulder(40), EqGraphGeometry.baseline)
        XCTAssertEqual(leftShoulder(64), EqGraphGeometry.baseline)
    }

    /// Prawa strona włącza się dopiero powyżej `Freq = 96`.
    func testThreeBandRightShoulderEngagesOnlyAboveThreshold() {
        func rightShoulder(_ frequency: Int) -> Double {
            let shape = EqGraphGeometry.threeBand(lowGain: 64, midGain: 127,
                                                  midFrequency: frequency, highGain: 64)
            let lines = shape.elements.compactMap { element -> EqGraphGeometry.SourcePoint? in
                if case let .line(point) = element { return point }
                return nil
            }
            // Przedostatni odcinek prosty prowadzi do punktu załamania półki Hi.
            return lines[lines.count - 2].y
        }
        XCTAssertEqual(rightShoulder(64), EqGraphGeometry.baseline)
        XCTAssertEqual(rightShoulder(96), EqGraphGeometry.baseline)
        XCTAssertLessThan(rightShoulder(127), EqGraphGeometry.baseline)
    }

    func testThreeBandNeutralSettingIsFlat() {
        let shape = EqGraphGeometry.threeBand(lowGain: 64, midGain: 64,
                                              midFrequency: 64, highGain: 64)
        for point in points(shape) {
            XCTAssertEqual(point.y, EqGraphGeometry.baseline,
                           "przy neutralnych wzmocnieniach ekran musi być płaski")
        }
    }

    func testThreeBandGainsMoveTheirOwnEnds() {
        let shape = EqGraphGeometry.threeBand(lowGain: 127, midGain: 64,
                                              midFrequency: 64, highGain: 0)
        XCTAssertLessThan(shape.start.y, EqGraphGeometry.baseline)
        XCTAssertGreaterThan(shape.end.y, EqGraphGeometry.baseline)
    }

    // MARK: - Granice zakresu

    func testAllShapesProduceFiniteCoordinates() {
        for value in stride(from: 0, through: 127, by: 9) {
            let shapes = [
                EqGraphGeometry.peak(frequency: value, gain: value, bandwidth: value),
                EqGraphGeometry.twoBand(lowGain: value, highGain: 127 - value),
                EqGraphGeometry.threeBand(lowGain: value, midGain: 127 - value,
                                          midFrequency: value, highGain: value),
            ]
            for shape in shapes {
                for point in points(shape) {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite, "wartość \(value)")
                }
            }
        }
    }

    func testOutOfRangeValuesAreClamped() {
        XCTAssertEqual(EqGraphGeometry.peak(frequency: -10, gain: -10, bandwidth: -10).start,
                       EqGraphGeometry.peak(frequency: 0, gain: 0, bandwidth: 0).start)
        XCTAssertEqual(EqGraphGeometry.twoBand(lowGain: 999, highGain: 999).start,
                       EqGraphGeometry.twoBand(lowGain: 127, highGain: 127).start)
    }
}
