// MutatorMorphLimitTests.swift
// Limit 25 morfów przy zapisie osobnika do wariacji liczy RÓŻNE PARAMETRY, nie wpisy —
// jak `CopyMorphs` oryginału: wpisy idą w porządku klucza i kopiowanie kończy się na
// pierwszym wpisie, który wprowadziłby 26. parametr → [[Docs/ui/morphs]].

@testable import G2Core
import XCTest

final class MutatorMorphLimitTests: XCTestCase {
    private func patch(parameters: Int) -> G2Patch {
        var module = G2Module(id: 1, typeID: 1, area: .voice)
        module.parameters = Array(repeating: 64, count: parameters)
        module.parameterVariations = Array(repeating: module.parameters, count: 10)
        module.hasParameterEntry = true
        var patch = G2Patch()
        patch.voiceModules = [module]
        return patch
    }

    private func individual(params: Range<Int>, groups: [Int]) -> G2Individual {
        var individual = G2Individual()
        for param in params {
            let key = G2Individual.Key(area: .voice, moduleID: 1, paramIndex: param)
            for group in groups { individual.setMorphRange(key, morph: group, range: 10) }
        }
        return individual
    }

    /// 20 parametrów po dwie grupy = 40 wpisów, ale tylko 20 różnych parametrów — wszystko dozwolone.
    func testEntriesOfFewerThan25ParametersAreAllKept() {
        var target = patch(parameters: 30)

        target.apply(individual(params: 0 ..< 20, groups: [0, 1]), variation: 2)

        XCTAssertEqual(target.morphAssignments[2].count, 40)
        XCTAssertEqual(Set(target.morphAssignments[2].map(\.paramIndex)).count, 20)
    }

    /// 30 parametrów po jednej grupie: zostaje pierwszych 25 parametrów, reszta przepada.
    func testMoreThan25ParametersAreCutAtThe26th() {
        var target = patch(parameters: 30)

        target.apply(individual(params: 0 ..< 30, groups: [0]), variation: 0)

        XCTAssertEqual(target.morphAssignments[0].count, 25)
        XCTAssertEqual(target.morphAssignments[0].map(\.paramIndex), Array(0 ..< 25))
    }

    /// 26 parametrów po dwie grupy: pierwsze 25 parametrów zachowuje OBA wpisy (50), 26. znika w całości.
    func testKeptParametersKeepAllTheirGroups() {
        var target = patch(parameters: 30)
        var source = individual(params: 0 ..< 25, groups: [0, 3])
        source.setMorphRange(G2Individual.Key(area: .voice, moduleID: 1, paramIndex: 25), morph: 0, range: 10)

        target.apply(source, variation: 1)

        XCTAssertEqual(target.morphAssignments[1].count, 50)
        XCTAssertFalse(target.morphAssignments[1].contains { $0.paramIndex == 25 })
    }

    /// Dokładnie 25 różnych parametrów przechodzi bez zmian.
    func testExactly25ParametersPass() {
        var target = patch(parameters: 30)

        target.apply(individual(params: 0 ..< 25, groups: [0, 1, 2]), variation: 0)

        XCTAssertEqual(target.morphAssignments[0].count, 75)
    }
}
