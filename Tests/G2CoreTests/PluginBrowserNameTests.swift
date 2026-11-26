@testable import G2EditorCore
import XCTest

final class PluginBrowserNameTests: XCTestCase {
    private func name(_ file: String) -> String {
        PluginBrowser.nameFromFile(URL(fileURLWithPath: "/tmp/\(file)"))
    }

    func testDownloadedFileKeepsOnlyThePatchName() {
        XCTAssertEqual(name("3VcoPolysynth — Clavia [5dde484d].pch2"), "3VcoPolysynth")
        XCTAssertEqual(name("Warm Pad [0a1b2c3d].pch2"), "Warm Pad")
        XCTAssertEqual(name("Bass — Someone.pch2"), "Bass")
    }

    func testPlainNamesAreOnlyShortened() {
        XCTAssertEqual(name("Acid.pch2"), "Acid")
        XCTAssertEqual(name("A very long patch name indeed.pch2"), "A very long patc")
    }

    func testNameMadeOnlyOfDecorationFallsBackToTheFileName() {
        XCTAssertEqual(name(" — Clavia.pch2"), " — Clavia")
    }
}
