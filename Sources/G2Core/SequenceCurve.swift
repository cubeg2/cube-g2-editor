// SequenceCurve.swift
// Curve generator for the value rows of SeqVal, SeqLev and SeqCtr: a shape (sine, triangle, saw, square,
// smooth random, sample & hold, accent groove) laid over the played steps, with a number of cycles, a
// phase shift and a low and a high end.
//
// Pure functions over value arrays, like `SequenceGenerator`: the window writes the 16 values as
// ordinary step values (one undo step, locked steps kept), nothing is added to the patch.
// → [[Docs/roadmap]] "Sequence Editor" wersja 2 (generatory)

import Foundation

public enum SequenceCurve: String, CaseIterable, Identifiable, Sendable {
    case sine, triangle, sawUp, sawDown, square, smoothRandom, sampleAndHold, groove

    public var id: String {
        rawValue
    }

    /// Name shown in the UI — English.
    public var title: String {
        switch self {
        case .sine: "Sine"
        case .triangle: "Triangle"
        case .sawUp: "Saw up"
        case .sawDown: "Saw down"
        case .square: "Square"
        case .smoothRandom: "Smooth random"
        case .sampleAndHold: "Sample & hold"
        case .groove: "Accent groove"
        }
    }

    /// Tooltip text — English.
    public var help: String {
        switch self {
        case .sine: "A smooth wave"
        case .triangle: "Up and down in straight lines"
        case .sawUp: "Rises, then jumps back"
        case .sawDown: "Falls, then jumps back"
        case .square: "Half the steps high, half low"
        case .smoothRandom: "Random points joined by smooth curves (4 per cycle); a new one each time"
        case .sampleAndHold: "Random values held for a few steps (4 per cycle); a new one each time"
        case .groove: "Strong on the beats, medium on the eighths, weak between — for accents (Cycles is ignored)"
        }
    }

    /// The `count` step values (0…127). The shape is laid over the first `length` steps — `cycles`
    /// times (1…4) — moved on by `phase` steps; the steps after `length` repeat it. `low` and `high` are
    /// percentages of the whole range 0…127 (swapped if given the wrong way round).
    public func values(count: Int = SequencerLayout.steps, length: Int, cycles: Int, phase: Int,
                       low: Int, high: Int, using generator: inout some RandomNumberGenerator) -> [Int]
    {
        let length = max(1, min(SequencerLayout.steps, length))
        let cycles = max(1, min(4, cycles))
        let lowEnd = Double(max(0, min(100, min(low, high)))) / 100
        let highEnd = Double(max(0, min(100, max(low, high)))) / 100
        let segments = max(1, min(length, cycles * 4))
        let points = (0 ..< segments).map { _ in Double.random(in: 0 ... 1, using: &generator) }

        return (0 ..< max(0, count)).map { step in
            let position = ((step % length) + (phase % length + length) % length) % length
            let fraction = Double(position) / Double(length) * Double(cycles)
            let x = fraction - fraction.rounded(.down)
            let level: Double = switch self {
            case .sine: 0.5 + 0.5 * sin(2 * .pi * x)
            case .triangle: x < 0.5 ? 2 * x : 2 - 2 * x
            case .sawUp: x
            case .sawDown: 1 - x
            case .square: x < 0.5 ? 1 : 0
            case .smoothRandom, .sampleAndHold: randomLevel(position: position, length: length,
                                                            points: points, smooth: self == .smoothRandom)
            case .groove: position % 4 == 0 ? 1 : (position % 2 == 0 ? 0.7 : 0.45)
            }
            return max(0, min(127, Int(((lowEnd + level * (highEnd - lowEnd)) * 127).rounded())))
        }
    }

    /// The random shapes: `points` spread evenly over the length, held (sample & hold) or joined by
    /// cosine curves, the last one running back to the first so the curve loops.
    private func randomLevel(position: Int, length: Int, points: [Double], smooth: Bool) -> Double {
        let segment = Double(position) * Double(points.count) / Double(length)
        let index = min(points.count - 1, Int(segment))
        guard smooth else { return points[index] }
        let fraction = segment - Double(index)
        let blend = (1 - cos(.pi * fraction)) / 2
        return points[index] + (points[(index + 1) % points.count] - points[index]) * blend
    }
}
