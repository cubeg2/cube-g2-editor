@testable import G2EditorCore
import XCTest

/// Geometria wirtualnej klawiatury. Do 2026-09-21 rysunek liczył białe klawisze od
/// `lowestNote` jak od C — po przesunięciu widoku o półton czarne zostawały w miejscu,
/// a nuty pod nimi wędrowały. Te testy pilnują, żeby klawisz leżał tam, gdzie jego nuta.
final class KeyboardLayoutTests: XCTestCase {
    private let width: CGFloat = 350 // 5 oktaw × 7 białych = 35 klawiszy po 10 pt

    func testFiveOctavesAlwaysHaveThirtyFiveWhiteKeysWhereverTheyStart() {
        for lowest in [36, 37, 41, 42, 47] {
            let keys = KeyboardLayout.keys(lowest: lowest, octaves: 5, width: width, height: 64)
            XCTAssertEqual(keys.filter { !$0.isBlack }.count, 35, "start \(lowest)")
            XCTAssertEqual(keys.filter(\.isBlack).count, 25, "start \(lowest)")
            XCTAssertEqual(keys.map(\.note), (lowest ..< lowest + 60).map { UInt8($0) })
        }
    }

    func testBlackKeySitsOnTheBoundaryBetweenItsWhiteNeighbours() {
        // Widok od C# (37): C# wystaje w lewo poza krawędź, D zaczyna rysunek,
        // D# siedzi na granicy D–E, czyli na x = 10.
        let keys = KeyboardLayout.keys(lowest: 37, octaves: 5, width: width, height: 64)
        let cSharp = keys[0], d = keys[1], dSharp = keys[2], e = keys[3]
        XCTAssertTrue(cSharp.isBlack)
        XCTAssertEqual(cSharp.rect.midX, 0, accuracy: 0.01)
        XCTAssertFalse(d.isBlack)
        XCTAssertEqual(d.rect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(dSharp.rect.midX, 10, accuracy: 0.01)
        XCTAssertEqual(e.rect.minX, 10, accuracy: 0.01)
        // E–F nie ma czarnego: F zaczyna się zaraz za E.
        XCTAssertEqual(keys[4].note, 41)
        XCTAssertFalse(keys[4].isBlack)
        XCTAssertEqual(keys[4].rect.minX, 20, accuracy: 0.01)
    }

    func testBlackKeysAreShorterAndSitOnTop() throws {
        let keys = KeyboardLayout.keys(lowest: 36, octaves: 5, width: width, height: 64)
        let black = try XCTUnwrap(keys.first { $0.isBlack })
        let white = try XCTUnwrap(keys.first { !$0.isBlack })
        XCTAssertEqual(black.rect.height, 64 * 0.6, accuracy: 0.01)
        XCTAssertEqual(white.rect.height, 64)
        XCTAssertLessThan(black.rect.width, white.rect.width)
    }

    func testHitTestPrefersTheBlackKeyAndFillsTheGapBetweenWhites() {
        let keys = KeyboardLayout.keys(lowest: 36, octaves: 5, width: width, height: 64)
        // Granica C–D u góry to C#, u dołu (pod czarnym) to już biały klawisz.
        XCTAssertEqual(KeyboardLayout.note(at: CGPoint(x: 10, y: 5), in: keys), 37)
        XCTAssertEqual(KeyboardLayout.note(at: CGPoint(x: 8, y: 60), in: keys), 36)
        XCTAssertEqual(KeyboardLayout.note(at: CGPoint(x: 12, y: 60), in: keys), 38)
        // Szczelina 1 pt między białymi należy do klawisza z lewej.
        XCTAssertEqual(KeyboardLayout.note(at: CGPoint(x: 9.5, y: 60), in: keys), 36)
        XCTAssertNil(KeyboardLayout.note(at: CGPoint(x: -5, y: 60), in: keys))
    }

    func testShiftByWhiteKeysSkipsBlackOnes() {
        XCTAssertEqual(KeyboardLayout.shifted(36, byWhiteKeys: 7), 48) // oktawa
        XCTAssertEqual(KeyboardLayout.shifted(48, byWhiteKeys: -1), 47) // C → B
        XCTAssertEqual(KeyboardLayout.shifted(37, byWhiteKeys: 1), 38) // C# → D
        XCTAssertEqual(KeyboardLayout.shifted(40, byWhiteKeys: 1), 41) // E → F, bez czarnego
        XCTAssertEqual(KeyboardLayout.shifted(60, byWhiteKeys: 0), 60)
    }

    func testTypingKeysCoverAnOctaveAndAFourthWithoutGapsOrDuplicates() {
        let offsets = KeyboardLayout.typingKeys.map(\.offset).sorted()
        XCTAssertEqual(offsets, Array(0 ..< KeyboardLayout.typingSpan))
        XCTAssertEqual(KeyboardLayout.typingSpan, 18)
        XCTAssertEqual(Set(KeyboardLayout.typingKeys.map(\.keyCode)).count, KeyboardLayout.typingKeys.count)
        // Biały rząd: A–' to białe klawisze od C; czarny rząd W–P.
        XCTAssertEqual(KeyboardLayout.typingLabel(offset: 0), "A")
        XCTAssertEqual(KeyboardLayout.typingLabel(offset: 1), "W")
        XCTAssertEqual(KeyboardLayout.typingLabel(offset: 12), "K")
        XCTAssertEqual(KeyboardLayout.typingLabel(offset: 17), "'")
        XCTAssertNil(KeyboardLayout.typingLabel(offset: 18))
        for key in KeyboardLayout.typingKeys {
            XCTAssertEqual(KeyboardLayout.isBlack(key.offset), ["W", "E", "T", "Y", "U", "O", "P"].contains(key.label),
                           "\(key.label) na złym rzędzie")
        }
        XCTAssertFalse(KeyboardLayout.typingKeys.contains { $0.keyCode == KeyboardLayout.typingOctaveDownKeyCode })
        XCTAssertFalse(KeyboardLayout.typingKeys.contains { $0.keyCode == KeyboardLayout.typingOctaveUpKeyCode })
    }

    func testChordNotesStartOnTheClickedKey() {
        XCTAssertEqual(KeyboardChord.single.notes(root: 60), [60])
        XCTAssertEqual(KeyboardChord.major.notes(root: 60), [60, 64, 67])
        XCTAssertEqual(KeyboardChord.minor.notes(root: 57), [57, 60, 64])
        XCTAssertEqual(KeyboardChord.seventh.notes(root: 55), [55, 59, 62, 65])
        for chord in KeyboardChord.allCases {
            XCTAssertEqual(chord.intervals.first, 0, "\(chord.title) bez prymy")
        }
    }

    /// Góra zakresu MIDI: nuty ponad 127 nie istnieją, reszta akordu gra.
    func testChordDropsNotesAboveMidiRange() {
        XCTAssertEqual(KeyboardChord.major.notes(root: 125), [125])
        XCTAssertEqual(KeyboardChord.octave.notes(root: 120), [120])
    }
}
