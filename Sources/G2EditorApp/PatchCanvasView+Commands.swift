import AppKit
import G2Core
import G2EditorCore
import SwiftUI

extension PatchCanvasView {
    // MARK: - Drop destination helpers

    /// Konwertuje punkt upuszczenia (screen-pt, zoomed) na pozycję w gridzie (kolumna, wiersz).
    private func dropPointToGrid(_ location: CGPoint) -> (col: Int, row: Int) {
        let x = location.x / zoom
        let y = location.y / zoom
        let grid = PatchLayout.gridPosition(at: CGPoint(x: x, y: y), rowOffset: rowOffset)
        return (grid.column, grid.row)
    }

    // MARK: - Context menu

    /// Menu pod prawym przyciskiem. Instrukcja Clavii ma ich cztery (str. 68–71) i
    /// rozróżnia je po tym, co jest pod kursorem. Kolejność sprawdzania:
    /// gniazdo → parametr → moduł → kabel → tło.
    ///
    /// Kabel jest po module świadomie: kable biegną nad panelami, a nad panelem
    /// bardziej przydatne jest menu modułu. W wolnej przestrzeni kabel jest jedynym
    /// trafieniem, a jego menu otwiera się też z każdego gniazda, do którego dochodzi.
    @ViewBuilder
    var contextMenuItems: some View {
        let lp = CGPoint(x: hoverScreenPt.x / zoom, y: hoverScreenPt.y / zoom)

        if let connector = findConnector(at: lp), let cable = cablesAt(connector: connector).first {
            cableMenuItems(for: cable)
        } else if let hit = findHoverHit(at: lp), !hit.usesModes {
            parameterMenuItems(for: hit)
        } else if let id = findModuleBody(at: lp)?.moduleID {
            moduleMenuItems(for: id)
        } else if let cable = findCable(at: lp) {
            cableMenuItems(for: cable)
        } else {
            patchBackgroundMenuItems()
        }
    }

    private func moduleMenuItems(for id: Int) -> some View {
        Group {
            moduleClipboardMenuItems(for: id)

            Divider()

            Button("Rename") {
                guard let module = modules.first(where: { $0.id == id }) else { return }
                let defLabel = ModuleDatabase.module(id: module.typeID)?.shortName ?? ""
                editingText = module.label.isEmpty ? defLabel : module.label
                editingModuleID = id
                activeModuleID = id
                nameFieldFocused = true
            }

            moduleAssignMenus(for: id)

            Divider()

            moduleColorMenu(for: id)

            Divider()

            // „Exclude From Mutations" oryginału: zaznaczone moduły znikają z pola
            // widzenia Patch Mutatora i przy otwartym mutatorze dostają czerwoną ramkę.
            excludeFromMutationButton(id: id)

            Divider()

            moduleDisconnectMenu(for: id)

            Button("Delete", role: .destructive) {
                deleteSelectedModules(targetID: id)
            }
        }
    }

    /// „Disconnect Cables ▸" — kable zaznaczenia (albo samego modułu pod kursorem)
    /// hurtem, jednym krokiem undo. Pusty wariant jest wyszarzony.
    private func moduleDisconnectMenu(for id: Int) -> some View {
        let targets = selectedModuleIDs.contains(id) ? selectedModuleIDs : [id]
        return Menu("Disconnect Cables") {
            ForEach(CableDisconnectScope.allCases, id: \.self) { scope in
                Button(scope.title) { commands.disconnectModuleCables?(targets, scope) }
                    .disabled((commands.moduleCableCount?(targets, scope) ?? 0) == 0)
            }
        }
        .disabled(commands.disconnectModuleCables == nil)
    }

    private func moduleColorMenu(for id: Int) -> some View {
        Menu("Color") {
            Button(ModuleColorPalette.name(0)) { onColorModule?(id, 0) }
            Divider()
            ForEach(ModuleColorPalette.all, id: \.self) { color in
                moduleColorMenuItem(id: id, color: color)
            }
        }
    }

    /// Cut / Copy / Paste / Paste Params — cztery pozycje, które instrukcja wymienia
    /// na początku menu modułu (str. 69).
    private func moduleClipboardMenuItems(for id: Int) -> some View {
        Group {
            Button("Cut") {
                selectIfNeeded(id)
                copySelectedModules()
                deleteSelectedModules(targetID: id)
            }

            Button("Copy") {
                selectIfNeeded(id)
                copySelectedModules()
            }

            Button("Paste") {
                if let content = G2ClipboardContent.readFromPasteboard() {
                    onPasteModules?(content)
                }
            }
            // Świadomie NIE rozpakowujemy tu schowka. AppKit odpytuje otwarte menu
            // o stan pozycji na bieżąco, a `readFromPasteboard` dekoduje przy każdym
            // takim pytaniu całą zawartość schowka — przy grającym patchu (główny wątek
            // zajęty strumieniem z Norda) było to widać jako mruganie listy.
            .disabled(!G2ClipboardContent.hasModulesOnPasteboard)

            Button("Paste Params") {
                let targets = selectedModuleIDs.contains(id) ? selectedModuleIDs : [id]
                commands.pasteParams?(targets)
            }
            .disabled(!G2ClipboardContent.hasModulesOnPasteboard)

            Divider()

            Button("Save Selection as Block…") {
                selectIfNeeded(id)
                commands.saveModulesAsBlock?(selectedModuleIDs.isEmpty ? [id] : selectedModuleIDs)
            }
        }
    }

    /// Moduł pod kursorem wchodzi do zaznaczenia, jeśli go w nim nie było — tak samo
    /// zachowuje się każde menu kontekstowe, które działa na „zaznaczeniu albo celu".
    private func selectIfNeeded(_ id: Int) {
        guard !selectedModuleIDs.contains(id) else { return }
        selectedModuleIDs = [id]
        activeModuleID = id
    }

    /// „Assign" i „Global Assign" z menu modułu obsadzają WSZYSTKIE jego parametry,
    /// wchodząc na kolejne strony, gdy jedna nie starcza (instrukcja, str. 91:
    /// „Assign|Page X|Multi Column").
    private func moduleAssignMenus(for id: Int) -> some View {
        Group {
            moduleAssignMenu(for: id, global: false)
            moduleAssignMenu(for: id, global: true)
            moduleMidiMenu(for: id)
        }
    }

    /// „Assign MIDI to Selection" i „Deassign MIDI from Selection" — instrukcja wiesza
    /// je w menu Tools (str. 130), ale działają na ZAZNACZENIU, a to żyje na kanwie,
    /// więc trzymamy je razem z resztą poleceń modułu.
    @ViewBuilder
    private func moduleMidiMenu(for id: Int) -> some View {
        let targets = selectedModuleIDs.contains(id) ? selectedModuleIDs : [id]
        Menu("MIDI Controllers") {
            Button("Assign To Selection") { commands.assignMidiToModules?(targets) }
            Button("Remove From Selection") { commands.clearMidiFromModules?(targets) }
        }
        .disabled(commands.assignMidiToModules == nil)
    }

    private func moduleAssignMenu(for id: Int, global: Bool) -> some View {
        Menu(global ? "Global Assign" : "Assign") {
            ForEach(0 ..< G2KnobPages.pageCount, id: \.self) { page in
                Button(Self.pageMenuTitle(page)) {
                    commands.assignAllModuleParameters?(id, page, global)
                }
            }
        }
        .disabled(commands.assignAllModuleParameters == nil)
    }

    /// Etykieta strony w menu: „A1 · Osc" — litera i numer jak na panelu, nazwa grupy
    /// dla orientacji (Knob Floater Overview rysuje jedno pod drugim).
    static func pageMenuTitle(_ page: Int) -> String {
        "\(G2KnobPages.pageLabel(page)) · \(G2KnobPages.groupName(ofPage: page))"
    }

    @ViewBuilder
    private func excludeFromMutationButton(id: Int) -> some View {
        let targets = selectedModuleIDs.contains(id) ? selectedModuleIDs : [id]
        let excluded = modules.first { $0.id == id }?.excludedFromMutation ?? false
        Button {
            onExcludeFromMutation?(targets, !excluded)
        } label: {
            Text(excluded ? "✓ Exclude From Mutations" : "Exclude From Mutations")
        }
    }

    /// ⚠️ **`Image` i `Text` MUSZĄ leżeć wprost w etykiecie przycisku — nie w `Label`.**
    /// Zmierzone `--dump-menu` na macOS 15.7: `Label { Text } icon: { Image }` NIE
    /// dokłada obrazka do `NSMenuItem` (pozycja nie ma nawet kolumny na ikonę), a ta
    /// sama treść podana jako dwa widoki obok siebie — dokłada. Na macOS 26 działa
    /// jedno i drugie, stąd „u mnie widać, u ciebie nie"
    /// → [[Docs/context/bug-history]] #81.
    private func moduleColorMenuItem(id: Int, color: UInt8) -> some View {
        Button {
            onColorModule?(id, color)
        } label: {
            Image(nsImage: ModuleColorPalette.swatchImage(color))
            Text(ModuleColorPalette.name(color))
        }
    }

    func commitNameEdit() {
        guard let id = editingModuleID else { return }
        onRenameModule?(id, editingText)
        editingModuleID = nil
        nameFieldFocused = false
    }

    func cancelNameEdit() {
        editingModuleID = nil
        nameFieldFocused = false
    }

    // MARK: - Delete

    /// Usuwa zaznaczoną grupę albo pojedynczy moduł wskazany z menu/aktywnego stanu.
    func deleteSelectedModules(targetID: Int? = nil) {
        let moduleIDs: Set<Int>
        if let targetID {
            moduleIDs = selectedModuleIDs.contains(targetID) ? selectedModuleIDs : [targetID]
        } else if !selectedModuleIDs.isEmpty {
            moduleIDs = selectedModuleIDs
        } else if let activeModuleID {
            moduleIDs = [activeModuleID]
        } else {
            return
        }

        onDeleteModules?(moduleIDs)
        selectedModuleIDs.subtract(moduleIDs)
        if let activeModuleID, moduleIDs.contains(activeModuleID) {
            self.activeModuleID = nil
        }
        if let editingModuleID, moduleIDs.contains(editingModuleID) {
            self.editingModuleID = nil
            nameFieldFocused = false
        }
    }

    // MARK: - Copy / Paste

    /// Buduje G2ClipboardContent z aktualnie zaznaczonych modułów i zapisuje na schowek.
    func copySelectedModules() {
        // Zaznaczone moduły — lub aktywny jeśli brak selection
        var ids = selectedModuleIDs
        if ids.isEmpty, let id = activeModuleID { ids = [id] }
        guard let content = G2ClipboardContent.make(modules: modules, cables: cables, ids: ids,
                                                    labels: commands.moduleLabels?())
        else { return }
        content.writeToPasteboard()
    }
}
