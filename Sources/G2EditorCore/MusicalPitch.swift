// MusicalPitch.swift
// Herce ↔ nuty w nazewnictwie reszty edytora: nuta MIDI 60 = C4, A4 = 440 Hz
// (tak samo liczą klawiatura i wykresy modułów). Służy oknu Spectrum — podpisy osi
// w nutach i odczyt pod kursorem.

import Foundation

public enum MusicalPitch {
    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// „C4", „A#2" — oktawa liczona tak, że nuta 60 to C4.
    public static func name(ofMidiNote note: Int) -> String {
        let octave = Int((Double(note) / 12).rounded(.down)) - 1
        return names[((note % 12) + 12) % 12] + "\(octave)"
    }

    public static func hz(ofMidiNote note: Int) -> Double {
        440 * pow(2, Double(note - 69) / 12)
    }

    /// Najbliższa nuta i odstrojenie od niej w centach (−50…+50).
    public static func nearest(toHz hz: Double) -> (note: Int, cents: Int) {
        let exact = 69 + 12 * log2(hz / 440)
        let note = Int(exact.rounded())
        return (note, Int(((exact - Double(note)) * 100).rounded()))
    }

    /// Etykieta nuty dla odczytu w hercach — ale tylko w paśmie, w którym G2 stroi:
    /// od `C-1` (8,18 Hz, dolna granica oscylatora). Niżej chodzi LFO jako modulator
    /// i nazwa w rodzaju „A-3” byłaby myląca, więc nuty tam nie ma.
    public static func pitchedLabel(forHz hz: Double) -> String? {
        guard hz > 0, nearest(toHz: hz).note >= 0 else { return nil }
        return label(forHz: hz)
    }

    /// Nuta, którą gra gałka strojenia oscylatora (TextFunc 60). Zerem wysokości
    /// w G2 jest E4 = nuta 64 — tak liczy klawiatura i KBT — więc Coarse jest wprost
    /// numerem nuty MIDI, a Fine przesuwa o mniej niż pół tonu i nazwy nie zmienia.
    /// `nil` dla trybów, w których nuty nie ma: Fac i Part podają stosunek
    /// częstotliwości, PShift — przesunięcie, nie wysokość.
    public static func oscTuningName(freqMode: Int, coarse: Int) -> String? {
        guard freqMode == 0 || freqMode == 1, (0 ... 127).contains(coarse) else { return nil }
        return name(ofMidiNote: coarse)
    }

    /// „A3 +12 ct", „C4 ±0 ct" — odczyt pod kursorem w oknie Spectrum.
    public static func label(forHz hz: Double) -> String {
        let (note, cents) = nearest(toHz: hz)
        let offset = cents == 0 ? "±0" : cents > 0 ? "+\(cents)" : "−\(-cents)"
        return "\(name(ofMidiNote: note)) \(offset) ct"
    }
}
