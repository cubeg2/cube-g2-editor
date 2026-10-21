// PatchValidator.swift
//
// Kontrola strukturalna wczytanego patcha — WYŁĄCZNIE raport, nic nie zmienia.
//
// Powód powstania: użytkownik zgłosił, że w oryginalnym edytorze Clavii patche
// potrafiły się zepsuć tak, że nie dawały się już otworzyć. Nasz parser jest
// wyrozumialszy (CRC nie jest weryfikowane, sekcje czytane niezależnie), więc
// otwiera pliki, których oryginał odmawia — ale wtedy tym bardziej trzeba umieć
// nazwać, co w środku jest niespójne.
//
// Zakres tej wersji: sprawdzamy tylko to, co da się rozstrzygnąć na podstawie
// samych danych patcha i `ModuleDatabase`. Świadomie NIE sprawdzamy wartości
// parametrów — w pliku każdy parametr to 7 bitów, więc po wczytaniu zawsze
// mieści się w 0...127, a węższe zakresy sprzętowe (`ParameterRangeDatabase`
// + typy kontrolek) zna dopiero warstwa UI.
//
// Naprawą zajmuje się osobny krok — patrz Docs/roadmap.md. Tutaj żadna metoda
// nie modyfikuje patcha.

import Foundation

public enum PatchIssueSeverity: String {
    /// Plik jest wewnętrznie sprzeczny — G2 nie mógłby takiego stanu wytworzyć.
    case error
    /// Coś odbiega od oczekiwań, ale może też świadczyć o luce w naszej bazie modułów.
    case warning
}

public enum PatchIssueKind: String, CaseIterable {
    case unknownModuleType
    case duplicateModuleID
    case parametersMissing
    case parameterCountMismatch
    case modeCountMismatch
    case cableToMissingModule
    case cableConnectorOutOfRange
    case cableLinkTypeContradictsModule
    case duplicateCable
    case cableToItself
    case inputWithSeveralOutputs
}

/// Pojedyncze znalezisko. `message` jest po angielsku, bo trafi do UI aplikacji.
public struct PatchIssue: Equatable {
    public let kind: PatchIssueKind
    public let severity: PatchIssueSeverity
    public let area: PatchArea
    public let message: String

    public init(kind: PatchIssueKind, severity: PatchIssueSeverity,
                area: PatchArea, message: String)
    {
        self.kind = kind
        self.severity = severity
        self.area = area
        self.message = message
    }
}

public enum PatchValidator {
    /// Przegląda patcha i zwraca listę niespójności. Nie modyfikuje niczego.
    public static func issues(in patch: G2Patch) -> [PatchIssue] {
        PatchArea.allCases.flatMap { area in
            moduleIssues(patch.modules(in: area), area: area)
                + cableIssues(patch.cables(in: area), modules: patch.modules(in: area), area: area)
                + sourceIssues(patch, area: area)
        }
    }

    /// Wejście (albo łańcuch wejść) z dwoma wyjściami naraz. Edytor takiego kabla
    /// nie wepnie, tak jak oryginalny; plik z zewnątrz może go jednak mieć (#142).
    private static func sourceIssues(_ patch: G2Patch, area: PatchArea) -> [PatchIssue] {
        patch.chainsWithSeveralOutputs(in: area).map { chain in
            let outputs = Set(chain.filter(\.sourceIsOutput).map(\.sourceConnector))
                .sorted { ($0.moduleID, $0.index) < ($1.moduleID, $1.index) }
                .map { "\($0.moduleID):\($0.index)" }
            let inputs = Set(chain.flatMap { [$0.sourceConnector, $0.destinationConnector] })
                .filter { !$0.isOutput }
                .sorted { ($0.moduleID, $0.index) < ($1.moduleID, $1.index) }
                .map { "\($0.moduleID):\($0.index)" }
            return PatchIssue(
                kind: .inputWithSeveralOutputs, severity: .error, area: area,
                message: "Inputs \(inputs.joined(separator: ", ")) are fed by \(outputs.count) outputs "
                    + "(\(outputs.joined(separator: ", "))); an input takes only one output."
            )
        }
    }

    // MARK: - Moduły

    private static func moduleIssues(_ modules: [G2Module], area: PatchArea) -> [PatchIssue] {
        var issues: [PatchIssue] = []
        var seenIDs = Set<Int>()

        for module in modules {
            if !seenIDs.insert(module.id).inserted {
                issues.append(PatchIssue(
                    kind: .duplicateModuleID, severity: .error, area: area,
                    message: "Module id \(module.id) is used by more than one module — every cable to it is ambiguous."
                ))
            }

            guard let def = ModuleDatabase.module(id: module.typeID) else {
                issues.append(PatchIssue(
                    kind: .unknownModuleType, severity: .warning, area: area,
                    message: "Module \(module.id) has type \(module.typeID), which is not in the module database."
                ))
                continue
            }

            // Brak parametrów przy module, który ich oczekuje, znaczy że sekcja
            // 0x4d nie objęła tego modułu (albo jej w pliku nie ma).
            if module.parameters.isEmpty, !def.paramNames.isEmpty {
                issues.append(PatchIssue(
                    kind: .parametersMissing, severity: .warning, area: area,
                    message: "Module \(module.id) (\(def.shortName)) carries no parameter values; \(def.paramNames.count) expected."
                ))
            } else if !module.parameters.isEmpty, module.parameters.count != def.paramNames.count {
                issues.append(PatchIssue(
                    kind: .parameterCountMismatch, severity: .warning, area: area,
                    message: "Module \(module.id) (\(def.shortName)) carries \(module.parameters.count) parameter values; \(def.paramNames.count) expected."
                ))
            }

            if module.modes.count != def.modeNames.count {
                issues.append(PatchIssue(
                    kind: .modeCountMismatch, severity: .warning, area: area,
                    message: "Module \(module.id) (\(def.shortName)) carries \(module.modes.count) mode values; \(def.modeNames.count) expected."
                ))
            }
        }
        return issues
    }

    // MARK: - Kable

    private enum CableEnd: String {
        case source, destination
    }

    private struct CableEndpoints: Hashable {
        let fromModule: Int
        let fromConnector: Int
        let toModule: Int
        let toConnector: Int
    }

    private static func cableIssues(_ cables: [G2Cable], modules: [G2Module],
                                    area: PatchArea) -> [PatchIssue]
    {
        // uniquingKeysWith, a nie uniqueKeysWithValues: powtórzone id modułu to
        // jedno ze znalezisk, więc nie może wywrócić samego walidatora.
        let byID = Dictionary(modules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var issues: [PatchIssue] = []
        var seenEndpoints = Set<CableEndpoints>()

        for cable in cables {
            let endpoints = CableEndpoints(fromModule: cable.fromModule, fromConnector: cable.fromConnector,
                                           toModule: cable.toModule, toConnector: cable.toConnector)
            if !seenEndpoints.insert(endpoints).inserted {
                issues.append(PatchIssue(
                    kind: .duplicateCable, severity: .warning, area: area,
                    message: "Cable \(describe(cable)) appears more than once."
                ))
            }

            if cable.fromModule == cable.toModule, cable.fromConnector == cable.toConnector,
               !cable.sourceIsOutput
            {
                issues.append(PatchIssue(
                    kind: .cableToItself, severity: .error, area: area,
                    message: "Cable \(describe(cable)) connects one connector to itself."
                ))
            }

            issues += endIssues(of: cable, at: .source, in: byID, area: area)
            issues += endIssues(of: cable, at: .destination, in: byID, area: area)
        }
        return issues
    }

    /// Sprawdza jeden koniec kabla. Koniec docelowy jest ZAWSZE wejściem; o tym,
    /// czym jest koniec źródłowy, decyduje `linkType` (→ `G2Cable.sourceIsOutput`).
    private static func endIssues(of cable: G2Cable, at end: CableEnd,
                                  in modules: [Int: G2Module], area: PatchArea) -> [PatchIssue]
    {
        let moduleID = end == .source ? cable.fromModule : cable.toModule
        let connector = end == .source ? cable.fromConnector : cable.toConnector
        let expectsOutput = end == .source ? cable.sourceIsOutput : false

        guard let module = modules[moduleID] else {
            return [PatchIssue(
                kind: .cableToMissingModule, severity: .error, area: area,
                message: "Cable \(describe(cable)): \(end.rawValue) module \(moduleID) does not exist in this area."
            )]
        }
        // Nieznany typ modułu jest zgłaszany osobno; bez definicji nie mamy czym mierzyć.
        guard let def = ModuleDatabase.module(id: module.typeID) else { return [] }

        let expected = expectsOutput ? def.outputs.count : def.inputs.count
        guard connector >= expected else { return [] }

        // Konektor nie istnieje jako oczekiwany rodzaj, ale istnieje jako ten
        // drugi — na końcu źródłowym to znaczy dokładnie tyle, że bit linkType
        // ma złą wartość, i naprawa jest jednoznaczna. Na końcu docelowym nie ma
        // czego przestawiać (tam wejście jest wymuszone formatem).
        let opposite = expectsOutput ? def.inputs.count : def.outputs.count
        if end == .source, connector < opposite {
            return [PatchIssue(
                kind: .cableLinkTypeContradictsModule, severity: .error, area: area,
                message: "Cable \(describe(cable)): source connector \(connector) is not "
                    + "\(expectsOutput ? "an output" : "an input") on module \(moduleID) (\(def.shortName)) "
                    + "but it is \(expectsOutput ? "an input" : "an output") — the direction flag is wrong."
            )]
        }

        return [PatchIssue(
            kind: .cableConnectorOutOfRange, severity: .error, area: area,
            message: "Cable \(describe(cable)): \(end.rawValue) connector \(connector) is out of range "
                + "for module \(moduleID) (\(def.shortName): \(def.inputs.count) inputs, \(def.outputs.count) outputs)."
        )]
    }

    private static func describe(_ cable: G2Cable) -> String {
        "\(cable.fromModule):\(cable.fromConnector) → \(cable.toModule):\(cable.toConnector)"
    }
}
