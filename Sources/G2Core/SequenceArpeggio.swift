// SequenceArpeggio.swift
// Arpeggio for the Sequence Editor (SeqNote): a chord — picked by type, stacked from a scale
// degree, or taken from the notes already in the pattern — turned into the 16 steps in a chosen
// direction over one to three octaves.
//
// Pure functions over value arrays, like `SequenceGenerator`: the window writes the result as
// ordinary note values (one undo step, locked steps kept), nothing is added to the patch.
// → [[Docs/roadmap]] "Sequence Editor" wersja 2 (arpeggiator z akordu)

import Foundation

/// Chord types for the arpeggiator. Intervals in semitones above the chord root.
public enum ChordType: String, CaseIterable, Identifiable, Sendable {
    case major, minor, diminished, augmented, sus2, sus4
    case dominant7, major7, minor7, halfDiminished, diminished7, minorMajor7

    public var id: String {
        rawValue
    }

    public var intervals: [Int] {
        switch self {
        case .major: [0, 4, 7]
        case .minor: [0, 3, 7]
        case .diminished: [0, 3, 6]
        case .augmented: [0, 4, 8]
        case .sus2: [0, 2, 7]
        case .sus4: [0, 5, 7]
        case .dominant7: [0, 4, 7, 10]
        case .major7: [0, 4, 7, 11]
        case .minor7: [0, 3, 7, 10]
        case .halfDiminished: [0, 3, 6, 10]
        case .diminished7: [0, 3, 6, 9]
        case .minorMajor7: [0, 3, 7, 11]
        }
    }

    /// Written after the root note: "C", "Cm", "C7", "Cmaj7"… — English.
    public var suffix: String {
        switch self {
        case .major: ""
        case .minor: "m"
        case .diminished: "dim"
        case .augmented: "aug"
        case .sus2: "sus2"
        case .sus4: "sus4"
        case .dominant7: "7"
        case .major7: "maj7"
        case .minor7: "m7"
        case .halfDiminished: "m7♭5"
        case .diminished7: "dim7"
        case .minorMajor7: "mMaj7"
        }
    }

    /// Name for menus — English.
    public var title: String {
        switch self {
        case .major: "Major"
        case .minor: "Minor"
        case .diminished: "Diminished"
        case .augmented: "Augmented"
        case .sus2: "Sus2"
        case .sus4: "Sus4"
        case .dominant7: "Dominant 7"
        case .major7: "Major 7"
        case .minor7: "Minor 7"
        case .halfDiminished: "Half-diminished (m7♭5)"
        case .diminished7: "Diminished 7"
        case .minorMajor7: "Minor-major 7"
        }
    }

    /// The type whose intervals are exactly `intervals` (from the root, ascending), if any.
    public static func recognize(_ intervals: [Int]) -> ChordType? {
        allCases.first { $0.intervals == intervals }
    }
}

/// Order in which the chord notes are played.
public enum ArpeggioDirection: String, CaseIterable, Identifiable, Sendable {
    case up, down, upDown, downUp, random

    public var id: String {
        rawValue
    }

    /// Name for menus — English.
    public var title: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .upDown: "Up-Down"
        case .downUp: "Down-Up"
        case .random: "Random"
        }
    }
}

/// Where the chord comes from.
public enum ArpeggioChord: Hashable, Sendable {
    /// A chord type built on the scale root.
    case type(ChordType)
    /// Thirds stacked on a degree of the chosen scale (0 = first degree), three notes or four.
    case scaleDegree(Int, seventh: Bool)
    /// The different notes the pattern already plays.
    case pattern
}

public enum SequenceArpeggio {
    /// Notes of a chord of `type` with its root at `root` (MIDI), ascending, kept inside 0…127.
    public static func notes(of type: ChordType, root: Int) -> [Int] {
        type.intervals.map { root + $0 }.filter { (0 ... 127).contains($0) }
    }

    /// Scale a degree chord is stacked in: the chromatic scale has no degrees, so it reads as major.
    public static func degreeScale(_ scale: MusicalScale) -> MusicalScale {
        scale == .chromatic ? .major : scale
    }

    /// Chord built from every other note of the scale, starting at `degree` (0 = the root). `base` is
    /// the first-degree note (MIDI) the counting starts from. Empty if the scale runs out of notes.
    public static func scaleChord(degree: Int, seventh: Bool, scale: MusicalScale, root: Int, base: Int) -> [Int] {
        let pool = degreeScale(scale).notes(in: 0 ... 127, root: root)
        guard let start = pool.firstIndex(where: { $0 >= base }) else { return [] }
        let first = start + max(0, degree)
        let picks = seventh ? [0, 2, 4, 6] : [0, 2, 4]
        let indices = picks.map { first + $0 }
        guard let last = indices.last, last < pool.count else { return [] }
        return indices.map { pool[$0] }
    }

    /// Menu name of a scale-degree chord: root note and quality, e.g. "E m" in C major — empty
    /// quality (a plain triad) shows just the note. `noteName` turns a pitch class into text.
    public static func scaleChordName(degree: Int, seventh: Bool, scale: MusicalScale, root: Int,
                                      noteName: (Int) -> String) -> String
    {
        let chord = scaleChord(degree: degree, seventh: seventh, scale: scale, root: root, base: 60)
        guard let first = chord.first else { return "–" }
        let quality = ChordType.recognize(chord.map { $0 - first })
        return noteName(first % 12) + (quality?.suffix ?? "")
    }

    /// Number of degrees to offer for a scale (the chromatic scale counts as major).
    public static func degreeCount(of scale: MusicalScale) -> Int {
        degreeScale(scale).intervals.count
    }

    /// The `count` steps: the chord repeated over `octaves` octaves, played in `direction`. A chord
    /// of one note repeats it; notes above 127 are left out. Random never plays the same note twice
    /// in a row when it has a choice.
    public static func steps(chord: [Int], direction: ArpeggioDirection, octaves: Int,
                             count: Int = SequencerLayout.steps,
                             using generator: inout some RandomNumberGenerator) -> [Int]
    {
        let base = Array(Set(chord)).sorted()
        guard !base.isEmpty else { return [] }
        let ladder = (0 ..< max(1, min(3, octaves))).flatMap { octave in
            base.map { $0 + 12 * octave }
        }
        .filter { $0 <= 127 }
        guard !ladder.isEmpty else { return [] }

        if direction == .random {
            var result: [Int] = []
            for _ in 0 ..< count {
                var next = ladder.randomElement(using: &generator) ?? ladder[0]
                if ladder.count > 1, next == result.last {
                    next = ladder.filter { $0 != next }.randomElement(using: &generator) ?? next
                }
                result.append(next)
            }
            return result
        }

        // Turning points are played once: up-down is c e g e, not c e g g e c.
        let inner = ladder.count > 2 ? Array(ladder.dropFirst().dropLast()) : []
        let cycle: [Int] = switch direction {
        case .up: ladder
        case .down: ladder.reversed()
        case .upDown: ladder + inner.reversed()
        case .downUp: ladder.reversed() + inner
        case .random: ladder
        }
        return (0 ..< count).map { cycle[$0 % cycle.count] }
    }
}
