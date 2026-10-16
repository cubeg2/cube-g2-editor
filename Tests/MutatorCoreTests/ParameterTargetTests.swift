import MutatorCore
import XCTest

/// Krok 3.1: silnik ma cel bez G2 i powtarzalne losowanie.
final class ParameterTargetTests: XCTestCase {
    /// Zapis różnicy zmienia tylko podane adresy i tylko w swojej warstwie.
    func testMockWritesDiffIntoOneLayer() async throws {
        let target = MockTarget()
        let address = ParameterAddress(area: 1, module: 0, parameter: 2)

        try await target.write([address: 100], layer: 3)

        let layer3 = try await target.snapshot(layer: 3)
        let layer0 = try await target.snapshot(layer: 0)
        XCTAssertEqual(layer3[address], 100)
        XCTAssertEqual(layer0[address], 64)
        XCTAssertEqual(layer3.count, target.space.count)
        XCTAssertEqual(layer3.filter { $0.value != layer0[$0.key] }.count, 1)
        XCTAssertEqual(target.writes.count, 1)
    }

    /// Wzorcowy ciąg SplitMix64 dla ziarna 0 — ten sam co w implementacji referencyjnej.
    func testSplitMix64MatchesReferenceSequence() {
        var rng = SplitMix64(seed: 0)
        XCTAssertEqual(rng.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(rng.next(), 0x6E78_9E6A_A1B9_65F4)
        XCTAssertEqual(rng.next(), 0x06C4_5D18_8009_454F)
    }

    func testSameSeedGivesSameSequence() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        let first = (0 ..< 16).map { _ in Int.random(in: 0 ... 127, using: &a) }
        let second = (0 ..< 16).map { _ in Int.random(in: 0 ... 127, using: &b) }
        XCTAssertEqual(first, second)
    }

    func testAddressesSortByAreaModuleParameter() {
        let addresses = [
            ParameterAddress(area: 1, module: 0, parameter: 5),
            ParameterAddress(area: 0, module: 9, parameter: 0),
            ParameterAddress(area: 1, module: 0, parameter: 1),
        ]
        XCTAssertEqual(addresses.sorted().map(\.description), ["0:9:0", "1:0:1", "1:0:5"])
    }
}
