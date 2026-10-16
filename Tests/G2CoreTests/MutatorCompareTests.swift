// MutatorCompareTests.swift
// „Compare": A/B uchem — A to Mother, B kratka z ⌘-kliku, spacja przełącza. Obie strony
// grają przez bufor odsłuchu (albo przełączenie wariacji), więc żadna wariacja nie ginie.

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class MutatorCompareTests: XCTestCase {
    private let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("test_3osc.pch2")

    private func state() throws -> PatchState {
        let state = PatchState()
        state.slots = try [XCTUnwrap(PatchParser.parse(data: Data(contentsOf: fixtureURL)).first)]
        state.mutatorLocks = G2MutatorLocks(enabled: 0xFF)
        state.mutatorMutate()
        return state
    }

    private func buffer(of state: PatchState) -> G2Individual {
        G2Mutator.individual(from: state.patch, variation: G2Patch.mutatorVariation, genome: state.mutatorGenome)
    }

    func testCommandClickMarksBAndSpaceSwitchesWithMother() throws {
        let state = try state()
        XCTAssertNil(state.mutatorCompare)
        XCTAssertNil(state.mutatorComparePlaying)
        let mother = try XCTUnwrap(state.mutatorParents[G2Mutator.motherIndex])
        let child = try XCTUnwrap(state.mutatorIndividual(at: .child(2)))

        state.mutatorSetCompare(.child(2))
        XCTAssertEqual(state.mutatorCompare, .child(2))
        XCTAssertEqual(state.mutatorFocus, .child(2), "⌘-klik to też zwykły klik: kratka gra")
        XCTAssertEqual(state.mutatorComparePlaying, .b)
        XCTAssertEqual(buffer(of: state).values, child.values.mapValues { $0.rounded() })

        state.mutatorCompareToggle()
        XCTAssertEqual(state.mutatorComparePlaying, .a)
        XCTAssertEqual(state.mutatorFocus, .mother)
        XCTAssertEqual(buffer(of: state).values, mother.values.mapValues { $0.rounded() })
        XCTAssertEqual(state.mutatorCompare, .child(2), "B zostaje, gdy gra A")

        state.mutatorCompareToggle()
        XCTAssertEqual(state.mutatorComparePlaying, .b)
        XCTAssertEqual(buffer(of: state).values, child.values.mapValues { $0.rounded() })
        XCTAssertTrue(state.isAuditioningMutation, "obie strony grają z bufora, wariacje nietknięte")
    }

    func testBSurvivesPlainClicksElsewhere() throws {
        let state = try state()
        state.mutatorSetCompare(.child(1))
        state.mutatorSetFocus(.child(4))
        XCTAssertEqual(state.mutatorCompare, .child(1))
        XCTAssertNil(state.mutatorComparePlaying, "gra coś trzeciego")

        state.mutatorCompareToggle()
        XCTAssertEqual(state.mutatorComparePlaying, .b, "spacja przy czymś trzecim najpierw gra B")
        state.mutatorComparePlay(.a)
        XCTAssertEqual(state.mutatorFocus, .mother)
    }

    func testMotherAndEmptyBoxesCannotBeB() throws {
        let state = try state()
        state.mutatorSetCompare(.mother)
        XCTAssertNil(state.mutatorCompare)
        state.mutatorSetCompare(G2MutatorBox(.storage, 5))
        XCTAssertNil(state.mutatorCompare, "pusta kratka magazynu")
        state.mutatorCompareToggle()
        XCTAssertEqual(state.mutatorFocus, .child(0), "bez B spacja nic nie robi")
    }

    func testBVanishesWhenItsBoxEmpties() throws {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.undoManager.beginUndoGrouping()
        state.slots = try [XCTUnwrap(PatchParser.parse(data: Data(contentsOf: fixtureURL)).first)]
        state.mutatorMutate()
        state.mutatorStore(.child(3))
        let stored = G2MutatorBox(.storage, 0)
        state.mutatorSetCompare(stored)
        state.undoManager.endUndoGrouping()
        XCTAssertEqual(state.mutatorCompare, stored)

        state.undoManager.beginUndoGrouping()
        state.mutatorDelete(stored)
        state.undoManager.endUndoGrouping()
        XCTAssertNil(state.mutatorCompare)
        XCTAssertNil(state.mutatorComparePlaying)

        state.undoManager.undo()
        XCTAssertEqual(state.mutatorCompare, stored, "undo przywraca kratkę, więc i B")
    }

    /// Bez Mother (świeże okno) ⌘-klik w wariację: Mother bierze bieżący dźwięk, a A/B
    /// przełącza między buforem a wariacją — jak przycisk wariacji na Nordzie.
    func testVariationAsBAgainstAFreshMother() throws {
        let state = PatchState()
        state.slots = try [XCTUnwrap(PatchParser.parse(data: Data(contentsOf: fixtureURL)).first)]
        let current = state.currentIndividual()

        state.mutatorSetCompare(G2MutatorBox(.variations, 3))
        XCTAssertEqual(state.mutatorParents[G2Mutator.motherIndex], current, "pusta Mother = bieżący dźwięk")
        XCTAssertEqual(state.patch.activeVariation, 3)
        XCTAssertEqual(state.mutatorComparePlaying, .b)

        state.mutatorCompareToggle()
        XCTAssertEqual(state.mutatorComparePlaying, .a)
        XCTAssertTrue(state.isAuditioningMutation)
        XCTAssertEqual(buffer(of: state).values, current.values)

        state.mutatorCompareToggle()
        XCTAssertEqual(state.patch.activeVariation, 3)
        XCTAssertEqual(state.mutatorComparePlaying, .b)
    }
}

extension MutatorCompareTests {
    /// Przełącznik „A = Father": liczy się tylko przy niepustym Father; Father jako B
    /// znika, gdy staje się stroną A.
    func testFatherCanBeSideA() throws {
        let state = try state()
        state.mutatorSetCompare(.child(0))
        state.mutatorCompareSwitchA()
        XCTAssertEqual(state.mutatorCompareA, .mother, "bez Father przycisk A gra Mother")
        XCTAssertEqual(state.mutatorFocus, .mother)

        state.mutatorCopyToParent(.child(5), mother: false)
        let father = try XCTUnwrap(state.mutatorIndividual(at: .father))
        state.mutatorCompareSwitchA()
        XCTAssertEqual(state.mutatorCompareA, .father, "z Father przycisk A przełącza rodzica")
        XCTAssertEqual(state.mutatorComparePlaying, .a)
        XCTAssertEqual(state.mutatorFocus, .father)
        XCTAssertEqual(buffer(of: state).values, father.values.mapValues { $0.rounded() })
        state.mutatorCompareToggle()
        XCTAssertEqual(state.mutatorFocus, .child(0), "spacja: B")
        state.mutatorCompareToggle()
        XCTAssertEqual(state.mutatorFocus, .father, "spacja wraca do A, czyli Father")
        state.mutatorCompareSwitchA()
        XCTAssertEqual(state.mutatorFocus, .mother, "przycisk A: znów Mother")
        state.mutatorCompareAgainstFather = true

        state.mutatorSetCompare(.father)
        XCTAssertNil(state.mutatorCompare, "Father nie może być B, gdy jest A")
        state.mutatorCompareAgainstFather = false
        XCTAssertEqual(state.mutatorCompare, .father, "Mother kontra Father")
        XCTAssertEqual(state.mutatorComparePlaying, .b)
    }
}
