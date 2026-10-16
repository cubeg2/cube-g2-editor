// G2AudibilityMap.swift
// „Only audible" — które parametry patcha w ogóle coś słychać.
//
// W typowym patchu duża część gałek nic nie robi, a mutowanie ich daje dzieci, które
// brzmią jak rodzic. Mapa odpowiada z samego patcha, bez dźwięku:
//   • moduł gra, gdy któreś jego wyjście prowadzi kablami (także przez wejścia sterujące
//     innych modułów) do modułu wyjścia 2-Out / 4-Out — szukanie wstecz od wyjść;
//   • moduł z `Active` = 0 nie gra i nie przekazuje dalej niczego;
//   • gałka siły modulacji (`FmAmount`, `PitchMod`, `ShapeMod`…) nic nie robi, gdy jej
//     wejście nie ma kabla.
// Celowo NIE uznajemy za głuche modułów za zamkniętym poziomem miksera: mutacja może ten
// poziom otworzyć, a wtedy zamrożone źródło byłoby niespodzianką. Tym zajmuje się
// „Not silent" (`G2SilenceGuard`). Moduł bez żadnego wyjścia (np. MIDI) liczy się jako
// grający — nie umiemy powiedzieć, że nic nie robi → Docs/mutator/plan-engine §6.

import MutatorCore

public struct G2AudibilityMap: Equatable, Sendable {
    public struct ModuleRef: Hashable, Sendable {
        public let area: PatchArea
        public let id: Int

        public init(area: PatchArea, id: Int) {
            self.area = area
            self.id = id
        }
    }

    private struct Node: Hashable {
        let area: PatchArea
        let module: Int
        let isOutput: Bool
        let index: Int
    }

    /// Moduły, których nie słychać — cały moduł „nic nie robi".
    public let silentModules: Set<ModuleRef>
    /// Gałki modulacji bez kabla na swoim wejściu (w modułach, które grają).
    public let deadParameters: Set<G2Individual.Key>

    private static let sinkTypes: Set<String> = ["2-Out", "4-Out"]

    /// `sound` daje wartości `Active` (np. Mother); bez niego — i dla parametru, którego
    /// w nim nie ma — bierzemy bieżącą wariację z modułu.
    public init(patch: G2Patch, sound: G2Individual? = nil) {
        var silent: Set<ModuleRef> = []
        var dead: Set<G2Individual.Key> = []
        for area in [PatchArea.voice, PatchArea.fx] {
            let modules = Dictionary(patch.modules(in: area).map { ($0.id, $0) }) { first, _ in first }
            var links: [Node: [Node]] = [:]
            for cable in patch.cables(in: area) {
                let from = Node(area: area, module: cable.fromModule, isOutput: cable.sourceIsOutput,
                                index: cable.fromConnector)
                let to = Node(area: area, module: cable.toModule, isOutput: false, index: cable.toConnector)
                links[from, default: []].append(to)
                links[to, default: []].append(from)
            }

            var audible: Set<Int> = []
            var queue: [Int] = []
            for module in modules.values {
                guard let def = ModuleDatabase.module(id: module.typeID) else {
                    audible.insert(module.id) // nieznany typ — nie oceniamy
                    continue
                }
                if Self.sinkTypes.contains(def.shortName) || def.outputs.isEmpty {
                    audible.insert(module.id)
                    queue.append(module.id)
                }
            }
            while let id = queue.popLast() {
                guard let module = modules[id], let def = ModuleDatabase.module(id: module.typeID),
                      Self.isActive(module, def: def, sound: sound) else { continue }
                for index in def.inputs.indices {
                    for source in Self.sources(of: Node(area: area, module: id, isOutput: false, index: index),
                                               links: links)
                        where audible.insert(source.module).inserted
                    {
                        queue.append(source.module)
                    }
                }
            }

            for module in modules.values {
                let ref = ModuleRef(area: area, id: module.id)
                guard let def = ModuleDatabase.module(id: module.typeID) else { continue }
                guard audible.contains(module.id), Self.isActive(module, def: def, sound: sound) else {
                    silent.insert(ref)
                    continue
                }
                for (param, input) in Self.modulationInputs[module.typeID] ?? [:] {
                    let node = Node(area: area, module: module.id, isOutput: false, index: input)
                    if Self.sources(of: node, links: links).isEmpty {
                        dead.insert(G2Individual.Key(area: area, moduleID: module.id, paramIndex: param))
                    }
                }
            }
        }
        silentModules = silent
        deadParameters = dead
    }

    public func isSilent(area: PatchArea, module: Int) -> Bool {
        silentModules.contains(ModuleRef(area: area, id: module))
    }

    /// Czy ruszenie parametru może być słyszalne. Ustawienia patcha — zawsze tak.
    public func isAudible(_ key: G2Individual.Key) -> Bool {
        guard let area = key.area else { return true }
        return !isSilent(area: area, module: key.moduleID) && !deadParameters.contains(key)
    }

    /// Waga słyszalności w języku silnika: 1 słychać, 0 nic nie robi.
    public func weight(_ address: ParameterAddress) -> Double {
        isAudible(address.key) ? 1 : 0
    }

    // MARK: - Graf

    /// Wyjścia, z których płynie sygnał do wejścia — przez całą sieć kabli
    /// (kabel wejście→wejście dzieli źródło).
    private static func sources(of input: Node, links: [Node: [Node]]) -> [Node] {
        var seen: Set<Node> = [input]
        var stack = [input]
        var outputs: [Node] = []
        while let current = stack.popLast() {
            if current.isOutput {
                outputs.append(current)
                continue
            }
            for next in links[current] ?? [] where seen.insert(next).inserted {
                stack.append(next)
            }
        }
        return outputs
    }

    private static func isActive(_ module: G2Module, def: ModuleDef, sound: G2Individual?) -> Bool {
        guard let index = def.paramNames.firstIndex(of: "Active") else { return true }
        let key = G2Individual.Key(area: module.area, moduleID: module.id, paramIndex: index)
        if let value = sound?[key] { return Int(value.rounded()) != 0 }
        return index < module.parameters.count ? module.parameters[index] != 0 : true
    }

    /// Gałka siły modulacji → wejście, które moduluje: typ modułu → [parametr: wejście].
    /// Tylko gałki, które skalują wyłącznie to wejście; bez kabla są martwe.
    static let modulationInputs: [Int: [Int: Int]] = [
        7: [3: 1, 5: 3, 7: 4], // OscB: PitchMod→PitchVar, FmAmount→FmMod, ShapeMod→ShapeMod
        8: [3: 1, 5: 3, 7: 4], // OscShpB: PitchMod→PitchVar, FmAmount→FmMod, ShapeMod→ShapeMod
        9: [4: 2, 7: 0], // OscC: FmAmount→FmMod, PitchMod→PitchVar
        13: [3: 2], // OscString: PitchMod→PitchVar
        18: [0: 2], // X-Fade: MixMod→Mod
        23: [4: 1, 5: 2, 6: 3, 7: 4], // ModADSR: AttackMod…ReleaseMod→AttackMod…ReleaseMod
        25: [3: 1, 6: 4, 8: 3], // LfoShpA: RateMod→RateVar, PhaseMod→PhaseMod, ShapeMod→ShapeMod
        26: [3: 1], // LfoA: RateMod→RateVar
        27: [4: 1], // OscMaster: PitchMod→PitchVar
        28: [1: 1], // Saturate: AmountMod→Mod
        29: [3: 0, 4: 1], // MetNoise: FreqMod→FreqMod, ColorMod→ColorMod
        34: [1: 1], // ShpExp: AmountMod→Mod
        38: [1: 1], // Pulse: TimeMod→Time
        42: [1: 1], // Delay: TimeMod→TimeMod
        45: [5: 1, 7: 2], // FltVoice: VowelMod→VowelMod, FreqMod→FreqMod
        47: [0: 1], // Pan: PanMod→Mod
        49: [1: 1], // FltMulti: PitchMod→PitchVar
        51: [1: 1, 7: 3, 9: 4], // FltNord: PitchMod→PitchVar, FM_Lin→FMLin, ResMod→Res
        61: [0: 1], // Clip: ClipLevMod→Mod
        62: [0: 1], // Overdrive: AmountMod→Mod
        63: [1: 1], // Scratch: RatioMod→Mod
        74: [0: 1], // WaveWrap: AmountMod→Mod
        87: [1: 1], // FltLP: FreqMod→Pitch
        92: [1: 1], // FltClassic: PitchMod→PitchVar
        98: [1: 1], // FreqShift: ShiftMod→Shift
        102: [0: 1, 2: 2, 8: 3], // FltPhase: PitchMod→PitchVar, SpreadMod→Spr, FBMod→FB
        106: [3: 1, 6: 2], // OscNoise: PitchMod→PitchVar, WidthMod→Width
        113: [1: 1], // Fade1-2: MixMod→Mod
        114: [1: 2], // Fade2-1: MixMod→Mod
        118: [2: 1], // Digitizer: RateMod→Rate
        125: [0: 1], // WahWah: SweepMod→Sweep
        134: [1: 1], // FltHP: FreqMod→Pitch
        162: [1: 2, 4: 3], // FltComb: PitchMod→PitchVar, FBMod→FB
        163: [3: 1, 5: 3, 8: 4], // OscShpA: PitchMod→PitchVar, FmAmount→FmMod, ShapeMod→ShapeMod
        164: [3: 1, 6: 3, 12: 4], // OscDual: PitchMod→PitchVar, PWMod→PW, PhaseMod→Phase
        167: [2: 1], // PShift: ShiftMod→Pitch
        169: [3: 1, 4: 2, 5: 3], // ModAHD: AttackMod, HoldMod, DecayMod→A, H, D
        173: [1: 1], // DlySingleB: TimeMod→Time
        174: [1: 1, 3: 2], // DelayDual: Time1Mod→Time1, Time2Mod→Time2
        175: [1: 1, 3: 2, 5: 3, 7: 4], // DelayQuad: TimeNMod→TimeN
        177: [5: 1, 6: 2], // DelayB: FBMod→FBMod, DryWetMod→DryWetMod
        183: [4: 2, 6: 0], // OscPM: PhaseMod→PhaseMod, PitchVar→PitchVar
        190: [1: 1, 9: 3], // LfoB: RateMod→RateVar, PhaseMod→Phase
        196: [4: 1], // OscPerc: PitchMod→PitchVar
        202: [3: 1], // RandomB: RateMod→RateVar
        205: [1: 3], // RndTrig: StepProbMod→Prob
        206: [4: 3], // RndClkB: StepProbMod→Step
        208: [4: 4], // RndPattern: StepProbMod→StepProb
    ]
}
