// MutatorPoolTests.swift
// „Pool & Diversity" w panelu Mutation settings: pula kandydatów, wybór sześciorga
// najbardziej różnych, które przyciski z niej losują i że zwinięty panel puli nie używa.

import G2Core
@testable import G2EditorCore
import MutatorCore
import XCTest

@MainActor
final class MutatorPoolTests: XCTestCase {
    private func fixture() throws -> G2Patch {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("test_3osc.pch2")
        return try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
    }

    /// Kandydaci z puli są dalej od Mother niż sześcioro zwykłych dzieci — na tym samym
    /// ziarnie, więc wynik jest stały.
    func testPoolPicksChildrenFurtherFromMother() throws {
        let patch = try fixture()
        let genome = G2MutatorGenome(patch: patch)
        let space = G2EngineSpace(patch: patch, genome: genome)
        let mother = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        let settings = G2MutatorSettings(probability: 0.3, range: 0.2, link: false)
        var rng = SplitMix64(seed: 5)
        var pool: [G2Individual] = []
        while pool.count < 64 {
            pool += G2Mutator.mutate(parent: mother, genome: genome, settings: settings,
                                     locks: G2MutatorLocks(enabled: 0xFF), using: &rng)
        }
        let chosen = space.mostDifferent(6, from: pool, parents: [mother])
        XCTAssertEqual(chosen.count, 6)
        XCTAssertTrue(chosen.allSatisfy { child in pool.contains(child) }, "wybór spoza puli")

        let diversity = Diversity(space: space.space)
        func spread(_ children: [G2Individual]) -> Double {
            children.map { diversity.distance(space.genome(of: $0), space.genome(of: mother)) }.reduce(0, +)
        }
        XCTAssertGreaterThan(spread(chosen), spread(Array(pool.prefix(6))))
    }

    func testOperationUsesPoolOnlyWhenLit() throws {
        let state = PatchState()
        state.slots = try [fixture()]
        let mother = state.currentIndividual()
        var batches = 0
        let batch = { () -> [G2Individual] in
            batches += 1
            return Array(repeating: mother, count: G2Mutator.childCount)
        }

        state.mutatorPanel = .standard
        XCTAssertEqual(state.pooled(.mutate, parents: [mother], audibility: nil, batch: batch).count, 6)
        XCTAssertEqual(batches, 1, "Standard — jedno zwykłe losowanie")

        batches = 0
        state.mutatorPanel = G2MutatorPanelSettings(poolSize: 32, poolOperations: [.mutate])
        XCTAssertEqual(state.pooled(.mutate, parents: [mother], audibility: nil, batch: batch).count, 6)
        XCTAssertEqual(batches, 6, "32 kandydatów po sześcioro")

        batches = 0
        _ = state.pooled(.cross, parents: [mother], audibility: nil, batch: batch)
        XCTAssertEqual(batches, 1, "Cross zgaszony — bez puli")
    }

    func testCollapsedPanelHasNoPool() {
        let open = G2MutatorPanelSettings(poolSize: 64)
        for operation in G2MutatorPanelSettings.PoolOperation.allCases {
            XCTAssertEqual(open.pool(for: operation), 64)
            XCTAssertNil(open.effective(panelOpen: false).pool(for: operation))
        }
        XCTAssertNil(G2MutatorPanelSettings(poolSize: 0).pool(for: .mutate))
    }

    func testPanelControllerRemembersPool() throws {
        let suite = "MutatorPoolTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let panels = PanelController(defaults: defaults)
        XCTAssertEqual(panels.mutatorPanelSettings.poolSize, 32)
        XCTAssertEqual(panels.mutatorPanelSettings.poolOperations, [.mutate, .randomize, .cross])

        panels.mutatorPanelSettings.poolSize = 64
        panels.mutatorPanelSettings.poolOperations = [.randomize]
        let reloaded = PanelController(defaults: defaults).mutatorPanelSettings
        XCTAssertEqual(reloaded.poolSize, 64)
        XCTAssertEqual(reloaded.poolOperations, [.randomize])
    }
}
