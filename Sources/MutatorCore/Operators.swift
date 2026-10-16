// Operators.swift
// Operatory silnika: Mutate, Randomize, Interpolate, Cross — z regułami rodzaju parametru.
//
// Wszystkie klonują Mother jako szkielet, zostawiają geny zablokowane (factor 0)
// i krytyczne, a wynikowi ustawiają `lineage`. Reguły rodzaju → Docs/mutator/plan-engine §5:
//
//   liniowy, bipolarny, poziom — gauss w domenie surowej, odbicie od krawędzi
//   logarytmiczny, czas         — gauss w domenie log(raw + 1)
//   półtony, podziały           — całkowity krok na siatce
//   rezonans                    — gauss z hamulcem powyżej `resonanceBrake`
//   kategoria, przełącznik      — skok z małym prawdopodobieństwem; w interpolacji próg t = 0,5
//   krok sekwencera             — cały wzór modułu przesunięty, nie gauss per krok
//   obwiednia                   — czasy modułu razem, jednym współczynnikiem skali
//
// To silnik poziomu Rozszerzonego. Standard (wierne operatory oryginału) zostaje
// w `G2Mutator` i tego pliku nie używa.

import Foundation

public enum CrossMode: Sendable, Equatable {
    /// Po każdym genie przeskok na drugiego rodzica z tym prawdopodobieństwem.
    case gene(switchProbability: Double)
    /// Każdy moduł w całości od jednego, losowego rodzica.
    case moduleLevel
}

public struct Operators: Sendable {
    public var space: [ParameterAddress: ParameterSemantics]
    public var mutability: MutabilityMap

    /// Powyżej tej wartości rezonans rośnie o połowę wolniej — mniej przypadkowej samooscylacji.
    public static let resonanceBrake = 100.0
    /// Szansa skoku kategorii / przełącznika przy magnitude 1 i pełnej swobodzie.
    public static let categoricalJump = 0.3
    public static let booleanFlip = 0.05
    /// Odchylenie kroku w półtonach i w pozycjach siatki podziałów przy magnitude 1.
    public static let semitoneSigma = 12.0
    public static let divisionSigma = 3.0

    public init(space: [ParameterAddress: ParameterSemantics], mutability: MutabilityMap = MutabilityMap()) {
        self.space = space
        self.mutability = mutability
    }

    // MARK: - Mutate

    public func mutate(_ mother: Genome, magnitude: Double, using rng: inout some RandomNumberGenerator) -> Genome {
        var child = offspring(of: [mother], by: .mutate)
        var envelopeTimes: [ModuleAddress: [ParameterAddress]] = [:]
        var sequences: [ModuleAddress: [ParameterAddress]] = [:]

        for address in mother.genes.keys.sorted() {
            guard let (semantics, freedom) = movable(address) else { continue }
            if semantics.kind == .timeMs, semantics.group == .envelope {
                envelopeTimes[ModuleAddress(address), default: []].append(address)
                continue
            }
            if semantics.kind == .sequencerStep {
                sequences[ModuleAddress(address), default: []].append(address)
                continue
            }
            let raw = mother.genes[address]!.raw
            child.genes[address]?.raw = mutateValue(raw, semantics, freedom, magnitude, &rng)
        }
        for module in envelopeTimes.keys.sorted(by: { ($0.area, $0.module) < ($1.area, $1.module) }) {
            scaleEnvelope(envelopeTimes[module]!, of: mother, into: &child, magnitude: magnitude, using: &rng)
        }
        for module in sequences.keys.sorted(by: { ($0.area, $0.module) < ($1.area, $1.module) }) {
            rotatePattern(sequences[module]!, of: mother, into: &child, magnitude: magnitude, using: &rng)
        }
        return child
    }

    private func mutateValue(_ raw: UInt8, _ semantics: ParameterSemantics, _ freedom: Mutability,
                             _ magnitude: Double, _ rng: inout some RandomNumberGenerator) -> UInt8
    {
        let max = Double(semantics.maxRaw)
        let strength = magnitude * freedom.factor
        switch semantics.kind {
        case .continuousLinear, .bipolar, .level:
            return MutationStep.gaussian(raw: raw, maxRaw: semantics.maxRaw, mutability: freedom,
                                         magnitude: magnitude, using: &rng)
        case .resonance:
            let moved = Double(MutationStep.gaussian(raw: raw, maxRaw: semantics.maxRaw, mutability: freedom,
                                                     magnitude: magnitude, using: &rng))
            guard moved > Self.resonanceBrake, moved > Double(raw) else { return UInt8(moved) }
            let start = Swift.max(Self.resonanceBrake, Double(raw))
            return UInt8((start + (moved - start) / 2).rounded())
        case .continuousLog, .timeMs:
            let sigma = MutationStep.fullScaleSigma * strength * log(max + 1)
            let moved = log(Double(raw) + 1) + sigma * MutationStep.standardNormal(using: &rng)
            return UInt8(MutationStep.reflect((exp(moved) - 1).rounded(), max: max))
        case .pitchSemitone, .syncedDivision:
            let sigma = (semantics.kind == .pitchSemitone ? Self.semitoneSigma : Self.divisionSigma) * strength
            let step = (sigma * MutationStep.standardNormal(using: &rng)).rounded()
            return UInt8(MutationStep.reflect(Double(raw) + step, max: max))
        case .categorical:
            guard semantics.maxRaw > 0, Double.random(in: 0 ..< 1, using: &rng) < Self.categoricalJump * strength
            else { return raw }
            let other = UInt8.random(in: 0 ..< semantics.maxRaw, using: &rng)
            return other >= raw ? other + 1 : other
        case .boolean:
            guard Double.random(in: 0 ..< 1, using: &rng) < Self.booleanFlip * strength else { return raw }
            return raw == 0 ? semantics.maxRaw : 0
        case .sequencerStep:
            return raw // obsługuje `rotatePattern`
        }
    }

    /// Czasy obwiedni modułu mnożone przez ten sam `exp(ε)` w domenie log(raw + 1) —
    /// proporcje A : D : R zostają, artykulacja się nie rozjeżdża. Przycinanie zamiast
    /// odbicia, bo odbicie odwróciłoby kierunek tylko części czasów.
    private func scaleEnvelope(_ addresses: [ParameterAddress], of mother: Genome, into child: inout Genome,
                               magnitude: Double, using rng: inout some RandomNumberGenerator)
    {
        let strength = addresses.map { movable($0)?.1.factor ?? 0 }.min() ?? 0
        let normal = MutationStep.standardNormal(using: &rng)
        for address in addresses {
            guard let semantics = space[address], let raw = mother.genes[address]?.raw else { continue }
            let max = Double(semantics.maxRaw)
            let epsilon = MutationStep.fullScaleSigma * magnitude * strength * log(max + 1) * normal
            let scaled = (exp(log(Double(raw) + 1) + epsilon) - 1).rounded()
            child.genes[address]?.raw = UInt8(Swift.min(Swift.max(scaled, 0), max))
        }
    }

    /// Wzór sekwencera przesunięty w całości o losową liczbę kroków.
    private func rotatePattern(_ addresses: [ParameterAddress], of mother: Genome, into child: inout Genome,
                               magnitude: Double, using rng: inout some RandomNumberGenerator)
    {
        let strength = addresses.map { movable($0)?.1.factor ?? 0 }.min() ?? 0
        guard addresses.count > 1,
              Double.random(in: 0 ..< 1, using: &rng) < Self.categoricalJump * magnitude * strength
        else { return }
        let offset = Int.random(in: 1 ..< addresses.count, using: &rng)
        for (index, address) in addresses.enumerated() {
            let source = addresses[(index + offset) % addresses.count]
            child.genes[address]?.raw = mother.genes[source]!.raw
        }
    }

    // MARK: - Randomize

    public func randomize(_ mother: Genome, using rng: inout some RandomNumberGenerator) -> Genome {
        var child = offspring(of: [mother], by: .randomize)
        for address in mother.genes.keys.sorted() {
            guard let (semantics, _) = movable(address) else { continue }
            child.genes[address]?.raw = UInt8.random(in: 0 ... semantics.maxRaw, using: &rng)
        }
        return child
    }

    // MARK: - Interpolate

    /// Punkt `t` drogi z Mother do Target. `t = 0` daje Mother, `t = 1` — Target
    /// na genach, które wolno ruszać.
    public func interpolate(_ mother: Genome, _ target: Genome, t: Double) throws -> Genome {
        try mother.requireCompatible(with: target)
        var child = offspring(of: [mother, target], by: .interpolate)
        for address in mother.genes.keys.sorted() {
            guard let (semantics, _) = movable(address), let a = mother.genes[address]?.raw,
                  let b = target.genes[address]?.raw else { continue }
            child.genes[address]?.raw = Self.lerp(a, b, t: t, kind: semantics.kind)
        }
        return child
    }

    public static func lerp(_ a: UInt8, _ b: UInt8, t: Double, kind: ParameterKind) -> UInt8 {
        if t <= 0 { return a }
        if t >= 1 { return b }
        switch kind {
        case .categorical, .boolean, .sequencerStep:
            return t < 0.5 ? a : b
        case .continuousLog, .timeMs:
            let x = log(Double(a) + 1) + (log(Double(b) + 1) - log(Double(a) + 1)) * t
            return UInt8((exp(x) - 1).rounded())
        case .continuousLinear, .bipolar, .level, .resonance, .pitchSemitone, .syncedDivision:
            return UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded())
        }
    }

    // MARK: - Cross

    public func cross(_ mother: Genome, _ father: Genome, mode: CrossMode,
                      using rng: inout some RandomNumberGenerator) throws -> Genome
    {
        try mother.requireCompatible(with: father)
        var child = offspring(of: [mother, father], by: .cross)
        var fromFather = Bool.random(using: &rng)
        var moduleChoice: [ModuleAddress: Bool] = [:]
        for address in mother.genes.keys.sorted() {
            switch mode {
            case let .gene(switchProbability):
                if Double.random(in: 0 ..< 1, using: &rng) < switchProbability { fromFather.toggle() }
            case .moduleLevel:
                let module = ModuleAddress(address)
                if moduleChoice[module] == nil { moduleChoice[module] = Bool.random(using: &rng) }
                fromFather = moduleChoice[module]!
            }
            guard movable(address) != nil, fromFather, let raw = father.genes[address]?.raw else { continue }
            child.genes[address]?.raw = raw
        }
        return child
    }

    // MARK: - Wspólne

    /// Semantyka i swoboda genu, albo `nil`, gdy gen ma zostać jak w Mother.
    private func movable(_ address: ParameterAddress) -> (ParameterSemantics, Mutability)? {
        guard let semantics = space[address], !semantics.critical else { return nil }
        let freedom = mutability.mutability(address)
        return freedom.isLocked ? nil : (semantics, freedom)
    }

    private func offspring(of parents: [Genome], by kind: OperatorKind) -> Genome {
        var child = parents[0]
        child.id = UUID()
        child.createdAt = Date()
        child.lineage = Lineage(parents: parents.map(\.id), operatorKind: kind,
                                generation: (parents.map(\.lineage.generation).max() ?? 0) + 1)
        return child
    }
}
