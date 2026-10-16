// MutatorAxisTests.swift
// „Amount axis" w panelu Mutation settings: fader po zamrożonej drodze Mother → cel,
// New target, Latch, Store, cel z kratki i wysyłka paczkami.

import G2Core
@testable import G2EditorCore
import MutatorCore
import XCTest

@MainActor
final class MutatorAxisTests: XCTestCase {
    private func fixture(_ name: String = "test_3osc") throws -> G2Patch {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("\(name).pch2")
        return try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
    }

    private func state(target: G2MutationAxis.Target = .random) throws -> PatchState {
        let state = PatchState()
        state.slots = try [fixture()]
        state.mutatorLocks = G2MutatorLocks(enabled: 0xFF)
        state.mutatorPanel = G2MutatorPanelSettings(onlyAudible: false, poolSize: 0, axisTarget: target)
        return state
    }

    private func buffer(of state: PatchState) -> G2Individual {
        G2Mutator.individual(from: state.patch, variation: G2Patch.mutatorVariation, genome: state.mutatorGenome)
    }

    /// Kontrakt §8: t = 0 daje bit w bit Mother — także z anchorami, które by coś poprawiły.
    func testZeroIsMotherBitForBit() throws {
        let patch = try fixture("test_all_modules_1")
        let genome = G2MutatorGenome(patch: patch)
        var mother = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        let key = try XCTUnwrap(genome.genes.first(where: \.isMutable)).key
        mother[key] = 40.37
        var rng = SplitMix64(seed: 5)
        let target = G2Mutator.randomize(base: mother, genome: genome, locks: G2MutatorLocks(enabled: 0xFF),
                                         using: &rng)[0]
        let axis = G2MutationAxis(origin: mother, target: target, kind: .random)
        let anchoring = G2MutatorAnchoring(patch: patch, genome: genome,
                                           anchors: G2MutatorAnchors(rootPitch: 0, loudness: 0.1, tempoGrid: true))
        XCTAssertEqual(axis.point(at: 0, genome: genome, anchoring: anchoring), mother)

        let off = G2MutatorAnchoring(patch: patch, genome: genome, anchors: .off)
        XCTAssertEqual(axis.point(at: 1, genome: genome, anchoring: off).values, target.values)
        let half = axis.point(at: 0.5, genome: genome, anchoring: off)
        for gene in genome.genes {
            guard let a = mother[gene.key], let b = target[gene.key] else { continue }
            XCTAssertEqual(try XCTUnwrap(half[gene.key]), (a + b) / 2, accuracy: 1e-9)
        }
    }

    /// „Smooth" z panelu działa na osi fadera: z obiema grupami zapalonymi żaden
    /// przycisk ani selektor nie odjeżdża od Mother, a gałki jadą normalnie. Zmiana
    /// ustawienia unieważnia oś — inaczej fader jechałby dalej po starym celu.
    func testSmoothPanelSettingHoldsButtonsOnTheFaderAxis() throws {
        let state = try state()
        state.mutatorPanel.smoothAxis = .all
        state.mutatorAxisSetAmount(1)
        state.mutatorAxisEndGesture()

        let genome = state.mutatorGenome
        let mother = try XCTUnwrap(state.mutatorParents[G2Mutator.motherIndex])
        let sound = buffer(of: state)
        var moved = 0
        for gene in genome.genes {
            guard let before = mother[gene.key], let after = sound[gene.key] else { continue }
            if gene.discreteStates != nil {
                XCTAssertEqual(after, before.rounded(), "\(gene.key) miał zostać jak w Mother")
            } else if after != before.rounded() {
                moved += 1
            }
        }
        XCTAssertGreaterThan(moved, 0, "gałki miały jechać")

        let smoothAxis = try XCTUnwrap(state.mutatorAxis)
        state.mutatorPanel.smoothAxis = []
        state.mutatorAxisSetAmount(1)
        state.mutatorAxisEndGesture()
        XCTAssertNotEqual(state.mutatorAxis?.target, smoothAxis.target,
                          "zmiana ustawienia Smooth musi policzyć oś od nowa")
    }

    /// Fader nie losuje: ten sam procent = ten sam dźwięk, powrót na 0 % = Mother.
    func testFaderSlidesOnFrozenTarget() throws {
        let state = try state()
        state.mutatorAxisSetAmount(0.6)
        state.mutatorAxisEndGesture()
        let axis = try XCTUnwrap(state.mutatorAxis)
        let atSixty = buffer(of: state)
        XCTAssertNotEqual(atSixty.values, axis.origin.values, "fader nic nie zmienił")

        state.mutatorAxisSetAmount(0.2)
        state.mutatorAxisEndGesture()
        state.mutatorAxisSetAmount(0.6)
        state.mutatorAxisEndGesture()
        XCTAssertEqual(state.mutatorAxis, axis, "ruch fadera wylosował nowy cel")
        XCTAssertEqual(buffer(of: state).values, atSixty.values)

        state.mutatorAxisSetAmount(0)
        state.mutatorAxisEndGesture()
        let mother = try XCTUnwrap(state.mutatorParents[G2Mutator.motherIndex])
        XCTAssertEqual(mother, axis.origin)
        XCTAssertEqual(buffer(of: state).values, mother.values.mapValues { $0.rounded() })
    }

    func testNewTargetKeepsAmount() throws {
        let state = try state(target: .mutate)
        state.mutatorSettings.setProbability(1)
        state.mutatorAxisSetAmount(0.5)
        state.mutatorAxisEndGesture()
        let first = try XCTUnwrap(state.mutatorAxis)
        XCTAssertEqual(first.kind, .mutate)
        state.mutatorAxisNewTarget()
        XCTAssertEqual(state.mutatorAxisAmount, 0.5)
        XCTAssertNotEqual(state.mutatorAxis?.target, first.target)
        XCTAssertEqual(state.mutatorAxis?.origin, first.origin)
    }

    func testLatchAndStore() throws {
        let state = try state()
        state.mutatorAxisSetAmount(0.3)
        state.mutatorAxisEndGesture()
        let axis = try XCTUnwrap(state.mutatorAxis)
        let point = axis.point(at: 0.3, genome: state.mutatorGenome, anchoring: state.mutatorAnchoring())

        state.mutatorAxisStore()
        XCTAssertEqual(state.mutatorStorage[0], point)

        state.mutatorAxisLatch()
        XCTAssertEqual(state.mutatorParents[G2Mutator.motherIndex], point)
        XCTAssertEqual(state.mutatorAxisAmount, 0)
        XCTAssertEqual(state.mutatorAxis?.target, axis.target, "Latch zostawia cel")
        XCTAssertEqual(state.mutatorAxis?.origin, point)

        state.mutatorAxisLatch()
        XCTAssertEqual(state.mutatorParents[G2Mutator.motherIndex], point, "na 0 % Latch nic nie robi")
    }

    func testFocusTargetIsTheClickedSound() throws {
        let state = try state(target: .focus)
        XCTAssertFalse(state.mutatorAxisHasTarget)
        state.mutatorAxisSetAmount(0.5)
        state.mutatorAxisEndGesture()
        XCTAssertNil(state.mutatorAxis, "bez kratki nie ma dokąd jechać")

        state.mutatorMutate()
        state.mutatorSetFocus(.child(2))
        XCTAssertTrue(state.mutatorAxisHasTarget)
        state.mutatorAxisSetAmount(1)
        state.mutatorAxisEndGesture()
        XCTAssertEqual(state.mutatorAxis?.target, state.mutatorParents[2])
        XCTAssertEqual(state.mutatorFocus, .child(2), "fader nie zabiera focusu")
    }

    /// Pod faderem każdy krok idzie **jednym zrzutem bufora**, tak samo jak klik
    /// w kratkę — od kroku 1.5 nie ma już drogi „parametr po parametrze" ani paczkowej
    /// (→ [[Docs/usb/mutator-dump]]).
    func testFaderSendsOneDumpPerStep() throws {
        let state = try state()
        state.mutatorMutate()
        var single = 0
        var batches = 0
        var dumps: [Int] = []
        state.onLiveParameterChange = { _, _, _, _, _, _ in single += 1 }
        state.onLiveParameterBatch = { _, _, _ in batches += 1 }
        state.onMutatorAudition = { _, _, variation in dumps.append(variation) }
        state.mutatorAxisSetAmount(1)
        state.mutatorAxisEndGesture()
        XCTAssertEqual(single, 0)
        XCTAssertEqual(batches, 0)
        XCTAssertEqual(dumps, [G2Patch.mutatorVariation])
    }

    func testPanelControllerRemembersTarget() throws {
        let suite = "MutatorAxisTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let panels = PanelController(defaults: defaults)
        XCTAssertEqual(panels.mutatorPanelSettings.axisTarget, .random)
        panels.mutatorPanelSettings.axisTarget = .focus
        XCTAssertEqual(PanelController(defaults: defaults).mutatorPanelSettings.axisTarget, .focus)
    }
}
