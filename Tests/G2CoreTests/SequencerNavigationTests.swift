// SequencerNavigationTests.swift — the ‹ › arrows of the Sequence Editor's Edit tab.

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class SequencerNavigationTests: XCTestCase {
    private func target(_ id: Int) -> PanelController.SequenceEditorTarget {
        .init(slot: 0, area: .voice, moduleID: id)
    }

    func testNextAndPreviousMoveOnePlace() {
        let list = [target(1), target(2), target(3)]
        XCTAssertEqual(PanelController.neighbour(of: target(2), in: list, step: 1), target(3))
        XCTAssertEqual(PanelController.neighbour(of: target(2), in: list, step: -1), target(1))
    }

    func testWrapsAroundAtBothEnds() {
        let list = [target(1), target(2), target(3)]
        XCTAssertEqual(PanelController.neighbour(of: target(3), in: list, step: 1), target(1))
        XCTAssertEqual(PanelController.neighbour(of: target(1), in: list, step: -1), target(3))
    }

    func testUnknownCurrentStartsFromAnEnd() {
        let list = [target(1), target(2)]
        XCTAssertEqual(PanelController.neighbour(of: target(9), in: list, step: 1), target(1))
        XCTAssertEqual(PanelController.neighbour(of: nil, in: list, step: -1), target(2))
    }

    func testEmptyListGivesNothing() {
        XCTAssertNil(PanelController.neighbour(of: target(1), in: [], step: 1))
    }
}
