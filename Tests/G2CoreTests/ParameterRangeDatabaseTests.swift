@testable import G2Core
import XCTest

final class ParameterRangeDatabaseTests: XCTestCase {
    func testOutputPadUsesOnlyHardwareSupportedStates() {
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 3, codeRef: 2), 0 ... 1)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 4, codeRef: 2), 0 ... 1)

        // Pozostałe odmiany Pad mają liczbę napisów zgodną ze sprzętowym zakresem,
        // więc nie potrzebują wyjątków w bazie zakresów.
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 40, codeRef: 9))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 116, codeRef: 0))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 123, codeRef: 8))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 127, codeRef: 2))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 161, codeRef: 17))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 170, codeRef: 2))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 171, codeRef: 2))
    }

    func testDXRouterAlgorithmRange() {
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 165, codeRef: 0), 0 ... 31)
    }

    func testDXRouterFeedbackRange() {
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 165, codeRef: 1), 0 ... 7)
    }

    func testValueSwitchStopsAtDisplayedValue64() {
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 17, codeRef: 0), 0 ... 63)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 105, codeRef: 0), 0 ... 63)
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 17, codeRef: 1))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 105, codeRef: 1))
    }

    /// Kanał MIDI ma trzy sprzętowe typy (`ParamDef` 92/93/94): 0…16 „This",
    /// 0…17 dodatkowo „Keyb", 0…20 dodatkowo Sloty A-D. Bez wpisów +/- chodziło
    /// po całym 0…127, czyli po numerach kanałów, których sprzęt nie zna.
    func testMidiChannelRangesMatchHardware() {
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 142, codeRef: 1), 0 ... 16)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 147, codeRef: 1), 0 ... 16)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 148, codeRef: 1), 0 ... 17)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 149, codeRef: 0), 0 ... 17)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 149, codeRef: 4), 0 ... 20)
        for typeID in [57, 141, 143] {
            XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: typeID, codeRef: 2), 0 ... 20,
                           "typeID \(typeID)")
        }
        // Dane MIDI (Ctrl/Val/Note/Vel) zostają pełne 0…127 — bez wpisu w bazie.
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 141, codeRef: 0))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 143, codeRef: 1))
    }

    /// Oba ekrany kanału numerują od zera = kanał 1. `PatchMIDIInChannel` ma
    /// w oryginale 18 pozycji (`Table(…, 0x12, …)`), `PatchMIDIOutChannel` 21.
    func testMidiChannelReadouts() {
        XCTAssertEqual(g2InfoFunction(109, val: 0), "1")
        XCTAssertEqual(g2InfoFunction(109, val: 15), "16")
        XCTAssertEqual(g2InfoFunction(109, val: 16), "This")
        XCTAssertEqual(g2InfoFunction(109, val: 17), "Keyb")

        XCTAssertEqual(g2InfoFunction(108, val: 0), "1")
        XCTAssertEqual(g2InfoFunction(108, val: 16), "This")
        XCTAssertEqual(g2InfoFunction(108, val: 17), "Slot A")
        XCTAssertEqual(g2InfoFunction(108, val: 20), "Slot D")
    }

    func testClkDivDividerRange() {
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 69, codeRef: 0), 0 ... 127)
    }

    func testOperatorRanges() {
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 5), 0 ... 14)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 6), 0 ... 7)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 7), 0 ... 7)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 16), 0 ... 7)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 8), 0 ... 99)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 17), 0 ... 99)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 19), 0 ... 99)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 21), 0 ... 99)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 22), 0 ... 99)
    }

    func testOperatorFrequencyRanges() {
        // Coarse to mnożnik 0...31, Fine liczba 0...99 — bez wpisów gałki chodziły
        // po pełnym 0...127 i ich wskazówki stały w złych miejscach.
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 3), 0 ... 31)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 4), 0 ... 99)
    }

    func testLfoRangeButtonsStopBeforeClk() {
        // LfoA i LfoC mają na przycisku pięć napisów, ale znają tylko cztery zakresy —
        // Clk ma dopiero LfoB i LfoShpA (te zostają bez wpisu, pełne pięć stanów).
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 24, codeRef: 3), 0 ... 3)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 26, codeRef: 7), 0 ... 3)
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 190, codeRef: 2))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 25, codeRef: 1))
    }

    func testEnvelopeOutputTypeRangesMatchHardwareVariants() {
        // Większość krótszych kopert ma tylko P+/P−/N+/N−. EnvMulti dopuszcza
        // dodatkowo Bip, natomiast pełne ADSR/ModADSR/ADDSR korzystają z sześciu
        // stanów ogólnych i dlatego nie potrzebują wpisów wyjątków.
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 41, codeRef: 1), 0 ... 3)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 46, codeRef: 5), 0 ... 3)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 52, codeRef: 10), 0 ... 4)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 55, codeRef: 1), 0 ... 3)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 84, codeRef: 5), 0 ... 3)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 169, codeRef: 6), 0 ... 3)
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 20, codeRef: 5))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 23, codeRef: 8))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 119, codeRef: 9))
    }

    func testRandomRangeButtonsStopBeforeClk() {
        // RandomA/RandomB: ten sam błąd co LfoA/LfoC — panel ma pięć napisów
        // (Sub/Lo/Hi/BPM/Clk), sprzęt zna tylko cztery.
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 200, codeRef: 3), 0 ... 3)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 202, codeRef: 7), 0 ... 3)
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 200, codeRef: 0))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 202, codeRef: 0))
    }

    func testClkGenBeatSyncRange() {
        // „Sync every N beats": 1, 2, 4, 8, 16, 32.
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 68, codeRef: 3), 0 ... 5)
    }

    func testFilterNavigatorRanges() {
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 102, codeRef: 4), 0 ... 5)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 45, codeRef: 0), 0 ... 8)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 45, codeRef: 1), 0 ... 8)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 45, codeRef: 2), 0 ... 8)
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 45, codeRef: 3))
    }

    func testDigitizerBitsStopAtHardwareOffState() {
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 118, codeRef: 0), 0 ... 12)
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 118, codeRef: 1))
    }

    func testCompressorKnobsStopAtHardwareRanges() {
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 150, codeRef: 0), 0 ... 42)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 150, codeRef: 1), 0 ... 66)
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 150, codeRef: 4), 0 ... 42)
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 150, codeRef: 2))
    }

    func testVocoderBandsSelectOnlyOffOrOneOfSixteenAnalysisBands() {
        for codeRef in 0 ... 15 {
            XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 108, codeRef: codeRef), 0 ... 16)
        }
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 108, codeRef: 16))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 108, codeRef: 17))
    }

    func testRndPatternLoopCountFullRange() {
        // „Loop": InfoFunc:2 dawało 16 kroków, a g2ools (Range_128) i prawdziwe patche
        // pokazują pełne 1...128 — ten sam przypadek co ClkDiv „Divider".
        XCTAssertEqual(ParameterRangeDatabase.range(moduleTypeID: 208, codeRef: 3), 0 ... 127)
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 208, codeRef: 5))
    }

    func testUnknownParameterHasNoOverride() {
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 165, codeRef: 2))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 1, codeRef: 0))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 69, codeRef: 1))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 180, codeRef: 23))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 24, codeRef: 0))
        XCTAssertNil(ParameterRangeDatabase.range(moduleTypeID: 68, codeRef: 0))
    }
}
