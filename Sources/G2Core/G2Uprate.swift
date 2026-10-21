// G2Uprate.swift
// Uprate — czy moduł z gniazdami dwukolorowymi pracuje z częstotliwością audio.
//
// Gniazdo niebiesko-czerwone (albo żółto-pomarańczowe) liczy z częstotliwością
// sterowania, dopóki nie dostanie sygnału audio. Wtedy cały moduł przechodzi na
// częstotliwość audio, jego dwukolorowe wyjścia stają się czerwone i to samo może
// spotkać moduły dalej w łańcuchu (instrukcja, rozdział 10).
//
// Nord tego nie liczy sam: flagę ustawia edytor — w pliku i komendą na żywo.
// Bez niej moduł przepuszcza piłę z częstotliwością sterowania i słychać aliasing.

import Foundation

public extension G2Patch {
    /// Przelicza flagi uprate całego patcha po zmianie kabli albo modułów.
    ///
    /// Tak samo jak oryginalny edytor: kolejne przebiegi po wszystkich modułach obszaru,
    /// aż żaden się nie zmieni. Moduł dostaje uprate, gdy któreś z jego dwukolorowych
    /// wejść dochodzi — kablem albo łańcuchem wejście→wejście — do wyjścia audio:
    /// czerwonego albo dwukolorowego w module, który już ma uprate. W przeciwnym razie
    /// wraca do częstotliwości sterowania. Liczy od bieżących flag, nie od zera.
    mutating func recomputeUprates() {
        for area in PatchArea.allCases {
            recomputeUprates(in: area)
        }
    }

    private mutating func recomputeUprates(in area: PatchArea) {
        let before = modules(in: area)
        var modules = before
        let position = Dictionary(modules.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sources = audioRateSources(in: area)

        func isAudioRate(_ output: G2Connector) -> Bool {
            guard let index = position[output.moduleID],
                  let color = ModuleDatabase.module(id: modules[index].typeID)?
                  .outputs[safe: output.index]?.color else { return false }
            switch color {
            case .audio: return true
            case .pitchOrControl, .logicOrControl: return modules[index].uprate
            case .control, .logic: return false
            }
        }

        // Każdy przebieg może tylko przepchnąć zmianę o jeden moduł dalej, więc
        // liczba modułów + 1 przebiegów wystarcza z zapasem.
        for _ in 0 ... modules.count {
            var changed = false
            for index in modules.indices {
                let inputs = sources[modules[index].id] ?? []
                let uprate = inputs.contains(where: isAudioRate)
                if modules[index].uprate != uprate {
                    modules[index].uprate = uprate
                    changed = true
                }
            }
            guard changed else { break }
        }

        if area == .voice { voiceModules = modules } else { fxModules = modules }

        for (old, module) in zip(before, modules) where old.uprate != module.uprate {
            recolorTwoColourOutputs(of: module, in: area)
        }
    }

    /// Jak oryginalny edytor przy zmianie uprate: całe drzewo kabli z każdego
    /// dwukolorowego wyjścia dostaje kolor sygnału, który to wyjście teraz niesie.
    /// Kolor wybrany ręcznie przepada — tak samo jak w oryginale.
    private mutating func recolorTwoColourOutputs(of module: G2Module, in area: PatchArea) {
        guard let outputs = ModuleDatabase.module(id: module.typeID)?.outputs else { return }
        for (index, output) in outputs.enumerated()
            where output.color == .pitchOrControl || output.color == .logicOrControl
        {
            guard let color = module.cableColor(forOutput: index) else { continue }
            let connector = G2Connector(moduleID: module.id, index: index, isOutput: true)
            for cable in cables(in: area) where cable.sourceConnector == connector {
                setCableColor(color, forChainContaining: cable, in: area)
            }
        }
    }

    /// Dla każdego modułu: wyjścia, które karmią jego dwukolorowe wejścia.
    /// Wejście połączone łańcuchem wejście→wejście dostaje wyjście tego łańcucha;
    /// łańcuch bez wyjścia nie niesie sygnału i nic nie daje.
    private func audioRateSources(in area: PatchArea) -> [Int: [G2Connector]] {
        let cables = cables(in: area)
        var sources: [Int: [G2Connector]] = [:]
        for module in modules(in: area) {
            guard let def = ModuleDatabase.module(id: module.typeID) else { continue }
            for (index, input) in def.inputs.enumerated()
                where input.color == .pitchOrControl || input.color == .logicOrControl
            {
                let connector = G2Connector(moduleID: module.id, index: index, isOutput: false)
                guard let cable = cables.first(where: {
                    $0.destinationConnector == connector || $0.sourceConnector == connector
                }) else { continue }
                let chain = cableChain(containing: cable, in: area)
                if let output = chain.first(where: \.sourceIsOutput)?.sourceConnector {
                    sources[module.id, default: []].append(output)
                }
            }
        }
        return sources
    }
}

public extension G2Module {
    /// Kolor kabla z wyjścia `index`, taki jak sygnał, który to wyjście teraz niesie.
    /// Dwukolorowe wyjście jest niebieskie (żółte) bez uprate, czerwone (pomarańczowe) z nim.
    func cableColor(forOutput index: Int) -> CableColor? {
        guard let color = ModuleDatabase.module(id: typeID)?.outputs[safe: index]?.color else { return nil }
        switch color {
        case .audio: return .red
        case .control: return .blue
        case .logic: return .yellow
        case .pitchOrControl: return uprate ? .red : .blue
        case .logicOrControl: return uprate ? .orange : .yellow
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
