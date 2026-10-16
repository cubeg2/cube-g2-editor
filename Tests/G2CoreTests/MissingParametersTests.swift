// MissingParametersTests.swift
// Plik bez wartości parametrów modułu (w kolekcji: „Very Saxy", cała warstwa FX) —
// edytor ma pokazać i wysłać wartości domyślne, a nie zera.

@testable import G2Core
import XCTest

final class MissingParametersTests: XCTestCase {
    private let out2 = 4 // 2-Out: Destination, Active, Pad

    func testModuleWithoutParametersGetsTypeDefaults() throws {
        var patch = G2Patch()
        patch.add(module: G2Module(id: 3, typeID: out2, area: .fx))

        patch.fillMissingParameters()

        let module = try XCTUnwrap(patch.fxModules.first)
        XCTAssertEqual(module.parameters, ModuleDefaultsDatabase.defaults(forTypeID: out2))
        XCTAssertEqual(module.parameters[1], 1, "Active musi być włączony, inaczej warstwa milczy")
        XCTAssertEqual(module.parameterVariations.count, G2Patch.runtimeVariationCount)
        XCTAssertTrue(module.parameterVariations.allSatisfy { $0 == module.parameters })
    }

    func testValuesFromTheFileAreLeftAlone() throws {
        var module = G2Module(id: 1, typeID: out2, area: .voice)
        module.parameters = [2, 0, 3]
        module.parameterVariations = [[2, 0, 3]]
        var patch = G2Patch()
        patch.add(module: module)

        patch.fillMissingParameters()

        let kept = try XCTUnwrap(patch.voiceModules.first)
        XCTAssertEqual(kept.parameters, [2, 0, 3])
        XCTAssertEqual(kept.parameterVariations, [[2, 0, 3]])
    }

    func testModuleTypeWithoutParametersStaysEmpty() throws {
        let typeID = try XCTUnwrap(ModuleDatabase.all.first { $0.paramNames.isEmpty }).id
        var patch = G2Patch()
        patch.add(module: G2Module(id: 1, typeID: typeID, area: .voice))

        patch.fillMissingParameters()

        XCTAssertEqual(patch.voiceModules.first?.parameters, [])
    }
}
