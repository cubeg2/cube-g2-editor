@testable import G2Core
import XCTest

/// Różnica dwóch stanów slotu — to ona decyduje, jakie komendy strukturalne lecą do Norda
/// po edycji w edytorze (patrz `G2MidiManager.syncPatch`).
final class G2PatchDiffTests: XCTestCase {
    private func module(id: Int, typeID: Int = 1, area: PatchArea = .voice) -> G2Module {
        var module = G2Module(id: id, typeID: typeID, area: area)
        module.parameters = [10]
        module.parameterVariations = Array(repeating: [10], count: 9)
        return module
    }

    private func cable(from: Int, to: Int, area: PatchArea = .voice) -> G2Cable {
        G2Cable(fromModule: from, fromConnector: 0, toModule: to, toConnector: 0,
                color: .red, area: area)
    }

    /// Patch z dwoma modułami i kablem między nimi.
    private func patch() -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = [module(id: 1), module(id: 2)]
        patch.voiceCables = [cable(from: 1, to: 2)]
        return patch
    }

    func testIdenticalPatchesProduceNoCommands() {
        XCTAssertTrue(G2PatchDiff.between(patch(), patch()).isEmpty)
    }

    func testDeletedModuleTakesItsCableWithIt() {
        var edited = patch()
        edited.deleteModules(moduleIDs: [2], in: .voice)

        let diff = G2PatchDiff.between(patch(), edited)
        XCTAssertEqual(diff.modulesToDelete.map(\.id), [2])
        XCTAssertEqual(diff.cablesToDelete.count, 1)
        XCTAssertTrue(diff.modulesToAdd.isEmpty)
        XCTAssertTrue(diff.cablesToAdd.isEmpty)
    }

    /// Objaw zgłoszony 2026-09-05: „skasowałem wszystkie moduły, a Nord nadal gra".
    func testDeletingEveryModuleDeletesEveryModuleOnTheDevice() {
        let diff = G2PatchDiff.between(patch(), G2Patch())
        XCTAssertEqual(diff.modulesToDelete.map(\.id).sorted(), [1, 2])
        XCTAssertEqual(diff.cablesToDelete.count, 1)
    }

    func testAddedModuleIsSentWithoutTouchingTheRest() {
        var edited = patch()
        edited.voiceModules.append(module(id: 3))

        let diff = G2PatchDiff.between(patch(), edited)
        XCTAssertEqual(diff.modulesToAdd.map(\.id), [3])
        XCTAssertTrue(diff.modulesToDelete.isEmpty)
        XCTAssertTrue(diff.cablesToDelete.isEmpty)
        XCTAssertTrue(diff.cablesToAdd.isEmpty)
    }

    func testCableAloneIsAddedAndRemoved() {
        var edited = patch()
        edited.voiceCables = [cable(from: 2, to: 1)]

        let diff = G2PatchDiff.between(patch(), edited)
        XCTAssertTrue(diff.modulesToAdd.isEmpty)
        XCTAssertTrue(diff.modulesToDelete.isEmpty)
        XCTAssertEqual(diff.cablesToDelete.map(\.fromModule), [1])
        XCTAssertEqual(diff.cablesToAdd.map(\.fromModule), [2])
    }

    /// Podmiana modułu zostawia to samo id, ale inny typ — dla urządzenia to skasowanie
    /// i dodanie od nowa, razem z przepięciem kabli, które przy tym padły.
    func testReplacedModuleGoesDownAndUpAgainWithItsCable() {
        var edited = patch()
        edited.voiceModules[1] = module(id: 2, typeID: 7)

        let diff = G2PatchDiff.between(patch(), edited)
        XCTAssertEqual(diff.modulesToDelete.map(\.id), [2])
        XCTAssertEqual(diff.modulesToAdd.map(\.typeID), [7])
        XCTAssertEqual(diff.cablesToDelete.count, 1)
        XCTAssertEqual(diff.cablesToAdd.count, 1)
    }

    /// Nazwa i kolor mają własne komendy (0x33, 0x31) — moduł zostaje w slocie i gra
    /// dalej. `AddModule` na istniejące id przebudowałby go i urwał dźwięk.
    func testRenamedAndRecoloredModuleIsNotRebuilt() {
        var edited = patch()
        edited.voiceModules[0].label = "Osc mine"
        edited.voiceModules[1].color = 7

        let diff = G2PatchDiff.between(patch(), edited)
        XCTAssertTrue(diff.modulesToAdd.isEmpty)
        XCTAssertTrue(diff.modulesToDelete.isEmpty)
        XCTAssertEqual(diff.modulesToRename.map(\.id), [1])
        XCTAssertEqual(diff.modulesToRecolor.map(\.id), [2])
    }

    /// Przesunięcie ma własną komendę (`0x34`) — moduł zostaje w slocie i gra dalej.
    func testMovedModuleIsNotRebuilt() {
        var edited = patch()
        edited.voiceModules[0].column = 3
        edited.voiceModules[0].row = 9

        let diff = G2PatchDiff.between(patch(), edited)
        XCTAssertTrue(diff.modulesToAdd.isEmpty)
        XCTAssertTrue(diff.modulesToDelete.isEmpty)
        XCTAssertEqual(diff.modulesToMove.map(\.id), [1])
    }

    /// Przesunięcie jednego modułu spycha sąsiadów, więc urządzenie musi dostać
    /// KAŻDY moduł ze zmienioną pozycją, nie tylko ten chwycony myszą.
    func testEveryDisplacedModuleIsSentNotJustTheDraggedOne() {
        var edited = patch()
        edited.voiceModules[0].row = 4
        edited.voiceModules[1].row = 6

        XCTAssertEqual(G2PatchDiff.between(patch(), edited).modulesToMove.map(\.id).sorted(), [1, 2])
    }

    /// Moduł dopiero co dodany nie dostaje dodatkowo `ModuleName`/`ModuleColor` —
    /// molekuła `AddModule` niesie nazwę i kolor w sobie.
    func testFreshModuleDoesNotAlsoGetNameAndColorCommands() {
        var edited = patch()
        var fresh = module(id: 3)
        fresh.label = "Fresh"
        fresh.color = 5
        edited.voiceModules.append(fresh)

        let diff = G2PatchDiff.between(patch(), edited)
        XCTAssertEqual(diff.modulesToAdd.map(\.id), [3])
        XCTAssertTrue(diff.modulesToRename.isEmpty)
        XCTAssertTrue(diff.modulesToRecolor.isEmpty)
        XCTAssertTrue(diff.modulesToMove.isEmpty)
    }

    func testAreasAreDiffedSeparately() {
        var old = G2Patch()
        old.voiceModules = [module(id: 1)]
        var edited = old
        edited.fxModules = [module(id: 1, area: .fx)]

        let diff = G2PatchDiff.between(old, edited)
        XCTAssertEqual(diff.modulesToAdd.map(\.area), [.fx])
        XCTAssertTrue(diff.modulesToDelete.isEmpty)
    }
}
