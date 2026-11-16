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

        init(_ name: String, _ steps: [Int], second: [Int] = []) {
            self.name = name
            self.steps = steps
            self.second = second
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
