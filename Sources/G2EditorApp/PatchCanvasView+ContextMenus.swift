import G2Core
import G2EditorCore
import SwiftUI

// Menu kontekstowe parametru, kabla i tła patcha — trzy z czterech menu, które
// instrukcja Clavii opisuje na stronach 68–71. Czwarte (menu modułu) siedzi
// w `PatchCanvasView+Commands.swift`, bo istniało tam wcześniej.

extension PatchCanvasView {
    // MARK: - Parameter popup (instrukcja, str. 70)

    func parameterMenuItems(for hit: ParamHoverHit) -> some View {
        Group {
            Text(parameterMenuTitle(hit))

            Divider()

            Button("Default Value") {
                guard let value = defaultValue(for: hit) else { return }
                onParameterChange?(hit.moduleID, hit.paramIndex, value)
            }
            .disabled(defaultValue(for: hit) == nil)

            morphAssignButton(for: hit)

            Divider()

            parameterAssignMenu(for: hit, global: false)
            parameterAssignMenu(for: hit, global: true)
            midiControllerMenu(for: hit)
        }
    }

    /// Nagłówek menu: nazwa modułu i parametru, żeby było widać, czego dotyczy —
    /// kontrolki są małe, a menu potrafi zasłonić tę, z której wyszło.
    private func parameterMenuTitle(_ hit: ParamHoverHit) -> String {
        guard let module = modules.first(where: { $0.id == hit.moduleID }) else { return hit.paramName }
        let moduleName = module.label.isEmpty
            ? (ModuleDatabase.module(id: module.typeID)?.shortName ?? "Module")
            : module.label
        return hit.paramName.isEmpty ? moduleName : "\(moduleName) · \(hit.paramName)"
    }

    private func defaultValue(for hit: ParamHoverHit) -> Int? {
        guard let module = modules.first(where: { $0.id == hit.moduleID }) else { return nil }
        let defaults = ModuleDefaultsDatabase.defaults(forTypeID: module.typeID)
        return defaults.indices.contains(hit.paramIndex) ? defaults[hit.paramIndex] : nil
    }

    /// „Morph assign" działa na morfie Z FOCUSEM — tym samym, który wybiera pasek
    /// morfów i Option-przeciąganie gałki. Zaznaczenie zdejmuje przypisanie.
    ///
    /// Zakres przy zakładaniu: **do maksimum parametru**. Instrukcja mówi wprost
    /// tylko o przyciskach („the Morph range will always be fixed at the maximum
    /// range"), ale zakres 0 nie istnieje — plik i urządzenie kasują nim wpis —
    /// więc przypisanie bez zakresu nie miałoby czego zapisać. Gdy gałka stoi już
    /// na maksimum, zakres idzie w dół, do minimum.
    @ViewBuilder
    private func morphAssignButton(for hit: ParamHoverHit) -> some View {
        let assigned = morphRange(moduleID: hit.moduleID, paramIndex: hit.paramIndex) != 0
        Button {
            onMorphRangeChange?(hit.moduleID, hit.paramIndex,
                                assigned ? 0 : defaultMorphRange(moduleID: hit.moduleID,
                                                                 paramIndex: hit.paramIndex))
        } label: {
            Text(assigned
                ? "✓ Morph Assign (\(Self.morphName(focusedMorph)))"
                : "Morph Assign (\(Self.morphName(focusedMorph)))")
        }
        .disabled(onMorphRangeChange == nil)
    }

    /// Nazwa morfu z focusem — ta sama, którą pokazuje pasek morfów.
    static func morphName(_ morph: Int) -> String {
        G2Morph.names.indices.contains(morph) ? G2Morph.names[morph] : "Morph \(morph + 1)"
    }

    /// Zakres, który dostaje świeżo przypisany parametr — patrz komentarz nad
    /// `morphAssignButton`. Używa go i menu, i Ctrl-klik na gałce.
    func defaultMorphRange(moduleID: Int, paramIndex: Int) -> Int {
        guard let module = modules.first(where: { $0.id == moduleID }) else { return 1 }
        let range = ParameterRangeDatabase.range(moduleTypeID: module.typeID,
                                                 codeRef: paramIndex) ?? 0 ... 127
        let current = paramIndex < module.parameters.count ? module.parameters[paramIndex] : 0
        let up = range.upperBound - current
        return up > 0 ? up : range.lowerBound - current
    }

    /// „Assign ▸ Page X ▸ Knob" / „Global Assign" — parametr ląduje na pierwszej
    /// wolnej gałce wskazanej strony. „Disable" go stamtąd zdejmuje (instrukcja, str. 90).
    @ViewBuilder
    private func parameterAssignMenu(for hit: ParamHoverHit, global: Bool) -> some View {
        let current = global
            ? commands.globalKnobIndexFor?(hit.moduleID, hit.paramIndex)
            : commands.knobIndexFor?(hit.moduleID, hit.paramIndex)
        Menu(global ? "Global Assign" : "Assign") {
            ForEach(0 ..< G2KnobPages.pageCount, id: \.self) { page in
                let onThisPage = current.map { $0 / G2KnobPages.knobsPerPage == page } ?? false
                Button(onThisPage ? "✓ \(Self.pageMenuTitle(page))" : Self.pageMenuTitle(page)) {
                    if global {
                        commands.assignGlobalKnobToPage?(hit.moduleID, hit.paramIndex, page)
                    } else {
                        commands.assignKnobToPage?(hit.moduleID, hit.paramIndex, page)
                    }
                }
            }
            Divider()
            Button("Disable") {
                if global {
                    commands.clearGlobalKnob?(hit.moduleID, hit.paramIndex)
                } else {
                    commands.clearKnob?(hit.moduleID, hit.paramIndex)
                }
            }
            .disabled(current == nil)
        }
    }

    /// „MIDI Controller ▸ Assign / Remove" (instrukcja, str. 70 i 91). Numery
    /// zarezerwowane (Modwheel, Bank Select, Sustain…) nie pojawiają się na liście —
    /// pilnuje tego `G2MidiControllers.isValid`.
    @ViewBuilder
    private func midiControllerMenu(for hit: ParamHoverHit) -> some View {
        let current = commands.midiControllerFor?(hit.moduleID, hit.paramIndex)
        Menu(current.map { "MIDI Controller (CC \($0))" } ?? "MIDI Controller") {
            ForEach(Self.midiControllerBanks, id: \.first) { bank in
                Menu("CC \(bank.first)–\(bank.last)") {
                    ForEach(bank.numbers, id: \.self) { cc in
                        Button(cc == current ? "✓ CC \(cc)" : "CC \(cc)") {
                            commands.assignMidiController?(hit.moduleID, hit.paramIndex, cc)
                        }
                    }
                }
            }
            Divider()
            Button("Remove") { commands.clearMidiController?(hit.moduleID, hit.paramIndex) }
                .disabled(current == nil)
        }
        .disabled(commands.assignMidiController == nil)
    }

    /// Sto dwadzieścia numerów CC w dziesiątkach — płaska lista byłaby nie do przejścia.
    static let midiControllerBanks: [(first: Int, last: Int, numbers: [Int])] = stride(from: 0, to: G2MidiControllers.count, by: 10).compactMap { start in
        let end = min(start + 9, G2MidiControllers.count - 1)
        let numbers = (start ... end).filter { G2MidiControllers.isValid($0) }
        return numbers.isEmpty ? nil : (first: start, last: end, numbers: numbers)
    }

    // MARK: - Cable popup (instrukcja, str. 70–71)

    func cableMenuItems(for cable: G2Cable) -> some View {
        Group {
            Text(cableMenuTitle(cable))

            Divider()

            Button("Disconnect") { commands.disconnectCable?(cable) }
            Button("Break") { commands.breakCable?(cable) }

            Divider()

            Menu("Color") {
                ForEach(CableColor.allCases, id: \.self) { color in
                    Button(color == cable.color ? "✓ \(color.displayName)" : color.displayName) {
                        commands.setCableColor?(cable, color)
                    }
                }
            }

            Divider()

            Button("Delete", role: .destructive) { commands.deleteCableChain?(cable) }

            Button("Delete Unused Cables") { commands.deleteUnusedCables?() }
                .disabled((commands.unusedCableCount?() ?? 0) == 0)
        }
    }

    private func cableMenuTitle(_ cable: G2Cable) -> String {
        let source = moduleDisplayName(cable.fromModule)
        let destination = moduleDisplayName(cable.toModule)
        return "\(source) → \(destination)"
    }

    private func moduleDisplayName(_ moduleID: Int) -> String {
        guard let module = modules.first(where: { $0.id == moduleID }) else { return "?" }
        return module.label.isEmpty
            ? (ModuleDatabase.module(id: module.typeID)?.shortName ?? "?")
            : module.label
    }

    // MARK: - Patch window popup (instrukcja, str. 68–69)

    func patchBackgroundMenuItems() -> some View {
        Group {
            Button("Cut") {
                copySelectedModules()
                deleteSelectedModules()
            }
            .disabled(selectedModuleIDs.isEmpty && activeModuleID == nil)

            Button("Copy") { copySelectedModules() }
                .disabled(selectedModuleIDs.isEmpty && activeModuleID == nil)

            Button("Paste") {
                if let content = G2ClipboardContent.readFromPasteboard() {
                    onPasteModules?(content)
                }
            }
            .disabled(!G2ClipboardContent.hasModulesOnPasteboard)

            Divider()

            insertModuleMenu()

            Divider()

            Button("Select All") { selectedModuleIDs = Set(modules.map(\.id)) }

            Divider()

            Button("Delete Unused Cables") { commands.deleteUnusedCables?() }
                .disabled((commands.unusedCableCount?() ?? 0) == 0)

            Button("Delete Unused Modules") { commands.deleteUnusedModules?() }
                .disabled((commands.unusedModuleCount?() ?? 0) == 0)
        }
    }

    /// „Insert ▸" — grupy modułów i ich zawartość. Moduł ląduje pod kursorem, czyli
    /// tam, gdzie otwarto menu (instrukcja: „Place the cursor where you want the
    /// module to be placed and click to drop the module").
    @ViewBuilder
    private func insertModuleMenu() -> some View {
        let drop = insertGridPosition()
        Menu("Insert") {
            ForEach(ModuleCatalogOrder.categories, id: \.self) { category in
                let entries = ModuleCatalogOrder.orderedModules(in: category,
                                                                from: ModuleDatabase.all)
                if !entries.isEmpty {
                    Menu(category) {
                        ForEach(entries, id: \.id) { def in
                            Button(def.shortName) {
                                onAddModuleAt?(def.id, drop.column, drop.row)
                            }
                        }
                    }
                }
            }
        }
        .disabled(onAddModuleAt == nil)
    }

    private func insertGridPosition() -> (column: Int, row: Int) {
        let point = CGPoint(x: hoverScreenPt.x / zoom, y: hoverScreenPt.y / zoom)
        let grid = PatchLayout.gridPosition(at: point, rowOffset: rowOffset)
        return (grid.column, grid.row)
    }
}
