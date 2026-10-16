// MidiNoteOutputTests.swift
// Nuty z wtyczki DAW jako MIDI: kanał slotu, dynamika, puszczenie.

@testable import G2EditorCore
import XCTest

final class MidiNoteOutputTests: XCTestCase {
    func testNoteOnCarriesSlotChannelAndVelocity() {
        let words = MidiNoteOutput.words(for: [.init(key: 60, velocity: 90, on: true)], channel: 2)
        XCTAssertEqual(words, [0x2091_3C5A]) // kanał 2 = 0x91
    }

    func testNoteOffUsesStatus80() {
        let words = MidiNoteOutput.words(for: [.init(key: 60, velocity: 0, on: false)], channel: 16)
        XCTAssertEqual(words, [0x208F_3C40])
    }

    /// Wciśnięcie z dynamiką 0 to w MIDI puszczenie — cichutka nuta z DAW-a nie może zniknąć.
    func testZeroVelocityNoteOnStaysANote() {
        let words = MidiNoteOutput.words(for: [.init(key: 64, velocity: 0, on: true)], channel: 1)
        XCTAssertEqual(words, [0x2090_4001])
    }
}
