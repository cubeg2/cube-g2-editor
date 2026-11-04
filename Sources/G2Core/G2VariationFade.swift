// G2VariationFade.swift
// Fader wariacji (życzenie z forum #13): płynne przejście z jednej wariacji w drugą.
//
// Ani oryginalny edytor, ani BVerhue tego nie mają. Brzmienie „pomiędzy” powstaje
// w buforze odsłuchu (zestaw 9, ten sam co Patch Mutatora), więc osiem zapisanych
// wariacji zostaje nietkniętych → [[Docs/ui/variations]] „Variation fader”.

/// Liczenie brzmienia pod faderem wariacji — bez stanu, bez urządzenia.
public enum G2VariationFade {
    /// Ustawienia patcha, które płyną razem z gałkami: osiem gałek morfów, Patch Volume,
    /// Glide Time i głębokość/szybkość vibrata. Reszta obszaru 2 to przełączniki i skoki
    /// (źródła morfów, tryby Glide/Bend/Arp, Octave Shift…) — te skaczą w połowie drogi.
    static let smoothSettings: Set<G2Individual.Key> = Set(
        (0 ..< G2Morph.count).map { G2Individual.Key.setting(module: G2Mutator.morphSettingsModule, param: $0) }
            + [G2PatchSetting.patchVolume, .glideTime, .vibratoCents, .vibratoRate]
            .map { G2Individual.Key.setting(module: $0.module, param: $0.param) }
    )

    /// Wariacje 1–8 (w kodzie 0–7) z pominięciem tych, które brzmią identycznie jak
    /// poprzednia — tyle przystanków, ile naprawdę różnych brzmień (decyzja Kuby).
    /// Pierwsza wariacja jest przystankiem zawsze. Liczone przy każdej zmianie patcha
    /// (`SlotHeader`), więc porównuje surowe tablice, bez budowania osobników.
    public static func stops(of patch: G2Patch) -> [Int] {
        [0] + (1 ..< G2Patch.initVariation).filter { !patch.soundsSame($0, $0 - 1) }
    }

    /// Numer przystanku, na którym brzmi `variation`. Wariacja pominięta jako identyczna
    /// z poprzednią należy do przystanku tej poprzedniej. Para z porównania (np. [4, 0])
    /// nie jest posortowana — tam liczy się tylko obecność na liście.
    public static func stopIndex(of variation: Int, in stops: [Int]) -> Int? {
        guard (0 ..< G2Patch.initVariation).contains(variation) else { return nil }
        if let index = stops.firstIndex(of: variation) { return index }
        guard stops == stops.sorted() else { return nil }
        return stops.lastIndex { $0 <= variation }
    }

    /// Brzmienie w położeniu `t` między `a` (0) i `b` (1). Gałki i suwaki przechodzą
    /// płynnie; przełączniki i selektory (fale, typy filtra, on/off) mieszać się nie dają —
    /// średnia z „piły” i „kwadratu” nie istnieje — więc biorą wartości z `switches`
    /// (decyzja Kuby 2026-11-04: skok dopiero na przystanku, środek drogi w pełni płynny).
    /// Bez `switches` skaczą w połowie drogi. Morfy uśredniają się jak przy Interpolate.
    public static func blend(_ a: G2Individual, _ b: G2Individual, t: Double,
                             switches: G2Individual? = nil, genome: G2MutatorGenome) -> G2Individual
    {
        let t = min(1, max(0, t))
        var result = G2Mutator.blend(mother: a, father: b, t: t, genome: genome)
        let held = switches ?? (t < 0.5 ? a : b)
        for gene in genome.genes where gene.discreteStates != nil {
            result[gene.key] = held[gene.key]
        }
        for key in G2Mutator.settingKeys where !smoothSettings.contains(key) {
            result[key] = held[key]
        }
        return result
    }

    /// Brzmienie w położeniu `position` na drodze przez `stops` (0 = pierwszy przystanek,
    /// 1 = drugi…). Mieszają się zawsze tylko dwaj sąsiedzi: 2,5 to pół trzeciego
    /// i pół czwartego przystanku. `switchStop` — przystanek, którego przełączniki trzymamy
    /// (ten, z którego suwak ruszył); na samym przystanku gra on w całości.
    public static func sound(at position: Double, stops: [Int], switchStop: Int? = nil,
                             patch: G2Patch, genome: G2MutatorGenome) -> G2Individual
    {
        guard !stops.isEmpty else { return G2Individual() }
        let clamped = min(Double(stops.count - 1), max(0, position))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, stops.count - 1)
        let a = G2Mutator.individual(from: patch, variation: stops[lower], genome: genome)
        guard upper != lower, clamped != Double(lower) else { return a }
        let b = G2Mutator.individual(from: patch, variation: stops[upper], genome: genome)
        let switches = switchStop.map { $0 == lower ? a : $0 == upper ? b
            : G2Mutator.individual(from: patch, variation: stops[min(max($0, 0), stops.count - 1)], genome: genome)
        }
        return blend(a, b, t: clamped - Double(lower), switches: switches, genome: genome)
    }

    /// Przystanek, którego przełączniki trzyma suwak po ruchu `from` → `to`: ostatni
    /// minięty albo dotknięty po drodze; bez takiego — dotychczasowy `held`.
    public static func switchStop(held: Int, from: Double, to: Double) -> Int {
        if to > from {
            let passed = to.rounded(.down)
            return passed > from || passed == to ? Int(passed) : held
        }
        if to < from {
            let passed = to.rounded(.up)
            return passed < from || passed == to ? Int(passed) : held
        }
        return held
    }

    /// Jak mocno świeci przycisk wariacji przy danym położeniu: 1 na przystanku,
    /// po połowie dla obu sąsiadów w pół drogi, 0 dla reszty. Wariacje pominięte jako
    /// identyczne świecą razem ze swoim przystankiem. Para z porównania (`pair`) świeci
    /// tylko swoimi dwiema wariacjami — [0, 1] jest posortowana, ale 3…8 nie są kopiami „2”.
    public static func weight(of variation: Int, at position: Double, stops: [Int],
                              pair: Bool = false) -> Double
    {
        let index = pair ? stops.firstIndex(of: variation) : stopIndex(of: variation, in: stops)
        guard let index else { return 0 }
        return max(0, 1 - abs(position - Double(index)))
    }
}

public extension G2Patch {
    /// Czy dwie wariacje brzmią identycznie: te same wartości parametrów obu obszarów,
    /// te same ustawienia patcha (z gałkami morfów) i te same przypisania morfów.
    func soundsSame(_ a: Int, _ b: Int) -> Bool {
        for module in voiceModules + fxModules {
            let values = module.parameterVariations
            guard values.indices.contains(a), values.indices.contains(b) else { continue }
            if values[a] != values[b] { return false }
        }
        if variationSettings.indices.contains(a), variationSettings.indices.contains(b),
           variationSettings[a] != variationSettings[b] { return false }
        if morphAssignments.indices.contains(a), morphAssignments.indices.contains(b),
           morphAssignments[a] != morphAssignments[b] { return false }
        return true
    }
}
