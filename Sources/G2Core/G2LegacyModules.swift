// G2LegacyModules.swift
// Pliki zapisane przez najstarsze OS-y G2 (2004) niosą moduły w postaci, której Nord 1.62
// już nie zna: wycofany ClkDivFix (Nord odrzuca cały slot — #168), ClkDiv bez trybu,
// FreqShift z piątym parametrem (zawieszał Norda — #157) i kable w gniazdach, których
// moduł już nie ma. Oryginalny edytor przerabia taki plik przy otwarciu, krok po kroku
// do bieżącej wersji formatu; tu robimy to samo jednym przejściem → [[Docs/parser/file-versions]].

public extension G2Patch {
    /// Typy wycofane z firmware'u. Oryginał przy konwersji pomija je razem z kablami.
    static let retiredModuleTypes: Set<Int> = [77] // ClkDivFix

    /// Doprowadza moduły do definicji bieżącego firmware'u. Patch zapisany przez nowy OS
    /// zostaje bez zmian. Plik na dysku zmienia się dopiero przy zapisie.
    mutating func upgradeLegacyModules() {
        for area in [PatchArea.voice, .fx] {
            let retired = modules(in: area).filter { Self.retiredModuleTypes.contains($0.typeID) }.map(\.id)
            deleteModules(moduleIDs: Set(retired), in: area)
        }
        self = trimmedToModuleDefinitions()
        voiceModules = voiceModules.map(Self.withMissingModes)
        fxModules = fxModules.map(Self.withMissingModes)
        voiceCables.removeAll { !Self.connectorsExist($0, in: voiceModules) }
        fxCables.removeAll { !Self.connectorsExist($0, in: fxModules) }
        dropAssignmentsToMissingParameters()
    }

    /// Brakujący tryb dostaje 0 — tak oryginał uzupełnia stary ClkDiv.
    private static func withMissingModes(_ module: G2Module) -> G2Module {
        guard let count = ModuleDatabase.module(id: module.typeID)?.modeNames.count,
              module.modes.count < count
        else { return module }
        var upgraded = module
        upgraded.modes += Array(repeating: 0, count: count - module.modes.count)
        return upgraded
    }

    /// Moduł spoza bazy zostawiamy w spokoju — nie wiemy, jakie ma gniazda.
    private static func connectorsExist(_ cable: G2Cable, in modules: [G2Module]) -> Bool {
        func definition(_ id: Int) -> ModuleDef? {
            modules.first { $0.id == id }.flatMap { ModuleDatabase.module(id: $0.typeID) }
        }
        if let target = definition(cable.toModule), cable.toConnector >= target.inputs.count { return false }
        if let source = definition(cable.fromModule) {
            let count = cable.sourceIsOutput ? source.outputs.count : source.inputs.count
            if cable.fromConnector >= count { return false }
        }
        return true
    }

    /// Czy obszar ma moduł z tym parametrem.
    internal func hasParameter(location: UInt8, moduleID: Int, paramIndex: Int) -> Bool {
        guard location <= 1 else { return false }
        let modules = location == 1 ? voiceModules : fxModules
        return modules.first { $0.id == moduleID }.map { paramIndex < Self.parameterCount(of: $0) } ?? false
    }

    /// Ile parametrów moduł ma naprawdę: według definicji, a dla typu spoza bazy — według pliku.
    /// Plik bywa krótszy od definicji (stary Mix4-1S: 8 z 9), a gałka na brakującym
    /// parametrze dalej ma sens w Nordzie — więc długość z pliku to za mało.
    private static func parameterCount(of module: G2Module) -> Int {
        ModuleDatabase.module(id: module.typeID)?.paramNames.count ?? module.parameters.count
    }

    /// Gałki, CC i morfy na parametrze, którego moduł już nie ma — oryginał usuwa je
    /// razem z parametrem. Ustawienia patcha (lokacja 2) nie są modułem, więc zostają.
    private mutating func dropAssignmentsToMissingParameters() {
        let voice = voiceModules, fx = fxModules
        func exists(location: UInt8, moduleID: Int, paramIndex: Int) -> Bool {
            guard location <= 1 else { return true }
            let modules = location == 1 ? voice : fx
            guard let module = modules.first(where: { $0.id == moduleID }) else { return true }
            return paramIndex < Self.parameterCount(of: module)
        }
        for knob in knobAssignments.indices {
            if let assignment = knobAssignments[knob],
               !exists(location: assignment.location, moduleID: assignment.moduleID,
                       paramIndex: assignment.paramIndex)
            {
                knobAssignments[knob] = nil
            }
        }
        for cc in midiControllerAssignments.indices {
            if let assignment = midiControllerAssignments[cc],
               !exists(location: assignment.location, moduleID: assignment.moduleID,
                       paramIndex: assignment.paramIndex)
            {
                midiControllerAssignments[cc] = nil
            }
        }
        for variation in morphAssignments.indices {
            morphAssignments[variation].removeAll {
                !exists(location: $0.location, moduleID: $0.moduleID, paramIndex: $0.paramIndex)
            }
        }
    }
}

public extension G2PerformanceSettings {
    /// Gałki globalne performance'u na parametrach, które `upgradeLegacyModules` usunęło —
    /// oryginał kasuje je razem z parametrem (także mapę gałek performance'u).
    mutating func dropGlobalKnobs(removedFrom original: [G2Patch], upgraded: [G2Patch]) {
        for knob in globalKnobAssignments.indices {
            guard let assignment = globalKnobAssignments[knob],
                  original.indices.contains(assignment.slot), upgraded.indices.contains(assignment.slot)
            else { continue }
            let target = (assignment.location, assignment.moduleID, assignment.paramIndex)
            if original[assignment.slot].hasParameter(location: target.0, moduleID: target.1, paramIndex: target.2),
               !upgraded[assignment.slot].hasParameter(location: target.0, moduleID: target.1, paramIndex: target.2)
            {
                globalKnobAssignments[knob] = nil
            }
        }
    }
}
