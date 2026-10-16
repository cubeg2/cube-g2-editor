@testable import MutatorCore
import XCTest

/// Krok 3.3: jeden mechanizm blokad z powodem (§17 „locki").
final class MutabilityTests: XCTestCase {
    private let address = ParameterAddress(area: 1, module: 3, parameter: 2)

    /// factor == 0 ⇒ raw niezmienione, nawet przy magnitude 1.0 — dla każdego powodu.
    func testLockedParameterNeverMovesAtFullMagnitude() {
        var rng = SplitMix64(seed: 7)
        for reason in LockReason.allCases {
            for raw in [UInt8(0), 1, 64, 126, 127] {
                for _ in 0 ..< 200 {
                    XCTAssertEqual(MutationStep.gaussian(raw: raw, maxRaw: 127, mutability: .locked(reason),
                                                         magnitude: 1, using: &rng), raw)
                }
            }
        }
    }

    func testFreeParameterMovesAndStaysInScale() {
        var rng = SplitMix64(seed: 11)
        var moved = 0
        for _ in 0 ..< 1000 {
            let value = MutationStep.gaussian(raw: 3, maxRaw: 7, mutability: .free, magnitude: 1, using: &rng)
            XCTAssertLessThanOrEqual(value, 7)
            if value != 3 { moved += 1 }
        }
        XCTAssertGreaterThan(moved, 500)
    }

    /// Połowa swobody daje wyraźnie mniejsze kroki niż pełna.
    func testFactorScalesStepSize() {
        func meanStep(_ factor: Double) -> Double {
            var rng = SplitMix64(seed: 3)
            let mutability = Mutability(factor: factor, reason: nil)
            let steps = (0 ..< 2000).map { _ in
                abs(Int(MutationStep.gaussian(raw: 64, maxRaw: 127, mutability: mutability,
                                              magnitude: 0.3, using: &rng)) - 64)
            }
            return Double(steps.reduce(0, +)) / Double(steps.count)
        }
        XCTAssertLessThan(meanStep(0.5), meanStep(1) * 0.7)
    }

    /// Blokady Standardu wyrażone w mapie, z powodem; blokada parametru wygrywa z modułem.
    func testMapAnswersWithReasonAndParameterLockWins() {
        let module = ModuleAddress(address)
        var map = MutabilityMap(moduleLocks: [module: .module])
        XCTAssertEqual(map.mutability(address), .locked(.module))
        XCTAssertEqual(map.mutability(ParameterAddress(area: 1, module: 4, parameter: 2)), .free)

        map.parameterLocks[address] = .knobAssigned
        XCTAssertEqual(map.mutability(address), .locked(.knobAssigned))

        let other = ParameterAddress(area: 0, module: 1, parameter: 0)
        map.factors[other] = 0.4
        XCTAssertEqual(map.mutability(other), Mutability(factor: 0.4, reason: nil))
        map.factors[other] = 0
        XCTAssertEqual(map.mutability(other), .locked(.group))
    }

    func testReflectFoldsBackIntoScale() {
        XCTAssertEqual(MutationStep.reflect(-3, max: 127), 3)
        XCTAssertEqual(MutationStep.reflect(130, max: 127), 124)
        XCTAssertEqual(MutationStep.reflect(260, max: 127), 6)
        XCTAssertEqual(MutationStep.reflect(127, max: 127), 127)
    }
}
