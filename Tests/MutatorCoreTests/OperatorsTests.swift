import Foundation
import MutatorCore
import XCTest

/// Krok 3.5: operatory z regułami rodzaju parametru (§17 „operatory", „envelope", „locki").
final class OperatorsTests: XCTestCase {
    /// Moduł 1: obwiednia (A, D, S, R), moduł 2: fala (kategoria), filtr, rezonans, przełącznik,
    /// moduł 3: sekwencer ośmiu kroków.
    private static func address(_ module: UInt8, _ parameter: UInt8) -> ParameterAddress {
        ParameterAddress(area: 1, module: module, parameter: parameter)
    }

    private let attack = address(1, 0), decay = address(1, 1), sustain = address(1, 2), release = address(1, 3)
    private let wave = address(2, 0), cutoff = address(2, 1), resonance = address(2, 2), mode = address(2, 3)

    private lazy var space: [ParameterAddress: ParameterSemantics] = {
        var space: [ParameterAddress: ParameterSemantics] = [
            attack: ParameterSemantics(maxRaw: 127, kind: .timeMs, group: .envelope),
            decay: ParameterSemantics(maxRaw: 127, kind: .timeMs, group: .envelope),
            sustain: ParameterSemantics(maxRaw: 127, group: .envelope),
            release: ParameterSemantics(maxRaw: 127, kind: .timeMs, group: .envelope),
            wave: ParameterSemantics(maxRaw: 5, kind: .categorical, group: .timbre),
            cutoff: ParameterSemantics(maxRaw: 127, group: .timbre, weight: 3),
            resonance: ParameterSemantics(maxRaw: 127, kind: .resonance, group: .timbre),
            mode: ParameterSemantics(maxRaw: 3, kind: .categorical, critical: true),
        ]
        for step in 0 ..< UInt8(8) {
            space[Self.address(3, step)] = ParameterSemantics(maxRaw: 127, kind: .sequencerStep, group: .motion)
        }
        return space
    }()

    private let fingerprint = TargetFingerprint(modules: [
        ModuleIdentity(area: 1, index: 1, type: 20),
        ModuleIdentity(area: 1, index: 2, type: 51),
        ModuleIdentity(area: 1, index: 3, type: 121),
    ])

    private func genome(_ values: [ParameterAddress: UInt8]) -> Genome {
        Genome(fingerprint: fingerprint, snapshot: space.keys.reduce(into: [:]) { $0[$1] = values[$1] ?? 40 })
    }

    private lazy var mother = genome([attack: 10, decay: 40, sustain: 90, release: 25, wave: 1, cutoff: 60,
                                      resonance: 20, mode: 2])
    private lazy var father: Genome = {
        var values: [ParameterAddress: UInt8] = [attack: 70, decay: 100, sustain: 10, release: 90, wave: 4,
                                                 cutoff: 120, resonance: 110, mode: 0]
        for step in 0 ..< UInt8(8) {
            values[Self.address(3, step)] = 100 + step
        }
        return genome(values)
    }()

    // MARK: - Interpolate

    func testInterpolateEndsAreParents() throws {
        let operators = Operators(space: space)
        XCTAssertEqual(try operators.interpolate(mother, father, t: 0).values, mother.values)
        let end = try operators.interpolate(mother, father, t: 1)
        for (address, semantics) in space where !semantics.critical {
            XCTAssertEqual(end.genes[address]?.raw, father.genes[address]?.raw, "\(address)")
        }
        XCTAssertEqual(end.genes[mode]?.raw, mother.genes[mode]?.raw, "krytyczny zostaje z Mother")
    }

    /// Kategoria przy t = 0,5 to wartość jednego z rodziców, nigdy średnia.
    func testCategoricalNeverAverages() throws {
        let operators = Operators(space: space)
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let child = try operators.interpolate(mother, father, t: t)
            XCTAssertTrue(try [1, 4].contains(XCTUnwrap(child.genes[wave]?.raw)), "t = \(t)")
        }
        XCTAssertEqual(Operators.lerp(1, 4, t: 0.5, kind: .categorical), 4)
        XCTAssertEqual(Operators.lerp(1, 4, t: 0.49, kind: .categorical), 1)
    }

    func testInterpolateRejectsDifferentStructure() {
        let stranger = Genome(fingerprint: TargetFingerprint(modules: []), snapshot: mother.values)
        XCTAssertThrowsError(try Operators(space: space).interpolate(mother, stranger, t: 0.5))
    }

    // MARK: - Cross

    /// Krzyżowanie po modułach: wszystkie geny modułu od tego samego rodzica.
    func testModuleLevelCrossKeepsModulesWhole() throws {
        let operators = Operators(space: space)
        var sawBothParents = Set<Bool>()
        for seed in 0 ..< UInt64(40) {
            var rng = SplitMix64(seed: seed)
            let child = try operators.cross(mother, father, mode: .moduleLevel, using: &rng)
            for module in [UInt8(1), 2, 3] {
                let genes = space.keys.filter { $0.module == module && !space[$0]!.critical }
                let fromFather = genes.map { child.genes[$0]!.raw == father.genes[$0]!.raw }
                XCTAssertEqual(Set(fromFather).count, 1, "moduł \(module), ziarno \(seed)")
                sawBothParents.insert(fromFather[0])
            }
        }
        XCTAssertEqual(sawBothParents, [true, false])
    }

    func testCrossTakesOnlyParentValuesAndSetsLineage() throws {
        var rng = SplitMix64(seed: 5)
        let child = try Operators(space: space).cross(mother, father, mode: .gene(switchProbability: 0.5), using: &rng)
        for address in space.keys {
            XCTAssertTrue(try [XCTUnwrap(mother.genes[address]?.raw), XCTUnwrap(father.genes[address]?.raw)].contains(XCTUnwrap(child.genes[address]?.raw)))
        }
        XCTAssertEqual(child.lineage.parents, [mother.id, father.id])
        XCTAssertEqual(child.lineage.operatorKind, .cross)
        XCTAssertEqual(child.lineage.generation, 1)
    }

    // MARK: - Mutate

    /// Obwiednia mutuje proporcjonalnie: log(decay) − log(attack) zostaje (w domenie log(raw + 1)).
    func testEnvelopeKeepsItsProportions() throws {
        let operators = Operators(space: space)
        func gap(_ genome: Genome) -> Double {
            log(Double(genome.genes[decay]!.raw) + 1) - log(Double(genome.genes[attack]!.raw) + 1)
        }
        var changed = 0
        for seed in 0 ..< UInt64(200) {
            var rng = SplitMix64(seed: seed)
            let child = operators.mutate(mother, magnitude: 0.3, using: &rng)
            guard try XCTUnwrap(child.genes[attack]?.raw) > 2, try XCTUnwrap(child.genes[decay]?.raw) < 125 else { continue }
            if try XCTUnwrap(child.genes[attack]?.raw) != mother.genes[attack]!.raw { changed += 1 }
            XCTAssertEqual(gap(child), gap(mother), accuracy: 0.12, "ziarno \(seed)")
        }
        XCTAssertGreaterThan(changed, 100)
    }

    /// Zablokowany gen i gen krytyczny stoją nawet przy magnitude 1.
    func testLockedAndCriticalGenesNeverMove() throws {
        let operators = Operators(space: space, mutability: MutabilityMap(
            parameterLocks: [cutoff: .explicit],
            moduleLocks: [ModuleAddress(area: 1, module: 1): .module]
        ))
        for seed in 0 ..< UInt64(100) {
            var rng = SplitMix64(seed: seed)
            let child = operators.mutate(mother, magnitude: 1, using: &rng)
            for address in [cutoff, mode, attack, decay, sustain, release] {
                XCTAssertEqual(try XCTUnwrap(child.genes[address]?.raw), try XCTUnwrap(mother.genes[address]?.raw), "\(address)")
            }
            var again = SplitMix64(seed: seed)
            let random = operators.randomize(mother, using: &again)
            XCTAssertEqual(random.genes[mode]?.raw, mother.genes[mode]?.raw)
            XCTAssertEqual(random.genes[cutoff]?.raw, mother.genes[cutoff]?.raw)
        }
    }

    func testValuesStayInScaleAndCategoryJumpsToAnotherValue() throws {
        let operators = Operators(space: space)
        var jumped = 0
        for seed in 0 ..< UInt64(300) {
            var rng = SplitMix64(seed: seed)
            let child = operators.mutate(father, magnitude: 1, using: &rng)
            for (address, semantics) in space {
                XCTAssertLessThanOrEqual(try XCTUnwrap(child.genes[address]?.raw), semantics.maxRaw, "\(address)")
            }
            if try XCTUnwrap(child.genes[wave]?.raw) != father.genes[wave]!.raw { jumped += 1 }
        }
        XCTAssertGreaterThan(jumped, 30)
        XCTAssertLessThan(jumped, 200)
    }

    /// Sekwencer: wzór przesuwa się w całości — ten sam zbiór wartości, żadnych nowych.
    func testSequencerRotatesWholePattern() {
        let operators = Operators(space: space)
        let steps = (0 ..< UInt8(8)).map { Self.address(3, $0) }
        var rotated = 0
        for seed in 0 ..< UInt64(100) {
            var rng = SplitMix64(seed: seed)
            let child = operators.mutate(father, magnitude: 1, using: &rng)
            let values = steps.map { child.genes[$0]!.raw }
            XCTAssertEqual(values.sorted(), steps.map { father.genes[$0]!.raw }.sorted())
            if values != steps.map({ father.genes[$0]!.raw }) { rotated += 1 }
        }
        XCTAssertGreaterThan(rotated, 10)
    }

    /// Rezonans powyżej hamulca rośnie wolniej niż zwykły parametr liniowy.
    func testResonanceBrakesNearSelfOscillation() throws {
        var linear = space
        linear[resonance]?.kind = .continuousLinear
        var braked = 0, free = 0
        for seed in 0 ..< UInt64(400) {
            var a = SplitMix64(seed: seed), b = SplitMix64(seed: seed)
            try braked += Int(XCTUnwrap(Operators(space: space).mutate(father, magnitude: 0.4, using: &a).genes[resonance]?.raw))
            try free += Int(XCTUnwrap(Operators(space: linear).mutate(father, magnitude: 0.4, using: &b).genes[resonance]?.raw))
        }
        XCTAssertLessThan(braked, free)
    }

    func testSameSeedGivesSameChild() {
        var a = SplitMix64(seed: 9), b = SplitMix64(seed: 9)
        let operators = Operators(space: space)
        XCTAssertEqual(operators.mutate(mother, magnitude: 0.5, using: &a).values,
                       operators.mutate(mother, magnitude: 0.5, using: &b).values)
    }
}
