@testable import G2Core
import XCTest

final class ModuleCatalogOrderTests: XCTestCase {
    func testCategoryOrderMatchesClaviaAndKeepsPMExtensionLast() {
        XCTAssertEqual(
            ModuleCatalogOrder.orderedCategories(from: ModuleDatabase.all),
            [
                "In/Out", "Note", "Osc", "LFO", "Rnd", "Env", "Filter",
                "FX", "Delay", "Shaper", "Level", "Mixer", "Switch", "Logic", "Seq", "MIDI", "PM",
            ]
        )
    }

    func testInOutOrderAndVisualGroupsMatchClaviaToolbar() {
        XCTAssertEqual(
            ModuleCatalogOrder.orderedModules(in: "In/Out", from: ModuleDatabase.all).map(\.id),
            [4, 3, 170, 171, 127, 1, 199, 30, 197, 156, 126]
        )
        XCTAssertEqual(
            ModuleCatalogOrder.visualGroups["In/Out"],
            [[4, 3], [170, 171], [127], [1, 199, 30], [197], [156], [126]]
        )
    }

    func testCatalogContainsEveryKnownModuleExactlyOnce() {
        let catalogIDs = ModuleCatalogOrder.visualGroups.values.flatMap { $0 }.flatMap { $0 }
        XCTAssertEqual(catalogIDs.count, Set(catalogIDs).count)
        XCTAssertEqual(Set(catalogIDs), Set(ModuleDatabase.all.map(\.id)))
    }

    func testOnlyLaterVisualGroupsRequestExtraSpacing() {
        XCTAssertFalse(ModuleCatalogOrder.startsSeparatedVisualGroup(typeID: 4, in: "In/Out"))
        XCTAssertFalse(ModuleCatalogOrder.startsSeparatedVisualGroup(typeID: 3, in: "In/Out"))
        XCTAssertTrue(ModuleCatalogOrder.startsSeparatedVisualGroup(typeID: 170, in: "In/Out"))
        XCTAssertTrue(ModuleCatalogOrder.startsSeparatedVisualGroup(typeID: 127, in: "In/Out"))
    }
}
