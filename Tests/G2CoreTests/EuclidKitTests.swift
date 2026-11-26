// EuclidKitTests.swift — the grouped Euclid presets and the kits for a group of sequencers.

@testable import G2Core
import XCTest

final class EuclidKitTests: XCTestCase {
    private func hitSteps(_ pattern: [Bool]) -> [Int] {
        pattern.enumerated().filter(\.element).map(\.offset)
    }

    // MARK: Presets

    func testPresetsFitOneModuleAndHaveUniqueNames() {
        let presets = EuclideanRhythm.presets
        XCTAssertGreaterThanOrEqual(presets.count, 20)
        XCTAssertEqual(Set(presets.map(\.name)).count, presets.count)
        for preset in presets {
            XCTAssertTrue((2 ... SequencerLayout.steps).contains(preset.steps), preset.name)
            XCTAssertTrue((1 ... preset.steps).contains(preset.hits), preset.name)
            XCTAssertTrue((0 ..< preset.steps).contains(preset.rotation), preset.name)
        }
    }

    func testTheOriginalSevenPresetsAreStillThere() {
        let expected = [("Four on the floor", 4, 16), ("Tresillo", 3, 8), ("Cinquillo", 5, 8), ("Bossa nova", 5, 16),
                        ("Samba", 7, 16), ("Bell", 7, 12), ("Aksak", 4, 9)]
        for (name, hits, steps) in expected {
            let found = EuclideanRhythm.presets.first { $0.name == name }
            XCTAssertEqual(found?.hits, hits, name)
            XCTAssertEqual(found?.steps, steps, name)
            XCTAssertEqual(found?.rotation, 0, name)
        }
    }

    func testEveryCategoryHasPresetsAndTogetherTheyCoverTheList() {
        var count = 0
        for category in EuclideanRhythm.Category.allCases {
            let list = EuclideanRhythm.presets(in: category)
            XCTAssertFalse(list.isEmpty, category.title)
            count += list.count
        }
        XCTAssertEqual(count, EuclideanRhythm.presets.count)
    }

    func testRotatedPresetsPlayWhereTheNameSays() {
        func steps(_ name: String) -> [Int] {
            let preset = EuclideanRhythm.presets.first { $0.name == name }!
            return hitSteps(EuclideanRhythm.pattern(hits: preset.hits, steps: preset.steps, rotation: preset.rotation))
        }
        XCTAssertEqual(steps("Four on the floor"), [0, 4, 8, 12])
        XCTAssertEqual(steps("Backbeat"), [4, 12])
        XCTAssertEqual(steps("Offbeat hat"), [2, 6, 10, 14])
    }

    // MARK: Kits

    func testEveryKitPartFitsOneModule() {
        XCTAssertGreaterThanOrEqual(EuclidKit.all.count, 6)
        XCTAssertEqual(Set(EuclidKit.all.map(\.name)).count, EuclidKit.all.count)
        for kit in EuclidKit.all {
            XCTAssertGreaterThanOrEqual(kit.parts.count, 3, kit.name)
            for part in kit.parts {
                XCTAssertTrue((1 ... SequencerLayout.steps).contains(part.steps), "\(kit.name) \(part.role)")
                XCTAssertTrue((1 ... part.steps).contains(part.hits), "\(kit.name) \(part.role)")
                let pattern = part.pattern()
                XCTAssertEqual(pattern.count, part.steps)
                XCTAssertEqual(pattern.filter { $0 }.count, part.hits)
            }
        }
    }

    func testHouseKitPlaysKickClapAndOffbeatHat() throws {
        let house = try XCTUnwrap(EuclidKit.all.first { $0.name == "House" })
        XCTAssertEqual(hitSteps(house.parts[0].pattern()), [0, 4, 8, 12])
        XCTAssertEqual(hitSteps(house.parts[1].pattern()), [4, 12])
        XCTAssertEqual(hitSteps(house.parts[2].pattern()), [2, 6, 10, 14])
        XCTAssertEqual(house.summary, "1 kick · 2 clap · 3 offbeat hat · 4 shaker")
    }

    func testAPartAdaptsToTheRowItIsWrittenTo() {
        let clap = EuclidKit.Part("clap", 2, rotation: 4)
        XCTAssertEqual(clap.pattern(steps: 8).count, 8)
        XCTAssertEqual(hitSteps(clap.pattern(steps: 8)), [0, 4]) // E(2,8) rotated 4 wraps inside 8 steps
        // More hits than steps are cut to the length; the steps are kept between 1 and 16.
        let busy = EuclidKit.Part("hat", 11)
        XCTAssertEqual(busy.pattern(steps: 5).filter { $0 }.count, 5)
        XCTAssertEqual(busy.pattern(steps: 99).count, SequencerLayout.steps)
        XCTAssertEqual(busy.pattern(steps: 0).count, 1)
    }

    func testPolymeterKitRepeatsAfterTheLeastCommonMultiple() throws {
        let kit = try XCTUnwrap(EuclidKit.all.first { $0.name.hasPrefix("Polymeter") })
        XCTAssertEqual(kit.parts.map(\.steps), [5, 7, 9, 11])
        func lcm(_ a: Int, _ b: Int) -> Int {
            var (x, y) = (a, b)
            while y != 0 { (x, y) = (y, x % y) }
            return a / x * b
        }
        XCTAssertEqual(kit.parts.map(\.steps).reduce(1, lcm), 3465)
    }
}
