// MutatorFamilyTests.swift
// „Family → Variations": osiem próbek osi Mother → cel w rzędzie magazynu; wariacje,
// Init i bufor odsłuchu nietknięte, dopóki użytkownik nie naciśnie `v`.

import G2Core
@testable import G2EditorCore
import MutatorCore
import XCTest

@MainActor
final class MutatorFamilyTests: XCTestCase {
    private func fixture(_ name: String = "test_3osc") throws -> G2Patch {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("\(name).pch2")
        return try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
    }

    private func state(spacing: G2FamilySpacing = .linear) throws -> PatchState {
        let state = PatchState()
        state.slots = try [fixture()]
        state.mutatorLocks = G2MutatorLocks(enabled: 0xFF)
        state.mutatorPanel = G2MutatorPanelSettings(onlyAudible: false, poolSize: 0, familySpacing: spacing)
        return state
    }

    private func sets(of patch: G2Patch, genome: G2MutatorGenome) -> [G2Individual] {
        (0 ... G2Patch.mutatorVariation).map { G2Mutator.individual(from: patch, variation: $0, genome: genome) }
    }

    private func axis(spacing _: G2FamilySpacing = .linear) throws
        -> (G2MutationAxis, G2MutatorGenome, G2MutatorAnchoring)
    {
        let patch = try fixture()
        let genome = G2MutatorGenome(patch: patch)
        let mother = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        var rng = SplitMix64(seed: 11)
        let target = G2Mutator.randomize(base: mother, genome: genome, locks: G2MutatorLocks(enabled: 0xFF),
                                         using: &rng)[0]
        return (G2MutationAxis(origin: mother, target: target, kind: .random), genome,
                G2MutatorAnchoring(patch: patch, genome: genome, anchors: .off))
    }

    /// Kontrakt §8 i §17: rodzina idzie do magazynu — dziesięć zestawów patcha bez zmian,
    /// wariacje ruszają się dopiero po `v`, a Init (8) i bufor (9) nawet wtedy nie.
    func testFamilyFillsStorageRowOnly() throws {
        let state = try state()
        let genome = state.mutatorGenome
        let before = sets(of: state.patch, genome: genome)

        state.mutatorMakeFamily()
        let mother = try XCTUnwrap(state.mutatorParents[G2Mutator.motherIndex])
        XCTAssertEqual(sets(of: state.patch, genome: genome), before, "rodzina ruszyła patch")
        XCTAssertEqual(state.mutatorFocus, nil, "rodzina nie zabiera focusu ani nie gra")
        let row = Array(state.mutatorStorage[0 ..< 8])
        XCTAssertEqual(row.first, mother, "kratka 1 to Mother bit w bit")
        XCTAssertNotEqual(row.last??.values, mother.values, "kratka 8 to cel, nie Mother")
        XCTAssertEqual(row.compactMap(\.self).count, 8)
        XCTAssertTrue(state.mutatorStorage[8...].allSatisfy { $0 == nil })
        XCTAssertEqual(state.mutatorFamilyRow, 1, "następna rodzina do drugiego rzędu")

        state.mutatorCopyStorageRowToVariations(0)
        let after = sets(of: state.patch, genome: genome)
        for variation in 0 ..< 8 {
            XCTAssertEqual(after[variation].values, try XCTUnwrap(row[variation]).values.mapValues { $0.rounded() },
                           "V\(variation + 1)")
        }
        XCTAssertEqual(after[8], before[8], "Init nietknięty")
        XCTAssertEqual(after[9], before[9], "bufor odsłuchu nietknięty")
    }

    func testFamilyNeedsAnEmptyRow() throws {
        let state = try state()
        state.mutatorMakeFamily()
        state.mutatorMakeFamily()
        state.mutatorMakeFamily()
        XCTAssertNil(state.mutatorFamilyRow)
        XCTAssertTrue(state.mutatorStorage.allSatisfy { $0 != nil })
        let full = state.mutatorStorage
        state.mutatorMakeFamily()
        XCTAssertEqual(state.mutatorStorage, full, "bez pustego rzędu nic się nie dzieje")

        state.mutatorClearStorageRow(1)
        XCTAssertEqual(state.mutatorFamilyRow, 1)
    }

    /// Rodzina jedzie po tej samej osi co fader — ten sam cel, więc kratka 8 = fader na 100 %;
    /// potem cel jest zużyty i następne kliknięcie daje inną rodzinę.
    func testFamilySharesTheFaderAxisThenRollsANewTarget() throws {
        let state = try state()
        state.mutatorAxisSetAmount(0.4)
        state.mutatorAxisEndGesture()
        let axis = try XCTUnwrap(state.mutatorAxis)
        state.mutatorMakeFamily()
        XCTAssertEqual(state.mutatorAxisAmount, 0.4, "fader zostaje, gdzie był")
        XCTAssertEqual(state.mutatorStorage[7]?.values, axis.target.values)
        XCTAssertNil(state.mutatorAxis, "cel zużyty")

        state.mutatorMakeFamily()
        state.mutatorMakeFamily()
        let rows = (0 ..< 3).map { row in state.mutatorStorage[row * 8 + 7]?.values }
        XCTAssertEqual(rows[0], axis.target.values)
        XCTAssertNotEqual(rows[0], rows[1], "druga rodzina taka sama jak pierwsza")
        XCTAssertNotEqual(rows[1], rows[2], "trzecia rodzina taka sama jak druga")
        XCTAssertTrue((0 ..< 3).allSatisfy { state.mutatorStorage[$0 * 8] == axis.origin },
                      "każda rodzina zaczyna od tej samej Mother")
    }

    func testSpacingsStartAtMotherAndEndAtTarget() throws {
        let (axis, genome, anchoring) = try axis()
        for spacing in G2FamilySpacing.allCases {
            let amounts = G2VariationFamily.amounts(axis: axis, spacing: spacing, genome: genome,
                                                    anchoring: anchoring) { _, _ in 1 }
            XCTAssertEqual(amounts.count, 8, spacing.rawValue)
            XCTAssertEqual(amounts.first, 0, spacing.rawValue)
            XCTAssertEqual(try XCTUnwrap(amounts.last), 1, accuracy: 1e-9, spacing.rawValue)
            XCTAssertEqual(amounts, amounts.sorted(), "\(spacing.rawValue): kratki nie rosną")
        }
        let easeIn = G2VariationFamily.amounts(axis: axis, spacing: .easeIn, genome: genome,
                                               anchoring: anchoring) { _, _ in 1 }
        let easeOut = G2VariationFamily.amounts(axis: axis, spacing: .easeOut, genome: genome,
                                                anchoring: anchoring) { _, _ in 1 }
        XCTAssertLessThan(easeIn[1], 1.0 / 7, "Ease in: pierwszy skok mniejszy niż liniowy")
        XCTAssertGreaterThan(easeOut[1], 1.0 / 7, "Ease out: pierwszy skok większy niż liniowy")
    }

    // MARK: - „Smooth" — oś bez skoków

    /// Zapalone grupy zostają na wartości Mother, gałki jadą dalej.
    func testSmoothHoldsTheChosenGroupsAtMother() throws {
        let patch = try fixture()
        let genome = G2MutatorGenome(patch: patch)
        let mother = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        var rng = SplitMix64(seed: 11)
        let wild = G2Mutator.randomize(base: mother, genome: genome, locks: G2MutatorLocks(enabled: 0xFF),
                                       using: &rng)[0]

        let smooth = G2SmoothAxis.all.hold(wild, at: mother, genome: genome)
        var held = 0
        var moved = 0
        for gene in genome.genes {
            guard let before = mother[gene.key], let after = smooth[gene.key] else { continue }
            if gene.discreteStates != nil {
                XCTAssertEqual(after, before, "przycisk miał zostać jak w Mother")
                held += 1
            } else if after != before {
                moved += 1
            }
        }
        XCTAssertGreaterThan(held, 0, "fixture nie ma ani jednego przycisku — test o niczym")
        XCTAssertGreaterThan(moved, 0, "gałki miały jechać dalej")

        // Jedna grupa zapalona rusza tylko swoją połowę.
        let onlySwitches = G2SmoothAxis.switches.hold(wild, at: mother, genome: genome)
        let twoState = genome.genes.filter { $0.discreteStates == 2 }
        let manyState = genome.genes.filter { ($0.discreteStates ?? 0) > 2 }
        XCTAssertFalse(twoState.isEmpty)
        XCTAssertFalse(manyState.isEmpty)
        XCTAssertTrue(twoState.allSatisfy { onlySwitches[$0.key] == mother[$0.key] })
        XCTAssertTrue(manyState.contains { onlySwitches[$0.key] == wild[$0.key] },
                      "selektory miały zostać nietknięte")
    }

    /// Po co to wszystko: z gładką osią „Equal" znowu daje kratki w równych odstępach,
    /// także dla celu z `Randomize` — to ten sam pomiar, który na surowej osi pokazywał
    /// kratki bliźniacze i jeden wielki skok (#110) → [[Docs/roadmap]].
    func testSmoothAxisMakesEqualSpacingEvenAgain() throws {
        let patch = try fixture()
        let genome = G2MutatorGenome(patch: patch)
        let space = try G2EngineSpace(patch: patch, genome: genome)
        let mother = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        let anchoring = G2MutatorAnchoring(patch: patch, genome: genome, anchors: .off)

        for seed in UInt64(1) ... 6 {
            var rng = SplitMix64(seed: seed)
            let wild = G2Mutator.randomize(base: mother, genome: genome, locks: G2MutatorLocks(enabled: 0xFF),
                                           using: &rng)[0]
            let axis = G2MutationAxis(origin: mother,
                                      target: G2SmoothAxis.all.hold(wild, at: mother, genome: genome),
                                      kind: .random, smooth: .all)
            let amounts = G2VariationFamily.amounts(axis: axis, spacing: .equalDistance, genome: genome,
                                                    anchoring: anchoring) { space.distance($0, $1) }
            let sounds = amounts.map { axis.point(at: $0, genome: genome, anchoring: anchoring) }
            let gaps = (1 ..< 8).map { space.distance(sounds[$0 - 1], sounds[$0]) }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            XCTAssertGreaterThan(mean, 0, "ziarno \(seed): oś bez skoków nie może być pusta")
            for gap in gaps {
                XCTAssertEqual(gap, mean, accuracy: mean * 0.15, "ziarno \(seed), kratki nierówno: \(gaps)")
            }
        }
    }

    /// Oś prowadzona wyłącznie po gałkach o pełnej skali — droga bez skoków.
    /// Cel z `Randomize` przestawia także przełączniki i kroki sekwencerów, a każdy
    /// taki przeskok to w metryce jeden duży, niepodzielny sus; przy takiej drodze
    /// ośmiu równych odstępów po prostu nie ma z czego zrobić
    /// → [[Docs/roadmap]] „Family: Equal na drodze z przeskokami".
    private func knobAxis() throws -> (G2MutationAxis, G2MutatorGenome, G2MutatorAnchoring) {
        let patch = try fixture()
        let genome = G2MutatorGenome(patch: patch)
        let mother = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        var target = mother
        for (index, gene) in genome.genes.enumerated()
            where gene.maxValue == 127 && gene.isMutable && !gene.moduleExcluded
        {
            target[gene.key] = Double((index * 37) % 128)
        }
        return (G2MutationAxis(origin: mother, target: target, kind: .random), genome,
                G2MutatorAnchoring(patch: patch, genome: genome, anchors: .off))
    }

    /// „Equal": sąsiednie kratki różnią się o tyle samo w metryce dystansu — także wtedy,
    /// gdy droga jest nierówna (tu: druga połowa liczy się podwójnie).
    func testEqualDistanceEvensOutAnUnevenPath() throws {
        let (axis, genome, anchoring) = try knobAxis()
        let space = try G2EngineSpace(patch: fixture(), genome: genome)
        let amounts = G2VariationFamily.amounts(axis: axis, spacing: .equalDistance, genome: genome,
                                                anchoring: anchoring) { space.distance($0, $1) }
        let sounds = amounts.map { axis.point(at: $0, genome: genome, anchoring: anchoring) }
        let gaps = (1 ..< 8).map { space.distance(sounds[$0 - 1], sounds[$0]) }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        for gap in gaps {
            XCTAssertEqual(gap, mean, accuracy: mean * 0.15, "kratki nierówno: \(gaps)")
        }

        // Metryka, która liczy tylko górną połowę drogi: kratki 2…8 tłoczą się w tej połowie.
        let midpoint = axis.point(at: 0.5, genome: genome, anchoring: anchoring)
        let halfway = space.distance(midpoint, axis.origin)
        let skewed = G2VariationFamily.amounts(axis: axis, spacing: .equalDistance, genome: genome,
                                               anchoring: anchoring)
        { a, b in
            space.distance(a, axis.origin) >= halfway ? space.distance(a, b) : 0
        }
        XCTAssertGreaterThanOrEqual(skewed[1], 0.45, "druga kratka powinna być blisko połowy drogi: \(skewed)")
    }

    func testPanelControllerRemembersSpacing() throws {
        let suite = "MutatorFamilyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let panels = PanelController(defaults: defaults)
        XCTAssertEqual(panels.mutatorPanelSettings.familySpacing, .linear)
        panels.mutatorPanelSettings.familySpacing = .equalDistance
        XCTAssertEqual(PanelController(defaults: defaults).mutatorPanelSettings.familySpacing, .equalDistance)
    }
}
