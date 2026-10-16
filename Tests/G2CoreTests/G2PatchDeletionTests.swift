@testable import G2Core
import XCTest

final class G2PatchDeletionTests: XCTestCase {
    func testDeletingMultipleModulesRemovesSelectionAndConnectedCablesOnlyInArea() {
        var patch = G2Patch()
        patch.voiceModules = (1 ... 4).map { G2Module(id: $0, typeID: 1, area: .voice) }
        patch.voiceCables = [
            G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 0,
                    color: .red, area: .voice),
            G2Cable(fromModule: 2, fromConnector: 0, toModule: 3, toConnector: 0,
                    color: .blue, area: .voice),
            G2Cable(fromModule: 3, fromConnector: 0, toModule: 4, toConnector: 0,
                    color: .yellow, area: .voice),
        ]
        patch.fxModules = [G2Module(id: 2, typeID: 1, area: .fx)]
        patch.fxCables = [
            G2Cable(fromModule: 2, fromConnector: 0, toModule: 2, toConnector: 1,
                    color: .red, area: .fx),
        ]

        patch.deleteModules(moduleIDs: [1, 2], in: .voice)

        XCTAssertEqual(patch.voiceModules.map(\.id), [3, 4])
        XCTAssertEqual(patch.voiceCables.count, 1)
        XCTAssertEqual(patch.voiceCables.first?.fromModule, 3)
        XCTAssertEqual(patch.voiceCables.first?.toModule, 4)
        XCTAssertEqual(patch.fxModules.map(\.id), [2])
        XCTAssertEqual(patch.fxCables.count, 1)
    }
}
