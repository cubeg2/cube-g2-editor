// SequenceUserLibrary.swift
// The user's own patterns for the Sequence Editor's Presets ▸ My patterns menu. One library file
// next to the app's settings; three separate lists — notes (SeqNote), rhythms (SeqEvent) and curves
// (SeqVal / SeqLev / SeqCtr) — so each sequencer only sees patterns that make sense for it.
//
// A pattern is what the module itself holds: row 1 values, row 2 on/off flags and the Length. Loading
// one writes ordinary parameters, so it is one undo step like every other operation of the window.
// → [[Docs/roadmap]] "Sequence Editor — presety"

import Foundation

public struct SequenceUserPattern: Codable, Equatable, Identifiable, Sendable {
    /// Which sequencers can use a pattern.
    public enum Category: String, Codable, CaseIterable, Sendable {
        case notes, rhythms, curves

        public init(kind: SequencerLayout.Kind) {
            switch kind {
            case .note: self = .notes
            case .event: self = .rhythms
            case .value, .controlled: self = .curves
            }
        }

        /// Name for menus — English.
        public var title: String {
            switch self {
            case .notes: "note"
            case .rhythms: "rhythm"
            case .curves: "curve"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var category: Category
    /// Row 1: notes / values 0…127, or the on/off flags of Row 1 on a SeqEvent.
    public var values: [Int]
    /// Row 2: on/off flags (0 / 1).
    public var gates: [Int]
    /// Steps played (1…16); `nil` when the module has no Length (SeqCtr).
    public var length: Int?
}

public struct SequenceUserLibrary: Codable, Equatable, Sendable {
    public private(set) var patterns: [SequenceUserPattern]

    public static let maxNameLength = 40

    public init(patterns: [SequenceUserPattern] = []) {
        self.patterns = patterns
    }

    /// The patterns of one category, by name.
    public func patterns(in category: SequenceUserPattern.Category) -> [SequenceUserPattern] {
        patterns.filter { $0.category == category }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Saves a pattern. The name is trimmed and cut to `maxNameLength`; an empty name saves nothing.
    /// A pattern of the same name in the same category is replaced (it keeps its id).
    @discardableResult
    public mutating func save(name: String, category: SequenceUserPattern.Category,
                              values: [Int], gates: [Int], length: Int?) -> SequenceUserPattern?
    {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
        guard !name.isEmpty else { return nil }
        let steps = SequencerLayout.steps
        let pattern = SequenceUserPattern(
            id: patterns.first { $0.category == category && $0.name == name }?.id ?? UUID(),
            name: name, category: category,
            values: Self.fit(values, count: steps, range: 0 ... 127),
            gates: Self.fit(gates, count: steps, range: 0 ... 1),
            length: length.map { max(1, min(steps, $0)) }
        )
        if let index = patterns.firstIndex(where: { $0.id == pattern.id }) {
            patterns[index] = pattern
        } else {
            patterns.append(pattern)
        }
        return pattern
    }

    public mutating func remove(id: UUID) {
        patterns.removeAll { $0.id == id }
    }

    /// Exactly `count` values inside `range`: missing steps read as 0, extra ones are dropped.
    private static func fit(_ values: [Int], count: Int, range: ClosedRange<Int>) -> [Int] {
        (0 ..< count).map { index in
            index < values.count ? max(range.lowerBound, min(range.upperBound, values[index])) : 0
        }
    }

    // MARK: File

    /// `…/Application Support/G2Editor/SequencePatterns.json`.
    public static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("G2Editor", isDirectory: true)
            .appendingPathComponent("SequencePatterns.json")
    }

    /// Reads the library; a missing or damaged file gives an empty one, and entries that cannot be
    /// read (no name, wrong size) are dropped rather than failing the whole file.
    public static func load(from url: URL? = defaultURL) -> SequenceUserLibrary {
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SequenceUserLibrary.self, from: data)
        else { return SequenceUserLibrary() }
        var library = SequenceUserLibrary()
        for pattern in file.patterns {
            guard let saved = library.save(name: pattern.name, category: pattern.category, values: pattern.values,
                                           gates: pattern.gates, length: pattern.length),
                let index = library.patterns.firstIndex(where: { $0.id == saved.id })
            else { continue }
            library.patterns[index].id = pattern.id
        }
        return library
    }

    public func write(to url: URL? = defaultURL) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
