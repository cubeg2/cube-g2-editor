// MutatorTreeTests.swift
// „Tree": drzewo ewolucji pamięta każdy dźwięk z rodzicami i przyciskiem; ten sam dźwięk
// to jeden węzeł; undo cofa kratki, nie drzewo; klik w węzeł gra przez bufor odsłuchu.

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class MutatorTreeTests: XCTestCase {
    private let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("test_3osc.pch2")

    private func state() throws -> PatchState {
        let state = PatchState()
        state.slots = try [XCTUnwrap(PatchParser.parse(data: Data(contentsOf: fixtureURL)).first)]
        state.mutatorLocks = G2MutatorLocks(enabled: 0xFF)
        return state
    }

    private func buffer(of state: PatchState) -> G2Individual {
        G2Mutator.individual(from: state.patch, variation: G2Patch.mutatorVariation, genome: state.mutatorGenome)
    }

    private func node(_ state: PatchState, at box: G2MutatorBox) throws -> G2MutatorTree.NodeID {
        try XCTUnwrap(state.mutatorTree.node(of: XCTUnwrap(state.mutatorIndividual(at: box))))
    }

    func testFirstMutateRootsThePatchAndAddsSixChildren() throws {
        let state = try state()
        XCTAssertTrue(state.mutatorTree.isEmpty)
        XCTAssertEqual(state.mutatorTree.generations, 0)

        state.mutatorMutate()
        let tree = state.mutatorTree
        XCTAssertEqual(tree.count, 7)
        XCTAssertEqual(tree.roots.count, 1)
        XCTAssertEqual(tree.generations, 2)
        let root = try XCTUnwrap(tree.roots.first)
        XCTAssertEqual(tree.sound(of: root), state.mutatorParents[G2Mutator.motherIndex])
        XCTAssertEqual(tree[root].origin, .patch)
        XCTAssertEqual(tree[root].children.count, 6)
        for child in tree[root].children {
            XCTAssertEqual(tree[child].parents, [root])
            XCTAssertEqual(tree[child].origin, .mutate)
            XCTAssertEqual(tree[child].generation, 1)
            XCTAssertEqual(tree[child].breed, 1)
        }
        XCTAssertEqual(state.mutatorTreePlaying, try node(state, at: .child(0)), "gra pierwsze dziecko")
        XCTAssertEqual(tree.batches(of: root).map(\.members.count), [6])
    }

    func testBreedingFromAChildGrowsAGenerationAndKeepsSiblings() throws {
        let state = try state()
        state.mutatorMutate()
        let picked = try node(state, at: .child(2))
        state.mutatorMutate(from: .child(2))
        let tree = state.mutatorTree
        XCTAssertEqual(tree.count, 13)
        let root = try XCTUnwrap(tree.roots.first)
        let grandchild = try node(state, at: .child(0))
        XCTAssertEqual(tree.ancestors(of: grandchild), [root, picked, grandchild])
        XCTAssertEqual(tree[grandchild].generation, 2)
        XCTAssertEqual(tree.batches(of: root).count, 1, "stara miotka zostaje")
        XCTAssertEqual(tree.batches(of: picked).map(\.breed), [2])
        XCTAssertEqual(tree.siblings(of: grandchild).count, 6)
        XCTAssertEqual(tree.descendantCount(of: root), 12)
        XCTAssertEqual(tree.descendantCount(of: picked), 6)
    }

    func testCrossAndInterpolateRecordBothParents() throws {
        let state = try state()
        state.mutatorMutate()
        state.mutatorCopyToParent(.child(5), mother: false)
        let mother = try node(state, at: .mother)
        let father = try node(state, at: .father)

        // Dziecko bywa bit w bit równe któremuś rodzicowi, a ten sam dźwięk to jeden węzeł —
        // kratka wskazuje wtedy węzeł rodzica, nie nowy. Dlatego pytamy nie o numer kratki,
        // tylko o węzły, które ta hodowla naprawdę założyła: `nodes` rośnie i nic z niej nie znika.
        var known = state.mutatorTree.count
        state.mutatorCross()
        var tree = state.mutatorTree
        let crossed = tree.nodes[known...].map(\.id)
        XCTAssertFalse(crossed.isEmpty, "krzyżowanie zakłada nowe węzły")
        for child in crossed {
            XCTAssertEqual(tree[child].parents, [mother, father])
            XCTAssertEqual(tree[child].origin, .cross)
            XCTAssertTrue(tree[father].children.contains(child), "ale Father też ją zna")
        }
        let batch = try XCTUnwrap(tree.batches(of: mother).last)
        XCTAssertEqual(batch.otherParent, father)
        XCTAssertEqual(batch.members, crossed, "miotka to dokładnie te nowe węzły")
        XCTAssertTrue(tree.batches(of: father).isEmpty, "miotka należy do rzędu Mother")

        known = tree.count
        state.mutatorInterpolate()
        tree = state.mutatorTree
        let interpolated = tree.nodes[known...].map(\.id)
        XCTAssertFalse(interpolated.isEmpty, "interpolacja zakłada nowe węzły")
        for child in interpolated {
            XCTAssertEqual(tree[child].origin, .interpolate)
        }
        XCTAssertEqual(tree.batches(of: mother).count, 3)
    }

    /// Kratka 1 rodziny to Mother bit w bit — ten sam węzeł, nie nowy; Latch i Store
    /// spod fadera zapisują się jako „Amount" pod Mother.
    func testSameSoundIsOneNodeAndAxisSoundsJoinTheTree() throws {
        let state = try state()
        state.mutatorPanel = G2MutatorPanelSettings(onlyAudible: false, poolSize: 0, familySpacing: .linear)
        state.mutatorMutate()
        let mother = try node(state, at: .mother)

        state.mutatorMakeFamily()
        var tree = state.mutatorTree
        XCTAssertEqual(tree.count, 7 + 7, "osiem kratek, ale kratka 1 to Mother")
        XCTAssertEqual(try tree.node(of: XCTUnwrap(state.mutatorStorage[0])), mother)
        let family = try XCTUnwrap(tree.batches(of: mother).last)
        XCTAssertEqual(family.origin, .family)
        XCTAssertEqual(family.members.count, 7)
        XCTAssertEqual(tree[family.members[0]].ordinal, 1, "kratka 2 rodziny")

        state.mutatorAxisSetAmount(0.5)
        state.mutatorAxisEndGesture()
        XCTAssertEqual(state.mutatorTree.count, 14, "fader w pół drogi nie zakłada węzłów")
        state.mutatorAxisLatch()
        tree = state.mutatorTree
        XCTAssertEqual(tree.count, 15)
        let latched = try node(state, at: .mother)
        XCTAssertEqual(tree[latched].origin, .amount)
        XCTAssertEqual(tree[latched].parents, [mother])
    }

    func testUndoKeepsTheTreeAndAnotherPatchClearsIt() throws {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.slots = try [XCTUnwrap(PatchParser.parse(data: Data(contentsOf: fixtureURL)).first)]
        state.undoManager.beginUndoGrouping()
        state.mutatorMutate()
        state.undoManager.endUndoGrouping()
        XCTAssertEqual(state.mutatorTree.count, 7)

        state.undoManager.undo()
        XCTAssertNil(state.mutatorParents[G2Mutator.motherIndex], "kratki cofnięte")
        XCTAssertEqual(state.mutatorTree.count, 7, "historia zostaje")

        state.clearMutations()
        XCTAssertTrue(state.mutatorTree.isEmpty)
        XCTAssertNil(state.mutatorTreePlaying)
    }

    func testPlayingANodeUsesItsBoxOrTheBufferAlone() throws {
        let state = try state()
        state.mutatorMutate()
        let root = try XCTUnwrap(state.mutatorTree.roots.first)
        let child = try node(state, at: .child(3))

        state.mutatorSetFocus(.child(3))
        XCTAssertEqual(state.mutatorTreePlaying, child)
        state.mutatorPlay(node: root)
        XCTAssertEqual(state.mutatorFocus, .mother, "korzeń siedzi w Mother, więc świeci Mother")
        XCTAssertEqual(state.mutatorTreePlaying, root)
        XCTAssertEqual(state.mutatorBoxes(of: root), [.mother])

        // Mother nadpisana dzieckiem: korzeń nie ma już kratki, gra prosto z drzewa.
        state.mutatorCopyToParent(.child(1), mother: true)
        XCTAssertTrue(state.mutatorBoxes(of: root).isEmpty)
        state.mutatorPlay(node: root)
        XCTAssertNil(state.mutatorFocus)
        XCTAssertEqual(state.mutatorTreePlaying, root)
        XCTAssertTrue(state.isAuditioningMutation)
        XCTAssertEqual(buffer(of: state).values, state.mutatorTree.sound(of: root).values.mapValues { $0.rounded() })

        state.mutatorSetFocus(.child(0))
        XCTAssertEqual(state.mutatorTreePlaying, try node(state, at: .child(0)), "klik w kratkę odwołuje węzeł")
    }

    func testStepsWalkSiblingsParentsAndLatestChildren() throws {
        let state = try state()
        state.mutatorMutate()
        let root = try XCTUnwrap(state.mutatorTree.roots.first)
        let first = try node(state, at: .child(0))
        let second = try node(state, at: .child(1))

        state.mutatorTreeStep(.right)
        XCTAssertEqual(state.mutatorTreePlaying, second)
        XCTAssertEqual(state.mutatorFocus, .child(1))
        state.mutatorTreeStep(.left)
        XCTAssertEqual(state.mutatorTreePlaying, first)
        state.mutatorTreeStep(.left)
        XCTAssertEqual(state.mutatorTreePlaying, first, "na brzegu miotki nic się nie dzieje")
        state.mutatorTreeStep(.up)
        XCTAssertEqual(state.mutatorTreePlaying, root)

        state.mutatorMutate(from: .child(4))
        let newest = try node(state, at: .child(0))
        state.mutatorPlay(node: root)
        state.mutatorTreeStep(.down)
        XCTAssertEqual(state.mutatorTreePlaying, first, "w dół: pierwsze dziecko najnowszej miotki korzenia")
        state.mutatorTreeStep(.down)
        XCTAssertEqual(state.mutatorTreePlaying, first, "dziecko 1 nie ma potomstwa")
        try state.mutatorPlay(node: XCTUnwrap(state.mutatorTree.parent(of: newest)))
        state.mutatorTreeStep(.down)
        XCTAssertEqual(state.mutatorTreePlaying, newest)
    }

    func testNodesCopyIntoBoxesAndBreed() throws {
        let state = try state()
        state.mutatorMutate()
        let child = try node(state, at: .child(2))
        let sound = state.mutatorTree.sound(of: child)

        state.mutatorCopy(node: child, to: G2MutatorBox(.storage, 5))
        XCTAssertEqual(state.mutatorStorage[5], sound)
        state.mutatorStore(node: child)
        XCTAssertEqual(state.mutatorStorage[0], sound)
        state.mutatorCopy(node: child, to: .father)
        XCTAssertEqual(state.mutatorParents[G2Mutator.fatherIndex], sound)
        XCTAssertEqual(Set(state.mutatorBoxes(of: child)),
                       [.child(2), .father, G2MutatorBox(.storage, 0), G2MutatorBox(.storage, 5)])

        state.mutatorCopy(node: child, to: G2MutatorBox(.variations, 4))
        let variation = G2Mutator.individual(from: state.patch, variation: 4, genome: state.mutatorGenome)
        XCTAssertEqual(variation.values, sound.values.mapValues { $0.rounded() })

        state.mutatorMutate(from: child)
        XCTAssertEqual(state.mutatorParents[G2Mutator.motherIndex], sound)
        XCTAssertEqual(state.mutatorTree.count, 13)
        XCTAssertEqual(state.mutatorTree.batches(of: child).count, 1)

        state.mutatorCross(node: child, with: G2MutatorBox(.storage, 5))
        XCTAssertEqual(state.mutatorTree.count, 13, "Cross dźwięku z samym sobą daje ten sam dźwięk")
    }

    /// Zwarty magazyn oddaje dźwięk bit w bit — z ułamkami, morfami i kluczem, którego
    /// wcześniejsze węzły nie miały — a dźwięk różniący się o 1 nie udaje znanego.
    func testCompactStorageRoundTripsExactly() {
        let key = G2Individual.Key(location: 1, moduleID: 3, paramIndex: 0)
        let other = G2Individual.Key(location: 1, moduleID: 3, paramIndex: 1)
        let extra = G2Individual.Key(location: 0, moduleID: 9, paramIndex: 2)
        var first = G2Individual(values: [key: 12.25, other: 100])
        first.setMorphRange(other, morph: 2, range: -7)
        var tree = G2MutatorTree()
        let root = tree.root(first)
        XCTAssertEqual(tree.sound(of: root), first)
        XCTAssertEqual(tree.node(of: first), root)

        let second = G2Individual(values: [key: 12.25, other: 100, extra: 3])
        let ids = tree.breed([second, first], parents: [root], origin: .mutate)
        XCTAssertEqual(ids[1], root, "ten sam dźwięk = ten sam węzeł")
        XCTAssertNotEqual(ids[0], root)
        XCTAssertEqual(tree.sound(of: ids[0]), second)
        XCTAssertEqual(tree.sound(of: root), first, "stary węzeł nie dostał nowego klucza")
        XCTAssertEqual(tree.count, 2)
        XCTAssertEqual(tree[root].children, [ids[0]])

        var nudged = second
        nudged[key] = 13.25
        XCTAssertNil(tree.node(of: nudged))
        var lessMorph = first
        lessMorph.setMorphRange(other, morph: 2, range: 0)
        XCTAssertNil(tree.node(of: lessMorph), "morfy też się liczą")
        XCTAssertNil(tree.node(of: G2Individual(values: [key: 12.25])), "dźwięk z mniejszą liczbą kluczy")
    }
}
