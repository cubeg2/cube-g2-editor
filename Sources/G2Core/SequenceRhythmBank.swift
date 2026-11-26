// SequenceRhythmBank.swift
// A bank of 16-step on/off rhythms for the Sequence Editor's Presets ▸ Rhythm bank menu. Each line is
// one bar of 16 steps: "x" plays, "-" rests. Pure data — the window writes it as one undo step into
// Row 1 of a SeqEvent, or into the step on/off row of the other sequencers, and keeps locked steps.
// Source: a list generated with Grok (2026-11), used as-is; the patterns are plain step grids with no
// claim to a particular drum role — the first step always plays. The two repeats in that list
// (its patterns 104 and 112) are left out, so the bank has 122 patterns.
// → [[Docs/roadmap]] "Sequence Editor — presety"

import Foundation

public enum SequenceRhythmBank {
    /// The patterns in bank order (1…). Each has exactly `SequencerLayout.steps` characters.
    public static let patterns: [String] = source.split(separator: "\n").map(String.init)

    /// Patterns per submenu page.
    public static let pageSize = 20

    /// The 16 on/off flags of pattern `index` (0-based); empty if there is no such pattern.
    public static func flags(at index: Int) -> [Int] {
        guard patterns.indices.contains(index) else { return [] }
        return patterns[index].map { $0 == "x" ? 1 : 0 }
    }

    /// Menu text of pattern `index`: its number and the steps drawn as ■ (plays) and · (rests),
    /// with a gap every four steps so the beats can be read.
    public static func label(at index: Int) -> String {
        guard patterns.indices.contains(index) else { return "" }
        let steps = patterns[index].map { $0 == "x" ? "■" : "·" }
        let beats = stride(from: 0, to: steps.count, by: 4).map { steps[$0 ..< min($0 + 4, steps.count)].joined() }
        return "\(index + 1)   " + beats.joined(separator: " ")
    }

    /// What a pattern is best suited to play, judged from where its hits fall (see `role(at:)`).
    public enum Role: String, CaseIterable, Identifiable, Sendable {
        case kick, snare, hat, percussion

        public var id: String {
            rawValue
        }

        /// Name for menus — English.
        public var title: String {
            switch self {
            case .kick: "Kick"
            case .snare: "Snare / Clap"
            case .hat: "Hat"
            case .percussion: "Percussion"
            }
        }
    }

    /// A rule of thumb, not a claim about the music — the list itself carries no roles. In order:
    /// - **Snare / Clap:** hits on steps 5 and 13 (the backbeat) but not on 9, so it leans on 2 and 4.
    /// - **Kick:** at least three hits on the quarter notes (1, 5, 9, 13), at most two on odd steps and
    ///   no more than six hits in all — a steady, anchored pattern.
    /// - **Hat:** four or more hits between the quarter notes (offbeats, syncopation) or a dense run of
    ///   straight eighths.
    /// - **Percussion:** whatever is left.
    public static func role(at index: Int) -> Role? {
        guard patterns.indices.contains(index) else { return nil }
        let hits = patterns[index].enumerated().filter { $0.element == "x" }.map(\.offset)
        let onBeats = hits.filter { $0 % 4 == 0 }.count
        let onOdd = hits.filter { $0 % 2 == 1 }.count
        if hits.contains(4), hits.contains(12), !hits.contains(8) { return .snare }
        if onBeats >= 3, onOdd <= 2, hits.count <= 6 { return .kick }
        if hits.count - onBeats >= 4 || hits.count > 6 { return .hat }
        return .percussion
    }

    /// 0-based indices of the patterns of one role, in bank order.
    public static func indices(of role: Role) -> [Int] {
        patterns.indices.filter { self.role(at: $0) == role }
    }

    /// Splits `indices` into menu pages of `pageSize`.
    public static func pages(of indices: [Int]) -> [[Int]] {
        stride(from: 0, to: indices.count, by: pageSize).map { Array(indices[$0 ..< min($0 + pageSize, indices.count)]) }
    }

    private static let source = """
    x---x---x---x---
    x--x--x--x--x--x
    x-x-x-x-x-x-x-x-
    x--x-x--x--x-x--
    x---x--x-x--x---
    x-x--x-x-x--x-x-
    x--x--x-x--x--x-
    x-x-x---x-x-x---
    x---x-x---x-x---
    x--x-x-x--x-x-x-
    x-x---x-x---x-x-
    x--x---x--x---x-
    x-x-x-x---x-x-x-
    x---x---x--x-x--
    x--x-x---x--x-x-
    x-x--x--x-x--x--
    x---x-x-x---x-x-
    x--x--x---x--x--
    x-x-x--x-x-x--x-
    x---x--x---x--x-
    x--x-x--x-x--x--
    x-x---x--x-x---x
    x--x---x-x--x---
    x-x-x---x--x-x--
    x---x-x--x---x-x
    x--x--x-x-x--x--
    x-x--x-x--x-x--x
    x---x---x-x---x-
    x--x-x-x-x--x-x-
    x-x-x--x---x-x--
    x---x-x---x--x--
    x--x---x-x-x---x
    x-x--x---x-x--x-
    x---x--x-x-x--x-
    x--x-x---x-x---x
    x-x-x-x--x---x-x
    x---x-x-x--x---x
    x--x--x---x-x--x
    x-x---x-x-x---x-
    x--x-x-x---x--x-
    x-x-x---x-x---x-
    x---x--x--x-x---
    x--x---x---x--x-
    x-x--x-x---x-x--
    x---x-x--x-x---x
    x--x-x--x---x-x-
    x-x-x-x-x---x---
    x---x---x-x-x---
    x--x--x-x---x-x-
    x-x---x--x---x-x
    x--x-x-x-x-x--x-
    x-x-x--x-x---x--
    x---x-x---x-x-x-
    x--x---x-x---x-x
    x-x--x---x--x-x-
    x---x--x-x---x--
    x--x-x--x-x-x---
    x-x-x-x---x--x--
    x---x-x-x-x---x-
    x--x--x---x-x-x-
    x-x---x-x--x---x
    x--x-x---x---x-x
    x-x-x--x--x-x---
    x---x---x--x---x
    x--x-x-x--x---x-
    x-x--x-x-x-x---x
    x---x-x--x--x-x-
    x--x---x--x-x-x-
    x-x-x---x---x-x-
    x---x--x-x-x-x--
    x--x-x--x---x---
    x-x-x-x-x-x---x-
    x---x-x-x---x---
    x--x--x-x-x-x---
    x-x---x---x-x--x
    x--x-x-x---x-x--
    x-x-x--x-x-x---x
    x---x---x-x--x--
    x--x-x---x-x-x--
    x-x--x--x---x-x-
    x---x-x-x--x-x--
    x--x---x-x-x-x--
    x-x-x---x-x-x-x-
    x---x--x---x-x-x
    x--x-x-x-x---x--
    x-x--x-x---x---x
    x---x-x---x---x-
    x--x--x---x---x-
    x-x-x-x--x-x---x
    x---x-x-x-x-x---
    x--x-x--x-x---x-
    x-x---x-x-x-x---
    x--x---x---x-x-x
    x-x-x--x---x---x
    x---x--x-x--x-x-
    x--x-x-x--x-x---
    x-x--x---x-x-x--
    x---x-x--x-x-x--
    x--x---x-x---x--
    x-x-x-x-x---x-x-
    x---x---x-x-x-x-
    x--x-x---x--x---
    x-x--x-x-x---x--
    x--x--x-x--x-x--
    x-x-x---x--x---x
    x---x--x--x---x-
    x--x-x-x-x-x-x--
    x-x--x---x---x-x
    x---x-x--x---x--
    x--x---x-x-x--x-
    x---x-x-x-x--x--
    x--x-x--x--x---x
    x-x---x--x-x-x--
    x--x-x-x---x---x
    x-x-x--x-x--x---
    x---x---x--x-x-x
    x--x--x-x-x---x-
    x-x--x-x--x---x-
    x---x-x---x-x--x
    x--x-x---x-x--x-
    x-x-x-x-x-x-x---
    x---x--x-x-x---x
    """
}
