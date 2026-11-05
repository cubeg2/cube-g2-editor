@testable import G2Core
import XCTest

final class G2PatchInsertionTests: XCTestCase {
    func testInsertPushesExistingColumnDownAndKeepsNewModuleAtDropRow() {
        var first = G2Module(id: 1, typeID: 1, area: .voice)
        first.column = 0
        first.row = 0

        var second = G2Module(id: 2, typeID: 1, area: .voice)
        second.column = 0
        second.row = 2

        var inserted = G2Module(id: 3, typeID: 1, area: .voice)
        inserted.column = 0
        inserted.row = 0

        var patch = G2Patch()
        patch.voiceModules = [first, second]

        patch.insert(module: inserted)

        let rowsByID = Dictionary(uniqueKeysWithValues: patch.voiceModules.map { ($0.id, $0.row) })
        XCTAssertEqual(rowsByID[3], 0)
        XCTAssertEqual(rowsByID[1], 2)
        XCTAssertEqual(rowsByID[2], 4)
    }

    func testInsertNameBetweenOscBAndOperatorKeepsOscBAboveDropRow() {
        var oscB = G2Module(id: 1, typeID: 7, area: .voice)
        oscB.column = 0
        oscB.row = 0

        var operatorModule = G2Module(id: 2, typeID: 180, area: .voice)
        operatorModule.column = 0
        operatorModule.row = 5

        var name = G2Module(id: 3, typeID: 126, area: .voice)
        name.column = 0
        name.row = 5

        var patch = G2Patch()
        patch.voiceModules = [oscB, operatorModule]

        patch.insert(module: name)

        let rowsByID = Dictionary(uniqueKeysWithValues: patch.voiceModules.map { ($0.id, $0.row) })
        XCTAssertEqual(rowsByID[1], 0)
        XCTAssertEqual(rowsByID[3], 5)
        XCTAssertEqual(rowsByID[2], 6)
    }

    // MARK: - Upuszczenie w środek modułu (#175)

    private func module(_ id: Int, typeID: Int, row: Int, column: Int = 0) -> G2Module {
        var module = G2Module(id: id, typeID: typeID, area: .voice)
        module.column = column
        module.row = row
        return module
    }

    private static func height(_ typeID: Int) -> Int {
        ModuleDatabase.module(id: typeID)?.height ?? 2
    }

    /// Kolumna OscB → Operator → OscB stojąca ciasno; nowy moduł puszczony tak, że jego
    /// górny róg wypada w środku modułu `hit`. Zwraca wiersze po wstawieniu.
    private func dropInto(hitOffset: Int, newTypeID: Int) -> (rows: [Int: Int], column: [G2Module]) {
        let osc = 7, op = 180
        let top = module(1, typeID: osc, row: 0)
        let hit = module(2, typeID: op, row: Self.height(osc))
        let below = module(3, typeID: osc, row: Self.height(osc) + Self.height(op))
        var patch = G2Patch()
        patch.voiceModules = [top, hit, below]

        patch.insert(module: module(4, typeID: newTypeID, row: hit.row + hitOffset))

        let rows = Dictionary(uniqueKeysWithValues: patch.voiceModules.map { ($0.id, $0.row) })
        return (rows, patch.voiceModules)
    }

    /// Zgłoszenie Kuby: moduł puszczony w połowie wysokości kolumny rozsuwał ją za bardzo —
    /// trafiony moduł skakał pod nowy, a nad nowym zostawała pusta przerwa.
    func testDropOnUpperHalfOfModuleInsertsBeforeItWithoutGap() {
        let osc = Self.height(7), op = Self.height(180), name = Self.height(126)
        XCTAssertGreaterThan(op, 2, "Operator must be tall enough to have a middle")
        let result = dropInto(hitOffset: 1, newTypeID: 126)

        XCTAssertEqual(result.rows[1], 0, "module above stays")
        XCTAssertEqual(result.rows[4], osc, "new module takes the hit module's place")
        XCTAssertEqual(result.rows[2], osc + name, "hit module moves down by exactly the new height")
        XCTAssertEqual(result.rows[3], osc + op + name, "the rest moves by the same amount")
    }

    func testDropOnLowerHalfOfModuleInsertsAfterItWithoutGap() {
        let osc = Self.height(7), op = Self.height(180), name = Self.height(126)
        let result = dropInto(hitOffset: op - 1, newTypeID: 126)

        XCTAssertEqual(result.rows[1], 0)
        XCTAssertEqual(result.rows[2], osc, "hit module stays")
        XCTAssertEqual(result.rows[4], osc + op, "new module goes right under it")
        XCTAssertEqual(result.rows[3], osc + op + name, "module below moves by exactly the new height")
    }

    /// Wysoki moduł wstawiany w środek — po wstawieniu kolumna jest ciasna jak przed.
    func testTallModuleDroppedMidColumnLeavesNoGap() {
        for offset in 1 ..< Self.height(180) {
            let column = dropInto(hitOffset: offset, newTypeID: 7).column.sorted { $0.row < $1.row }
            for (upper, lower) in zip(column, column.dropFirst()) {
                XCTAssertEqual(upper.row + Self.height(upper.typeID), lower.row,
                               "offset \(offset): gap or overlap between \(upper.id) and \(lower.id)")
            }
        }
    }

    /// Building Block puszczony w środek modułu — tak samo bez przerwy.
    func testBlockDroppedOnUpperHalfOfModuleInsertsBeforeIt() {
        let osc = Self.height(7), op = Self.height(180)
        var patch = G2Patch()
        patch.voiceModules = [module(1, typeID: 7, row: 0), module(2, typeID: 180, row: osc)]
        var block = G2Patch()
        block.voiceModules = [module(1, typeID: 7, row: 3, column: 4)]

        patch.insertBlock(block, dropArea: .voice, column: 0, row: osc + 1)

        let rows = Dictionary(uniqueKeysWithValues: patch.voiceModules.map { ($0.id, $0.row) })
        XCTAssertEqual(rows[3], osc, "block snaps to the hit module's top")
        XCTAssertEqual(rows[2], osc + osc, "hit module moves by exactly the block height")
        XCTAssertGreaterThan(op, 2)
    }

    /// Wysoki moduł wstawiony na górę kolumny różnych wysokości — kolejność zostaje,
    /// wszystko zjeżdża dokładnie o jego wysokość. Dawna kaskada (`resolveCollisions`)
    /// przestawiała moduły: SeqLev spod LevScalera wskakiwał na górę (sprawdzone w aplikacji).
    func testTallModuleOnTopKeepsColumnOrder() {
        let types = [7, 126, 180, 126, 7, 126]
        var patch = G2Patch()
        var row = 0
        for (index, type) in types.enumerated() {
            patch.voiceModules.append(module(index + 1, typeID: type, row: row))
            row += Self.height(type)
        }
        let before = patch.voiceModules

        patch.insert(module: module(99, typeID: 180, row: 0))

        let shift = Self.height(180)
        XCTAssertEqual(patch.voiceModules.first { $0.id == 99 }?.row, 0)
        for old in before {
            XCTAssertEqual(patch.voiceModules.first { $0.id == old.id }?.row, old.row + shift,
                           "module \(old.id) must move by exactly the new height")
        }
    }

    // MARK: - Wklejanie ⌘V w wybrane miejsce

    /// Kuba: wklejone moduły nakładały się na oryginały. Teraz grupa ląduje rogiem w klikniętym
    /// polu, zachowuje układ, a kolumna rozsuwa się dokładnie o wysokość grupy.
    func testPastedGroupLandsAtClickAndMakesRoomWithoutGap() {
        let osc = Self.height(7), op = Self.height(180), name = Self.height(126)
        var patch = G2Patch()
        patch.voiceModules = [module(1, typeID: 7, row: 0), module(2, typeID: 180, row: osc),
                              module(3, typeID: 7, row: osc + op)]
        let copied = [module(10, typeID: 126, row: 4, column: 3), module(11, typeID: 126, row: 4 + name, column: 3)]

        // Klik w górną część Operatora — grupa staje przed nim.
        patch.insert(modules: copied, column: 0, row: osc + 1, in: .voice)

        let rows = Dictionary(uniqueKeysWithValues: patch.voiceModules.map { ($0.id, $0.row) })
        let columns = Dictionary(uniqueKeysWithValues: patch.voiceModules.map { ($0.id, $0.column) })
        XCTAssertEqual(columns[10], 0)
        XCTAssertEqual(columns[11], 0)
        XCTAssertEqual(rows[10], osc, "group corner snaps to the Operator's top")
        XCTAssertEqual(rows[11], osc + name, "group layout is kept")
        XCTAssertEqual(rows[1], 0)
        XCTAssertEqual(rows[2], osc + 2 * name, "Operator moves by exactly the group height")
        XCTAssertEqual(rows[3], osc + op + 2 * name)
    }

    /// Grupa z kilku kolumn wklejona w puste miejsce — nic się nie rusza, układ zostaje.
    func testPastedGroupInEmptySpaceMovesNothing() {
        var patch = G2Patch()
        patch.voiceModules = [module(1, typeID: 7, row: 0)]
        let copied = [module(10, typeID: 7, row: 2, column: 0), module(11, typeID: 126, row: 3, column: 1)]

        patch.insert(modules: copied, column: 5, row: 0, in: .voice)

        let placed = patch.voiceModules.map { [$0.id, $0.column, $0.row] }
        XCTAssertEqual(placed, [[1, 0, 0], [10, 5, 0], [11, 6, 1]])
    }

    // MARK: - Przesuwanie modułów po kanwie

    /// Ciasna kolumna OscB → Operator → OscB w kolumnie 0 i `Name` w kolumnie 2.
    private func columnWithLooseName() -> G2Patch {
        let osc = Self.height(7), op = Self.height(180)
        var patch = G2Patch()
        patch.voiceModules = [module(1, typeID: 7, row: 0), module(2, typeID: 180, row: osc),
                              module(3, typeID: 7, row: osc + op), module(4, typeID: 126, row: 0, column: 2)]
        return patch
    }

    private func rows(_ patch: G2Patch) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: patch.voiceModules.map { ($0.id, $0.row) })
    }

    /// Przeciągnięty moduł w dolną część Operatora — staje pod nim, bez przerwy, reszta o jego wysokość.
    func testModuleMovedIntoLowerHalfGoesUnderWithoutGap() {
        let osc = Self.height(7), op = Self.height(180), name = Self.height(126)
        var patch = columnWithLooseName()

        patch.moveModules([4], columns: -2, rows: osc + op - 1, in: .voice)

        let r = rows(patch)
        XCTAssertEqual(patch.voiceModules.first { $0.id == 4 }?.column, 0)
        XCTAssertEqual(r[1], 0)
        XCTAssertEqual(r[2], osc, "Operator stays")
        XCTAssertEqual(r[4], osc + op, "moved module goes right under it")
        XCTAssertEqual(r[3], osc + op + name, "the rest moves by exactly its height")
    }

    func testModuleMovedIntoUpperHalfGoesBeforeWithoutGap() {
        let osc = Self.height(7), name = Self.height(126)
        var patch = columnWithLooseName()

        patch.moveModules([4], columns: -2, rows: osc + 1, in: .voice)

        let r = rows(patch)
        XCTAssertEqual(r[4], osc)
        XCTAssertEqual(r[2], osc + name, "Operator moves by exactly the moved height")
    }

    /// Moduł z dołu kolumny przeciągnięty w górną część środkowego — zamieniają się miejscami,
    /// kolejność reszty zostaje.
    func testModuleMovedUpWithinColumnGoesBefore() {
        let osc = Self.height(7), op = Self.height(180)
        var patch = columnWithLooseName()

        patch.moveModules([3], columns: 0, rows: -op + 1, in: .voice)

        let r = rows(patch)
        XCTAssertEqual(r[1], 0)
        XCTAssertEqual(r[3], osc, "moved OscB takes the Operator's place")
        XCTAssertEqual(r[2], 2 * osc, "Operator goes right under it")
    }

    /// Zaznaczona grupa jedzie razem, w swoim układzie; kolejność w pliku zostaje.
    func testGroupMoveKeepsLayoutAndArrayOrder() {
        let osc = Self.height(7), op = Self.height(180)
        var patch = columnWithLooseName()
        patch.voiceModules.append(module(5, typeID: 126, row: 1, column: 3))
        let order = patch.voiceModules.map(\.id)

        patch.moveModules([4, 5], columns: -2, rows: osc + op - 1, in: .voice)

        XCTAssertEqual(patch.voiceModules.map(\.id), order)
        let placed = Dictionary(uniqueKeysWithValues: patch.voiceModules.map { ($0.id, [$0.column, $0.row]) })
        XCTAssertEqual(placed[4], [0, osc + op])
        XCTAssertEqual(placed[5], [1, osc + op + 1], "group layout is kept")
        XCTAssertEqual(placed[3], [0, osc + op + Self.height(126)])
    }
}
