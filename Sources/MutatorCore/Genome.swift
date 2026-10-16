// Genome.swift
// Gen i genom — jeden dźwięk jako zbiór surowych wartości parametrów.
//
// Surowa wartość jest JEDYNYM źródłem prawdy. Skala 0…127 w G2 jest już percepcyjnie
// rozłożona przez producenta; trzymanie genu jako `Double` po drugiej krzywej
// logarytmowałoby dwa razy, a przejście tam i z powrotem gubiłoby wartości przy
// zaokrąglaniu. Krzywa służy tylko do policzenia kroku mutacji i nigdzie nie jest
// zapisywana → Docs/mutator/plan-architecture §4.1.

import Foundation

public struct Gene: Hashable, Codable, Sendable {
    public var address: ParameterAddress
    public var raw: UInt8
    /// 0 = gen wyciszony, 1 = pełna ekspresja.
    public var expression: Double

    public init(address: ParameterAddress, raw: UInt8, expression: Double = 1) {
        self.address = address
        self.raw = raw
        self.expression = expression
    }
}

/// Operator, który stworzył genom.
public enum OperatorKind: String, Codable, Sendable {
    case mutate, randomize, interpolate, cross
}

/// Skąd genom się wziął — rodzice, operator i numer pokolenia.
public struct Lineage: Hashable, Codable, Sendable {
    public var parents: [UUID]
    public var operatorKind: OperatorKind?
    public var generation: Int

    public init(parents: [UUID] = [], operatorKind: OperatorKind? = nil, generation: Int = 0) {
        self.parents = parents
        self.operatorKind = operatorKind
        self.generation = generation
    }
}

public enum GenomeError: Error, Equatable {
    /// Dwa genomy pochodzą z celów o różnej strukturze — ich genów nie da się sparować.
    case fingerprintMismatch(TargetFingerprint, TargetFingerprint)
}

public struct Genome: Identifiable, Codable, Sendable {
    public var id: UUID
    public var fingerprint: TargetFingerprint
    public var genes: [ParameterAddress: Gene]
    public var lineage: Lineage
    public var createdAt: Date

    public init(id: UUID = UUID(), fingerprint: TargetFingerprint, genes: [ParameterAddress: Gene],
                lineage: Lineage = Lineage(), createdAt: Date = Date())
    {
        self.id = id
        self.fingerprint = fingerprint
        self.genes = genes
        self.lineage = lineage
        self.createdAt = createdAt
    }

    /// Genom ze zrzutu celu (`ParameterTarget.snapshot`).
    public init(fingerprint: TargetFingerprint, snapshot: [ParameterAddress: UInt8],
                lineage: Lineage = Lineage())
    {
        self.init(fingerprint: fingerprint,
                  genes: snapshot.reduce(into: [:]) { genes, entry in
                      genes[entry.key] = Gene(address: entry.key, raw: entry.value)
                  },
                  lineage: lineage)
    }

    /// Surowe wartości — to, co idzie do `ParameterTarget.write`.
    public var values: [ParameterAddress: UInt8] {
        genes.mapValues(\.raw)
    }

    /// Wartości, które różnią się od `other` — zapis wysyła tylko je.
    public func diff(from other: Genome) -> [ParameterAddress: UInt8] {
        genes.reduce(into: [:]) { diff, entry in
            if other.genes[entry.key]?.raw != entry.value.raw { diff[entry.key] = entry.value.raw }
        }
    }

    /// Rzuca, gdy `other` ma inną strukturę — przed każdym operatorem dwojga rodziców.
    public func requireCompatible(with other: Genome) throws {
        guard fingerprint.structureHash == other.fingerprint.structureHash else {
            throw GenomeError.fingerprintMismatch(fingerprint, other.fingerprint)
        }
    }
}
