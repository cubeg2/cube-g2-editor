// PatchValidatorTests.swift
// Kontrola strukturalna patcha — każdy rodzaj znaleziska ma tu przypadek,
// który go wywołuje, oraz przypadek czysty, który nie może go wywołać.

@testable import G2Core
import XCTest

final class PatchValidatorTests: XCTestCase {
    // OscB: 5 wejść, 1 wyjście. 2-Out: 2 wejścia, 0 wyjść.
    private let oscB = 7
    private let out2 = 4

    /// Moduł z kompletem parametrów i trybów, żeby czysty patch był naprawdę czysty.
    private func module(_ id: Int, type: Int, area: PatchArea = .voice) throws -> G2Module {
        let def = try XCTUnwrap(ModuleDatabase.module(id: type), "brak typu \(type) w bazie modułów")
        var module = G2Module(id: id, typeID: type, area: area)
        module.parameters = Array(repeating: 0, count: def.paramNames.count)
        module.modes = Array(repeating: 0, count: def.modeNames.count)
        return module
    }

    /// OscB (id 1) → 2-Out (id 2), zwykły kabel wyjście→wejście.
    private func cleanPatch() throws -> G2Patch {
        var patch = G2Patch()
        try patch.add(module: module(1, type: oscB))
        try patch.add(module: module(2, type: out2))
        patch.add(cable: G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 0,
                                 color: .red, area: .voice, sourceIsOutput: true))
        return patch
    }

    private func kinds(_ patch: G2Patch) -> [PatchIssueKind] {
        PatchValidator.issues(in: patch).map(\.kind)
    }

    func testCleanPatchHasNoIssues() throws {
        XCTAssertEqual(try PatchValidator.issues(in: cleanPatch()), [])
    }

    func testCableToMissingModuleIsReported() throws {
        var patch = try cleanPatch()
        patch.add(cable: G2Cable(fromModule: 1, fromConnector: 0, toModule: 99, toConnector: 0,
                                 color: .red, area: .voice, sourceIsOutput: true))
        XCTAssertEqual(kinds(patch), [.cableToMissingModule])
    }

    /// Dokładnie ten przypadek psuł się do 2026-09-03: kabel wychodzący z wejścia,
    /// zapisany jako „wyjście→wejście". Konektor 3 istnieje w OscB jako wejście,
    /// ale nie jako wyjście (jest tylko jedno) — czyli bit kierunku ma złą wartość
    /// i naprawa jest jednoznaczna.
    func testWrongLinkTypeIsReported() throws {
        var patch = try cleanPatch()
        patch.add(cable: G2Cable(fromModule: 1, fromConnector: 3, toModule: 2, toConnector: 1,
                                 color: .red, area: .voice, sourceIsOutput: true))
        XCTAssertEqual(kinds(patch), [.cableLinkTypeContradictsModule])
    }

    /// Ten sam kabel z poprawnym bitem kierunku jest legalny — Nord pozwala wpiąć
    /// kabel z jednego wejścia w drugie.
    func testInputToInputCableIsAccepted() throws {
        var patch = try cleanPatch()
        patch.add(cable: G2Cable(fromModule: 1, fromConnector: 3, toModule: 2, toConnector: 1,
                                 color: .red, area: .voice, sourceIsOutput: false))
        XCTAssertEqual(PatchValidator.issues(in: patch), [])
    }

    func testConnectorOutOfRangeIsReported() throws {
        var patch = try cleanPatch()
        // 9 nie istnieje w OscB ani jako wejście (5), ani jako wyjście (1).
        patch.add(cable: G2Cable(fromModule: 1, fromConnector: 9, toModule: 2, toConnector: 0,
                                 color: .red, area: .voice, sourceIsOutput: true))
        XCTAssertEqual(kinds(patch), [.cableConnectorOutOfRange])
    }

    func testDuplicateCableIsReported() throws {
        var patch = try cleanPatch()
        patch.add(cable: G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 0,
                                 color: .blue, area: .voice, sourceIsOutput: true))
        XCTAssertEqual(kinds(patch), [.duplicateCable])
    }

    func testDuplicateModuleIDIsReported() throws {
        var patch = try cleanPatch()
        try patch.add(module: module(2, type: out2))
        XCTAssertEqual(kinds(patch), [.duplicateModuleID])
    }

    func testUnknownModuleTypeIsReported() throws {
        var patch = try cleanPatch()
        patch.add(module: G2Module(id: 3, typeID: 250, area: .voice))
        XCTAssertEqual(kinds(patch), [.unknownModuleType])
    }

    func testMissingParametersAreReported() throws {
        var patch = try cleanPatch()
        patch.voiceModules[0].parameters = []
        XCTAssertEqual(kinds(patch), [.parametersMissing])
    }

    /// Znaleziska z obszaru FX nie mogą wyciekać do obszaru Voice i odwrotnie.
    func testIssueCarriesItsArea() throws {
        var patch = try cleanPatch()
        patch.add(cable: G2Cable(fromModule: 1, fromConnector: 0, toModule: 99, toConnector: 0,
                                 color: .red, area: .fx, sourceIsOutput: true))
        let issues = PatchValidator.issues(in: patch)
        // Obszar FX jest pusty, więc OBA końce kabla wskazują nieistniejące moduły —
        // przy okazji dowód, że sprawdzamy koniec źródłowy i docelowy osobno.
        XCTAssertEqual(issues.map(\.kind), [.cableToMissingModule, .cableToMissingModule])
        XCTAssertTrue(issues.allSatisfy { $0.area == .fx }, "znalezisko trafiło do złego obszaru")
    }
}
