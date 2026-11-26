// SequenceGenerators.swift
// Melody generators for the Sequence Editor's Generate menu: Markov (plays "like the current
// pattern"), Walk (small steps along a scale) and Motif (a short figure repeated with variations).
//
// Like everything in `SequencePattern`, these are pure functions over value arrays. They only
// produce the 16 note values; the window writes them as ordinary parameter changes (one undo
// step, locked steps kept), so the patch stays byte-for-byte hand-editable.
// → [[Docs/roadmap]] "Sequence Editor" wersja 2 (generatory)

import Foundation

public enum SequenceGenerator: String, CaseIterable, Identifiable, Sendable {
    case markov, walk, motif

    public var id: String {
        rawValue
    }

    /// Name shown in the UI — English.
    public var title: String {
        switch self {
        case .markov: "Markov (like current)"
        case .walk: "Walk"
        case .motif: "Motif"
        }
    }

    /// Tooltip text — English.
    public var help: String {
        switch self {
        case .markov: "New melody that uses the notes of the current pattern and the moves between them"
        case .walk: "Melody that moves in small steps along the scale"
        case .motif: "A short random figure, repeated with small variations"
        }
    }

    /// Notes a generator may use: the scale (built on `root`) inside `range`. With no scale
    /// every semitone of the range is allowed.
    public static func pool(range: ClosedRange<Int>, scale: MusicalScale?, root: Int) -> [Int] {
        let notes = (scale ?? .chromatic).notes(in: range, root: root)
        return notes.isEmpty ? Array(range) : notes
    }

    /// Generate `count` notes. `current` is the pattern as it stands (the Markov model learns
    /// from its first `length` steps; Walk and Motif ignore it).
    public func notes(count: Int = SequencerLayout.steps,
                      current: [Int],
                      length: Int,
                      range: ClosedRange<Int>,
                      scale: MusicalScale?,
                      root: Int,
                      using generator: inout some RandomNumberGenerator) -> [Int]
    {
        let pool = Self.pool(range: range, scale: scale, root: root)
        switch self {
        case .markov:
            return Self.markov(count: count, source: Array(current.prefix(max(1, length))),
                               pool: pool, scale: scale, root: root, using: &generator)
        case .walk:
            return Self.walk(count: count, pool: pool, using: &generator)
        case .motif:
            return Self.motif(count: count, pool: pool, using: &generator)
        }
    }

    // MARK: Markov

    /// First-order Markov chain over the notes of `source`: after note A comes a note that
    /// followed A somewhere in the source (the end wraps to the start, so loops stay loops).
    /// A source with fewer than two different notes has nothing to learn — falls back to Walk.
    /// Notes outside the scale snap to it, so the result obeys the chosen scale.
    static func markov(count: Int, source: [Int], pool: [Int],
                       scale: MusicalScale?, root: Int,
                       using generator: inout some RandomNumberGenerator) -> [Int]
    {
        guard Set(source).count >= 2 else { return walk(count: count, pool: pool, using: &generator) }
        var successors: [Int: [Int]] = [:]
        for (index, note) in source.enumerated() {
            successors[note, default: []].append(source[(index + 1) % source.count])
        }
        func fit(_ note: Int) -> Int {
            scale.map { $0.snapped(note, root: root) } ?? note
        }
        var current = source.randomElement(using: &generator) ?? source[0]
        var result: [Int] = []
        for _ in 0 ..< count {
            result.append(fit(current))
            current = successors[current]?.randomElement(using: &generator)
                ?? source.randomElement(using: &generator) ?? current
        }
        return result
    }

    // MARK: Walk

    /// Random walk over the pool: each step moves up to `maxLeap` pool notes either way
    /// (so at most `maxLeap` scale degrees); at the ends of the range it bounces back.
    static func walk(count: Int, pool: [Int], maxLeap: Int = 2,
                     using generator: inout some RandomNumberGenerator) -> [Int]
    {
        guard !pool.isEmpty else { return Array(repeating: 64, count: count) }
        var position = Int.random(in: 0 ..< pool.count, using: &generator)
        var result: [Int] = []
        for _ in 0 ..< count {
            result.append(pool[position])
            let move = Int.random(in: -maxLeap ... maxLeap, using: &generator)
            position = bounced(position + move, count: pool.count)
        }
        return result
    }

    // MARK: Motif

    /// A random figure of `motifLength` notes (a short walk), repeated over the steps. After
    /// the first pass every note has a `variation` chance (0…1) to move one pool note up or down.
    static func motif(count: Int, pool: [Int], motifLength: Int = 4, variation: Double = 0.25,
                      using generator: inout some RandomNumberGenerator) -> [Int]
    {
        guard !pool.isEmpty else { return Array(repeating: 64, count: count) }
        let figure = walk(count: max(1, motifLength), pool: pool, maxLeap: 3, using: &generator)
        let chance = max(0, min(1, variation))
        return (0 ..< count).map { step in
            let note = figure[step % figure.count]
            guard step >= figure.count, Double.random(in: 0 ..< 1, using: &generator) < chance,
                  let index = pool.firstIndex(of: note)
            else { return note }
            let move = Bool.random(using: &generator) ? 1 : -1
            return pool[bounced(index + move, count: pool.count)]
        }
    }

    /// Fold `index` back into 0 ..< count by reflecting at both ends.
    static func bounced(_ index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        if index < 0 { return min(count - 1, -index) }
        if index >= count { return max(0, 2 * (count - 1) - index) }
        return index
    }
}
