import MutatorCore
import XCTest

/// Krok 3.6: metryka d(A, B) i wybór greedy max-min (§17 „selekcja").
final class DiversityTests: XCTestCase {
    private let cutoff = ParameterAddress(area: 1, module: 1, parameter: 0)
    private let fine = ParameterAddress(area: 1, module: 1, parameter: 1)
    private let wave = ParameterAddress(area: 1, module: 2, parameter: 0)

    private lazy var space: [ParameterAddress: ParameterSemantics] = [
        cutoff: ParameterSemantics(maxRaw: 127, group: .timbre, weight: 3),
        fine: ParameterSemantics(maxRaw: 127, kind: .bipolar, group: .pitch, weight: 0.4),
        wave: ParameterSemantics(maxRaw: 5, kind: .categorical, group: .timbre, weight: 2.5),
    ]
    private let fingerprint = TargetFingerprint(modules: [ModuleIdentity(area: 1, index: 1, type: 1)])

    private func genome(cutoff c: UInt8, fine f: UInt8 = 64, wave w: UInt8 = 0) -> Genome {
        Genome(fingerprint: fingerprint, snapshot: [cutoff: c, fine: f, wave: w])
    }

    func testDistanceWeighsParametersByKind() {
        let diversity = Diversity(space: space)
        let base = genome(cutoff: 0)
        XCTAssertEqual(diversity.distance(base, base), 0)
        XCTAssertEqual(diversity.distance(base, genome(cutoff: 127)), 3, accuracy: 1e-9)
        XCTAssertEqual(diversity.distance(base, genome(cutoff: 0, fine: 127)), 0.4 * 63 / 127, accuracy: 1e-9)
        XCTAssertGreaterThan(diversity.distance(base, genome(cutoff: 40)),
                             diversity.distance(base, genome(cutoff: 0, fine: 104)),
                             "ten sam ruch surowy na filtrze waży więcej niż na fine")
    }

    /// Kategoria: każda inna wartość jest tak samo daleko.
    func testCategoricalDistanceIsSameOrDifferent() {
        let diversity = Diversity(space: space)
        let base = genome(cutoff: 0, wave: 1)
        XCTAssertEqual(diversity.distance(base, genome(cutoff: 0, wave: 2)),
                       diversity.distance(base, genome(cutoff: 0, wave: 5)))
    }

    func testDistanceIsSymmetricAndInaudibleCountsZero() {
        let a = genome(cutoff: 10, fine: 30, wave: 1), b = genome(cutoff: 90, fine: 70, wave: 3)
        let diversity = Diversity(space: space)
        XCTAssertEqual(diversity.distance(a, b), diversity.distance(b, a), accuracy: 1e-9)
        let deafToCutoff = Diversity(space: space) { [cutoff] in $0 == cutoff ? 0 : 1 }
        XCTAssertEqual(deafToCutoff.distance(genome(cutoff: 0), genome(cutoff: 127)), 0)
    }

    /// Greedy max-min: pula to sześć skupisk po dziesięć niemal identycznych dźwięków.
    /// Wybranych sześcioro dzieci ma pochodzić z sześciu różnych skupisk — żadne dwa
    /// nie są bliżej niż odstęp między skupiskami.
    func testSelectionPicksOnePerClusterAndNoTwoAreClose() {
        let diversity = Diversity(space: space)
        let mother = genome(cutoff: 64, fine: 64, wave: 0)
        let centres: [(UInt8, UInt8)] = [(0, 1), (25, 2), (50, 3), (80, 4), (105, 5), (127, 1)]
        var pool: [Genome] = []
        for jitter in 0 ..< UInt8(10) {
            for (c, w) in centres {
                pool.append(genome(cutoff: c, fine: 60 + jitter, wave: w))
            }
        }

        let chosen = diversity.selectMostDifferent(6, from: pool, mother: mother)

        XCTAssertEqual(chosen.count, 6)
        XCTAssertEqual(Set(chosen.map { $0.genes[cutoff]!.raw }).count, 6, "po jednym z każdego skupiska")
        let minimumGap = diversity.distance(genome(cutoff: 0, wave: 1), genome(cutoff: 25, wave: 2)) * 0.9
        for i in chosen.indices {
            for j in chosen.indices where j > i {
                XCTAssertGreaterThan(diversity.distance(chosen[i], chosen[j]), minimumGap)
            }
        }
    }

    func testSelectionFromSmallPoolReturnsWholePoolOnce() {
        let diversity = Diversity(space: space)
        let pool = [genome(cutoff: 1), genome(cutoff: 100)]
        let chosen = diversity.selectMostDifferent(6, from: pool, mother: genome(cutoff: 0))
        XCTAssertEqual(chosen.map { $0.genes[cutoff]!.raw }, [100, 1])
    }
}
