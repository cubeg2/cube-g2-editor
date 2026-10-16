@testable import G2EditorCore
import XCTest

/// System paneli (punkt 0.1 planu). Reguły są tu, a nie w widoku, właśnie po to,
/// żeby dało się je sprawdzić bez uruchamiania aplikacji.
@MainActor
final class PanelControllerTests: XCTestCase {
    /// Każdy test dostaje własny magazyn ustawień — inaczej sąsiadowałyby ze sobą
    /// przez `UserDefaults.standard` i kolejność testów zmieniałaby wynik.
    private func controller(_ name: String = UUID().uuidString) -> (PanelController, UserDefaults) {
        let defaults = UserDefaults(suiteName: name)!
        return (PanelController(defaults: defaults), defaults)
    }

    /// Pusty start = biblioteka modułów wysunięta, żadnych okien. Edytor bez listy
    /// modułów nie ma czym zacząć pracy.
    func testStartsWithTheModuleLibraryOut() {
        let (panels, _) = controller()
        XCTAssertEqual(panels.drawer, .modules)
        XCTAssertTrue(panels.windows.isEmpty)
    }

    /// Biblioteka czekająca przy starcie na podglądy jest schowana, ale zapis zostaje:
    /// zamknięcie aplikacji w trakcie nie może zgubić wysuniętej szuflady.
    func testHeldDrawerHidesButKeepsItsSavedState() {
        let name = UUID().uuidString
        let (panels, _) = controller(name)
        panels.holdDrawer()
        XCTAssertFalse(panels.isOpen(.modules))
        XCTAssertEqual(controller(name).0.drawer, .modules)
        panels.releaseDrawer()
        XCTAssertTrue(panels.isOpen(.modules))
    }

    /// Klik w Modules w trakcie czekania wysuwa bibliotekę od razu — nie zamyka jej.
    func testButtonOnAHeldDrawerShowsIt() {
        let (panels, _) = controller()
        panels.holdDrawer()
        panels.toggle(.modules)
        XCTAssertTrue(panels.isOpen(.modules))
        XCTAssertFalse(panels.drawerHeld)
    }

    func testAnotherDrawerDuringHoldReplacesTheHeldOne() {
        let (panels, _) = controller()
        panels.holdDrawer()
        panels.toggle(.banks)
        XCTAssertTrue(panels.isOpen(.banks))
        panels.releaseDrawer()
        XCTAssertFalse(panels.isOpen(.modules))
    }

    func testButtonTogglesTheSameDrawerOpenAndShut() {
        let (panels, _) = controller()
        panels.toggle(.banks)
        XCTAssertTrue(panels.isOpen(.banks))
        panels.toggle(.banks)
        XCTAssertNil(panels.drawer)
    }

    /// Rdzeń zasady: wysunięta jest dokładnie jedna szuflada — kto szuka patcha,
    /// nie szuka w tej chwili modułu.
    func testOpeningTheOtherDrawerReplacesTheOpenOne() {
        let (panels, _) = controller()
        panels.toggle(.banks)
        XCTAssertTrue(panels.isOpen(.banks))
        XCTAssertFalse(panels.isOpen(.modules))
        panels.toggle(.modules)
        XCTAssertTrue(panels.isOpen(.modules))
        XCTAssertFalse(panels.isOpen(.banks))
    }

    /// Okien może być otwartych ile się chce i szuflady nie ruszają — po to są oknami.
    func testWindowsOpenTogetherAndDoNotTouchTheDrawer() {
        let (panels, _) = controller()
        panels.toggle(.dsp)
        panels.toggle(.keyboard)
        XCTAssertEqual(panels.windows, [.dsp, .keyboard])
        XCTAssertEqual(panels.drawer, .modules)

        panels.closeWindow(.dsp)
        XCTAssertEqual(panels.windows, [.keyboard])
    }

    /// `Esc` chowa szufladę; okna zamyka się ich własnym przyciskiem.
    func testEscapeClosesOnlyTheDrawer() {
        let (panels, _) = controller()
        panels.toggle(.keyboard)
        panels.close()
        XCTAssertNil(panels.drawer)
        XCTAssertTrue(panels.isOpen(.keyboard))
    }

    func testWidthIsClampedAndRememberedPerPanel() throws {
        let name = UUID().uuidString
        let (panels, _) = controller(name)
        panels.setWidth(10000, for: .banks)
        XCTAssertEqual(panels.width(of: .banks), PanelController.maxPanelWidth)
        panels.setWidth(1, for: .banks)
        XCTAssertEqual(panels.width(of: .banks), PanelController.minPanelWidth)
        XCTAssertEqual(panels.width(of: .keyboard), PanelController.Panel.keyboard.defaultWidth,
                       "szerokość jednego panelu nie rusza pozostałych")

        panels.setWidth(300, for: .banks)
        let reopened = try PanelController(defaults: XCTUnwrap(UserDefaults(suiteName: name)))
        XCTAssertEqual(reopened.width(of: .banks), 300)
    }

    /// Panel „Mutation settings": domyślnie zwinięty (okno jak Standard), wysunięty
    /// poszerza tylko okno mutatora i przeżywa restart.
    func testMutatorSettingsWidenOnlyTheMutatorAndSurviveARestart() throws {
        let name = UUID().uuidString
        let (panels, _) = controller(name)
        XCTAssertFalse(panels.mutatorSettingsOpen)
        XCTAssertEqual(panels.baseWindowSize(of: .mutator), PanelController.Panel.mutator.fixedWindowSize)

        panels.mutatorSettingsOpen = true
        let standard = try XCTUnwrap(PanelController.Panel.mutator.fixedWindowSize)
        XCTAssertEqual(panels.baseWindowSize(of: .mutator),
                       CGSize(width: standard.width + PanelController.mutatorSettingsWidth,
                              height: standard.height))
        XCTAssertEqual(panels.baseWindowSize(of: .patchAdjuster),
                       PanelController.Panel.patchAdjuster.fixedWindowSize)

        let reopened = try PanelController(defaults: XCTUnwrap(UserDefaults(suiteName: name)))
        XCTAssertTrue(reopened.mutatorSettingsOpen)
    }

    /// Stan przeżywa restart: co było wysunięte i jakie okna były otwarte.
    func testDrawerAndWindowsSurviveARestart() throws {
        let name = UUID().uuidString
        let (panels, _) = controller(name)
        panels.toggle(.banks)
        panels.toggle(.dsp)

        let reopened = try PanelController(defaults: XCTUnwrap(UserDefaults(suiteName: name)))
        XCTAssertEqual(reopened.drawer, .banks)
        XCTAssertEqual(reopened.windows, [.dsp])
    }

    /// Zapis sprzed rozdzielenia paneli: „DSP wysunięty przy prawej krawędzi" nie ma
    /// już takiego miejsca, więc szuflada zostaje pusta zamiast pokazać coś nie tam.
    func testStateFromTheOldLayoutDoesNotPutAWindowPanelInTheDrawer() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set("dsp", forKey: "g2_panel_drawer")

        let panels = PanelController(defaults: defaults)
        XCTAssertNil(panels.drawer)
    }

    /// Biblioteka modułów miała własny przełącznik; kto ją schował, ma ją zastać
    /// schowaną także po zmianie układu.
    func testHiddenModuleLibraryStaysHiddenAfterTheLayoutChange() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(false, forKey: "g2_sidebar_shown")

        let panels = PanelController(defaults: defaults)
        XCTAssertNil(panels.drawer)
    }

    /// Strony parametrów, Mutator i klawiatura to siatki o znanych wymiarach — ich okna mają rozmiar
    /// zablokowany, żeby nie dało się przyciąć kratek ani klawiszy. Otwierają się
    /// dokładnie w tym rozmiarze.
    func testGridPanelsHaveALockedWindowSize() {
        for panel in [PanelController.Panel.parameterPages, .parameterOverview, .mutator, .keyboard] {
            let size = panel.fixedWindowSize
            XCTAssertNotNil(size, "\(panel.rawValue) ma mieć stały rozmiar")
            XCTAssertEqual(panel.defaultWindowHeight, size?.height)
            XCTAssertEqual(panel.defaultWidth, size?.width)
        }
        XCTAssertEqual(PanelController.Panel.parameterPages.fixedWindowSize,
                       CGSize(width: 530, height: 144))
        XCTAssertEqual(PanelController.Panel.parameterOverview.fixedWindowSize,
                       CGSize(width: 530, height: 765))
        XCTAssertNil(PanelController.Panel.dsp.fixedWindowSize, "obciążenie DSP wolno skalować")
    }

    /// Focus klawiatury zabiera głównemu oknu status kluczowego, a z nim połowę menu.
    /// Bierze go wyłącznie mutator, bo tylko on ma własne skróty.
    func testOnlyTheMutatorTakesKeyboardFocus() {
        for panel in PanelController.Panel.allCases where panel.placement == .window {
            XCTAssertEqual(panel.needsKeyboardFocus, panel == .mutator, panel.rawValue)
        }
    }
}
