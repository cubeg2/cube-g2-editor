// G2MutatorAnchors.swift
// „Anchors" w panelu Mutation settings: poprawki dziecka już po wylosowaniu.
//
// Quick Lock mówi „nie ruszaj", waga grupy „ruszaj mniej", a anchor „ruszaj, ale wynik
// ma spełniać warunek" → Docs/mutator/plan-engine §9. Działają przy wszystkich
// czterech przyciskach; punktem odniesienia jest zawsze Mother.

import Foundation

/// Które anchory są włączone i z jakim zakresem.
public struct G2MutatorAnchors: Equatable, Sendable {
    /// Parametry przypięte do gałek (strony A1…E3) zostają jak w Mother — live set się nie rozjeżdża.
    public var knobAssigned: Bool
    /// Strój oscylatorów (kategoria OscFreq) najwyżej o tyle kroków od Mother; `nil` = wyłączony.
    public var rootPitch: Int?
    /// O ile (ułamek) wolno zmienić się sumie poziomów mikserów; `nil` = wyłączony.
    public var loudness: Double?
    /// LFO i delaye zsynchronizowane z zegarem lądują na prostych nutach (bez T i D).
    public var tempoGrid: Bool

    public static let pitchWindows = [0, 2, 7, 12]
    public static let loudnessWindows = [0.1, 0.25, 0.5]

    /// Domyślnie tylko gałki — reszta czeka, aż użytkownik ją zapali.
    public init(knobAssigned: Bool = true, rootPitch: Int? = nil, loudness: Double? = nil, tempoGrid: Bool = false) {
        self.knobAssigned = knobAssigned
        self.rootPitch = rootPitch
        self.loudness = loudness
        self.tempoGrid = tempoGrid
    }

    /// Wszystko wyłączone — tak jak oryginał.
    public static let off = G2MutatorAnchors(knobAssigned: false)

    public var isOff: Bool {
        self == .off
    }
}

/// Anchory przygotowane dla jednego patcha: które parametry pilnuje każdy z nich.
/// Budowane raz na naciśnięcie przycisku, potem poprawia każde dziecko.
public struct G2MutatorAnchoring {
    private let anchors: G2MutatorAnchors
    private let knobKeys: Set<G2Individual.Key>
    private let pitchKeys: [G2Individual.Key]
    private let levelKeys: [G2Individual.Key]
    private let tempoFields: [TempoField]

    private struct TempoField {
        let rate: G2Individual.Key
        let sync: G2Individual.Key
        /// Wartość przełącznika, przy której parametr liczy się w nutach.
        let syncValue: Int
        /// Wartości surowe, które wypadają na prostych nutach.
        let straight: [Int]
    }

    /// Klasa „Lev1…Lev8" poziomów mikserów.
    private static let mixerLevelClass: UInt8 = 0x3A
    /// Przełącznik zakresu LFO: 4 = Clk (zegar). Czasy delayów: przełącznik Clk = 1.
    private static let lfoClockMode = 4
    private static let lfoRateTextFunc = 103
    private static let delayClockTextFuncs: Set<Int> = [140, 143, 146]

    public init(patch: G2Patch, genome: G2MutatorGenome, anchors: G2MutatorAnchors) {
        self.anchors = anchors
        knobKeys = anchors.knobAssigned
            ? Set(patch.knobAssignments.compactMap { $0.map {
                G2Individual.Key(location: $0.location, moduleID: $0.moduleID, paramIndex: $0.paramIndex)
            } })
            : []
        pitchKeys = anchors.rootPitch == nil ? [] : genome.genes.filter { $0.category == .oscFreq }.map(\.key)

        var modules: [G2Individual.Key: G2Module] = [:]
        for area in [PatchArea.voice, PatchArea.fx] {
            for module in patch.modules(in: area) {
                modules[G2Individual.Key(area: area, moduleID: module.id, paramIndex: 0)] = module
            }
        }
        let moduleOf = { (gene: G2MutatorGenome.Gene) in
            modules[G2Individual.Key(area: gene.area, moduleID: gene.moduleID, paramIndex: 0)]
        }
        levelKeys = anchors.loudness == nil ? [] : genome.genes.filter { gene in
            guard let module = moduleOf(gene) else { return false }
            return G2ParamClass.of(moduleTypeID: module.typeID, paramIndex: gene.paramIndex)?.rawValue
                == Self.mixerLevelClass
        }.map(\.key)

        var tempo: [TempoField] = []
        if anchors.tempoGrid {
            for area in [PatchArea.voice, PatchArea.fx] {
                for module in patch.modules(in: area) {
                    for field in ModuleUIDatabase.shared.uiDef(forID: module.typeID)?.textFields ?? [] {
                        guard field.dependencies.count >= 2, field.dependencies[0] >= 0,
                              field.dependencies[1] >= 0 else { continue }
                        let rate = G2Individual.Key(area: area, moduleID: module.id, paramIndex: field.dependencies[0])
                        let sync = G2Individual.Key(area: area, moduleID: module.id, paramIndex: field.dependencies[1])
                        if field.textFunc == Self.lfoRateTextFunc {
                            tempo.append(TempoField(rate: rate, sync: sync, syncValue: Self.lfoClockMode,
                                                    straight: Self.straightLFO))
                        } else if Self.delayClockTextFuncs.contains(field.textFunc) {
                            tempo.append(TempoField(rate: rate, sync: sync, syncValue: 1,
                                                    straight: Self.straightDelay))
                        }
                    }
                }
            }
        }
        tempoFields = tempo
    }

    /// Poprawia dziecko względem Mother. Kolejność: gałki (wygrywają), tempo, strój,
    /// głośność — strój i głośność tylko cofają zmianę w stronę Mother, więc nie ruszają
    /// tego, co gałki już przywróciły.
    public func apply(_ child: G2Individual, mother: G2Individual) -> G2Individual {
        guard !anchors.isOff else { return child }
        var result = child
        for key in knobKeys {
            if let value = mother[key] { result[key] = value }
        }
        for field in tempoFields where !knobKeys.contains(field.rate) {
            guard let sync = result[field.sync], Int(sync.rounded()) == field.syncValue,
                  let rate = result[field.rate] else { continue }
            let raw = Int(rate.rounded())
            guard !field.straight.contains(raw),
                  let nearest = field.straight.min(by: { abs($0 - raw) < abs($1 - raw) }) else { continue }
            result[field.rate] = Double(nearest)
        }
        if let window = anchors.rootPitch.map(Double.init) {
            for key in pitchKeys {
                guard let base = mother[key], let value = result[key] else { continue }
                result[key] = min(base + window, max(base - window, value))
            }
        }
        if let loudness = anchors.loudness {
            scaleLevels(&result, mother: mother, tolerance: loudness)
        }
        return result
    }

    public func apply(_ children: [G2Individual], mother: G2Individual) -> [G2Individual] {
        anchors.isOff ? children : children.map { apply($0, mother: mother) }
    }

    /// Suma poziomów mikserów może odjechać od Mother najwyżej o `tolerance` — liczone od
    /// sumy Mother, ale nie mniej niż od jednego pełnego poziomu, żeby cichy patch też mógł
    /// się rozkręcić. Zbyt duża zmiana cofa się proporcjonalnie na wszystkich poziomach.
    private func scaleLevels(_ child: inout G2Individual, mother: G2Individual, tolerance: Double) {
        var motherSum = 0.0
        var childSum = 0.0
        for key in levelKeys {
            guard let base = mother[key], let value = child[key] else { continue }
            motherSum += base
            childSum += value
        }
        let allowed = tolerance * max(motherSum, 127)
        let drift = abs(childSum - motherSum)
        guard drift > allowed else { return }
        let factor = allowed / drift
        for key in levelKeys {
            guard let base = mother[key], let value = child[key] else { continue }
            child[key] = base + (value - base) * factor
        }
    }

    // MARK: Proste nuty

    /// Wartości zegarowe LFO i delayów, których napis to prosta nuta: obie liczby są
    /// potęgami dwójki i nie ma triolki (T) ani kropki (D).
    static func isStraightNote(_ label: String) -> Bool {
        guard !label.contains("T"), !label.contains("D") else { return false }
        let parts = label.split(separator: "/").compactMap { Int($0) }
        return parts.count == 2 && parts.allSatisfy { $0 > 0 && $0 & ($0 - 1) == 0 }
    }

    static let straightLFO = (0 ... 127).filter { isStraightNote(g2LFOClockStr($0)) }
    static let straightDelay = (0 ... 127).filter { isStraightNote(g2DelayClockSync($0)) }
}
