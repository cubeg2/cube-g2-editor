@testable import G2Core
import XCTest

final class ModuleAutoLabelTests: XCTestCase {
    func testNumbersStartAtOneAndGrowPerType() {
        XCTAssertEqual(ModuleAutoLabel.next(shortName: "OscB", existingLabels: []), "OscB1")
        XCTAssertEqual(ModuleAutoLabel.next(shortName: "OscB", existingLabels: ["OscB1"]), "OscB2")
        XCTAssertEqual(ModuleAutoLabel.next(shortName: "LfoA", existingLabels: ["OscB1", "OscB2"]), "LfoA1")
    }

    func testNextNumberFollowsHighestUsedNotCount() {
        XCTAssertEqual(ModuleAutoLabel.next(shortName: "OscB", existingLabels: ["OscB1", "OscB7"]), "OscB8")
    }

    func testRenamedModulesDoNotFeedNumbering() {
        XCTAssertEqual(ModuleAutoLabel.next(shortName: "OscB", existingLabels: ["Bass", "OscB2"]), "OscB3")
    }

    func testUntouchedDefaultCoversBareNameAndNumberedVariants() {
        XCTAssertTrue(ModuleAutoLabel.isUntouchedDefault("Name", shortName: "Name"))
        XCTAssertTrue(ModuleAutoLabel.isUntouchedDefault("Name2", shortName: "Name"))
        XCTAssertFalse(ModuleAutoLabel.isUntouchedDefault("Filters", shortName: "Name"))
        XCTAssertFalse(ModuleAutoLabel.isUntouchedDefault("", shortName: "Name"))
    }
}
