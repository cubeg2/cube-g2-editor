// G2MutatorAxis.swift
// „Amount axis" w panelu Mutation settings: fader jedzie po zamrożonej drodze Mother → cel.
//
// Klik w przycisk losuje, fader nie — przesuwa się po tym samym wektorze, więc ten sam
// procent daje zawsze ten sam dźwięk → Docs/mutator/plan-engine §8.

import Foundation

/// „Smooth" — grupy parametrów, które na osi Amount mają zostać jak w Mother.
///
/// Gałka przechodzi z wartości na wartość po 128 stopniach, więc droga jest gładka.
/// Przycisk ma dwa stany, selektor kilka — taki parametr nie potrafi być „w połowie",
/// więc każde jego przestawienie to jeden niepodzielny skok. Droga złożona z kilku
/// skoków nie daje się podzielić na osiem równych kratek („Family ▸ Equal") ani
/// przejechać faderem bez trzasku.
///
/// Zapalona grupa znaczy: ten rodzaj parametru zostaje na wartości Mother przez całą
/// drogę. Obie grupy zapalone = oś rusza same gałki, czyli zmiana w pełni stopniowa.
/// Cena jest po drugiej stronie: żadna kratka nie wprowadzi nowej fali ani innego
/// filtra, więc rodzina robi się spokojniejsza. Stąd domyślnie wyłączone.
public struct G2SmoothAxis: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Parametry o dwóch stanach: przyciski Off/On, kroki `Evnt` sekwencerów, `Active`.
    public static let switches = G2SmoothAxis(rawValue: 1 << 0)
    /// Parametry o trzech i więcej stanach: fale, typy filtrów, wyjścia, tryby arpeggiatora.
    public static let selectors = G2SmoothAxis(rawValue: 1 << 1)

    public static let all: G2SmoothAxis = [.switches, .selectors]

    /// Czy ten parametr ma zostać na wartości Mother.
    public func holds(_ gene: G2MutatorGenome.Gene) -> Bool {
        guard let states = gene.discreteStates else { return false }
        return contains(states <= 2 ? .switches : .selectors)
    }

    /// Cel z parametrami wybranych grup przepisanymi z Mother. Pusty zestaw nic nie zmienia.
    public func hold(_ target: G2Individual, at mother: G2Individual,
                     genome: G2MutatorGenome) -> G2Individual
    {
        guard !isEmpty else { return target }
        var result = target
        for gene in genome.genes where holds(gene) {
            result[gene.key] = mother[gene.key]
            result.morphs[gene.key] = mother.morphs[gene.key]
        }
        return result
    }
}

/// Droga od Mother (0 %) do celu (100 %).
public struct G2MutationAxis: Equatable, Sendable {
    /// Skąd bierze się cel.
    public enum Target: String, CaseIterable, Sendable {
        /// Jedno losowanie jak w Randomize — daleko od Mother.
        case random = "Random"
        /// Jedno dziecko Mutate z gałek Probability i Range — blisko Mother.
        case mutate = "Mutate"
        /// Kratka, którą właśnie słychać — płynne Interpolate.
        case focus = "Focus"
    }

    /// 0 % — bit w bit Mother z chwili utworzenia osi.
    public let origin: G2Individual
    /// 100 %.
    public let target: G2Individual
    public let kind: Target
    /// Grupy trzymane na wartości Mother przy budowie celu — oś zbudowana z innym
    /// ustawieniem „Smooth" jest inną osią i trzeba ją policzyć od nowa.
    public let smooth: G2SmoothAxis

    public init(origin: G2Individual, target: G2Individual, kind: Target,
                smooth: G2SmoothAxis = [])
    {
        self.origin = origin
        self.target = target
        self.kind = kind
        self.smooth = smooth
    }

    /// Dźwięk w `amount` drogi. Anchory liczą się od Mother, tak jak przy przyciskach;
    /// na 0 % nie działają wcale, żeby wynik był dokładnie Mother.
    public func point(at amount: Double, genome: G2MutatorGenome, anchoring: G2MutatorAnchoring) -> G2Individual {
        guard amount > 0 else { return origin }
        // Na 100 % sam cel — `a + (b − a) × 1` nie zawsze wraca dokładnie do `b`.
        let blend = amount < 1 ? G2Mutator.blend(mother: origin, father: target, t: amount, genome: genome) : target
        return anchoring.apply(blend, mother: origin)
    }
}
