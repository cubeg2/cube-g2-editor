// SequencePresets.swift
// Ready-made patterns for the Sequence Editor's Presets menu: curves for SeqVal / SeqLev / SeqCtr,
// note figures for SeqNote, drum rhythms for SeqEvent. Pure data — the window writes them as one
// undo step and keeps locked steps.
// → [[Docs/roadmap]] "Sequence Editor — presety"

import Foundation

public enum SequencePresets {
    public struct Preset: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        /// Curve: the 16 values (0…127). Note figure: semitones above the root note, repeated over
        /// the steps. Rhythm: Row 1 on/off flags.
        public let steps: [Int]
        /// Rhythms only: Row 2 on/off flags.
        public let second: [Int]
        /// Note figures only: the style submenu a figure sits in (`nil` = the main list).
        public let group: String?

        init(_ name: String, _ steps: [Int], second: [Int] = [], group: String? = nil) {
            self.name = name
            self.steps = steps
            self.second = second
            self.group = group
        }
    }

    private static let count = SequencerLayout.steps

    private static func flags(_ on: [Int]) -> [Int] {
        (0 ..< count).map { on.contains($0) ? 1 : 0 }
    }

    private static func curve(_ name: String, _ function: (Int) -> Double) -> Preset {
        Preset(name, (0 ..< count).map { max(0, min(127, Int((function($0) * 127).rounded()))) })
    }

    /// SeqVal / SeqLev / SeqCtr: shapes over the 16 steps (the whole 0…127 range).
    public static let curves: [Preset] = [
        curve("Ramp up") { Double($0) / 15 },
        curve("Ramp down") { 1 - Double($0) / 15 },
        curve("Triangle") { $0 < 8 ? Double($0) / 7 : Double(15 - $0) / 7 },
        curve("Saw ×2") { Double($0 % 8) / 7 },
        curve("Square") { $0 < 8 ? 1 : 0 },
        curve("Staircase") { Double($0 / 4) / 3 },
        curve("Sine") { 0.5 + 0.5 * sin(Double($0) / 16 * 2 * .pi) },
        curve("Alternate") { $0 % 2 == 0 ? 1 : 0 },
    ]

    /// SeqNote: figures in semitones above the root note, repeated over the 16 steps.
    public static let figures: [Preset] = [
        Preset("Major arpeggio", [0, 4, 7, 12]),
        Preset("Minor arpeggio", [0, 3, 7, 12]),
        Preset("Arpeggio up and down", [0, 4, 7, 12, 7, 4]),
        Preset("Octaves", [0, 12]),
        Preset("Fifths", [0, 7]),
        Preset("Root and fifth walk", [0, 0, 7, 0, 5, 0, 7, 10]),
        Preset("Acid line", [0, 0, 12, 0, 0, 10, 0, 7, 0, 12, 0, 3, 0, 0, 5, 7]),
        Preset("Minor pentatonic", [0, 3, 5, 7, 10, 7, 5, 3]),
        // Added 2026-11-18 (user's request for more): chord arpeggios, runs, bass and groove figures.
        Preset("Major 7 arpeggio", [0, 4, 7, 11]),
        Preset("Minor 7 arpeggio", [0, 3, 7, 10]),
        Preset("Dominant 7 arpeggio", [0, 4, 7, 10]),
        Preset("Sus4 arpeggio", [0, 5, 7, 12]),
        Preset("Major arpeggio down", [12, 7, 4, 0]),
        Preset("Minor arpeggio down", [12, 7, 3, 0]),
        Preset("Power fifths", [0, 7, 12, 7]),
        Preset("Octave and fifth", [0, 12, 7, 12]),
        Preset("Syncopated octaves", [0, 12, 0, 0, 12, 0, 12, 0]),
        Preset("Pedal tone", [0, 7, 0, 12, 0, 7, 0, 10]),
        Preset("Rolling bass", [0, 0, 12, 0, 0, 10, 0, 7]),
        Preset("Blues riff", [0, 3, 5, 6, 7, 10, 7, 5]),
        Preset("Major pentatonic run", [0, 2, 4, 7, 9, 7, 4, 2]),
        Preset("Dorian run", [0, 2, 3, 5, 7, 9, 10, 12]),
        Preset("Phrygian line", [0, 1, 3, 5, 7, 5, 3, 1]),
        Preset("Whole tone run", [0, 2, 4, 6, 8, 10, 8, 6]),
        Preset("Chromatic climb", [0, 1, 2, 3, 4, 5, 6, 7]),
        Preset("Hirajoshi", [0, 2, 3, 7, 8, 7, 3, 2]),
        Preset("Tritone", [0, 6]),
        Preset("Minor third bounce", [0, 3]),
        Preset("Major arpeggio, 3 octaves", [0, 4, 7, 12, 16, 19, 24, 19, 16, 12, 7, 4]),
        Preset("Minor arpeggio, 3 octaves", [0, 3, 7, 12, 15, 19, 24, 19, 15, 12, 7, 3]),
        Preset("Fourths stack", [0, 5, 10, 15, 10, 5]),
        Preset("Octave staircase", [0, 12, 24, 12]),
    ] + styles

    /// Figures by style (added 2026-11-18 — more presets at the user's request): each is one bar of 16 steps in
    /// semitones above the root, meant for a minor key unless the name says otherwise. Repeated notes are on
    /// purpose: the rhythm comes from the step row (Step on) and the Rhythm bank.
    private static let styles: [Preset] = [
        // Acid
        Preset("Acid squelch", [0, 0, 0, 12, 0, 0, 7, 0, 0, 12, 0, 0, 10, 0, 7, 5], group: "Acid"),
        Preset("Acid climb", [0, 0, 3, 0, 5, 0, 7, 0, 10, 0, 12, 0, 10, 0, 7, 3], group: "Acid"),
        Preset("Acid octave jumps", [0, 12, 0, 12, 0, 0, 12, 0, 0, 12, 0, 7, 0, 12, 0, 0], group: "Acid"),
        Preset("Acid slide", [0, 0, 0, 3, 3, 5, 5, 7, 7, 10, 10, 12, 12, 10, 7, 3], group: "Acid"),
        // Trance
        Preset("Trance arp", [0, 7, 12, 15, 12, 7, 0, 7, 3, 10, 15, 19, 15, 10, 3, 10], group: "Trance"),
        Preset("Rolling octaves", [0, 12, 7, 12, 0, 12, 7, 12, 3, 15, 10, 15, 5, 17, 12, 17], group: "Trance"),
        Preset("Uplifting lead", [12, 14, 15, 19, 15, 14, 12, 10, 12, 14, 15, 19, 22, 19, 15, 14], group: "Trance"),
        Preset("Trance pluck", [0, 0, 12, 0, 7, 0, 12, 0, 0, 0, 12, 0, 7, 0, 12, 0], group: "Trance"),
        // Techno
        Preset("Root pulse", [0], group: "Techno"),
        Preset("Rumble octaves", [0, 0, 0, 12, 0, 0, 0, 12, 0, 0, 0, 12, 0, 0, 12, 0], group: "Techno"),
        Preset("Minor chug", [0, 0, 3, 0, 0, 0, 5, 0, 0, 0, 3, 0, 0, 7, 0, 0], group: "Techno"),
        Preset("Techno stab", [0, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 7, 0], group: "Techno"),
        // Dub techno
        Preset("Dub minor 9", [0, 3, 7, 10, 14, 10, 7, 3], group: "Dub techno"),
        Preset("Dub sparse", [0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 0], group: "Dub techno"),
        Preset("Dub fifth echo", [0, 7, 0, 7, 3, 10, 3, 10], group: "Dub techno"),
        // House and disco
        Preset("House piano riff", [0, 3, 7, 3, 10, 7, 3, 0, 5, 8, 12, 8, 7, 10, 14, 10], group: "House & disco"),
        Preset("Funky house bass", [0, 12, 0, 10, 0, 7, 0, 5, 0, 12, 0, 10, 0, 7, 3, 0], group: "House & disco"),
        Preset("Disco octaves", [0, 12, 0, 12, 0, 12, 0, 12, 5, 17, 5, 17, 7, 19, 7, 19], group: "House & disco"),
        Preset("Offbeat chord root", [0, 0, 0, 0, 3, 3, 3, 3, 5, 5, 5, 5, 7, 7, 7, 7], group: "House & disco"),
        // Drum and bass
        Preset("DnB bass line", [0, 0, 12, 0, 0, 10, 0, 0, 7, 0, 0, 5, 0, 3, 0, 0], group: "Drum & bass"),
        Preset("Jungle sub", [0, 0, 0, 12, 0, 0, 10, 0, 0, 7, 0, 0, 12, 0, 0, 5], group: "Drum & bass"),
        Preset("Reese walk", [0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 3, 5, 5, 7, 7], group: "Drum & bass"),
        // Funk
        Preset("Funk slap", [0, 12, 0, 0, 10, 0, 12, 0, 0, 7, 0, 5, 0, 3, 5, 0], group: "Funk"),
        Preset("Funk walk", [0, 0, 3, 5, 7, 5, 3, 0, 0, 0, 5, 7, 10, 7, 5, 3], group: "Funk"),
        Preset("Octave pops", [0, 0, 12, 0, 0, 12, 0, 12], group: "Funk"),
        // Ambient and arps
        Preset("Ambient fifths", [0, 7, 12, 7, 14, 7, 12, 7], group: "Ambient & arps"),
        Preset("Lydian shimmer", [0, 7, 11, 14, 18, 14, 11, 7], group: "Ambient & arps"),
        Preset("Pentatonic drift", [0, 2, 7, 4, 9, 7, 12, 9], group: "Ambient & arps"),
        Preset("Sus2 arpeggio", [0, 2, 7, 12, 14, 12, 7, 2], group: "Ambient & arps"),
        Preset("Open fifths and sixths", [0, 7, 9, 14, 12, 9, 7, 4], group: "Ambient & arps"),
    ]

    /// Notes for the 16 steps: the figure repeated, above `base`, kept inside 0…127.
    public static func notes(of figure: Preset, base: Int) -> [Int] {
        (0 ..< count).map { max(0, min(127, base + figure.steps[$0 % figure.steps.count])) }
    }

    /// SeqEvent: Row 1 (kick) and Row 2 (snare / clap / hat) on 16 steps — the usual grooves of
    /// house, rock, hip-hop, breakbeat and the Latin claves (all on one bar of 16 steps).
    public static let rhythms: [Preset] = [
        Preset("Four on the floor", flags([0, 4, 8, 12]), second: flags([4, 12])),
        Preset("House (offbeat hat)", flags([0, 4, 8, 12]), second: flags([2, 6, 10, 14])),
        Preset("Rock backbeat", flags([0, 8]), second: flags([4, 12])),
        Preset("Boom bap", flags([0, 7, 10]), second: flags([4, 12])),
        Preset("Breakbeat", flags([0, 2, 10]), second: flags([4, 12])),
        Preset("Half-time", flags([0, 10]), second: flags([8])),
        Preset("Trap", flags([0, 7, 10]), second: flags([8])),
        Preset("Dembow", flags([0, 4, 8, 12]), second: flags([3, 6, 11, 14])),
        Preset("Son clave 3-2", flags([0, 3, 6, 10, 12]), second: flags([])),
        Preset("Rumba clave 3-2", flags([0, 3, 7, 10, 12]), second: flags([])),
        Preset("Bossa nova clave", flags([0, 3, 6, 10, 13]), second: flags([0, 4, 8, 12])),
        Preset("Tresillo", flags([0, 3, 6, 8, 11, 14]), second: flags([])),
        Preset("Offbeat", flags([2, 6, 10, 14]), second: flags([0, 4, 8, 12])),
    ]
}
