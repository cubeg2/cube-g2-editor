// ModuleReplacementBaselineTests.swift
//
// Characterisation ("golden") tests for module replacement.
//
// Purpose: freeze the behaviour a user can actually observe - which modules may
// replace which, and where cables and knob values end up after a swap - so that
// the tables behind that behaviour can be rebuilt without silently changing what
// the editor does. The baseline file is the oracle: a behavioural regression shows
// up as a line-by-line diff instead of a vague "something moved".
//
// The baseline deliberately records outcomes, not table contents. It stays valid
// across a rewrite of the underlying data, which is the whole point of having it.
//
// Regenerating is a deliberate act, never a way to silence a failing test. Review
// the resulting diff and explain every changed line:
//
//   G2_REGEN_REPLACEMENT_BASELINE=1 swift test --filter ModuleReplacementBaseline
//
// Companion file: Fixtures/module-replacement-baseline.txt

@testable import G2Core
import XCTest

final class ModuleReplacementBaselineTests: XCTestCase {
    // MARK: - Scenarios

    /// Cable patterns worth pinning. Replacement consumes mapping candidates
    /// greedily, so a half-patched module can map differently from a fully
    /// patched one; both cases are therefore recorded.
    private enum Scenario: String, CaseIterable {
        /// Nothing patched: only knob values can carry over.
        case bare
        /// Only the first input patched: catches greedy consumption order.
        case firstInput = "in0"
        /// Everything patched: the maximal mapping.
        case full

        func inputs(_ module: ModuleDef) -> Set<Int> {
            switch self {
            case .bare: []
            case .firstInput: module.inputs.isEmpty ? [] : [0]
            case .full: Set(module.inputs.indices)
            }
        }

        func outputs(_ module: ModuleDef) -> Set<Int> {
            switch self {
            case .bare, .firstInput: []
            case .full: Set(module.outputs.indices)
            }
        }
    }

    // MARK: - Baseline rendering

    private static func render() -> String {
        var lines = [
            "# module-replacement baseline v1",
            "#",
            "# Observable behaviour of module replacement, produced by",
            "# Tests/G2CoreTests/ModuleReplacementBaselineTests.swift.",
            "# Records outcomes only, so it survives a rewrite of the tables that",
            "# produce them. Regenerate with G2_REGEN_REPLACEMENT_BASELINE=1.",
            "#",
            "# [candidates] typeID: replacement offers, in menu order",
            "# [plans]      source>target scenario P source=target I ... O ...",
            "#              P knob values, I cable inputs, O cable outputs.",
            "#              A dash means the swap is refused.",
            "",
            "[candidates]",
        ]

        let offered = ModuleDatabase.all
            .map { ($0.id, ModuleReplacementDatabase.candidates(for: $0.id)) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.0 < $1.0 }
        for (typeID, candidates) in offered {
            lines.append("\(typeID): \(candidates.map(String.init).joined(separator: ","))")
        }

        lines.append("")
        lines.append("[plans]")
        for (typeID, candidates) in offered {
            guard let source = ModuleDatabase.module(id: typeID) else { continue }
            for target in candidates.sorted() where target != typeID {
                for scenario in Scenario.allCases {
                    let plan = ModuleReplacementDatabase.plan(
                        from: typeID,
                        to: target,
                        connectedInputs: scenario.inputs(source),
                        connectedOutputs: scenario.outputs(source)
                    )
                    let head = "\(typeID)>\(target) \(scenario.rawValue)"
                    guard let plan else {
                        lines.append("\(head) -")
                        continue
                    }
                    lines.append(
                        head
                            + " P " + describe(plan.parameterMap)
                            + " I " + describe(plan.inputMap)
                            + " O " + describe(plan.outputMap)
                    )
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func describe(_ map: [Int: Int]) -> String {
        map.isEmpty
            ? "."
            : map.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }

    private static var baselineURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("module-replacement-baseline.txt")
            .standardized
    }

    // MARK: - The golden test

    func testBehaviourMatchesRecordedBaseline() throws {
        let produced = Self.render()
        let url = Self.baselineURL

        if ProcessInfo.processInfo.environment["G2_REGEN_REPLACEMENT_BASELINE"] == "1" {
            try produced.write(to: url, atomically: true, encoding: .utf8)
            print("baseline rewritten: \(url.path)")
            return
        }

        let recorded = try String(contentsOf: url, encoding: .utf8)
        guard recorded != produced else { return }

        // Report the first few differing lines rather than dumping both files.
        let old = recorded.split(separator: "\n", omittingEmptySubsequences: false)
        let new = produced.split(separator: "\n", omittingEmptySubsequences: false)
        var reported = 0
        for index in 0 ..< max(old.count, new.count) where reported < 12 {
            let before = index < old.count ? String(old[index]) : "<missing>"
            let after = index < new.count ? String(new[index]) : "<missing>"
            if before != after {
                XCTFail("line \(index + 1)\n  recorded: \(before)\n  produced: \(after)")
                reported += 1
            }
        }
        XCTAssertEqual(old.count, new.count, "baseline line count changed")
    }

    // MARK: - Behavioural invariants

    //
    // These hold for any correct implementation. They describe what replacement
    // means, so a rewrite that satisfies them is behaving sanely even before the
    // baseline diff is consulted.

    func testReplacementOffersAreMutual() {
        for module in ModuleDatabase.all {
            let candidates = ModuleReplacementDatabase.candidates(for: module.id)
            guard !candidates.isEmpty else { continue }
            XCTAssertTrue(
                candidates.contains(module.id),
                "module \(module.id) is missing from its own replacement offers"
            )
            for other in candidates {
                XCTAssertEqual(
                    Set(ModuleReplacementDatabase.candidates(for: other)),
                    Set(candidates),
                    "replacement offers of \(module.id) and \(other) disagree"
                )
            }
        }
    }

    func testPlanExistsExactlyWhenTypesAreInterchangeable() {
        let ids = ModuleDatabase.all.map(\.id)
        for source in ids {
            let interchangeable = Set(ModuleReplacementDatabase.candidates(for: source))
            for target in ids where target != source {
                let plan = ModuleReplacementDatabase.plan(
                    from: source,
                    to: target,
                    connectedInputs: [],
                    connectedOutputs: []
                )
                XCTAssertEqual(
                    plan != nil,
                    interchangeable.contains(target),
                    "\(source) -> \(target): offer and plan disagree"
                )
            }
        }
    }

    /// A cable has exactly one end, so two of them may never be routed to the
    /// same socket. Knobs are different: folding a mono pair into one stereo
    /// channel deliberately sends two source knobs to one target knob, so no such
    /// rule applies to `parameterMap`.
    func testNoTwoCablesLandInTheSameSocket() throws {
        for source in ModuleDatabase.all {
            for target in ModuleReplacementDatabase.candidates(for: source.id)
                where target != source.id
            {
                let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
                    from: source.id,
                    to: target,
                    connectedInputs: Set(source.inputs.indices),
                    connectedOutputs: Set(source.outputs.indices)
                ))
                assertInjective(plan.inputMap, "\(source.id)>\(target) inputs")
                assertInjective(plan.outputMap, "\(source.id)>\(target) outputs")
            }
        }
    }

    /// When several source knobs share a target knob - the mono-into-stereo case -
    /// the surviving value must not depend on dictionary iteration order.
    func testKnobFoldingPicksTheSameValueEveryTime() throws {
        for source in ModuleDatabase.all {
            for target in ModuleReplacementDatabase.candidates(for: source.id)
                where target != source.id
            {
                let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
                    from: source.id, to: target,
                    connectedInputs: Set(source.inputs.indices),
                    connectedOutputs: Set(source.outputs.indices)
                ))
                let folded = Dictionary(grouping: plan.parameterMap, by: \.value)
                    .filter { $0.value.count > 1 }
                guard !folded.isEmpty else { continue }

                var patch = G2Patch()
                var module = G2Module(id: 1, typeID: source.id, area: .voice)
                module.parameters = source.paramNames.indices.map { 10 + $0 }
                module.parameterVariations = Array(repeating: module.parameters, count: 9)
                patch.voiceModules = [module]

                var results: Set<[Int]> = []
                for _ in 0 ..< 8 {
                    var attempt = patch
                    XCTAssertTrue(attempt.replaceModule(moduleID: 1, with: target, in: .voice))
                    results.insert(attempt.voiceModules[0].parameters)
                }
                XCTAssertEqual(
                    results.count, 1,
                    "\(source.shortName)>\(target): folded knobs settled on \(results.count) different results"
                )
            }
        }
    }

    func testMappedCablesKeepTheirSignalKind() throws {
        for source in ModuleDatabase.all {
            for targetID in ModuleReplacementDatabase.candidates(for: source.id)
                where targetID != source.id
            {
                let target = try XCTUnwrap(ModuleDatabase.module(id: targetID))
                let plan = try XCTUnwrap(ModuleReplacementDatabase.plan(
                    from: source.id,
                    to: targetID,
                    connectedInputs: Set(source.inputs.indices),
                    connectedOutputs: Set(source.outputs.indices)
                ))
                for (from, to) in plan.inputMap {
                    assertCompatible(
                        source.inputs[from], target.inputs[to],
                        "\(source.shortName)>\(target.shortName) input \(from)"
                    )
                }
                for (from, to) in plan.outputMap {
                    assertCompatible(
                        source.outputs[from], target.outputs[to],
                        "\(source.shortName)>\(target.shortName) output \(from)"
                    )
                }
            }
        }
    }

    func testPlanningIsDeterministic() {
        for source in ModuleDatabase.all {
            for target in ModuleReplacementDatabase.candidates(for: source.id)
                where target != source.id
            {
                let connected = Set(source.inputs.indices)
                let first = ModuleReplacementDatabase.plan(
                    from: source.id, to: target,
                    connectedInputs: connected, connectedOutputs: []
                )
                let second = ModuleReplacementDatabase.plan(
                    from: source.id, to: target,
                    connectedInputs: connected, connectedOutputs: []
                )
                XCTAssertEqual(first, second, "\(source.id)>\(target) planned differently twice")
            }
        }
    }

    /// Patching more cables must not take away a mapping that a sparser patch had.
    func testPatchingMoreCablesNeverRemovesAnExistingMapping() throws {
        for source in ModuleDatabase.all where !source.inputs.isEmpty {
            for target in ModuleReplacementDatabase.candidates(for: source.id)
                where target != source.id
            {
                let sparse = try XCTUnwrap(ModuleReplacementDatabase.plan(
                    from: source.id, to: target,
                    connectedInputs: [0], connectedOutputs: []
                ))
                let full = try XCTUnwrap(ModuleReplacementDatabase.plan(
                    from: source.id, to: target,
                    connectedInputs: Set(source.inputs.indices),
                    connectedOutputs: Set(source.outputs.indices)
                ))
                for (from, to) in sparse.inputMap {
                    XCTAssertEqual(
                        full.inputMap[from], to,
                        "\(source.id)>\(target): input \(from) moved once more cables were patched"
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func assertInjective(_ map: [Int: Int], _ label: String) {
        XCTAssertEqual(
            Set(map.values).count, map.count,
            "\(label): two sources map onto the same target"
        )
    }

    /// A cable may move to a socket of a different colour - the G2 accepts a logic
    /// signal on a red input, and `OscPerc.Trig` is red where `DrumSynth.Trig` is
    /// yellow - so a shared socket name counts as compatible on its own.
    private func assertCompatible(_ from: ConnectorDef, _ to: ConnectorDef, _ label: String) {
        let interchangeable: [Set<ConnectorColor>] = [
            [.audio, .control, .pitchOrControl],
            [.logic, .control, .logicOrControl, .pitchOrControl],
        ]
        let ok = from.name == to.name
            || from.color == to.color
            || interchangeable.contains { $0.contains(from.color) && $0.contains(to.color) }
        XCTAssertTrue(ok, "\(label): \(from.name) (\(from.color)) -> \(to.name) (\(to.color))")
    }
}
