// G2SignalGraph.swift
// Tor sygnału patcha jako graf modułów: kto zasila kogo, co dochodzi do wyjścia,
// a co gra do ściany.
//
// Kable mówią o gniazdach, a pytania są o modułach: „skąd bierze się sygnał w filtrze",
// „czy oscylator B w ogóle słychać", „w jakiej kolejności ustawić moduły od źródła do
// wyjścia". Graf sprowadza kable do krawędzi moduł → moduł, przy czym kabel wejście→wejście
// nie jest osobnym źródłem, tylko rozdzielaczem: oba wejścia dostają to samo wyjście.
//
// Wyjściem obszaru jest moduł 2-Out / 4-Out; za ujście uchodzi też każdy moduł bez
// wyjść (nadajniki MIDI, Name) — nie umiemy powiedzieć, że nic nie robi. Moduł z `Active`
// wyłączonym nie gra i nic nie przepuszcza dalej. Poziomów mikserów nie oceniamy: gałka
// na zerze to nadal droga do wyjścia, tylko zamknięta.

import Foundation

public struct G2SignalGraph: Equatable {
    /// Jedna krawędź: wyjście modułu → wejście innego modułu, po nazwach gniazd.
    public struct Edge: Hashable {
        public let fromModule: Int
        public let fromOutput: Int
        public let toModule: Int
        public let toInput: Int

        public init(fromModule: Int, fromOutput: Int, toModule: Int, toInput: Int) {
            self.fromModule = fromModule
            self.fromOutput = fromOutput
            self.toModule = toModule
            self.toInput = toInput
        }
    }

    /// Dlaczego modułu nie słychać.
    public enum SilenceReason: String, Equatable {
        /// Żadne wyjście modułu nie prowadzi kablami do modułu wyjścia.
        case noRouteToOutput = "no route to an output module"
        /// Przycisk `Active` (On/Off) modułu jest wyłączony.
        case inactive = "module is switched off (Active)"
        /// Sygnał dochodzi tylko przez moduł, który jest wyłączony.
        case behindInactiveModule = "only reaches the output through a switched-off module"
    }

    public let area: PatchArea
    public let edges: [Edge]
    /// Moduły obszaru w kolejności z patcha.
    public let moduleIDs: [Int]
    /// Moduły, których sygnał dociera do ujścia (2-Out, 4-Out albo moduł bez wyjść).
    public let audibleModules: Set<Int>
    public let silenceReasons: [Int: SilenceReason]

    private let modulesByID: [Int: G2Module]
    private let outgoing: [Int: [Edge]]
    private let incoming: [Int: [Edge]]

    private static let sinkTypes: Set<String> = ["2-Out", "4-Out"]

    public init(patch: G2Patch, area: PatchArea) {
        self.area = area
        let modules = patch.modules(in: area)
        moduleIDs = modules.map(\.id)
        modulesByID = Dictionary(modules.map { ($0.id, $0) }) { first, _ in first }
        edges = Self.resolveEdges(cables: patch.cables(in: area))
        outgoing = Dictionary(grouping: edges, by: \.fromModule)
        incoming = Dictionary(grouping: edges, by: \.toModule)

        var inactive: Set<Int> = []
        var sinks: [Int] = []
        for module in modules {
            guard let def = ModuleDatabase.module(id: module.typeID) else {
                sinks.append(module.id) // nieznany typ — nie oceniamy
                continue
            }
            if !Self.isActive(module, def: def) { inactive.insert(module.id) }
            if Self.sinkTypes.contains(def.shortName) || def.outputs.isEmpty {
                sinks.append(module.id)
            }
        }

        // Wstecz od ujść; wyłączony moduł jest ścianą — nie oddaje niczego dalej.
        var audible = Set(sinks)
        var queue = sinks
        while let id = queue.popLast() {
            guard !inactive.contains(id) else { continue }
            for edge in incoming[id] ?? [] where audible.insert(edge.fromModule).inserted {
                queue.append(edge.fromModule)
            }
        }
        // Ten sam spacer bez ściany — żeby odróżnić „nie ma drogi" od „droga przez wyłączony".
        var reachable = Set(sinks)
        queue = sinks
        while let id = queue.popLast() {
            for edge in incoming[id] ?? [] where reachable.insert(edge.fromModule).inserted {
                queue.append(edge.fromModule)
            }
        }

        var reasons: [Int: SilenceReason] = [:]
        for module in modules {
            if inactive.contains(module.id) {
                reasons[module.id] = .inactive
            } else if !audible.contains(module.id) {
                reasons[module.id] = reachable.contains(module.id) ? .behindInactiveModule : .noRouteToOutput
            }
        }
        audibleModules = audible.subtracting(inactive)
        silenceReasons = reasons
    }

    // MARK: - Pytania

    /// Moduły, których wyjścia zasilają ten moduł (bez powtórzeń, w kolejności krawędzi).
    public func upstream(of moduleID: Int) -> [Int] {
        var seen: Set<Int> = []
        return (incoming[moduleID] ?? []).map(\.fromModule).filter { seen.insert($0).inserted }
    }

    /// Moduły, do których idzie sygnał z tego modułu.
    public func downstream(of moduleID: Int) -> [Int] {
        var seen: Set<Int> = []
        return (outgoing[moduleID] ?? []).map(\.toModule).filter { seen.insert($0).inserted }
    }

    public func isAudible(_ moduleID: Int) -> Bool {
        audibleModules.contains(moduleID)
    }

    /// Moduły bez wejść zasilanych kablem — początki toru (klawiatura, oscylatory, LFO…).
    public var sources: [Int] {
        moduleIDs.filter { (incoming[$0] ?? []).isEmpty && !(outgoing[$0] ?? []).isEmpty }
    }

    /// Ujścia obszaru: 2-Out / 4-Out i moduły bez wyjść.
    public var sinks: [Int] {
        moduleIDs.filter { id in
            guard let module = modulesByID[id], let def = ModuleDatabase.module(id: module.typeID) else {
                return false
            }
            return Self.sinkTypes.contains(def.shortName) || def.outputs.isEmpty
        }
    }

    /// Odległość od najdalszego źródła (0 = źródło) — najdłuższa droga w grafie bez
    /// krawędzi wstecznych. Sprzężenie (kabel z powrotem do modułu wyżej w torze) nie
    /// liczy się jako kolejny stopień: przechodzimy tor od źródeł i pomijamy krawędzie,
    /// które wracają do modułu jeszcze otwartego na stosie.
    public func depths() -> [Int: Int] {
        var state: [Int: Int] = [:] // 1 = na stosie, 2 = zamknięty
        var order: [Int] = [] // kolejność zamykania (odwrócona = topologiczna)
        var forward: [Int: [Int]] = [:]
        func visit(_ id: Int) {
            state[id] = 1
            for next in downstream(of: id) where state[next] != 1 {
                forward[id, default: []].append(next)
                if state[next] == nil { visit(next) }
            }
            state[id] = 2
            order.append(id)
        }
        for id in sources + moduleIDs where state[id] == nil {
            visit(id)
        }

        var depth: [Int: Int] = [:]
        for id in order.reversed() {
            let here = depth[id] ?? 0
            depth[id] = here
            for next in forward[id] ?? [] {
                depth[next] = max(depth[next] ?? 0, here + 1)
            }
        }
        return depth
    }

    /// Łańcuchy od każdego źródła do ujścia: lista modułów po drodze. Rozgałęzienia
    /// dają osobne łańcuchy; pętle są ucinane przy pierwszym powtórzeniu.
    public func chains(maxCount: Int = 64) -> [[Int]] {
        var result: [[Int]] = []
        let sinkSet = Set(sinks)
        func walk(_ path: [Int]) {
            guard result.count < maxCount, let last = path.last else { return }
            let next = downstream(of: last).filter { !path.contains($0) }
            if sinkSet.contains(last) || next.isEmpty {
                result.append(path)
                return
            }
            for id in next {
                walk(path + [id])
            }
        }
        for source in sources {
            walk([source])
        }
        return result
    }

    // MARK: - Budowa

    /// Kable → krawędzie moduł → moduł. Kabel wejście→wejście dzieli źródło: wejście
    /// docelowe dostaje wszystkie wyjścia, które zasilają wejście źródłowe (przez całą sieć).
    private static func resolveEdges(cables: [G2Cable]) -> [Edge] {
        struct Pin: Hashable {
            let module: Int
            let isOutput: Bool
            let index: Int
        }
        // Kto zasila dane gniazdo. Kabel wyjście→wejście zasila swój koniec; kabel
        // wejście-wejście zapisany jest ODWROTNIE do przepływu — `to` jest gniazdem
        // zasilanym, a `from` z niego bierze (usterka #100), więc krawędź idzie w tę stronę.
        var feeders: [Pin: [Pin]] = [:]
        var takesFromInput: [Pin: [Pin]] = [:]
        var inputs: Set<Pin> = []
        for cable in cables {
            let from = Pin(module: cable.fromModule, isOutput: cable.sourceIsOutput, index: cable.fromConnector)
            let to = Pin(module: cable.toModule, isOutput: false, index: cable.toConnector)
            inputs.insert(to)
            if cable.sourceIsOutput {
                feeders[to, default: []].append(from)
            } else {
                inputs.insert(from)
                takesFromInput[from, default: []].append(to)
            }
        }
        // Gniazdo, które bierze z innego wejścia, ma JEDYNIE tamto źródło — własny kabel
        // z wyjścia wpięty obok jest konfliktem, przez który G2 nie słychać (usterka #100).
        for (taker, sources) in takesFromInput {
            feeders[taker] = sources
        }

        var edges: [Edge] = []
        var seen: Set<Edge> = []
        for input in inputs.sorted(by: { ($0.module, $0.index) < ($1.module, $1.index) }) {
            var visited: Set<Pin> = [input]
            var stack = [input]
            while let pin = stack.popLast() {
                if pin.isOutput {
                    let edge = Edge(fromModule: pin.module, fromOutput: pin.index,
                                    toModule: input.module, toInput: input.index)
                    if seen.insert(edge).inserted { edges.append(edge) }
                    continue
                }
                for next in feeders[pin] ?? [] where visited.insert(next).inserted {
                    stack.append(next)
                }
            }
        }
        return edges
    }

    private static func isActive(_ module: G2Module, def: ModuleDef) -> Bool {
        guard let index = def.paramNames.firstIndex(of: "Active") else { return true }
        return index < module.parameters.count ? module.parameters[index] != 0 : true
    }
}
