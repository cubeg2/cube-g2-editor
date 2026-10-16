// PatchParserTests.swift
// Tests for the G2 .pch2 parser

@testable import G2Core
import XCTest

final class PatchParserTests: XCTestCase {
    // MARK: - Helpers

    /// Resolve a fixture file from Tests/G2CoreTests/Fixtures/ — works locally and on CI.
    func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .standardized
    }

    func load(_ name: String) throws -> G2Patch {
        let patches = try PatchParser.parse(url: fixtureURL(name))
        return try XCTUnwrap(patches.first, "No patches in file: \(name)")
    }

    // MARK: - Pliki, które patchem nigdy nie były

    /// Zgłoszenie 2026-09-23: w zbiorze użytkownika 116 z 4580 „patchy" to jedna i ta sama
    /// strona HTML forum („nie masz uprawnień do pobrania załącznika"), zapisana pod nazwą
    /// `.pch2` przy masowym ściąganiu. Komunikat mówił wtedy o brakującym „null terminatorze",
    /// czyli o niczym — a wystarczy spojrzeć na początek pliku, żeby nazwać rzecz po imieniu.
    func testHtmlPageSavedAsPatchSaysItIsAWebPage() {
        let html = Data("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\">\n<html><head>".utf8)
        XCTAssertThrowsError(try PatchParser.parse(data: html)) { error in
            XCTAssertTrue("\(error)".contains("web page"), "\(error)")
        }
    }

    /// Plik binarny bez zera i bez znaczników HTML — ogólny komunikat, ale już bez żargonu.
    func testBinaryRubbishSaysThereIsNoPatchHeader() {
        let rubbish = Data(repeating: 0xFF, count: 5000)
        XCTAssertThrowsError(try PatchParser.parse(data: rubbish)) { error in
            XCTAssertTrue("\(error)".contains("no patch header"), "\(error)")
        }
    }

    // MARK: - Basic parse tests

    func testSimpleSynthParsesWithoutError() throws {
        let patch = try load("simplesynth001-20240802.pch2")
        XCTAssertNotNil(patch)
    }

    func testEnvFxParsesWithoutError() throws {
        _ = try load("EnvFx.pch2")
    }

    func testDelayLevelParsesWithoutError() throws {
        _ = try load("DelayLevel.pch2")
    }

    func testRndFilterParsesWithoutError() throws {
        _ = try load("RndFilter.pch2")
    }

    func testManyOscAHasVoiceModules() throws {
        let patch = try load("manyOSCA.pch2")
        XCTAssertGreaterThan(patch.voiceModules.count, 0,
                             "manyOSCA should have voice modules")
    }

    func testSimpleSynthHasVoiceAndCables() throws {
        let patch = try load("simplesynth001-20240802.pch2")
        XCTAssertGreaterThan(patch.voiceModules.count, 0, "Should have voice modules")
        XCTAssertGreaterThan(patch.voiceCables.count, 0, "Should have voice cables")
    }

    func testAllModules1ParsesWithoutError() throws {
        _ = try load("test_all_modules_1.pch2")
    }

    func testAllModules2ParsesWithoutError() throws {
        _ = try load("test_all_modules_2.pch2")
    }

    func test3OscHasModules() throws {
        let patch = try load("test_3osc.pch2")
        // 3 oscillators + at least filter, env, out = >3 modules
        XCTAssertGreaterThan(patch.voiceModules.count, 2)
    }

    func testModuleHasColumnAndRow() throws {
        let patch = try load("EnvFx.pch2")
        let allModules = patch.voiceModules + patch.fxModules
        XCTAssertFalse(allModules.isEmpty, "Should have at least one module")
        // Columns and rows are 7-bit values (0–127)
        for m in allModules {
            XCTAssertGreaterThanOrEqual(m.column, 0)
            XCTAssertLessThanOrEqual(m.column, 127)
            XCTAssertGreaterThanOrEqual(m.row, 0)
            XCTAssertLessThanOrEqual(m.row, 127)
        }
    }

    func testGraphDependenciesPreserveModeReferences() throws {
        let panel = """
        <#Module
          Name:"GraphMode"
          <#Graph
            ID:3
            XPos:10
            YPos:4
            Width:32
            Height:22
            Graph Func:18
            Dependencies:"6,S0,s2"
          #>
        #>
        """

        let moduleUI = try XCTUnwrap(BVerhueParser.parse(text: panel))
        XCTAssertEqual(moduleUI.graphs.first?.dependencies, [6, -1, -3])
    }

    func testCableColorsAreValid() throws {
        let patch = try load("simplesynth001-20240802.pch2")
        let allCables = patch.voiceCables + patch.fxCables
        // All cables should have a valid color (CableColor rawValue 0–7)
        for c in allCables {
            XCTAssertNotNil(CableColor(rawValue: c.color.rawValue))
        }
    }

    // MARK: - All fixtures round-trip test

    func testAllReferencePatches() throws {
        let fixtures = [
            "EnvFx.pch2",
            "DelayLevel.pch2",
            "RndFilter.pch2",
            "LogicMidi.pch2",
            "ioosc.pch2",
            "SwitchSeqNote.pch2",
            "test_3osc.pch2",
            "test_all_modules_1.pch2",
            "test_all_modules_2.pch2",
            "manyOSCA.pch2",
            "simplesynth001-20240802.pch2",
        ]

        var failures = [String]()
        for name in fixtures {
            do {
                _ = try load(name)
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        XCTAssert(failures.isEmpty,
                  "Failed to parse \(failures.count) patch(es):\n" + failures.joined(separator: "\n"))
    }
}
