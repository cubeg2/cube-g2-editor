// G2CableChains.swift
// Łańcuchy kabli — to, czego potrzebuje menu pod prawym przyciskiem nad kablem:
// „Disconnect", „Break", „Color", „Delete" i „Delete Unused Cables"
// (instrukcja Clavii, „Cable popup", str. 70–71).
//
// Reguły łączenia z instrukcji (str. 83–84):
// • wyjście można wpiąć w wiele wejść (rozgałęzienie),
// • wejścia można łączyć szeregowo między sobą, ale sygnał popłynie dopiero,
//   gdy łańcuch dostanie gdzieś wyjście,
// • dwóch wyjść nie łączy się nigdy.
//
// Stąd jedna zasada, na której stoi cały ten plik: **łańcuch rozchodzi się przez
// WEJŚCIA, nie przez wyjścia**. Dzięki temu dwa kable z tego samego wyjścia do
// dwóch różnych wejść to dwa osobne łańcuchy (instrukcja: rozgałęzienie kasuje się
// od źródła, nie od gałęzi), a szereg wejście→wejście→wejście jest jednym.

import Foundation

/// Jeden koniec kabla: gniazdo modułu.
public struct G2Connector: Hashable, Sendable {
    public var moduleID: Int
    public var index: Int
    public var isOutput: Bool

    public init(moduleID: Int, index: Int, isOutput: Bool) {
        self.moduleID = moduleID
        self.index = index
        self.isOutput = isOutput
    }
}

public extension G2Cable {
    /// Koniec źródłowy — wyjście albo (przy kablu wejście→wejście) wejście.
    var sourceConnector: G2Connector {
        G2Connector(moduleID: fromModule, index: fromConnector, isOutput: sourceIsOutput)
    }

    /// Koniec docelowy — zawsze wejście.
    var destinationConnector: G2Connector {
        G2Connector(moduleID: toModule, index: toConnector, isOutput: false)
    }

    /// Czy to ten sam kabel (bez porównywania koloru — ten wolno zmienić).
    func connectsSameAs(_ other: G2Cable) -> Bool {
        fromModule == other.fromModule && fromConnector == other.fromConnector
            && toModule == other.toModule && toConnector == other.toConnector
    }
}

public extension G2Patch {
    // MARK: - Łańcuch

    /// Kable jednego łańcucha szeregowego, do którego należy `cable`.
    ///
    /// Rozrost idzie wyłącznie przez gniazda **wejściowe**: wyjście jest ścianą,
    /// więc równoległe gałęzie z tego samego wyjścia zostają osobno.
    func cableChain(containing cable: G2Cable, in area: PatchArea) -> [G2Cable] {
        let all = cables(in: area)
        var chain: [G2Cable] = [cable]
        var inChain: Set<Int> = []
        if let index = all.firstIndex(where: { $0.connectsSameAs(cable) }) { inChain.insert(index) }

        // Gniazda wejściowe, przez które łańcuch może się jeszcze rozrosnąć.
        var frontier: [G2Connector] = [cable.sourceConnector, cable.destinationConnector]
            .filter { !$0.isOutput }
        var visited = Set(frontier)

        while let connector = frontier.popLast() {
            for (index, candidate) in all.enumerated() where !inChain.contains(index) {
                let ends = [candidate.sourceConnector, candidate.destinationConnector]
                guard ends.contains(connector) else { continue }
                inChain.insert(index)
                chain.append(candidate)
                for end in ends where !end.isOutput && visited.insert(end).inserted {
                    frontier.append(end)
                }
            }
        }
        return chain
    }

    // MARK: - Jedno wyjście na wejście

    /// Czy wpięcie `cable` dałoby wejściu (albo łańcuchowi wejść, w który wpada)
    /// drugie wyjście. Instrukcja: „An input can be connected to only one output
    /// and optionally share that output with other inputs." Oryginalny edytor
    /// takiego kabla nie wepnie, więc nasz też nie (#142).
    /// `cable` nie musi jeszcze być w patchu: łańcuch rośnie od niego.
    func cableWouldJoinTwoOutputs(_ cable: G2Cable, in area: PatchArea) -> Bool {
        Self.distinctOutputs(of: cableChain(containing: cable, in: area)) > 1
    }

    /// Łańcuchy, w które wpięte są co najmniej dwa różne wyjścia. Plik z zewnątrz
    /// może taki mieć — `PatchValidator` go wskazuje, nic nie kasujemy.
    func chainsWithSeveralOutputs(in area: PatchArea) -> [[G2Cable]] {
        let all = cables(in: area)
        var found: [[G2Cable]] = []
        var handled = Set<Int>()

        for (index, cable) in all.enumerated() where !handled.contains(index) {
            let chain = cableChain(containing: cable, in: area)
            for member in chain {
                if let i = all.firstIndex(where: { $0.connectsSameAs(member) }) { handled.insert(i) }
            }
            if Self.distinctOutputs(of: chain) > 1 { found.append(chain) }
        }
        return found
    }

    /// Jedno wyjście wolno rozgałęzić, więc liczą się różne wyjścia, nie kable.
    private static func distinctOutputs(of chain: [G2Cable]) -> Int {
        Set(chain.filter(\.sourceIsOutput).map(\.sourceConnector)).count
    }

    // MARK: - Disconnect / Break / Delete

    /// „Disconnect" — wyjmuje z łańcucha gniazdo docelowe tego kabla i **zszywa
    /// łańcuch z powrotem**: to, co szło dalej z tego gniazda, dostaje sygnał
    /// prosto ze źródła usuniętego kabla. Instrukcja: „Deletes the connection.
    /// Any remaining cable chains will be rerouted."
    mutating func disconnectCable(_ cable: G2Cable, in area: PatchArea) {
        let dropped = cable.destinationConnector
        let source = cable.sourceConnector
        remove(cable: cable)

        // Kable, które wychodziły z odpiętego gniazda dalej w szereg — przepinamy je
        // na źródło. Kabel wejście→wejście w drugą stronę (X → dropped) zostawiamy:
        // to on karmił gniazdo, które właśnie odpięliśmy.
        let rest = cables(in: area).filter { $0.sourceConnector == dropped }
        for onward in rest {
            remove(cable: onward)
            var rerouted = onward
            rerouted.fromModule = source.moduleID
            rerouted.fromConnector = source.index
            rerouted.sourceIsOutput = source.isOutput
            // Bez duplikatów — źródło mogło już karmić ten sam cel.
            if !cables(in: area).contains(where: { $0.connectsSameAs(rerouted) }) {
                add(cable: rerouted)
            }
        }
    }

    /// „Break" — usuwa sam kabel i nic nie zszywa. Reszta łańcucha zostaje wpięta,
    /// ale bez sygnału; takie kable rysujemy na biało (instrukcja, str. 70).
    mutating func breakCable(_ cable: G2Cable) {
        remove(cable: cable)
    }

    /// „Delete" — cały łańcuch szeregowy, którego częścią jest ten kabel.
    mutating func deleteCableChain(containing cable: G2Cable, in area: PatchArea) {
        for member in cableChain(containing: cable, in: area) {
            remove(cable: member)
        }
    }

    // MARK: - Kolor

    /// Kolor jednego łańcucha. Instrukcja: „Cables in a serial cable chain will
    /// always have the same color", więc kolor zmienia się dla całego łańcucha naraz.
    mutating func setCableColor(_ color: CableColor, forChainContaining cable: G2Cable,
                                in area: PatchArea)
    {
        let chain = cableChain(containing: cable, in: area)
        for member in chain {
            if area == .voice {
                if let i = voiceCables.firstIndex(where: { $0.connectsSameAs(member) }) {
                    voiceCables[i].color = color
                }
            } else {
                if let i = fxCables.firstIndex(where: { $0.connectsSameAs(member) }) {
                    fxCables[i].color = color
                }
            }
        }
    }

    // MARK: - Kable bez sygnału

    /// Kable, przez które nic nie płynie: łańcuchy wejście→wejście, do których
    /// nigdzie nie dochodzi wyjście. Instrukcja rysuje je na biało i kasuje
    /// poleceniem „Delete Unused Cables".
    func unusedCables(in area: PatchArea) -> [G2Cable] {
        let all = cables(in: area)
        var unused: [G2Cable] = []
        var handled = Set<Int>()

        for (index, cable) in all.enumerated() where !handled.contains(index) {
            let chain = cableChain(containing: cable, in: area)
            for member in chain {
                if let i = all.firstIndex(where: { $0.connectsSameAs(member) }) { handled.insert(i) }
            }
            let hasOutput = chain.contains { $0.sourceIsOutput }
            if !hasOutput { unused.append(contentsOf: chain) }
        }
        return unused
    }

    /// Czy przez ten kabel w ogóle płynie sygnał — rendering rysuje „martwe" na biało.
    func isCableUnused(_ cable: G2Cable, in area: PatchArea) -> Bool {
        !cableChain(containing: cable, in: area).contains { $0.sourceIsOutput }
    }

    /// Bieli łańcuchy, które właśnie straciły źródło. Instrukcja: „Any non-functional
    /// input-to-input connections are indicated by white cable color."
    mutating func recolorUnusedChains(in area: PatchArea) {
        for cable in unusedCables(in: area) where cable.color != .white {
            if area == .voice {
                if let i = voiceCables.firstIndex(where: { $0.connectsSameAs(cable) }) {
                    voiceCables[i].color = .white
                }
            } else {
                if let i = fxCables.firstIndex(where: { $0.connectsSameAs(cable) }) {
                    fxCables[i].color = .white
                }
            }
        }
    }

    /// Czy okablowanie różni się od innego patcha — po tym poznajemy, czy operacja
    /// na kablach w ogóle coś zmieniła i czy jest co wpisywać na stos undo.
    func cablesDiffer(from other: G2Patch) -> Bool {
        voiceCables != other.voiceCables || fxCables != other.fxCables
    }
}
