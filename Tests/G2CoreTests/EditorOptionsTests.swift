// EditorOptionsTests.swift
// Okno „Setup ▸ Options" (instrukcja Clavii, str. 125): styl kabli i sposób,
// w jaki mysz kręci gałkami.

import CoreGraphics
@testable import G2EditorCore
import XCTest

final class CableStyleTests: XCTestCase {
    /// Cztery pozycje z instrukcji, ani jednej więcej.
    func testFourStylesFromTheManual() {
        XCTAssertEqual(Set(CableStyle.allCases.map(\.title)),
                       ["Curved 3D", "Straight 3D", "Curved Thin", "Straight Thin"])
    }

    func testCurvedAndThinSplitTheStylesTheWayTheNamesSay() {
        XCTAssertTrue(CableStyle.curved3D.isCurved)
        XCTAssertTrue(CableStyle.curvedThin.isCurved)
        XCTAssertFalse(CableStyle.straight3D.isCurved)
        XCTAssertFalse(CableStyle.straightThin.isCurved)

        XCTAssertTrue(CableStyle.curved3D.hasShadow)
        XCTAssertTrue(CableStyle.straight3D.hasShadow)
        XCTAssertFalse(CableStyle.curvedThin.hasShadow)
        XCTAssertFalse(CableStyle.straightThin.hasShadow)
    }
}

final class KnobControlTests: XCTestCase {
    private let center = CGPoint(x: 100, y: 100)

    /// Skala zaczyna się na godzinie 7:30 (135°) i biegnie 270° w prawo.
    func testScaleStartsAtSevenThirtyAndSpansTwoSeventyDegrees() {
        // Punkt dokładnie na początku skali — w lewo i w dół od środka.
        let start = CGPoint(x: center.x - 10, y: center.y + 10)
        XCTAssertEqual(KnobControl.circularValue(at: start, center: center, maxValue: 127), 0)

        // Góra tarczy to połowa zakresu.
        let top = CGPoint(x: center.x, y: center.y - 10)
        XCTAssertEqual(KnobControl.circularValue(at: top, center: center, maxValue: 127), 64)

        // Koniec skali — w prawo i w dół.
        let end = CGPoint(x: center.x + 10, y: center.y + 10)
        XCTAssertEqual(KnobControl.circularValue(at: end, center: center, maxValue: 127), 127)
    }

    /// Wycinek pod tarczą leży poza skalą — instrukcja mówi o przeskoku z maksimum
    /// na minimum „past the 6 o'clock position", więc wartości tam nie ma.
    func testTheDeadWedgeBelowTheDialHasNoValue() {
        let below = CGPoint(x: center.x, y: center.y + 10)
        XCTAssertNil(KnobControl.circularValue(at: below, center: center, maxValue: 127))
    }

    /// Na samym środku kąt nie jest określony.
    func testCenterHasNoAngle() {
        XCTAssertNil(KnobControl.circularValue(at: center, center: center, maxValue: 127))
    }

    func testThreeModesFromTheManual() {
        XCTAssertEqual(Set(KnobControl.allCases.map(\.title)),
                       ["Vertical", "Horizontal", "Circular"])
    }
}

/// Klik w milczący slot: A gra z klawiaturą, klikamy milczący B.
final class SilentSlotClickTests: XCTestCase {
    private let playing = [true, false, false, false]
    private let keyboard = [true, false, false, false]

    func testAddToPlayingKeepsAAndGivesBTheKeyboardToo() {
        let result = SilentSlotClick.addToPlaying.selection(clicking: 1, playing: playing,
                                                            keyboard: keyboard, slotCount: 4)
        XCTAssertEqual(result?.enabled, [true, true, false, false])
        XCTAssertEqual(result?.keyboard, [true, true, false, false])
    }

    func testFocusOnlyLeavesTheSelectionAlone() {
        XCTAssertNil(SilentSlotClick.focusOnly.selection(clicking: 1, playing: playing,
                                                         keyboard: keyboard, slotCount: 4))
    }

    /// Jak oryginał: B gra sam i przejmuje klawiaturę, bo A już jej trzymać nie może.
    func testPlayAloneMutesTheRestAndMovesTheKeyboard() {
        let result = SilentSlotClick.playAlone.selection(clicking: 1, playing: playing,
                                                         keyboard: keyboard, slotCount: 4)
        XCTAssertEqual(result?.enabled, [false, true, false, false])
        XCTAssertEqual(result?.keyboard, [false, true, false, false])
    }

    /// Bez nagłówka z urządzenia (puste tablice) dokładanie daje sam kliknięty slot.
    func testAddToPlayingWithUnknownStateStartsFromTheClickedSlot() {
        let result = SilentSlotClick.addToPlaying.selection(clicking: 2, playing: [],
                                                            keyboard: [], slotCount: 4)
        XCTAssertEqual(result?.enabled, [false, false, true, false])
        XCTAssertEqual(result?.keyboard, [false, false, true, false])
    }

    func testDefaultIsAddToPlaying() {
        UserDefaults.standard.removeObject(forKey: SilentSlotClick.storageKey)
        XCTAssertEqual(SilentSlotClick.stored, .addToPlaying)
    }
}

/// Selekcja slotów po wgraniu patchy bez ustawień performance'u.
final class SlotSelectionAfterPatchUploadTests: XCTestCase {
    /// Opcja „jak oryginał” po performansie, w którym grały A–C, a klawiatura była na B:
    /// patch w A, B–D puste — świeci tylko A i on dostaje klawiaturę.
    func testEmptySlotsGoDarkAndTheTargetTakesTheKeyboard() {
        let result = DeviceConnection.slotSelectionAfterPatchUpload(
            playing: [true, true, true, false], keyboard: [false, true, false, false],
            target: 0, emptySlots: [1, 2, 3]
        )
        XCTAssertEqual(result.enabled, [true, false, false, false])
        XCTAssertEqual(result.keyboard, [true, false, false, false])
    }

    /// Slot z patchem gra dalej, jak w oryginale — gaśnie tylko pusty.
    func testSlotsWithPatchesKeepPlaying() {
        let result = DeviceConnection.slotSelectionAfterPatchUpload(
            playing: [false, true, true, false], keyboard: [false, true, false, false],
            target: 0, emptySlots: [2, 3]
        )
        XCTAssertEqual(result.enabled, [true, true, false, false])
        XCTAssertEqual(result.keyboard, [false, true, false, false])
    }

    /// Pusty patch wgrany do slotu docelowego (New Patch) i tak ma grać.
    func testTheTargetPlaysEvenWhenEmpty() {
        let result = DeviceConnection.slotSelectionAfterPatchUpload(
            playing: [], keyboard: [], target: 2, emptySlots: [2]
        )
        XCTAssertEqual(result.enabled, [false, false, true, false])
        XCTAssertEqual(result.keyboard, [false, false, true, false])
    }
}

/// Źródło dźwięku dla Spectrum i X-Y — wspólne ustawienie obu okien.
final class LiveAudioSourceTests: XCTestCase {
    private let keys = [LiveAudioSource.kindKey, LiveAudioSource.deviceKey,
                        LiveAudioSource.leftKey, LiveAudioSource.rightKey]

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func testDefaultIsTheVirtualG2() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        XCTAssertEqual(LiveAudioSource.stored, .virtualG2)
    }

    /// Bez zapisanych kanałów interfejs zaczyna od pary 1–2.
    func testInterfaceStartsFromTheFirstPair() {
        UserDefaults.standard.set(LiveAudioSource.interfaceKind, forKey: LiveAudioSource.kindKey)
        UserDefaults.standard.set("uid-1", forKey: LiveAudioSource.deviceKey)
        XCTAssertEqual(LiveAudioSource.stored, .interface(deviceUID: "uid-1", left: 0, right: 1))
    }

    /// Interfejs bez wybranego urządzenia to wciąż wirtualny G2 — nie ma czego otwierać.
    func testInterfaceWithoutADeviceFallsBackToTheVirtualG2() {
        UserDefaults.standard.set(LiveAudioSource.interfaceKind, forKey: LiveAudioSource.kindKey)
        XCTAssertEqual(LiveAudioSource.stored, .virtualG2)
    }
}

/// Tryb Norda po otwarciu dokumentu (decyzja użytkownika 2026-09-21, wybór 2026-10-15).
final class PatchOpenModeTests: XCTestCase {
    func testPerformanceAlwaysSwitchesToPerformanceMode() {
        for choice in PatchOpenMode.allCases {
            XCTAssertEqual(PatchOpenMode.targetMode(performanceDocument: true, choice: choice), true)
        }
    }

    /// Oryginał przy `.pch2` przechodzi w tryb Patch; „Keep” zostawia tryb.
    func testSinglePatchFollowsTheChoice() {
        XCTAssertEqual(PatchOpenMode.targetMode(performanceDocument: false, choice: .switchToPatch), false)
        XCTAssertNil(PatchOpenMode.targetMode(performanceDocument: false, choice: .keepMode))
        XCTAssertEqual(PatchOpenMode.targetMode(performanceDocument: false, choice: .likeOriginal), false)
    }

    func testDefaultSwitchesToPatchAndKeepsSlots() {
        UserDefaults.standard.removeObject(forKey: PatchOpenMode.storageKey)
        XCTAssertEqual(PatchOpenMode.stored, .switchToPatch)
    }

    /// Podłączenie z samym patchem w edytorze idzie za opcją otwierania (jak oryginał:
    /// tryb Patch); `.prf2` → Performance; dokument z ustawieniami performance'u bez pliku
    /// (np. wczytany wcześniej z Norda) trybu nie rusza.
    func testConnectFollowsTheChoiceOnlyForASinglePatch() {
        for choice in PatchOpenMode.allCases {
            XCTAssertEqual(PatchOpenMode.targetModeAtConnect(performanceFile: true, performanceSettings: true,
                                                             choice: choice), true)
            XCTAssertNil(PatchOpenMode.targetModeAtConnect(performanceFile: false, performanceSettings: true,
                                                           choice: choice))
            XCTAssertEqual(PatchOpenMode.targetModeAtConnect(performanceFile: false, performanceSettings: false,
                                                             choice: choice),
                           PatchOpenMode.targetMode(performanceDocument: false, choice: choice))
        }
    }
}
