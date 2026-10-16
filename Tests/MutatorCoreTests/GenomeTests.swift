import Foundation
import MutatorCore
import XCTest

/// Krok 3.2: genom na surowych wartościach i odcisk struktury bez kabli (§17 „fingerprint").
final class GenomeTests: XCTestCase {
    private let osc = ModuleIdentity(area: 1, index: 1, type: 97)
    private let filter = ModuleIdentity(area: 1, index: 2, type: 92)

    func testFingerprintIgnoresModuleOrder() {
        XCTAssertEqual(TargetFingerprint(modules: [osc, filter]),
                       TargetFingerprint(modules: [filter, osc]))
    }

    /// Wartość zapisana na sztywno: odcisk nie może zależeć od uruchomienia (sesja leży na dysku).
    func testFingerprintIsStableAcrossRuns() {
        XCTAssertEqual(TargetFingerprint(modules: []).structureHash, 0xCBF2_9CE4_8422_2325)
        XCTAssertEqual(TargetFingerprint(modules: [osc]).structureHash,
                       TargetFingerprint(modules: [ModuleIdentity(area: 1, index: 1, type: 97)]).structureHash)
    }

    func testFingerprintChangesWithModuleTypeIndexOrArea() {
        let base = TargetFingerprint(modules: [osc, filter]).structureHash
        XCTAssertNotEqual(base, TargetFingerprint(modules: [osc, ModuleIdentity(area: 1, index: 2, type: 93)]).structureHash)
        XCTAssertNotEqual(base, TargetFingerprint(modules: [osc, ModuleIdentity(area: 1, index: 3, type: 92)]).structureHash)
        XCTAssertNotEqual(base, TargetFingerprint(modules: [osc, ModuleIdentity(area: 0, index: 2, type: 92)]).structureHash)
        XCTAssertNotEqual(base, TargetFingerprint(modules: [osc]).structureHash)
    }

    /// Mother × Father o różnym `structureHash` ⇒ rzuca błąd.
    func testParentsWithDifferentStructureAreRejected() {
        let values = [ParameterAddress(area: 1, module: 1, parameter: 0): UInt8(10)]
        let mother = Genome(fingerprint: TargetFingerprint(modules: [osc]), snapshot: values)
        let father = Genome(fingerprint: TargetFingerprint(modules: [osc, filter]), snapshot: values)

        XCTAssertThrowsError(try mother.requireCompatible(with: father)) { error in
            XCTAssertEqual(error as? GenomeError, .fingerprintMismatch(mother.fingerprint, father.fingerprint))
        }
        XCTAssertNoThrow(try mother.requireCompatible(with: mother))
    }

    /// Zrzut → genom → wartości daje dokładnie to samo; zapis wysyła tylko różnice.
    func testSnapshotRoundTripsAndDiffKeepsOnlyChanges() async throws {
        let target = MockTarget()
        let snapshot = try await target.snapshot(layer: 0)
        let mother = Genome(fingerprint: target.fingerprint, snapshot: snapshot)
        XCTAssertEqual(snapshot, mother.values)

        var child = mother
        let address = ParameterAddress(area: 1, module: 1, parameter: 3)
        child.genes[address]?.raw = 5
        XCTAssertEqual(child.diff(from: mother), [address: 5])
        XCTAssertEqual(mother.diff(from: mother), [:])
    }

    func testGenomeSurvivesCoding() throws {
        let genome = Genome(fingerprint: TargetFingerprint(modules: [osc]),
                            snapshot: [ParameterAddress(area: 1, module: 1, parameter: 2): 99],
                            lineage: Lineage(parents: [UUID()], generation: 4))
        let decoded = try JSONDecoder().decode(Genome.self, from: JSONEncoder().encode(genome))
        XCTAssertEqual(decoded.values, genome.values)
        XCTAssertEqual(decoded.fingerprint, genome.fingerprint)
        XCTAssertEqual(decoded.lineage, genome.lineage)
    }
}
