// G2MutatorFamily.swift
// „Family → Variations" w panelu Mutation settings: osiem próbek jednej drogi Mother → cel.
//
// To nie osiem wywołań Mutate — jedna oś (ta sama, po której jedzie fader Amount) i osiem
// punktów na niej, więc wariacje 1…8 na Nordzie przechodzą płynnie od Mother do celu
// → Docs/mutator/plan-engine §8.

import Foundation

/// Jak gęsto osiem punktów rozkłada się na drodze Mother → cel.
public enum G2FamilySpacing: String, CaseIterable, Sendable {
    /// Równe skoki fadera: 0, 14, 29 … 100 %.
    case linear = "Linear"
    /// Gęsto przy Mother — pierwsze kratki ledwo się różnią, ostatnie skaczą.
    case easeIn = "Ease in"
    /// Gęsto przy celu — szybko odjeżdża, końcówka prawie jak cel.
    case easeOut = "Ease out"
    /// Równe skoki w metryce dystansu (tej samej co „Pool & Diversity") — każda para
    /// sąsiednich kratek różni się o tyle samo.
    case equalDistance = "Equal"

    /// Położenie fadera dla kratki `index` z ośmiu. `equalDistance` liczy się z drogi
    /// (`G2VariationFamily.amounts`), tu zostaje liniowe jako punkt wyjścia.
    func amount(at index: Int) -> Double {
        let u = Double(index) / Double(G2VariationFamily.count - 1)
        switch self {
        case .linear, .equalDistance: return u
        case .easeIn: return u * u
        case .easeOut: return 1 - (1 - u) * (1 - u)
        }
    }
}

public enum G2VariationFamily {
    /// Tyle, ile wariacji użytkownika — rodzina wypełnia cały rząd magazynu.
    public static let count = 8
    /// Na ile odcinków dzielimy drogę, mierząc ją przy `equalDistance`.
    static let samples = 56

    /// Osiem dźwięków od Mother (kratka 1, bit w bit) do celu (kratka 8).
    public static func sounds(axis: G2MutationAxis, spacing: G2FamilySpacing, genome: G2MutatorGenome,
                              anchoring: G2MutatorAnchoring,
                              distance: (G2Individual, G2Individual) -> Double) -> [G2Individual]
    {
        amounts(axis: axis, spacing: spacing, genome: genome, anchoring: anchoring, distance: distance)
            .map { axis.point(at: $0, genome: genome, anchoring: anchoring) }
    }

    /// Położenia fadera dla ośmiu kratek. Przy `equalDistance` mierzymy drogę po kawałku
    /// — anchory i zaokrąglenia do bajtu wyginają ją, więc sam procent fadera nie mówi,
    /// jak daleko naprawdę jest dźwięk — i szukamy fadera, przy którym przebyta droga
    /// to i/7 całości.
    public static func amounts(axis: G2MutationAxis, spacing: G2FamilySpacing, genome: G2MutatorGenome,
                               anchoring: G2MutatorAnchoring,
                               distance: (G2Individual, G2Individual) -> Double) -> [Double]
    {
        let plain = (0 ..< count).map(spacing.amount(at:))
        guard spacing == .equalDistance else { return plain }
        let points = (0 ... samples).map {
            axis.point(at: Double($0) / Double(samples), genome: genome, anchoring: anchoring)
        }
        var travelled = [0.0]
        for step in 1 ... samples {
            travelled.append(travelled[step - 1] + distance(points[step - 1], points[step]))
        }
        let total = travelled[samples]
        guard total > 0 else { return plain }
        return (0 ..< count).map { index in
            let wanted = total * Double(index) / Double(count - 1)
            guard let step = (1 ... samples).first(where: { travelled[$0] >= wanted }) else { return 1 }
            let segment = travelled[step] - travelled[step - 1]
            let inside = segment > 0 ? (wanted - travelled[step - 1]) / segment : 0
            return (Double(step - 1) + inside) / Double(samples)
        }
    }
}
