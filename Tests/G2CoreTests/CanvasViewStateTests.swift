import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class CanvasViewStateTests: XCTestCase {
    func testZoomRequestsAreClampedWithoutUIAdapter() {
        let state = CanvasViewState()

        state.requestZoom(100)
        XCTAssertEqual(state.zoom, CanvasViewState.maxZoom)

        state.requestZoom(-1)
        XCTAssertEqual(state.zoom, CanvasViewState.minZoom)
    }

    func testZoomToFitUsesBothViewportDimensions() {
        let state = CanvasViewState()
        state.viewportSize = CGSize(width: 400, height: 300)

        state.zoomToFit(contentSize: CGSize(width: 800, height: 400))

        XCTAssertEqual(state.zoom, 0.5)
    }

    func testTogglingOneColorWhileAllAreHiddenShowsOnlyThatColor() {
        let state = CanvasViewState()
        state.hiddenCableColors = [.red]
        state.hideAllCables()

        state.toggleCableColor(.blue)

        XCTAssertFalse(state.allCablesHidden)
        XCTAssertTrue(state.isCableColorVisible(.blue))
        XCTAssertFalse(state.isCableColorVisible(.red))
        XCTAssertEqual(
            state.effectiveHiddenCableColors,
            Set(CableColor.allCases).subtracting([.blue])
        )

        state.showAllCables()
        XCTAssertTrue(state.effectiveHiddenCableColors.isEmpty)
    }
}
