@testable import G2Core
import XCTest

final class ModuleUILayoutTests: XCTestCase {
    func testFltPhaseFrequencyFieldUsesOriginalClaviaBinding() throws {
        let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: 102))
        let frequencyField = try XCTUnwrap(ui.textFields.first(where: { $0.id == 11 }))

        XCTAssertEqual(frequencyField.masterRef, 0)
        XCTAssertEqual(frequencyField.dependencies, [1])
    }

    /// SeqLev: rząd przycisków kroku stoi na osi gniazd, przez które przechodzi
    /// pozioma magistrala rysowana pod nim.
    func testSequencerStepRowSitsOnSocketAxis() throws {
        let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: 146))
        let stepButtons = ui.buttonsText.filter(\.text.isEmpty)
        XCTAssertEqual(stepButtons.count, 16)

        let rowCenter = try XCTUnwrap(stepButtons.map(\.yPt).min()) + 6.5 / 2
        let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
        let socketCenters = (ui.inputs + ui.outputs)
            .map { $0.yPt + connHalf }
            .filter { abs($0 - rowCenter) < 4.0 }
        XCTAssertFalse(socketCenters.isEmpty)

        let axis = socketCenters.reduce(0, +) / CGFloat(socketCenters.count)
        XCTAssertEqual(rowCenter, axis, accuracy: 0.01)
    }

    /// Strzałka „Trig" przy gnieździe ma wszędzie ten sam prześwit. W źródle SeqLev
    /// i SeqEvent mają 1 piksel zamiast 2 i strzałka niemal dotyka gniazda.
    func testTrigSymbolsKeepTheSameGapFromTheirSocket() throws {
        let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
        let expected = 13.0 * (140.0 / 256.0) // gniazdo (11 px) + 2 px prześwitu

        for typeID in [121, 144, 145, 146] {
            let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: typeID))
            let sockets = ui.inputs + ui.outputs
            var checked = 0
            for symbol in ui.symbols where symbol.type.hasPrefix("Trig") {
                let center = symbol.yPt + symbol.heightPt / 2
                guard let socket = sockets
                    .filter({ $0.xPt < symbol.xPt
                            && abs($0.yPt + connHalf - center) <= symbol.heightPt
                            && symbol.xPt - $0.xPt < 4 * expected
                    })
                    .max(by: { $0.xPt < $1.xPt })
                else { continue }
                XCTAssertEqual(symbol.xPt - socket.xPt, expected, accuracy: 0.01,
                               "typeID \(typeID), symbol \(symbol.id)")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 0, "typeID \(typeID)")
        }
    }

    func testConstSwMRetainsMomentaryPushType() throws {
        let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: 188))
        let button = try XCTUnwrap(ui.buttonsText.first(where: { $0.codeRef == 1 }))

        XCTAssertEqual(button.type, "Push")
    }

    func testMomentarySwitchesRetainPushButtons() throws {
        for typeID in [36, 186, 187] {
            let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: typeID))
            let button = try XCTUnwrap(ui.buttonsText.first(where: { $0.codeRef == 0 }))
            XCTAssertEqual(button.type, "Push", "typeID \(typeID)")
        }
    }

    /// `<#ButtonRadioEdit` wpadał w gałąź `hasPrefix("ButtonRadio")` i ginął, bo nie ma
    /// pola ButtonCount. Siatki z BVE.NMG2Data.pas: Sw2-1/Sw1-2 2×1, Sw4-1/Sw1-4 4×1,
    /// Sw8-1/Sw1-8 4×2.
    func testSwitchSelectorsRetainAllRadioButtons() throws {
        let expectedGrids = [100: (2, 1), 79: (4, 1), 15: (4, 2), 90: (2, 1), 88: (4, 1), 78: (4, 2)]
        for (typeID, grid) in expectedGrids {
            let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: typeID))
            let selector = try XCTUnwrap(ui.buttonsRadio.first, "typeID \(typeID)")
            XCTAssertEqual(selector.columns, grid.0, "typeID \(typeID) — kolumny")
            XCTAssertEqual(selector.rows, grid.1, "typeID \(typeID) — rzędy")
            XCTAssertEqual(selector.buttonCount, grid.0 * grid.1, "typeID \(typeID)")
            XCTAssertEqual(selector.buttonLabels.count, grid.0 * grid.1, "typeID \(typeID) — etykiety")
        }
    }

    /// Zwykłe ButtonRadio nadal opisuje się jako jeden rząd (albo jedna kolumna przy
    /// Orientation:"Vertical") — inaczej siatka zepsułaby wszystkie selektory fal.
    func testPlainRadioButtonsStayASingleRowOrColumn() {
        for typeID in [165, 100, 79] {
            guard let ui = ModuleUIDatabase.shared.uiDef(forID: typeID) else { continue }
            for radio in ui.buttonsRadio {
                XCTAssertEqual(radio.columns * radio.rows, radio.buttonCount, "typeID \(typeID)")
                XCTAssertGreaterThan(radio.columns, 0, "typeID \(typeID)")
                XCTAssertGreaterThan(radio.rows, 0, "typeID \(typeID)")
            }
        }
    }

    /// ConstSwM/ConstSwT i chwilowe Sw2-1M/Sw1-2M — przycisk „Switch" stoi na
    /// pionowej osi panelu, w jednej linii z gałką, ekranem i rysunkiem obok.
    func testSwitchButtonSitsOnModuleAxis() throws {
        let rowHeight: CGFloat = 140.0 * 15.0 / 256.0
        for typeID in [50, 188, 186, 187] {
            let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: typeID))
            let button = try XCTUnwrap(ui.buttonsText.first(where: { $0.text == "Switch" }),
                                       "typeID \(typeID)")
            let axis = CGFloat(ui.height) * rowHeight / 2
            XCTAssertEqual(button.yPt + 6.5 / 2, axis, accuracy: 0.01, "typeID \(typeID)")
        }
    }

    /// ValSw1-2/ValSw2-1 — ekran „Ctrl Value" i para −/+ kończą się na jednej linii.
    func testValueSwitchScreenSharesBottomWithIncDec() throws {
        let incDecHeight: CGFloat = 10.0 * (140.0 / 256.0)
        for typeID in [17, 105] {
            let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: typeID))
            let button = try XCTUnwrap(ui.incDecButtons.first, "typeID \(typeID)")
            let field = try XCTUnwrap(ui.textFields.first, "typeID \(typeID)")
            XCTAssertFalse(button.isVertical, "typeID \(typeID)")
            XCTAssertEqual(field.yPt + 6.5, button.yPt + incDecHeight, accuracy: 0.01, "typeID \(typeID)")
        }
    }

    /// Mux8-1X „X-Fade": ParamDef 71 ma RangeType `Level_100`, więc surowe 127
    /// pokazuje się jako 100 — nie jako 127.
    func testXFadeReadoutUsesZeroToHundredScale() {
        XCTAssertEqual(g2InfoFunction(56, val: 127), "100")
        XCTAssertEqual(g2InfoFunction(56, val: 0), "0")
    }

    /// Siatkę pianoli rysują, przewijają i przybliżają WYŁĄCZNIE suwaki kroków
    /// sekwencera. NoteSend i NoteRcv mają zwykłe, obrotowe gałki „Note" z tym samym
    /// `InfoFunc 13` — u nich siatka wychodziła zza gałki jako pasiasty prostokąt.
    func testNoteGridBelongsOnlyToSequencerSliders() throws {
        for typeID in [143, 148] {
            let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: typeID))
            XCTAssertFalse(ui.knobs.filter { $0.infoFunc == 13 }.isEmpty, "typeID \(typeID)")
            XCTAssertTrue(ui.seqNoteKnobs.isEmpty, "typeID \(typeID) — gałka obrotowa, nie suwak")
        }
        let seqNote = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: 121))
        XCTAssertEqual(seqNote.seqNoteKnobs.count, 16)
    }

    /// NoteSend: oba groty „Trig 2" stoją PRZED swoimi gniazdami. W źródle prześwit
    /// wynosi tam 0-1 piksela i grot dotykał obrysu gniazda.
    func testTrigSymbolsBeforeSocketKeepTheSameGap() throws {
        let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: 143))
        let gap = 2.0 * (140.0 / 256.0)
        let symbols = ui.symbols.filter { $0.type.hasPrefix("Trig") }
        XCTAssertEqual(symbols.count, 2)
        for symbol in symbols {
            let socket = try XCTUnwrap((ui.inputs + ui.outputs)
                .filter { $0.xPt > symbol.xPt }
                .min(by: { $0.xPt < $1.xPt }), "symbol \(symbol.id)")
            XCTAssertEqual(socket.xPt - (symbol.xPt + symbol.widthPt), gap, accuracy: 0.01,
                           "symbol \(symbol.id)")
        }
    }

    /// Nadajniki MIDI: raster 20×12 to przewód–ramka „D"–przewód, a 5×13 w NoteSend
    /// to para strzałek ▲▼ przy gnieździe Gate.
    func testMidiSendModulesExposeBitmapPlaceholders() throws {
        for typeID in [57, 141, 142] {
            let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: typeID))
            XCTAssertTrue(ui.bitmaps.contains { $0.widthPx == 20 && $0.heightPx == 12 },
                          "typeID \(typeID) — brak komórki danych MIDI")
        }
        let noteSend = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: 143))
        XCTAssertTrue(noteSend.bitmaps.contains { $0.widthPx == 5 && $0.heightPx == 13 })
    }

    /// Rysunki przełączników odtwarzamy wektorowo w miejscu oryginalnych bitmap, więc
    /// parser musi znać ich położenie i rozmiar. Rozmiar rozstrzyga, który to rysunek.
    func testSwitchModulesExposeBitmapPlaceholders() throws {
        let singlePole = [36, 76, 85, 53, 139] // 23×16
        let changeover = [100, 187, 90, 186, 17, 105] // 24×16
        for typeID in singlePole {
            let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: typeID))
            XCTAssertTrue(ui.bitmaps.contains { $0.widthPx == 23 && $0.heightPx == 16 },
                          "typeID \(typeID) — brak rastra przełącznika pojedynczego")
        }
        for typeID in changeover {
            let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: typeID))
            XCTAssertTrue(ui.bitmaps.contains { $0.widthPx == 24 && $0.heightPx == 16 },
                          "typeID \(typeID) — brak rastra przełącznika przełącznego")
        }
        for typeID in [53, 139] {
            let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: typeID))
            XCTAssertTrue(ui.bitmaps.contains { $0.widthPx == 11 && $0.heightPx == 12 },
                          "typeID \(typeID) — brak komórki S&H")
        }
        for typeID in [36, 186, 187, 188] {
            let ui = try XCTUnwrap(ModuleUIDatabase.shared.uiDef(forID: typeID))
            XCTAssertTrue(ui.bitmaps.contains { $0.widthPx == 7 && $0.heightPx == 12 },
                          "typeID \(typeID) — brak strzałek przycisku chwilowego")
        }
    }
}
