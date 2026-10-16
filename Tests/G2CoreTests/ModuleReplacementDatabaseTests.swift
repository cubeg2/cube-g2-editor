@testable import G2Core
import XCTest

final class ModuleReplacementDatabaseTests: XCTestCase {
    func testCandidatesKeepClaviaReplacementOrder() {
        XCTAssertEqual(ModuleReplacementDatabase.candidates(for: 4), [4, 3])
        XCTAssertEqual(ModuleReplacementDatabase.candidates(for: 170), [170, 171, 127])
        XCTAssertTrue(ModuleReplacementDatabase.candidates(for: 126).isEmpty)
    }

    func testTwoOutputToFourOutputMapsBothConnectedInputs() throws {
        let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
            from: 4,
            to: 3,
            connectedInputs: [0, 1],
            connectedOutputs: []
        ))

        XCTAssertEqual(plan.inputMap, [0: 0, 1: 1])
        XCTAssertEqual(plan.parameterMap[1], 1)
        XCTAssertEqual(plan.parameterMap[2], 2)
        XCTAssertNil(plan.parameterMap[0])
    }

    func testPatchReplacementPreservesStateAndDropsOnlyUnmappedCables() throws {
        var patch = G2Patch()
        var source = G2Module(id: 1, typeID: 3, area: .voice)
        source.column = 2
        source.row = 4
        source.color = 7
        source.uprate = true
        source.leds = true
        source.label = "Main out"
        source.parameters = [12, 34, 56]
        source.parameterVariations = (0 ..< 9).map { [12 + $0, 34 + $0, 56 + $0] }

        let provider = G2Module(id: 2, typeID: 1, area: .voice)
        patch.voiceModules = [source, provider]
        patch.voiceCables = (0 ..< 4).map { connector in
            G2Cable(
                fromModule: 2,
                fromConnector: connector,
                toModule: 1,
                toConnector: connector,
                color: .red,
                area: .voice
            )
        }

        XCTAssertTrue(patch.replaceModule(moduleID: 1, with: 4, in: .voice))
        let replacement = try XCTUnwrap(patch.voiceModules.first { $0.id == 1 })

        XCTAssertEqual(replacement.typeID, 4)
        XCTAssertEqual(replacement.column, 2)
        XCTAssertEqual(replacement.row, 4)
        XCTAssertEqual(replacement.color, 7)
        XCTAssertTrue(replacement.uprate)
        XCTAssertTrue(replacement.leds)
        XCTAssertEqual(replacement.label, "Main out")
        XCTAssertEqual(replacement.parameters, [0, 34, 56])
        XCTAssertEqual(replacement.parameterVariations[8], [0, 42, 64])
        XCTAssertEqual(patch.voiceCables.map(\.toConnector).sorted(), [0, 1])
        XCTAssertTrue(patch.voiceCables.allSatisfy { $0.fromModule == 2 && $0.toModule == 1 })
    }

    func testReplacementOutsideClaviaGroupIsRejectedWithoutMutation() {
        var patch = G2Patch()
        patch.voiceModules = [G2Module(id: 1, typeID: 4, area: .voice)]
        let original = patch.voiceModules

        XCTAssertFalse(patch.replaceModule(moduleID: 1, with: 7, in: .voice))
        XCTAssertEqual(patch.voiceModules.map(\.typeID), original.map(\.typeID))
    }

    func testEveryClaviaPairProducesMappingsInsideTargetDefinition() throws {
        for source in ModuleDatabase.all {
            let candidates = ModuleReplacementDatabase.candidates(for: source.id)
            for targetTypeID in candidates where targetTypeID != source.id {
                let target = try XCTUnwrap(ModuleDatabase.module(id: targetTypeID))
                let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
                    from: source.id,
                    to: targetTypeID,
                    connectedInputs: Set(source.inputs.indices),
                    connectedOutputs: Set(source.outputs.indices)
                ))

                XCTAssertTrue(plan.parameterMap.keys.allSatisfy(source.paramNames.indices.contains))
                XCTAssertTrue(plan.parameterMap.values.allSatisfy(target.paramNames.indices.contains))
                XCTAssertTrue(plan.inputMap.keys.allSatisfy(source.inputs.indices.contains))
                XCTAssertTrue(plan.inputMap.values.allSatisfy(target.inputs.indices.contains))
                XCTAssertTrue(plan.outputMap.keys.allSatisfy(source.outputs.indices.contains))
                XCTAssertTrue(plan.outputMap.values.allSatisfy(target.outputs.indices.contains))
            }
        }
    }
}
