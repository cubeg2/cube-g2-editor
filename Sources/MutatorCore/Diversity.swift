// Diversity.swift
// Metryka różnicy dwóch genomów i wybór najbardziej różnych dzieci z puli.
//
// Bez renderowania dźwięku zostaje ważony dystans parametryczny:
//
//   d(A, B) = Σ w(addr) · |rawA − rawB| / maxRaw        w(addr) = słyszalność × waga rodzaju
//
// Dzielimy przez `maxRaw` parametru, nie przez stałe 127: przełącznik 0…3 przestawiony
// o jedną pozycję to spora zmiana, a nie 1/127. Kategoria i przełącznik liczą się jako
// „inne albo takie same" — odległość między falą 1 a 4 nie jest większa niż między 1 a 2.
//
// To „równomiernie w metryce parametrycznej", nie „percepcyjnie" → Docs/mutator/plan-engine §7.

public struct Diversity: Sendable {
    public var space: [ParameterAddress: ParameterSemantics]
    /// Mnożnik słyszalności 0…1 na adres (w G2: `G2AudibilityMap.weight`); domyślnie wszystko słychać.
    public var audibility: @Sendable (ParameterAddress) -> Double

    public init(space: [ParameterAddress: ParameterSemantics],
                audibility: @escaping @Sendable (ParameterAddress) -> Double = { _ in 1 })
    {
        self.space = space
        self.audibility = audibility
    }

    public func distance(_ a: Genome, _ b: Genome) -> Double {
        var total = 0.0
        for (address, gene) in a.genes {
            guard let semantics = space[address], semantics.maxRaw > 0,
                  let other = b.genes[address]?.raw, other != gene.raw else { continue }
            let weight = semantics.weight * audibility(address)
            switch semantics.kind {
            case .categorical, .boolean:
                total += weight
            default:
                total += weight * Double(abs(Int(gene.raw) - Int(other))) / Double(semantics.maxRaw)
            }
        }
        return total
    }

    /// Greedy max-min: najpierw kandydat najdalszy od Mother, potem kolejno ten, którego
    /// najmniejsza odległość od Mother i już wybranych jest największa. Remis — wcześniejszy
    /// w puli, więc wynik zależy tylko od puli.
    public func selectMostDifferent(_ count: Int, from pool: [Genome], mother: Genome) -> [Genome] {
        selectMostDifferent(count, from: pool, parents: [mother]).map { pool[$0] }
    }

    /// To samo dla kilku rodziców (Cross: Mother i Father) — zwraca numery w puli, żeby
    /// wołający mógł wziąć własną postać kandydata. Pusta lista rodziców = start od pierwszego.
    public func selectMostDifferent(_ count: Int, from pool: [Genome], parents: [Genome]) -> [Int] {
        var nearest = pool.map { candidate in
            parents.map { distance(candidate, $0) }.min() ?? .infinity
        }
        var remaining = Array(pool.indices)
        var chosen: [Int] = []
        while chosen.count < count, !remaining.isEmpty {
            let best = remaining.indices.max { nearest[remaining[$0]] < nearest[remaining[$1]] }!
            let picked = remaining.remove(at: best)
            chosen.append(picked)
            for index in remaining {
                nearest[index] = min(nearest[index], distance(pool[index], pool[picked]))
            }
        }
        return chosen
    }
}
