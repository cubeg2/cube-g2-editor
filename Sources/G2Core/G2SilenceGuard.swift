// G2SilenceGuard.swift
// „Not silent" — czy dziecko mutacji w ogóle ma szansę coś zagrać.
//
// W oryginalnym Mutatorze częste zjawisko: mutacja skręca poziom miksera na drodze do
// wyjścia i dziecka nie słychać. Strażnik odpowiada na to BEZ dźwięku, z samego patcha:
// szuka drogi kablami od źródła do modułu wyjścia (2-Out, 4-Out), na której żaden
// mikser nie ma zamkniętego wejścia (poziom `Lev…` albo przełącznik `On…` = 0).
//
// Reguły są celowo wąskie — lepiej przepuścić cichy dźwięk niż wyrzucić grający:
//   • źródło = moduł ze strony Osc (poza DXRouterem), moduł bez wejść sygnałowych
//     (LFO, obwiednia, Fx-In…) albo wyjście, które nie prowadzi sygnału dalej
//     (np. `Env` obwiedni — patrz `carriesSignal`);
//   • wejście sygnałowe = nazwa zaczyna się od „In" albo zawiera „Chain"; sterujące
//     (Pitch, Mod, FM…) nie prowadzą sygnału do wyjścia;
//   • zawór miksera: `LevN`/`OnN` dla wejścia N, `Lev`/`On` dla pojedynczego,
//     `LevMaster` dla wszystkich; `Chain` zawsze otwarte;
//   • zawór całego modułu (`moduleValves`): wzmacniacze ze strony Level (`LevAmp.Gain`,
//     `LevMod`/`ModAmt.ModDepth`) i poziom wyjściowy korektorów oraz filtrów, które
//     mają własny `Level`/`Lev`;
//   • domknięty dolnoprzepust (`lowPassFilters`): `Freq` przy dole skali. Pomijamy go,
//     gdy rezonans stoi przy samej górze (filtr wtedy sam gwiżdże) albo gdy któreś
//     wejście sterujące modułu ma kabel — modulacja może cutoff podnieść;
//   • głośność patcha (`Patch Volume`) przy dole skali wycisza wszystko.
// Kabel wejście→wejście przenosi sygnał ze źródła drugiego wejścia (sieć kabli).
//
// `Strictness` przesuwa próg wszystkich reguł naraz — to gałka obok przycisku
// „Not silent". Przy `.exact` (gałka na zerze) zamknięte jest tylko dokładne zero.
//
// Strażnik ocenia dziecko tylko wtedy, gdy rodzic sam „gra" wg tych reguł — inaczej
// patch jest poza tym, co reguły rozumieją, i nic nie odrzucamy → Docs/mutator/plan-engine §6.1.

import Foundation

public struct G2SilenceGuard {
    /// Jak nisko musi stać zawór, żeby uznać go za zamknięty. Jedna gałka („Not silent
    /// sensitivity") przesuwa oba progi naraz; przełączniki `On…` są zawsze zero-jedynkowe.
    public struct Strictness: Equatable, Sendable {
        /// Poziom `Lev…`/`Gain`/`Patch Volume` (0…127), przy którym zawór jest zamknięty.
        public let level: Int
        /// `Freq` dolnoprzepustu (0…127), przy którym filtr jest domknięty.
        public let cutoff: Int

        public init(level: Int, cutoff: Int) {
            self.level = max(0, level)
            self.cutoff = max(0, cutoff)
        }

        /// Tylko dokładne zero — tak strażnik działał od początku.
        public static let exact = Strictness(level: 0, cutoff: 0)

        /// Gałka 0…1. Górne progi dobrane ostrożnie: poziom 16/127 to już ledwie
        /// słyszalne tło, a cutoff 12/127 leży poniżej najniższej nuty klawiatury,
        /// więc nawet na maksimum nie wyrzucamy basów.
        public init(sensitivity: Double) {
            let amount = min(1, max(0, sensitivity))
            self.init(level: Int((amount * 16).rounded()), cutoff: Int((amount * 12).rounded()))
        }
    }

    private struct Node: Hashable {
        let area: PatchArea
        let module: Int
        let isOutput: Bool
        let index: Int
    }

    private struct Entry {
        let module: G2Module
        let def: ModuleDef
    }

    private let modules: [PatchArea: [Int: Entry]]
    /// Wejście → wyjścia, z których do niego płynie sygnał (przez całą sieć kabli).
    private let sources: [Node: [Node]]
    private let sinks: [Node]
    private let strictness: Strictness
    /// Zawory głośności na drodze do wyjścia: parametr → +1, gdy wyżej znaczy głośniej,
    /// −1, gdy niżej znaczy głośniej (atak obwiedni, cutoff górnoprzepustu), 0 dla wyboru
    /// przełącznika, którędy idzie dźwięk (zostaje jak w rodzicu) → `protect`.
    public private(set) var loudnessValves: [G2Individual.Key: Double] = [:]

    private static let sinkTypes: Set<String> = ["2-Out", "4-Out"]

    public init(patch: G2Patch, strictness: Strictness = .exact) {
        self.strictness = strictness
        var modules: [PatchArea: [Int: Entry]] = [:]
        var links: [Node: [Node]] = [:]
        var sinks: [Node] = []
        for area in [PatchArea.voice, PatchArea.fx] {
            for module in patch.modules(in: area) {
                guard let def = ModuleDatabase.module(id: module.typeID) else { continue }
                modules[area, default: [:]][module.id] = Entry(module: module, def: def)
                if Self.sinkTypes.contains(def.shortName) {
                    sinks += def.inputs.indices.map { Node(area: area, module: module.id, isOutput: false, index: $0) }
                }
            }
            for cable in patch.cables(in: area) {
                let from = Node(area: area, module: cable.fromModule, isOutput: cable.sourceIsOutput,
                                index: cable.fromConnector)
                let to = Node(area: area, module: cable.toModule, isOutput: false, index: cable.toConnector)
                links[from, default: []].append(to)
                links[to, default: []].append(from)
            }
        }
        var sources: [Node: [Node]] = [:]
        for node in links.keys where !node.isOutput {
            var seen: Set<Node> = [node]
            var queue = [node]
            var outputs: [Node] = []
            while let current = queue.popLast() {
                if current.isOutput {
                    outputs.append(current)
                    continue // przez wyjście sygnał nie przechodzi na inne wejścia wstecz
                }
                for next in links[current] ?? [] where seen.insert(next).inserted {
                    queue.append(next)
                }
            }
            sources[node] = outputs
        }
        self.modules = modules
        self.sources = sources
        self.sinks = sinks
        loudnessValves = findLoudnessValves()
    }

    /// Czy dźwięk `individual` na pewno nic nie zagra wg reguł z nagłówka.
    public func isSilent(_ individual: G2Individual) -> Bool {
        let volume = G2Individual.Key.setting(module: G2PatchSetting.patchVolume.module,
                                              param: G2PatchSetting.patchVolume.param)
        if let value = individual[volume], Int(value.rounded()) <= strictness.level { return true }
        var memo: [Node: Bool] = [:]
        var visiting: Set<Node> = []
        return !sinks.contains { sink in
            (sources[sink] ?? []).contains { produces($0, individual, &memo, &visiting) }
        }
    }

    private func produces(_ output: Node, _ individual: G2Individual,
                          _ memo: inout [Node: Bool], _ visiting: inout Set<Node>) -> Bool
    {
        if let known = memo[output] { return known }
        guard let entry = modules[output.area]?[output.module],
              entry.def.outputs.indices.contains(output.index) else { return false }
        let outputName = entry.def.outputs[output.index].name
        if Self.isGenerator(entry.def) || !Self.carriesSignal(entry.def, outputName) {
            memo[output] = true
            return true
        }
        if hasClosedValve(entry, individual) || isClosedLowPass(entry, outputName, output, individual) {
            return false
        }
        guard visiting.insert(output).inserted else { return false } // pętla sprzężenia
        defer { visiting.remove(output) }
        var result = false
        for (index, input) in entry.def.inputs.enumerated() where Self.isSignal(input.name) {
            guard isOpen(entry, inputName: input.name, individual) else { continue }
            let node = Node(area: output.area, module: output.module, isOutput: false, index: index)
            if (sources[node] ?? []).contains(where: { produces($0, individual, &memo, &visiting) }) {
                result = true
                break
            }
        }
        // Fałsz policzony wewnątrz pętli zależy od miejsca, w którym ją przecięto —
        // zapamiętujemy tylko pewne „gra".
        if result { memo[output] = true }
        return result
    }

    private static func isGenerator(_ def: ModuleDef) -> Bool {
        (def.page == "Osc" && def.shortName != "DXRouter") || !def.inputs.contains { isSignal($0.name) }
    }

    private static func isSignal(_ name: String) -> Bool {
        name.hasPrefix("In") || name.contains("Chain")
    }

    /// Czy przez to wyjście da się iść w głąb patcha. Poza zwykłym „Out…" liczą się
    /// trzy wyjścia `FltMulti` — każde z nich niesie to, co filtr dostał na wejściu.
    private static let multiOutputs: Set<String> = ["LP", "BP", "HP"]

    private static func carriesSignal(_ def: ModuleDef, _ outputName: String) -> Bool {
        outputName.hasPrefix("Out") || (def.page == "Filter" && multiOutputs.contains(outputName))
    }

    // MARK: - Zawory całego modułu

    /// Moduł → parametry, których dół skali wycisza wszystko, co przez niego idzie.
    /// Nazwy zaczynające się od „On" to przełączniki: zamknięte dopiero przy zerze.
    private static let moduleValves: [String: [String]] = [
        "LevAmp": ["Gain"],
        "LevMod": ["ModDepth"],
        "ModAmt": ["ModDepth", "On"],
        "Eq2Band": ["Level"],
        "Eq3Band": ["Level"],
        "EqPeak": ["Level"],
        "FltVoice": ["Level"],
        "FltPhase": ["Level"],
        "FltComb": ["Lev"],
    ]

    private func hasClosedValve(_ entry: Entry, _ individual: G2Individual) -> Bool {
        guard let valves = Self.moduleValves[entry.def.shortName] else { return false }
        return valves.contains { isClosed(entry, param: $0, individual) }
    }

    /// Zamknięty zawór. Przełączniki (`On…`) znają tylko zero — próg gałki ich nie dotyczy,
    /// bo przy progu ≥ 1 zapalony przełącznik (wartość 1) wyszedłby jako zamknięty.
    private func isClosed(_ entry: Entry, param: String, _ individual: G2Individual) -> Bool {
        guard let index = entry.def.paramNames.firstIndex(of: param) else { return false }
        let limit = param.hasPrefix("On") ? 0 : strictness.level
        return value(entry, index, individual) <= limit
    }

    // MARK: - Domknięty dolnoprzepust

    private struct LowPass {
        let frequency: String
        var resonance: String?
        /// Parametr wyboru charakterystyki; 0 = dolnoprzepust → `FilterGraphGeometry.Kind`.
        var type: String?
        /// Gdy podane, reguła dotyczy tylko tego wyjścia.
        var output: String?
    }

    /// Filtry, którym `Freq` przy dole skali zamyka drogę. `FltVoice`, `FltComb`, `FltPhase`
    /// i `WahWah` świadomie pominięte — u nich niska częstotliwość nie oznacza ciszy.
    private static let lowPassFilters: [String: LowPass] = [
        "FltLP": LowPass(frequency: "Freq"),
        "FltClassic": LowPass(frequency: "Freq", resonance: "Res"),
        "FltMulti": LowPass(frequency: "Freq", resonance: "Res", output: "LP"),
        "FltNord": LowPass(frequency: "Freq", resonance: "Res", type: "FilterType"),
        "FltStatic": LowPass(frequency: "Freq", resonance: "Res", type: "FilterType"),
    ]

    /// Rezonans od tej wartości w górę — filtr sam gwiżdże, więc reguły nie stosujemy.
    private static let selfOscillation = 100

    private func isClosedLowPass(_ entry: Entry, _ outputName: String, _ output: Node,
                                 _ individual: G2Individual) -> Bool
    {
        guard let filter = Self.lowPassFilters[entry.def.shortName],
              filter.output == nil || filter.output == outputName,
              let frequency = entry.def.paramNames.firstIndex(of: filter.frequency),
              value(entry, frequency, individual) <= strictness.cutoff else { return false }
        if let type = filter.type,
           let index = entry.def.paramNames.firstIndex(of: type),
           value(entry, index, individual) != 0 { return false } // nie dolnoprzepust
        if let resonance = filter.resonance,
           let index = entry.def.paramNames.firstIndex(of: resonance),
           value(entry, index, individual) >= Self.selfOscillation { return false }
        return !hasControlCable(entry, output.area, output.module)
    }

    /// Kabel na wejściu sterującym (Pitch, FreqMod, Res…) może cutoff podnieść, więc
    /// przy takim kablu o domknięciu filtra nie orzekamy.
    private func hasControlCable(_ entry: Entry, _ area: PatchArea, _ module: Int) -> Bool {
        entry.def.inputs.enumerated().contains { index, input in
            !Self.isSignal(input.name)
                && sources[Node(area: area, module: module, isOutput: false, index: index)] != nil
        }
    }

    // MARK: - Zawory miksera

    private func isOpen(_ entry: Entry, inputName: String, _ individual: G2Individual) -> Bool {
        guard entry.def.page == "Mixer", !inputName.contains("Chain") else { return true }
        let number = inputName.dropFirst(2).prefix { $0.isNumber }
        var valves = ["LevMaster"]
        valves += number.isEmpty ? ["Lev", "On"] : ["Lev\(number)", "On\(number)"]
        return !valves.contains { isClosed(entry, param: $0, individual) }
    }

    // MARK: - Zawory głośności (gałka „Not silent" powyżej zera)

    /// Dziecko, w którym zawory głośności idą w stronę ciszy tylko o `1 − amount` drogi
    /// wylosowanej przez mutację; w stronę „głośniej" ruszają się swobodnie. Przy `amount`
    /// = 1 żaden zawór nie robi kroku w stronę ciszy, a reszta patcha mutuje normalnie.
    public func protect(_ child: G2Individual, parent: G2Individual, amount: Double) -> G2Individual {
        let keep = 1 - min(1, max(0, amount))
        guard keep < 1 else { return child }
        var result = child
        for (key, louder) in loudnessValves {
            guard let base = parent[key], let value = child[key] else { continue }
            if louder == 0 {
                // Przełącznik drogi: kierunku „głośniej" nie ma — od połowy gałki zostaje jak w rodzicu.
                if keep <= 0.5 { result[key] = base }
            } else if (value - base) * louder < 0 {
                result[key] = base + (value - base) * keep
            }
        }
        return result
    }

    private struct ModuleRef: Hashable {
        let area: PatchArea
        let module: Int
    }

    /// Parametry, których dół skali przycisza wszystko, co przez moduł idzie — zawory
    /// strażnika i poziomy generatorów, które potrafią zgasić same siebie.
    private static let louderUp: [String: [String]] = moduleValves.merging([
        "Clip": ["ClipLev"],
        "OscDual": ["SqrLevel", "SawLevel", "SubOctLevel"],
        "DrumSynth": ["MasterLevel", "SlaveLevel"],
    ]) { $0 + $1 }

    /// Obwiednie: atak w dół = głośniej (liczy się zawsze), reszta kształtu w górę —
    /// tylko gdy obwiednia sama jest na drodze albo steruje amplitudą (`amplitudeInputs`).
    private static let envelopeShape: [String: [String]] = [
        "EnvADSR": ["Decay", "Sustain"], "ModADSR": ["Decay", "Sustain"],
        "EnvAHD": ["Hold", "Decay"], "ModAHD": ["Hold", "Decay"],
        "EnvADDSR": ["Decay1", "Level1", "Decay2", "Level2"],
        "EnvD": ["Decay"], "EnvH": ["Hold"], "EnvADR": [],
    ]

    private static let amplitudeInputs: Set<String> = ["Mod", "AM"]

    /// Wstecz od wyjść po wejściach sygnałowych (bez względu na stan zaworów — mutacja może
    /// je otworzyć), potem obwiednie i bramki, które sterują modułami na tej drodze.
    private func findLoudnessValves() -> [G2Individual.Key: Double] {
        var valves: [G2Individual.Key: Double] = [
            .setting(module: G2PatchSetting.patchVolume.module, param: G2PatchSetting.patchVolume.param): 1,
        ]
        var used: [ModuleRef: Set<String>] = [:]
        var expanded: Set<ModuleRef> = []
        var queue = sinks
        var seen = Set(sinks)
        while let input = queue.popLast() {
            for output in sources[input] ?? [] {
                guard let entry = modules[output.area]?[output.module],
                      entry.def.outputs.indices.contains(output.index) else { continue }
                let ref = ModuleRef(area: output.area, module: output.module)
                let name = entry.def.outputs[output.index].name
                used[ref, default: []].insert(name)
                guard !Self.isGenerator(entry.def), Self.carriesSignal(entry.def, name),
                      expanded.insert(ref).inserted else { continue }
                for (index, port) in entry.def.inputs.enumerated() where Self.isSignal(port.name) {
                    let node = Node(area: output.area, module: output.module, isOutput: false, index: index)
                    if seen.insert(node).inserted { queue.append(node) }
                }
            }
        }

        func add(_ ref: ModuleRef, _ entry: Entry, _ param: String, _ louder: Double) {
            guard let index = entry.def.paramNames.firstIndex(of: param) else { return }
            valves[G2Individual.Key(area: ref.area, moduleID: ref.module, paramIndex: index)] = louder
        }
        func cabled(_ ref: ModuleRef, _ entry: Entry, _ input: String) -> Bool {
            guard let index = entry.def.inputs.firstIndex(where: { $0.name == input }) else { return false }
            return sources[Node(area: ref.area, module: ref.module, isOutput: false, index: index)] != nil
        }
        func addEnvelope(_ ref: ModuleRef, _ entry: Entry, wholeShape: Bool) {
            guard let shape = Self.envelopeShape[entry.def.shortName] else { return }
            add(ref, entry, "Attack", -1)
            guard wholeShape else { return }
            shape.forEach { add(ref, entry, $0, 1) }
            // Bramka z RndTrig: niskie prawdopodobieństwo = obwiednia prawie nie startuje.
            for (index, port) in entry.def.inputs.enumerated() where !Self.isSignal(port.name) {
                for source in sources[Node(area: ref.area, module: ref.module, isOutput: false, index: index)] ?? [] {
                    guard let trigger = modules[source.area]?[source.module],
                          trigger.def.shortName == "RndTrig" else { continue }
                    add(ModuleRef(area: source.area, module: source.module), trigger, "StepProb", 1)
                }
            }
        }

        // Przełącznik: wybór wejścia/wyjścia zostaje jak w rodzicu, włącznik się nie wyłącza.
        func addSwitch(_ ref: ModuleRef, _ entry: Entry) {
            add(ref, entry, "Sel", 0)
            add(ref, entry, "On", 1)
        }
        // Łańcuch sterowania amplitudą (np. gniazda replik: przełącznik → LevMult → VCA.Mod):
        // przez moduły Level, Mixer i Switch wstecz, przełączniki po drodze nie zmieniają wyboru.
        var visitedControl: Set<ModuleRef> = []
        func addControlSwitches(from ref: ModuleRef, depth: Int) {
            guard depth > 0, visitedControl.insert(ref).inserted,
                  let entry = modules[ref.area]?[ref.module],
                  ["Level", "Mixer", "Switch"].contains(entry.def.page) else { return }
            if entry.def.page == "Switch" {
                addSwitch(ref, entry)
            }
            for index in entry.def.inputs.indices {
                for source in sources[Node(area: ref.area, module: ref.module, isOutput: false, index: index)] ?? [] {
                    addControlSwitches(from: ModuleRef(area: source.area, module: source.module), depth: depth - 1)
                }
            }
        }

        for (ref, outputs) in used {
            guard let entry = modules[ref.area]?[ref.module] else { continue }
            let type = entry.def.shortName
            if entry.def.page == "Mixer" {
                for param in entry.def.paramNames
                    where param == "LevMaster" || param.range(of: "^(Lev|On)[0-9]*$", options: .regularExpression) != nil
                {
                    add(ref, entry, param, 1)
                }
            }
            if entry.def.page == "Switch" {
                addSwitch(ref, entry)
            }
            Self.louderUp[type]?.forEach { add(ref, entry, $0, 1) }
            if outputs.contains(where: { $0.hasPrefix("Out") }) {
                addEnvelope(ref, entry, wholeShape: true)
            }
            if let filter = Self.lowPassFilters[type], filter.output == nil || outputs == [filter.output!] {
                let lowPass = filter.type.flatMap { entry.def.paramNames.firstIndex(of: $0) }
                    .map { $0 < entry.module.parameters.count && entry.module.parameters[$0] == 0 } ?? true
                if lowPass { add(ref, entry, filter.frequency, 1) }
            }
            if type == "FltHP" || (type == "FltMulti" && outputs == ["HP"]) {
                add(ref, entry, "Freq", -1)
            }
            if type == "X-Fade" || type == "Fade2-1" {
                switch (cabled(ref, entry, "In1"), cabled(ref, entry, "In2")) {
                case (true, false): add(ref, entry, "Mix", -1)
                case (false, true): add(ref, entry, "Mix", 1)
                default: break
                }
            }
            // Obwiednie sterujące modułem na drodze: atak zawsze, cały kształt przy amplitudzie.
            for (index, port) in entry.def.inputs.enumerated() where !Self.isSignal(port.name) {
                for source in sources[Node(area: ref.area, module: ref.module, isOutput: false, index: index)] ?? [] {
                    let envelope = ModuleRef(area: source.area, module: source.module)
                    guard let envEntry = modules[source.area]?[source.module] else { continue }
                    addEnvelope(envelope, envEntry, wholeShape: Self.amplitudeInputs.contains(port.name))
                    if Self.amplitudeInputs.contains(port.name) {
                        addControlSwitches(from: envelope, depth: 4)
                    }
                }
            }
        }
        return valves
    }

    private func value(_ entry: Entry, _ index: Int, _ individual: G2Individual) -> Int {
        let key = G2Individual.Key(area: entry.module.area, moduleID: entry.module.id, paramIndex: index)
        if let raw = individual[key] { return Int(raw.rounded()) }
        return index < entry.module.parameters.count ? entry.module.parameters[index] : 1
    }
}
