// MutatorSilenceHarness.swift
// Pomiar „Not silent" na prawdziwych patchach: dzieci Randomize w czterech wariantach,
// zapisane jako .pch2 do odsłuchu w emulatorze → Docs/mutator/patche-pod-mutator.
// Pomijany, dopóki nie ustawisz G2_MUTSIM_OUT (folder wyników) i G2_MUTSIM_PATCHES
// (folder z patchami); liczba dzieci na patch w G2_MUTSIM_CHILDREN (domyślnie 4), co który
// plik folderu brać w G2_MUTSIM_STEP (domyślnie 4 — co czwarty, najwyżej 24 patche).

import G2Core
import XCTest

private struct HarnessGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

final class MutatorSilenceHarness: XCTestCase {
    /// off = bez „Not silent"; reroll = przycisk z gałką na maksimum (tylko losowanie
    /// od nowa, jak do 2026-10-29); protect50/protect100 = losowanie od nowa + zawory.
    private let variants: [(name: String, notSilent: Bool, protection: Double)] = [
        ("off", false, 0), ("reroll", true, 0), ("protect50", true, 0.5), ("protect100", true, 1),
    ]

    /// Co strażnik widzi w tych samych patchach: czy rodzic gra wg reguł (inaczej strażnik
    /// się wyłącza), ile zaworów głośności znalazł i ile dzieci Randomize uznałby za ciche.
    func testReportGuard() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["G2_MUTSIM_OUT"] != nil, let folder = env["G2_MUTSIM_PATCHES"] else {
            throw XCTSkip("Set G2_MUTSIM_OUT and G2_MUTSIM_PATCHES to run the Not silent measurement")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder)
            .filter { $0.hasSuffix(".pch2") }.sorted()
        for (number, file) in stride(from: 0, to: files.count, by: 4).prefix(24).map({ files[$0] }).enumerated() {
            guard let patch = try PatchParser.parse(url: URL(fileURLWithPath: folder).appendingPathComponent(file)).first
            else { continue }
            let genome = G2MutatorGenome(patch: patch)
            let parent = G2Mutator.individual(from: patch, variation: patch.activeVariation, genome: genome)
            let silence = G2SilenceGuard(patch: patch, strictness: .init(sensitivity: 1))
            var generator = HarnessGenerator(seed: UInt64(number + 1))
            let flagged = (0 ..< 24).filter { _ in
                silence.isSilent(G2Mutator.randomize(base: parent, genome: genome, locks: G2MutatorLocks(),
                                                     using: &generator)[0])
            }.count
            print("GUARD \(file) | parent silent: \(silence.isSilent(parent)) | valves: \(silence.loudnessValves.count) | flagged 24: \(flagged)")
        }
    }

    func testWriteRandomizeChildren() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["G2_MUTSIM_OUT"], let folder = env["G2_MUTSIM_PATCHES"] else {
            throw XCTSkip("Set G2_MUTSIM_OUT and G2_MUTSIM_PATCHES to run the Not silent measurement")
        }
        let childCount = Int(env["G2_MUTSIM_CHILDREN"] ?? "") ?? 4
        let files = try FileManager.default.contentsOfDirectory(atPath: folder)
            .filter { $0.hasSuffix(".pch2") }.sorted()
        let step = Int(env["G2_MUTSIM_STEP"] ?? "") ?? 4
        let picked = stride(from: 0, to: files.count, by: step).prefix(24).map { files[$0] }
        for (number, file) in picked.enumerated() {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
            let data = try Data(contentsOf: url)
            guard let patch = try PatchParser.parse(url: url).first else { continue }
            let variation = patch.activeVariation
            let genome = G2MutatorGenome(patch: patch)
            let parent = G2Mutator.individual(from: patch, variation: variation, genome: genome)
            for variant in variants {
                let strictness = G2SilenceGuard.Strictness(sensitivity: variant.notSilent ? 1 : 0)
                let silence = G2SilenceGuard(patch: patch, strictness: strictness)
                let guarding = variant.notSilent && !silence.isSilent(parent)
                var generator = HarnessGenerator(seed: UInt64(number + 1))
                let next = { () -> G2Individual in
                    let child = G2Mutator.randomize(base: parent, genome: genome, locks: G2MutatorLocks(),
                                                    using: &generator)[0]
                    return variant.protection > 0
                        ? silence.protect(child, parent: parent, amount: variant.protection) : child
                }
                for index in 0 ..< childCount {
                    var child = next()
                    var attempts = 0
                    while guarding, silence.isSilent(child), attempts < 24 {
                        child = next()
                        attempts += 1
                    }
                    var written = patch
                    written.apply(child, variation: variation)
                    let dir = URL(fileURLWithPath: out).appendingPathComponent(variant.name)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let name = (file as NSString).deletingPathExtension + "__c\(index).pch2"
                    try PatchParser.saveAll(originalData: data, patches: [written])
                        .write(to: dir.appendingPathComponent(name))
                }
            }
        }
    }
}
