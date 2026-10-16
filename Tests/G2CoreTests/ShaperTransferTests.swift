@testable import G2Core
import XCTest

final class ShaperTransferTests: XCTestCase {
    func testOverdriveAtMaximumMatchesClaviaPlateaus() {
        XCTAssertEqual(ShaperTransfer.overdrive(input: -1, symmetric: true, drive: 127), -0.5, accuracy: 0.000_001)
        XCTAssertEqual(ShaperTransfer.overdrive(input: 0, symmetric: true, drive: 127), 0, accuracy: 0.000_001)
        XCTAssertEqual(ShaperTransfer.overdrive(input: 1, symmetric: true, drive: 127), 1, accuracy: 0.000_001)
    }

    func testSaturateAtZeroIsDiagonalAndCurveOneBendsAtMaximum() {
        XCTAssertEqual(ShaperTransfer.saturate(input: -0.5, amount: 0, curve: 0), -0.5, accuracy: 0.000_001)
        XCTAssertEqual(ShaperTransfer.saturate(input: 0.5, amount: 0, curve: 3), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(ShaperTransfer.saturate(input: -0.5, amount: 127, curve: 0), -0.75, accuracy: 0.000_001)
        XCTAssertEqual(ShaperTransfer.saturate(input: 0.5, amount: 127, curve: 0), 0.75, accuracy: 0.000_001)
    }

    func testExponentialCurvesUseClaviaPowerMultiplier() {
        XCTAssertEqual(ShaperTransfer.exponential(input: 0.25, amount: 127, curve: 0), 0.125, accuracy: 0.000_001)
        XCTAssertEqual(ShaperTransfer.exponential(input: 0.25, amount: 127, curve: 3), 0.015_625, accuracy: 0.000_001)
        XCTAssertEqual(ShaperTransfer.exponential(input: -0.5, amount: 127, curve: 0), -0.5, accuracy: 0.000_001)
        XCTAssertEqual(ShaperTransfer.exponential(input: 0.5, amount: 127, curve: 3), 0.5, accuracy: 0.000_001)
    }

    func testWaveWrapUsesOriginalOneEighthScaling() {
        XCTAssertEqual(ShaperTransfer.waveWrapFactor(amount: 0), 1, accuracy: 0.000_001)
        XCTAssertEqual(ShaperTransfer.waveWrapFactor(amount: 64), 9, accuracy: 0.000_001)
        XCTAssertEqual(ShaperTransfer.waveWrapFactor(amount: 127), 16.875, accuracy: 0.000_001)
    }
}
