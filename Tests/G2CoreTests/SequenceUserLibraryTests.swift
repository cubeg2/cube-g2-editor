// SequenceUserLibraryTests.swift — the user's own patterns of the Sequence Editor (Presets ▸ My patterns).

@testable import G2Core
import XCTest

final class SequenceUserLibraryTests: XCTestCase {
    private let notes = Array(repeating: 60, count: 16)
    private let gates = (0 ..< 16).map { $0 % 2 }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SequenceUserLibraryTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("SequencePatterns.json")
    }

    func testCategoryFollowsTheSequencerKind() {
        XCTAssertEqual(SequenceUserPattern.Category(kind: .note), .notes)
        XCTAssertEqual(SequenceUserPattern.Category(kind: .event), .rhythms)
        XCTAssertEqual(SequenceUserPattern.Category(kind: .value), .curves)
        XCTAssertEqual(SequenceUserPattern.Category(kind: .controlled), .curves)
    }

    func testSaveTrimsTheNameAndRefusesAnEmptyOne() {
        var library = SequenceUserLibrary()
        XCTAssertEqual(library.save(name: "  Bassline \n", category: .notes, values: notes, gates: gates, length: 16)?.name,
                       "Bassline")
        XCTAssertNil(library.save(name: "   ", category: .notes, values: notes, gates: gates, length: 16))
        XCTAssertEqual(library.patterns.count, 1)
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(library.save(name: long, category: .notes, values: notes, gates: gates, length: 16)?.name.count,
                       SequenceUserLibrary.maxNameLength)
    }

    func testSameNameInTheSameCategoryReplacesAndKeepsTheId() {
        var library = SequenceUserLibrary()
        let first = library.save(name: "A", category: .notes, values: notes, gates: gates, length: 16)
        let second = library.save(name: "A", category: .notes, values: Array(repeating: 50, count: 16),
                                  gates: gates, length: 8)
        XCTAssertEqual(library.patterns.count, 1)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(library.patterns[0].length, 8)
        // The same name in another category is a different pattern.
        library.save(name: "A", category: .rhythms, values: gates, gates: gates, length: 16)
        XCTAssertEqual(library.patterns.count, 2)
    }

    func testCategoriesAreSeparateAndSortedByName() {
        var library = SequenceUserLibrary()
        library.save(name: "zeta", category: .notes, values: notes, gates: gates, length: 16)
        library.save(name: "Alpha", category: .notes, values: notes, gates: gates, length: 16)
        library.save(name: "Beat", category: .rhythms, values: gates, gates: gates, length: 16)
        XCTAssertEqual(library.patterns(in: .notes).map(\.name), ["Alpha", "zeta"])
        XCTAssertEqual(library.patterns(in: .rhythms).map(\.name), ["Beat"])
        XCTAssertTrue(library.patterns(in: .curves).isEmpty)
    }

    func testSavedValuesAreFittedToSixteenStepsInsideTheirRange() {
        var library = SequenceUserLibrary()
        let saved = library.save(name: "Odd", category: .curves, values: [500, -20] + Array(repeating: 9, count: 20),
                                 gates: [3, 0, 1], length: 99)
        XCTAssertEqual(saved?.values.count, 16)
        XCTAssertEqual(saved?.values.prefix(3), [127, 0, 9])
        XCTAssertEqual(saved?.gates.count, 16)
        XCTAssertEqual(saved?.gates.prefix(4), [1, 0, 1, 0])
        XCTAssertEqual(saved?.length, 16)
    }

    func testRemove() throws {
        var library = SequenceUserLibrary()
        let kept = library.save(name: "Keep", category: .notes, values: notes, gates: gates, length: nil)
        let gone = library.save(name: "Gone", category: .notes, values: notes, gates: gates, length: nil)
        try library.remove(id: XCTUnwrap(gone?.id))
        XCTAssertEqual(library.patterns.map(\.id), try [XCTUnwrap(kept?.id)])
        XCTAssertNil(library.patterns[0].length)
    }

    func testWriteAndLoadRoundTripKeepsEverythingIncludingIds() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var library = SequenceUserLibrary()
        library.save(name: "Acid", category: .notes, values: (0 ..< 16).map { 40 + $0 }, gates: gates, length: 12)
        library.save(name: "Kick", category: .rhythms, values: gates, gates: gates, length: 16)
        library.save(name: "Ramp", category: .curves, values: (0 ..< 16).map { $0 * 8 }, gates: gates, length: nil)
        try library.write(to: url)
        XCTAssertEqual(SequenceUserLibrary.load(from: url), library)
    }

    func testMissingOrDamagedFileGivesAnEmptyLibrary() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(SequenceUserLibrary.load(from: url), SequenceUserLibrary())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(SequenceUserLibrary.load(from: url), SequenceUserLibrary())
    }

    func testLoadDropsEntriesWithoutAName() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let good = SequenceUserPattern(id: UUID(), name: "Good", category: .notes, values: notes, gates: gates, length: 16)
        var bad = good
        bad.id = UUID()
        bad.name = "  "
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(SequenceUserLibrary(patterns: [bad, good])).write(to: url)
        XCTAssertEqual(SequenceUserLibrary.load(from: url).patterns.map(\.name), ["Good"])
    }
}
