// EngineAdapterTests.swift
// Patch G2 jako cel silnika mutacji: odczyt → zapis → odczyt bez strat, blokady Standardu,
// warstwy, których silnik nie wolno zapisać.

import G2Core
@testable import G2EditorCore
import MutatorCore
import XCTest

@MainActor
final class EngineAdapterTests: XCTestCase {
    private static let fixtures = ["test_3osc.pch2", "simplesynth001-20240802.pch2", "RndFilter.pch2",
                                   "SwitchSeqNote.pch2", "test_all_modules_1.pch2", "test_all_modules_2.pch2"]

    private func fixture(_ name: String) throws -> G2Patch {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
    }

    private func makeState(_ patch: G2Patch) -> PatchState {
        let state = PatchState()
        state.slots = [patch]
        return state
    }

    /// Kontrakt §17 bez sprzętu: zrzut każdej wariacji zapisany z powrotem nie zmienia
    /// ani jednego bajtu patcha i nie wysyła ani jednej komendy.
    func testSnapshotWriteSnapshotIsLossless() async throws {
        for name in Self.fixtures {
            let patch = try fixture(name)
            let state = makeState(patch)
            var sent = 0
            state.onLiveParameterChange = { _, _, _, _, _, _ in sent += 1 }
            state.onLiveStructureChange = { _, _ in sent += 1 }
            let target = G2PatchTarget(state: state)
            XCTAssertFalse(target.space.isEmpty, name)
            for layer: UInt8 in 0 ..< 8 {
                let before = try await target.snapshot(layer: layer)
                try await target.write([:], layer: layer)
                let after = try await target.snapshot(layer: layer)
                XCTAssertEqual(before, after, "\(name) V\(layer + 1)")
            }
            XCTAssertEqual(state.patch, patch, name)
            XCTAssertEqual(sent, 0, name)

            // Cały zrzut jako „różnica": wartości te same, więc nic się nie zmienia i nic nie idzie.
            let values = try await target.snapshot(layer: 2)
            try await target.write(values, layer: 2)
            XCTAssertEqual(state.patch, patch, name)
            XCTAssertEqual(sent, 0, name)
        }
    }

    /// Zmieniony gen trafia dokładnie w swój parametr i swoją wariację.
    func testWriteChangesOnlyTheAddressedParameter() async throws {
        let state = try makeState(fixture("test_3osc.pch2"))
        let target = G2PatchTarget(state: state)
        let address = try XCTUnwrap(target.space.first { !$0.value.critical && $0.value.maxRaw > 10 }?.key)
        let before = try await target.snapshot(layer: 4)
        let raw: UInt8 = before[address] == 3 ? 7 : 3
        try await target.write([address: raw], layer: 4)

        let after = try await target.snapshot(layer: 4)
        XCTAssertEqual(after[address], raw)
        XCTAssertEqual(after.filter { $0.key != address }, before.filter { $0.key != address })
        let otherLayer = try await target.snapshot(layer: 5)
        XCTAssertEqual(otherLayer[address], G2EngineSpace(patch: state.patch).genome(
            of: G2Mutator.individual(from: state.patch, variation: 5, genome: state.mutatorGenome)
        ).values[address])
    }

    /// Bufor odsłuchu: każdy zapis idzie **jednym zrzutem całego zestawu 9**, nie
    /// pojedynczymi `0x40` i nie różnicą. Od kroku 1.5 — do 2026-09-22 pierwszy zapis
    /// wysyłał komplet parametr po parametrze, a następne same różnice, przez co jedna
    /// zgubiona ramka zostawała rozbieżnością do końca sesji
    /// (→ [[Docs/usb/mutator-dump]], [[Docs/context/bug-history]] #109).
    func testAuditionBufferGoesAsOneDump() async throws {
        let state = try makeState(fixture("test_3osc.pch2"))
        var single = 0
        var dumps: [(variation: Int, value: Int?)] = []
        state.onLiveParameterChange = { _, _, _, _, _, variation in
            if variation == G2Patch.mutatorVariation { single += 1 }
        }
        let target = G2PatchTarget(state: state)
        let buffer = UInt8(G2Patch.mutatorVariation)
        let movable = target.space.filter { !$0.value.critical && $0.value.maxRaw > 10 }.keys.sorted()
        let first = try XCTUnwrap(movable.first)
        let second = try XCTUnwrap(movable.last)
        let values = try await target.snapshot(layer: buffer)

        try await target.write([first: values[first] == 1 ? 2 : 1], layer: buffer)
        let wanted: UInt8 = values[second] == 1 ? 2 : 1
        state.onMutatorAudition = { _, patch, variation in
            let module = patch.modules(in: second.area == 1 ? .voice : .fx)
                .first { $0.id == Int(second.module) }
            dumps.append((variation, module?.parameterVariations[variation][Int(second.parameter)]))
        }
        try await target.write([second: wanted], layer: buffer)

        XCTAssertEqual(single, 0, "żadnego 0x40 do zestawu 9")
        XCTAssertEqual(dumps.count, 1, "jedno przesłuchanie = jeden zrzut")
        XCTAssertEqual(dumps.first?.variation, G2Patch.mutatorVariation)
        XCTAssertEqual(dumps.first?.value, Int(wanted), "zrzut niesie nową wartość")
        XCTAssertEqual(state.patch.activeVariation, G2Patch.mutatorVariation)
    }

    func testInitLayerIsNeverWritten() async throws {
        let patch = try fixture("test_3osc.pch2")
        let state = makeState(patch)
        let target = G2PatchTarget(state: state)
        let address = try XCTUnwrap(target.space.keys.first)
        do {
            try await target.write([address: 0], layer: 8)
            XCTFail("Init zapisany")
        } catch {
            XCTAssertEqual(error as? G2PatchTargetError, .layerNotWritable(8))
        }
        XCTAssertEqual(state.patch, patch)
    }

    /// Po zmianie modułów stary cel nie może zapisać wartości w cudze adresy.
    func testWriteAfterStructureChangeIsRefused() async throws {
        let state = try makeState(fixture("test_3osc.pch2"))
        let target = G2PatchTarget(state: state)
        let address = try XCTUnwrap(target.space.keys.first)
        var patch = state.patch
        patch.voiceModules.removeLast()
        state.slots = [patch]
        do {
            try await target.write([address: 0], layer: 0)
            XCTFail("zapis przeszedł mimo innej struktury")
        } catch {
            XCTAssertTrue(error is GenomeError)
        }
        XCTAssertEqual(state.patch, patch)
    }

    func testFingerprintIgnoresCablesButNotModules() throws {
        let patch = try fixture("test_3osc.pch2")
        var rewired = patch
        rewired.voiceCables.removeAll()
        XCTAssertEqual(G2EngineSpace(patch: patch).fingerprint, G2EngineSpace(patch: rewired).fingerprint)
        var smaller = patch
        smaller.voiceModules.removeFirst()
        XCTAssertNotEqual(G2EngineSpace(patch: patch).fingerprint, G2EngineSpace(patch: smaller).fingerprint)
    }

    /// Nieruszony gen zostaje ułamkiem z osobnika — inaczej każde przejście przez silnik
    /// zaokrąglałoby dźwięk Standardu.
    func testUntouchedGenesKeepTheirFractions() throws {
        let patch = try fixture("test_3osc.pch2")
        let space = G2EngineSpace(patch: patch)
        let genes = space.space.filter { !$0.value.critical && $0.value.maxRaw > 10 }.keys.sorted()
        let kept = try XCTUnwrap(genes.first)
        let moved = try XCTUnwrap(genes.last)
        var base = G2Mutator.individual(from: patch, variation: 0, genome: G2MutatorGenome(patch: patch))
        base[kept.key] = 5.3
        base[moved.key] = 5.3
        var genome = space.genome(of: base)
        XCTAssertEqual(genome.genes[kept]?.raw, 5)
        genome.genes[moved]?.raw = 9

        let sound = space.individual(genome, base: base)
        XCTAssertEqual(sound[kept.key], 5.3)
        XCTAssertEqual(sound[moved.key], 9)
        XCTAssertEqual(sound.morphs, base.morphs)
        XCTAssertEqual(sound.values.filter(\.key.isSetting), base.values.filter(\.key.isSetting))
    }

    /// Twardy stop Standardu działa także w silniku: moduł wyłączony z mutacji, kategoria
    /// zamknięta Quick Lockiem i parametr, którego Standard nie rusza.
    func testStandardLocksHoldInTheEngine() throws {
        let patch = try fixture("test_all_modules_1.pch2")
        let genome = G2MutatorGenome(patch: patch)
        let space = G2EngineSpace(patch: patch, genome: genome)
        var locks = G2MutatorLocks(enabled: 0xFF)
        locks.toggleLock(.envelope)
        let map = space.mutability(locks: locks)

        let envelope = try XCTUnwrap(genome.genes.first { $0.category == .envelope && $0.isMutable && !$0.moduleExcluded })
        try XCTAssertEqual(map.mutability(XCTUnwrap(ParameterAddress(envelope.key))).reason, .explicit)
        if let excluded = genome.genes.first(where: \.moduleExcluded) {
            try XCTAssertEqual(map.mutability(XCTUnwrap(ParameterAddress(excluded.key))).reason, .module)
        }
        let fixed = try XCTUnwrap(genome.genes.first { !$0.isMutable })
        try XCTAssertEqual(space.space[XCTUnwrap(ParameterAddress(fixed.key))]?.critical, true)

        let operators = Operators(space: space.space, mutability: map)
        let mother = space.genome(of: G2Mutator.individual(from: patch, variation: 0, genome: genome))
        var rng = SplitMix64(seed: 7)
        var changed = false
        for _ in 0 ..< 20 {
            let child = operators.mutate(mother, magnitude: 1, using: &rng)
            for gene in genome.genes {
                guard let address = ParameterAddress(gene.key) else { continue }
                let differs = child.genes[address]?.raw != mother.genes[address]?.raw
                if G2Mutator.isEnabled(gene, locks: locks) {
                    changed = changed || differs
                } else {
                    XCTAssertFalse(differs, "\(gene.key) ruszony mimo blokady")
                }
            }
        }
        XCTAssertTrue(changed, "silnik w ogóle nic nie zmienił")
    }
}
