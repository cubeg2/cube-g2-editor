import G2Core
@testable import G2EditorCore
import XCTest

final class MusicalPitchTests: XCTestCase {
    /// Nazewnictwo jak w reszcie edytora: nuta 60 = C4, 69 = A4.
    func testNamesFollowTheEditorOctaveNumbering() {
        XCTAssertEqual(MusicalPitch.name(ofMidiNote: 60), "C4")
        XCTAssertEqual(MusicalPitch.name(ofMidiNote: 69), "A4")
        XCTAssertEqual(MusicalPitch.name(ofMidiNote: 70), "A#4")
        XCTAssertEqual(MusicalPitch.name(ofMidiNote: 24), "C1")
        XCTAssertEqual(MusicalPitch.name(ofMidiNote: 0), "C-1")
    }

    /// Strojenie oscylatora: zero to E4 (nuta 64), więc „+7” z wyświetlacza to B4 —
    /// nie G4, jak liczył wątek 2991 na forum.
    func testOscTuningNoteCountsFromE4() {
        XCTAssertEqual(MusicalPitch.oscTuningName(freqMode: 0, coarse: 64), "E4")
        XCTAssertEqual(MusicalPitch.oscTuningName(freqMode: 0, coarse: 71), "B4")
        XCTAssertEqual(MusicalPitch.oscTuningName(freqMode: 0, coarse: 52), "E3")
        // Tryb Freq pokazuje herce, ale wysokość liczy tak samo: 69 to A4 = 440 Hz.
        XCTAssertEqual(MusicalPitch.oscTuningName(freqMode: 1, coarse: 69), "A4")
    }

    /// Fac (2) i Part (3) podają stosunek częstotliwości, PShift (4) przesunięcie —
    /// w żadnym z nich nuta nie ma sensu, więc dymek jej nie dostaje.
    func testOscTuningNoteOnlyForPitchModes() {
        XCTAssertNil(MusicalPitch.oscTuningName(freqMode: 2, coarse: 64))
        XCTAssertNil(MusicalPitch.oscTuningName(freqMode: 3, coarse: 64))
        XCTAssertNil(MusicalPitch.oscTuningName(freqMode: 4, coarse: 64))
        XCTAssertNil(MusicalPitch.oscTuningName(freqMode: 0, coarse: 128))
    }

    /// Odcięcie filtra (InfoFunc 123) ma 440 Hz przy wartości 60, FltComb (173) przy 69 —
    /// dwa różne odniesienia, więc nutę liczy się z herców, nie z wartości gałki.
    func testPitchedHertzForFiltersAndComb() throws {
        XCTAssertEqual(try XCTUnwrap(g2PitchedHertz(infoFunc: 123, value: 60)), 440, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(g2PitchedHertz(infoFunc: 173, value: 69)), 440, accuracy: 0.01)
        XCTAssertEqual(try MusicalPitch.label(forHz: XCTUnwrap(g2PitchedHertz(infoFunc: 123, value: 60))), "A4 ±0 ct")
        XCTAssertEqual(try MusicalPitch.label(forHz: XCTUnwrap(g2PitchedHertz(infoFunc: 173, value: 57))), "A3 ±0 ct")
        XCTAssertNil(g2PitchedHertz(infoFunc: 88, value: 60)) // Digitizer Rate — nie wysokość
        XCTAssertNil(g2PitchedHertz(infoFunc: 0, value: 60))
    }

    /// Poniżej C-1 (8,18 Hz) nuty nie ma — wolne LFO to modulator, nie wysokość.
    func testPitchedLabelStopsBelowTheOscillatorRange() {
        XCTAssertNil(MusicalPitch.pitchedLabel(forHz: 3.44)) // LFO Rate Hi, wartość 45
        XCTAssertNil(MusicalPitch.pitchedLabel(forHz: 0))
        XCTAssertEqual(MusicalPitch.pitchedLabel(forHz: 8.1758), "C-1 ±0 ct")
        XCTAssertEqual(MusicalPitch.pitchedLabel(forHz: 13.75), "A-1 ±0 ct")
        XCTAssertEqual(MusicalPitch.pitchedLabel(forHz: 698.456), "F5 ±0 ct")
    }

    /// LFO dostaje nutę tylko w Rate Hi (mode 2) — tam sięga pasma słyszalnego.
    func testLFONoteOnlyInHighRate() throws {
        XCTAssertEqual(try XCTUnwrap(g2LFOHighRateHertz(mode: 2, value: 0)), 0.2555, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(g2LFOHighRateHertz(mode: 2, value: 127)), 391.9, accuracy: 0.5)
        XCTAssertNil(g2LFOHighRateHertz(mode: 0, value: 64)) // Rate Sub — sekundy
        XCTAssertNil(g2LFOHighRateHertz(mode: 1, value: 64)) // Rate Lo
        XCTAssertNil(g2LFOHighRateHertz(mode: 3, value: 64)) // BPM
        XCTAssertNil(g2LFOHighRateHertz(mode: 4, value: 64)) // Clk
    }

    func testNearestNoteAndCents() {
        XCTAssertEqual(MusicalPitch.nearest(toHz: 440).note, 69)
        XCTAssertEqual(MusicalPitch.nearest(toHz: 440).cents, 0)
        XCTAssertEqual(MusicalPitch.nearest(toHz: 261.63).note, 60)
        // 452 Hz leży 46,6 centa nad A4 — jeszcze bliżej A4 niż A#4.
        XCTAssertEqual(MusicalPitch.nearest(toHz: 452).note, 69)
        XCTAssertEqual(MusicalPitch.nearest(toHz: 452).cents, 47)
        XCTAssertEqual(MusicalPitch.nearest(toHz: 215).cents, -40)
    }

    func testLabel() {
        XCTAssertEqual(MusicalPitch.label(forHz: 440), "A4 ±0 ct")
        XCTAssertEqual(MusicalPitch.label(forHz: 223), "A3 +23 ct")
        XCTAssertEqual(MusicalPitch.label(forHz: 215), "A3 −40 ct")
    }

    func testHzRoundTrip() {
        XCTAssertEqual(MusicalPitch.hz(ofMidiNote: 69), 440, accuracy: 1e-9)
        XCTAssertEqual(MusicalPitch.hz(ofMidiNote: 60), 261.6256, accuracy: 1e-3)
    }
}
