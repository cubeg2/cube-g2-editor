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
}
