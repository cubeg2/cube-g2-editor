// MidiNoteOutputTests.swift
// Nuty z wtyczki DAW jako MIDI: kanał slotu, dynamika, puszczenie.

import CoreMIDI
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

    /// Kółka klawiatury z okna wtyczki: mod wheel (CC 1) i pitch bend 14-bitowy ze środkiem 8192.
    func testControllerAndPitchBendWords() {
        XCTAssertEqual(MidiNoteOutput.controllerWord(cc: 1, value: 64, channel: 2), 0x20B1_0140)
        XCTAssertEqual(MidiNoteOutput.pitchBendWord(0, channel: 1), 0x20E0_0040)
        XCTAssertEqual(MidiNoteOutput.pitchBendWord(1, channel: 1), 0x20E0_7F7F)
        XCTAssertEqual(MidiNoteOutput.pitchBendWord(-1, channel: 1), 0x20E0_0000)
        XCTAssertEqual(MidiNoteOutput.pitchBendWord(5, channel: 16), 0x20EF_7F7F, "out of range is clamped")
    }

    /// Kabel do Norda: wybrane wejście MIDI jest na liście (bez „Virtual G2”) i dostaje akord
    /// z dynamiką na kanale slotu — sprawdzone na wirtualnym wejściu CoreMIDI.
    @MainActor
    func testChosenPortListsAndReceivesAChord() async throws {
        let name = "G2 Test Port \(UUID().uuidString.prefix(6))"
        let received = ReceivedWords()
        var client = MIDIClientRef()
        XCTAssertEqual(MIDIClientCreate("test" as CFString, nil, nil, &client), noErr)
        var destination = MIDIEndpointRef()
        let status = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &destination) { list, _ in
            for packet in list.unsafeSequence() {
                withUnsafePointer(to: packet.pointee.words) { pointer in
                    pointer.withMemoryRebound(to: UInt32.self, capacity: Int(packet.pointee.wordCount)) {
                        for index in 0 ..< Int(packet.pointee.wordCount) { received.add($0[index]) }
                    }
                }
            }
        }
        XCTAssertEqual(status, noErr)
        defer { MIDIEndpointDispose(destination)
            MIDIClientDispose(client)
        }

        let names = MidiNoteOutput.destinationNames()
        XCTAssertTrue(names.contains(name))
        XCTAssertFalse(names.contains(MidiNoteOutput.virtualG2))

        let output = MidiNoteOutput()
        let chord = [60, 64, 67].map { MidiNoteOutput.Note(key: UInt8($0), velocity: 100, on: true) }
        XCTAssertTrue(output.send(chord, channel: 3, to: name))
        XCTAssertFalse(output.send(chord, channel: 3, to: "No Such Port"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(received.all, [0x2092_3C64, 0x2092_4064, 0x2092_4364])
    }
}

private final class ReceivedWords: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [UInt32] = []
    func add(_ word: UInt32) { lock.withLock { words.append(word) } }
    var all: [UInt32] { lock.withLock { words } }
}
