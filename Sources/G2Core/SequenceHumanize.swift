// SequenceHumanize.swift
// Humanize for the value rows of SeqVal, SeqLev and SeqCtr: every step that plays gets a small random
// nudge, so accents and modulation lines breathe instead of repeating exactly.
//
// Values only. A G2 step sequencer has one value and one on/off flag per step and no timing, so there is no
// way to move a step in time from here — the clock's Swing is the only timing control.
// Pure function over value arrays, like `SequenceCurve`; the window writes the result as ordinary step
// values (one undo step, locked steps kept).
// → [[Docs/roadmap]] "Sequence Editor" wersja 2 (humanize)

import Foundation

public enum SequenceHumanize {
    /// The largest nudge, in values, for an `amount` in percent of the range 0…127 (100 % = ±63).
    public static func spread(amount: Int) -> Int {
        Int((Double(max(0, min(100, amount))) / 100 * 127 / 2).rounded())
    }

    /// `values` with every step that plays (inside the first `length`) moved by a random amount up to
    /// ±`spread(amount:)`, kept inside 0…127. Small nudges are likelier than big ones (two dice, not one).
    /// Steps that rest, and steps after `length`, stay as they are.
    public static func jittered(_ values: [Int], playing: [Bool], length: Int, amount: Int,
                                using generator: inout some RandomNumberGenerator) -> [Int]
    {
        let reach = spread(amount: amount)
        guard reach > 0 else { return values }
        return values.enumerated().map { step, value in
            guard step < length, step < playing.count, playing[step] else { return value }
            let first = Int.random(in: -reach ... reach, using: &generator)
            let second = Int.random(in: -reach ... reach, using: &generator)
            return max(0, min(127, value + (first + second) / 2))
        }
    }
}
