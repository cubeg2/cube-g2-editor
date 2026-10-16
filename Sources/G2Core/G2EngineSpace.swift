// G2EngineSpace.swift
// Patch G2 widziany oczami silnika `MutatorCore`: adresy, semantyka, odcisk, blokady.
//
// Okno Standard trzyma dźwięk jako `G2Individual` (wartości `Double` + morfy), silnik —
// jako `Genome` (surowe bajty). Ten plik tłumaczy w obie strony i nic poza tym:
//   • adres silnika = klucz osobnika (obszar 0 FX / 1 VA, moduł, parametr);
//   • geny = parametry modułów z `G2MutatorGenome` — ten sam spis co Standard;
//   • ustawienia patcha (obszar 2: gałki morfów, Glide, Bend…) i morfy NIE są genami —
//     wracają do dziecka z osobnika bazowego bez zmian;
//   • blokady Standardu (Exclude From Mutations, Quick Locks) → `MutabilityMap`, żeby
//     twardy stop Standardu działał także w silniku → Docs/mutator/plan-ui „Dwie reguły".

import MutatorCore

public extension ParameterAddress {
    /// Adres parametru modułu. `nil` dla ustawień patcha i numerów spoza bajtu.
    init?(_ key: G2Individual.Key) {
        guard key.area != nil, let module = UInt8(exactly: key.moduleID),
              let parameter = UInt8(exactly: key.paramIndex) else { return nil }
        self.init(area: key.location, module: module, parameter: parameter)
    }

    var key: G2Individual.Key {
        G2Individual.Key(location: area, moduleID: Int(module), paramIndex: Int(parameter))
    }
}

public struct G2EngineSpace: Sendable {
    public let fingerprint: TargetFingerprint
    public let space: [ParameterAddress: ParameterSemantics]
    private let genome: G2MutatorGenome

    /// `genome` musi pochodzić z tego samego patcha — okno trzyma go w pamięci podręcznej.
    public init(patch: G2Patch, genome: G2MutatorGenome) {
        var types: [PatchArea: [Int: Int]] = [:]
        var modules: [ModuleIdentity] = []
        for area in [PatchArea.voice, PatchArea.fx] {
            for module in patch.modules(in: area) {
                types[area, default: [:]][module.id] = module.typeID
                if let index = UInt8(exactly: module.id), let type = UInt16(exactly: module.typeID) {
                    modules.append(ModuleIdentity(area: area.rawValue, index: index, type: type))
                }
            }
        }
        var space: [ParameterAddress: ParameterSemantics] = [:]
        for gene in genome.genes {
            guard let address = ParameterAddress(gene.key),
                  let type = types[gene.area]?[gene.moduleID] else { continue }
            let maxRaw = UInt8(clamping: gene.maxValue)
            // Parametru, którego Standard nie rusza, nie rusza też silnik.
            let known = gene.isMutable
                ? G2ParamClass.semantics(moduleTypeID: type, paramIndex: gene.paramIndex, maxRaw: maxRaw)
                : nil
            space[address] = known
                ?? ParameterSemantics(maxRaw: maxRaw, kind: .categorical, weight: 0, critical: true)
        }
        fingerprint = TargetFingerprint(modules: modules)
        self.space = space
        self.genome = genome
    }

    public init(patch: G2Patch) {
        self.init(patch: patch, genome: G2MutatorGenome(patch: patch))
    }

    /// Blokady Standardu w języku silnika. Moduł wyłączony z mutacji → blokada modułu,
    /// kategoria zamknięta Quick Lockiem (albo poza solo) → blokada parametru. Z mapą
    /// słyszalności parametr, którego nie słychać, dostaje powód `.inaudible` — nie jest
    /// „chroniony", tylko nic nie robi; prawdziwa blokada ma pierwszeństwo.
    public func mutability(locks: G2MutatorLocks, audibility: G2AudibilityMap? = nil) -> MutabilityMap {
        var map = MutabilityMap()
        for gene in genome.genes {
            guard let address = ParameterAddress(gene.key) else { continue }
            if gene.moduleExcluded {
                map.moduleLocks[ModuleAddress(address)] = .module
            } else if gene.isMutable, !locks.allows(gene.category) {
                map.parameterLocks[address] = .explicit
            } else if gene.isMutable, audibility?.isAudible(gene.key) == false {
                map.parameterLocks[address] = .inaudible
            }
        }
        return map
    }

    /// Genom dźwięku. Wartości zaokrąglone do bajtu — tak samo jak przy zapisie do patcha.
    public func genome(of individual: G2Individual) -> Genome {
        var snapshot: [ParameterAddress: UInt8] = [:]
        for (address, semantics) in space {
            guard let value = individual[address.key] else { continue }
            snapshot[address] = Self.byte(value, max: semantics.maxRaw)
        }
        return Genome(fingerprint: fingerprint, snapshot: snapshot)
    }

    /// Dźwięk z genomu. Gen, którego bajt się nie zmienił, zostaje dokładną wartością
    /// z `base` — Standard trzyma ułamki, żeby mutowanie raz za razem nie zaokrąglało się
    /// coraz bardziej. Ustawienia patcha i morfy też przychodzą z `base`.
    public func individual(_ genome: Genome, base: G2Individual) -> G2Individual {
        var result = base
        for (address, gene) in genome.genes {
            let key = address.key
            if let old = base[key], let semantics = space[address],
               Self.byte(old, max: semantics.maxRaw) == gene.raw { continue }
            result[key] = Double(gene.raw)
        }
        return result
    }

    /// „Pool & Diversity": `count` kandydatów najbardziej różnych od rodziców i od siebie
    /// nawzajem (greedy max-min z `Diversity`). Kandydaci wracają w swojej postaci —
    /// z ułamkami i morfami — a odległość liczymy na bajtach. Z mapą słyszalności parametr,
    /// którego nie słychać, nie robi różnicy.
    public func mostDifferent(_ count: Int, from pool: [G2Individual], parents: [G2Individual],
                              audibility: G2AudibilityMap? = nil) -> [G2Individual]
    {
        let diversity = Diversity(space: space) { audibility?.weight($0) ?? 1 }
        return diversity.selectMostDifferent(count, from: pool.map(genome(of:)),
                                             parents: parents.map(genome(of:)))
            .map { pool[$0] }
    }

    /// Odległość dwóch dźwięków w tej samej metryce co „Pool & Diversity" — na bajtach,
    /// z mapą słyszalności parametr, którego nie słychać, nie robi różnicy.
    public func distance(_ a: G2Individual, _ b: G2Individual, audibility: G2AudibilityMap? = nil) -> Double {
        Diversity(space: space) { audibility?.weight($0) ?? 1 }.distance(genome(of: a), genome(of: b))
    }

    private static func byte(_ value: Double, max: UInt8) -> UInt8 {
        UInt8(min(Swift.max(value.rounded(), 0), Double(max)))
    }
}
