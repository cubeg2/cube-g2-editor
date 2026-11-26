// EuclidGroup.swift
// Euclid on a group of sequencers: Interlock (the others fill the gaps of the first), Random group
// (hits rise from the first lane to the last, the second never plays with the first), and the
// meeting points — the steps where several lanes hit together.
//
// Pure functions over value arrays, like `EuclideanRhythm`; the window writes the patterns as
// ordinary step on/off values, one undo step.
// → [[Docs/roadmap]] "Euclid na grupie sekwencerów"

import Foundation

public enum EuclidGroup {
    /// Interlock: lane 1 plays E(`hits`, `steps`) rotated by `rotation`; the steps it rests on are dealt
    /// out one by one to the other lanes (two lanes: lane 2 is exactly the rests of lane 1). Together the
    /// lanes play every step once.
    public static func interlock(hits: Int, steps: Int, rotation: Int, lanes: Int) -> [[Bool]] {
        let steps = max(1, min(SequencerLayout.steps, steps))
        let first = EuclideanRhythm.pattern(hits: hits, steps: steps, rotation: rotation)
        guard lanes > 1 else { return lanes == 1 ? [first] : [] }
        var result = [first] + Array(repeating: Array(repeating: false, count: steps), count: lanes - 1)
        let rests = first.indices.filter { !first[$0] }
        for (position, step) in rests.enumerated() {
            result[1 + position % (lanes - 1)][step] = true
        }
        return result
    }

    /// Random group: one Euclidean rhythm per lane of `steps[i]` steps with a random rotation. The share
    /// of steps that play rises from 20 % on the first lane to 60 % on the last (kick sparse, hats
    /// busy), every lane has at least one hit, and lane 2 is rotated to meet lane 1 as little as possible
    /// (kick and snare never together, when the lengths allow it).
    public static func randomLanes(steps: [Int], using generator: inout some RandomNumberGenerator) -> [[Bool]] {
        var result: [[Bool]] = []
        for (index, length) in steps.enumerated() {
            let length = max(1, min(SequencerLayout.steps, length))
            let position = steps.count > 1 ? Double(index) / Double(steps.count - 1) : 0.5
            let hits = max(1, min(length, Int((Double(length) * (0.2 + 0.4 * position)).rounded())))
            func pattern(_ rotation: Int) -> [Bool] {
                EuclideanRhythm.pattern(hits: hits, steps: length, rotation: rotation)
            }
            var rotation = Int.random(in: 0 ..< length, using: &generator)
            if index == 1, let first = result.first, first.count == length {
                let overlaps = (0 ..< length).map { rotation in
                    zip(pattern(rotation), first).filter { $0 && $1 }.count
                }
                let best = overlaps.min() ?? 0
                let candidates = overlaps.indices.filter { overlaps[$0] == best }
                rotation = candidates.randomElement(using: &generator) ?? rotation
            }
            result.append(pattern(rotation))
        }
        return result
    }

    // MARK: Meeting points

    /// Steps shown for lanes of the given lengths: the time after which they all start over together,
    /// at most 32 (and 16 when there are no lanes).
    public static func span(ofLengths lengths: [Int]) -> Int {
        guard !lengths.isEmpty else { return SequencerLayout.steps }
        var result = 1
        for length in lengths.map({ max(1, $0) }) {
            var (a, b) = (result, length)
            while b != 0 { (a, b) = (b, a % b) }
            result = result / a * length
            if result >= 32 { return 32 }
        }
        return result
    }

    /// For each of `span` steps: how many lanes hit there. A lane shorter than `span` repeats.
    public static func meetingCounts(lanes: [[Bool]], span: Int) -> [Int] {
        (0 ..< max(0, span)).map { step in
            lanes.filter { !$0.isEmpty && $0[step % $0.count] }.count
        }
    }
}
