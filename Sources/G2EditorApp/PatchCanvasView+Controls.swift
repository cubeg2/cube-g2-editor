import AppKit
import G2Core
import SwiftUI

extension PatchCanvasView {
    // MARK: - Button tap handler

    func handleButtonTap(at point: CGPoint, screenPos: CGPoint = .zero) {
        let ro = rowOffset
        let mods = modules

        for module in mods {
            guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { continue }
            let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)

            // ── Sequencer slider ▲/▼ buttons ──────────────────────────────────
            for knob in ui.knobs where knob.type == .slider || knob.type == .seqSlider {
                let fader = faderLayout(module: module, knob: knob, ui: ui, rect: rect)
                let upRect = fader.up
                let dnRect = fader.down
                let cur = knob.codeRef < module.parameters.count ? module.parameters[knob.codeRef] : 0
                let readout = SliderReadout(moduleID: module.id, paramIndex: knob.codeRef,
                                            infoFunc: knob.infoFunc,
                                            textField: linkedTextField(for: knob, in: ui))
                if upRect.insetBy(dx: -1, dy: -1).contains(point) {
                    let newVal = min(127, cur + 1)
                    onParameterChange?(module.id, knob.codeRef, newVal)
                    showSeqSliderTooltip(readout, screenPos: screenPos)
                    faderButtonFlash = (moduleID: module.id, codeRef: knob.codeRef, isUp: true)
                    faderButtonFlashTask?.cancel()
                    faderButtonFlashTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        faderButtonFlash = nil
                    }
                    return
                }
                if dnRect.insetBy(dx: -1, dy: -1).contains(point) {
                    let newVal = max(0, cur - 1)
                    onParameterChange?(module.id, knob.codeRef, newVal)
                    showSeqSliderTooltip(readout, screenPos: screenPos)
                    faderButtonFlash = (moduleID: module.id, codeRef: knob.codeRef, isUp: false)
                    faderButtonFlashTask?.cancel()
                    faderButtonFlashTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        faderButtonFlash = nil
                    }
                    return
                }
            }

            // ── SeqNote piano strip + lupka (Graph:25) — klik cykluje zoom 0↔1↔2 ───
            for graph in ui.graphs where graph.graphFunc == 25 {
                let noteKnobs = ui.seqNoteKnobs
                guard !noteKnobs.isEmpty else { continue }
                let track = faderLayout(module: module, knob: noteKnobs[0], ui: ui, rect: rect).track
                // Strefa kliku: piano strip + obszar lupki powyżej
                let iconSize: CGFloat = min(graph.widthPt - 0.5, 5.5)
                let zoneTop = track.minY - iconSize - 2.0 - 2.0 // z marginesem
                let combinedRect = CGRect(x: rect.minX + graph.xPt - 2,
                                          y: zoneTop,
                                          width: graph.widthPt + 4,
                                          height: track.maxY - zoneTop + 2)
                if combinedRect.contains(point) {
                    let cur = seqNoteZoomLevel[module.id] ?? 1
                    let newZoom = (cur + 1) % 3
                    // Zachowaj centrum widoku przy zmianie skali (jeśli jest aktywny scroll offset)
                    if let curLo = seqNoteScrollOffset[module.id] {
                        let curOctaves = [3, 2, 1][cur]
                        let newOctaves = [3, 2, 1][newZoom]
                        let center = curLo + curOctaves * 6
                        seqNoteScrollOffset[module.id] = max(0, min(127 - newOctaves * 12, center - newOctaves * 6))
                    }
                    seqNoteZoomLevel[module.id] = newZoom
                    return
                }
            }

            // ── SeqNote: przyciski oktaw ▲▼ pod Graph:26 ──────────────────────
            for graph in ui.graphs where graph.graphFunc == 26 {
                guard !ui.seqNoteKnobs.isEmpty else { continue }
                let lcdH = UIMetrics.textFieldHeight
                let lcdY = rect.minY + graph.yPt
                let lcdRect = CGRect(x: rect.minX + graph.xPt, y: lcdY,
                                     width: graph.widthPt, height: lcdH)
                let frames = octaveButtonFrames(under: lcdRect)
                let upRect = frames.up
                let dnRect = frames.down

                let zl = seqNoteZoomLevel[module.id] ?? 1
                let octaves = [3, 2, 1][max(0, min(2, zl))]
                // Aktualny loNote: z offset lub auto-center (snapowany do C)
                let curLo: Int
                if let ov = seqNoteScrollOffset[module.id] {
                    curLo = ov
                } else {
                    let nk = ui.seqNoteKnobs
                    let np = nk.map { k in k.codeRef < module.parameters.count ? module.parameters[k.codeRef] : 60 }
                    let (lo, _) = noteViewRange(params: np, zoomLevel: zl)
                    curLo = lo
                }
                // Snapuj do C (wielokrotność 12), zakres C0(12)..C9(120)
                let snapLo = max(12, (curLo / 12) * 12)

                if upRect.insetBy(dx: -1, dy: -1).contains(point) {
                    let newLo = max(12, min(127 - octaves * 12, snapLo + 12))
                    seqNoteScrollOffset[module.id] = newLo
                    octaveButtonFlash = (moduleID: module.id, isUp: true)
                    octaveButtonFlashTask?.cancel()
                    octaveButtonFlashTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        octaveButtonFlash = nil
                    }
                    return
                }
                if dnRect.insetBy(dx: -1, dy: -1).contains(point) {
                    let newLo = max(12, min(127 - octaves * 12, snapLo - 12))
                    seqNoteScrollOffset[module.id] = newLo
                    octaveButtonFlash = (moduleID: module.id, isUp: false)
                    octaveButtonFlashTask?.cancel()
                    octaveButtonFlashTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        octaveButtonFlash = nil
                    }
                    return
                }
            }

            // ── Vocoder: siedem presetów mapowania 16 pasm (Graph:22) ─────────
            for graph in ui.graphs where graph.graphFunc == 22 {
                let presetRect = vocoderGraphRect(graph, ui: ui, moduleRect: rect)
                guard let button = vocoderPresetButtonRects(in: presetRect)
                    .firstIndex(where: { $0.insetBy(dx: -0.25, dy: -0.25).contains(point) })
                else { continue }

                for band in 0 ..< min(16, module.parameters.count) {
                    onParameterChange?(module.id, band, vocoderPresetValue(button, band: band))
                }
                vocoderSelectedPreset[module.id] = button
                return
            }

            // ── DrumSynth: wybór kompletnego presetu (Graph:46) ─────────────
            for graph in ui.graphs where graph.graphFunc == 46 {
                let selectorRect = CGRect(x: rect.minX + graph.xPt, y: rect.minY + graph.yPt,
                                          width: graph.widthPt, height: graph.heightPt)
                let buttons = drumSynthPresetButtonRects(in: selectorRect)
                let current = drumSynthPresetIndex(for: module.parameters)

                if buttons.up.insetBy(dx: -1, dy: -1).contains(point) {
                    // W oryginale pierwsze ▲ po ręcznej zmianie parametrów wraca do Kick 1.
                    let next = min(DrumSynthPreset.data.count - 1, (current ?? -1) + 1)
                    for (index, value) in DrumSynthPreset.data[next].values.enumerated() {
                        onParameterChange?(module.id, index, value)
                    }
                    return
                }
                if buttons.down.insetBy(dx: -1, dy: -1).contains(point),
                   let current, current > 0
                {
                    for (index, value) in DrumSynthPreset.data[current - 1].values.enumerated() {
                        onParameterChange?(module.id, index, value)
                    }
                    return
                }
            }

            // ── ButtonFlat ─────────────────────────────────────────────────────
            for btn in ui.buttonsFlat {
                var btnXPt = btn.xPt
                if module.typeID == 7, btn.codeRef == 2,
                   let fmLin = ui.buttonsFlat.first(where: { $0.codeRef == 10 })
                {
                    btnXPt = fmLin.xPt + fmLin.widthPt - btn.widthPt
                }
                let x = rect.minX + btnXPt
                let y = rect.minY + flatButtonYPt(module: module, button: btn, ui: ui)
                let w = max(btn.widthPt, 8)
                let h: CGFloat = 7.0
                guard CGRect(x: x, y: y, width: w, height: h).contains(point) else { continue }
                let cur = btn.codeRef < module.parameters.count ? module.parameters[btn.codeRef] : 0
                // Liczba stanów: znany zakres sprzętowy ma pierwszeństwo przed liczbą
                // napisów na przycisku — LfoA/LfoC mają pięć etykiet, ale tylko cztery
                // zakresy (bez Clk). Bez opcji tekstowych (np. Loop, infoFunc:9) → toggle 0/1.
                let states = ParameterRangeDatabase
                    .range(moduleTypeID: module.typeID, codeRef: btn.codeRef)
                    .map { $0.upperBound - $0.lowerBound + 1 }
                    ?? (btn.options.isEmpty ? 2 : btn.options.count)
                let next = (cur + 1) % states
                onParameterChange?(module.id, btn.codeRef, next)
                return
            }

            // ── ButtonText ─────────────────────────────────────────────────────
            for btn in ui.buttonsText {
                let x = rect.minX + btn.xPt
                let y = rect.minY + rndClkADiceYPt(module: module, btn: btn, ui: ui)
                let w = max(btn.widthPt, 6)
                let h = buttonTextHeight(module: module, button: btn)
                guard CGRect(x: x, y: y, width: w, height: h).contains(point) else { continue }
                if btn.text == "Clr" {
                    // Reset wszystkich faderów na dół (bipolar -64 = MIDI 0)
                    startMomentaryFlash(moduleID: module.id, codeRef: btn.codeRef)
                    for knob in ui.knobs where knob.type == .slider || knob.type == .seqSlider {
                        onParameterChange?(module.id, knob.codeRef, 0)
                    }
                    return
                }
                if btn.text == "Rnd" {
                    // Randomizuj pozycje wszystkich faderów
                    startMomentaryFlash(moduleID: module.id, codeRef: btn.codeRef)
                    for knob in ui.knobs where knob.type == .slider || knob.type == .seqSlider {
                        onParameterChange?(module.id, knob.codeRef, Int.random(in: 0 ... 127))
                    }
                    return
                }
                if btn.type == "Push" {
                    // Push Clavii jest akcją chwilową: ustawia 1 tylko na czas
                    // RequestChange, po czym od razu wraca do 0. Krótka zwłoka
                    // zachowuje czytelne wciśnięcie także na ekranie Canvasu.
                    startMomentaryFlash(moduleID: module.id, codeRef: btn.codeRef)
                    onMomentaryParameterChange?(module.id, btn.codeRef, 1)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        onMomentaryParameterChange?(module.id, btn.codeRef, 0)
                    }
                    return
                }
                let cur = btn.codeRef < module.parameters.count ? module.parameters[btn.codeRef] : 0
                onParameterChange?(module.id, btn.codeRef, cur == 0 ? 1 : 0)
                return
            }

            // ── ButtonRadio ────────────────────────────────────────────────────
            for btn in ui.buttonsRadio {
                let x0 = rect.minX + btn.xPt
                let y0 = rect.minY + buttonRadioYPt(moduleTypeID: module.typeID, button: btn, ui: ui)
                let rightInset: CGFloat = module.typeID == 163 && btn.orientation == "Horizontal" ? 1.5 : 0
                let bw = max(btn.buttonWidthPt, 6.0) - rightInset / CGFloat(btn.columns)
                let bh: CGFloat = 7.0
                let isVert = btn.orientation == "Vertical"
                guard CGRect(x: x0, y: y0,
                             width: bw * CGFloat(btn.columns),
                             height: bh * CGFloat(btn.rows)).contains(point) else { continue }
                let col = max(0, min(btn.columns - 1, Int((point.x - x0) / bw)))
                let row = max(0, min(btn.rows - 1, Int((point.y - y0) / bh)))
                let clamped = row * btn.columns + col
                // Vertical: wizualna pozycja 0 (góra) = labels[0]=BR = value (count-1)
                let finalValue = isVert ? (btn.buttonCount - 1 - clamped) : clamped
                onParameterChange?(module.id, btn.codeRef, finalValue)
                return
            }

            // ButtonIncDec (+/-): obsłużone przez incDecPressGesture (klik = jeden krok,
            // przytrzymanie = auto-powtarzanie) — patrz findIncDecButton/stepIncDec.

            // ── LevelShift — klik cykluje OutputType (Pos/PosInv/Neg/NegInv/Bip/BipInv) ──
            // Pełny zakres to 6 stanów (BVerhue prtPosNegInvBipInv), ale część modułów
            // ma węższy sprzętowy typ (prtPosNegInv=4, prtPosNegInvBip=5) — patrz
            // ParameterRangeDatabase i audyt "OutputType cykluje 6 stanów, sprzęt ma 4/5".
            for ls in ui.levelShifts {
                let lsRect = levelShiftRect(ls, moduleTypeID: module.typeID, in: rect)
                guard lsRect.insetBy(dx: -1, dy: -1).contains(point) else { continue }
                let cur = ls.codeRef < module.parameters.count ? module.parameters[ls.codeRef] : 0
                let states = (ParameterRangeDatabase.range(moduleTypeID: module.typeID, codeRef: ls.codeRef)?.upperBound ?? 5) + 1
                let next = (cur + 1) % states
                onParameterChange?(module.id, ls.codeRef, next)
                return
            }

            // ── PartSelector — kliknięcie rozwija listę wartości ────────────
            for sel in ui.partSelectors {
                guard sel.imageCount > 1 else { continue }
                let hitRect = partSelectorRect(sel, moduleTypeID: module.typeID, in: rect)
                let isSmallFilterSlope = isSmallFilterSlopeSelector(
                    moduleTypeID: module.typeID,
                    selector: sel
                )
                let expandedHitRect = isSmallFilterSlope
                    ? hitRect.insetBy(dx: -selectorDisclosureTabWidth(for: hitRect), dy: -3)
                    : hitRect.insetBy(dx: -1, dy: -1)
                guard expandedHitRect.contains(point) else { continue }
                // OutputType i Normal/Reset to zwykłe przyciski, nie ekrany — klik
                // przechodzi do następnego stanu, bez rozwijania listy.
                if Self.shortLabelButtonTitle(infoFunc: sel.infoFunc, value: 0) != nil {
                    let cur = sel.codeRef < module.parameters.count ? module.parameters[sel.codeRef] : 0
                    onParameterChange?(module.id, sel.codeRef, (cur + 1) % sel.imageCount)
                    return
                }
                let cur: Int = sel.usesParameter
                    ? (sel.codeRef < module.parameters.count ? module.parameters[sel.codeRef] : 0)
                    : (sel.codeRef < module.modes.count ? module.modes[sel.codeRef] : 0)
                let modeNames = moduleDefinition(module.typeID)?.modeNames ?? []
                let modeName = sel.codeRef < modeNames.count ? modeNames[sel.codeRef] : ""
                selectorPicker = SelectorPickerState(
                    moduleID: module.id,
                    moduleTypeID: module.typeID,
                    codeRef: sel.codeRef,
                    usesParameter: sel.usesParameter,
                    infoFunc: sel.infoFunc,
                    optionCount: sel.imageCount,
                    modeName: modeName,
                    // Kształt obwiedni (InfoFunc 136) rozwija się w listę ikon tak samo
                    // jak fale w LfoC — cztery krzywe, a nie cztery nazwy („LogExp"…),
                    // bo na zamkniętym ekranie też stoi rysunek, nie napis.
                    showsWaveOptions: isWavePartSelector(moduleTypeID: module.typeID, selector: sel)
                        || isPMDriverPartSelector(moduleTypeID: module.typeID, selector: sel)
                        || sel.infoFunc == 136
                        || isSmallFilterSlope
                        || [38, 42, 64, 69, 91].contains(module.typeID),
                    // Ten sam warunek co w drawBVPartSelectors: gdy tryb ma nazwę tekstową,
                    // zamknięty ekran renderuje ją fontem LCD — lista musi wyglądać tak samo.
                    showsLcdText: !isSmallFilterSlope
                        && g2ModeLabel(modeName: modeName, value: 0) != nil,
                    canvasRect: hitRect,
                    selectedValue: max(0, min(cur, sel.imageCount - 1))
                )
                return
            }
        }
    }

    @ViewBuilder
    func selectorPickerView(_ picker: SelectorPickerState) -> some View {
        // Nie zapamiętujemy pozycji w pikselach ekranu: Canvas zmienia skalę na żywo.
        let screenRect = CGRect(x: picker.canvasRect.minX * zoom,
                                y: picker.canvasRect.minY * zoom,
                                width: picker.canvasRect.width * zoom,
                                height: picker.canvasRect.height * zoom)
        // Rozwinięte ekrany (ikony fal/schematów Logic, teksty LCD) stykają się bez
        // odstępu — tworzą jedną ciągłą listę pod ekranem, tak jak w oryginale Clavii.
        let stacksUnderScreen = picker.showsWaveOptions || picker.showsLcdText
        // Jedna ramka dookoła CAŁEJ listy (nie per-wiersz) — inaczej styk dwóch
        // sąsiednich pozycji rysuje ich ramki jedna na drugiej, więc wychodzi grubsza
        // niż reszta obwodu. Promień dopasowany do stylu wiersza (LCD vs wave/Gate).
        let outerBorderRadius: CGFloat = picker.showsWaveOptions ? zoom : UIMetrics.socketCornerRadius * zoom
        let outerBorderWidth: CGFloat = 0.5 * zoom
        let rowSpacing: CGFloat = stacksUnderScreen ? 0 : 1
        let rowHeight = stacksUnderScreen ? screenRect.height : 23
        // Gate ma w każdym wierszu trzy strefy obok siebie (nazwa / symbol bramki /
        // tabela prawdy) — sama szerokość zamkniętego ekranu (39pt) na to nie starcza.
        // Szerokość dopasowana do zawartości (gateSelectorRowWidth to samo źródło
        // metryk co drawLogicSelectorDiagram, więc wypełnia wiersz bez pustego miejsca);
        // `- 2*zoom` bo Canvas wewnątrz insetuje `diagram` o `zoom` z każdej strony.
        let waveMenuWidth = picker.moduleTypeID == 64
            ? gateSelectorRowWidth(rowHeight: rowHeight - 2 * zoom) + 2 * zoom
            : screenRect.width
        let menuWidth = if picker.showsWaveOptions { waveMenuWidth } else if picker.showsLcdText { screenRect.width } else { max(104, screenRect.width + 30) }
        let requestedHeight = CGFloat(picker.optionCount) * rowHeight
            + CGFloat(max(0, picker.optionCount - 1)) * rowSpacing
            + (stacksUnderScreen ? 0 : 8)
        // Pozycje fal nie mogą być przycięte w połowie ekranu. Lista może wyjść
        // poza dół modułu, ale każdy jej wiersz zachowuje pełny rozmiar ekranu.
        let menuHeight = stacksUnderScreen
            ? requestedHeight
            : min(requestedHeight, max(36, canvasSize.height - 8))
        let rightEdge = max(4, canvasSize.width - menuWidth - 4)
        let bottomEdge = max(4, canvasSize.height - menuHeight - 4)
        // Lista fal wyskakuje pod ekranem (nie z boku) — wyrównana do jego lewej
        // krawędzi, tej samej szerokości; zakładka pozostaje wyłącznie małym
        // wskaźnikiem na ramce ekranu.
        let x = stacksUnderScreen
            ? min(max(4, screenRect.minX), rightEdge)
            : min(max(4, screenRect.maxX), rightEdge)
        let y = stacksUnderScreen
            ? max(4, screenRect.maxY)
            : min(max(4, screenRect.minY), bottomEdge)

        ScrollView {
            LazyVStack(spacing: rowSpacing) {
                ForEach(0 ..< picker.optionCount, id: \.self) { value in
                    Button {
                        if picker.usesParameter {
                            onParameterChange?(picker.moduleID, picker.codeRef, value)
                        } else {
                            onModeChange?(picker.moduleID, picker.codeRef, value)
                        }
                        selectorPicker = nil
                    } label: {
                        if picker.showsWaveOptions {
                            // Najazd zmienia WYŁĄCZNIE kolor rysunku (jaśniejsza zieleń),
                            // nigdy grubość linii — pogrubianie zmieniało proporcje symbolu
                            // i wiersz pod kursorem wyglądał jak inny widżet.
                            // Ta sama zasada co showsLcdText: domyślnie świeci wybrana
                            // pozycja, hover przejmuje podświetlenie (tylko jedna jasna
                            // na raz) — aktywna przygasza, dopóki kursor nie zjedzie z listy.
                            let isCurrent = selectorPickerHoveredValue.map { $0 == value }
                                ?? (value == picker.selectedValue)
                            let isPMDriver = moduleDefinition(picker.moduleTypeID)?.shortName == "Driver"
                            let lineColor = isCurrent ? UIColor.lcdText : UIColor.lcdTextDim
                            let accentColor = UIColor.pmDriverAccent.opacity(isCurrent ? 1.0 : 0.48)
                            Canvas { context, size in
                                let optionRect = CGRect(origin: .zero, size: size)
                                let isLogicDiagram = [38, 42, 64, 69, 91].contains(picker.moduleTypeID)
                                // Każda pozycja ma własne lekkie zaokrąglenie na WSZYSTKICH
                                // rogach (subtelna przerwa w tle na styku dwóch pozycji).
                                context.fill(Path(roundedRect: optionRect, cornerRadius: zoom),
                                             with: .color(isLogicDiagram
                                                 ? logicSelectorBackgroundColor(moduleTypeID: picker.moduleTypeID)
                                                 : UIColor.lcdBackground))
                                // Separator między pozycjami — rysowany TYLKO od góry każdej
                                // pozycji poza pierwszą (nie od dołu), żeby granica między
                                // dwoma wierszami nie była rysowana dwa razy (co dawałoby
                                // grubszą linię niż reszta ramki, patrz overlay w
                                // selectorPickerView, który rysuje resztę obwodu raz).
                                if value > 0 {
                                    var sep = Path()
                                    sep.move(to: CGPoint(x: 0, y: 0))
                                    sep.addLine(to: CGPoint(x: size.width, y: 0))
                                    context.stroke(sep, with: .color(.white.opacity(0.85)), lineWidth: outerBorderWidth)
                                }
                                if isLogicDiagram {
                                    drawLogicSelectorDiagram(
                                        context,
                                        in: optionRect.insetBy(dx: zoom, dy: zoom),
                                        moduleTypeID: picker.moduleTypeID,
                                        index: value,
                                        lineWidthScale: zoom,
                                        color: lineColor
                                    )
                                } else if isPMDriver {
                                    drawPMDriverSelectorIcon(
                                        context,
                                        rect: optionRect,
                                        value: value,
                                        color: lineColor,
                                        accentColor: accentColor,
                                        // Ten sam font co na zamkniętym ekranie: rozmiar
                                        // liczony z wysokości w jednostkach modułu, nie
                                        // z wiersza listy (patrz gałąź showsLcdText niżej).
                                        fontSize: UIFont.lcdDisplay(boxHeight: picker.canvasRect.height) * zoom,
                                        inset: zoom
                                    )
                                } else {
                                    drawWaveSelectorIcon(
                                        context,
                                        rect: optionRect.insetBy(dx: zoom, dy: zoom),
                                        moduleTypeID: picker.moduleTypeID,
                                        value: value,
                                        color: lineColor,
                                        lineWidth: UIMetrics.graphLineWidth * zoom,
                                        infoFunc: picker.infoFunc
                                    )
                                }
                            }
                            .frame(width: menuWidth, height: rowHeight)
                            .onHover { hovering in
                                selectorPickerHoveredValue = hovering ? value : nil
                            }
                        } else if picker.showsLcdText {
                            // Kopia zamkniętego ekranu: to samo tło, ramka i font DSEG.
                            // Domyślnie świeci wybrana pozycja; najechanie kursorem na
                            // inną przejmuje podświetlenie (tylko jedna jasna na raz) —
                            // aktywna przygasza, dopóki kursor nie zjedzie z listy.
                            let isCurrent = selectorPickerHoveredValue.map { $0 == value }
                                ?? (value == picker.selectedValue)
                            let label = selectorPickerLabel(picker, value: value)
                            // lcdDisplay(boxHeight:) jest kalibrowany na wysokość w jednostkach
                            // canvasu modułu (picker.canvasRect), NIE na rozmiar ekranowy tego
                            // wiersza (optionRect.height = canvasRect.height × zoom) — inaczej
                            // przy zoomie ≠ 1 font wypada innej wielkości niż na zamkniętym ekranie.
                            let fontSize = UIFont.lcdDisplay(boxHeight: picker.canvasRect.height) * zoom
                            Canvas { context, size in
                                let optionRect = CGRect(origin: .zero, size: size)
                                let corner = UIMetrics.socketCornerRadius * zoom
                                // Zaokrąglenie na wszystkich rogach każdej pozycji (subtelna
                                // przerwa w tle na styku dwóch pozycji).
                                context.fill(Path(roundedRect: optionRect, cornerRadius: corner),
                                             with: .color(UIColor.lcdBackground))
                                // Separator między pozycjami — tylko od góry (poza pierwszą),
                                // żeby granica między dwoma wierszami nie rysowała się dwa
                                // razy (grubiej niż reszta ramki z overlayu selectorPickerView).
                                if value > 0 {
                                    var sep = Path()
                                    sep.move(to: CGPoint(x: 0, y: 0))
                                    sep.addLine(to: CGPoint(x: size.width, y: 0))
                                    context.stroke(sep, with: .color(.white.opacity(0.85)), lineWidth: outerBorderWidth)
                                }
                                drawLcdText(context, text: label, box: optionRect,
                                            fontSize: fontSize,
                                            color: isCurrent ? UIColor.lcdText : UIColor.lcdTextDim)
                            }
                            .frame(width: menuWidth, height: rowHeight)
                            .onHover { hovering in
                                selectorPickerHoveredValue = hovering ? value : nil
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(selectorPickerLabel(picker, value: value))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                Spacer(minLength: 0)
                                if value == picker.selectedValue {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                }
                            }
                            .foregroundColor(value == picker.selectedValue ? .white : .primary)
                            .padding(.horizontal, 8)
                            .frame(height: rowHeight)
                            .background(value == picker.selectedValue
                                ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.94))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(selectorPickerLabel(picker, value: value))
                }
            }
            .padding(stacksUnderScreen ? 0 : 4)
        }
        .frame(width: menuWidth, height: menuHeight)
        .background(stacksUnderScreen ? Color.clear : Color(white: 0.16).opacity(0.96))
        .overlay {
            if stacksUnderScreen {
                RoundedRectangle(cornerRadius: outerBorderRadius)
                    .stroke(Color.white.opacity(0.85), lineWidth: outerBorderWidth)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black.opacity(0.65), lineWidth: 1)
            }
        }
        .shadow(color: stacksUnderScreen ? .clear : .black.opacity(0.35), radius: 4, y: 2)
        .position(x: x + menuWidth / 2, y: y + menuHeight / 2)
        .onKeyPress(.escape) {
            selectorPicker = nil
            return .handled
        }
    }

    private func selectorPickerLabel(_ picker: SelectorPickerState, value: Int) -> String {
        if picker.showsWaveOptions {
            return waveSelectorLabel(moduleTypeID: picker.moduleTypeID,
                                     value: value,
                                     optionCount: picker.optionCount)
        }
        if let label = g2ModeLabel(modeName: picker.modeName, value: value) {
            return label
        }
        if picker.moduleTypeID == 42 {
            let labels = ["Positive", "Negative", "Cycle"]
            return labels[min(value, labels.count - 1)]
        }
        if picker.moduleTypeID == 91 {
            return value == 0 ? "D" : "SR"
        }
        if picker.optionCount == 8, picker.infoFunc == 0 {
            let labels = ["Sine", "Triangle", "Saw Up", "Saw Down", "Square", "Pulse", "S&H", "S&G"]
            return labels[min(value, labels.count - 1)]
        }
        if picker.infoFunc == 0 {
            return "Option \(value + 1)"
        }
        return g2InfoFunction(picker.infoFunc, val: value)
    }

    /// Wartość suwaka tak, jak pokazuje ją dymek po najechaniu: z powiązanego pola
    /// tekstowego, a gdy suwak żadnego nie ma — z jego InfoFunc. Wcześniej dymek
    /// przy przeciąganiu zawsze pokazywał wartość dwubiegunową (`val - 64`), przez
    /// co suwaki SeqLev i SeqCtr (InfoFunc 0 → skala 0–100) czytały się inaczej
    /// niż ten sam suwak po najechaniu.
    func sliderReadoutText(_ readout: SliderReadout) -> String {
        let params = modules.first(where: { $0.id == readout.moduleID })?.parameters ?? []
        let value = params.indices.contains(readout.paramIndex) ? params[readout.paramIndex] : 0
        if let field = readout.textField {
            return g2TextFunction(textFunc: field.textFunc, deps: field.dependencies,
                                  params: params, knobInfoFunc: readout.infoFunc)
        }
        return g2InfoFunction(readout.infoFunc, val: value)
    }

    func showSeqSliderTooltip(_ readout: SliderReadout, screenPos: CGPoint) {
        seqTooltipTask?.cancel()
        seqSliderTooltip = (readout: readout, x: screenPos.x, y: screenPos.y)
        seqTooltipTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { seqSliderTooltip = nil }
        }
    }

    /// Rozwijanie skrótów na pełne nazwy w tooltipach ButtonFlat.
    /// Przycisk sam wyświetla skrót ("T"), tooltip pokazuje pełną nazwę ("Trigger").
    func expandedButtonFlatLabel(_ s: String) -> String {
        switch s {
        case "T": "Trigger"
        case "G": "Gate"
        case "BiP": "Bipolar"
        case "Uni": "Unipolar"
        case "Rnd": "Randomize"
        case "Clr": "Clear"
        default: s
        }
    }

    private func startMomentaryFlash(moduleID: Int, codeRef: Int) {
        momentaryFlashTask?.cancel()
        momentaryFlash = (moduleID: moduleID, codeRef: codeRef)
        momentaryFlashTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { momentaryFlash = nil }
        }
    }

    // MARK: - Hover overlay

    /// Zakres do chmurki: wartość bazowa i wartość przy morfie wykręconym do końca —
    /// ale tylko dla morfu **z focusem**, tak jak `CModule::GetHintTextWithMorph`
    /// (pyta `IsParamMorphed` z grupą z focusem, obce morfy chmurki nie zmieniają).
    /// Parametr o zakresie mniejszym niż 0…127 pokazuje całą swoją rozpiętość —
    /// przypisanie morfu ustawia mu bazę 0 i zakres równy maksimum.
    func morphHintSpan(moduleTypeID: Int?, moduleID: Int, paramIndex: Int,
                       value: Int) -> (base: Int, end: Int)?
    {
        let assignments = patch.morphs(variation: patch.activeVariation,
                                       location: area == .voice ? 1 : 0,
                                       moduleID: moduleID, paramIndex: paramIndex)
        guard let delta = assignments.first(where: { $0.morph == focusedMorph })?.range,
              delta != 0 else { return nil }
        let maxValue = moduleTypeID.flatMap {
            ParameterRangeDatabase.range(moduleTypeID: $0, codeRef: paramIndex)?.upperBound
        } ?? 127
        guard maxValue == 127 else { return (base: 0, end: maxValue) }
        return (base: value, end: max(0, min(maxValue, value + delta)))
    }

    @ViewBuilder
    var hoverOverlayView: some View {
        if let hit = hoverHit {
            let module = modules.first(where: { $0.id == hit.moduleID })
            let curVal: Int = if hit.usesModes {
                (module?.modes.indices.contains(hit.paramIndex) == true) ? module!.modes[hit.paramIndex] : 0
            } else {
                (module?.parameters.indices.contains(hit.paramIndex) == true) ? module!.parameters[hit.paramIndex] : 0
            }
            // Knob → wynik g2TextFunction (jeśli TextField powiązany) lub g2InfoFunction;
            // Przycisk z opcjami → bieżąca opcja; fallback → paramName
            let allParams = module?.parameters ?? []
            let valueText: (Int) -> String = { value in
                if hit.isKnob {
                    if let tf = hit.linkedTextField {
                        var params = allParams
                        if params.indices.contains(hit.paramIndex) { params[hit.paramIndex] = value }
                        return g2TextFunction(textFunc: tf.textFunc,
                                              deps: tf.dependencies,
                                              params: params,
                                              knobInfoFunc: hit.infoFunc)
                    }
                    return g2InfoFunction(hit.infoFunc, val: value)
                }
                if let opts = hit.displayOptions, opts.indices.contains(value) {
                    return opts[value]
                }
                return hit.paramName
            }
            let tipText = valueText(curVal)
            let morphSpan = hit.isKnob
                ? morphHintSpan(moduleTypeID: module?.typeID, moduleID: hit.moduleID,
                                paramIndex: hit.paramIndex, value: curVal)
                : nil

            // Tooltip — prawy dolny narożnik elementu
            Group {
                if let span = morphSpan {
                    // Parametr idzie za morfem z focusem: oryginał pokazuje w chmurce
                    // wartość bazową i wartość przy morfie wykręconym do końca
                    // (`CModule::GetHintTextWithMorph`).
                    VStack(alignment: .center, spacing: 1) {
                        Text("\(valueText(span.base)) -- \(valueText(span.end))")
                        Text("(\(span.base) -- \(span.end))")
                    }
                } else if hit.isKnob {
                    VStack(alignment: .center, spacing: 1) {
                        Text(tipText.isEmpty ? "\(curVal)" : tipText)
                        Text("(\(curVal))")
                    }
                } else {
                    Text(tipText.isEmpty ? "\(curVal)" : tipText)
                }
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.80)))
            .offset(x: hit.tooltipAnchor.x * zoom + 2,
                    y: hit.tooltipAnchor.y * zoom)
            .allowsHitTesting(false)

            // ▼▲ przyciski — tylko dla knobów rotacyjnych
            if let canvasRect = hit.btnsRect {
                let br = CGRect(x: canvasRect.minX * zoom, y: canvasRect.minY * zoom,
                                width: canvasRect.width * zoom, height: canvasRect.height * zoom)
                let halfW = br.width / 2 - 1
                HStack(spacing: 1) {
                    // Lewy przycisk = ▼ (dec, BVerhue aValue==0 → decrement)
                    Button {
                        let newVal = max(0, curVal - 1)
                        onParameterChange?(hit.moduleID, hit.paramIndex, newVal)
                    } label: {
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: br.height * 0.75))
                            .foregroundColor(.white)
                            .frame(width: halfW, height: br.height)
                            .background(Color(white: 0.30))
                    }
                    .buttonStyle(.plain)

                    // Prawy przycisk = ▲ (inc)
                    Button {
                        let newVal = min(127, curVal + 1)
                        onParameterChange?(hit.moduleID, hit.paramIndex, newVal)
                    } label: {
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: br.height * 0.75))
                            .foregroundColor(.white)
                            .frame(width: halfW, height: br.height)
                            .background(Color(white: 0.30))
                    }
                    .buttonStyle(.plain)
                }
                .background(Color(white: 0.20).opacity(0.9))
                .cornerRadius(2)
                .position(x: br.midX, y: br.midY)
            }
        }
    }
}
