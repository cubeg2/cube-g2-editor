// PatchCanvasView+KeyNavigation.swift
// Strzałki nad patchem — dolna połowa tabeli skrótów z instrukcji Clavii (str. 132):
//
//   ↑ / ↓                wartość parametru z focusem, o jeden krok
//   ← / →                focus na poprzednią / następną kontrolkę modułu
//   Ctrl + ↑ / ↓         zakres morfu parametru z focusem
//   Shift + ↑↓←→         focus na sąsiedni moduł, po tym jak leżą na ekranie
//
// „Focus" to jedna kontrolka jednego modułu. Ustawia go kliknięcie (albo złapanie
// gałki myszą) i to on dostaje obwódkę, żeby było widać, czego dotkną strzałki.

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

/// Kontrolka, której dotyczą strzałki.
struct ParameterFocus: Equatable {
    let moduleID: Int
    let paramIndex: Int
}

extension PatchCanvasView {
    // MARK: - Obsługa klawiszy

    /// `true` = strzałka obsłużona, zdarzenie nie idzie dalej.
    func handleArrowKey(_ direction: ArrowDirection, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers.contains(.shift) {
            return moveModuleFocus(direction)
        }
        guard let focus = focusedParam else { return false }

        switch direction {
        case .left, .right:
            // Instrukcja: „Ctrl + Arrow Left/Right — same as Arrow Left/Right".
            return moveParameterFocus(from: focus, forward: direction == .right)
        case .up, .down:
            let step = direction == .up ? 1 : -1
            if modifiers.contains(.control) {
                return nudgeMorphRange(focus, by: step)
            }
            return nudgeValue(focus, by: step)
        }
    }

    private func nudgeValue(_ focus: ParameterFocus, by step: Int) -> Bool {
        guard let module = modules.first(where: { $0.id == focus.moduleID }),
              module.parameters.indices.contains(focus.paramIndex) else { return false }
        let range = ParameterRangeDatabase.range(moduleTypeID: module.typeID,
                                                 codeRef: focus.paramIndex) ?? 0 ... 127
        let value = module.parameters[focus.paramIndex] + step
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        showKeyHint(focus)
        guard clamped != module.parameters[focus.paramIndex] else { return true }
        onParameterChange?(focus.moduleID, focus.paramIndex, clamped)
        return true
    }

    private func nudgeMorphRange(_ focus: ParameterFocus, by step: Int) -> Bool {
        guard let module = modules.first(where: { $0.id == focus.moduleID }) else { return false }
        let range = ParameterRangeDatabase.range(moduleTypeID: module.typeID,
                                                 codeRef: focus.paramIndex) ?? 0 ... 127
        let base = module.parameters.indices.contains(focus.paramIndex)
            ? module.parameters[focus.paramIndex] : 0
        let current = morphRange(moduleID: focus.moduleID, paramIndex: focus.paramIndex)
        // Ten sam warunek co przy Option-przeciąganiu: wartość docelowa (baza + zakres)
        // musi zostać w granicach parametru.
        let wanted = max(range.lowerBound - base,
                         min(range.upperBound - base, current + step))
        showKeyHint(focus)
        guard wanted != current else { return true }
        onMorphRangeChange?(focus.moduleID, focus.paramIndex, wanted)
        return true
    }

    /// Kolejność kontrolek w module bierzemy z pliku BVerhue — tej samej, w której
    /// są rysowane, więc „następna" znaczy „następna na panelu".
    private func moveParameterFocus(from focus: ParameterFocus, forward: Bool) -> Bool {
        guard let module = modules.first(where: { $0.id == focus.moduleID }),
              let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return false }
        let refs = ui.knobs.map(\.codeRef)
        guard let position = refs.firstIndex(of: focus.paramIndex), refs.count > 1 else { return false }
        let next = (position + (forward ? 1 : refs.count - 1)) % refs.count
        focusedParam = ParameterFocus(moduleID: focus.moduleID, paramIndex: refs[next])
        return true
    }

    /// Shift + strzałka: „The modules in a Patch are accessed depending on how they
    /// were visually placed in the Patch window" (instrukcja, str. 84) — więc szukamy
    /// najbliższego modułu w danym kierunku, licząc po siatce.
    private func moveModuleFocus(_ direction: ArrowDirection) -> Bool {
        let mods = modules
        guard !mods.isEmpty else { return false }
        guard let currentID = focusedParam?.moduleID ?? activeModuleID,
              let current = mods.first(where: { $0.id == currentID })
        else {
            selectModule(mods[0])
            return true
        }

        let candidates = mods.filter { candidate in
            switch direction {
            case .up: candidate.column == current.column && candidate.row < current.row
            case .down: candidate.column == current.column && candidate.row > current.row
            case .left: candidate.column < current.column
            case .right: candidate.column > current.column
            }
        }
        let nearest = candidates.min { lhs, rhs in
            distance(from: current, to: lhs, direction: direction)
                < distance(from: current, to: rhs, direction: direction)
        }
        guard let nearest else { return true } // krawędź patcha — nic nie robimy
        selectModule(nearest)
        return true
    }

    private func distance(from current: G2Module, to candidate: G2Module,
                          direction: ArrowDirection) -> Int
    {
        switch direction {
        case .up, .down:
            abs(candidate.row - current.row)
        case .left, .right:
            // W poziomie liczy się przede wszystkim kolumna, a przy remisie bliskość wiersza.
            abs(candidate.column - current.column) * 128 + abs(candidate.row - current.row)
        }
    }

    /// Focus przechodzi na pierwszą kontrolkę modułu — jest wtedy od razu co kręcić.
    private func selectModule(_ module: G2Module) {
        activeModuleID = module.id
        let firstRef = ModuleUIDatabase.shared.uiDef(forID: module.typeID)?.knobs.first?.codeRef
        focusedParam = firstRef.map { ParameterFocus(moduleID: module.id, paramIndex: $0) }
    }

    // MARK: - Obwódka kontrolki z focusem

    /// Cienka ramka wokół kontrolki, której dotyczą strzałki. Montowana tylko wtedy,
    /// gdy focus w ogóle jest.
    @ViewBuilder
    var parameterFocusOverlay: some View {
        if !isPreviewMode, let focus = focusedParam, let rect = focusRect(focus) {
            Canvas { ctx, _ in
                ctx.scaleBy(x: zoom, y: zoom)
                ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.2, dy: -1.2), cornerRadius: 1.5),
                           with: .color(Color.accentColor.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 0.6))
            }
            .allowsHitTesting(false)
        }
    }

    /// Prostokąt kontrolki z focusem w układzie canvasu.
    func focusRect(_ focus: ParameterFocus) -> CGRect? {
        let ro = rowOffset
        let mods = modules
        guard let module = mods.first(where: { $0.id == focus.moduleID }),
              let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID),
              let knob = ui.knobs.first(where: { $0.codeRef == focus.paramIndex })
        else { return nil }
        let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                          rowOffset: ro, allModules: mods)
        let origin = knobOrigin(module: module, knob: knob)
        let x = rect.minX + origin.x
        let y = rect.minY + origin.y
        if knob.type.isRotary {
            let radius = knob.type.radiusPt
            let center = knob.type.centerOffsetPt
            return CGRect(x: x + center.x - radius, y: y + center.y - radius,
                          width: radius * 2, height: radius * 2)
        }
        if knob.type == .slider || knob.type == .seqSlider {
            return faderLayout(module: module, knob: knob, ui: ui, rect: rect).track
        }
        let size = knob.type.sliderSizePt
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Cztery strzałki — osobny typ, żeby `handleArrowKey` nie żonglował kodami klawiszy.
enum ArrowDirection {
    case up, down, left, right

    /// Kody klawiszy strzałek na klawiaturze Apple.
    static func from(keyCode: UInt16) -> ArrowDirection? {
        switch keyCode {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        default: nil
        }
    }
}

// MARK: - Most do AppKit

/// Monitor strzałek nad kanwą. Ten sam wzorzec co `CanvasZoomPanNSView`: lokalny
/// monitor zdarzeń, który przepuszcza wszystko, czego nie obsłuży, i schodzi z drogi
/// polom tekstowym.
struct CanvasArrowKeysRepresentable: NSViewRepresentable {
    let handler: (ArrowDirection, NSEvent.ModifierFlags) -> Bool

    func makeNSView(context _: Context) -> CanvasArrowKeysNSView {
        let view = CanvasArrowKeysNSView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: CanvasArrowKeysNSView, context _: Context) {
        view.handler = handler
    }
}

final class CanvasArrowKeysNSView: NSView {
    var handler: ((ArrowDirection, NSEvent.ModifierFlags) -> Bool)?

    private var monitor: Any?

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        } else if window == nil {
            removeMonitor()
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, window.isKeyWindow, event.window === window else { return event }
        guard let direction = ArrowDirection.from(keyCode: event.keyCode) else { return event }
        // ⌘ zostawiamy systemowi (nawigacja po menu, skróty), a ⌥↑/⌥↓ przeglądarce
        // patchy (`PatchStepKeys` w `BanksPanel`) — kanwa ⌥ i tak niczym nie różniła.
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option)
        else { return event }
        // Lista panelu Patches i pola tekstowe nawigują strzałkami same — patrz `KeyEventScope`.
        if KeyEventScope.belongsToAnotherControl(in: window) { return event }
        return handler?(direction, event.modifierFlags) == true ? nil : event
    }
}
