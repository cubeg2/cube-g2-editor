// MutatorGroupsTests.swift
// „Profile & Groups" w panelu Mutation settings: grupy parametrów, suwaki „ile ruszać",
// profile i to, że profil „Timbre" nie rusza stroju.

import G2Core
@testable import G2EditorCore
import MutatorCore
import XCTest

@MainActor
final class MutatorGroupsTests: XCTestCase {
    private func fixture() throws -> G2Patch {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("test_3osc.pch2")
        return try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
    }

    private let allUnlocked = G2MutatorLocks(enabled: 0xFF)

    func testEveryGroupIsPresentInOscillatorPatch() throws {
        let genome = try G2MutatorGenome(patch: fixture())
        let groups = Set(genome.genes.filter(\.isMutable).map(\.group))
        XCTAssertTrue(groups.contains(.pitch), "strój oscylatorów")
        XCTAssertTrue(groups.contains(.timbre))
        XCTAssertTrue(groups.contains(.envelope))
        // Strój z Quick Locka trafia do Pitch nawet bez ręcznego opisu klasy.
        XCTAssertEqual(G2MutatorGroup.of(paramClass: nil, category: .oscFine), .pitch)
        XCTAssertEqual(G2MutatorGroup.of(paramClass: nil, category: nil), .other)
    }

    /// Kryterium kroku 4.4: profil „Timbre" nie rusza stroju — ani w Mutate, ani w Randomize.
    func testTimbreProfileKeepsPitch() throws {
        let patch = try fixture()
        let genome = G2MutatorGenome(patch: patch)
        let mother = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        let weights = G2MutatorProfile.timbre.weights
        let settings = G2MutatorSettings(probability: 1, range: G2MutatorSettings.maxRange, link: false)
        var rng = SplitMix64(seed: 11)
        let children = G2Mutator.mutate(parent: mother, genome: genome, settings: settings, locks: allUnlocked,
                                        groups: weights, using: &rng)
            + G2Mutator.randomize(base: mother, genome: genome, locks: allUnlocked, groups: weights, using: &rng)

        var timbreMoved = false
        for child in children {
            for gene in genome.genes where gene.isMutable {
                let changed = child[gene.key] != mother[gene.key]
                if gene.group != .timbre {
                    XCTAssertFalse(changed, "\(gene.group) ruszone przy profilu Timbre: \(gene.key)")
                } else if changed {
                    timbreMoved = true
                }
            }
        }
        XCTAssertTrue(timbreMoved, "Timbre w ogóle się nie zmienił")
    }

    /// Suwak 50 % w Randomize = połowa drogi do tej samej losowej wartości.
    func testHalfWeightMovesHalfway() throws {
        let patch = try fixture()
        let genome = G2MutatorGenome(patch: patch)
        let base = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        var fullRng = SplitMix64(seed: 3)
        var halfRng = SplitMix64(seed: 3)
        let full = G2Mutator.randomize(base: base, genome: genome, locks: allUnlocked, using: &fullRng)[0]
        let half = G2Mutator.randomize(base: base, genome: genome, locks: allUnlocked,
                                       groups: G2MutatorGroupWeights.full.scaled(to: 0.5),
                                       using: &halfRng)[0]
        for gene in genome.genes {
            guard let old = base[gene.key], let far = full[gene.key], let near = half[gene.key] else { continue }
            XCTAssertEqual(near, old + (far - old) / 2, accuracy: 1e-9)
        }
    }

    func testProfileLightsOnlyForExactWeights() {
        var weights = G2MutatorProfile.keepPitch.weights
        XCTAssertEqual(weights[.pitch], 0)
        XCTAssertEqual(weights[.space], 1)
        XCTAssertEqual(G2MutatorProfile.allCases.filter { $0.weights == weights }, [.keepPitch])
        weights[.space] = 0.95
        XCTAssertTrue(G2MutatorProfile.allCases.allSatisfy { $0.weights != weights })
        weights[.motion] = 7
        XCTAssertEqual(weights[.motion], 1, "suwak nie wychodzi poza 100 %")
    }

    func testStateUsesWeightsOnlyWithPanel() throws {
        let state = PatchState()
        state.slots = try [fixture()]
        state.mutatorLocks = allUnlocked
        state.mutatorSettings.setProbability(1)
        state.mutatorPanel = G2MutatorPanelSettings(onlyAudible: false, poolSize: 0,
                                                    groupWeights: G2MutatorProfile.timbre.weights)
        state.mutatorMutate()
        let mother = try XCTUnwrap(state.mutatorParents[G2Mutator.motherIndex])
        for child in state.mutatorParents.prefix(G2Mutator.childCount).compactMap(\.self) {
            for gene in state.mutatorGenome.genes where gene.group == .pitch {
                XCTAssertEqual(child[gene.key], mother[gene.key])
            }
        }
        XCTAssertEqual(G2MutatorPanelSettings(groupWeights: G2MutatorProfile.timbre.weights)
            .effective(panelOpen: false).groupWeights, .full, "zwinięty panel = oryginał")
    }

    func testPanelControllerRemembersWeights() throws {
        let suite = "MutatorGroupsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let panels = PanelController(defaults: defaults)
        XCTAssertEqual(panels.mutatorPanelSettings.groupWeights, .full)
        panels.mutatorPanelSettings.groupWeights[.envelope] = 0.45
        XCTAssertEqual(PanelController(defaults: defaults).mutatorPanelSettings.groupWeights[.envelope], 0.45)
    }
}

private extension G2MutatorGroupWeights {
    func scaled(to value: Double) -> G2MutatorGroupWeights {
        G2MutatorGroupWeights(Dictionary(uniqueKeysWithValues: G2MutatorGroup.allCases.map { ($0, value) }))
    }
}
