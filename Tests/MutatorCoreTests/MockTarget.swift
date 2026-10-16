import Foundation
import MutatorCore

/// Cel w pamięci — zamiast G2. Trzyma warstwy wartości i liczy zapisy, żeby testy
/// widziały, że silnik wysyła różnice, a nie cały stan.
final class MockTarget: ParameterTarget, @unchecked Sendable {
    let fingerprint: TargetFingerprint
    let space: [ParameterAddress: ParameterSemantics]

    private let lock = NSLock()
    private var layers: [UInt8: [ParameterAddress: UInt8]]
    private(set) var writes: [(diff: [ParameterAddress: UInt8], layer: UInt8)] = []

    /// `modules` modułów po `parameters` parametrów w obszarze 1, wartości od `start`.
    init(modules: UInt8 = 2, parameters: UInt8 = 4, maxRaw: UInt8 = 127, start: UInt8 = 64) {
        var space: [ParameterAddress: ParameterSemantics] = [:]
        for module in 0 ..< modules {
            for parameter in 0 ..< parameters {
                space[ParameterAddress(area: 1, module: module, parameter: parameter)] =
                    ParameterSemantics(maxRaw: maxRaw)
            }
        }
        self.space = space
        fingerprint = TargetFingerprint(structureHash: 0, moduleCount: Int(modules))
        layers = [0: space.mapValues { _ in min(start, maxRaw) }]
    }

    func snapshot(layer: UInt8) async throws -> [ParameterAddress: UInt8] {
        lock.withLock { layers[layer] ?? layers[0] ?? [:] }
    }

    func write(_ diff: [ParameterAddress: UInt8], layer: UInt8) async throws {
        lock.withLock {
            var values = layers[layer] ?? layers[0] ?? [:]
            values.merge(diff) { _, new in new }
            layers[layer] = values
            writes.append((diff, layer))
        }
    }
}
