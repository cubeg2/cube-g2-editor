// MutatorAnchorsTests.swift
// „Anchors" w panelu Mutation settings: gałki zostają jak w Mother, strój w oknie,
// suma poziomów w granicy, zsynchronizowane tempo na prostych nutach.

@testable import G2Core
@testable import G2EditorCore
import MutatorCore
import XCTest

@MainActor
final class MutatorAnchorsTests: XCTestCase {
    private func fixture(_ name: String = "test_3osc") throws -> G2Patch {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("\(name).pch2")
        return try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
    }

    private let allUnlocked = G2MutatorLocks(enabled: 0xFF)

    /// Kontrakt §17: anchor Knob assigned ⇒ parametry z gałek identyczne z Mother.
    func testKnobAssignedKeepsMotherValues() throws {
        var patch = try fixture()
        let genome = G2MutatorGenome(patch: patch)
        let assigned = genome.genes.filter(\.isMutable).prefix(3).map(\.key)
        for (index, key) in assigned.enumerated() {
            patch.knobAssignments[index] = G2KnobAssignment(location: key.location, moduleID: key.moduleID,
                                                            paramIndex: key.paramIndex)
        }
        let mother = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        var father = mother
        for gene in genome.genes where gene.isMutable {
            father[gene.key] = Double(gene.maxValue) - (mother[gene.key] ?? 0)
        }
        let anchoring = G2MutatorAnchoring(patch: patch, genome: genome, anchors: G2MutatorAnchors())
        var rng = SplitMix64(seed: 7)
        let children = G2Mutator.randomize(base: mother, genome: genome, locks: allUnlocked, using: &rng)
            + G2Mutator.interpolate(mother: mother, father: father, genome: genome)
            + G2Mutator.cross(mother: mother, father: father, genome: genome,
                              settings: G2MutatorSettings(crossProbability: 0.5), using: &rng)

        var othersMoved = false
        for child in anchoring.apply(children, mother: mother) {
            for key in assigned {
                XCTAssertEqual(child[key], mother[key], "gałka \(key) ruszona")
            }
            othersMoved = othersMoved || genome.genes.contains { !assigned.contains($0.key) && child[$0.key] != mother[$0.key] }
        }
        XCTAssertTrue(othersMoved, "reszta patcha powinna się zmieniać")
    }

    func testRootPitchStaysInWindow() throws {
        let patch = try fixture()
        let genome = G2MutatorGenome(patch: patch)
        let pitch = genome.genes.filter { $0.category == .oscFreq }
        XCTAssertFalse(pitch.isEmpty)
        let mother = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        let anchoring = G2MutatorAnchoring(patch: patch, genome: genome,
                                           anchors: G2MutatorAnchors(knobAssigned: false, rootPitch: 2))
        var rng = SplitMix64(seed: 13)
        for child in anchoring.apply(G2Mutator.randomize(base: mother, genome: genome, locks: allUnlocked,
                                                         using: &rng), mother: mother)
        {
            for gene in pitch {
                let drift = try abs(XCTUnwrap(child[gene.key]) - XCTUnwrap(mother[gene.key]))
                XCTAssertLessThanOrEqual(drift, 2 + 1e-9, "\(gene.key)")
            }
        }
    }

    func testLoudnessScalesMixerLevelsBack() throws {
        let patch = try fixture("test_all_modules_2")
        let genome = G2MutatorGenome(patch: patch)
        let modules = Dictionary(uniqueKeysWithValues: (patch.modules(in: .voice) + patch.modules(in: .fx))
            .map { (G2Individual.Key(area: $0.area, moduleID: $0.id, paramIndex: 0), $0.typeID) })
        let levels = genome.genes.filter { gene in
            guard let typeID = modules[G2Individual.Key(area: gene.area, moduleID: gene.moduleID, paramIndex: 0)]
            else { return false }
            return G2ParamClass.of(moduleTypeID: typeID, paramIndex: gene.paramIndex)?.rawValue == 0x3A
        }
        XCTAssertFalse(levels.isEmpty, "fixture bez mikserów")

        var mother = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        var child = mother
        for gene in levels {
            mother[gene.key] = 20
            child[gene.key] = 120
        }
        let motherSum = Double(levels.count) * 20
        let anchoring = G2MutatorAnchoring(patch: patch, genome: genome,
                                           anchors: G2MutatorAnchors(knobAssigned: false, loudness: 0.25))
        let fixed = anchoring.apply(child, mother: mother)
        let fixedSum = levels.compactMap { fixed[$0.key] }.reduce(0, +)
        XCTAssertEqual(fixedSum - motherSum, 0.25 * max(motherSum, 127), accuracy: 1e-6)
        XCTAssertTrue(levels.allSatisfy { (fixed[$0.key] ?? 0) > 20 }, "kierunek zmiany zostaje")
    }

    func testTempoGridSnapsSyncedRatesToStraightNotes() throws {
        XCTAssertEqual(G2MutatorAnchoring.straightDelay.map { g2DelayClockSync($0) }.uniqued(),
                       ["1/64", "1/32", "1/16", "1/8", "1/4", "1/2", "1/1", "2/1"])
        XCTAssertFalse(G2MutatorAnchoring.straightLFO.map { g2LFOClockStr($0) }.contains("48/1"))

        let patch = try fixture("test_all_modules_1")
        let genome = G2MutatorGenome(patch: patch)
        let lfo = try XCTUnwrap(patch.modules(in: .voice).first { module in
            ModuleUIDatabase.shared.uiDef(forID: module.typeID)?.textFields.contains { $0.textFunc == 103 } == true
        }, "fixture bez LFO")
        let field = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: lfo.typeID)?.textFields.first { $0.textFunc == 103 })
        let rate = G2Individual.Key(area: .voice, moduleID: lfo.id, paramIndex: field.dependencies[0])
        let mode = G2Individual.Key(area: .voice, moduleID: lfo.id, paramIndex: field.dependencies[1])

        var child = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        child[rate] = 57 // 1/1T
        let anchoring = G2MutatorAnchoring(patch: patch, genome: genome,
                                           anchors: G2MutatorAnchors(knobAssigned: false, tempoGrid: true))
        child[mode] = 2 // Rate Hi — nie zegar, zostaje
        XCTAssertEqual(anchoring.apply(child, mother: child)[rate], 57)
        child[mode] = 4 // Clk
        let snapped = try XCTUnwrap(anchoring.apply(child, mother: child)[rate])
        XCTAssertTrue(G2MutatorAnchoring.isStraightNote(g2LFOClockStr(Int(snapped))), g2LFOClockStr(Int(snapped)))
    }

    func testStateAnchorsOnlyWithPanel() throws {
        let state = PatchState()
        var patch = try fixture()
        let key = try XCTUnwrap(state.mutatorGenome(of: patch).genes.first(where: \.isMutable)).key
        patch.knobAssignments[0] = G2KnobAssignment(location: key.location, moduleID: key.moduleID,
                                                    paramIndex: key.paramIndex)
        state.slots = [patch]
        state.mutatorLocks = allUnlocked
        state.mutatorPanel = G2MutatorPanelSettings(onlyAudible: false, poolSize: 0)
        state.mutatorRandomize()
        let mother = try XCTUnwrap(state.mutatorParents[G2Mutator.motherIndex])
        for child in state.mutatorParents.prefix(G2Mutator.childCount).compactMap(\.self) {
            XCTAssertEqual(child[key], mother[key])
        }
        XCTAssertTrue(G2MutatorPanelSettings().effective(panelOpen: false).anchors.isOff, "zwinięty panel = oryginał")
    }

    func testPanelControllerRemembersAnchors() throws {
        let suite = "MutatorAnchorsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let panels = PanelController(defaults: defaults)
        XCTAssertEqual(panels.mutatorPanelSettings.anchors, G2MutatorAnchors())
        panels.mutatorPanelSettings.anchors = G2MutatorAnchors(knobAssigned: false, rootPitch: 7,
                                                               loudness: 0.5, tempoGrid: true)
        XCTAssertEqual(PanelController(defaults: defaults).mutatorPanelSettings.anchors,
                       G2MutatorAnchors(knobAssigned: false, rootPitch: 7, loudness: 0.5, tempoGrid: true))
        panels.mutatorPanelSettings.anchors.rootPitch = nil
        XCTAssertNil(PanelController(defaults: defaults).mutatorPanelSettings.anchors.rootPitch)
    }
}

private extension PatchState {
    func mutatorGenome(of patch: G2Patch) -> G2MutatorGenome {
        G2MutatorGenome(patch: patch)
    }
}

private extension [String] {
    func uniqued() -> [String] {
        reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }
}
