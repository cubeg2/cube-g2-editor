// PatchBoundViews.swift
// Widoki, które czytają patch (`state.slots`) — wydzielone z `ContentView`, żeby ruch
// gałki budził tylko je, a nie całe okno.
//
// Pod `@Observable` każda zmiana parametru to zapis do `slots`, a SwiftUI unieważnia
// wtedy KAŻDY widok, którego `body` przeczytało `slots` — choćby tylko `slots.count`.
// Do 2026-09-21 robiły to `RootView` (synchronizacja okien slotów) i `ContentView`
// (liczniki w belce, obciążenie DSP, podtytuł okna, kanwa), więc jeden tick gałki
// przeliczał od nowa belkę, pasy slotów, szufladę modułów i panel Banks: zmierzone
// 9–10 ms na tick przy 125 modułach, czyli przy ruchu myszy 60–120 zdarzeń/s główny
// wątek nie nadążał i gałka „nie kręciła się płynnie". Oryginał ma to z natury: gałka
// odświeża tam jeden widżet, nie okno → [[Docs/ui/canvas-performance]].

import G2Core
import G2EditorCore
import SwiftUI

/// Patch slotu tego okna — jedyne miejsce, z którego kanwa, liczniki i „Zoom to Fit"
/// mają brać dane. Nigdy `state.patch`: ten jest slotem z focusem, a okno slotu B ma
/// pokazywać B także wtedy, gdy edytowany jest A.
extension PatchState {
    func patch(inSlot slot: Int) -> G2Patch {
        slots.indices.contains(slot) ? slots[slot] : G2Patch()
    }
}

/// Kanwa jednego obszaru wraz z kompletem poleceń. To tu `slots` jest czytane, więc
/// tick gałki przerysowuje kanwę i nic ponad nią.
struct CanvasPane: View {
    let state: PatchState
    let viewState: CanvasViewState
    let selections: CanvasSelectionHub
    let device: DeviceConnection
    let panels: PanelController
    let slot: Int
    let area: PatchArea
    let zoom: CGFloat
    let minSize: CGSize
    let controller: CanvasZoomPanController
    let cableStyle: CableStyle
    let knobControl: KnobControl
    let knobStyle: KnobLook
    let panelShading: Bool
    /// Pod kanwą leży warstwa ze spektrogramem — kanwa nie zamalowuje wtedy tła.
    var showsBackdrop = false
    /// Moduł dodany z kanwy (wklejenie, upuszczenie) — lista ostatnio używanych
    /// mieszka w `ContentView`.
    let onModuleAdded: (Int) -> Void

    var body: some View {
        PatchCanvasView(
            patch: state.patch(inSlot: slot),
            area: area,
            zoom: zoom,
            hiddenColors: viewState.effectiveHiddenCableColors,
            cableShakeSeed: viewState.cableShakeSeed,
            overlayMode: viewState.overlayMode,
            cableStyle: cableStyle,
            knobControl: knobControl,
            knobStyle: knobStyle,
            panelShading: panelShading,
            showsBackdrop: showsBackdrop,
            device: device,
            slot: slot,
            selection: selections.selection(for: area),
            minSize: minSize,
            onParameterChange: { moduleID, paramIndex, value in
                state.setParameter(moduleID: moduleID,
                                   paramIndex: paramIndex,
                                   value: value,
                                   area: area)
            },
            onMomentaryParameterChange: { moduleID, paramIndex, value in
                state.setMomentaryParameter(moduleID: moduleID,
                                            paramIndex: paramIndex,
                                            value: value,
                                            area: area)
            },
            focusedMorph: state.focusedMorph,
            onMorphRangeChange: { moduleID, paramIndex, range in
                state.setMorphRange(location: area == .voice ? 1 : 0,
                                    moduleID: moduleID,
                                    paramIndex: paramIndex,
                                    morph: state.focusedMorph,
                                    range: range)
            },
            onKnobAssign: { moduleID, paramIndex in
                state.assignKnobToFocusedPage(
                    location: area == .voice ? 1 : 0,
                    moduleID: moduleID,
                    paramIndex: paramIndex
                )
            },
            onParameterPageKnobDrop: { knob, moduleID, paramIndex in
                state.assignParameterPageKnob(
                    index: knob,
                    location: area == .voice ? 1 : 0,
                    moduleID: moduleID,
                    paramIndex: paramIndex
                )
            },
            onParameterGestureBegan: { state.beginParameterGesture() },
            onParameterGestureEnded: { state.endParameterGesture() },
            onModeChange: { moduleID, modeIndex, value in
                state.setMode(moduleID: moduleID,
                              modeIndex: modeIndex,
                              value: value,
                              area: area)
            },
            onAddCable: { cable in
                state.addCable(cable)
            },
            onRemoveCable: { cable in
                state.removeCable(cable)
            },
            onStructureGestureBegan: { name in
                state.beginStructureGesture(name)
            },
            onStructureGestureEnded: {
                state.endStructureGesture()
            },
            onMoveModule: { moduleID, newColumn, newRow, push in
                state.moveModule(moduleID: moduleID,
                                 newColumn: newColumn,
                                 newRow: newRow,
                                 area: area,
                                 push: push)
            },
            onRenameModule: { moduleID, label in
                state.renameModule(moduleID: moduleID, label: label, area: area)
            },
            onDeleteModules: { moduleIDs in
                state.deleteModules(moduleIDs: moduleIDs, area: area)
            },
            onColorModule: { moduleID, color in
                state.setModuleColor(moduleID: moduleID, color: color, area: area)
            },
            onExcludeFromMutation: { moduleIDs, excluded in
                state.setModulesExcludedFromMutation(moduleIDs, excluded: excluded)
            },
            mutatorVisible: panels.windows.contains(.mutator),
            audibilityVisible: panels.windows.contains(.mutator) && panels.effectiveMutatorSettings.onlyAudible,
            onReplaceModule: { moduleID, targetTypeID in
                state.replaceModule(
                    moduleID: moduleID,
                    targetTypeID: targetTypeID,
                    area: area
                )
            },
            onAddModuleAt: { typeID, col, row in
                state.addModule(typeID: typeID, area: area, column: col, row: row)
                onModuleAdded(typeID)
            },
            onPasteModules: { content in
                state.pasteModules(content, area: area)
            },
            commands: commands,
            zoomPanController: controller,
            onZoomChange: { viewState.zoom = $0 }
        )
        // Kanwa rysuje się od nowa tylko wtedy, gdy zmieni się coś, co widać —
        // patrz `PatchCanvasView: Equatable`.
        .equatable()
    }

    /// Polecenia menu kontekstowego kanwy — patrz `PatchCanvasCommands`.
    /// `location` w protokole to numer obszaru: 1 = Voice, 0 = FX. Obszar jest
    /// argumentem, bo przy podzielonym oknie każda połowa dostaje własny komplet.
    private var commands: PatchCanvasCommands {
        let location = area.rawValue
        return PatchCanvasCommands(
            assignKnobToPage: { moduleID, paramIndex, page in
                state.assignKnob(toPage: page, location: location,
                                 moduleID: moduleID, paramIndex: paramIndex)
            },
            clearKnob: { moduleID, paramIndex in
                state.clearKnob(location: location, moduleID: moduleID, paramIndex: paramIndex)
            },
            knobIndexFor: { moduleID, paramIndex in
                state.knobIndex(location: location, moduleID: moduleID, paramIndex: paramIndex)
            },
            assignGlobalKnobToPage: { moduleID, paramIndex, page in
                state.assignGlobalKnob(toPage: page, location: location,
                                       moduleID: moduleID, paramIndex: paramIndex)
            },
            clearGlobalKnob: { moduleID, paramIndex in
                state.clearGlobalKnob(location: location, moduleID: moduleID, paramIndex: paramIndex)
            },
            globalKnobIndexFor: { moduleID, paramIndex in
                state.globalKnobIndex(location: location, moduleID: moduleID, paramIndex: paramIndex)
            },
            assignAllModuleParameters: { moduleID, page, global in
                state.assignAllParameters(ofModule: moduleID, area: area,
                                          toPage: page, global: global)
            },
            assignMidiController: { moduleID, paramIndex, cc in
                state.assignMidiController(cc: cc, location: location,
                                           moduleID: moduleID, paramIndex: paramIndex)
            },
            clearMidiController: { moduleID, paramIndex in
                state.clearMidiController(location: location, moduleID: moduleID,
                                          paramIndex: paramIndex)
            },
            midiControllerFor: { moduleID, paramIndex in
                state.midiController(location: location, moduleID: moduleID, paramIndex: paramIndex)
            },
            assignMidiToModules: { state.assignMidiControllers(toModules: $0, area: area) },
            clearMidiFromModules: { state.clearMidiControllers(forModules: $0, area: area) },
            disconnectCable: { state.disconnectCable($0, area: area) },
            breakCable: { state.breakCable($0, area: area) },
            deleteCableChain: { state.deleteCableChain($0, area: area) },
            setCableColor: { cable, color in
                state.setCableColor(color, forChainContaining: cable, area: area)
            },
            deleteUnusedCables: { state.deleteUnusedCables(area: area) },
            unusedCableCount: { state.unusedCableCount(area: area) },
            pasteParams: { moduleIDs in
                guard let content = G2ClipboardContent.readFromPasteboard() else { return }
                state.pasteParameters(content, into: moduleIDs, area: area)
            },
            deleteUnusedModules: { state.deleteUnusedModules(area: area) },
            unusedModuleCount: { state.unusedModuleIDs(area: area).count }
        )
    }
}

/// Obciążenie slotu, który jest na ekranie — cztery liczby w układzie oryginału
/// Clavii (Voice i FX × moc i pamięć), z paskiem pod każdą. Rozkład na siedem
/// pamięci i pozostałe sloty są w oknie „DSP Load".
///
/// Bez podłączonego Norda liczy to samo `G2PatchLoad.estimate` co panel — inaczej
/// belka milczałaby dokładnie wtedy, gdy okno obok podaje liczby.
struct ToolbarPatchLoad: View {
    let state: PatchState
    let device: DeviceConnection
    let slot: Int

    var body: some View {
        let voice = load(area: .voice)
        let fx = load(area: .fx)
        if voice != nil || fx != nil {
            PatchLoadReadout(voice: voice, fx: fx, layout: .toolbar,
                             scale: TopBarMetrics.readoutScale,
                             labelColor: .secondary)
                .help("Patch load — Voice and FX areas, cycles and memory (⌘⌥3 for the full picture)")
        }
    }

    private func load(area: PatchArea) -> G2PatchLoad? {
        if let reported = device.patchLoad(slot: slot, area: area) { return reported }
        guard state.slots.indices.contains(slot) else { return nil }
        return .estimate(area: area, modules: state.slots[slot].modules(in: area))
    }
}

/// Ile modułów i kabli w oglądanym obszarze — dwa wiersze, żeby nie rozpychać
/// belki w bok.
struct ToolbarPatchStats: View {
    let state: PatchState
    let slot: Int
    let area: PatchArea

    var body: some View {
        let patch = state.patch(inSlot: slot)
        TopBarCaption(
            text: "\(patch.modules(in: area).count) modules",
            secondLine: "\(patch.cables(in: area).count) cables"
        )
    }
}

/// Cztery rzędy pasów slotów (View ▸ Slot Layout ▸ Four Rows) — po jednym na slot.
/// Zwykły patch ma jeden slot, więc cztery rzędy sprowadzają się do jednego.
struct SlotBarRows: View {
    let state: PatchState
    let device: DeviceConnection

    var body: some View {
        VStack(spacing: 0) {
            ForEach(state.slots.indices, id: \.self) { row in
                if row > 0 { Divider() }
                SlotBarView(state: state, device: device, slot: row, layout: .fourRows)
            }
        }
    }
}

/// Tytuł i podtytuł okna. Siedzą w osobnym, pustym widoku, bo podtytuł liczy moduły
/// patcha — gdyby liczył je `ContentView`, każdy tick gałki budziłby całe okno.
/// Tytuł przy slotach w oknach to zakładka: litera slotu i nazwa patcha, jak w oknach
/// slotów B–D (`SlotWindows.title`); poza tym nazwa pliku.
struct DocumentTitles: View {
    let state: PatchState
    let slot: Int
    let layout: SlotLayout

    private static let slotLabels = ["A", "B", "C", "D"]

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
    }

    private var title: String {
        layout == .windows
            ? SlotWindows.title(slot: slot, state: state)
            : state.title
    }

    private var subtitle: String {
        let patch = state.patch(inSlot: slot)
        let slotPart = Self.slotLabels.indices.contains(slot)
            ? " · Slot \(Self.slotLabels[slot])" : ""
        return "\(patch.voiceModules.count) voice · \(patch.fxModules.count) FX modules\(slotPart)"
    }
}
