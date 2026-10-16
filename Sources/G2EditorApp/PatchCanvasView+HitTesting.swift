import AppKit
import G2Core
import G2EditorCore
import SwiftUI

extension PatchCanvasView {
    // MARK: - Module hit testing

    func findModuleBody(at point: CGPoint) -> ModuleHit? {
        let ro = rowOffset
        let mods = modules
        for module in mods {
            let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)
            if rect.contains(point) {
                return ModuleHit(moduleID: module.id, column: module.column, row: module.row)
            }
        }
        return nil
    }

    // MARK: - Grid snap

    func snapToGrid(dragState: ModuleDragState, dropPt _: CGPoint) -> (column: Int, row: Int) {
        guard let mod = modules.first(where: { $0.id == dragState.moduleID }) else {
            return (dragState.startColumn, dragState.startRow)
        }
        let ro = rowOffset
        let rect = PatchLayout.moduleRect(mod, def: moduleDefinition(mod.typeID),
                                          rowOffset: ro, allModules: modules)
        let offsetRect = rect.offsetBy(dx: moduleDrag?.dragOffset.width ?? 0,
                                       dy: moduleDrag?.dragOffset.height ?? 0)
        return PatchLayout.gridPosition(at: offsetRect.origin, rowOffset: ro)
    }

    // MARK: - Repatch helpers

    /// Wszystkie kable dotykające danego gniazda (może być kilka z jednego outputu).
    func cablesAt(connector conn: ConnectorEndpoint) -> [G2Cable] {
        cables.filter { cable in
            (cable.fromModule == conn.moduleID && cable.fromConnector == conn.connIndex
                && conn.isOutput == cable.sourceIsOutput) ||
                (cable.toModule == conn.moduleID && cable.toConnector == conn.connIndex && !conn.isOutput)
        }
    }

    /// Zwraca endpoint drugiego końca kabla (ten który zostaje jako kotwica).
    func anchorEndpoint(cable: G2Cable, grabbed: ConnectorEndpoint) -> ConnectorEndpoint? {
        let anchorModuleID: Int
        let anchorConnIndex: Int
        let anchorIsOutput: Bool

        // Który koniec złapano? Przy kablu wejście→wejście oba końce są wejściami.
        if grabbed.isOutput == cable.sourceIsOutput, cable.fromModule == grabbed.moduleID,
           cable.fromConnector == grabbed.connIndex
        {
            anchorModuleID = cable.toModule
            anchorConnIndex = cable.toConnector
            anchorIsOutput = false
        } else {
            anchorModuleID = cable.fromModule
            anchorConnIndex = cable.fromConnector
            anchorIsOutput = cable.sourceIsOutput
        }

        guard let anchorMod = modules.first(where: { $0.id == anchorModuleID }),
              let ui = ModuleUIDatabase.shared.uiDef(forID: anchorMod.typeID) else { return nil }
        let list = anchorIsOutput ? ui.outputs : ui.inputs
        guard anchorConnIndex < list.count else { return nil }

        let center = PatchLayout.connectorCenter(module: anchorMod, def: moduleDefinition(anchorMod.typeID),
                                                 connIndex: anchorConnIndex, isOutput: anchorIsOutput,
                                                 rowOffset: rowOffset)
        return ConnectorEndpoint(moduleID: anchorModuleID, connIndex: anchorConnIndex,
                                 isOutput: anchorIsOutput, center: center,
                                 signalType: list[anchorConnIndex].signalType)
    }

    // MARK: - Hit testing: znajdź knob pod punktem (logiczne pt, bez zoom)

    struct KnobHit {
        let moduleID: Int
        let paramIndex: Int
        let currentValue: Int
        let dragSensitivity: CGFloat // units/pt — wyższe dla sliderów
        let readout: SliderReadout
        /// Środek tarczy w układzie canvasu — potrzebny trybowi „Circular"
        /// z okna Options; dla suwaków to środek toru.
        var center: CGPoint = .zero
    }

    /// Pole tekstowe, które pokazuje wartość tej gałki/suwaka — po `masterRef`
    /// albo po liście zależności. Używane i przez dymek po najechaniu, i przez
    /// dymek przy przeciąganiu, żeby obie drogi dawały ten sam napis.
    func linkedTextField(for knob: BVKnob, in ui: ModuleUIDef) -> BVTextField? {
        ui.textFields.first {
            !$0.dependencies.isEmpty
                && ($0.masterRef == knob.codeRef || $0.dependencies.contains(knob.codeRef))
        }
    }

    struct KnobResetHit {
        let moduleID: Int
        let paramIndex: Int
        let defaultValue: Int
    }

    /// Zwraca trójkąt resetu nad gałką typu Reset / Reset/medium.
    func findKnobResetButton(at point: CGPoint) -> KnobResetHit? {
        let scale = CGFloat(140.0 / 256.0)
        let width = 10 * scale
        let height = 4 * scale
        let ro = rowOffset
        let mods = modules

        for module in mods {
            guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { continue }
            let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)
            let defaults = ModuleDefaultsDatabase.defaults(forTypeID: module.typeID)

            for knob in ui.knobs where knob.type.hasResetButton {
                guard defaults.indices.contains(knob.codeRef) else { continue }
                let origin = knobOrigin(module: module, knob: knob)
                let centerX = rect.minX + origin.x + knob.type.centerOffsetPt.x
                let topY = knobResetTriangleTopY(knobTopY: rect.minY + origin.y)
                let hitRect = CGRect(x: centerX - width / 2 - 1,
                                     y: topY - 1,
                                     width: width + 2,
                                     height: height + 2)
                if hitRect.contains(point) {
                    return KnobResetHit(moduleID: module.id,
                                        paramIndex: knob.codeRef,
                                        defaultValue: defaults[knob.codeRef])
                }
            }
        }
        return nil
    }

    func findKnob(at point: CGPoint) -> KnobHit? {
        let ro = rowOffset
        let mods = modules
        var bestHit: KnobHit?
        var bestDist: CGFloat = .infinity

        for module in mods {
            guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { continue }
            let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)

            for knob in ui.knobs {
                let origin = knobOrigin(module: module, knob: knob)
                let tlx = rect.minX + origin.x
                let tly = rect.minY + origin.y
                let dist: CGFloat
                let hitR: CGFloat
                let dragSens: CGFloat
                let center: CGPoint

                if knob.type.isRotary {
                    let off = knob.type.centerOffsetPt
                    let cx = tlx + off.x
                    let cy = tly + off.y
                    dist = hypot(point.x - cx, point.y - cy)
                    hitR = knob.type.radiusPt * 1.5 // 1.5× promień
                    dragSens = 0.4
                    center = CGPoint(x: cx, y: cy)
                } else if knob.type == .slider || knob.type == .seqSlider {
                    let slRect = faderLayout(module: module, knob: knob, ui: ui, rect: rect).track
                    let sliderH = slRect.height
                    if slRect.insetBy(dx: -1, dy: -2).contains(point) {
                        dist = 0
                        hitR = 1
                    } else { continue }
                    // Czułość: 24 semitony na wysokość slidera → ~3pt/semitone przy sliderH≈35pt
                    dragSens = 24.0 / max(1, sliderH)
                    center = CGPoint(x: slRect.midX, y: slRect.midY)
                } else {
                    let sz = knob.type.sliderSizePt
                    let slRect = CGRect(x: tlx, y: tly, width: sz.width, height: sz.height)
                    if slRect.insetBy(dx: -2, dy: -2).contains(point) {
                        dist = 0
                        hitR = 1
                    } else { continue }
                    dragSens = 0.4
                    center = CGPoint(x: slRect.midX, y: slRect.midY)
                }

                if dist < hitR, dist < bestDist {
                    let val = knob.codeRef < module.parameters.count
                        ? module.parameters[knob.codeRef] : 0
                    bestHit = KnobHit(moduleID: module.id,
                                      paramIndex: knob.codeRef,
                                      currentValue: val,
                                      dragSensitivity: dragSens,
                                      readout: SliderReadout(
                                          moduleID: module.id, paramIndex: knob.codeRef,
                                          infoFunc: knob.infoFunc,
                                          textField: linkedTextField(for: knob, in: ui)
                                      ),
                                      center: center)
                    bestDist = dist
                }
            }
        }
        return bestHit
    }

    /// Czy punkt `lp` leży w obszarze TEKSTU nazwy modułu?
    /// Rename triggeruje TYLKO gdy klik trafia bezpośrednio w tekst nazwy — nie w cały header.
    func isInNameArea(at lp: CGPoint, module: G2Module, rect: CGRect) -> Bool {
        let headerRect = CGRect(x: rect.minX, y: rect.minY,
                                width: rect.width, height: PatchLayout.headerH)
        guard headerRect.contains(lp) else { return false }

        // Name moduł (typeID=126) — cały header to nazwa
        if module.typeID == 126 { return true }

        // Oblicz zasięg tekstu nazwy (canvas-pt, niezależne od zoom)
        let fontSize = min(PatchLayout.headerH * 0.62, UIFont.moduleName) // rozmiar fontu w canvas-pt
        let charW = fontSize * 0.62
        let label = module.label.isEmpty
            ? (ModuleDatabase.module(id: module.typeID)?.shortName ?? "")
            : module.label
        let nameStartX = PatchLayout.moduleNameStartX(in: rect)
        let nameEndX = nameStartX + charW * CGFloat(max(label.count, 4)) + 4.0
        return lp.x >= nameStartX - 3.0 && lp.x <= nameEndX
    }

    /// Czy punkt `lp` (canvas-space) trafia na interaktywny element modułu (przycisk, knob, IncDec)?
    private func hasInteractiveElement(at lp: CGPoint, module: G2Module, rect: CGRect) -> Bool {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return false }

        // Vocoder preset (-2...Rnd) jest niestandardowym GraphFunc 22, ale zachowuje
        // się jak siedem przycisków i nie może rozpoczynać przeciągania modułu.
        for graph in ui.graphs where graph.graphFunc == 22 {
            let graphRect = vocoderGraphRect(graph, ui: ui, moduleRect: rect)
            if graphRect.insetBy(dx: -1, dy: -1).contains(lp) { return true }
        }

        // IncDec (+/-)
        for btn in ui.incDecButtons {
            let origin = operatorIncDecOrigin(module: module, button: btn)
            let x = rect.minX + origin.x
            let y = rect.minY + origin.y
            let sq = UIMetrics.incDecHeight
            let r = CGRect(x: x, y: y, width: sq * 2 + 0.5, height: sq)
            if r.insetBy(dx: -1, dy: -1).contains(lp) { return true }
        }

        // ButtonFlat
        for btn in ui.buttonsFlat {
            var btnXPt = btn.xPt
            if module.typeID == 7, btn.codeRef == 2,
               let fmLin = ui.buttonsFlat.first(where: { $0.codeRef == 10 })
            {
                btnXPt = fmLin.xPt + fmLin.widthPt - btn.widthPt
            }
            let isStepSized = btn.widthPt < UIMetrics.buttonFlatHeight
            let w = isStepSized ? UIMetrics.seqFaderWidth : max(btn.widthPt, 8)
            let h: CGFloat = isStepSized ? UIMetrics.seqFaderWidth : UIMetrics.buttonFlatHeight
            let r = CGRect(
                x: rect.minX + btnXPt,
                y: rect.minY + flatButtonYPt(module: module, button: btn, ui: ui),
                width: w,
                height: h
            )
            if r.insetBy(dx: -1, dy: -1).contains(lp) { return true }
        }

        // Knob (rotary)
        for knob in ui.knobs where knob.type.isRotary {
            let origin = knobOrigin(module: module, knob: knob)
            if knob.type.hasResetButton {
                let scale = CGFloat(140.0 / 256.0)
                let width = 10 * scale
                let height = 4 * scale
                let centerX = rect.minX + origin.x + knob.type.centerOffsetPt.x
                let topY = knobResetTriangleTopY(knobTopY: rect.minY + origin.y)
                let resetRect = CGRect(x: centerX - width / 2 - 1,
                                       y: topY - 1,
                                       width: width + 2,
                                       height: height + 2)
                if resetRect.contains(lp) { return true }
            }
            let off = knob.type.centerOffsetPt
            let cx = rect.minX + origin.x + off.x
            let cy = rect.minY + origin.y + off.y
            if hypot(lp.x - cx, lp.y - cy) < knob.type.radiusPt * 1.5 { return true }
        }

        return false
    }

    // MARK: - Connector hit testing

    func findConnector(at point: CGPoint) -> ConnectorEndpoint? {
        let ro = rowOffset
        let mods = modules
        let hitR: CGFloat = UIMetrics.connectorHalf * 1.8
        var best: ConnectorEndpoint?
        var bestDist = hitR

        for module in mods {
            guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { continue }
            for (i, conn) in ui.inputs.enumerated() {
                let c = PatchLayout.connectorCenter(module: module, def: moduleDefinition(module.typeID),
                                                    connIndex: i, isOutput: false, rowOffset: ro)
                let d = hypot(point.x - c.x, point.y - c.y)
                if d < bestDist { best = ConnectorEndpoint(moduleID: module.id, connIndex: i,
                                                           isOutput: false, center: c,
                                                           signalType: conn.signalType)
                    bestDist = d
                }
            }
            for (i, conn) in ui.outputs.enumerated() {
                let c = PatchLayout.connectorCenter(module: module, def: moduleDefinition(module.typeID),
                                                    connIndex: i, isOutput: true, rowOffset: ro)
                let d = hypot(point.x - c.x, point.y - c.y)
                if d < bestDist { best = ConnectorEndpoint(moduleID: module.id, connIndex: i,
                                                           isOutput: true, center: c,
                                                           signalType: conn.signalType)
                    bestDist = d
                }
            }
        }
        return best
    }

    // MARK: - Cable hit testing (kliknięcie → usunięcie)

    func findCable(at point: CGPoint) -> G2Cable? {
        var byID = [Int: G2Module]()
        for m in modules {
            byID[m.id] = m
        }
        let ro = rowOffset
        let threshold: CGFloat = UIMetrics.cableWidth + 3.0

        for cable in cables {
            guard !hiddenColors.contains(cable.color) else { continue }
            guard let src = byID[cable.fromModule], let dst = byID[cable.toModule] else { continue }
            let p1 = PatchLayout.connectorCenter(module: src, def: moduleDefinition(src.typeID),
                                                 connIndex: cable.fromConnector, isOutput: cable.sourceIsOutput,
                                                 rowOffset: ro)
            let p2 = PatchLayout.connectorCenter(module: dst, def: moduleDefinition(dst.typeID),
                                                 connIndex: cable.toConnector, isOutput: false, rowOffset: ro)
            if nearestDistanceToCable(point: point, p1: p1, p2: p2) < threshold {
                return cable
            }
        }
        return nil
    }

    /// Odległość punktu od narysowanego kabla. Kształt bierzemy z tej samej funkcji,
    /// która go rysuje — inaczej przy stylu „Straight" klikałoby się w łuk, którego
    /// na ekranie nie ma.
    private func nearestDistanceToCable(point: CGPoint, p1: CGPoint, p2: CGPoint) -> CGFloat {
        guard cableStyle.isCurved else {
            return Self.distanceToSegment(point: point, a: p1, b: p2)
        }
        let dy = abs(p2.y - p1.y)
        let sag = max(6, dy * 0.35)
        let midX = (p1.x + p2.x) / 2
        let cp1 = CGPoint(x: p1.x + (midX - p1.x) * 0.5, y: p1.y + sag)
        let cp2 = CGPoint(x: p2.x + (midX - p2.x) * 0.5, y: p2.y + sag)
        var minD: CGFloat = .infinity
        for i in 0 ... 24 {
            let t = CGFloat(i) / 24
            let mt = 1 - t
            let bx = mt * mt * mt * p1.x + 3 * mt * mt * t * cp1.x + 3 * mt * t * t * cp2.x + t * t * t * p2.x
            let by = mt * mt * mt * p1.y + 3 * mt * mt * t * cp1.y + 3 * mt * t * t * cp2.y + t * t * t * p2.y
            let d = hypot(point.x - bx, point.y - by)
            if d < minD { minD = d }
        }
        return minD
    }

    static func distanceToSegment(point: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    // MARK: - Cable validation & creation

    func tryAddCable(from a: ConnectorEndpoint, to b: ConnectorEndpoint) {
        // Nie łącz tego samego gniazda ze sobą
        guard !(a.moduleID == b.moduleID && a.connIndex == b.connIndex && a.isOutput == b.isOutput) else { return }
        // Dwa wyjścia → niedozwolone
        guard !(a.isOutput && b.isOutput) else { return }

        // Ustal kierunek: from = output, to = input (auto-swap gdy oba to input)
        let from = a.isOutput ? a : b
        let to = a.isOutput ? b : a

        // Kabel wejście→wejście sam z siebie niczego nie przenosi — instrukcja (str. 70)
        // każe rysować takie połączenia na biało, dopóki łańcuch nie dostanie wyjścia.
        // Kolor źródła wraca do niego w `PatchState.addCable`.
        let color = from.isOutput ? cableColorFrom(signalType: from.signalType) : .white
        // linkType w formacie G2: 1 gdy źródło jest wyjściem, 0 dla kabla
        // wejście-wejście (BVerhue g2_mess.pas:6005 — decyzja po rodzaju konektora).
        let cable = G2Cable(fromModule: from.moduleID, fromConnector: from.connIndex,
                            toModule: to.moduleID, toConnector: to.connIndex,
                            color: color, area: area,
                            sourceIsOutput: from.isOutput)

        // Nie duplikuj istniejącego kabla
        let alreadyExists = cables.contains {
            $0.fromModule == cable.fromModule && $0.fromConnector == cable.fromConnector &&
                $0.toModule == cable.toModule && $0.toConnector == cable.toConnector
        }
        guard !alreadyExists else { return }

        onAddCable?(cable)
    }

    private func cableColorFrom(signalType: BVSignalType) -> CableColor {
        switch signalType {
        case .audio: .red
        case .control: .blue
        case .logic: .yellow
        case .pitchOrControl: .red // dominujący audio
        case .logicOrControl: .orange // dominujący logic HQ
        }
    }

    /// Udostępnia rendererowi dobór koloru bez rozszerzania dostępu do logiki interakcji.
    func renderedCableColor(for signalType: BVSignalType) -> CableColor {
        cableColorFrom(signalType: signalType)
    }

    // MARK: - Hover hit detection

    func findHoverHit(at lp: CGPoint) -> ParamHoverHit? {
        let ro = rowOffset
        let mods = modules

        for module in mods {
            guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { continue }
            let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)
            guard rect.insetBy(dx: -6, dy: -6).contains(lp) else { continue }

            // Knobs (rotary + slider/push/box)
            for knob in ui.knobs {
                let origin = knobOrigin(module: module, knob: knob)
                let tlx = rect.minX + origin.x
                let tly = rect.minY + origin.y
                let isHit: Bool
                if knob.type.isRotary {
                    let off = knob.type.centerOffsetPt
                    let r = knob.type.radiusPt
                    isHit = hypot(lp.x - (tlx + off.x), lp.y - (tly + off.y)) <= r * 1.5
                } else {
                    let sz = knob.type.sliderSizePt
                    isHit = CGRect(x: tlx, y: tly, width: sz.width, height: sz.height)
                        .insetBy(dx: -2, dy: -2).contains(lp)
                }
                guard isHit else { continue }

                var btnsRect: CGRect?
                let anchor: CGPoint
                if knob.type.isRotary {
                    let bsz = knob.type.btnsSizePt
                    let btop = knob.type.btnsTopOffsetPt
                    let br = CGRect(x: tlx,
                                    y: tly + btop,
                                    width: bsz.width,
                                    height: bsz.height)
                    btnsRect = br
                    anchor = CGPoint(x: br.maxX, y: br.maxY)
                } else {
                    let sz = knob.type.sliderSizePt
                    anchor = CGPoint(x: tlx + sz.width,
                                     y: tly + sz.height)
                }
                // Szukaj pola tekstowego którego ten knob jest częścią (masterRef lub dependency)
                let linkedTF = linkedTextField(for: knob, in: ui)
                return ParamHoverHit(
                    moduleID: module.id, paramIndex: knob.codeRef,
                    infoFunc: knob.infoFunc, paramName: "",
                    isKnob: true, displayOptions: nil,
                    linkedTextField: linkedTF,
                    btnsRect: btnsRect, tooltipAnchor: anchor
                )
            }

            let d = moduleDefinition(module.typeID)

            // BVButtonIncDec — +/- (np. Length 1–16)
            for btn in ui.incDecButtons {
                let sq: CGFloat = UIMetrics.incDecHeight
                let gap: CGFloat = 0.5
                let totalW = sq * 2 + gap
                let origin = operatorIncDecOrigin(module: module, button: btn)
                let r = CGRect(x: rect.minX + origin.x, y: rect.minY + origin.y, width: totalW, height: sq)
                guard r.insetBy(dx: -2, dy: -2).contains(lp) else { continue }
                let anchor = CGPoint(x: r.maxX, y: r.maxY)
                let cur = btn.codeRef < module.parameters.count ? module.parameters[btn.codeRef] : 0
                let displayVal = g2InfoFunction(btn.infoFunc, val: cur)
                let fallback = (d?.paramNames.indices.contains(btn.codeRef) == true)
                    ? d!.paramNames[btn.codeRef] : "Length"
                return ParamHoverHit(moduleID: module.id, paramIndex: btn.codeRef,
                                     infoFunc: btn.infoFunc, paramName: fallback,
                                     isKnob: false,
                                     displayOptions: [displayVal],
                                     linkedTextField: nil,
                                     btnsRect: nil, tooltipAnchor: anchor)
            }

            // BVButtonFlat — opcje tekstowe (np. "Off,On" lub "Semi,Freq,Fac,Part")
            for btn in ui.buttonsFlat {
                var btnXPt = btn.xPt
                if module.typeID == 7, btn.codeRef == 2,
                   let fmLin = ui.buttonsFlat.first(where: { $0.codeRef == 10 })
                {
                    btnXPt = fmLin.xPt + fmLin.widthPt - btn.widthPt
                }
                let bw = max(btn.widthPt, 8)
                let bh: CGFloat = 7.0
                let r = CGRect(x: rect.minX + btnXPt,
                               y: rect.minY + flatButtonYPt(module: module, button: btn, ui: ui),
                               width: bw, height: bh)
                guard r.insetBy(dx: -2, dy: -2).contains(lp) else { continue }
                let anchor = CGPoint(x: r.maxX, y: r.maxY)
                let fallback = (d?.paramNames.indices.contains(btn.codeRef) == true)
                    ? d!.paramNames[btn.codeRef] : ""
                // InfoFunc:9 = Loop/1-Cycle (ikonowy, options=[]) → opis zależny od stanu
                let flatOpts: [String]? = btn.infoFunc == 9
                    ? ["1-Cycle", "Loop"]
                    : (btn.options.isEmpty ? nil : btn.options.map { expandedButtonFlatLabel($0) })
                return ParamHoverHit(moduleID: module.id, paramIndex: btn.codeRef,
                                     infoFunc: -1, paramName: fallback,
                                     isKnob: false,
                                     displayOptions: flatOpts,
                                     linkedTextField: nil,
                                     btnsRect: nil, tooltipAnchor: anchor)
            }

            // BVButtonText — toggle (0=Off, 1=On) lub akcja (Rnd/Clr)
            for btn in ui.buttonsText {
                let bw = max(btn.widthPt, 6)
                let bh = buttonTextHeight(module: module, button: btn)
                let r = CGRect(x: rect.minX + btn.xPt,
                               y: rect.minY + rndClkADiceYPt(module: module, btn: btn, ui: ui),
                               width: bw, height: bh)
                guard r.insetBy(dx: -2, dy: -2).contains(lp) else { continue }
                let anchor = CGPoint(x: r.maxX, y: r.maxY)
                let fallback = (d?.paramNames.indices.contains(btn.codeRef) == true)
                    ? d!.paramNames[btn.codeRef] : btn.text
                // Przycisk Power (param "Active", g2ools ActiveMonitor: 0=Monitor,
                // 1=Active) ma własne nazwy stanów, inne niż generyczny Off/On.
                let opts: [String]? = fallback == "Active"
                    ? ["Monitor", "Active"]
                    : (expandedButtonFlatLabel(btn.text) != btn.text
                        ? [expandedButtonFlatLabel(btn.text)]
                        : ["Off", "On"])
                return ParamHoverHit(moduleID: module.id, paramIndex: btn.codeRef,
                                     infoFunc: -1, paramName: fallback,
                                     isKnob: false,
                                     displayOptions: opts,
                                     linkedTextField: nil,
                                     btnsRect: nil, tooltipAnchor: anchor)
            }

            // BVButtonRadio — pokazuje nazwę konkretnego przycisku nad którym jest kursor
            for btn in ui.buttonsRadio {
                let x0 = rect.minX + btn.xPt
                let y0 = rect.minY + btn.yPt
                let rightInset: CGFloat = module.typeID == 163 && btn.orientation == "Horizontal" ? 1.5 : 0
                let bw = max(btn.buttonWidthPt, 6.0) - rightInset / CGFloat(btn.columns)
                let bh: CGFloat = 7.0
                guard CGRect(x: x0, y: y0,
                             width: bw * CGFloat(btn.columns),
                             height: bh * CGFloat(btn.rows))
                    .insetBy(dx: -2, dy: -2).contains(lp) else { continue }

                // Który konkretny button w siatce jest pod kursorem
                let hovCol = max(0, min(btn.columns - 1, Int((lp.x - x0) / bw)))
                let hovRow = max(0, min(btn.rows - 1, Int((lp.y - y0) / bh)))
                let hovIdx = hovRow * btn.columns + hovCol

                // BVerhue wpisuje w ikonowe ButtonRadio atrapy tekstowe „1,2,3,4,5" —
                // to nie są nazwy fal, tylko wypełniacz (oryginał ich nie pokazuje, bo
                // rysuje ikony). Gdy WSZYSTKIE etykiety grupy są czysto liczbowe,
                // pierwszeństwo ma tabela nazw z InfoFunc (LfoB 164, LfoShpA 165…) —
                // stąd wcześniejsze dymki „1", „2"… przy poprawnym „Sqr" dla ostatniego
                // przycisku, który jako jedyny nie miał atrapy w danych.
                let placeholderLabels = btn.buttonLabels.allSatisfy { Int($0) != nil }
                let hovLabel: String = if !placeholderLabels,
                                          btn.buttonLabels.indices.contains(hovIdx)
                {
                    btn.buttonLabels[hovIdx]
                } else if btn.infoFunc > 0 {
                    g2InfoFunction(btn.infoFunc, val: hovIdx)
                } else if btn.buttonLabels.indices.contains(hovIdx) {
                    btn.buttonLabels[hovIdx]
                } else {
                    (d?.paramNames.indices.contains(btn.codeRef) == true)
                        ? d!.paramNames[btn.codeRef] : ""
                }

                // Anchor przy prawej krawędzi hoverowanego przycisku, środek pionowy
                let btnX0 = x0 + CGFloat(hovCol) * bw
                let btnY0 = y0 + CGFloat(hovRow) * bh
                let anchor = CGPoint(x: btnX0 + bw,
                                     y: btnY0 + bh)

                return ParamHoverHit(moduleID: module.id, paramIndex: btn.codeRef,
                                     infoFunc: -1, paramName: hovLabel,
                                     isKnob: false, displayOptions: nil,
                                     linkedTextField: nil,
                                     btnsRect: nil, tooltipAnchor: anchor)
            }

            // BVLevelShift — OutputType cyclic button
            for ls in ui.levelShifts {
                let r = levelShiftRect(ls, moduleTypeID: module.typeID, in: rect)
                guard r.insetBy(dx: -2, dy: -2).contains(lp) else { continue }
                let anchor = CGPoint(x: r.maxX, y: r.maxY)
                return ParamHoverHit(moduleID: module.id, paramIndex: ls.codeRef,
                                     infoFunc: -1, paramName: "",
                                     isKnob: false,
                                     displayOptions: ["Pos", "PosInv", "Neg", "NegInv", "Bip", "BipInv"],
                                     linkedTextField: nil,
                                     btnsRect: nil, tooltipAnchor: anchor)
            }

            // BVPartSelector — pełna nazwa wybranego trybu w tooltip
            for sel in ui.partSelectors {
                let r = partSelectorRect(sel, moduleTypeID: module.typeID, in: rect)
                guard r.insetBy(dx: -2, dy: -2).contains(lp) else { continue }
                let anchor = CGPoint(x: r.maxX, y: r.maxY)
                // Dla infoFunc=136 (Env Shape) mapujemy value→ nazwę kształtu
                var options: [String]?
                if sel.infoFunc == PatchCanvasView.outputTypeInfoFunc {
                    // OutputType — pełne nazwy trzech stanów (na przycisku jest litera).
                    options = ["BiPolar", "Positive", "Negative"]
                } else if sel.infoFunc == PatchCanvasView.envRetriggerInfoFunc {
                    options = ["Normal", "Reset"]
                } else if sel.infoFunc == 136 {
                    // G2 binary: 0=LogExp, 1=LinExp, 2=ExpExp, 3=LinLin
                    options = (0 ..< sel.imageCount).map { v in
                        ["LogExp", "LinExp", "ExpExp", "LinLin"][v % 4]
                    }
                } else if !sel.usesParameter {
                    // Selektor bez własnego parametru (tryb, np. GateMode1/2, FlipFlop
                    // D/S) — zbuduj listę opcji z g2ModeLabel, tak samo jak rozwinięta
                    // lista (selectorPickerLabel). Bez tego fallback schodził do
                    // d.paramNames, który dla trybów jest pusty/nietrafny.
                    let modeName = (d?.modeNames.indices.contains(sel.codeRef) == true)
                        ? d!.modeNames[sel.codeRef] : ""
                    let labels = (0 ..< sel.imageCount).compactMap { g2ModeLabel(modeName: modeName, value: $0) }
                    if labels.count == sel.imageCount { options = labels }
                }
                let fallback = (d?.paramNames.indices.contains(sel.codeRef) == true)
                    ? d!.paramNames[sel.codeRef] : ""
                return ParamHoverHit(moduleID: module.id, paramIndex: sel.codeRef,
                                     infoFunc: -1, paramName: fallback,
                                     isKnob: false, displayOptions: options,
                                     linkedTextField: nil,
                                     btnsRect: nil, tooltipAnchor: anchor,
                                     usesModes: !sel.usesParameter)
            }
        }
        return nil
    }
}
