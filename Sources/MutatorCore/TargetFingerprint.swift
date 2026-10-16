// TargetFingerprint.swift
// Odcisk struktury celu — czy dwa genomy mają ten sam zbiór genów.
//
// Liczony wyłącznie z modułów (obszar, numer, typ), **bez kabli**: kabel zmienia
// brzmienie, ale nie zbiór parametrów, więc dołożenie kabla nie może unieważnić
// sesji hodowli → Docs/mutator/plan-architecture §4.2.

/// Jeden moduł celu, tak jak widzi go odcisk.
public struct ModuleIdentity: Hashable, Codable, Sendable {
    public var area: UInt8
    public var index: UInt8
    public var type: UInt16

    public init(area: UInt8, index: UInt8, type: UInt16) {
        self.area = area
        self.index = index
        self.type = type
    }
}

/// Odcisk struktury celu. Krzyżowanie jest legalne tylko przy równym `structureHash`.
public struct TargetFingerprint: Hashable, Codable, Sendable {
    public var structureHash: UInt64
    public var moduleCount: Int

    public init(structureHash: UInt64, moduleCount: Int) {
        self.structureHash = structureHash
        self.moduleCount = moduleCount
    }

    /// Odcisk z listy modułów. Kolejność listy nie ma znaczenia.
    ///
    /// FNV-1a zamiast `Hasher`: `Hasher` losuje ziarno przy każdym uruchomieniu,
    /// a odcisk trafia do zapisanej sesji i musi być ten sam jutro.
    public init(modules: [ModuleIdentity]) {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        let sorted = modules.sorted { ($0.area, $0.index, $0.type) < ($1.area, $1.index, $1.type) }
        for module in sorted {
            mix(module.area)
            mix(module.index)
            mix(UInt8(module.type >> 8))
            mix(UInt8(module.type & 0xFF))
        }
        self.init(structureHash: hash, moduleCount: modules.count)
    }
}
