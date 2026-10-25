// G2Mutator.swift
// Patch Mutator — hodowla patchy, jak w oknie „Patch Mutator" oryginału.
//
// Źródła: instrukcja „Nord Modular G2 Patch Mutator" (Palle Dahlstedt, 2006) oraz
// oryginalny edytor Clavii — Muta Synth Data, `CopyMutateContext`, `CopyRandomizeContext`,
// `InterpolateContext`, `RecombineContext`, Muta Box dialog (DrawChromosome).
//
// Model oryginału: jeden zestaw wartości parametrów to JEDEN OSOBNIK. Osobniki
// siedzą w kratkach — Mother, Father, sześcioro Children, 24 kratki Temporary
// Storage i osiem wariacji patcha. Cztery operacje robią z rodziców sześcioro
// dzieci:
//
//   Mutate      — jeden rodzic, losowe drgnięcia parametrów (prawdopodobieństwo × zasięg)
//   Randomize   — jeden rodzic, wartości losowane od zera
//   Interpolate — dwoje rodziców, dziecko `i` leży w (i+1)/7 drogi z Mother do Father
//   Cross       — dwoje rodziców, kopiowanie skacze między nimi z prawdopodobieństwem `crossProbability`
//
// Wartości trzymamy jako `Double`, nie jako gotowe bajty parametru — dokładnie jak
// oryginał (Module Param Data<double>). Dzięki temu mutowanie tego samego rodzica
// raz za razem nie zaokrągla się coraz bardziej.

import Foundation

// MARK: - Kategorie Quick Lock

/// Siedem kategorii parametrów z rzędu **Quick Locks** pod oknem mutatora.
/// Wartości bitów są te same, co maski Muta Synth Data (offsety 0x390 / 0x394)
/// — sprawdzone w Muta Synth Data (IsEnabled).
public enum G2MutatorCategory: UInt8, CaseIterable, Sendable {
    case oscFreq = 0x01
    case oscFine = 0x02
    case envelope = 0x08
    case seqValue = 0x10
    case seqEvent = 0x20
    case delays = 0x40
    case effects = 0x80

    /// Napis na przycisku — dosłownie jak w oryginale (Muta Background dialog).
    public var title: String {
        switch self {
        case .oscFreq: "OscFreq"
        case .oscFine: "OscFine"
        case .envelope: "Envelope"
        case .seqValue: "SeqValue"
        case .seqEvent: "SeqEvent"
        case .delays: "Delays"
        case .effects: "Effects"
        }
    }

    /// Kolejność przycisków w oknie — taka, w jakiej tworzy je konstruktor Clavii.
    public static let displayOrder: [G2MutatorCategory] =
        [.oscFreq, .oscFine, .envelope, .seqValue, .seqEvent, .delays, .effects]

    public var help: String {
        switch self {
        case .oscFreq: "Main oscillator frequency — Semi, Freq, Fact, Partial, DrumSynth master and slave"
        case .oscFine: "Oscillator fine tune (Cent)"
        case .envelope: "All envelope times and levels"
        case .seqValue: "Value faders of the step sequencers"
        case .seqEvent: "Gate and trigger event buttons of the sequencers"
        case .delays: "Parameters of the Delay modules"
        case .effects: "Parameters of the modules in the FX group"
        }
    }
}

/// Stan rzędu Quick Locks. Oryginał trzyma dwie maski bitowe: `enabled` (bit
/// ZAPALONY = kategoria wolna) i `solo`. Gdy `solo` jest niezerowe, przesłania
/// `enabled` w całości — a parametry bez kategorii przestają być ruszane, bo
/// `IsEnabled` kończy wtedy gałęzią `default: return solo == 0`.
public struct G2MutatorLocks: Equatable, Sendable {
    /// Domyślnie 0xFE — czyli `OscFreq` (bit 0x01) zamknięty na starcie, tak jak
    /// w konstruktorze Muta Synth Data i jak widać na zrzucie z instrukcji.
    public var enabled: UInt8
    public var solo: UInt8

    public init(enabled: UInt8 = 0xFE, solo: UInt8 = 0) {
        self.enabled = enabled
        self.solo = solo
    }

    /// Przycisk kategorii świeci, gdy kategoria jest ZABLOKOWANA (bit wygaszony).
    public func isLocked(_ category: G2MutatorCategory) -> Bool {
        effective & category.rawValue == 0
    }

    public func isSolo(_ category: G2MutatorCategory) -> Bool {
        solo & category.rawValue != 0
    }

    public mutating func toggleLock(_ category: G2MutatorCategory) {
        enabled ^= category.rawValue
    }

    public mutating func toggleSolo(_ category: G2MutatorCategory) {
        solo ^= category.rawValue
    }

    /// Maska, która faktycznie decyduje — solo bije zwykłe blokady.
    public var effective: UInt8 {
        solo == 0 ? enabled : solo
    }

    /// Czy wolno ruszyć parametr tej kategorii. `nil` = parametr bez kategorii:
    /// wolno, dopóki żadne solo nie jest włączone.
    public func allows(_ category: G2MutatorCategory?) -> Bool {
        guard let category else { return solo == 0 }
        return effective & category.rawValue != 0
    }
}

// MARK: - Genom patcha

/// Opis „co w tym patchu w ogóle jest parametrem" — lista wszystkich parametrów
/// wszystkich modułów, najpierw obszar Voice, potem FX, w kolejności numerów
/// modułów. Ta sama kolejność, w której chodzi Module Id Iterator oryginału,
/// więc i rysunek chromosomu wychodzi taki sam.
public struct G2MutatorGenome: Sendable {
    public struct Gene: Sendable {
        public let area: PatchArea
        public let moduleID: Int
        public let paramIndex: Int
        public let maxValue: Int
        /// Kategoria Quick Lock albo `nil`, gdy parametr do żadnej nie należy.
        public let category: G2MutatorCategory?
        /// Krzywa losowania z klasy parametru (`G2ParamClass`).
        public let curve: G2ParamClass.Curve
        /// Czy moduł jest wyłączony z mutacji (`Exclude From Mutations`).
        public let moduleExcluded: Bool
        /// Moduł wyłączony z mutacji ręcznie, nie z góry (wejścia/wyjścia, MIDI…).
        /// Taki moduł zostaje w patchu taki, jak go słychać — kratka nie przywraca
        /// jego stanu sprzed zmiany (`G2Mutator.keepingHeldModules`).
        public let moduleHeld: Bool
        /// Tylko `FreqCoarse` oscylatora: klucz jego `FreqMode`. Randomize sprawdza,
        /// czy oscylator stoi w trybie Partials — wtedy losuje z górnej części skali.
        public let freqModeKey: G2Individual.Key?
        /// Grupa brzmieniowa — suwak „Profile & Groups", który ten parametr słucha.
        public let group: G2MutatorGroup
        /// Ile stanów ma przycisk albo selektor; `nil` dla gałek i pól liczbowych.
        /// Stąd wiadomo, które parametry potrafią się zmieniać tylko skokiem —
        /// „Smooth" na osi Amount trzyma je na wartości Mother (`G2SmoothAxis`).
        public let discreteStates: Int?

        /// Czy mutator w ogóle wolno ruszać ten parametr — klasa parametru z listy
        /// wyciętych w `IsEnabled` (przełączniki, `Kbt`, `Active`, tryby wyjścia…)
        /// dostaje krzywą `.none`. Selektory fal i typów filtra są w oryginale
        /// liniowe, więc mutują się tak samo jak gałki.
        public var isMutable: Bool {
            curve != .none
        }

        public var key: G2Individual.Key {
            G2Individual.Key(area: area, moduleID: moduleID, paramIndex: paramIndex)
        }
    }

    public let genes: [Gene]

    public init(patch: G2Patch) {
        var genes: [Gene] = []
        for area in [PatchArea.voice, PatchArea.fx] {
            for module in patch.modules(in: area).sorted(by: { $0.id < $1.id }) {
                let excluded = module.excludedFromMutation
                let held = excluded && !G2Module.isExcludedFromMutationByDefault(typeID: module.typeID)
                let classes = module.parameters.indices.map {
                    G2ParamClass.of(moduleTypeID: module.typeID, paramIndex: $0)
                }
                let freqModeKey = classes.firstIndex { $0?.rawValue == G2ParamClass.oscillatorFreqMode }
                    .map { G2Individual.Key(area: area, moduleID: module.id, paramIndex: $0) }
                for index in module.parameters.indices {
                    let maxValue = Self.maxValue(moduleTypeID: module.typeID, paramIndex: index)
                    let paramClass = classes[index]
                    let category = Self.category(of: module, paramIndex: index)
                    genes.append(Gene(
                        area: area,
                        moduleID: module.id,
                        paramIndex: index,
                        maxValue: max(1, maxValue),
                        category: category,
                        curve: maxValue > 0 ? paramClass?.curve ?? .none : .none,
                        moduleExcluded: excluded,
                        moduleHeld: held,
                        freqModeKey: paramClass?.rawValue == G2ParamClass.oscillatorCoarse ? freqModeKey : nil,
                        group: G2MutatorGroup.of(paramClass: paramClass, category: category),
                        discreteStates: G2ParameterText.buttonOptions(
                            moduleTypeID: module.typeID, paramIndex: index
                        )?.count
                    ))
                }
            }
        }
        self.genes = genes
    }

    /// Górna granica skali parametru — dziedzina losowania dla Mutate i Randomize.
    /// Kolejność źródeł ma znaczenie:
    ///
    /// 1. potwierdzony zakres sprzętowy, gdy baza go zna (`2-Out Dest` ma sześć
    ///    napisów, a sprzęt dwa stany);
    /// 2. liczba stanów przycisku albo selektora — stąd wiadomo, że krok `Evnt`
    ///    sekwencera ma dwa stany, a nie 128. Bez tego Randomize losował z pełnej
    ///    skali i zapalał krok w 127 przypadkach na 128, więc wszystkie kroki
    ///    wychodziły jednakowo włączone;
    /// 3. pełna skala gałki.
    static func maxValue(moduleTypeID: Int, paramIndex: Int) -> Int {
        if let range = ParameterRangeDatabase.range(moduleTypeID: moduleTypeID, codeRef: paramIndex) {
            return range.upperBound
        }
        if let options = G2ParameterText.buttonOptions(moduleTypeID: moduleTypeID, paramIndex: paramIndex) {
            return Swift.max(0, options.count - 1)
        }
        return 127
    }

    // MARK: Przypisanie kategorii

    /// Moduły grupy FX — kategoria `Effects`. Numery typów wprost z `IsEnabled`
    /// (0x0C, 0x3F, 0x59, 0x5E, 0x62, 0x76, 0x96, 0xA7, 0xC0); w naszej bazie to
    /// dokładnie strona „FX" razem z Compress (0x96).
    static let effectTypeIDs: Set<Int> = [0x0C, 0x3F, 0x59, 0x5E, 0x62, 0x76, 0x96, 0xA7, 0xC0]
    /// Moduły opóźnień — kategoria `Delays` (0xAC…0xB3, 0xB5, 0xB6). W naszej bazie
    /// to cała strona „Delay"; 0xB4 to FM Operator i słusznie tu nie należy.
    static let delayTypeIDs: Set<Int> = Set(0xAC ... 0xB3).union([0xB5, 0xB6])

    /// Kategoria Quick Lock — w tej samej kolejności co `IsEnabled`: najpierw typ
    /// modułu (`Effects`, `Delays`), potem klasa parametru (`G2ParamClass.category`).
    public static func category(of module: G2Module, paramIndex: Int) -> G2MutatorCategory? {
        if effectTypeIDs.contains(module.typeID) { return .effects }
        if delayTypeIDs.contains(module.typeID) { return .delays }
        return G2ParamClass.of(moduleTypeID: module.typeID, paramIndex: paramIndex)?.category
    }
}

// MARK: - Osobnik

/// Jeden „dźwięk" mutatora — komplet wartości parametrów patcha. Trzymamy je pod
/// kluczem (obszar, moduł, parametr), a nie jako płaską tablicę, żeby dodanie albo
/// usunięcie modułu nie unieważniało zawartości magazynu.
public struct G2Individual: Hashable, Sendable {
    public struct Key: Hashable, Sendable {
        /// Obszar jak w protokole: 0 = FX, 1 = Voice, 2 = ustawienia patcha. Surowy
        /// numer, a nie `PatchArea`, bo dźwięk niesie też obszar 2 — gałki i źródła
        /// morfów, Glide, Bend, Vibrato, Arpeggiator, Octave Shift (tak samo
        /// `G2MorphAssignment.location`).
        public let location: UInt8
        public let moduleID: Int
        public let paramIndex: Int

        public init(location: UInt8, moduleID: Int, paramIndex: Int) {
            self.location = location
            self.moduleID = moduleID
            self.paramIndex = paramIndex
        }

        public init(area: PatchArea, moduleID: Int, paramIndex: Int) {
            self.init(location: area.rawValue, moduleID: moduleID, paramIndex: paramIndex)
        }

        /// Numer obszaru ustawień patcha.
        public static let settingsLocation: UInt8 = 2

        /// Klucz ustawienia patcha — adres z sekcji `0x4d`: numer grupy jest numerem
        /// modułu, pozycja w grupie numerem parametru (`G2PatchSetting`).
        public static func setting(module: Int, param: Int) -> Key {
            Key(location: settingsLocation, moduleID: module, paramIndex: param)
        }

        /// Obszar modułów albo `nil` dla ustawień patcha.
        public var area: PatchArea? {
            PatchArea(rawValue: location)
        }

        public var isSetting: Bool {
            location == Self.settingsLocation
        }
    }

    public var values: [Key: Double]
    /// Przypisania morfów dźwięku: parametr → (numer morfu → zakres). Trzymamy tylko
    /// zakresy niezerowe — zero znaczy „przypisania nie ma", tak jak w pliku i w
    /// urządzeniu. Osobnik może ich nieść **więcej niż 25** (Cross i Interpolate
    /// niczego nie przycinają, jak w oryginale); do 25 przycina dopiero zapis do
    /// wariacji albo do bufora odsłuchu (`G2Patch.apply`).
    public var morphs: [Key: [Int: Int]]

    public init(values: [Key: Double] = [:], morphs: [Key: [Int: Int]] = [:]) {
        self.values = values
        self.morphs = morphs
    }

    public var isEmpty: Bool {
        values.isEmpty
    }

    public subscript(key: Key) -> Double? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// Zakres morfu parametru — 0, gdy przypisania nie ma.
    public func morphRange(_ key: Key, morph: Int) -> Int {
        morphs[key]?[morph] ?? 0
    }

    /// Ustawia zakres; zero usuwa przypisanie.
    public mutating func setMorphRange(_ key: Key, morph: Int, range: Int) {
        if range == 0 {
            morphs[key]?[morph] = nil
            if morphs[key]?.isEmpty == true { morphs[key] = nil }
        } else {
            morphs[key, default: [:]][morph] = range
        }
    }

    /// Wszystkie przypisania w porządku klucza pliku (obszar, moduł, parametr, morf)
    /// — w tej kolejności oryginał kopiuje morfy i w tej kolejności przycina do 25.
    public var morphAssignments: [G2MorphAssignment] {
        morphs.flatMap { key, ranges in
            ranges.map { morph, range in
                G2MorphAssignment(location: key.location, moduleID: key.moduleID,
                                  paramIndex: key.paramIndex, morph: morph, range: range)
            }
        }.sorted { ($0.location, $0.moduleID, $0.paramIndex, $0.morph) < ($1.location, $1.moduleID, $1.paramIndex, $1.morph) }
    }
}

// MARK: - Kratki okna

/// Trzy rodzaje kratek okna mutatora — dokładnie `EMutaBoxType` oryginału
/// (0 rodzice i dzieci, 1 magazyn tymczasowy, 2 wariacje patcha).
public enum G2MutatorBoxKind: Int, Hashable, Sendable {
    case parents = 0
    case storage = 1
    case variations = 2
}

/// Adres jednej kratki — Muta Box Spec.
public struct G2MutatorBox: Hashable, Sendable {
    public let kind: G2MutatorBoxKind
    public let index: Int

    public init(_ kind: G2MutatorBoxKind, _ index: Int) {
        self.kind = kind
        self.index = index
    }

    public static let mother = G2MutatorBox(.parents, G2Mutator.motherIndex)
    public static let father = G2MutatorBox(.parents, G2Mutator.fatherIndex)
    public static func child(_ index: Int) -> G2MutatorBox {
        G2MutatorBox(.parents, index)
    }
}

// MARK: - Ustawienia

/// Prawdopodobieństwo, zasięg i sprzężenie `Link` — wszystkie trzy gałki górnego
/// paska okna. Domyślne wartości i krzywa sprzężenia wprost z oryginalnego edytora.
public struct G2MutatorSettings: Equatable, Sendable {
    /// Szansa, że dany parametr w ogóle zostanie ruszony (0…1).
    public private(set) var probability: Double
    /// Jak daleko wolno go przesunąć — ułamek pełnej skali parametru (0…0,5).
    public private(set) var range: Double
    /// Jak często kopiowanie w `Cross` przeskakuje na drugiego rodzica (0…1).
    public var crossProbability: Double
    /// Czy gałki prawdopodobieństwa i zasięgu chodzą razem. Oryginał startuje z `true`.
    public var link: Bool
    /// „Not silent" — dzieci, których wg `G2SilenceGuard` nic nie zagra, są losowane
    /// od nowa. Nasz dodatek, nie oryginału; domyślnie wyłączony (okno = oryginał).
    public var notSilent = false
    /// Czułość „Not silent" (0…1) — gałka obok przycisku. 0 = tylko dokładne zero
    /// zamyka zawór, wyżej za ciszę idą też wartości przy dole skali → `G2SilenceGuard.Strictness`.
    public var silenceSensitivity = 0.0

    public static let maxRange = 0.5

    /// Wartości z konstruktora Muta Synth Data: 0,3721 / 0,189 / 0,15.
    public init(probability: Double = 0.3721,
                range: Double = 0.189,
                crossProbability: Double = 0.15,
                link: Bool = true)
    {
        self.probability = min(1, max(0, probability))
        self.range = min(Self.maxRange, max(0, range))
        self.crossProbability = min(1, max(0, crossProbability))
        self.link = link
    }

    public mutating func setProbability(_ value: Double) {
        probability = min(1, max(0, value))
        if link { range = Self.range(fromProbability: probability) }
    }

    public mutating func setRange(_ value: Double) {
        range = min(Self.maxRange, max(0, value))
        if link { probability = Self.probability(fromRange: range) }
    }

    /// Muta Synth Data (SetMutationProbFromRange) — stałe 0,7 / 0,53 / −0,78 / 0,22
    /// jak w oryginalnym edytorze.
    public static func probability(fromRange range: Double) -> Double {
        let t = (sqrt(max(0, range)) - 0.7) / 0.53 * -0.78 + 0.22
        return min(1, max(0, t * t))
    }

    /// Muta Synth Data (SetMutationRangeFromProb) — dokładne odwrócenie powyższej.
    public static func range(fromProbability probability: Double) -> Double {
        let t = (sqrt(max(0, probability)) - 0.22) / 0.78 * -0.53 + 0.7
        return min(maxRange, max(0, t * t))
    }

    /// Odczyt procentowy taki, jak `Utils::FloatToStr((0,005 + v) × 100, 0)`.
    public static func percent(_ value: Double) -> Int {
        Int((value + 0.005) * 100)
    }
}

// MARK: - Panel „Mutation settings"

/// Ustawienia wysuwanego panelu. Działają WYŁĄCZNIE przy wysuniętym panelu — zwinięty
/// panel to okno Standard, czyli oryginał (reguła A → Docs/mutator/plan-ui §14).
public struct G2MutatorPanelSettings: Equatable, Sendable {
    /// Przyciski, które mogą losować z puli „Pool & Diversity". Interpolate nie losuje.
    public enum PoolOperation: String, CaseIterable, Sendable {
        case mutate = "Mutate"
        case randomize = "Randomize"
        case cross = "Cross"
    }

    /// „Only audible" — Mutate i Randomize nie ruszają parametrów, których nie słychać
    /// (`G2AudibilityMap`). Domyślnie zapalony (decyzja użytkownika 2026-09-17).
    public var onlyAudible: Bool
    /// „Pool & Diversity" — ilu kandydatów losujemy, żeby pokazać sześcioro najbardziej
    /// różnych; 0 = bez puli. Domyślnie 32 (decyzja użytkownika 2026-09-17).
    public var poolSize: Int
    /// Które przyciski korzystają z puli — domyślnie wszystkie trzy.
    public var poolOperations: Set<PoolOperation>
    /// „Profile & Groups" — ile Mutate i Randomize ruszają każdą grupę. Domyślnie pełne.
    public var groupWeights: G2MutatorGroupWeights
    /// „Anchors" — poprawki dziecka po wylosowaniu, przy wszystkich czterech przyciskach.
    /// Domyślnie pilnują tylko gałek (Knob assigned).
    public var anchors: G2MutatorAnchors
    /// „Amount axis" — skąd fader bierze cel. Domyślnie losowanie jak w Randomize.
    public var axisTarget: G2MutationAxis.Target
    /// „Family → Variations" — rozstaw ośmiu kratek na drodze Mother → cel. Domyślnie równy.
    public var familySpacing: G2FamilySpacing
    /// „Smooth" — grupy parametrów, które na osi Amount zostają jak w Mother, bo potrafią
    /// zmienić się tylko skokiem. Domyślnie żadna: oryginał zmienia wszystko.
    public var smoothAxis: G2SmoothAxis

    public static let poolSizes = [0, 16, 32, 64]

    public init(onlyAudible: Bool = true, poolSize: Int = 32,
                poolOperations: Set<PoolOperation> = Set(PoolOperation.allCases),
                groupWeights: G2MutatorGroupWeights = .full, anchors: G2MutatorAnchors = G2MutatorAnchors(),
                axisTarget: G2MutationAxis.Target = .random, familySpacing: G2FamilySpacing = .linear,
                smoothAxis: G2SmoothAxis = [])
    {
        self.onlyAudible = onlyAudible
        self.poolSize = poolSize
        self.poolOperations = poolOperations
        self.groupWeights = groupWeights
        self.anchors = anchors
        self.axisTarget = axisTarget
        self.familySpacing = familySpacing
        self.smoothAxis = smoothAxis
    }

    /// Jak zachowuje się oryginał — wszystko, co panel dodaje, wyłączone.
    public static let standard = G2MutatorPanelSettings(onlyAudible: false, poolSize: 0, anchors: .off)

    /// Ilu kandydatów losuje dany przycisk; `nil` = zwykłe sześcioro dzieci.
    public func pool(for operation: PoolOperation) -> Int? {
        poolSize > G2Mutator.childCount && poolOperations.contains(operation) ? poolSize : nil
    }

    /// Jedyne miejsce decyzji „jakie ustawienia obowiązują teraz".
    public func effective(panelOpen: Bool) -> G2MutatorPanelSettings {
        panelOpen ? self : .standard
    }
}

// MARK: - Mutator

public enum G2Mutator {
    /// Ilu potomków robi jedno naciśnięcie przycisku — tyle samo co w oryginale.
    public static let childCount = 6
    /// Ile kratek ma Temporary Storage (trzy rzędy po osiem).
    public static let storageCount = 24
    /// Ile kratek ma rząd rodziców i dzieci: 0…5 to dzieci, 6 Mother, 7 Father.
    public static let parentBoxCount = 8
    public static let motherIndex = 6
    public static let fatherIndex = 7

    // MARK: Zdjęcie patcha

    /// Parametry obszaru ustawień patcha (2) w kolejności adresów, tak jak chodzi po
    /// nich oryginał: moduł 1 to osiem gałek i osiem źródeł morfów, moduły 2…7 —
    /// arkusz Patch Settings (`G2PatchSetting`). Dźwięk niesie je obok Voice i FX:
    /// Cross i Interpolate je ruszają, Mutate i Randomize przepisują bez zmian
    /// (`CopyContext`). W chromosomie ich nie ma — rysunek bierze tylko moduły.
    public static let settingKeys: [G2Individual.Key] =
        (0 ..< 2 * G2Morph.count).map { G2Individual.Key.setting(module: morphSettingsModule, param: $0) }
            + G2PatchSetting.allCases.map { G2Individual.Key.setting(module: $0.module, param: $0.param) }

    /// Numer modułu gałek i źródeł morfów w obszarze ustawień patcha.
    public static let morphSettingsModule = 1

    /// Osobnik z bieżących wartości wariacji — tak powstaje zawartość kratki
    /// wariacji i punkt wyjścia każdej operacji.
    public static func individual(from patch: G2Patch, variation: Int, genome: G2MutatorGenome) -> G2Individual {
        var values: [G2Individual.Key: Double] = [:]
        values.reserveCapacity(genome.genes.count + settingKeys.count)
        var cache: [PatchArea: [Int: G2Module]] = [:]
        for area in [PatchArea.voice, PatchArea.fx] {
            cache[area] = Dictionary(uniqueKeysWithValues: patch.modules(in: area).map { ($0.id, $0) })
        }
        for gene in genome.genes {
            guard let module = cache[gene.area]?[gene.moduleID] else { continue }
            values[gene.key] = Double(value(of: module, paramIndex: gene.paramIndex, variation: variation))
        }
        if patch.variationSettings.indices.contains(variation) {
            for key in settingKeys {
                values[key] = Double(setting(of: patch, key: key, variation: variation))
            }
        }
        // Morfy jadą razem z dźwiękiem (`CopyMorphs`) — także te z obszaru ustawień.
        var morphs: [G2Individual.Key: [Int: Int]] = [:]
        for entry in patch.morphs(in: variation) where entry.range != 0 {
            if let area = entry.area, cache[area]?[entry.moduleID] == nil { continue }
            let key = G2Individual.Key(location: entry.location, moduleID: entry.moduleID,
                                       paramIndex: entry.paramIndex)
            morphs[key, default: [:]][entry.morph] = entry.range
        }
        return G2Individual(values: values, morphs: morphs)
    }

    /// Dźwięk z kratki z modułami wyłączonymi z mutacji ręcznie przepisanymi z `playing`
    /// — wartości i morfy. Kratka pamięta dźwięk z chwili powstania, więc bez tego taki
    /// moduł wracał do stanu z Mother: Power zgaszony po zrobieniu Mother zapalał się
    /// przy następnym Mutate. Oryginał robi tak samo; to nasza poprawka.
    ///
    /// Moduły wyłączone z góry jadą dalej z dźwiękiem kratki — `2-Out` potrafi mieć
    /// w każdej wariacji inne wyjście, a wariacja przeciągnięta do Mother ma brzmieć
    /// dokładnie jak ona (#109).
    public static func keepingHeldModules(_ individual: G2Individual, from playing: G2Individual,
                                          genome: G2MutatorGenome) -> G2Individual
    {
        var result = individual
        for gene in genome.genes where gene.moduleHeld {
            result[gene.key] = playing[gene.key]
            result.morphs[gene.key] = playing.morphs[gene.key]
        }
        return result
    }

    /// Wartość ustawienia patcha spod klucza obszaru 2.
    static func setting(of patch: G2Patch, key: G2Individual.Key, variation: Int) -> Int {
        if key.moduleID == morphSettingsModule {
            return key.paramIndex < G2Morph.count
                ? patch.morphDial(key.paramIndex, in: variation)
                : patch.morphMode(key.paramIndex - G2Morph.count, in: variation)
        }
        guard let setting = G2PatchSetting.allCases.first(where: { $0.module == key.moduleID && $0.param == key.paramIndex })
        else { return 0 }
        return patch.variationSettings[variation][keyPath: setting.keyPath]
    }

    private static func value(of module: G2Module, paramIndex: Int, variation: Int) -> Int {
        if module.parameterVariations.indices.contains(variation),
           paramIndex < module.parameterVariations[variation].count
        {
            return module.parameterVariations[variation][paramIndex]
        }
        return paramIndex < module.parameters.count ? module.parameters[paramIndex] : 0
    }

    // MARK: Mutate

    /// Sześcioro dzieci jednego rodzica — przycisk `Mutate`.
    public static func mutate(parent: G2Individual, genome: G2MutatorGenome,
                              settings: G2MutatorSettings, locks: G2MutatorLocks,
                              audibility: G2AudibilityMap? = nil, groups: G2MutatorGroupWeights = .full,
                              using generator: inout some RandomNumberGenerator) -> [G2Individual]
    {
        (0 ..< childCount).map { _ in
            mutateOnce(parent: parent, genome: genome, settings: settings, locks: locks,
                       audibility: audibility, groups: groups, using: &generator)
        }
    }

    /// Jedno dziecko: kopia rodzica z drgniętymi parametrami. `CopyMutateContext`.
    /// Waga grupy skraca zasięg kroku; przy pełnych wagach losowania są te same co bez panelu.
    public static func mutateOnce(parent: G2Individual, genome: G2MutatorGenome,
                                  settings: G2MutatorSettings, locks: G2MutatorLocks,
                                  audibility: G2AudibilityMap? = nil, groups: G2MutatorGroupWeights = .full,
                                  using generator: inout some RandomNumberGenerator) -> G2Individual
    {
        var child = parent
        for gene in genome.genes {
            guard let base = parent[gene.key] else { continue }
            guard isEnabled(gene, locks: locks, audibility: audibility) else { continue }
            let weight = groups[gene.group]
            guard weight > 0 else { continue }
            guard Double.random(in: 0 ..< 1, using: &generator) < settings.probability else { continue }
            let moved = applyCurve(gene.curve, max: gene.maxValue, value: base, range: settings.range * weight,
                                   using: &generator)
            child[gene.key] = reflect(moved, max: Double(gene.maxValue))
        }
        return child
    }

    // MARK: Randomize

    /// Sześcioro dzieci o wartościach losowanych od zera — przycisk `Randomize`.
    /// Parametry zablokowane (kategorią albo modułem) przepisujemy z osobnika,
    /// który miał focus — tak samo jak `CopyRandomizeContext`.
    public static func randomize(base: G2Individual, genome: G2MutatorGenome,
                                 locks: G2MutatorLocks, audibility: G2AudibilityMap? = nil,
                                 groups: G2MutatorGroupWeights = .full,
                                 using generator: inout some RandomNumberGenerator) -> [G2Individual]
    {
        (0 ..< childCount).map { _ in
            var child = base
            for gene in genome.genes where isEnabled(gene, locks: locks, audibility: audibility) {
                guard let old = base[gene.key] else { continue }
                // Waga grupy: 0 = wartość zostaje, pośrednia = tyle drogi do losowej wartości.
                let weight = groups[gene.group]
                guard weight > 0 else { continue }
                let random = randomValue(for: gene, base: base, using: &generator)
                child[gene.key] = weight < 1 ? old + (random - old) * weight : random
            }
            return child
        }
    }

    /// Jedna losowa wartość parametru z całej skali, tą samą krzywą co Mutate:
    /// oryginał woła `ApplyCurve(typ, maks, −1, −1)`, a ujemna wartość wchodzi
    /// gałęzią „losuj równomiernie `0…maks + 0,999`, potem krzywa odwrotna". Krótkie
    /// czasy i słabe FM wypadają więc częściej niż długie. Wynik jest **przycięty**
    /// do skali, nie odbity — tak robi Randomize w oryginale.
    ///
    /// Wyjątek: `FreqCoarse` oscylatora w trybie **Partials** losuje wyłącznie
    /// z górnej części skali (49…127, najczęściej wokół 64), żeby nie wypadały
    /// absurdalnie niskie numery harmonicznych.
    public static func randomValue(for gene: G2MutatorGenome.Gene, base: G2Individual,
                                   using generator: inout some RandomNumberGenerator) -> Double
    {
        let random = Double.random(in: 0 ..< 1, using: &generator)
        let maxValue = Double(gene.maxValue)
        let raw: Double = if let modeKey = gene.freqModeKey,
                             let mode = base[modeKey], Int(mode) == G2ParamClass.partialsMode
        {
            partialsCoarse(random, max: gene.maxValue)
        } else {
            warp(random * (maxValue + 0.999), curve: gene.curve, max: gene.maxValue, inverse: true)
        }
        // Obcinamy w dół, nie zaokrąglamy. Zapas `+0,999` w losowaniu jest po to,
        // żeby każda wartość całkowita `0…maks` miała przedział tej samej szerokości
        // — ale tylko przy obcinaniu. Zaokrąglanie robi z dolnego przedziału połowę
        // szerokości, a z górnego półtorej: przy skali 0…127 przesunięcie o pół kroku
        // jest niewidoczne, przy przycisku o dwóch stanach dawało 75 % „włączony".
        return Swift.min(maxValue, Swift.max(0, raw)).rounded(.down)
    }

    /// Losowy `FreqCoarse` dla trybu Partials: dolna granica to 49 przeniesione do
    /// dziedziny krzywej `(−5, −2)`, losowanie równomierne od niej do końca skali,
    /// powrót krzywą `(5, 2)`.
    static func partialsCoarse(_ random: Double, max maxValue: Int) -> Double {
        let lowest = dualCurve(low: -5, high: -2, 49, max: 127)
        let picked = lowest + random * (Double(maxValue) - lowest + 0.999)
        return dualCurve(low: 5, high: 2, picked, max: maxValue)
    }

    // MARK: Interpolate

    /// Sześcioro dzieci po drodze z Mother do Father — dziecko `i` w (i+1)/7 drogi
    /// (`GetInterpolatedChildrenMolecules`: `(i + 1) / 7`).
    ///
    /// **Blokady tu nie działają** i tak jest w oryginale: interpolacja musi ruszyć
    /// każdy parametr, żeby przejście było płynne. Parametry o tej samej wartości
    /// u obojga rodziców i tak zostają bez zmian.
    ///
    /// Zakresy morfów też się uśredniają (`InterpolateContext`): brak przypisania
    /// liczy się jako 0, wynik obcina się w stronę zera, a zero znaczy „bez morfu".
    /// Limitu 25 nikt tu nie pilnuje — dziecko może mieć sumę morfów obojga rodziców.
    /// Ustawienia patcha (obszar 2) idą tą samą drogą co parametry modułów.
    public static func interpolate(mother: G2Individual, father: G2Individual,
                                   genome: G2MutatorGenome) -> [G2Individual]
    {
        (0 ..< childCount).map { index in
            blend(mother: mother, father: father, t: (Double(index) + 1.0) / 7.0, genome: genome)
        }
    }

    /// Jeden punkt drogi Mother → Father: `t` = 0 to Mother, 1 to Father. Wspólne dla
    /// Interpolate i fadera „Amount axis".
    public static func blend(mother: G2Individual, father: G2Individual, t: Double,
                             genome: G2MutatorGenome) -> G2Individual
    {
        var child = mother
        for key in genome.genes.map(\.key) + settingKeys {
            guard let a = mother[key], let b = father[key] else { continue }
            child[key] = a + (b - a) * t
        }
        child.morphs = [:]
        for key in Set(mother.morphs.keys).union(father.morphs.keys) {
            for morph in 0 ..< G2Morph.count {
                let a = Double(mother.morphRange(key, morph: morph))
                let b = Double(father.morphRange(key, morph: morph))
                child.setMorphRange(key, morph: morph, range: Int(a + (b - a) * t))
            }
        }
        return child
    }

    // MARK: Cross

    /// Sześcioro dzieci ze skrzyżowania dwojga rodziców — `RecombineContext`.
    /// Kopiowanie zaczyna od losowo wybranego rodzica i po KAŻDYM parametrze
    /// przeskakuje na drugiego z prawdopodobieństwem `crossProbability`.
    /// Żadnych losowych zmian wartości — dziecko dostaje wyłącznie wartości rodziców.
    /// Przypisania morfów parametru idą **razem z jego wartością**, od tego samego
    /// rodzica; nikt nie liczy, czy nie wyszło ich więcej niż 25. Ustawienia patcha
    /// (obszar 2) krzyżują się osobnym przebiegiem z własnym losowym startem — oryginał
    /// woła `RecombineContext` dla każdego obszaru z osobna.
    public static func cross(mother: G2Individual, father: G2Individual,
                             genome: G2MutatorGenome, settings: G2MutatorSettings,
                             using generator: inout some RandomNumberGenerator) -> [G2Individual]
    {
        (0 ..< childCount).map { _ in
            var child = mother
            recombine(genome.genes.map(\.key), into: &child, mother: mother, father: father,
                      probability: settings.crossProbability, using: &generator)
            recombine(settingKeys, into: &child, mother: mother, father: father,
                      probability: settings.crossProbability, using: &generator)
            return child
        }
    }

    /// `RecombineContext` dla jednej listy parametrów.
    private static func recombine(_ keys: [G2Individual.Key], into child: inout G2Individual,
                                  mother: G2Individual, father: G2Individual, probability: Double,
                                  using generator: inout some RandomNumberGenerator)
    {
        var fromFather = Bool.random(using: &generator)
        for key in keys {
            let source = fromFather ? father : mother
            if let value = source[key] {
                child[key] = value
                child.morphs[key] = source.morphs[key]
            }
            if Double.random(in: 0 ..< 1, using: &generator) < probability {
                fromFather.toggle()
            }
        }
    }

    // MARK: Reguły

    /// Muta Synth Data (IsEnabled) — czy wolno ruszyć ten parametr.
    public static func isEnabled(_ gene: G2MutatorGenome.Gene, locks: G2MutatorLocks) -> Bool {
        guard gene.isMutable, !gene.moduleExcluded else { return false }
        return locks.allows(gene.category)
    }

    /// Jak wyżej, a przy „Only audible" (mapa podana) także bez parametrów, których nie słychać.
    public static func isEnabled(_ gene: G2MutatorGenome.Gene, locks: G2MutatorLocks,
                                 audibility: G2AudibilityMap?) -> Bool
    {
        isEnabled(gene, locks: locks) && audibility?.isAudible(gene.key) != false
    }

    // MARK: Krzywe losowania

    /// `ApplyCurve` — jeden krok mutacji wybraną krzywą. Liniowa losuje wprost
    /// (`applyCurve1`); wykładnicze przenoszą oba końce przedziału
    /// `wartość ± maks × zasięg` do dziedziny krzywej, losują tam równomiernie
    /// i wracają krzywą odwrotną. Dzięki temu krótki atak drga o ułamki, długi —
    /// o dziesiątki, a strój wokół środka skali trzyma się środka. Każda krzywa
    /// pobiera dokładnie jedną liczbę losową, więc geny liniowe dostają te same
    /// losowania co przed dodaniem krzywych.
    public static func applyCurve(_ curve: G2ParamClass.Curve, max maxValue: Int, value: Double,
                                  range: Double, using generator: inout some RandomNumberGenerator) -> Double
    {
        guard curve.isExponential else {
            return applyCurve1(max: maxValue, value: value, range: range, using: &generator)
        }
        let step = Double(maxValue) * range
        let low = warp(value - step, curve: curve, max: maxValue, inverse: false)
        let high = warp(value + step, curve: curve, max: maxValue, inverse: false)
        let picked = low + (high - low) * Double.random(in: 0 ..< 1, using: &generator)
        return warp(picked, curve: curve, max: maxValue, inverse: true)
    }

    /// `ApplyCurve1` — krzywa liniowa, jedyna, której oryginał używa dla mutacji
    /// bez wskazanej krzywej wykładniczej:
    /// `nowa = stara + 2 × zasięg × (maks + 0,999) × (los01 − 0,5)`.
    public static func applyCurve1(max maxValue: Int, value: Double, range: Double,
                                   using generator: inout some RandomNumberGenerator) -> Double
    {
        let span = Double(maxValue) + 0.999
        return value + 2 * range * span * (Double.random(in: 0 ..< 1, using: &generator) - 0.5)
    }

    /// Przejście do dziedziny krzywej (`inverse == false`) albo z niej z powrotem
    /// (`inverse == true`). Wykładniki oryginału: ±1,5 dla krzywych jednostronnych,
    /// ±2 dla dwustronnej; przeciwny znak daje krzywą dokładnie odwrotną.
    public static func warp(_ value: Double, curve: G2ParamClass.Curve, max maxValue: Int, inverse: Bool) -> Double {
        switch curve {
        case .none, .linear:
            return value
        case .oneSided:
            return singleCurve(inverse ? 1.5 : -1.5, value, max: maxValue)
        case .oneSidedInverse:
            return singleCurve(inverse ? -1.5 : 1.5, value, max: maxValue)
        case .twoSided:
            let power = inverse ? 2.0 : -2.0
            return dualCurve(low: power, high: power, value, max: maxValue)
        }
    }

    /// Wykładnik potęgi z parametru krzywej: `p + 1` dla dodatniego,
    /// `−1 / (p − 1)` dla ujemnego — para wzajemnie odwrotna (1,5 → 2,5; −1,5 → 0,4).
    private static func exponent(_ power: Double) -> Double {
        power >= 0 ? power + 1 : -1 / (power - 1)
    }

    /// `ApplySingleCurve` — potęga na skali `0…maks + 0,99`. Wartość ujemna
    /// przechodzi przez krzywą jako odbicie lustrzane, żeby przedział wystający
    /// poniżej zera zachował ciągłość (o krawędź odbija dopiero `reflect`).
    public static func singleCurve(_ power: Double, _ value: Double, max maxValue: Int) -> Double {
        guard value >= 0 else { return -singleCurve(power, -value, max: maxValue) }
        let span = Double(maxValue) + 0.99
        return pow(value / span, exponent(power)) * span
    }

    /// `ApplyDualCurve` — potęga liczona od środka skali osobno w dół (`low`)
    /// i w górę (`high`); środek zostaje na miejscu.
    public static func dualCurve(low: Double, high: Double, _ value: Double, max maxValue: Int) -> Double {
        let span = Double(maxValue) + 0.99
        let offset = (value - span * 0.5) * 2 / span
        let scaled: Double = if offset > 0 {
            pow(offset, exponent(high)) + 1
        } else if offset < 0 {
            1 - pow(-offset, exponent(low))
        } else {
            1
        }
        return 0.5 * scaled * span
    }

    /// Odbicie od krawędzi zakresu zamiast przycięcia — jak w `CopyMutateContext`.
    /// Powtarzane, bo przy dużym zasięgu jedno odbicie może wyrzucić poza drugą krawędź.
    public static func reflect(_ value: Double, max maxValue: Double) -> Double {
        var result = value
        var guardCount = 0
        while result < 0 || result > maxValue, guardCount < 16 {
            if result < 0 { result = -result }
            if result > maxValue { result = maxValue - (result - maxValue) }
            guardCount += 1
        }
        return Swift.max(0, Swift.min(maxValue, result))
    }

    // MARK: Chromosom

    /// Punkt rysunku chromosomu w układzie bez skali — `DrawChromosome` liczy je
    /// żółwiem: bajty parametrów idą parami, pierwszy z pary skręca, drugi robi krok.
    public struct ChromosomePoint: Equatable, Sendable {
        public let x: Double
        public let y: Double
    }

    /// Krzywa, którą oryginał rysuje w każdej kratce. Bierze WSZYSTKIE parametry
    /// wszystkich modułów (nie tylko te, które mutator rusza) — najpierw obszar
    /// Voice, potem FX, każdy poprzedzony zerem, tak jak dwa wywołania
    /// `MakeParamArray`.
    public static func chromosome(of individual: G2Individual, genome: G2MutatorGenome) -> [ChromosomePoint] {
        var bytes: [Int] = []
        bytes.reserveCapacity(genome.genes.count + 2)
        var lastArea: PatchArea?
        for gene in genome.genes {
            if gene.area != lastArea {
                bytes.append(0)
                lastArea = gene.area
            }
            guard let value = individual[gene.key] else { continue }
            bytes.append(Int(value + 1.0))
        }
        return walk(bytes)
    }

    /// Żółw z `DrawChromosome`: bajty idą parami — pierwszy z pary skręca o
    /// `bajt − 0x3F` stopni, drugi robi krok o długości `bajt`. Drzewo ewolucji
    /// podaje tu bajty wprost ze swojej tabeli (`G2MutatorTree.chromosome`).
    static func walk(_ bytes: [Int]) -> [ChromosomePoint] {
        guard bytes.count > 1 else { return [] }

        var points: [ChromosomePoint] = []
        points.reserveCapacity(bytes.count + 1)
        var angle = 0
        var x = 0.0
        var y = 0.0
        for (index, byte) in bytes.enumerated() {
            points.append(ChromosomePoint(x: x, y: y))
            if index.isMultiple(of: 2) {
                angle += byte - 0x3F
            } else {
                x += Double(byte) * cosDegrees(angle)
                y += Double(byte) * cosDegrees(angle - 90)
            }
        }
        points.append(ChromosomePoint(x: x, y: y))
        return points
    }

    /// To samo dla wariacji patcha — bez budowania słownika, bo kratki wariacji
    /// odświeżają się przy każdym ruchu gałki.
    public static func chromosome(of patch: G2Patch, variation: Int,
                                  genome: G2MutatorGenome) -> [ChromosomePoint]
    {
        var bytes: [Int] = []
        bytes.reserveCapacity(genome.genes.count + 2)
        var cache: [PatchArea: [Int: G2Module]] = [:]
        for area in [PatchArea.voice, PatchArea.fx] {
            cache[area] = Dictionary(uniqueKeysWithValues: patch.modules(in: area).map { ($0.id, $0) })
        }
        var lastArea: PatchArea?
        for gene in genome.genes {
            if gene.area != lastArea {
                bytes.append(0)
                lastArea = gene.area
            }
            guard let module = cache[gene.area]?[gene.moduleID] else { continue }
            bytes.append(value(of: module, paramIndex: gene.paramIndex, variation: variation) + 1)
        }
        return walk(bytes)
    }

    /// Tablica `fCosLookupData` oryginału: `cos(i × π / 180)` dla 360 wpisów,
    /// czytana pod `abs(kąt % 360)` — a `cos(−a) = cos(a)`, więc to zwykły cosinus.
    private static func cosDegrees(_ degrees: Int) -> Double {
        var index = degrees % 360
        if index < 0 { index = -index }
        return Foundation.cos(Double(index) * .pi / 180)
    }

    /// Ile kratki zajmuje rysunek — `DOUBLE_00289cf8` z `DrawChromosome`.
    public static let chromosomeFill = 0.9
}

// MARK: - Przykładanie osobnika do patcha

/// Co zapis osobnika faktycznie zmienił w wariacji — dzwoniący wysyła dokładnie
/// tyle komend, ile trzeba.
public struct G2IndividualChanges {
    public var parameters: [(area: PatchArea, moduleID: Int, paramIndex: Int, value: Int)] = []
    /// Ustawienia patcha (obszar 2) po zmianie: (moduł, parametr, wartość).
    public var settings: [(moduleID: Int, paramIndex: Int, value: Int)] = []
    /// Przypisania morfów po zmianie; zakres 0 znaczy „przypisanie zdjęte".
    public var morphs: [G2MorphAssignment] = []

    public init() {}
}

public extension G2Patch {
    /// Wpisuje wartości i morfy osobnika do wskazanej wariacji — parametry modułów
    /// i ustawienia patcha (obszar 2).
    ///
    /// Morfy wariacji są **wymieniane** na morfy osobnika, jak w `CopyMorphs`
    /// oryginału: w porządku klucza (obszar, moduł, parametr, morf) i najwyżej
    /// **pierwsze 25** — reszta po cichu przepada, dokładnie tak, jak u Clavii.
    @discardableResult
    mutating func apply(_ individual: G2Individual, variation: Int) -> G2IndividualChanges {
        var changes = G2IndividualChanges()
        var present: [PatchArea: [Int: Int]] = [:]
        for area in [PatchArea.voice, PatchArea.fx] {
            for module in modules(in: area) {
                present[area, default: [:]][module.id] = module.parameters.count
                for paramIndex in module.parameters.indices {
                    let key = G2Individual.Key(area: area, moduleID: module.id, paramIndex: paramIndex)
                    guard let raw = individual[key] else { continue }
                    let rounded = max(0, min(127, Int(raw.rounded())))
                    let old = module.parameterVariations.indices.contains(variation)
                        ? module.parameterVariations[variation][paramIndex]
                        : module.parameters[paramIndex]
                    guard old != rounded else { continue }
                    setParameter(moduleID: module.id, paramIndex: paramIndex,
                                 value: rounded, in: area, variation: variation)
                    changes.parameters.append((area, module.id, paramIndex, rounded))
                }
            }
        }
        if variationSettings.indices.contains(variation) {
            for key in G2Mutator.settingKeys {
                guard let raw = individual[key] else { continue }
                let rounded = max(0, min(127, Int(raw.rounded())))
                guard G2Mutator.setting(of: self, key: key, variation: variation) != rounded else { continue }
                setSetting(key: key, value: rounded, variation: variation)
                changes.settings.append((key.moduleID, key.paramIndex,
                                         G2Mutator.setting(of: self, key: key, variation: variation)))
            }
        }
        guard morphAssignments.indices.contains(variation) else { return changes }

        let settingKeys = Set(G2Mutator.settingKeys)
        let incoming = individual.morphAssignments.filter { entry in
            guard let area = entry.area else {
                return settingKeys.contains(.setting(module: entry.moduleID, param: entry.paramIndex))
            }
            guard let count = present[area]?[entry.moduleID] else { return false }
            return entry.paramIndex < count
        }.prefix(G2Morph.maxAssignmentsPerVariation)
        let old = morphAssignments[variation]

        let same = { (a: G2MorphAssignment, b: G2MorphAssignment) in
            a.location == b.location && a.moduleID == b.moduleID
                && a.paramIndex == b.paramIndex && a.morph == b.morph
        }
        for entry in old {
            if let new = incoming.first(where: { same($0, entry) }) {
                if new.range != entry.range { changes.morphs.append(new) }
            } else {
                var cleared = entry
                cleared.range = 0
                changes.morphs.append(cleared)
            }
        }
        changes.morphs += incoming.filter { new in !old.contains { same($0, new) } }

        morphAssignments[variation] = Array(incoming)
        return changes
    }

    /// Wpisuje ustawienie patcha spod klucza obszaru 2. Źródło morfu przycina się do
    /// swoich pozycji (0…1, dla morfu 5 do 0…2), jak przy ręcznej zmianie.
    private mutating func setSetting(key: G2Individual.Key, value: Int, variation: Int) {
        if key.moduleID == G2Mutator.morphSettingsModule {
            if key.paramIndex < G2Morph.count {
                setMorphDial(key.paramIndex, in: variation, value: value)
            } else {
                setMorphMode(key.paramIndex - G2Morph.count, in: variation, value: value)
            }
            return
        }
        guard let setting = G2PatchSetting.allCases.first(where: { $0.module == key.moduleID && $0.param == key.paramIndex })
        else { return }
        variationSettings[variation][keyPath: setting.keyPath] = value
    }
}
