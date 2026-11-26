// MidiNoteOutput.swift
// Nuty z wtyczki DAW jako zwykłe MIDI — z dynamiką i na kanale slotu.
//
// Po co: `0x56` (nuta przez USB) nie ma ani dynamiki, ani slotu — gra każdy slot z włączoną
// klawiaturą. MIDI ma jedno i drugie, a slot słucha swojego kanału z Synth Settings, więc
// każda ścieżka w DAW-ie gra tylko swój slot. Wirtualny G2 wystawia do tego własne wejście
// CoreMIDI „Virtual G2" (emulator, `g2live.cpp`); Nord dostanie te same nuty kablem przez
// port wybrany przez użytkownika (do zrobienia przy Nordzie, plan wtyczki §2.7).
//
// Klient CoreMIDI powstaje dopiero przy pierwszej nucie — edytor bez wtyczki go nie tworzy.

import CoreMIDI
import Foundation

@MainActor
final class MidiNoteOutput {
    /// Wejście MIDI, które wystawia wirtualny G2.
    static let virtualG2 = "Virtual G2"

    struct Note: Equatable {
        var key: UInt8
        /// 1…127 przy wciśnięciu; przy puszczeniu bez znaczenia.
        var velocity: UInt8
        var on: Bool
    }

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    /// Wysyła nuty na kanał `channel` (1…16) do wejścia o nazwie `destination`.
    /// Fałsz, gdy takiego wejścia nie ma — wtedy woła się drogę zapasową.
    func send(_ notes: [Note], channel: Int, to destination: String) -> Bool {
        guard let endpoint = endpoint(named: destination) else { return false }
        let words = Self.words(for: notes, channel: channel)
        // Jedna lista mieści pakiet do 64 słów; paczka z wtyczki bywa dłuższa.
        for start in stride(from: 0, to: words.count, by: 64) {
            var list = MIDIEventList()
            var packet = MIDIEventListInit(&list, ._1_0)
            for var word in words[start ..< min(start + 64, words.count)] {
                packet = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
            }
            MIDISendEventList(port, endpoint, &list)
        }
        return true
    }

    /// Komunikaty MIDI 1.0 w formie UMP (typ 2, grupa 0): `status · klawisz · dynamika`.
    /// Puszczenie to `0x80` z dynamiką 64, jak u większości klawiatur. Wciśnięcie
    /// z dynamiką 0 znaczyłoby puszczenie — stąd co najmniej 1.
    nonisolated static func words(for notes: [Note], channel: Int) -> [UInt32] {
        let channelBits = UInt32(min(max(channel, 1), 16) - 1)
        return notes.map { note in
            let status: UInt32 = (note.on ? 0x90 : 0x80) | channelBits
            let velocity = note.on ? UInt32(min(max(note.velocity, 1), 127)) : 64
            return 0x2000_0000 | status << 16 | UInt32(note.key & 0x7F) << 8 | velocity
        }
    }

    /// Wejścia MIDI do wyboru w oknie wtyczki (kabel do Norda). Bez „Virtual G2” — to wejście
    /// emulatora edytor obsługuje sam.
    nonisolated static func destinationNames() -> [String] {
        (0 ..< MIDIGetNumberOfDestinations()).compactMap { index in
            var value: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(MIDIGetDestination(index), kMIDIPropertyName, &value) == noErr,
                  let name = value?.takeRetainedValue() as String?, name != virtualG2 else { return nil }
            return name
        }
    }

    /// Control Change (`0xB0`) i Pitch Bend (`0xE0`, 14 bitów, środek 8192) jako słowa UMP.
    nonisolated static func controllerWord(cc: Int, value: Int, channel: Int) -> UInt32 {
        let status = 0xB0 | UInt32(min(max(channel, 1), 16) - 1)
        return 0x2000_0000 | status << 16 | UInt32(min(max(cc, 0), 127)) << 8 | UInt32(min(max(value, 0), 127))
    }

    nonisolated static func pitchBendWord(_ amount: Double, channel: Int) -> UInt32 {
        let status = 0xE0 | UInt32(min(max(channel, 1), 16) - 1)
        let raw = UInt32(min(max((amount.clamped(-1, 1) + 1) / 2 * 16383, 0), 16383).rounded())
        return 0x2000_0000 | status << 16 | (raw & 0x7F) << 8 | (raw >> 7)
    }

    /// Wysyła gotowe słowa UMP do wejścia `destination`; fałsz, gdy go nie ma.
    func send(words: [UInt32], to destination: String) -> Bool {
        guard let endpoint = endpoint(named: destination) else { return false }
        var list = MIDIEventList()
        var packet = MIDIEventListInit(&list, ._1_0)
        for var word in words {
            packet = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        }
        MIDISendEventList(port, endpoint, &list)
        return true
    }

    private func endpoint(named name: String) -> MIDIEndpointRef? {
        guard prepare() else { return nil }
        for index in 0 ..< MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(index)
            var value: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &value) == noErr,
                  let found = value?.takeRetainedValue() else { continue }
            if found as String == name { return endpoint }
        }
        return nil
    }

    private func prepare() -> Bool {
        if port != 0 { return true }
        guard MIDIClientCreateWithBlock("G2 Editor" as CFString, &client, nil) == noErr else { return false }
        return MIDIOutputPortCreate(client, "Notes" as CFString, &port) == noErr
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double {
        Swift.min(Swift.max(self, low), high)
    }
}
