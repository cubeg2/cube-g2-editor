import AppKit
import G2Core
import G2EditorCore
import SwiftUI

extension PatchCanvasView {
    // MARK: - Combined drag gesture

    var combinedDragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { g in
                guard !exportingBlock else { return }
                let startLP = CGPoint(x: g.startLocation.x / zoom, y: g.startLocation.y / zoom)
                let curLP = CGPoint(x: g.location.x / zoom, y: g.location.y / zoom)

                // ── Inicjalizacja celu na pierwszym evencie ──────────────────
                if connectorDrag == nil && repatchDrag == nil && dragTarget == nil && moduleDrag == nil && rubberBandStart == nil {
                    let shiftHeld = NSEvent.modifierFlags.contains(.shift)
                    if let conn = findConnector(at: startLP) {
                        let optionHeld = NSEvent.modifierFlags.contains(.option)
                        let attached = cablesAt(connector: conn)

                        if optionHeld, !attached.isEmpty {
                            // Option + gniazdo z kablami → repatch (cycling)
                            let key = ConnectorCycleKey(moduleID: conn.moduleID,
                                                        connIndex: conn.connIndex,
                                                        isOutput: conn.isOutput)
                            let idx = cycleIndex[key, default: 0] % attached.count
                            let cable = attached[idx]
                            cycleIndex[key] = idx + 1

                            onStructureGestureBegan?("Repatch Cable")
                            onRemoveCable?(cable)

                            if let anchor = anchorEndpoint(cable: cable, grabbed: conn) {
                                repatchDrag = RepatchDragState(anchor: anchor,
                                                               originalCable: cable,
                                                               tipPt: curLP)
                            }
                        } else {
                            // Domyślnie → zawsze nowy kabel (też gdy Option ale brak kabli)
                            connectorDrag = ConnectorDragState(source: conn, tipPt: curLP)
                        }
                    } else if let hit = findKnob(at: startLP) {
                        // Option na gałce = zmiana ZAKRESU MORFU z focusem, nie wartości
                        // parametru (oryginał: `gLockMode == 2`) → [[Docs/ui/morphs]].
                        let morphDrag = NSEvent.modifierFlags.contains(.option)
                        dragTarget = KnobDragTarget(moduleID: hit.moduleID,
                                                    paramIndex: hit.paramIndex,
                                                    startValue: hit.currentValue,
                                                    startY: g.startLocation.y,
                                                    fine: shiftHeld,
                                                    sensitivity: hit.dragSensitivity,
                                                    readout: hit.readout,
                                                    startPoint: startLP,
                                                    center: hit.center,
                                                    startRange: morphRange(moduleID: hit.moduleID,
                                                                           paramIndex: hit.paramIndex),
                                                    isMorph: morphDrag)
                        // Złapana gałka dostaje focus — po puszczeniu myszy strzałki
                        // dostrajają dokładnie ją.
                        focusedParam = ParameterFocus(moduleID: hit.moduleID,
                                                      paramIndex: hit.paramIndex)
                        activeModuleID = hit.moduleID
                        // Cały ruch gałki = jeden wpis undo (patrz PatchState.beginParameterGesture)
                        onParameterGestureBegan?()
                    } else if let hit = findModuleBody(at: startLP) {
                        let extras: [(id: Int, startColumn: Int, startRow: Int)]
                        if selectedModuleIDs.contains(hit.moduleID) {
                            extras = modules
                                .filter { selectedModuleIDs.contains($0.id) && $0.id != hit.moduleID }
                                .map { (id: $0.id, startColumn: $0.column, startRow: $0.row) }
                        } else {
                            selectedModuleIDs.removeAll()
                            extras = []
                        }
                        moduleDrag = ModuleDragState(moduleID: hit.moduleID,
                                                     startColumn: hit.column,
                                                     startRow: hit.row,
                                                     extraModules: extras,
                                                     dragOffset: .zero)
                    } else {
                        // Drag na pustym tle → rubber-band selection.
                        // Bez Shift zaczynamy od czystego zaznaczenia (ramka je zastępuje),
                        // z Shift dokładamy do bieżącego (onEnded robi wtedy toggle).
                        if !shiftHeld { selectedModuleIDs.removeAll() }
                        rubberBandStart = startLP
                        rubberBandCurrent = startLP
                    }
                }

                // ── Aktualizacja tip podczas draga ──────────────────────────
                if rubberBandStart != nil { rubberBandCurrent = curLP
                    return
                }
                if connectorDrag != nil { connectorDrag?.tipPt = curLP
                    return
                }
                if repatchDrag != nil { repatchDrag?.tipPt = curLP
                    return
                }

                // ── Module drag ──────────────────────────────────────────────
                if let drag = moduleDrag {
                    if startBlockExportIfOutside(drag) { return }
                    moduleDrag?.dragOffset = CGSize(
                        width: (g.location.x - g.startLocation.x) / zoom,
                        height: (g.location.y - g.startLocation.y) / zoom
                    )
                    return
                }

                // ── Knob/Slider drag ─────────────────────────────────────────
                guard let target = dragTarget else { return }
                let maxValue = modules.first(where: { $0.id == target.moduleID })
                    .flatMap { ParameterRangeDatabase.range(moduleTypeID: $0.typeID, codeRef: target.paramIndex) }
                    .map(\.upperBound) ?? 127

                // Tryb „Circular" liczy wartość WPROST z kąta, nie z przyrostu — stąd
                // opisany w instrukcji przeskok z maksimum na minimum przy 6 godzinie.
                // Zmiany zakresu morfu to zawsze przyrost: kąt opisywałby wartość
                // parametru, a nie długość czerwonego wycinka.
                if knobControl == .circular, !target.isMorph,
                   let value = KnobControl.circularValue(at: curLP, center: target.center,
                                                         maxValue: maxValue)
                {
                    onParameterChange?(target.moduleID, target.paramIndex, value)
                    if target.sensitivity > 0.1 { showSeqSliderTooltip(target.readout, screenPos: g.location) }
                    return
                }

                // W prawo = więcej, w górę = więcej. Slidery: droga myszy jest w
                // screen-space, a `sliderH` w canvas-space → koryguj zoom.
                let rawDistance = knobControl == .horizontal
                    ? g.location.x - g.startLocation.x
                    : target.startY - g.location.y
                let dy = target.sensitivity > 1.0 ? rawDistance / zoom : rawDistance
                let sens: CGFloat = target.fine ? target.sensitivity * 0.1 : target.sensitivity
                let delta = Int((dy * sens).rounded())
                if target.isMorph {
                    // Zakres morfu przycięty tak, żeby wartość docelowa (baza + zakres)
                    // została w granicach parametru — dokładnie ten warunek pilnuje
                    // oryginał (Control (ClickDragIdleHandler), gLockMode 2).
                    let base = target.startValue
                    let range = max(-base, min(maxValue - base, target.startRange + delta))
                    onMorphRangeChange?(target.moduleID, target.paramIndex, range)
                    return
                }
                let newValue = max(0, min(maxValue, target.startValue + delta))
                onParameterChange?(target.moduleID, target.paramIndex, newValue)
                // Tooltip podczas przeciągania sekwencera (wysoka czułość = slider, nie gałka rotacyjna)
                if target.sensitivity > 0.1 {
                    showSeqSliderTooltip(target.readout, screenPos: g.location)
                }
            }
            .onEnded { g in
                defer { if dragTarget != nil { onParameterGestureEnded?() }
                    if repatchDrag != nil { onStructureGestureEnded?() }
                    connectorDrag = nil
                    repatchDrag = nil
                    dragTarget = nil
                    moduleDrag = nil
                    rubberBandStart = nil
                    rubberBandCurrent = nil
                }
                guard !exportingBlock else { return }
                let endLP = CGPoint(x: g.location.x / zoom, y: g.location.y / zoom)

                // Rubber-band → toggle zaznaczenia modułów w prostokącie
                if let rbStart = rubberBandStart, let rbEnd = rubberBandCurrent {
                    let rect = CGRect(x: min(rbStart.x, rbEnd.x), y: min(rbStart.y, rbEnd.y),
                                      width: abs(rbEnd.x - rbStart.x), height: abs(rbEnd.y - rbStart.y))
                    let inRect = modulesInRect(rect)
                    selectedModuleIDs.subtract(selectedModuleIDs.intersection(inRect))
                    selectedModuleIDs.formUnion(inRect.subtracting(selectedModuleIDs))
                    return
                }

                if let drag = repatchDrag {
                    // Upuszczenie na gniazdo → reconnect; na puste miejsce → kabel skasowany
                    if let target = findConnector(at: endLP) {
                        tryAddCable(from: drag.anchor, to: target)
                    }
                    return
                }

                if let drag = connectorDrag {
                    guard let target = findConnector(at: endLP) else { return }
                    tryAddCable(from: drag.source, to: target)
                }

                if let drag = moduleDrag {
                    let snapped = snapToGrid(dragState: drag, dropPt: endLP)
                    let dCol = snapped.column - drag.startColumn
                    let dRow = snapped.row - drag.startRow
                    if dCol != 0 || dRow != 0 {
                        // Kierunek push z kierunku ruchu, nie z geometrii kolizji.
                        // push .down gdy moduł idzie w dół lub zostaje; .up gdy idzie w górę.
                        let push: G2Patch.PushDirection = dRow >= 0 ? .down : .up
                        onMoveModule?(drag.moduleID, snapped.column, snapped.row, push)
                        for extra in drag.extraModules {
                            onMoveModule?(extra.id,
                                          max(0, extra.startColumn + dCol),
                                          max(0, extra.startRow + dRow),
                                          push)
                        }
                    }
                }
            }
    }

    /// Chwytane ZAZNACZONE moduły wyjechały poza widoczną kanwę: przesuwanie się kończy (moduły
    /// wracają na miejsce), a zaczyna zwykłe przeciąganie bloku — na listę Patches ▸ Blocks albo
    /// na jej folder, gdzie zapisuje się pod nazwą z okienka (`BlockExportDragData`). Moduł
    /// niezaznaczony zostaje przy przesuwaniu (decyzja użytkownika 2026-10-23).
    func startBlockExportIfOutside(_ drag: ModuleDragState) -> Bool {
        guard selectedModuleIDs.contains(drag.moduleID) else { return false }
        guard let view = dragSource.view, view.pointerLeftVisibleCanvas else { return false }
        let ids = Set([drag.moduleID] + drag.extraModules.map(\.id))
        guard let block = commands.blockFromModules?(ids) else { return false }
        let preview = BlockDragPreview(name: ids.count == 1 ? "1 module" : "\(ids.count) modules", load: nil)
        guard let image = ImageRenderer(content: preview).nsImage,
              view.beginBlockExport(BlockExportDragData.begin(block), image: image,
                                    ended: { exportingBlock = false })
        else { return false }
        moduleDrag = nil
        exportingBlock = true
        return true
    }

    /// Zakres morfu z focusem dla parametru w bieżącej wariacji — 0, gdy nie przypisany.
    func morphRange(moduleID: Int, paramIndex: Int) -> Int {
        patch.morphRange(variation: patch.activeVariation,
                         location: area == .voice ? 1 : 0,
                         moduleID: moduleID, paramIndex: paramIndex, morph: focusedMorph)
    }

    // MARK: - ButtonIncDec (+/-): przytrzymanie = auto-powtarzanie kroku

    struct IncDecHoldState: Equatable {
        let moduleID: Int
        let codeRef: Int
        let isUp: Bool
        let range: ClosedRange<Int>
    }

    /// Osobna gestura (minimumDistance:0 — łapie samo mouseDown, bez wymogu ruchu) dołączana
    /// przez `.simultaneousGesture` PO zwykłym tapie. Poza przyciskami +/- nic nie robi
    /// (`findIncDecButton` zwraca nil), a równoległe rozpoznawanie nie blokuje kliknięć ani
    /// `combinedDragGesture`, który pozostaje źródłem prawdy dla pozostałych interakcji.
    /// Klik = jeden krok (onChanged przy mouseDown), przytrzymanie = auto-powtarzanie
    /// (startIncDecRepeat), puszczenie = stop (onEnded).
    var incDecPressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                guard incDecHold == nil else { return }
                let lp = CGPoint(x: g.startLocation.x / zoom, y: g.startLocation.y / zoom)
                guard let hit = findIncDecButton(at: lp) else { return }
                incDecHold = hit
                // Klik i całe auto-powtarzanie = jeden wpis undo (do puszczenia przycisku)
                onParameterGestureBegan?()
                let cur = currentValue(for: hit)
                let newVal = hit.isUp ? min(hit.range.upperBound, cur + 1) : max(hit.range.lowerBound, cur - 1)
                onParameterChange?(hit.moduleID, hit.codeRef, newVal)
                startIncDecRepeat(hit, from: newVal)
            }
            .onEnded { _ in
                stopIncDecRepeat()
            }
    }

    private func findIncDecButton(at point: CGPoint) -> IncDecHoldState? {
        let ro = rowOffset
        let mods = modules
        for module in mods {
            guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { continue }
            let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)
            for btn in ui.incDecButtons {
                let origin = operatorIncDecOrigin(module: module, button: btn)
                let x = rect.minX + origin.x
                let sq: CGFloat = UIMetrics.incDecHeight
                let gap: CGFloat = UIMetrics.incDecGap
                // Musi się zgadzać z dociśnięciem w drawBVButtons (PatchCanvasView+Rendering.swift) —
                // inaczej trafienie w klik nie pokrywa się z tym, co narysowane.
                let totalH = btn.isVertical ? sq * 2 + gap : sq
                let bottomMargin: CGFloat = 1.0
                let y = min(rect.minY + origin.y, rect.maxY - bottomMargin - totalH)
                // Ta sama zamiana lewej/prawej co w drawBVButtons: poziomo „−" jest z
                // LEWEJ, „+" z PRAWEJ — musi się zgadzać z tym, co narysowane.
                let leftRect = CGRect(x: x, y: y, width: sq, height: sq)
                let secondRect = btn.isVertical
                    ? CGRect(x: x, y: y + sq + gap, width: sq, height: sq)
                    : CGRect(x: x + sq + gap, y: y, width: sq, height: sq)
                let upRect = btn.isVertical ? leftRect : secondRect
                let dnRect = btn.isVertical ? secondRect : leftRect
                let range = ParameterRangeDatabase.range(moduleTypeID: module.typeID, codeRef: btn.codeRef)
                    ?? (0 ... (btn.infoFunc == 2 ? 15 : 127))
                if upRect.insetBy(dx: -1, dy: -1).contains(point) {
                    return IncDecHoldState(moduleID: module.id, codeRef: btn.codeRef, isUp: true, range: range)
                }
                if dnRect.insetBy(dx: -1, dy: -1).contains(point) {
                    return IncDecHoldState(moduleID: module.id, codeRef: btn.codeRef, isUp: false, range: range)
                }
            }
        }
        return nil
    }

    private func currentValue(for hit: IncDecHoldState) -> Int {
        guard let module = modules.first(where: { $0.id == hit.moduleID }) else { return 0 }
        return hit.codeRef < module.parameters.count ? module.parameters[hit.codeRef] : 0
    }

    /// Opóźnienie startowe 350ms (żeby zwykły klik nie dorzucił drugiego kroku), potem
    /// powtarzanie co 90ms aż do puszczenia (stopIncDecRepeat, wołane z onEnded gestury).
    ///
    /// `PatchCanvasView` to `struct` — `self` złapane przez `Task` jest ZAMROŻONĄ kopią
    /// z momentu wciśnięcia (wartość `patch` się nie zmienia wraz z odświeżeniami widoku).
    /// Odczyt `currentValue(for:)` na każdym powtórzeniu zwracałby więc zawsze tę samą,
    /// nieaktualną wartość — krok liczony na jej podstawie nigdy by nie postępował.
    /// Dlatego licznik trzymamy LOKALNIE w pętli (`value`), niezależnie od `self`.
    private func startIncDecRepeat(_ hit: IncDecHoldState, from startValue: Int) {
        incDecRepeatTask?.cancel()
        incDecRepeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            var value = startValue
            while !Task.isCancelled {
                value = hit.isUp
                    ? min(hit.range.upperBound, value + 1)
                    : max(hit.range.lowerBound, value - 1)
                onParameterChange?(hit.moduleID, hit.codeRef, value)
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
        }
    }

    private func stopIncDecRepeat() {
        incDecRepeatTask?.cancel()
        incDecRepeatTask = nil
        if incDecHold != nil { onParameterGestureEnded?() }
        incDecHold = nil
    }
}
