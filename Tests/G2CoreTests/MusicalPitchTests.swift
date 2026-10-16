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
