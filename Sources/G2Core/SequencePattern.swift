// SequencePattern.swift
// Pure step-sequencer logic for the Sequence Editor window: where the steps of each Seq
// module live in its parameter list, and the whole-pattern operations (shift, reverse,
// transpose, scale snap, Euclidean rhythms, Clavia-style Clear/Random).
//
// Everything here works on plain value arrays. The window turns the result into ordinary
// parameter changes, so a pattern edited here is byte-for-byte what hand-editing the
// sliders would produce — the patch keeps working on a G2 without this editor.
// → [[Docs/roadmap]] "Sequence Editor", [[Docs/ui/sequence-editor-euclid]]

import Foundation

// MARK: - Parameter layout

/// Where a step-sequencer module keeps its steps. All five Seq modules share the same
/// shape: row 1 = parameters 0–15, row 2 = 16–31; what follows differs per module.
public struct SequencerLayout: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// SeqNote: row 1 = notes 0…127 (64 = E4), row 2 = step on/off.
        case note
        /// SeqEvent: two on/off rows, no values.
        case event
        /// SeqVal / SeqLev: row 1 = values 0…127, row 2 = trigger on/off.
        case value
        /// SeqCtr: like `.value`, but the step is picked by the Ctrl input — no Length/Loop.
        case controlled
    }

    public static let steps = 16

    public let typeID: Int
    public let kind: Kind
    /// First parameter of each row (always 0 and 16).
    public let rowStarts: [Int]
    /// `Loop` parameter (0 = 1-Cycle, 1 = Loop); `nil` on SeqCtr.
    public let loopIndex: Int?
    /// `Length` parameter (stored 0…15 = 1…16 steps); `nil` on SeqCtr.
    public let lengthIndex: Int?
    /// `BipUni` parameter (0 = bipolar, 1 = unipolar); `nil` where the module has none.
    public let bipUniIndex: Int?

    /// Layout for a module type, `nil` for anything that is not a step sequencer.
    public init?(typeID: Int) {
        self.typeID = typeID
        rowStarts = [0, 16]
        switch typeID {
        case 121:
            kind = .note
            loopIndex = 32
            lengthIndex = 33
            bipUniIndex = nil
        case 144:
            kind = .event
            loopIndex = 32
            lengthIndex = 33
            bipUniIndex = nil
        case 145, 146:
            kind = .value
            loopIndex = 32
            lengthIndex = 33
            bipUniIndex = 34
        case 154:
            kind = .controlled
            loopIndex = nil
            lengthIndex = nil
            bipUniIndex = 33
        default:
            return nil
        }
    }

    public static func isSequencer(typeID: Int) -> Bool {
        SequencerLayout(typeID: typeID) != nil
    }

    /// The number a step's value is shown as, like the module: SeqVal in BiP −64…+63 (with a sign), in Uni
    /// 0…127; SeqLev in Uni 0…100 (percent), in BiP −64…+63.
    public func displayValue(_ value: Int, bipolar: Bool) -> String {
        if bipolar {
            let shifted = value - 64
            return shifted > 0 ? "+\(shifted)" : "\(shifted)"
        }
        return typeID == 146 ? "\(Int((Double(value) * 100 / 127).rounded()))" : "\(value)"
    }

    /// Does row `row` hold on/off flags (as opposed to 0…127 values)?
    public func isGateRow(_ row: Int) -> Bool {
        kind == .event || row == 1
    }

    /// Parameter indices of one row, step 1 first.
    public func indices(ofRow row: Int) -> [Int] {
        (0 ..< Self.steps).map { rowStarts[row] + $0 }
    }

    /// One row read out of the module's parameters (missing entries read as 0).
    public func row(_ row: Int, in parameters: [Int]) -> [Int] {
        indices(ofRow: row).map { $0 < parameters.count ? parameters[$0] : 0 }
    }

    /// Number of steps the module plays (1…16); 16 when the module has no Length.
    public func length(in parameters: [Int]) -> Int {
        guard let lengthIndex, lengthIndex < parameters.count else { return Self.steps }
        return max(1, min(Self.steps, parameters[lengthIndex] + 1))
    }

    public func isBipolar(in parameters: [Int]) -> Bool {
        guard let bipUniIndex, bipUniIndex < parameters.count else { return false }
        return parameters[bipUniIndex] == 0
    }
}

// MARK: - Whole-pattern operations

public enum SequencePattern {
    /// Rotate `values` right by `amount` steps (negative = left), wrapping around.
    /// Only the first `length` steps move — steps the module never plays stay put.
    public static func rotated(_ values: [Int], by amount: Int, length: Int? = nil) -> [Int] {
        let count = max(0, min(values.count, length ?? values.count))
        guard count > 1 else { return values }
        let shift = ((amount % count) + count) % count
        guard shift > 0 else { return values }
        let head = Array(values[..<count])
        var result = values
        for index in 0 ..< count {
            result[(index + shift) % count] = head[index]
        }
        return result
    }

    /// Reverse the first `length` steps.
    public static func reversed(_ values: [Int], length: Int? = nil) -> [Int] {
        let count = max(0, min(values.count, length ?? values.count))
        var result = values
        result.replaceSubrange(0 ..< count, with: values[..<count].reversed())
        return result
    }

    /// Mirror values inside `range` (low ↔ high), e.g. a melody upside down.
    public static func inverted(_ values: [Int], in range: ClosedRange<Int> = 0 ... 127) -> [Int] {
        values.map { range.upperBound + range.lowerBound - clamp($0, to: range) }
    }

    /// Mirror on/off flags.
    public static func invertedGates(_ gates: [Int]) -> [Int] {
        gates.map { $0 == 0 ? 1 : 0 }
    }

    /// Add `semitones` to every value, clamped to 0…127.
    public static func transposed(_ values: [Int], by semitones: Int) -> [Int] {
        values.map { clamp($0 + semitones, to: 0 ... 127) }
    }

    /// Copy steps 1–8 onto 9–16.
    public static func doubledFirstHalf(_ values: [Int]) -> [Int] {
        let half = values.count / 2
        guard half > 0 else { return values }
        return Array(values[..<half]) + Array(values[..<half]) + values[(half * 2)...]
    }

    /// Steps flagged in `locked` keep their old value; the rest take the new one.
    public static func respectingLocks(_ new: [Int], old: [Int], locked: Set<Int>) -> [Int] {
        new.indices.map { locked.contains($0) && $0 < old.count ? old[$0] : new[$0] }
    }

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        max(range.lowerBound, min(range.upperBound, value))
    }
}

// MARK: - Clavia Clear / Random

public extension SequencePattern {
    /// What the original editor's Clr button writes into the value row: the middle (64)
    /// on SeqNote and on bipolar modules, the bottom (0) on unipolar ones.
    static func clearedValue(kind: SequencerLayout.Kind, bipolar: Bool) -> Int {
        switch kind {
        case .note: 64
        case .event: 0
        case .value, .controlled: bipolar ? 64 : 0
        }
    }

    /// Clavia's Rnd: every step random over the whole range, except SeqNote, where it stays
    /// inside the octaves visible on the module (`noteRange`).
    static func randomValues(count: Int = SequencerLayout.steps,
                             in range: ClosedRange<Int> = 0 ... 127,
                             using generator: inout some RandomNumberGenerator) -> [Int]
    {
        (0 ..< count).map { _ in Int.random(in: range, using: &generator) }
    }

    /// Random on/off flags: each step plays with probability `density` (0…1). Density 1 plays
    /// every step, 0 none, and 0.5 is a fair coin.
    static func randomGates(count: Int = SequencerLayout.steps,
                            density: Double,
                            using generator: inout some RandomNumberGenerator) -> [Int]
    {
        let chance = max(0, min(1, density))
        return (0 ..< count).map { _ in Double.random(in: 0 ..< 1, using: &generator) < chance ? 1 : 0 }
    }

    /// Steps a Mutate of `percent` % touches: that share of the first `length` steps, rounded,
    /// at least one while `percent` > 0, drawn from the steps that are not locked.
    static func mutationSteps(length: Int, percent: Int, locked: Set<Int> = [],
                              using generator: inout some RandomNumberGenerator) -> Set<Int>
    {
        guard percent > 0 else { return [] }
        let free = (0 ..< max(0, length)).filter { !locked.contains($0) }
        let wanted = max(1, Int((Double(free.count) * Double(min(percent, 100)) / 100).rounded()))
        return Set(free.shuffled(using: &generator).prefix(wanted))
    }

    /// Flip the on/off flags at `steps`.
    static func flippedGates(_ gates: [Int], at steps: Set<Int>) -> [Int] {
        gates.enumerated().map { steps.contains($0.offset) ? ($0.element == 0 ? 1 : 0) : $0.element }
    }

    /// Replace the values at `steps` with `replacement()`; the rest stay.
    static func replaced(_ values: [Int], at steps: Set<Int>, with replacement: () -> Int) -> [Int] {
        values.enumerated().map { steps.contains($0.offset) ? replacement() : $0.element }
    }
}

// MARK: - Scales

/// Scales for snapping and generating notes. Intervals in semitones from the root.
public enum MusicalScale: String, CaseIterable, Identifiable, Sendable {
    case chromatic, major, naturalMinor, harmonicMinor, dorian, mixolydian
    case majorPentatonic, minorPentatonic, blues

    public var id: String {
        rawValue
    }

    /// Name shown in the UI — English.
    public var title: String {
        switch self {
        case .chromatic: "Chromatic"
        case .major: "Major"
        case .naturalMinor: "Natural minor"
        case .harmonicMinor: "Harmonic minor"
        case .dorian: "Dorian"
        case .mixolydian: "Mixolydian"
        case .majorPentatonic: "Major pentatonic"
        case .minorPentatonic: "Minor pentatonic"
        case .blues: "Blues"
        }
    }

    public var intervals: [Int] {
        switch self {
        case .chromatic: Array(0 ..< 12)
        case .major: [0, 2, 4, 5, 7, 9, 11]
        case .naturalMinor: [0, 2, 3, 5, 7, 8, 10]
        case .harmonicMinor: [0, 2, 3, 5, 7, 8, 11]
        case .dorian: [0, 2, 3, 5, 7, 9, 10]
        case .mixolydian: [0, 2, 4, 5, 7, 9, 10]
        case .majorPentatonic: [0, 2, 4, 7, 9]
        case .minorPentatonic: [0, 3, 5, 7, 10]
        case .blues: [0, 3, 5, 6, 7, 10]
        }
    }

    /// Is MIDI note `note` in this scale built on `root` (0 = C … 11 = B)?
    public func contains(_ note: Int, root: Int) -> Bool {
        intervals.contains(((note - root) % 12 + 12) % 12)
    }

    /// Nearest note of the scale; on a tie the lower one wins, so snapping is stable.
    public func snapped(_ note: Int, root: Int) -> Int {
        for distance in 0 ... 12 {
            for candidate in [note - distance, note + distance]
                where (0 ... 127).contains(candidate) && contains(candidate, root: root)
            {
                return candidate
            }
        }
        return note
    }

    /// All scale notes inside `range`, ascending.
    public func notes(in range: ClosedRange<Int>, root: Int) -> [Int] {
        range.filter { contains($0, root: root) }
    }
}

// MARK: - Euclidean rhythms

public enum EuclideanRhythm {
    /// `hits` pulses spread as evenly as possible over `steps`, rotated right by `rotation`.
    /// Step *i* plays when `(i · hits) mod steps < hits` — the same answer as Bjorklund's
    /// algorithm up to rotation (E(5,8) starts `x.x.xx.x` here, not `x.xx.xx.`).
    /// Shared with the MCP `write_sequence` tool so both produce identical patterns.
    public static func pattern(hits: Int, steps: Int, rotation: Int = 0) -> [Bool] {
        let steps = max(1, min(SequencerLayout.steps, steps))
        let hits = max(0, min(steps, hits))
        var pattern = (0 ..< steps).map { ($0 * hits) % steps < hits }
        let shift = ((rotation % steps) + steps) % steps
        if shift > 0 {
            pattern = Array(pattern[(steps - shift)...] + pattern[..<(steps - shift)])
        }
        return pattern
    }

    /// Reads a rhythm back from its steps: `hits` and the smallest `rotation` for which
    /// `pattern(hits:steps:rotation:)` gives exactly `gates`; `nil` when the rhythm is not
    /// Euclidean (a step was toggled by hand, or the pattern came from elsewhere).
    public static func recognize(_ gates: [Bool]) -> (hits: Int, rotation: Int)? {
        let steps = gates.count
        guard (1 ... SequencerLayout.steps).contains(steps) else { return nil }
        let hits = gates.filter { $0 }.count
        for rotation in 0 ..< steps where pattern(hits: hits, steps: steps, rotation: rotation) == gates {
            return (hits, rotation)
        }
        return nil
    }

    /// Named presets for the Euclid tab. Names after Toussaint (2005); orientation follows
    /// our formula, see `pattern`.
    public struct Preset: Identifiable, Sendable {
        public let name: String
        public let hits: Int
        public let steps: Int
        public var id: String {
            name
        }
    }

    public static let presets: [Preset] = [
        Preset(name: "Four on the floor", hits: 4, steps: 16),
        Preset(name: "Tresillo", hits: 3, steps: 8),
        Preset(name: "Cinquillo", hits: 5, steps: 8),
        Preset(name: "Bossa nova", hits: 5, steps: 16),
        Preset(name: "Samba", hits: 7, steps: 16),
        Preset(name: "Bell", hits: 7, steps: 12),
        Preset(name: "Aksak", hits: 4, steps: 9),
    ]
}

// MARK: - Sequencers grouped by clock

/// The step sequencers of one patch area, grouped by the module that drives their Clk
/// input — the "All" tab of the Sequence Editor. Input-to-input cable chains are followed
/// back to the real source (`G2SignalGraph`), so sequencers daisy-chained on Clk land in
/// the clock's group.
public struct SequencerClockGroup: Equatable, Sendable {
    /// Module whose output drives Clk; `nil` = no clock (SeqCtr, or Clk not connected).
    public let clockModuleID: Int?
    /// Sequencers in patch order.
    public let sequencerIDs: [Int]

    public init(clockModuleID: Int?, sequencerIDs: [Int]) {
        self.clockModuleID = clockModuleID
        self.sequencerIDs = sequencerIDs
    }

    public static func groups(in patch: G2Patch, area: PatchArea) -> [SequencerClockGroup] {
        let modules = patch.modules(in: area).filter { SequencerLayout.isSequencer(typeID: $0.typeID) }
        guard !modules.isEmpty else { return [] }
        let graph = G2SignalGraph(patch: patch, area: area)
        var order: [Int?] = []
        var members: [Int?: [Int]] = [:]
        for module in modules {
            let clock = clockSource(of: module, graph: graph)
            if members[clock] == nil { order.append(clock) }
            members[clock, default: []].append(module.id)
        }
        // Unclocked sequencers last.
        order.sort { lhs, rhs in lhs != nil && rhs == nil }
        return order.map { SequencerClockGroup(clockModuleID: $0, sequencerIDs: members[$0] ?? []) }
    }

    private static func clockSource(of module: G2Module, graph: G2SignalGraph) -> Int? {
        guard let clk = ModuleDatabase.module(id: module.typeID)?.inputs.firstIndex(where: { $0.name == "Clk" })
        else { return nil }
        return graph.edges.first { $0.toModule == module.id && $0.toInput == clk }?.fromModule
    }
}
