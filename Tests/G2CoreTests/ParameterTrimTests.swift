// ParameterTrimTests.swift
// #157: plik z najstarszego OS-u ma FreqShift z 5 parametrami, a Nord 1.62 zna 4.
// Wysłany bez zmian zawieszał Norda (3 próby, 3 zawieszenia). Oryginalny edytor buduje
// patch do wysyłki z definicji modułu, więc nadmiarowy parametr nigdy nie wychodzi.

@testable import G2Core
import XCTest

final class ParameterTrimTests: XCTestCase {
    private func module(typeID: Int, id: Int, values: Int) -> G2Module {
        var module = G2Module(id: id, typeID: typeID, area: .voice)
        module.parameters = Array(repeating: 64, count: values)
        module.parameterVariations = Array(repeating: module.parameters, count: 9)
        module.hasParameterEntry = true
        return module
    }

    func testExtraParametersAreDroppedAndTheRestIsKept() throws {
        let definition = try XCTUnwrap(ModuleDatabase.module(id: 98))
        XCTAssertEqual(definition.paramNames.count, 4, "FreqShift Nord 1.62")
        var patch = G2Patch()
        patch.voiceModules = [module(typeID: 98, id: 13, values: 5), module(typeID: 98, id: 14, values: 3)]
        patch.voiceModules[0].parameters[3] = 7

        let trimmed = patch.trimmedToModuleDefinitions()

        XCTAssertEqual(trimmed.voiceModules[0].parameters, [64, 64, 64, 7])
        XCTAssertTrue(trimmed.voiceModules[0].parameterVariations.allSatisfy { $0.count == 4 })
        XCTAssertEqual(trimmed.voiceModules[1], patch.voiceModules[1], "brakujących wartości nie dopisujemy")
        XCTAssertEqual(patch.voiceModules[0].parameters.count, 5, "model edytora zostaje nietknięty")
    }

    /// Strumień do Norda ma mieć 4 parametry — sprawdzone po ponownym odczycie zapisu.
    func testSavedStreamCarriesTheDefinitionCount() throws {
        var patch = G2Patch()
        patch.voiceModules = [module(typeID: 98, id: 1, values: 5)]

        let data = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile,
                                           patches: [patch.trimmedToModuleDefinitions()])

        let reread = try XCTUnwrap(try PatchParser.parse(data: data).first)
        XCTAssertEqual(reread.voiceModules.first?.parameters.count, 4)
    }
}
