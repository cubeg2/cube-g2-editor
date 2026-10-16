// TextDisplayTests.swift
// Wartości graniczne TextFunc 141 dla modułów Delay Static/Single/Dual.

@testable import G2Core
import XCTest

final class TextDisplayTests: XCTestCase {
    func testDelayStaticTextFunctionUsesRangeAndPreservesBoundaries() {
        func display(value: Int, range: Int) -> String {
            g2TextFunction(
                textFunc: 141,
                deps: [0, -1],
                params: [value],
                modes: [range],
                knobInfoFunc: 0
            )
        }

        XCTAssertEqual(display(value: 0, range: 0), "0.01m")
        XCTAssertEqual(display(value: 1, range: 0), "0.05m")
        XCTAssertEqual(display(value: 127, range: 4), "1.000s")
        XCTAssertEqual(display(value: 63, range: 5), "992m")
        XCTAssertEqual(display(value: 64, range: 5), "1.008s")
        XCTAssertEqual(display(value: 47, range: 6), "999.2m")
        XCTAssertEqual(display(value: 48, range: 6), "1.02s")
        XCTAssertEqual(display(value: 127, range: 6), "2.7s")
    }

    func testDelayTextFunctionsCoverQuadEightStereoAndClockSync() {
        func display(_ textFunc: Int, _ deps: [Int], _ params: [Int], _ modes: [Int] = []) -> String {
            g2TextFunction(textFunc: textFunc, deps: deps, params: params, modes: modes, knobInfoFunc: 0)
        }

        XCTAssertEqual(display(140, [0, 8, -1], [127, 0, 0, 0, 0, 0, 0, 0, 0], [4]), "1.000s")
        XCTAssertEqual(display(140, [0, 8, -1], [0, 0, 0, 0, 0, 0, 0, 0, 1], [0]), "1/64T")
        XCTAssertEqual(display(145, [0, -1], [127], [6]), "338m")
        XCTAssertEqual(display(146, [0, 8, -1], [95, 0, 0, 0, 0, 0, 0, 0, 0], [2]), "1.011s")
        XCTAssertEqual(display(146, [0, 8, -1], [124, 0, 0, 0, 0, 0, 0, 0, 1], [0]), "2/1")
        XCTAssertEqual(display(143, [0, 5, -1], [127, 0, 0, 0, 0, 0], [0]), "500m")
        XCTAssertEqual(display(143, [0, 5, -1], [127, 0, 0, 0, 0, 0], [1]), "1.00s")
    }

    func testDelayRangeSelectorsUseClaviaMNotation() {
        XCTAssertEqual(g2ModeLabel(modeName: "DelayRange", value: 0), "500m")
        XCTAssertEqual(g2ModeLabel(modeName: "DelayRange3", value: 0), "5m")
        XCTAssertEqual(g2ModeLabel(modeName: "DelayRange3", value: 3), "500m")
        XCTAssertEqual(g2ModeLabel(modeName: "DelayRange1", value: 0), "500m")
    }

    func testRemainingRawTextFunctionsUseTheirReferenceFormatting() {
        func display(_ textFunc: Int, _ deps: [Int], _ params: [Int], _ modes: [Int] = []) -> String {
            g2TextFunction(textFunc: textFunc, deps: deps, params: params, modes: modes, knobInfoFunc: 0)
        }

        XCTAssertEqual(display(108, [0], [16]), "This")
        XCTAssertEqual(display(110, [0, 1, 2], [52, 1, 0]), "108 BPM")
        XCTAssertEqual(display(110, [0, 1, 2], [52, 0, 0]), "--")
        XCTAssertEqual(display(110, [0, 1, 2], [52, 1, 1]), "MASTER")
        XCTAssertEqual(display(122, [0, 1], [0, 0]), "0.10m")
        XCTAssertEqual(display(122, [0, 1], [127, 2]), "100s")
        XCTAssertEqual(display(142, [0, 1], [0, 0]), "0.000Hz")
        XCTAssertEqual(display(142, [0, 1], [127, 0]), "8.78Hz")
        XCTAssertEqual(display(142, [0, 1], [127, 1]), "97.6Hz")
        XCTAssertEqual(display(142, [0, 1], [127, 2]), "1568Hz")
        // Rozstrzygnięte zrzutami prawdziwego edytora Clavii (2026-08-13): BrPoint=0 -> "A-1",
        // BrPoint=99 -> "C8", BrPoint=50 (wartość domyślna) -> "B3", środek KBLevScale.
        XCTAssertEqual(display(197, [0], [0]), "A-1")
        XCTAssertEqual(display(197, [0], [99]), "C8")
        XCTAssertEqual(display(197, [0], [50]), "B3")
        XCTAssertEqual(display(198, [0, 1, 2], [0, 0, 0]), "x0.50")
        XCTAssertEqual(display(198, [0, 1, 2], [3, 0, 1]), "1.000kHz")
        // PShift: Semi i centy Fine jak PitchShift ("%+2.1f %+4.0f").
        XCTAssertEqual(display(201, [0, 1], [64, 64]), "+0.0   +0")
        XCTAssertEqual(display(201, [0, 1], [69, 64]), "+1.2   +0")
        XCTAssertEqual(display(201, [0, 1], [38, 49]), "-6.5  -12")
        XCTAssertEqual(display(201, [0, 1], [0, 0]), "-16.0  -50")
        XCTAssertEqual(display(201, [0, 1], [127, 127]), "+15.8  +49")
    }

    func testFxDisplaysUseClaviaSpecificFormats() {
        XCTAssertEqual(g2ScratchPitchRatio(0), "-x4.00")
        XCTAssertEqual(g2ScratchPitchRatio(80), "x1.00")
        XCTAssertEqual(g2ScratchPitchRatio(127), "x4.00")
        XCTAssertEqual(g2ReverbBrightness(64), "50")
        XCTAssertEqual(g2InfoFunction(174, val: 1), "0.53m")
        XCTAssertEqual(g2InfoFunction(175, val: 20), "250m")
    }

    func testDefaultLevelDisplayMatchesClaviaWithoutPercentSuffix() {
        XCTAssertEqual(g2InfoFunction(0, val: 0), "0")
        XCTAssertEqual(g2InfoFunction(0, val: 1), "0.8")
        XCTAssertEqual(g2InfoFunction(0, val: 32), "25")
        XCTAssertEqual(g2InfoFunction(0, val: 64), "50")
        XCTAssertEqual(g2InfoFunction(0, val: 96), "75")
        XCTAssertEqual(g2InfoFunction(0, val: 127), "100")
    }

    func testFltClassicResonanceDisplayUsesOnlyIntegers() {
        XCTAssertEqual(g2FltClassicResonanceText(0), "0")
        XCTAssertEqual(g2FltClassicResonanceText(1), "0")
        XCTAssertEqual(g2FltClassicResonanceText(2), "1")
        XCTAssertEqual(g2FltClassicResonanceText(64), "50")
        XCTAssertEqual(g2FltClassicResonanceText(126), "98")
        XCTAssertEqual(g2FltClassicResonanceText(127), "100")
    }

    func testEnvelopeDisplaysPreserveClaviaTrailingZeros() {
        XCTAssertEqual(g2InfoFunction(28, val: 0), "0.5m")
        XCTAssertEqual(g2InfoFunction(28, val: 79), "3.0s")
        XCTAssertEqual(g2InfoFunction(28, val: 127), "45.0s")

        XCTAssertEqual(
            g2TextFunction(textFunc: 137, deps: [0, 1], params: [0, 0], knobInfoFunc: 0),
            "0.0"
        )
        XCTAssertEqual(
            g2TextFunction(textFunc: 137, deps: [0, 1], params: [127, 0], knobInfoFunc: 0),
            "63.5"
        )
    }

    func testLevelModuleDefaultsMatchClaviaDisplays() {
        XCTAssertEqual(g2InfoFunction(17, val: 64), "0")
        XCTAssertEqual(g2InfoFunction(17, val: 127), "64")

        XCTAssertEqual(
            g2TextFunction(textFunc: 96, deps: [0, 1], params: [64, 0], knobInfoFunc: 16),
            "0"
        )
        XCTAssertEqual(
            g2TextFunction(textFunc: 96, deps: [0, 1], params: [64, 1], knobInfoFunc: 16),
            "32.0"
        )
        XCTAssertEqual(
            g2TextFunction(textFunc: 147, deps: [0, 1], params: [64, 0], knobInfoFunc: 0),
            "x1.00"
        )

        XCTAssertEqual(g2InfoFunction(129, val: 0), "Fast")
        XCTAssertEqual(g2InfoFunction(130, val: 20), "24.6m")
        XCTAssertEqual(g2InfoFunction(159, val: 0), "0.2m")
        XCTAssertEqual(g2InfoFunction(160, val: 64), "86.4m")
        XCTAssertEqual(g2InfoFunction(220, val: 20), "-16.1dB")
    }

    /// Grupa Mixer — odczyty zgodne z oryginalnym edytorem Clavii.
    /// dBLin (TextFunc 102): trzecia pozycja przełącznika
    /// „Exp,Lin,dB" przestawia ekran z procentów na decybele.
    func testMixerLevelSwitchesToDecibelsInDbMode() {
        // deps = [poziom, ExpLin]; params = [wartość poziomu, tryb]
        XCTAssertEqual(
            g2TextFunction(textFunc: 102, deps: [0, 1], params: [100, 0], knobInfoFunc: 0),
            "78.1" // Exp → procent
        )
        XCTAssertEqual(
            g2TextFunction(textFunc: 102, deps: [0, 1], params: [100, 1], knobInfoFunc: 0),
            "78.1" // Lin → ten sam procent
        )
        // Wartość zmierzona na zrzucie z oryginalnego edytora: domyślny poziom 100
        // przełączony na „dB" pokazuje -6.2, co odpowiada 20·log10(x³).
        XCTAssertEqual(
            g2TextFunction(textFunc: 102, deps: [0, 1], params: [100, 2], knobInfoFunc: 0),
            "-6.2"
        )
        // Wartości brzegowe wpisane w oryginale na sztywno.
        XCTAssertEqual(g2MixerDecibels(0), "-oo")
        XCTAssertEqual(g2MixerDecibels(1), "-99.9")
        XCTAssertEqual(g2MixerDecibels(2), "-99.0")
        XCTAssertEqual(g2MixerDecibels(127), "-0")
    }

    /// Oba przełączniki miksera mają po TRZY pozycje — ExpLin
    /// (Table "Exp","Lin","dB") i Pad (0dB / -6dB / -12dB).
    func testMixerSwitchesHaveThreePositions() {
        XCTAssertEqual(g2InfoFunction(169, val: 0), "Exp")
        XCTAssertEqual(g2InfoFunction(169, val: 1), "Lin")
        XCTAssertEqual(g2InfoFunction(169, val: 2), "dB")

        XCTAssertEqual(g2InfoFunction(188, val: 0), "0dB")
        XCTAssertEqual(g2InfoFunction(188, val: 1), "-6dB")
        XCTAssertEqual(g2InfoFunction(188, val: 2), "-12dB")
        // Mix8-1A używa własnej funkcji o tej samej treści.
        XCTAssertEqual(g2InfoFunction(57, val: 2), "-12dB")
    }

    /// Audyt grupy Seq (2026-08-27) — trzy rozbieżności wobec oryginalnego edytora Clavii.
    func testSequencerDisplaysMatchClaviaParamText() {
        // GetKeyName (g2_types.pas) i Semitone: oktawa = v div 12 - 1.
        XCTAssertEqual(g2InfoFunction(13, val: 0), "C-1")
        XCTAssertEqual(g2InfoFunction(13, val: 60), "C4")
        XCTAssertEqual(g2InfoFunction(13, val: 127), "G9")

        // XFade — pierwsza pozycja to "Off", nie "0%"
        // (potwierdza też ParamDef id 158: ButtonText "Off;25%;50%;100%").
        XCTAssertEqual(g2InfoFunction(134, val: 0), "Off")
        XCTAssertEqual(g2InfoFunction(134, val: 3), "100%")

        // InfoFunc 500 istnieje wyłącznie w SeqCtr.txt BVerhue; oryginalny panel Clavii ma tam 0.
        for value in [0, 1, 64, 96, 127] {
            XCTAssertEqual(g2InfoFunction(500, val: value), g2InfoFunction(0, val: value))
        }
    }
}
