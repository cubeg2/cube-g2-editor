import AppKit
import G2Core
import SwiftUI

struct DrumSynthPresetItem {
    let name: String
    let values: [Int]
}

extension PatchCanvasView {
    // MARK: - Graph displays (ADSR, filter response, waveform shape)

    /// Wspólna geometria obu specjalnych elementów Vocodera. Ekran pasm zachowuje
    /// dwupikselowe (Gen1) szczeliny do górnej magistrali i przycisków +/−, a siedem
    /// presetów zaczyna się na lewej krawędzi ekranu i stoi na osi przycisku Emp.
    func vocoderGraphRect(_ graph: BVGraph, ui: ModuleUIDef, moduleRect: CGRect) -> CGRect {
        let sourceScale = PatchLayout.bverhuePixelScale
        var result = CGRect(
            x: moduleRect.minX + graph.xPt,
            y: moduleRect.minY + graph.yPt,
            width: graph.widthPt,
            height: graph.heightPt
        )

        if graph.graphFunc == 8 {
            let topBusYPt = 23 * sourceScale
            let routingGap = 2 * sourceScale
            result.origin.y = moduleRect.minY + topBusYPt + routingGap
        } else if graph.graphFunc == 22 {
            let bandGraph = ui.graphs.first(where: { $0.graphFunc == 8 })
            let emphasisButton = ui.buttonsFlat.first(where: { $0.codeRef == 16 })
            result.origin.x = moduleRect.minX + (bandGraph?.xPt ?? graph.xPt)
            result.origin.y = moduleRect.minY + (emphasisButton?.yPt ?? graph.yPt)
            result.size.height = UIMetrics.buttonFlatHeight
        }
        return result
    }

    func vocoderPresetButtonRects(in rect: CGRect) -> [CGRect] {
        let count = 7
        let gap: CGFloat = 0.5
        let width = (rect.width - CGFloat(count - 1) * gap) / CGFloat(count)
        return (0 ..< count).map { index in
            CGRect(
                x: rect.minX + CGFloat(index) * (width + gap),
                y: rect.minY,
                width: width,
                height: rect.height
            )
        }
    }

    func vocoderPresetValue(_ preset: Int, band: Int) -> Int {
        switch preset {
        case 0: band + 3 < 17 ? band + 3 : 0 // -2
        case 1: band + 2 < 17 ? band + 2 : 0 // -1
        case 2: band + 1 // 0
        case 3: band // +1
        case 4: max(0, band - 1) // +2
        case 5: 16 - band // Inv
        default: Int.random(in: 0 ... 16) // Rnd
        }
    }

    /// Rozpoznaje sześć deterministycznych presetów z aktualnych parametrów.
    /// Domyślne mapowanie 1...16 odpowiada presetowi „0”, więc świeci on od razu
    /// po wstawieniu modułu; niestandardowy patch nie dostaje fałszywego wyboru.
    func matchingVocoderPreset(parameters: [Int]) -> Int? {
        guard parameters.count >= 16 else { return nil }
        return (0 ..< 6).first { preset in
            (0 ..< 16).allSatisfy { band in
                parameters[band] == vocoderPresetValue(preset, band: band)
            }
        }
    }

    /// GraphFunc 12 z Mux8-1X — odwzorowanie X Mux Graph (Draw) z oryginalnego edytora.
    ///
    /// Oryginał rysuje dwie trapezowe charakterystyki na **całej** szerokości ekranu,
    /// a nie tylko między magistralami: szczyt lewej wchodzi zza lewej krawędzi, szczyt
    /// prawej wychodzi poza prawą. Odcinek przejścia rozsuwa się o `spread` w obie
    /// strony od środka, więc przy XFade 0 obie krzywe przełączają się pionowo w
    /// połowie ekranu (twardy multiplekser), a przy maksimum tworzą pełny „X".
    /// Dwie jasne kreski pionowe stoją na 1/8 i 7/8 szerokości.
    private func drawXMuxGraph(_ ctx: GraphicsContext, value: Int, rect: CGRect) {
        let w = rect.width
        let margin = (w / 8).rounded(.down)
        let mid = w / 2
        let spread = CGFloat(min(127, max(0, value))) / 127 * (w - 2 * margin) / 2
        // Marginesy są NIESYMETRYCZNE — oryginał trzyma szczyt 3 piksele źródłowe od
        // górnej krawędzi, a dolinę tylko 1 od dolnej (`SingleLineTo(…, 3)` wobec
        // `h − 1`), więc krzywa schodzi niemal do dna ekranu.
        let px = PatchLayout.bverhuePixelScale
        let topY = rect.minY + min(3 * px, rect.height / 3)
        let botY = rect.maxY - min(px, rect.height / 3)
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x, y: y)
        }

        var guides = Path()
        guides.move(to: at(margin, rect.minY))
        guides.addLine(to: at(margin, botY))
        guides.move(to: at(w - margin, rect.minY))
        guides.addLine(to: at(w - margin, botY))
        ctx.stroke(guides, with: .color(UIColor.graphBaseline.opacity(0.75)), lineWidth: 0.5)

        var leftCurve = Path()
        leftCurve.move(to: at(3 * margin - 2 * mid, botY))
        leftCurve.addLine(to: at(2 * margin - mid + spread, topY))
        leftCurve.addLine(to: at(mid - spread, topY))
        leftCurve.addLine(to: at(mid + spread, botY))

        var rightCurve = Path()
        rightCurve.move(to: at(mid - spread, botY))
        rightCurve.addLine(to: at(mid + spread, topY))
        rightCurve.addLine(to: at(w - 2 * margin + mid - spread, topY))
        rightCurve.addLine(to: at(2 * (mid - margin) + w - margin, botY))

        var clipped = ctx
        clipped.clip(to: Path(rect))
        strokeGraphPath(clipped, leftCurve)
        strokeGraphPath(clipped, rightCurve)
    }

    func drawBVGraphs(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        guard let uid = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return }
        let noteZoom = seqNoteZoomLevel[module.id] ?? 1

        // Dla SeqNote: oblicz rect paska piano dopasowany do obszaru sliderów
        var pianoY: CGFloat?
        var pianoH: CGFloat?
        let noteKnobs = uid.seqNoteKnobs
        if !noteKnobs.isEmpty {
            let fader = faderLayout(module: module, knob: noteKnobs[0], ui: uid, rect: rect)
            pianoY = fader.track.minY
            pianoH = fader.track.height
        }

        for graph in uid.graphs {
            var gRect = CGRect(
                x: rect.minX + graph.xPt,
                y: rect.minY + graph.yPt,
                width: graph.widthPt,
                height: graph.heightPt
            )

            if module.typeID == 108, graph.graphFunc == 8 || graph.graphFunc == 22 {
                gRect = vocoderGraphRect(graph, ui: uid, moduleRect: rect)
            }

            // Graph:25 (piano strip) — wyrównaj wysokość do obszaru sliderów
            if graph.graphFunc == 25, let py = pianoY, let ph = pianoH {
                gRect = CGRect(x: gRect.minX, y: py, width: gRect.width, height: ph)
                // Lupka nad klawiaturą
                let iconSize = min(gRect.width - 0.5, 5.5)
                let iconX = gRect.minX + (gRect.width - iconSize) / 2
                let iconRect = CGRect(x: iconX, y: py - iconSize - 2.0, width: iconSize, height: iconSize)
                drawMagnifierIcon(ctx, in: iconRect, color: Color(white: 0.15))
            }

            // Graph:26 (note display) — zmniejsz do wysokości TextFielda + rysuj przyciski oktaw
            if graph.graphFunc == 26, !noteKnobs.isEmpty {
                let lcdH = UIMetrics.textFieldHeight // 6.5pt = jak Length LCD
                gRect = CGRect(x: gRect.minX, y: gRect.minY, width: gRect.width, height: lcdH)
                // Przyciski oktaw pod LCD — para KWADRATÓW obok siebie (jak każda
                // inna para −/+ w aplikacji), wyśrodkowana pod ekranem. Wcześniej
                // były to dwa płaskie prostokąty jeden pod drugim.
                let frame = octaveButtonFrames(under: gRect)
                let upFlash = octaveButtonFlash?.moduleID == module.id && octaveButtonFlash?.isUp == true
                let dnFlash = octaveButtonFlash?.moduleID == module.id && octaveButtonFlash?.isUp == false
                drawSeqIncDecButton(ctx, x: frame.down.minX, y: frame.down.minY,
                                    w: frame.down.width, h: frame.down.height,
                                    isUp: false, highlighted: dnFlash)
                drawSeqIncDecButton(ctx, x: frame.up.minX, y: frame.up.minY,
                                    w: frame.up.width, h: frame.up.height,
                                    isUp: true, highlighted: upFlash)
            }

            drawGraph(ctx, graph: graph, module: module, rect: gRect,
                      zoomLevel: noteZoom, loNoteOverride: seqNoteScrollOffset[module.id])
        }
    }

    /// Para przycisków oktawy pod ekranem nuty: dwa kwadraty obok siebie („−" z lewej,
    /// „+" z prawej — jak przy każdej innej parze w aplikacji), wyśrodkowane pod
    /// ekranem. Wspólne dla rysowania i obsługi kliknięcia.
    func octaveButtonFrames(under lcd: CGRect) -> (down: CGRect, up: CGRect) {
        let side = UIMetrics.incDecHeight
        let gap = UIMetrics.incDecGap
        let totalW = 2 * side + gap
        let x = lcd.midX - totalW / 2
        let y = lcd.maxY + 1.0
        return (CGRect(x: x, y: y, width: side, height: side),
                CGRect(x: x + side + gap, y: y, width: side, height: side))
    }

    /// Ekran wykresu (obwiednie, filtry, fale…) — wspólna obudowa wszystkich GraphFunc.
    private func drawGraphFrame(_ ctx: GraphicsContext, rect: CGRect) {
        PanelFace.recessed(ctx, rect, cornerRadius: UIMetrics.graphCornerRadius,
                           fill: UIColor.graphBackground, border: UIColor.graphBorder, shaded: panelShading)
    }

    private func drawGraph(_ ctx: GraphicsContext, graph: BVGraph, module: G2Module, rect: CGRect,
                           zoomLevel: Int = 1, loNoteOverride: Int? = nil)
    {
        let params = module.parameters
        func p(_ i: Int) -> Int {
            guard i < graph.dependencies.count else { return 0 }
            let idx = graph.dependencies[i]
            if idx < 0 {
                let modeIndex = -idx - 1
                guard module.modes.indices.contains(modeIndex) else { return 0 }
                return module.modes[modeIndex]
            }
            guard idx < params.count else { return 0 }
            return params[idx]
        }

        // Graph:25 (piano strip) — rysujemy przed standardowym bg/inner, bo pasek jest wąski
        // (~6pt) i guard inner.width > 4 blokuje normalne ścieżki. Używamy pełnego rect.
        if graph.graphFunc == 25 {
            let noteVals = (0 ..< min(16, graph.dependencies.count)).map { p($0) }
            let (lo25, hi25) = noteViewRange(params: noteVals, zoomLevel: zoomLevel, loNoteOverride: loNoteOverride)
            drawPianoKeyboardStrip(ctx, rect: rect, loNote: lo25, hiNote: hi25)
            return
        }

        // Graph:26 (note LCD) — zmniejszony do 6.5pt, inner.height < 4pt → obsługa przed guard.
        // Używamy mniejszego inset (dy:0.8) żeby tekst się zmieścił.
        if graph.graphFunc == 26 {
            drawGraphFrame(ctx, rect: rect)
            let inner26 = rect.insetBy(dx: 1.0, dy: 0.8)
            guard inner26.width > 2, inner26.height > 1 else { return }
            let noteVals26 = (0 ..< min(16, graph.dependencies.count)).map { p($0) }
            let (lo26, _) = noteViewRange(params: noteVals26, zoomLevel: zoomLevel,
                                          loNoteOverride: loNoteOverride)
            let baseOctaveNote = max(12, (lo26 / 12) * 12) // min C0
            let octaveLabel = midiNoteName(baseOctaveNote, baseOctave: baseOctaveNote / 12 - 1)
            let noteFontSize = min(UIFont.lcdDisplay(boxHeight: inner26.height), 6.0)
            drawLcdText(ctx, text: octaveLabel, box: inner26, fontSize: noteFontSize)
            return
        }

        // DrumSynth: Graph Func 46 nie jest wykresem, lecz wyborem kompletnych presetów.
        // Oryginał pokazuje nazwę tylko wtedy, gdy wszystkie 15 wartości zgadzają się z
        // jednym z zapisanych ustawień; dwa przyciski po prawej zmieniają cały zestaw.
        if graph.graphFunc == 46 {
            drawDrumSynthPresetSelector(ctx, params: params, rect: rect)
            return
        }

        // Vocoder: GraphFunc 8 jest ekranem 16 połączeń pasm, a GraphFunc 22
        // siedmioma prawdziwymi przyciskami presetów. Drugi element nie jest LCD.
        if graph.graphFunc == 8 {
            drawVocoderBands(ctx, values: (0 ..< 16).map { p($0) }, rect: rect)
            return
        }
        if graph.graphFunc == 22 {
            drawVocoderPresetButtons(ctx, module: module, rect: rect)
            return
        }

        // Background + border (wszystkie inne grafy)
        drawGraphFrame(ctx, rect: rect)

        // Wspólny margines wykresów: połowa poprzedniej wartości, by każdy ekran
        // wykorzystywał większy obszar bez dotykania obrysu.
        let inner = rect.insetBy(dx: 0.75, dy: 0.75)
        guard inner.width > 4, inner.height > 4 else { return }

        switch graph.graphFunc {
        // AR-Env: deps="1,3,0,2,4" → Attack, Release, Shape(dekoracyjne EnvCurve, bez
        // realnego selektora — zawsze 0), Output type (LevelShift, p(4)). W Clavii
        // dziedziczy geometrię ADSR z D=0 i S=127.
        case 5:
            drawEnvADSR(
                ctx,
                attack: p(0),
                decay: 0,
                sustain: 127,
                release: p(1),
                shape: 0,
                outputType: p(4),
                rect: inner
            )

        // Hold-Env: deps="0,1" → Hold, Output type (LevelShift, p(1)). H Env Graph
        // dziedziczy rysowanie AHD z natychmiastowym atakiem i opadaniem.
        case 7:
            drawEnvAHD(ctx, attack: 0, hold: p(0), decay: 0, shape: 0, outputType: p(1),
                       dynamicTotal: true, rect: inner)

        // EnvADR: deps="1,3,0,7,5" → Attack, Release, Shape, Dcy/Rel, Output type.
        // W trybie Rel AD Graph ABC przenosi opad na koniec osi i wstawia żółty hold.
        case 1:
            drawEnvADR(ctx, attack: p(0), release: p(1), shape: p(2),
                       releaseMode: p(3) != 0, outputType: p(4), rect: inner)

        case 3: drawEnvADSR(ctx, attack: p(0), decay: p(1), sustain: p(2), release: p(3), shape: p(4), outputType: p(5), rect: inner)

        // ModADSR: deps="0,1,2,3,8" → A,D,S,R, Output type (LevelShift, p(4)). Brak
        // selektora Shape w BVerhue tego modułu — zawsze 0 (nie hardkodowany błąd).
        case 4: drawEnvADSR(ctx, attack: p(0), decay: p(1), sustain: p(2), release: p(3), shape: 0, outputType: p(4), rect: inner)

        // EnvD: deps="0,1" → Decay, Output type (LevelShift, p(1)).
        case 6: drawEnvD(ctx, decay: p(0), outputType: p(1), rect: inner)

        // EqPeak: deps="0,1,2" → Freq, Gain, BW. Eq Mid Graph liczy
        // szerokość pasma jako |BW − 127|, więc trzecia zależność jest surowa.
        case 10: drawEqPeak(ctx, freq: p(0), gain: p(1), bandwidth: p(2), rect: inner)

        // LevScaler: deps="0,1,2" → p(0)=L (lewy slope), p(1)=BP (breakpoint, nuta 0-127), p(2)=R (prawy slope)
        case 11: drawLevelScalerCurve(ctx, left: p(0), breakpoint: p(1), right: p(2), rect: inner)

        // Mux8-1X: deps="0" → szerokość strefy przejścia między ośmioma wejściami.
        case 12: drawXMuxGraph(ctx, value: p(0), rect: inner)

        // Shaper Clip: deps="2,1" → kształt Asym/Sym i poziom obcinania.
        case 14: drawClipTransfer(ctx, symmetric: p(0) != 0, level: p(1), rect: inner)

        // Shaper Overdrive: deps="4,1" → kształt Asym/Sym i Drive.
        case 15: drawOverdriveTransfer(ctx, symmetric: p(0) != 0, drive: p(1), rect: inner)

        // Shaper WaveWrap: deps="1" → liczba załamań rośnie wraz z Amount.
        case 16: drawWaveWrapTransfer(ctx, amount: p(0), rect: inner)

        // OscShpB: Dependencies="6,S0" — Shape oraz wybrany przebieg w pierwszym mode.
        // Shape jest parametrem bipolarnym i zmienia geometrię wykresu; ikona
        // PartSelectora pozostaje statycznym wzorcem wybranego przebiegu.
        case 18: drawOscShpBWaveShape(ctx, waveIndex: p(1), shape: p(0), rect: inner)

        // PulseOsc: deps="5,7,10,11,S0". Oryginał wykorzystuje Width i Pulse
        // period; pozostałe kontrolki nie zmieniają statycznego podglądu.
        case 19: drawPulseOscWave(ctx, width: p(0), waveform: p(1), rect: inner)

        // FltPhase: deps="5,3,4,9" → Spread, FB, NotchCount (surowe 0...5), Type.
        case 13:
            drawFeedbackFilter(ctx, feedback: p(1), type: p(3),
                               notchCount: p(2), spread: p(0), rect: inner)

        // FltClassic: deps="0,3,4,5" → Freq, Res, dB/Oct (12/18/24), Active — zawsze LP.
        // Classic Filter Graph liczy nachylenie jako dep×6+12 i jako jedyne
        // ustawia wariant skróconych uchwytów oraz zerowy mnożnik rezonansu.
        case 20:
            drawFilter(ctx, freqParam: p(0), resParam: p(1), filterType: 0,
                       slope: min(2, max(0, p(2))) * 6 + 12,
                       resonanceScale: 0, classicVariant: true,
                       active: p(3) != 0, rect: inner)

        // FltNord: deps="0,4,8,3,5,6" → Freq, Res, FilterType, GC, dB/Oct, Active.
        // Normal Filter Graph liczy nachylenie jako dep×12+12 (12 albo 24),
        // a GC trafia wprost do mnożnika podnoszącego poziom całej linii.
        case 21:
            drawFilter(ctx, freqParam: p(0), resParam: p(1), filterType: p(2),
                       slope: min(1, max(0, p(4))) * 12 + 12,
                       resonanceScale: p(3), active: p(5) != 0, rect: inner)

        // EnvAHD: deps="1,2,4,0,5" (5 wartości: +Shape +Output type) → A,H,D,Shape,OutputType.
        // ModAHD: deps="0,1,2,6" (4 wartości: BRAK selektora Shape w BVerhue) → A,H,D,OutputType.
        // Ten sam GraphFunc dla obu modułów, ale inne przesunięcie ostatniej zależności —
        // rozróżniamy po liczbie zależności zamiast zgadywać stały indeks.
        case 28:
            if graph.dependencies.count >= 5 {
                drawEnvAHD(ctx, attack: p(0), hold: p(1), decay: p(2), shape: p(3), outputType: p(4), rect: inner)
            } else {
                drawEnvAHD(ctx, attack: p(0), hold: p(1), decay: p(2), shape: 0, outputType: p(3), rect: inner)
            }

        // EnvMulti: deps="0,1,2,3,4,5,6,7,9,10,12" → L1-L4, T1-T4, Sustain stage
        // ("L1,L2,L3,Trg" — indeks 3 = Trg = bez podtrzymania), Output type (LevelShift), Shape.
        // Brak osobnego Release — L4 jest jednocześnie poziomem końcowym.
        case 17:
            drawEnvMulti(ctx, levels: [p(0), p(1), p(2), p(3)], times: [p(4), p(5), p(6), p(7)],
                         sustainStage: p(8) < 3 ? p(8) : nil, release: nil,
                         shape: p(10), outputType: p(9), rect: inner)

        // EnvADDSR: deps="2,3,4,5,6,7,1,8,9" → A,D1,L1,D2,L2,R, Shape, Sustain stage
        // ("L1,L2" — obie wartości poprawne, bez opcji wyłączenia), Output type.
        // Attack nie ma własnego poziomu docelowego w BVerhue (tylko L1/L2) — w
        // oryginale wznosi się do pełnej skali (127), tak jak peak w drawEnvADSR.
        case 23:
            drawEnvMulti(ctx, levels: [127, p(2), p(4)], times: [p(0), p(1), p(3)],
                         sustainStage: p(7) + 1, release: p(5),
                         shape: p(6), outputType: p(8), rect: inner)

        // Operator: deps="8...15" → R1, L1, R2, L2, R3, L3, R4, L4.
        // Oryginalny DX Env Graph pokazuje cztery odcinki obwiedni DX.
        case 29:
            // Surowy `rect` (nie `inner`) — funkcja sama replikuje marginesy
            // z oryginału (Shrink 1 Gen1px + własne stałe), inny podział niż
            // wspólne wcięcie 1.5pt reszty wykresów.
            drawDXEnvelope(ctx,
                           rates: [p(0), p(2), p(4), p(6)],
                           levels: [p(1), p(3), p(5), p(7)],
                           rect: rect)

        // FltLP/FltHP: mały wykres Clavii nie liczy transmitancji biquada. Punkt
        // odcięcia przesuwa liniowo po ekranie, a tryb S0 wybiera 6...36 dB/Oct.
        case 30:
            drawSmallFilterGraph(ctx, freqParam: p(0), active: p(1) != 0,
                                 slopeMode: p(2), highPass: false, rect: inner)

        case 31:
            drawSmallFilterGraph(ctx, freqParam: p(0), active: p(1) != 0,
                                 slopeMode: p(2), highPass: true, rect: inner)

        // OscShpA: Dependencies="7,9" — drugi parametr to RadioButton Waveform;
        // pierwszy steruje Shape. LfoShpA zachowuje swoją kolejność zależności.
        case 32: drawOscShpAWaveShape(ctx, waveIndex: p(1), shape: p(0), rect: inner)

        // LfoShpA: deps="11,5,7,10" → Waveform, Shape, Phase, Output type.
        // (LfoC.txt nie ma w ogóle elementu Graph, tylko mały PartSelector osobno —
        // ten GraphFunc obsługuje wyłącznie LfoShpA.)
        case 34:
            drawGraphBaseline(ctx, rect: inner, outputType: p(3))
            let signalRect = graphSignalRectAvoidingEdgeBaseline(rect: inner, outputType: p(3))
            drawLfoShpAWaveShape(ctx, waveIndex: p(0), shape: p(1), phase: p(2),
                                 outputType: p(3), rect: signalRect)

        // LfoB: deps="4,6,8" → Waveform, Phase, Output type.
        case 33:
            drawGraphBaseline(ctx, rect: inner, outputType: p(2))
            let signalRect = graphSignalRectAvoidingEdgeBaseline(rect: inner, outputType: p(2))
            drawLfoBWaveShape(ctx, waveIndex: p(0), phase: p(1), outputType: p(2), rect: signalRect)

        // FltComb: deps="3,5" → FB oraz Type. Oryginał używa czterech stałych
        // zębów i maksymalnego rozstawu; FltPhase niżej współdzieli ten sam renderer.
        case 35:
            drawFeedbackFilter(ctx, feedback: p(0), type: p(1),
                               notchCount: 4, spread: 120, rect: inner)

        // Eq2Band: deps="0,1" → Lo/Hi gain. Eq Hi Lo Graph ma stałe punkty
        // załamania półek, więc przełączniki częstotliwości nie są zależnością
        // GraphFunc i nie zmieniają kształtu ekranu.
        case 36:
            drawEq2Band(ctx, loGain: p(0), hiGain: p(1), rect: inner)

        // Eq3Band: deps="0,1,2,3" → Lo gain, Mid gain, Mid freq, Hi gain.
        // Tak samo jak wyżej: częstotliwości półek pozostają poza zależnościami.
        case 37:
            drawEq3Band(ctx, loGain: p(0), midGain: p(1), midFreq: p(2),
                        hiGain: p(3), rect: inner)

        // Shaper Shape Exp i Saturate: deps="0,3" → Amount oraz wybrana krzywa 0...3.
        case 38: drawExponentialShaperTransfer(ctx, amount: p(0), curve: p(1), rect: inner)

        case 39: drawSaturateTransfer(ctx, amount: p(0), curve: p(1), rect: inner)

        // FltStatic: deps="0,1,2,4,3" → Freq, Res, Type, GC, Active.
        // Static Filter Graph nie ma przycisku nachylenia i wpisuje na stałe 12.
        case 40:
            drawFilter(ctx, freqParam: p(0), resParam: p(1), filterType: p(2),
                       slope: 12, resonanceScale: p(3),
                       active: p(4) != 0, rect: inner)

        // Operator: deps="17...21" → Breakpoint, typ/głębokość lewej i prawej strony.
        // Operator Graph rozróżnia -Lin, -Exp, +Exp oraz +Lin po obu stronach punktu.
        case 41:
            drawOperatorBreakpointCurve(ctx, breakpoint: p(0), leftType: p(1), leftDepth: p(2),
                                        rightType: p(3), rightDepth: p(4), rect: inner)

        // DXRouter: deps="0" → p(0)=Algorithm (0-31). Feedback (params[1]) nie wpływa na
        // KSZTAŁT diagramu — tylko na siłę sprzężenia zwrotnego operatora, który już jest
        // ustalony przez sam algorytm (potwierdzone: help.htm "An internal feedback loop
        // is indicated with orange lines... Select the internal feedback amount FOR THE
        // CONNECTED Operator" — operator jest własnością algorytmu, nie osobnym wyborem).
        case 42: drawDXAlgorithm(ctx, algorithm: p(0), rect: inner)

        // OscNoise / TunedNoise: deps="6" → Width (0...127). Oryginalny
        // Tuned Noise Graph pokazuje pasmo szumu jako symetryczną krzywą.
        case 43: drawTunedNoiseSpectrum(ctx, width: p(0), rect: inner)

        // RndTrig: deps="0" → Prob (0...127). Rnd Trig Graph (Draw) z oryginału:
        // pozioma kreska u dołu zawsze, a dziesięć pionowych
        // kresek odsłania się wg PROGÓW, nie w prostej kolejności lewo→prawo —
        // patrz tabela progów w funkcji niżej.
        case 45: drawRndTrigProbabilityBar(ctx, prob: p(0), rect: inner)

        default: break
        }
    }

    /// GraphFunc 45 (RndTrig „Prob"). 1:1 z Rnd Trig Graph (Draw) (oryginalny edytor Clavii):
    /// pozioma kreska u dołu zawsze widoczna; dziesięć pionowych kresek, równo
    /// rozstawionych od lewej krawędzi, każda odsłania się osobno gdy `prob` (bajt
    /// 0...127) przekroczy WŁASNY próg. Progi NIE rosną w kolejności pozycji —
    /// pierwsza odsłonięta (próg 0, każde prob>0) to pozycja 5 (środek), potem 2, 4,
    /// 8, 3, 6, 9, 1, 7, a jako ostatnia (próg 120) pozycja 0 (lewa krawędź) — dokładny
    /// porządek z oryginału, nie zgadywany. Potwierdzone na zrzutach 0/1/20/30/50/70/100%:
    /// każdy próg <= 10×(wartość%) daje dokładnie tyle kresek, ile widać na zrzucie.
    private func drawRndTrigProbabilityBar(_ ctx: GraphicsContext, prob: Int, rect: CGRect) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        baseline.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.stroke(baseline, with: .color(UIColor.graphLine), lineWidth: UIMetrics.graphLineWidth)

        // Indeks = pozycja 0...9 (lewo→prawo, krok co 1/9 szerokości — w oryginale
        // co 2 Gen1px poczynając od lewej krawędzi shrinkniętego prostokąta).
        // Wartość = próg z oryginału; kreska widoczna gdy prob > próg.
        let thresholds = [120, 96, 24, 60, 36, 0, 72, 108, 48, 84]
        let totalTicks = thresholds.count
        let spacing = rect.width / CGFloat(totalTicks - 1)
        for (i, threshold) in thresholds.enumerated() where prob > threshold {
            let x = rect.minX + spacing * CGFloat(i)
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: rect.minY))
            tick.addLine(to: CGPoint(x: x, y: rect.maxY))
            ctx.stroke(tick, with: .color(UIColor.graphLine), lineWidth: UIMetrics.graphLineWidth)
        }
    }

    private func drawDrumSynthPresetSelector(_ ctx: GraphicsContext, params: [Int], rect: CGRect) {
        let buttonWidth = min(9.0, max(6.0, rect.height * 0.52))
        let gap: CGFloat = 0.5
        let displayRect = CGRect(x: rect.minX, y: rect.minY,
                                 width: max(1, rect.width - buttonWidth - gap), height: rect.height)
        PanelFace.recessed(ctx, displayRect, cornerRadius: UIMetrics.graphCornerRadius,
                           fill: UIColor.lcdBackground, border: UIColor.graphBorder, shaded: panelShading)

        let presetName = (drumSynthPresetIndex(for: params).map { DrumSynthPreset.data[$0].name } ?? "none")
            .replacingOccurrences(of: " ", with: "")
        let lcdBox = displayRect.insetBy(dx: 1.1, dy: 0.8)
        // `drawLcdText` dopasowuje font/tracking osobno dla KAŻDEGO stringa: sześcioznakowe
        // nazwy (np. "Snare1") nie mieszczą się przy preferowanym trackingu 0.20 nawet przy
        // trackingu 0, więc dostawały dodatkowe zmniejszenie fontu — krótsze, pięcioznakowe
        // nazwy ("Kick1") mieściły się bez tego i renderowały większym fontem. Efekt: różne
        // rozmiary czcionki na tej samej liście. Fix: policz dopasowanie raz dla najdłuższej
        // nazwy z tabeli presetów i użyj tego samego, już „ściśniętego" rozmiaru dla wszystkich
        // — cała lista renderuje się teraz jednym (mniejszym) rozmiarem.
        let baseFontSize = min(UIFont.lcdDisplay(boxHeight: lcdBox.height), 6.4)
        let fontSize = Self.drumSynthFittedFontSize(box: lcdBox, fontSize: baseFontSize, tracking: 0.20)
        drawLcdText(ctx, text: presetName, box: lcdBox, fontSize: fontSize,
                    preferredTracking: 0.20, centered: true)

        let buttonHeight = (rect.height - gap) / 2
        let x = displayRect.maxX + gap
        drawSeqIncDecButton(ctx, x: x, y: rect.minY, w: buttonWidth, h: buttonHeight, isUp: true)
        drawSeqIncDecButton(ctx, x: x, y: rect.minY + buttonHeight + gap,
                            w: buttonWidth, h: buttonHeight, isUp: false)
    }

    func drumSynthPresetButtonRects(in rect: CGRect) -> (up: CGRect, down: CGRect) {
        let buttonWidth = min(9.0, max(6.0, rect.height * 0.52))
        let gap: CGFloat = 0.5
        let buttonHeight = (rect.height - gap) / 2
        let x = rect.maxX - buttonWidth
        return (
            up: CGRect(x: x, y: rect.minY, width: buttonWidth, height: buttonHeight),
            down: CGRect(x: x, y: rect.minY + buttonHeight + gap, width: buttonWidth, height: buttonHeight)
        )
    }

    func drumSynthPresetIndex(for parameters: [Int]) -> Int? {
        DrumSynthPreset.data.firstIndex { preset in
            parameters.count >= preset.values.count && zip(parameters, preset.values).allSatisfy(==)
        }
    }

    /// Sam rozmiar czcionki wymagany, żeby najdłuższa nazwa presetu (po usunięciu spacji,
    /// np. "Snare1") zmieściła się w `box` przy zadanym trackingu — bez rysowania. Ten sam
    /// wynik jest potem używany dla wszystkich nazw presetów, żeby lista miała jeden,
    /// jednolity rozmiar zamiast osobnego dopasowania per string (patrz `drawDrumSynthPresetSelector`).
    private static func drumSynthFittedFontSize(box: CGRect, fontSize: CGFloat, tracking: CGFloat) -> CGFloat {
        let fontName = "MatrixSansScreen-Regular"
        func measuredWidth(_ string: String, size: CGFloat) -> CGFloat {
            guard !string.isEmpty else { return 0 }
            let font = NSFont(name: fontName, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            return (string as NSString).size(withAttributes: [.font: font]).width
        }
        let widestName = DrumSynthPreset.data
            .map { $0.name.replacingOccurrences(of: " ", with: "") }
            .max { $0.count < $1.count } ?? "Snare1"
        let glyphGaps = max(1, widestName.count - 1)
        let availableWidth = max(1, box.width - 1.4)
        let trackedWidth = max(1, measuredWidth(widestName, size: fontSize) + tracking * CGFloat(glyphGaps))
        let fitScale = min(1, availableWidth / trackedWidth)
        return fontSize * fitScale
    }

    enum DrumSynthPreset {
        /// Zawartość fValues/fNames z Drum Preset Selector w oryginalnym edytorze Clavii.
        static let data: [DrumSynthPresetItem] = [
            DrumSynthPresetItem(name: "Kick 1", values: [42, 15, 46, 50, 120, 102, 57, 32, 39, 49, 1, 68, 61, 79, 115]),
            DrumSynthPresetItem(name: "Kick 2", values: [43, 26, 55, 53, 105, 94, 63, 18, 78, 36, 1, 76, 44, 25, 123]),
            DrumSynthPresetItem(name: "Kick 3", values: [31, 71, 45, 35, 127, 0, 90, 24, 71, 27, 0, 84, 42, 81, 112]),
            DrumSynthPresetItem(name: "Kick 4", values: [32, 61, 58, 42, 113, 110, 90, 0, 0, 27, 1, 37, 55, 90, 127]),
            DrumSynthPresetItem(name: "Kick 5", values: [36, 39, 50, 52, 104, 92, 111, 0, 40, 32, 0, 34, 68, 79, 69]),
            DrumSynthPresetItem(name: "Snare 1", values: [79, 55, 35, 43, 127, 42, 102, 46, 0, 37, 2, 2, 0, 127, 127]),
            DrumSynthPresetItem(name: "Snare 2", values: [68, 3, 48, 42, 84, 127, 55, 66, 63, 40, 2, 63, 37, 126, 122]),
            DrumSynthPresetItem(name: "Snare 3", values: [64, 23, 36, 44, 120, 84, 26, 0, 19, 44, 2, 24, 44, 127, 98]),
            DrumSynthPresetItem(name: "Snare 4", values: [68, 57, 47, 33, 105, 0, 91, 28, 42, 42, 0, 81, 44, 112, 127]),
            DrumSynthPresetItem(name: "Snare 5", values: [85, 107, 32, 23, 127, 94, 0, 0, 63, 45, 2, 39, 55, 102, 98]),
            DrumSynthPresetItem(name: "Tom1 1", values: [80, 38, 56, 47, 102, 58, 98, 26, 27, 50, 0, 33, 69, 105, 97]),
            DrumSynthPresetItem(name: "Tom1 2", values: [69, 38, 57, 52, 102, 58, 96, 26, 27, 51, 0, 33, 69, 105, 89]),
            DrumSynthPresetItem(name: "Tom1 3", values: [56, 38, 58, 52, 102, 58, 93, 26, 27, 53, 0, 33, 69, 105, 89]),
            DrumSynthPresetItem(name: "Tom2 1", values: [86, 2, 55, 44, 99, 0, 67, 0, 56, 56, 0, 86, 65, 81, 117]),
            DrumSynthPresetItem(name: "Tom2 2", values: [69, 2, 56, 45, 99, 0, 67, 0, 56, 56, 0, 86, 65, 81, 117]),
            DrumSynthPresetItem(name: "Tom2 3", values: [55, 2, 58, 49, 99, 0, 67, 0, 56, 57, 0, 86, 65, 81, 117]),
            DrumSynthPresetItem(name: "Tom3 1", values: [70, 28, 45, 51, 113, 81, 102, 4, 12, 47, 0, 44, 46, 96, 97]),
            DrumSynthPresetItem(name: "Tom3 2", values: [58, 28, 46, 53, 113, 81, 102, 4, 12, 47, 0, 44, 57, 93, 97]),
            DrumSynthPresetItem(name: "Tom3 3", values: [48, 28, 52, 54, 108, 81, 102, 4, 12, 47, 0, 44, 66, 96, 103]),
            DrumSynthPresetItem(name: "Cymb 1", values: [127, 93, 0, 0, 0, 102, 91, 0, 26, 46, 2, 127, 0, 0, 127]),
            DrumSynthPresetItem(name: "Cymb 2", values: [127, 93, 0, 0, 0, 102, 91, 50, 16, 55, 2, 127, 0, 0, 127]),
            DrumSynthPresetItem(name: "Cymb 3", values: [127, 127, 19, 0, 28, 58, 112, 60, 0, 50, 2, 0, 0, 81, 107]),
            DrumSynthPresetItem(name: "Cymb 4", values: [127, 127, 0, 0, 0, 127, 102, 107, 0, 53, 2, 127, 0, 0, 127]),
            DrumSynthPresetItem(name: "Cymb 5", values: [28, 111, 42, 64, 73, 28, 83, 57, 37, 71, 0, 83, 50, 109, 123]),
            DrumSynthPresetItem(name: "Perc 1", values: [77, 32, 31, 45, 117, 93, 32, 32, 40, 45, 2, 110, 126, 116, 30]),
            DrumSynthPresetItem(name: "Perc 2", values: [127, 99, 52, 48, 86, 71, 110, 120, 0, 45, 2, 47, 16, 49, 114]),
            DrumSynthPresetItem(name: "Perc 3", values: [96, 60, 36, 42, 127, 72, 32, 32, 40, 45, 2, 46, 24, 89, 46]),
            DrumSynthPresetItem(name: "Perc 4", values: [87, 60, 36, 42, 127, 72, 32, 32, 40, 45, 2, 46, 24, 89, 46]),
            DrumSynthPresetItem(name: "Perc 5", values: [110, 93, 58, 66, 92, 79, 92, 127, 0, 58, 0, 0, 0, 127, 89]),
            DrumSynthPresetItem(name: "Perc 6", values: [30, 45, 62, 46, 127, 127, 55, 127, 28, 41, 2, 81, 55, 80, 97]),
        ]
    }

    // MARK: - Shaper transfer displays (GraphFunc 14, 15, 16, 38, 39)

    /// Wspólny układ osi i próbkowanie charakterystyki wejście→wyjście. Oryginalna
    /// Clavia rysuje te pięć ekranów w tej samej, bipolarnej przestrzeni -1...1.
    private func drawShaperTransfer(_ ctx: GraphicsContext,
                                    rect: CGRect,
                                    samples: Int? = nil,
                                    trimsOutsideRange: Bool = false,
                                    transform: (Double) -> Double)
    {
        var axes = Path()
        axes.move(to: CGPoint(x: rect.minX, y: rect.midY))
        axes.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        axes.move(to: CGPoint(x: rect.midX, y: rect.minY))
        axes.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        ctx.stroke(axes, with: .color(UIColor.graphBaseline.opacity(0.75)), lineWidth: 0.5)

        let sampleCount = samples ?? max(48, Int(rect.width * 3))
        var path = Path()
        var previousT: Double?
        var previousOutput: Double?
        var hasVisibleSegment = false

        func point(t: Double, output: Double) -> CGPoint {
            CGPoint(
                x: rect.minX + CGFloat(t) * rect.width,
                y: rect.midY - CGFloat(output) * rect.height * 0.5
            )
        }

        for index in 0 ... sampleCount {
            let t = Double(index) / Double(sampleCount)
            let input = t * 2 - 1
            let output = transform(input)

            if trimsOutsideRange {
                if (-1 ... 1).contains(output) {
                    let currentPoint = point(t: t, output: output)
                    if hasVisibleSegment {
                        path.addLine(to: currentPoint)
                    } else if let previousT, let previousOutput {
                        let boundary = previousOutput < -1 ? -1.0 : 1.0
                        let fraction = (boundary - previousOutput) / (output - previousOutput)
                        let crossingT = previousT + (t - previousT) * fraction
                        path.move(to: point(t: crossingT, output: boundary))
                        path.addLine(to: currentPoint)
                        hasVisibleSegment = true
                    } else {
                        path.move(to: currentPoint)
                        hasVisibleSegment = true
                    }
                } else if hasVisibleSegment, let previousT, let previousOutput {
                    let boundary = output < -1 ? -1.0 : 1.0
                    let fraction = (boundary - previousOutput) / (output - previousOutput)
                    let crossingT = previousT + (t - previousT) * fraction
                    path.addLine(to: point(t: crossingT, output: boundary))
                    hasVisibleSegment = false
                }
            } else {
                let visibleOutput = max(-1, min(1, output))
                let currentPoint = point(t: t, output: visibleOutput)
                if index == 0 { path.move(to: currentPoint) } else { path.addLine(to: currentPoint) }
            }

            previousT = t
            previousOutput = output
        }
        strokeGraphPath(ctx, path)
    }

    /// GraphFunc 14 — odcinki liniowe Dist A Graph: wraz ze wzrostem Level skraca
    /// się część liniowa, a końce charakterystyki przechodzą w poziome ograniczenie.
    private func drawClipTransfer(_ ctx: GraphicsContext,
                                  symmetric: Bool,
                                  level: Int,
                                  rect: CGRect)
    {
        let amount = Double(max(0, min(127, level))) / 127
        // Dist A Graph wyznacza granicę bez dodatkowego „bezpiecznego” marginesu.
        // Przy 127 oba odcinki spotykają się dokładnie w osi zera.
        let threshold = 1 - amount
        drawShaperTransfer(ctx, rect: rect) { input in
            if symmetric { return max(-threshold, min(threshold, input)) }
            return input < 0 ? input : min(threshold, input)
        }
    }

    /// GraphFunc 15 — znormalizowana postać sześciennych odcinków
    /// Dist B Graph (Draw). Oryginał rysuje 20 kroków, nie funkcję tanh;
    /// zachowanie tej konstrukcji usuwa niezgodne falowanie widoczne przy Drive.
    private func drawOverdriveTransfer(_ ctx: GraphicsContext,
                                       symmetric: Bool,
                                       drive: Int,
                                       rect: CGRect)
    {
        drawShaperTransfer(ctx, rect: rect, samples: 20) { input in
            ShaperTransfer.overdrive(input: input, symmetric: symmetric, drive: drive)
        }
    }

    /// Wektorowa konstrukcja Wrap Graph. Clavia kreśli parę lustrzanych
    /// łamanych; nie jest to fala sinusoidalna ani funkcja arcsin(sin()).
    private func drawWaveWrapTransfer(_ ctx: GraphicsContext, amount: Int, rect: CGRect) {
        var axes = Path()
        axes.move(to: CGPoint(x: rect.minX, y: rect.midY))
        axes.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        axes.move(to: CGPoint(x: rect.midX, y: rect.minY))
        axes.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        ctx.stroke(axes, with: .color(UIColor.graphBaseline.opacity(0.75)), lineWidth: 0.5)

        // `UpdateGraphics`: value = Amount / 8 + 1 (1/8 = 0.125).
        let wraps = ShaperTransfer.waveWrapFactor(amount: amount)
        let fullSegments = Int(wraps.rounded(.down))
        let remainder = wraps - Double(fullSegments)
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        let segmentWidth = halfWidth / CGFloat(wraps)

        var right = Path()
        var left = Path()
        var x: CGFloat = 0
        var y = halfHeight
        right.move(to: CGPoint(x: rect.midX, y: rect.minY + y))
        left.move(to: CGPoint(x: rect.midX, y: rect.maxY - y))

        func nextFullY(_ phase: Int, from current: CGFloat) -> CGFloat {
            switch phase % 4 {
            case 1: current - halfHeight
            case 2, 3: current + halfHeight
            default: current - halfHeight
            }
        }

        for phase in 1 ... fullSegments {
            let nextX = x + segmentWidth
            let next = nextFullY(phase, from: y)
            right.addLine(to: CGPoint(x: rect.midX + nextX, y: rect.minY + next))
            left.addLine(to: CGPoint(x: rect.midX - nextX, y: rect.maxY - next))
            x = nextX
            y = next
        }

        if remainder > 0 {
            let nextX = x + segmentWidth * CGFloat(remainder)
            let next = switch fullSegments % 4 {
            case 0, 3: y - halfHeight * CGFloat(remainder)
            default: y + halfHeight * CGFloat(remainder)
            }
            right.addLine(to: CGPoint(x: rect.midX + nextX, y: rect.minY + next))
            left.addLine(to: CGPoint(x: rect.midX - nextX, y: rect.maxY - next))
        }
        strokeGraphPath(ctx, right)
        strokeGraphPath(ctx, left)
    }

    /// GraphFunc 38 — Shape B Graph miesza przebieg liniowy z potęgą o wykładniku
    /// wybieranym przez przyciski x2...x5.
    private func drawExponentialShaperTransfer(_ ctx: GraphicsContext,
                                               amount: Int,
                                               curve: Int,
                                               rect: CGRect)
    {
        drawShaperTransfer(ctx, rect: rect, trimsOutsideRange: true) { input in
            ShaperTransfer.exponential(input: input, amount: amount, curve: curve)
        }
    }

    /// GraphFunc 39 — rodzina krzywych saturacji x2...x5. Większy Amount podnosi
    /// nachylenie przy zerze i spłaszcza oba końce charakterystyki.
    private func drawSaturateTransfer(_ ctx: GraphicsContext,
                                      amount: Int,
                                      curve: Int,
                                      rect: CGRect)
    {
        drawShaperTransfer(ctx, rect: rect) { input in
            ShaperTransfer.saturate(input: input, amount: amount, curve: curve)
        }
    }

    // MARK: - DXRouter: diagram algorytmu FM (GraphFunc:42)

    /// Definicja jednego z pierwszych sześciu algorytmów DX7, zachowanych zgodnie
    /// z ręcznie zatwierdzonym trasowaniem SVG użytkownika. Algorytmy 7–32 korzystają
    /// z dokładnych ścieżek w `DXRouterAtlas`.
    /// Moduł "Algorithm" DXRoutera to dosłownie
    /// indeks algorytmu DX7 — potwierdzone w `reference/g2ools/dx2g2.py`:
    /// `dxrouter.params.Algorithm.variations[i] = dxpatch.Algorithm`, oraz w oficjalnej
    /// pomocy Norda: "These 32 algorithms corresponds to the factory algorithms of the
    /// DX7 synthesizer"). `edges`: (from, to) = operator `from` moduluje operator `to`
    /// (FM). Operator który nie jest źródłem żadnej krawędzi = carrier (miksowany do
    /// wyjścia "Main"). `feedback`: operator, z którego wychodzi pętla sprzężenia.
    private struct DXAlgoDef {
        let edges: [(from: Int, to: Int)]
        let feedback: Int
    }

    /// Pierwsze sześć algorytmów pozostaje zgodne z zaakceptowanymi szkicami 1–4 oraz
    /// ręcznym przepisaniem 5–6 z atlasu. Dalsze algorytmy nie używają tej tabeli.
    /// Sam tor sprzężenia pochodzi z atlasu (`DXRouterAtlas.firstSixFeedback`), dlatego
    /// tabela podaje tylko operator źródłowy — także dla algorytmów 4 i 6, gdzie pętla
    /// obejmuje kilka operatorów (6→4 oraz 6→5).
    private static let dxAlgorithms: [DXAlgoDef] = [
        /* 1  */ DXAlgoDef(edges: [(2, 1), (6, 5), (5, 4), (4, 3)], feedback: 6),
        /* 2  */ DXAlgoDef(edges: [(2, 1), (6, 5), (5, 4), (4, 3)], feedback: 2),
        /* 3  */ DXAlgoDef(edges: [(2, 1), (6, 5), (5, 4), (4, 1), (3, 2)], feedback: 6),
        /* 4  */ DXAlgoDef(edges: [(2, 1), (6, 5), (5, 4), (4, 1), (3, 2)], feedback: 6),
        /* 5  */ DXAlgoDef(edges: [(2, 1), (4, 3), (6, 5)], feedback: 6),
        /* 6  */ DXAlgoDef(edges: [(2, 1), (4, 3), (6, 5)], feedback: 6),
    ]

    /// Rysuje algorytmy 7–32 z polilinii zapisanych w `DXRouterAtlas`.
    /// Współrzędne atlasu są przeliczane na zaakceptowaną geometrię pierwszych sześciu
    /// algorytmów, dlatego boxy i cyfry pozostają stylistycznie identyczne.
    private func drawDXAtlasAlgorithm(_ ctx: GraphicsContext, algorithm: Int, rect: CGRect) {
        let drawing = DXRouterAtlas.algorithms[max(0, min(25, algorithm - 6))]
        // Diagram wypełnia teraz większą część ekranu, zachowując środkową kolumnę na
        // osi i proporcje każdego atlasowego punktu względem gniazd.
        let columnWidth = rect.width / 3 * 1.12
        // Gniazdo ma szerokość oryginału (17 z 49 px kolumny atlasu); szersze zasłaniało
        // tor sprzężenia biegnący tuż obok.
        let boxW = columnWidth * 0.3479
        let boxH = rect.height * 0.245
        let topY = rect.minY + rect.height * 0.145
        let bottomY = topY + boxH + rect.height * 0.16
        let topCenterY = topY + boxH / 2
        let rowScale = (bottomY - topY) / 25
        let columnScale = columnWidth / 49

        func atlasPoint(_ point: DXAtlasPoint) -> CGPoint {
            CGPoint(
                x: rect.midX + (point.x - 68) * columnScale,
                y: topCenterY + (point.y - 16.5) * rowScale
            )
        }

        func box(_ op: Int) -> CGRect {
            let isTop = [2, 4, 6].contains(op)
            let col: Int = [2: 0, 4: 1, 6: 2, 1: 0, 3: 1, 5: 2][op] ?? 0
            let centerX = rect.midX + CGFloat(col - 1) * columnWidth
            return CGRect(x: centerX - boxW / 2, y: isTop ? topY : bottomY, width: boxW, height: boxH)
        }

        func draw(_ polylines: [[DXAtlasPoint]], color: Color, normalizeFeedbackClearance: Bool = false) {
            for points in polylines {
                guard let first = points.first else { continue }
                var path = Path()
                path.move(to: atlasPoint(normalizeFeedbackClearance
                        ? DXRouterAtlas.displayFeedbackPoint(first) : first))
                for point in points.dropFirst() {
                    path.addLine(to: atlasPoint(normalizeFeedbackClearance
                            ? DXRouterAtlas.displayFeedbackPoint(point) : point))
                }
                ctx.stroke(path, with: .color(color), lineWidth: UIMetrics.graphLineWidth)
            }
        }

        // Sprzężenie jest pod liniami modulacji i boxami, tak jak w zatwierdzonych 1–6.
        draw(drawing.feedback, color: UIColor.connectorAudio, normalizeFeedbackClearance: true)
        draw(
            drawing.modulation.map {
                $0.map { DXRouterAtlas.displayModulationPoint($0, algorithm: algorithm + 1) }
            },
            color: UIColor.graphLine
        )

        // Grot wyjścia jest jedynym wypełnionym elementem atlasu; pozycja zmienia się
        // między rodzinami algorytmów i dlatego pochodzi z każdej klatki osobno.
        let arrowTip = atlasPoint(DXAtlasPoint(x: drawing.arrowX, y: 63))
        // Pionowa magistrala atlasu kończy się na Y=59. Grot zaczyna się dokładnie w
        // tym samym punkcie, inaczej po skalowaniu powstaje widoczna szczelina.
        let arrowLeft = atlasPoint(DXAtlasPoint(x: drawing.arrowX - 3, y: 59))
        let arrowRight = atlasPoint(DXAtlasPoint(x: drawing.arrowX + 3, y: 59))
        var head = Path()
        head.move(to: arrowLeft)
        head.addLine(to: arrowTip)
        head.addLine(to: arrowRight)
        head.closeSubpath()
        ctx.fill(head, with: .color(UIColor.graphLine))

        for op in 1 ... 6 {
            let b = box(op)
            ctx.fill(Path(roundedRect: b, cornerRadius: 0.5), with: .color(UIColor.graphBackground))
            ctx.stroke(Path(roundedRect: b, cornerRadius: 0.5), with: .color(UIColor.graphLine), lineWidth: UIMetrics.graphLineWidth)
            ctx.draw(
                Text("\(op)").font(.custom("MatrixSansScreen-Regular", size: boxH * 0.62))
                    .foregroundColor(UIColor.lcdText),
                at: CGPoint(x: b.midX, y: b.midY), anchor: .center
            )
        }
    }

    /// Rysuje diagram algorytmu: gniazda 2/4/6 w górnym rzędzie, 1/3/5 w dolnym (pozycje
    /// STAŁE, niezależne od algorytmu), zielone linie modulacji, czerwona pętla feedbacku,
    /// strzałka w dół do "Main". Geometria i reguły trasowania odtworzone ze szkiców SVG
    /// użytkownika (`DXRouter-1/2/3.svg`): wyjście operatora wychodzi dołem gniazda,
    /// wejście wchodzi górą (przy zajętej stronie — po przeciwnej), a linie biegną trzema
    /// poziomymi korytarzami, omijając się nawzajem (własny korytarz pionowy + pas
    /// zapasowy przy magistrali).
    private func drawDXAlgorithm(_ ctx: GraphicsContext, algorithm: Int, rect: CGRect) {
        let clampedAlgorithm = max(0, min(31, algorithm))
        if clampedAlgorithm >= 6 {
            drawDXAtlasAlgorithm(ctx, algorithm: clampedAlgorithm, rect: rect)
            return
        }
        let algo = Self.dxAlgorithms[clampedAlgorithm]

        // Wszystkie ułamki poniżej odczytane 1:1 ze szkiców SVG użytkownika
        // (DXRouter-1/2/3.svg, viewBox 275.34×134.85) — nie są przybliżeniami.
        // Wspólna geometria z atlasem 7–32: większy, lecz nadal wyśrodkowany diagram.
        let columnWidth = rect.width / 3 * 1.12
        // Szerokość gniazda jak w oryginale (17 z 49 px kolumny atlasu) — wspólna z 7–32.
        let boxW = columnWidth * 0.3479
        let boxH = rect.height * 0.245
        let topY = rect.minY + rect.height * 0.145
        let bottomY = topY + boxH + rect.height * 0.16

        func isTopRow(_ op: Int) -> Bool {
            [2, 4, 6].contains(op)
        }
        func box(_ op: Int) -> CGRect {
            // op ∈ {2,4,6} → górny rząd; op ∈ {1,3,5} → dolny rząd (pozycje stałe)
            let col: Int = [2: 0, 4: 1, 6: 2, 1: 0, 3: 1, 5: 2][op] ?? 0
            let centerX = rect.midX + CGFloat(col - 1) * columnWidth
            return CGRect(x: centerX - boxW / 2, y: isTopRow(op) ? topY : bottomY, width: boxW, height: boxH)
        }

        // Trzy poziome korytarze, którymi biegną linie: nad górnym rzędem, w przerwie
        // między rzędami, oraz magistrala pod dolnym rzędem (+ pas zapasowy tuż nad nią,
        // używany gdy dwie linie musiałyby biec po sobie).
        let busY = bottomY + boxH + rect.height * 0.10
        let raisedBusY = busY - rect.height * 0.0524
        let outerTopY = rect.minY + rect.height * 0.0693
        let loweredTopY = outerTopY + rect.height * 0.0469
        let midGapY = (topY + boxH + bottomY) / 2
        let arrowX = rect.midX - columnWidth / 2

        /// Poziom, na który linia wychodzi z danej krawędzi gniazda.
        func lane(_ op: Int, bottom: Bool) -> CGFloat {
            if isTopRow(op) { return bottom ? midGapY : outerTopY }
            return bottom ? busY : midGapY
        }

        // Strony podłączeń: WYJŚCIE operatora zawsze dołem gniazda, WEJŚCIE górą; jeśli
        // wymagana strona jest już zajęta przez inną krawędź — linia ląduje po przeciwnej
        // (DXRouter-3.svg: operator 1 przyjmuje 2→1 górą, więc 4→1 wchodzi dołem).
        // Carrier rezerwuje dół (zjeżdża do magistrali), feedback — górę swojego operatora
        // (pętla własna tam wraca, sprzężenie wieloperatorowe stamtąd wychodzi; do dołu
        // celu wchodzi z przesunięciem w bok, więc tam nic nie rezerwuje).
        let sources = Set(algo.edges.map(\.from))
        let carriers = (1 ... 6).filter { !sources.contains($0) }
        var usedBottom = Set(carriers)
        var usedTop: Set<Int> = [algo.feedback]
        var sides: [(srcBottom: Bool, dstTop: Bool)] = []
        for (from, to) in algo.edges {
            let srcBottom = !usedBottom.contains(from)
            if srcBottom { usedBottom.insert(from) } else { usedTop.insert(from) }
            let dstTop = !usedTop.contains(to)
            if dstTop { usedTop.insert(to) } else { usedBottom.insert(to) }
            sides.append((srcBottom, dstTop))
        }

        var usedCorridors: [CGFloat] = []
        var busRuns: [(CGFloat, CGFloat)] = []
        var topRuns: [(CGFloat, CGFloat)] = []

        // Sprzężenie — polilinia z tej samej klatki atlasu, z której pochodzą algorytmy
        // 7–32, więc pętla ma wszędzie ten sam kształt i rozmiar. Rysowana PRZED liniami
        // modulacji i gniazdami: rezerwuje swoje korytarze (linie modulacji ustąpią jej
        // miejsca) i chowa końcówki pod gniazdami. Kolor czerwony jak gniazda audio.
        let rowScale = (bottomY - topY) / 25
        let columnScale = columnWidth / 49
        let fbPoints = DXRouterAtlas.firstSixFeedback[clampedAlgorithm].map { rawPoint in
            let point = DXRouterAtlas.displayFeedbackPoint(rawPoint)
            return CGPoint(
                x: rect.midX + (point.x - 68) * columnScale,
                y: topY + boxH / 2 + (point.y - 16.5) * rowScale
            )
        }
        var fb = Path()
        fb.move(to: fbPoints[0])
        for point in fbPoints.dropFirst() {
            fb.addLine(to: point)
        }
        ctx.stroke(fb, with: .color(UIColor.connectorAudio), lineWidth: UIMetrics.graphLineWidth)

        // Rezerwacje dla linii modulacji: pionowe obejście zajmuje swój korytarz (stuby
        // przy gniazdach — pierwszy i ostatni odcinek — niczego nie blokują), a odcinek
        // poziomy blokuje pas tylko wtedy, gdy naprawdę na nim leży. Sprzężenie biegnące
        // pasem zapasowym zostawia więc pas główny wolny, zamiast spychać na siebie zieloną.
        for index in 0 ..< fbPoints.count - 1 {
            let (a, b) = (fbPoints[index], fbPoints[index + 1])
            let isStub = index == 0 || index == fbPoints.count - 2
            let run = (min(a.x, b.x), max(a.x, b.x))
            if abs(a.x - b.x) < 0.5 {
                if !isStub { usedCorridors.append(a.x) }
            } else if a.y < topY, abs(a.y - outerTopY) < abs(a.y - loweredTopY) {
                topRuns.append(run)
            } else if a.y > bottomY + boxH, abs(a.y - busY) < abs(a.y - raisedBusY) {
                busRuns.append(run)
            }
        }

        // Linie modulacji — pod spodem, żeby gniazda (rysowane później) je przykryły na styku.
        for (index, edge) in algo.edges.enumerated() {
            let a = box(edge.from)
            let b = box(edge.to)
            let (srcBottom, dstTop) = sides[index]
            var path = Path()
            // Para w tej samej kolumnie podłączona naturalnymi stronami → prosta pionowa.
            if abs(a.midX - b.midX) < 0.5, srcBottom, dstTop, isTopRow(edge.from) {
                path.move(to: CGPoint(x: a.midX, y: a.maxY))
                path.addLine(to: CGPoint(x: b.midX, y: b.minY))
                ctx.stroke(path, with: .color(UIColor.graphLine), lineWidth: UIMetrics.graphLineWidth)
                continue
            }
            let start = CGPoint(x: a.midX, y: srcBottom ? a.maxY : a.minY)
            let end = CGPoint(x: b.midX, y: dstTop ? b.minY : b.maxY)
            var srcLane = lane(edge.from, bottom: srcBottom)
            var dstLane = lane(edge.to, bottom: !dstTop)
            // Korytarz pionowy: zwykle granica kolumn po drodze do celu. Krawędź wpadająca
            // do magistrali obchodzi gniazdo źródła z przeciwnej strony (DXRouter-3.svg:
            // 4→1 schodzi prawą stroną, mimo że cel jest po lewej).
            var corridorX: CGFloat = if dstLane == busY {
                a.midX + (b.midX < a.midX ? columnWidth / 2 : -columnWidth / 2)
            } else if abs(a.midX - b.midX) > columnWidth * 1.5 {
                b.midX + (a.midX > b.midX ? columnWidth / 2 : -columnWidth / 2)
            } else {
                (a.midX + b.midX) / 2
            }
            let shift: CGFloat = a.midX < corridorX ? -columnWidth * 0.12 : columnWidth * 0.12
            while usedCorridors.contains(where: { abs($0 - corridorX) < columnWidth * 0.05 }) {
                corridorX += shift
            }
            usedCorridors.append(corridorX)
            // Odcinek biegnący przy magistrali — przy kolizji z już poprowadzoną linią
            // przesuwany na pas zapasowy (DXRouter-3.svg: 3→2 biegnie ponad 4→1).
            if srcLane == busY || dstLane == busY {
                let runX = srcLane == busY ? start.x : end.x
                let run = (min(runX, corridorX), max(runX, corridorX))
                if busRuns.contains(where: { $0.0 < run.1 - 0.5 && run.0 < $0.1 - 0.5 }) {
                    if srcLane == busY { srcLane = raisedBusY } else { dstLane = raisedBusY }
                } else {
                    busRuns.append(run)
                }
            }
            // To samo dla korytarza nad rzędami — ustępuje np. sprzężeniu wieloperatorowemu,
            // które biegnie górą przez cały diagram (DXRouter-4.svg: 5→4 spycha się niżej).
            if srcLane == outerTopY || dstLane == outerTopY {
                let runX = srcLane == outerTopY ? start.x : end.x
                let run = (min(runX, corridorX), max(runX, corridorX))
                if topRuns.contains(where: { $0.0 < run.1 - 0.5 && run.0 < $0.1 - 0.5 }) {
                    if srcLane == outerTopY { srcLane = loweredTopY } else { dstLane = loweredTopY }
                } else {
                    topRuns.append(run)
                }
            }
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x, y: srcLane))
            path.addLine(to: CGPoint(x: corridorX, y: srcLane))
            path.addLine(to: CGPoint(x: corridorX, y: dstLane))
            path.addLine(to: CGPoint(x: end.x, y: dstLane))
            path.addLine(to: end)
            ctx.stroke(path, with: .color(UIColor.graphLine), lineWidth: UIMetrics.graphLineWidth)
        }

        // Carrier = operator który nie jest źródłem żadnej krawędzi → miksowany do "Main".
        for op in carriers {
            let b = box(op)
            let isTopRow = isTopRow(op)
            // Operator górnego rzędu jako carrier: ominięcie gniazda pod nim (ta sama kolumna)
            let dropX = isTopRow ? b.midX - boxW * 0.30 : b.midX
            var p = Path()
            p.move(to: CGPoint(x: b.midX, y: b.maxY))
            if isTopRow { p.addLine(to: CGPoint(x: dropX, y: b.maxY)) }
            p.addLine(to: CGPoint(x: dropX, y: busY))
            p.addLine(to: CGPoint(x: arrowX, y: busY))
            ctx.stroke(p, with: .color(UIColor.graphLine), lineWidth: UIMetrics.graphLineWidth)
        }
        // Strzałka wyjścia "Main" — stała pozycja (granica kolumn 0/1) niezależnie od tego,
        // które operatory są carrierami; grot to wypełniony trójkąt. 1:1 ze szkicem SVG.
        let arrowTipY = busY + rect.height * 0.0911
        let headSize = rect.height * 0.0611
        var arrow = Path()
        arrow.move(to: CGPoint(x: arrowX, y: busY))
        arrow.addLine(to: CGPoint(x: arrowX, y: arrowTipY - headSize))
        ctx.stroke(arrow, with: .color(UIColor.graphLine), lineWidth: UIMetrics.graphLineWidth)
        var head = Path()
        head.move(to: CGPoint(x: arrowX - headSize, y: arrowTipY - headSize))
        head.addLine(to: CGPoint(x: arrowX, y: arrowTipY))
        head.addLine(to: CGPoint(x: arrowX + headSize, y: arrowTipY - headSize))
        head.closeSubpath()
        ctx.fill(head, with: .color(UIColor.graphLine))

        // Gniazda operatorów — rysowane NA liniach, żeby zakończenia wchodziły "pod" box.
        // Sam outline (bez żółtego wypełnienia) — tło takie jak reszta grafu, żeby linie
        // pod spodem nie prześwitywały na styku z krawędzią.
        for op in 1 ... 6 {
            let b = box(op)
            ctx.fill(Path(roundedRect: b, cornerRadius: 0.5), with: .color(UIColor.graphBackground))
            ctx.stroke(Path(roundedRect: b, cornerRadius: 0.5), with: .color(UIColor.graphLine), lineWidth: UIMetrics.graphLineWidth)
            ctx.draw(
                Text("\(op)").font(.custom("MatrixSansScreen-Regular", size: boxH * 0.62))
                    .foregroundColor(UIColor.lcdText),
                at: CGPoint(x: b.midX, y: b.midY), anchor: .center
            )
        }
    }

    // MARK: - Piano keyboard strip (SeqNote)

    /// Pionowy pasek klawiszy piano po prawej stronie siatki SeqNote.
    /// Dwa przebiegi: najpierw białe klawisze, potem czarne na wierzchu.
    /// Czarny klawisz = 62% szerokości, z marginesem pionowym.
    /// Etykiety C (np. "C4") na prawo od paska.
    private func drawPianoKeyboardStrip(
        _ ctx: GraphicsContext, rect: CGRect,
        loNote: Int, hiNote: Int
    ) {
        let range = CGFloat(hiNote - loNote)
        guard range > 0, rect.width > 1 else { return }

        // Korpus klawiatury jest BIAŁY (jak w oryginale Clavii) — białe klawisze to
        // samo tło rozdzielone cienkimi kreskami, a czarne to ciemne prostokąty
        // wchodzące od lewej krawędzi paska. Wcześniej pasek miał ciemne tło
        // i wszystkie klawisze rysowane osobno, przez co czytał się jako szara siatka.
        let blackKeys: Set = [1, 3, 6, 8, 10]
        let boardColor = Color(white: 0.94)
        let blackKey = Color(white: 0.12)
        let sepColor = Color(white: 0.55)
        let blackW = rect.width * 0.62

        // Rogi jak u pozostałych ramek w aplikacji; klawisze przycięte do tego kształtu.
        let corner = UIMetrics.buttonCornerRadius
        let frame = Path(roundedRect: rect, cornerRadius: corner)

        // Każdy półton zajmuje tyle samo miejsca; separator odejmujemy od pasa
        // (nie rysujemy go NA nim), więc wszystkie klawisze są równej wysokości.
        let keyPitch = rect.height / range
        let separator = min(0.3, max(0, keyPitch - 0.4) / 2)
        ctx.drawLayer { layer in
            layer.clip(to: frame)
            layer.fill(frame, with: .color(boardColor))
            for n in loNote ..< hiNote {
                let frac0 = CGFloat(n - loNote) / range
                let frac1 = CGFloat(n + 1 - loNote) / range
                let top = rect.minY + (1 - frac1) * rect.height + separator / 2
                let bottom = rect.minY + (1 - frac0) * rect.height - separator / 2
                let kH = max(0.3, bottom - top)

                if blackKeys.contains(n % 12) {
                    layer.fill(Path(CGRect(x: rect.minX, y: top, width: blackW, height: kH)),
                               with: .color(blackKey))
                } else if separator > 0 {
                    // Dwa białe klawisze obok siebie (E-F, B-C) rozdziela kreska.
                    var sep = Path()
                    sep.move(to: CGPoint(x: rect.minX, y: bottom + separator / 2))
                    sep.addLine(to: CGPoint(x: rect.maxX, y: bottom + separator / 2))
                    layer.stroke(sep, with: .color(sepColor), lineWidth: separator)
                }
            }
        }

        // Ramka paska — zawsze czarna (zoom wskazuje lupka, nie ramka)
        ctx.stroke(frame, with: .color(Color(white: 0.1)), lineWidth: 0.5)
    }

    /// Ikona lupki (kółko + ogon) — rysowana nad klawiaturą piano, zmiana skali przy kliknięciu.
    private func drawMagnifierIcon(_ ctx: GraphicsContext, in rect: CGRect, color _: Color) {
        // Lupka to PRZYCISK (klik cykluje skalę siatki), więc dostaje taką samą
        // ramkę i kolor jak każdy inny aktywny przycisk — sama ikona byłaby
        // nieodróżnialna od dekoracji.
        let button = rect.insetBy(dx: -0.6, dy: -0.6)
        PanelFace.raised(ctx, button, cornerRadius: UIMetrics.buttonCornerRadius,
                         fill: UIColor.buttonActive, shaded: panelShading)
        let color = Color.white

        // Mniejsze kółko i dłuższy uchwyt — przy proporcjach 1:1 ikona czytała się
        // jak litera „Q".
        let cx = rect.midX - rect.width * 0.06
        let cy = rect.midY - rect.height * 0.12
        let r = rect.width * 0.26
        // Kółko
        let circleRect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        ctx.stroke(Path(ellipseIn: circleRect), with: .color(color), lineWidth: 0.8)
        // Ogon (uchwyt)
        let hx0 = cx + r * 0.70
        let hy0 = cy + r * 0.70
        var handle = Path()
        handle.move(to: CGPoint(x: hx0, y: hy0))
        handle.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5))
        ctx.stroke(handle, with: .color(color), lineWidth: 0.8)
    }

    /// Skrót nazwy nuty MIDI: C4, D#3 itp.
    func midiNoteName(_ midiNote: Int, baseOctave _: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let semitone = midiNote % 12
        let octave = midiNote / 12 - 1
        return "\(names[semitone])\(octave)"
    }

    // MARK: - Envelope rendering helpers

    /// Dotychczasowa skala podglądu zachowana wyłącznie dla EnvADDSR, którego osobna
    /// klasa Clavii nie jest częścią tej poprawki.
    private func envNorm(_ envIdx: Int) -> CGFloat {
        CGFloat(sqrt(g2EnvTime(envIdx)))
    }

    /// Dodaje gładki odpowiednik ćwiartki elipsy rysowanej przez Graph ABC (ExpTo).
    /// Clavia próbkowała łuk w 20 krokach całkowitopikselowych; Canvas zachowuje tę samą
    /// styczność początku i końca, ale bez schodków widocznych po powiększeniu.
    private func addClaviaEnvelopeArc(_ path: inout Path, from start: CGPoint, to end: CGPoint,
                                      fastStart: Bool)
    {
        guard start.x != end.x, start.y != end.y else {
            path.addLine(to: end)
            return
        }

        let kappa: CGFloat = 0.552_284_749_8
        let dx = end.x - start.x
        let dy = end.y - start.y
        if fastStart {
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x, y: start.y + dy * kappa),
                          control2: CGPoint(x: end.x - dx * kappa, y: end.y))
        } else {
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + dx * kappa, y: start.y),
                          control2: CGPoint(x: end.x, y: end.y - dy * kappa))
        }
    }

    /// Back Line Color: pełna szerokość wewnętrznego ekranu, jak `BackLineTo`
    /// w klasach obwiedni oryginalnego edytora.
    private func drawEnvelopeBaseline(_ ctx: GraphicsContext, y: CGFloat, rect: CGRect) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: rect.minX, y: y))
        baseline.addLine(to: CGPoint(x: rect.maxX, y: y))
        ctx.stroke(baseline, with: .color(UIColor.graphBaseline.opacity(0.75)), lineWidth: 0.5)
    }

    private func strokeGraphPath(_ ctx: GraphicsContext, _ path: Path,
                                 color: Color = UIColor.graphLine,
                                 lineWidth: CGFloat = UIMetrics.graphLineWidth)
    {
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
    }

    /// Wspólne zielone wypełnienie charakterystyk filtrów. Clavia zamyka obszar
    /// od końców krzywej do dolnej krawędzi ekranu (`FillUnderGraph`).
    private func fillUnderGraph(_ ctx: GraphicsContext, path: Path,
                                first: CGPoint?, last: CGPoint?, rect: CGRect)
    {
        guard let first, let last else { return }
        var fill = path
        fill.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        fill.addLine(to: CGPoint(x: first.x, y: rect.maxY))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(UIColor.graphLine.opacity(0.30)))
    }

    /// Obrysowuje ścieżkę, a potem DOKŁADA po jej odcinkach poziomych cienką (pół
    /// grubości) kreskę w ich osi.
    ///
    /// Przy małym powiększeniu canvasu krzywa ma ~1,3 piksela urządzenia: idealnie
    /// poziomy odcinek trafia wtedy POMIĘDZY rzędy pikseli i antyaliasing rozkłada go
    /// na dwa rzędy po ~50 % krycia, przez co czyta się jako bledszy od pionu czy skosu
    /// (te same piksele trafiają pełną szerokością). Dokładka leży w OSI odcinka, więc
    /// tam, gdzie linia jest już kryjąca — czyli przy każdym większym powiększeniu —
    /// nie zmienia nic (zmierzone: identyczna suma krycia przy zoomie 2,6 i 5,0),
    /// a przy zoomie 1,0 podnosi szczyt krycia ze 129 do 152 na 199 pionu. Pełna
    /// grubość dokładki przeciążałaby poziomy przy dużym powiększeniu (+20 % „farby"
    /// względem pionów), stąd połowa.
    private func strokeEvenly(_ ctx: GraphicsContext, _ path: Path,
                              color: Color, lineWidth: CGFloat)
    {
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

        var horizontals = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // Closure w zmiennej, nie trailing closure: `Path` nie jest `Sequence`, a
        // swiftformat zamienia `path.forEach { … }` na pętlę `for … in path`.
        let collectHorizontal: (Path.Element) -> Void = { element in
            switch element {
            case let .move(to: point):
                current = point
                subpathStart = point
            case let .line(to: point):
                if abs(point.y - current.y) < 0.01, abs(point.x - current.x) > 0.01 {
                    horizontals.move(to: current)
                    horizontals.addLine(to: point)
                }
                current = point
            case let .quadCurve(to: point, control: _):
                current = point
            case let .curve(to: point, control1: _, control2: _):
                current = point
            case .closeSubpath:
                current = subpathStart
            }
        }
        path.forEach(collectHorizontal)
        guard !horizontals.isEmpty else { return }
        // Zakończenia `.butt` — dokładka ma leżeć dokładnie na oryginale, nie wystawać
        // poza narożniki (tam grubość i tak daje już `.round` z pierwszego obrysu).
        ctx.stroke(horizontals, with: .color(color),
                   style: StrokeStyle(lineWidth: lineWidth / 2, lineCap: .butt))
    }

    /// Pozioma linia odniesienia (poziom zera) na ekranie fali — oryginał
    /// (Waveform Graph ABC (DrawBackLine)) rysuje ją zawsze PRZED samą falą, dla
    /// każdego ekranu tej rodziny (LfoB/LfoShpA). Ten sam wygląd co linia bazowa
    /// `claviaDoubleSaw` używana gdzie indziej w tym pliku — stały, przygaszony szary,
    /// nie kolor samej fali.
    ///
    /// WYSOKOŚĆ zależy od ustawienia Output type (pole trybu w oryginale).
    /// `DrawBackLine` testuje bitmaskę `1 << mode`:
    ///   `& 0x03` → tryby 0,1 (Pos, PosInv)    → `y = height-2` (DÓŁ ekranu)
    ///   `& 0x0c` → tryby 2,3 (Neg, NegInv)    → `y = 1`        (GÓRA ekranu)
    ///   `& 0x30` → tryby 4,5 (Bip, BipInv)    → `y = (h-1)/2`  (ŚRODEK)
    /// Numeracja trybów wg g2ools `PosNegInvBipInv`.
    private func drawGraphBaseline(_ ctx: GraphicsContext, rect: CGRect, outputType: Int = 4) {
        let y: CGFloat = switch outputType {
        case 0, 1: rect.maxY // Pos / PosInv
        case 2, 3: rect.minY // Neg / NegInv
        case 4, 5: rect.midY // Bip / BipInv
        default: rect.minY
        }
        var line = Path()
        line.move(to: CGPoint(x: rect.minX, y: y))
        line.addLine(to: CGPoint(x: rect.maxX, y: y))
        ctx.stroke(line, with: .color(UIColor.graphBaseline.opacity(0.75)), lineWidth: 0.5)
    }

    /// LFO rysuje skraje przebiegu z zapasem połowy zielonego stroke'u. Przy baseline
    /// na górze/dole dokładamy połowę jego grubości, żeby oba obrysy tylko się stykały.
    private func graphSignalRectAvoidingEdgeBaseline(rect: CGRect, outputType: Int) -> CGRect {
        let baselineHalfWidth: CGFloat = 0.25
        switch outputType % 6 {
        case 0, 1: // Pos / PosInv — baseline na dole
            return CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width, height: max(0, rect.height - baselineHalfWidth))
        case 2, 3: // Neg / NegInv — baseline u góry
            return CGRect(x: rect.minX, y: rect.minY + baselineHalfWidth,
                          width: rect.width, height: max(0, rect.height - baselineHalfWidth))
        default: // Bip / BipInv — linia zera przecina przebieg w środku
            return rect
        }
    }

    // MARK: - Tuned Noise spectrum

    /// GraphFunc 43 (Tuned Noise Graph) — widmo wąskopasmowego szumu.
    /// Parametr Width rozsuwa oba końce pasma równomiernie od środka, zachowując
    /// wąski, widoczny pik przy wartości zero. Kształt odpowiada dwóm
    /// symetrycznym krzywym Béziera i wypełnieniu Graph ABC (FillUnderGraph).
    private func drawTunedNoiseSpectrum(_ ctx: GraphicsContext, width: Int, rect: CGRect) {
        let normalizedWidth = CGFloat(min(127, max(0, width))) / 127.0
        let baselineY = rect.maxY - 0.5
        let peakY = rect.minY + 0.5
        let maxHalfWidth = max(0.8, (rect.width - 1.0) * 0.5)
        let halfWidth = 0.8 + normalizedWidth * max(0, maxHalfWidth - 0.8)
        let centerX = rect.midX
        let leftX = centerX - halfWidth
        let rightX = centerX + halfWidth

        var path = Path()
        path.move(to: CGPoint(x: leftX, y: baselineY))
        path.addCurve(to: CGPoint(x: centerX, y: peakY),
                      control1: CGPoint(x: leftX + halfWidth * 0.25, y: baselineY),
                      control2: CGPoint(x: centerX - halfWidth * 0.25, y: peakY))
        path.addCurve(to: CGPoint(x: rightX, y: baselineY),
                      control1: CGPoint(x: centerX + halfWidth * 0.25, y: peakY),
                      control2: CGPoint(x: rightX - halfWidth * 0.25, y: baselineY))

        var fill = path
        fill.addLine(to: CGPoint(x: leftX, y: baselineY))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(UIColor.graphLine.opacity(0.20)))
        strokeGraphPath(ctx, path)

        var baseline = Path()
        baseline.move(to: CGPoint(x: rect.minX, y: baselineY))
        baseline.addLine(to: CGPoint(x: rect.maxX, y: baselineY))
        ctx.stroke(baseline, with: .color(UIColor.graphBaseline.opacity(0.75)), lineWidth: 0.5)
    }

    // Nord G2 Envelope Shape values:
    //   0 = LinLin — atak liniowy, decay liniowy → trójkąt
    //   1 = LogExp — atak ExpD (gwałtowny start), decay ExpD → kopuła
    //   2 = LinExp — atak liniowy, decay ExpD → rampa + krzywa
    //   3 = ExpExp — atak ExpU (wolny start, strzela u szczytu), decay ExpD → szpiczasta Λ

    private func envAttack(_ path: inout Path, shapeType: Int,
                           x0: CGFloat, yBase: CGFloat, xA: CGFloat, yTop: CGFloat)
    {
        switch shapeType {
        case 1: // LogExp: Exp D — gwałtowne wzniesienie, wypłaszczenie na szczycie
            addClaviaEnvelopeArc(&path, from: CGPoint(x: x0, y: yBase),
                                 to: CGPoint(x: xA, y: yTop), fastStart: true)
        case 3: // ExpExp: Exp U — wolny start, gwałtowne przyspieszenie do szczytu
            addClaviaEnvelopeArc(&path, from: CGPoint(x: x0, y: yBase),
                                 to: CGPoint(x: xA, y: yTop), fastStart: false)
        default: // 0 (LinLin), 2 (LinExp): liniowy atak
            path.addLine(to: CGPoint(x: xA, y: yTop))
        }
    }

    private func envDecay(_ path: inout Path, shapeType: Int,
                          xA: CGFloat, yTop: CGFloat, xD: CGFloat, ySust: CGFloat)
    {
        switch shapeType {
        case 0: // LinLin: liniowy
            path.addLine(to: CGPoint(x: xD, y: ySust))
        default: // 1,2,3: Exp D — gwałtowny spadek ze szczytu, wypłaszcza się na sustain
            addClaviaEnvelopeArc(&path, from: CGPoint(x: xA, y: yTop),
                                 to: CGPoint(x: xD, y: ySust), fastStart: true)
        }
    }

    private func envRelease(_ path: inout Path, shapeType: Int,
                            xS: CGFloat, ySust: CGFloat, xR: CGFloat, yBase: CGFloat)
    {
        switch shapeType {
        case 0: // LinLin: liniowy
            path.addLine(to: CGPoint(x: xR, y: yBase))
        default: // 1,2,3: Exp D — gwałtowny spadek z sustain, wypłaszcza się na 0
            addClaviaEnvelopeArc(&path, from: CGPoint(x: xS, y: ySust),
                                 to: CGPoint(x: xR, y: yBase), fastStart: true)
        }
    }

    /// OutputType: kierunek krzywej (yStart→yPeak) i linia bazowa / zamknięcie wypełnienia (yFill).
    /// Na górnej/dolnej krawędzi środek zielonej kreski jest odsunięty o sumę
    /// połówek obu stroke'ów: kreski stykają się krawędziami, ale się nie zasłaniają.
    /// Wspólne dla wszystkich obwiedni z Output type (ADSR, EnvMulti):
    /// Pos(0):    bot→top, yFill=bot   | PosInv(1): top→bot, yFill=bot (duże wypełnienie przy spoczynku)
    /// Neg(2):    bot→top, yFill=top   | NegInv(3): top→bot, yFill=top
    /// Bip(4):    środek→top, yFill=środek  | BipInv(5): środek→bot, yFill=środek
    /// (Bip/BipInv: linia odniesienia i spoczynek koperty w połowie wysokości ekranu —
    /// zgodne ze zrzutami użytkownika z prawdziwego edytora Clavii, poprzednia wersja
    /// 1/6 wysokości nie miała źródła w oryginale).
    private func envOutputLevels(outputType: Int, top: CGFloat, bot: CGFloat, h: CGFloat)
        -> (start: CGFloat, peak: CGFloat, fill: CGFloat)
    {
        let edgeOffset = UIMetrics.graphLineWidth / 2.0 + 0.25 // baseline ma 0,5 pt
        let signalTop = min(bot, top + edgeOffset)
        let signalBottom = max(top, bot - edgeOffset)

        switch outputType % 6 {
        case 1: return (top, signalBottom, bot) // PosInv
        case 2: return (bot, signalTop, top) // Neg
        case 3: return (signalTop, bot, top) // NegInv
        case 4: // Bip
            let mid = top + h / 2.0
            return (mid, top, mid)
        case 5: // BipInv
            let mid = top + h / 2.0
            return (mid, bot, mid)
        default: return (signalBottom, top, bot) // Pos
        }
    }

    private func drawEnvADSR(_ ctx: GraphicsContext,
                             attack: Int, decay: Int, sustain: Int, release: Int,
                             shape: Int, outputType: Int = 0, rect: CGRect)
    {
        // ADSR Graph ABC skaluje surowe A/D/R przez stałą 461.0. Nie używa czasu
        // wyświetlanego w sekundach ani minimalnej szerokości segmentu; dlatego A=0
        // musi dawać dokładnie pionową linię w x0.
        let x0 = rect.minX + 0.5
        let xR = rect.maxX
        let bot = rect.maxY - 0.5
        let top = rect.minY + 0.5
        let h = bot - top

        let (yStart, yPeak, yFill) = envOutputLevels(outputType: outputType, top: top, bot: bot, h: h)

        let sL = CGFloat(sustain) / 127.0
        let ySust = yStart + sL * (yPeak - yStart)

        let timeScale = max(0, xR - x0) / 461.0
        let a = CGFloat(min(127, max(0, attack)))
        let d = CGFloat(min(127, max(0, decay)))
        let r = CGFloat(min(127, max(0, release)))
        let xA = x0 + a * timeScale
        let xD = xA + d * timeScale
        let xS = xR - r * timeScale
        let st = (shape + 1) % 4

        var path = Path()
        path.move(to: CGPoint(x: x0, y: yStart))
        envAttack(&path, shapeType: st, x0: x0, yBase: yStart, xA: xA, yTop: yPeak)
        envDecay(&path, shapeType: st, xA: xA, yTop: yPeak, xD: xD, ySust: ySust)
        path.addLine(to: CGPoint(x: xS, y: ySust))
        envRelease(&path, shapeType: st, xS: xS, ySust: ySust, xR: xR, yBase: yStart)

        // Wypełnienie między krzywą a yFill
        var fillPath = path
        fillPath.addLine(to: CGPoint(x: xR, y: yFill))
        fillPath.addLine(to: CGPoint(x: x0, y: yFill))
        fillPath.closeSubpath()
        ctx.fill(fillPath, with: .color(UIColor.graphLine.opacity(0.20)))

        strokeGraphPath(ctx, path)

        // Odcinek sustain-hold (xD→xS na poziomie ySust) — w oryginale Clavii rysowany
        // osobnym kolorem (Sustain Color, żółty) niż reszta krzywej (zielona),
        // nakładka na już narysowaną zieloną ścieżkę pokazuje poziom Sustain.
        var sustainSegment = Path()
        sustainSegment.move(to: CGPoint(x: xD, y: ySust))
        sustainSegment.addLine(to: CGPoint(x: xS, y: ySust))
        strokeGraphPath(ctx, sustainSegment, color: UIColor.graphSustain)

        drawEnvelopeBaseline(ctx, y: yFill, rect: rect)
    }

    private func drawEnvADR(_ ctx: GraphicsContext,
                            attack: Int, release: Int, shape: Int, releaseMode: Bool,
                            outputType: Int = 0, rect: CGRect)
    {
        // AD Graph ABC dla EnvADR rezerwuje dwa pełne zakresy 0...127 (A + D/R).
        // Surowe zero nie dostaje sztucznej szerokości, więc atak zaczyna się pionowo.
        let x0 = rect.minX + 0.5
        let xEnd = rect.maxX
        let bot = rect.maxY - 0.5
        let top = rect.minY + 0.5
        let h = bot - top
        let (yBase, yTop, yFill) = envOutputLevels(outputType: outputType, top: top, bot: bot, h: h)

        let timeScale = max(0, xEnd - x0) / (2.0 * 127.0)
        let a = CGFloat(min(127, max(0, attack)))
        let r = CGFloat(min(127, max(0, release)))
        let xA = x0 + a * timeScale
        let xReleaseStart = releaseMode ? max(xA, xEnd - r * timeScale) : xA
        let xR = releaseMode ? xEnd : min(xEnd, xA + r * timeScale)
        let st = (shape + 1) % 4

        var path = Path()
        path.move(to: CGPoint(x: x0, y: yBase))
        envAttack(&path, shapeType: st, x0: x0, yBase: yBase, xA: xA, yTop: yTop)
        if releaseMode {
            path.addLine(to: CGPoint(x: xReleaseStart, y: yTop))
        }
        envRelease(&path, shapeType: st, xS: xReleaseStart, ySust: yTop,
                   xR: xR, yBase: yBase)
        // Stała oś dwóch zakresów zwykle zostawia miejsce po opadzie — dociągnij
        // poziom spoczynku do prawej krawędzi, jak `SingleLineTo` w Clavii.
        if xR < xEnd {
            path.addLine(to: CGPoint(x: xEnd, y: yBase))
        }

        var fillPath = path
        fillPath.addLine(to: CGPoint(x: xEnd, y: yFill))
        fillPath.addLine(to: CGPoint(x: x0, y: yFill))
        fillPath.closeSubpath()
        ctx.fill(fillPath, with: .color(UIColor.graphLine.opacity(0.20)))

        strokeGraphPath(ctx, path)

        if releaseMode, xReleaseStart > xA {
            var sustainPath = Path()
            sustainPath.move(to: CGPoint(x: xA, y: yTop))
            sustainPath.addLine(to: CGPoint(x: xReleaseStart, y: yTop))
            strokeGraphPath(ctx, sustainPath, color: UIColor.graphSustain)
        }

        drawEnvelopeBaseline(ctx, y: yFill, rect: rect)
    }

    private func drawEnvAHD(_ ctx: GraphicsContext,
                            attack: Int, hold: Int, decay: Int, shape: Int,
                            outputType: Int = 0, dynamicTotal: Bool = false, rect: CGRect)
    {
        // AHD Graph ABC: EnvAHD/ModAHD mają trzy pełne zakresy czasu; Hold-Env
        // dziedziczy tę samą klasę z mnożnikiem jednego zakresu.
        let x0 = rect.minX + 0.5
        let xEnd = rect.maxX
        let bot = rect.maxY - 0.5
        let top = rect.minY + 0.5
        let h = bot - top
        let (yBase, yTop, yFill) = envOutputLevels(outputType: outputType, top: top, bot: bot, h: h)

        let rangeCount: CGFloat = dynamicTotal ? 1.0 : 3.0
        let timeScale = max(0, xEnd - x0) / (rangeCount * 127.0)
        let a = CGFloat(min(127, max(0, attack)))
        let holdValue = CGFloat(min(127, max(0, hold)))
        let d = CGFloat(min(127, max(0, decay)))
        let xA = x0 + a * timeScale
        let xH = xA + holdValue * timeScale
        let xD = min(xEnd, xH + d * timeScale)
        let st = (shape + 1) % 4

        var path = Path()
        path.move(to: CGPoint(x: x0, y: yBase))
        envAttack(&path, shapeType: st, x0: x0, yBase: yBase, xA: xA, yTop: yTop)
        path.addLine(to: CGPoint(x: xH, y: yTop))
        envDecay(&path, shapeType: st, xA: xH, yTop: yTop, xD: xD, ySust: yBase)
        if xD < xEnd {
            path.addLine(to: CGPoint(x: xEnd, y: yBase))
        }

        var fillPath = path
        fillPath.addLine(to: CGPoint(x: xEnd, y: yFill))
        fillPath.addLine(to: CGPoint(x: x0, y: yFill))
        fillPath.closeSubpath()
        ctx.fill(fillPath, with: .color(UIColor.graphLine.opacity(0.20)))

        strokeGraphPath(ctx, path)

        drawEnvelopeBaseline(ctx, y: yFill, rect: rect)
    }

    private func drawEnvD(_ ctx: GraphicsContext, decay: Int, outputType: Int = 0, rect: CGRect) {
        let x0 = rect.minX + 0.5
        let xEnd = rect.maxX
        let bot = rect.maxY - 0.5
        let top = rect.minY + 0.5
        let h = bot - top
        let (yBase, yTop, yFill) = envOutputLevels(outputType: outputType, top: top, bot: bot, h: h)

        var path = Path()
        path.move(to: CGPoint(x: x0, y: yBase))
        // EnvD nie ma Attacku — natychmiastowy pionowy skok do szczytu, potem
        // wykładniczy spadek (brakowało tej pierwszej kreski w poprzedniej wersji,
        // ścieżka zaczynała się już na szczycie).
        path.addLine(to: CGPoint(x: x0, y: yTop))
        // D Env Graph używa AD Graph ABC z jednym zakresem 0...127. Po opadzie
        // rysuje poziom spoczynku do końca ekranu — sam łuk nie może zajmować całej osi.
        let decayValue = CGFloat(min(127, max(0, decay)))
        let xD = x0 + max(0, xEnd - x0) * decayValue / 127.0
        addClaviaEnvelopeArc(&path, from: CGPoint(x: x0, y: yTop),
                             to: CGPoint(x: xD, y: yBase), fastStart: true)
        if xD < xEnd {
            path.addLine(to: CGPoint(x: xEnd, y: yBase))
        }

        var fillPath = path
        fillPath.addLine(to: CGPoint(x: xEnd, y: yFill))
        fillPath.addLine(to: CGPoint(x: x0, y: yFill))
        fillPath.closeSubpath()
        ctx.fill(fillPath, with: .color(UIColor.graphLine.opacity(0.20)))

        strokeGraphPath(ctx, path)

        drawEnvelopeBaseline(ctx, y: yFill, rect: rect)
    }

    /// GraphFunc 17 (Multi Env Graph, moduł EnvMulti) i GraphFunc 23
    /// (ADBDSR Env Graph, moduł EnvADDSR) — obwiednia N-segmentowa Ln/Tn z
    /// wybieranym punktem podtrzymania. Czas segmentów liczony jak w drawEnvADSR
    /// (`envNorm`, InfoFunc:28 na gałkach Tn w BVerhue), poziomy liniowo 0...127
    /// (InfoFunc:16, jak Sustain w EnvADSR) — NIE skala wykładnicza DX7 z
    /// `drawDXEnvelope` (ta obsługuje inny, niepowiązany moduł Operator z
    /// poziomami 0...99). `sustainStage` to indeks segmentu, na którego poziomie
    /// wstawić żółty odcinek podtrzymania; `nil` = bez podtrzymania (EnvMulti
    /// "Trg" — jedyny wariant z opcją wyłączenia; EnvADDSR "L1,L2" zawsze ma
    /// aktywne podtrzymanie, obie wartości poprawne). `release` to opcjonalny
    /// czas powrotu do poziomu spoczynku na samym końcu (EnvADDSR ma go, EnvMulti
    /// nie — L4 jest już poziomem końcowym). Minimalna szerokość 1,5pt pozostaje
    /// tylko w starszej gałęzi EnvADDSR; EnvMulti korzysta z surowej osi Clavii.
    ///
    /// EnvMulti korzysta z dokładnej geometrii Multi Env Graph (Draw): surowe czasy
    /// są skalowane przez stałą 588, a wolne miejsce osi zostaje wstawione po wybranym
    /// poziomie sustain. Dzięki temu T4 zachowuje własną szerokość i końcowy opad nie
    /// zapada się w pion przy prawej krawędzi. EnvADDSR ma osobną klasę Clavii i na
    /// razie zachowuje dotychczasową, wydzieloną geometrię.
    private func drawEnvMulti(_ ctx: GraphicsContext,
                              levels: [Int], times: [Int], sustainStage: Int?, release: Int?,
                              shape: Int, outputType: Int, rect: CGRect)
    {
        guard levels.count == times.count, !levels.isEmpty else { return }

        if release == nil, levels.count == 4 {
            drawClaviaMultiEnvelope(ctx, levels: levels, times: times,
                                    sustainStage: sustainStage, shape: shape,
                                    outputType: outputType, rect: rect)
            return
        }

        let x0 = rect.minX + 0.5
        let xR = rect.maxX
        let bot = rect.maxY - 0.5
        let top = rect.minY + 0.5
        let h = bot - top
        let (yStart, yPeak, yFill) = envOutputLevels(outputType: outputType, top: top, bot: bot, h: h)

        func levelY(_ level: Int) -> CGFloat {
            yStart + CGFloat(min(127, max(0, level))) / 127.0 * (yPeak - yStart)
        }

        let minSegPt: CGFloat = 1.5
        let tN = times.map(envNorm)
        let maxT = envNorm(127)
        let hasSustain = sustainStage.map { levels.indices.contains($0) } ?? false
        let rN = release.map(envNorm) ?? 0
        let total = tN.reduce(0, +) + (hasSustain ? maxT : 0) + rN
        guard total > 0 else { return }
        let w0 = rect.width / total
        // Release dostaje tę samą minimalną szerokość co w drawEnvADSR — bez tego
        // krótki czas (np. EnvADDSR domyślne R=5,5ms) znikał za prawą krawędzią,
        // bo `w0*rN` wychodziło poniżej 1 punktu.
        let rWidth = release != nil ? max(w0 * rN, minSegPt) : 0
        let xBodyEnd = xR - rWidth
        let bodyTotal = tN.reduce(0, +) + (hasSustain ? maxT : 0)
        let w = bodyTotal > 0 ? max(0, xBodyEnd - x0) / bodyTotal : 0
        let st = (shape + 1) % 4

        var path = Path()
        path.move(to: CGPoint(x: x0, y: yStart))

        var x = x0
        var yPrev = yStart
        var sustainSegment: (x0: CGFloat, x1: CGFloat, y: CGFloat)?
        for stage in levels.indices {
            let xNext = x + w * tN[stage]
            let yNext = levelY(levels[stage])
            if yNext < yPrev {
                envAttack(&path, shapeType: st, x0: x, yBase: yPrev, xA: xNext, yTop: yNext)
            } else {
                envDecay(&path, shapeType: st, xA: x, yTop: yPrev, xD: xNext, ySust: yNext)
            }
            x = xNext
            yPrev = yNext
            if hasSustain, stage == sustainStage {
                let xHoldEnd = x + w * maxT
                path.addLine(to: CGPoint(x: xHoldEnd, y: yPrev))
                sustainSegment = (x, xHoldEnd, yPrev)
                x = xHoldEnd
            }
        }
        if x < xBodyEnd {
            path.addLine(to: CGPoint(x: xBodyEnd, y: yPrev))
            x = xBodyEnd
        }
        if release != nil {
            envRelease(&path, shapeType: st, xS: x, ySust: yPrev, xR: xR, yBase: yStart)
        }

        var fillPath = path
        fillPath.addLine(to: CGPoint(x: xR, y: yFill))
        fillPath.addLine(to: CGPoint(x: x0, y: yFill))
        fillPath.closeSubpath()
        ctx.fill(fillPath, with: .color(UIColor.graphLine.opacity(0.20)))

        strokeGraphPath(ctx, path)

        if let seg = sustainSegment {
            var sustainPath = Path()
            sustainPath.move(to: CGPoint(x: seg.x0, y: seg.y))
            sustainPath.addLine(to: CGPoint(x: seg.x1, y: seg.y))
            strokeGraphPath(ctx, sustainPath, color: UIColor.graphSustain)
        }

        drawEnvelopeBaseline(ctx, y: yFill, rect: rect)
    }

    /// Wierny port osi X z Multi Env Graph (Draw) (skala 588.0).
    private func drawClaviaMultiEnvelope(_ ctx: GraphicsContext,
                                         levels: [Int], times: [Int], sustainStage: Int?,
                                         shape: Int, outputType: Int, rect: CGRect)
    {
        let x0 = rect.minX + 0.5
        let xR = rect.maxX
        let bot = rect.maxY - 0.5
        let top = rect.minY + 0.5
        let h = bot - top
        let (yStart, yPeak, yFill) = envOutputLevels(outputType: outputType, top: top, bot: bot, h: h)

        func levelY(_ level: Int) -> CGFloat {
            yStart + CGFloat(min(127, max(0, level))) / 127.0 * (yPeak - yStart)
        }

        let rawTimes = times.map { CGFloat(min(127, max(0, $0))) }
        let pathWidth = max(0, xR - x0)
        // SetSize(84), Shrink(1): naturalne segmenty zajmują 74 z 79 pikseli osi;
        // pozostałe 5 pikseli również trafia do przerwy sustain.
        let timeScale = pathWidth * (74.0 / 79.0) / 588.0
        let naturalWidth = rawTimes.reduce(0, +) * timeScale
        let sustainPadding = max(0, pathWidth - naturalWidth)
        let st = (shape + 1) % 4

        var path = Path()
        path.move(to: CGPoint(x: x0, y: yStart))

        var x = x0
        var yPrevious = yStart
        var sustainSegment: (x0: CGFloat, x1: CGFloat, y: CGFloat)?
        for stage in levels.indices {
            let xNext = min(xR, x + rawTimes[stage] * timeScale)
            let yNext = levelY(levels[stage])
            if yNext < yPrevious {
                envAttack(&path, shapeType: st, x0: x, yBase: yPrevious, xA: xNext, yTop: yNext)
            } else {
                envDecay(&path, shapeType: st, xA: x, yTop: yPrevious, xD: xNext, ySust: yNext)
            }
            x = xNext
            yPrevious = yNext

            if sustainStage == stage {
                let holdEnd = min(xR, x + sustainPadding)
                path.addLine(to: CGPoint(x: holdEnd, y: yPrevious))
                sustainSegment = (x, holdEnd, yPrevious)
                x = holdEnd
            }
        }

        if x < xR {
            path.addLine(to: CGPoint(x: xR, y: yPrevious))
        }

        var fillPath = path
        fillPath.addLine(to: CGPoint(x: xR, y: yFill))
        fillPath.addLine(to: CGPoint(x: x0, y: yFill))
        fillPath.closeSubpath()
        ctx.fill(fillPath, with: .color(UIColor.graphLine.opacity(0.20)))

        strokeGraphPath(ctx, path)

        if let segment = sustainSegment {
            var sustainPath = Path()
            sustainPath.move(to: CGPoint(x: segment.x0, y: segment.y))
            sustainPath.addLine(to: CGPoint(x: segment.x1, y: segment.y))
            strokeGraphPath(ctx, sustainPath, color: UIColor.graphSustain)
        }

        drawEnvelopeBaseline(ctx, y: yFill, rect: rect)
    }

    // MARK: - Operator graphs

    /// GraphFunc 29 (DX Env Graph) — obwiednia DX z czterema parami Rate/Level.
    /// R1–R3 prowadzą kolejno do L1–L3, L3 jest utrzymywany, a R4 kończy przebieg
    /// przejściem do L4. Geometria zgodna z oryginałem
    /// (DX Env Graph (Draw)) — liczona w NATYWNYCH pikselach Gen1 (nie w pt),
    /// ze stałymi oryginału (nie zgadywanymi): 2.0, 1.0, 480.0, 4.0, 100.0, 99.0.
    /// Kluczowe odkrycie: poziom (Level 0...99) NIE jest liniowy na osi Y — mapuje się
    /// przez krzywą wykładniczą `1.0471^poziom` (styl DX7 Output Level: podwojenie co
    /// ~15 kroków, poziom=0 → 0), stąd „ostry szpic" przy niskich poziomach i spłaszczenie
    /// przy wysokich — zrzut użytkownika z L1=0,L2=99,L3=50 (wszystkie Rate=0) potwierdził
    /// to jednoznacznie (wąski szpic mimo najwolniejszego Rate i największego dystansu,
    /// co przeczyło poprzedniej liniowej wersji).
    private func drawDXEnvelope(_ ctx: GraphicsContext, rates: [Int], levels: [Int], rect: CGRect) {
        guard rates.count == 4, levels.count == 4 else { return }

        let scale = PatchLayout.bverhuePixelScale
        let widthPx = rect.width / scale
        let heightPx = rect.height / scale
        guard widthPx > 10, heightPx > 10 else { return }

        // Shrink(rect,1) — początek przesunięty o +1 Gen1px,
        // szerokość/wysokość zmniejszone o 2 (po 1 z każdej strony).
        let shrunkW = widthPx - 2.0
        let shrunkH = heightPx - 2.0
        let xRight = shrunkW - 1.0
        let yBaseline = shrunkH - 2.0 - 1.0
        let xScale = (xRight - 2.0) / 480.0
        let yScale = (yBaseline - 4.0) / 100.0

        func levelPower(_ level: Int) -> CGFloat {
            let l = min(99, max(0, level))
            return l == 0 ? 0 : CGFloat(pow(1.0471, Double(l)))
        }
        func yPx(_ level: Int) -> CGFloat {
            yBaseline - levelPower(level) * yScale
        }
        func durationPx(_ rate: Int, from: Int, to: Int) -> CGFloat {
            // 99.0 — dzielnik dystansu, ten sam co w Operator BrPoint
            CGFloat(abs(from - to)) / 99.0 * CGFloat(99 - min(99, max(0, rate))) * xScale
        }
        func toPt(_ xPx: CGFloat, _ yPx: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (1 + xPx) * scale, y: rect.minY + (1 + yPx) * scale)
        }

        // Węzły łamanej w Gen1px — X z dokładnego wzoru czasu trwania, Y z krzywej
        // wykładniczej poziomu (patrz wyżej).
        var nodes: [CGPoint] = []
        var xPx: CGFloat = 2.0 // początkowy odstęp od lewej
        nodes.append(CGPoint(x: xPx, y: yPx(levels[3])))
        xPx += durationPx(rates[0], from: levels[3], to: levels[0])
        nodes.append(CGPoint(x: xPx, y: yPx(levels[0])))
        xPx += durationPx(rates[1], from: levels[0], to: levels[1])
        nodes.append(CGPoint(x: xPx, y: yPx(levels[1])))
        xPx += durationPx(rates[2], from: levels[1], to: levels[2])
        nodes.append(CGPoint(x: xPx, y: yPx(levels[2])))
        // Release liczony wstecz od prawej krawędzi, jak w oryginale — sustain
        // wypełnia resztę szerokości płaską linią na poziomie L3.
        let releaseStartXPx = max(xPx, xRight - durationPx(rates[3], from: levels[2], to: levels[3]))
        nodes.append(CGPoint(x: releaseStartXPx, y: yPx(levels[2])))
        nodes.append(CGPoint(x: xRight, y: yPx(levels[3])))

        // Każdy odcinek to krzywa Béziera z DWOMA niezależnymi stycznymi. Użytkownik
        // narysował na renderze dokładnie czego brakowało: SZCZYTY (lokalne maksimum
        // poziomu) mają zostać OSTRE (dwie różne, PIONOWE styczne spotykają się pod
        // kątem), DOLINY gładkie (POZIOME styczne po obu stronach), a wznoszenie ORAZ
        // opadanie mają same w sobie być łukiem, nie linią prostą. Pierwsza „czysto
        // pozioma" wersja (sterowanie tylko przez szczyt/dolinę, końce zawsze płaskie)
        // dawała zbyt płaski, prawie kwadratowy kształt na końcach linii („łuk za
        // płaski") — końce całej obwiedni (start/koniec) traktowane są NEUTRALNIE:
        // styczna wzdłuż prostej łączącej punkty (1/3 reguła Béziera), nie sztucznie
        // spłaszczona ani stroma. Odcinek sustain (stały poziom L3) zostaje prostą linią.
        let n = nodes.count
        func isPeak(_ i: Int) -> Bool {
            guard i > 0, i < n - 1 else { return false }
            return nodes[i].y < nodes[i - 1].y && nodes[i].y < nodes[i + 1].y
        }
        // Punkty kontrolne jako UŁAMEK (nie cały „róg") odległości w danym kierunku —
        // pełny róg (p1.x,p0.y) dawał przesadny hak przy skrajnie szerokich-a-płytkich
        // odcinkach (szerokość >> wysokość w tym wykresie), zgłoszone jako „łuk za
        // płaski". Końce całej obwiedni (start/koniec) traktowane tak samo jak
        // dolina/plateau (płaska styczna) — użytkownik: „na początku ma być wklęsły
        // łuk [na odcinku] wznoszącym" — płaski start + przyspieszający wznios do
        // szczytu to właśnie krzywa wklęsła (nie neutralna linia prosta).
        let steepFrac: CGFloat = 0.6
        let flatFrac: CGFloat = 0.6
        var path = Path()
        path.move(to: toPt(nodes[0].x, nodes[0].y))
        for i in 0 ..< n - 1 {
            let p0 = nodes[i]
            let p1 = nodes[i + 1]
            if p0.y == p1.y {
                path.addLine(to: toPt(p1.x, p1.y))
                continue
            }
            let c1: CGPoint = isPeak(i)
                ? CGPoint(x: p0.x, y: p0.y + (p1.y - p0.y) * steepFrac) // stroma (pionowa) styczna przy szczycie
                : CGPoint(x: p0.x + (p1.x - p0.x) * flatFrac, y: p0.y) // płaska (pozioma) — dolina/plateau/koniec
            let c2: CGPoint = isPeak(i + 1)
                ? CGPoint(x: p1.x, y: p1.y - (p1.y - p0.y) * steepFrac)
                : CGPoint(x: p1.x - (p1.x - p0.x) * flatFrac, y: p1.y)
            path.addCurve(to: toPt(p1.x, p1.y), control1: toPt(c1.x, c1.y), control2: toPt(c2.x, c2.y))
        }

        let bottom = toPt(0, 0).y + shrunkH * scale
        var fill = path
        fill.addLine(to: CGPoint(x: toPt(xRight, 0).x, y: bottom))
        fill.addLine(to: CGPoint(x: toPt(0, 0).x, y: bottom))
        fill.closeSubpath()

        var clippedCtx = ctx
        clippedCtx.clip(to: Path(rect))
        clippedCtx.fill(fill, with: .color(UIColor.graphLine.opacity(0.20)))
        strokeGraphPath(clippedCtx, path)

        var baseline = Path()
        baseline.move(to: CGPoint(x: toPt(0, 0).x, y: bottom))
        baseline.addLine(to: CGPoint(x: toPt(xRight, 0).x, y: bottom))
        ctx.stroke(baseline, with: .color(UIColor.graphBaseline.opacity(0.75)), lineWidth: 0.5)
    }

    /// GraphFunc 41 (Operator Graph) — krzywa wokół Breakpointu. Wartości selectorów
    /// odpowiadają kolejno opisom przycisków: -Lin, -Exp, +Exp, +Lin.
    private func drawOperatorBreakpointCurve(_ ctx: GraphicsContext,
                                             breakpoint: Int, leftType: Int, leftDepth: Int,
                                             rightType: Int, rightDepth: Int, rect: CGRect)
    {
        // Oryginał (Operator Graph (Draw)): dx każdego ramienia = PEŁNA szerokość boksu,
        // STAŁA — niezależna od Breakpointu I od głębokości. Dzięki temu:
        // 1) dx zawsze ≥ odległość od Breakpointu do dowolnej krawędzi boksu, więc
        //    ramię zawsze SIĘGA (lub przekracza, przycięte) obu krawędzi — niezależnie
        //    od pozycji Breakpointu (naprawia: linia nie dochodziła do krawędzi przy
        //    skrajnym BrPoint, np. A-1 z płytką głębokością).
        // 2) dx się nie zmienia gdy przesuwamy Breakpoint, więc kąt (atan(dy/dx)) też
        //    się nie zmienia — cały rysunek tylko się PRZESUWA w bok wraz z
        //    Breakpointem, zamiast zmieniać nachylenie (naprawia: poprzednia wersja
        //    liczyła dx jako odległość Breakpoint→krawędź, więc przy przesuwaniu
        //    Breakpointu zmieniał się kąt, a wierzchołek „odjeżdżał" od podstawy —
        //    zrzut użytkownika, BrPoint=C1 vs oryginał).
        // Skala głębokości: żeby zachować potwierdzone wcześniej „45° przy głębokości 99,
        // Breakpoint≈środek", amount(99) musi się równać dx (=szerokość boksu) — stąd
        // dzielnik to PEŁNA szerokość, nie jej połowa.
        let left = rect.minX
        let right = rect.maxX
        let width = right - left
        func amount(_ depth: Int) -> CGFloat {
            CGFloat(min(99, max(0, depth))) / 99.0 * width
        }
        let leftAmount = amount(leftDepth)
        let rightAmount = amount(rightDepth)
        let clampedBreakpoint = CGFloat(min(99, max(0, breakpoint))) / 99.0
        let xBreakpoint = left + clampedBreakpoint * width
        // (wysokość - 2 Gen1px marginesu) / 2, jak w oryginale — centerY nieznacznie nad
        // geometrycznym środkiem boksu.
        let centerY = rect.midY - PatchLayout.bverhuePixelScale

        func endpointY(type: Int, amount: CGFloat) -> CGFloat {
            // Operator Graph: -Lin/-Exp leżą poniżej osi, +Exp/+Lin nad osią,
            // tak samo z lewej i z prawej strony breakpointu.
            centerY + (type < 2 ? amount : -amount)
        }
        // Graph ABC (ExpTo) (wywoływane z Operator Graph (Draw)) rysuje
        // ćwiartkę elipsy — ten sam mechanizm co już przeportowany `expTo()` w
        // `drawDXEnvelope()` wyżej w tym pliku. Krzywa jest PŁASKA (styczna pozioma)
        // przy Breakpoincie i STROMA (styczna pionowa) przy końcu L-Depth/R-Depth —
        // stąd charakterystyczne płaskie plateau na szczycie/dołku i strome zbocza na
        // końcach, potwierdzone zrzutami oryginalnego edytora (pikselowe „schodki" tam
        // to tylko artefakt renderu do małej bitmapy — u nas ma być gładka krzywa).
        // Pojedyncza krzywa kwadratowa Béziera ma jednoznaczny kształt przy 3 zadanych
        // punktach, więc nie trzeba osobno rozróżniać -Exp/+Exp — kierunek (góra/dół)
        // ustala już `endpointY()`.
        func addSegment(_ path: inout Path, from: CGPoint, to: CGPoint, type: Int, isLeftSegment: Bool) {
            if type == 0 || type == 3 {
                path.addLine(to: to)
                return
            }
            let control = isLeftSegment
                ? CGPoint(x: from.x, y: to.y) // płasko przy Breakpoincie (to), stromo przy from
                : CGPoint(x: to.x, y: from.y) // płasko przy Breakpoincie (from), stromo przy to
            path.addQuadCurve(to: to, control: control)
        }

        // Subtelna linia odniesienia, jak tło wykresów charakterystyki w oryginalnym panelu.
        var grid = Path()
        grid.move(to: CGPoint(x: rect.minX, y: centerY))
        grid.addLine(to: CGPoint(x: rect.maxX, y: centerY))
        ctx.stroke(grid, with: .color(UIColor.graphBaseline.opacity(0.75)), lineWidth: 0.5)

        let leftPoint = CGPoint(x: xBreakpoint - width, y: endpointY(type: leftType, amount: leftAmount))
        let breakpointPoint = CGPoint(x: xBreakpoint, y: centerY)
        let rightPoint = CGPoint(x: xBreakpoint + width, y: endpointY(type: rightType, amount: rightAmount))
        var path = Path()
        path.move(to: leftPoint)
        addSegment(&path, from: leftPoint, to: breakpointPoint, type: leftType, isLeftSegment: true)
        addSegment(&path, from: breakpointPoint, to: rightPoint, type: rightType, isLeftSegment: false)

        // Duża głębokość (patrz wyżej) może wyprowadzić punkty poza rect — oryginał
        // rysuje w bitmapę dokładnie wielkości boksu, więc linia jest tam przycinana,
        // nie skalowana. Odtwarzamy to przycinając kontekst do rect przed rysowaniem.
        var clippedCtx = ctx
        clippedCtx.clip(to: Path(rect))
        strokeGraphPath(clippedCtx, path)
    }

    // MARK: - Filter response rendering

    /// Mały wykres FltLP/FltHP przepisany z Small Filter Graph (Draw).
    /// Clavia używa surowej wartości częstotliwości jako pozycji X i osobnej
    /// geometrii Béziera dla sześciu nachyleń, zamiast transmitancji filtra.
    private func drawSmallFilterGraph(_ ctx: GraphicsContext,
                                      freqParam: Int, active: Bool, slopeMode: Int,
                                      highPass: Bool, rect: CGRect)
    {
        let slopeValue = (min(5, max(0, slopeMode)) + 1) * 6
        let baselineY = rect.minY + rect.height / 3
        let cutoffX = rect.minX + rect.width * CGFloat(min(127, max(0, freqParam))) / 127
        // Obrys musi dojść do granicy wypełnienia; wcześniejsze 91% zostawiało
        // widoczną przerwę na końcu opadającego zbocza.
        let bottomY = rect.maxY

        var response = Path()
        let first: CGPoint
        let last: CGPoint
        if !active {
            first = CGPoint(x: rect.minX, y: baselineY)
            last = CGPoint(x: rect.maxX, y: baselineY)
            response.move(to: first)
            response.addLine(to: last)
        } else if highPass {
            first = CGPoint(x: rect.maxX, y: baselineY)
            let knee = CGPoint(x: cutoffX, y: baselineY)
            let controlOffset = rect.width * (1 - CGFloat(slopeValue) * 0.85 / 32)
            let endOffset = rect.width * (1 - CGFloat(slopeValue) * 0.80 / 32)
            last = CGPoint(x: cutoffX - endOffset, y: bottomY)
            response.move(to: first)
            response.addLine(to: knee)
            response.addCurve(
                to: last,
                control1: knee,
                control2: CGPoint(x: cutoffX - controlOffset,
                                  y: rect.minY + rect.height * 0.50)
            )
        } else {
            first = CGPoint(x: rect.minX, y: baselineY)
            let knee = CGPoint(x: cutoffX, y: baselineY)
            let controlOffset = rect.width * (1 - CGFloat(slopeValue) * 0.85 / 32)
            let endOffset = rect.width * (1 - CGFloat(slopeValue) * 0.80 / 32)
            last = CGPoint(x: cutoffX + endOffset, y: bottomY)
            response.move(to: first)
            response.addLine(to: knee)
            response.addCurve(
                to: last,
                control1: knee,
                control2: CGPoint(x: cutoffX + controlOffset,
                                  y: rect.minY + rect.height * 0.50)
            )
        }

        var clipped = ctx
        clipped.clip(to: Path(rect))
        fillUnderGraph(clipped, path: response, first: first, last: last, rect: rect)

        var baseline = Path()
        baseline.move(to: CGPoint(x: rect.minX, y: baselineY))
        baseline.addLine(to: CGPoint(x: rect.maxX, y: baselineY))
        clipped.stroke(baseline, with: .color(UIColor.graphBaseline.opacity(0.85)), lineWidth: 0.5)
        strokeGraphPath(clipped, response)

        let labelBox = CGRect(x: rect.minX + rect.width * 0.63,
                              y: rect.minY,
                              width: rect.width * 0.34,
                              height: max(1, baselineY - rect.minY))
        let slopeFontSize = UIFont.lcdDisplay(boxHeight: labelBox.height) * (5.0 / 3.0)
        drawLcdText(clipped, text: String(slopeValue), box: labelBox,
                    fontSize: slopeFontSize, centered: true)
    }

    /// GraphFunc 20/21/40 — odwzorowanie Filter Graph ABC (Draw)() z oryginalnego
    /// edytora. Geometrię liczy `FilterGraphGeometry` na źródłowym buforze 50×26;
    /// tutaj zostaje wyłącznie przeskalowanie punktów na ekran modułu.
    ///
    /// Rezonans podnosi tylko punkt kontrolny przy częstotliwości granicznej,
    /// więc przy dużym `Res` powstaje lokalny pik. Poprzednia wersja próbkowała
    /// transmitancję biquada i przy dużym Q gubiła go w podpikselowej szczelinie.
    /// - Parameters:
    ///   - freqParam: surowe `Freq` 0…127.
    ///   - resParam: surowe `Res` 0…127.
    ///   - filterType: indeks PartSelectora 0=LP, 1=BP, 2=HP, 3=BR.
    ///   - slope: nachylenie w dB/Oct rysowane też jako liczba w rogu ekranu.
    ///   - resonanceScale: Gain Compensation — podnosi poziom całej linii.
    ///   - classicVariant: `true` wyłącznie dla FltClassic (`this[0x89] == 1`).
    ///   - active: `false` rysuje samą linię 0 dB.
    private func drawFilter(_ ctx: GraphicsContext,
                            freqParam: Int, resParam: Int,
                            filterType: Int, slope: Int,
                            resonanceScale: Int = 0,
                            classicVariant: Bool = false,
                            active: Bool = true,
                            rect: CGRect)
    {
        let kind = FilterGraphGeometry.Kind(rawValue: min(3, max(0, filterType)) + 1) ?? .lowPass
        let shape = FilterGraphGeometry.shape(
            frequency: freqParam,
            resonance: resParam,
            kind: kind,
            slope: slope,
            resonanceScale: resonanceScale,
            classicVariant: classicVariant,
            active: active
        )

        /// Bufor Clavii ma 50×26 punktów; punktów spoza niego nie zaciskamy,
        /// bo oryginał pozwala krzywej wejść i wyjść poza widoczną ramkę.
        func point(_ source: FilterGraphGeometry.SourcePoint) -> CGPoint {
            CGPoint(
                x: rect.minX + CGFloat(source.x / FilterGraphGeometry.innerWidth) * rect.width,
                y: rect.minY + CGFloat(source.y / FilterGraphGeometry.innerHeight) * rect.height
            )
        }

        var clipped = ctx
        clipped.clip(to: Path(rect))

        let baselineY = rect.minY
            + CGFloat(FilterGraphGeometry.baseline / FilterGraphGeometry.innerHeight)
            * rect.height
        var baseline = Path()
        baseline.move(to: CGPoint(x: rect.minX, y: baselineY))
        baseline.addLine(to: CGPoint(x: rect.maxX, y: baselineY))
        clipped.stroke(baseline, with: .color(UIColor.graphBaseline.opacity(0.75)), lineWidth: 0.5)

        var path = Path()
        let first = point(shape.start)
        path.move(to: first)
        if let lineTo = shape.lineTo {
            path.addLine(to: point(lineTo))
        }
        for segment in shape.segments {
            path.addCurve(to: point(segment.end),
                          control1: point(segment.control1),
                          control2: point(segment.control2))
        }
        let last = point(shape.segments.last?.end ?? shape.lineTo ?? shape.start)

        fillUnderGraph(clipped, path: path, first: first, last: last, rect: rect)
        strokeGraphPath(clipped, path)

        // Oryginał wypisuje nachylenie przy prawej krawędzi, na wysokości 7.
        // Rozmiar bierzemy ze stałej wysokości w jednostkach źródłowych — tej
        // samej, której używają małe filtry (FltLP/FltHP mają ekran 32×22).
        // Bez tego font rośnie razem z wyższym ekranem 52×28 i dwucyfrowe
        // wartości wchodzą w maksymalną kompresję odstępów, sklejając cyfry.
        let labelHeight = CGFloat(22.0 / 3.0 / FilterGraphGeometry.innerHeight) * rect.height
        let slopeFontSize = UIFont.lcdDisplay(boxHeight: labelHeight) * (5.0 / 3.0)
        // Pole jest niewiele szersze od najszerszej wartości `24`, dzięki czemu
        // wyśrodkowana treść trzyma się prawej krawędzi ekranu.
        let labelBox = CGRect(x: rect.minX + rect.width * 0.68,
                              y: rect.minY,
                              width: rect.width * 0.32,
                              height: max(1, baselineY - rect.minY))
        drawLcdText(clipped, text: String(slope), box: labelBox,
                    fontSize: slopeFontSize, centered: true)
    }

    /// GraphFunc 13/35 — odwzorowanie Feedback Flt (Draw)() z oryginalnego edytora.
    /// FltPhase przekazuje liczbę dodatkowych zębów 0...5 i regulowany Spread,
    /// a FltComb zawsze używa czterech zębów oraz Spread=120.
    private func drawFeedbackFilter(_ ctx: GraphicsContext,
                                    feedback: Int, type: Int,
                                    notchCount: Int, spread: Int,
                                    rect: CGRect)
    {
        let sourceWidth = 52.0
        let sourceInnerWidth = 50.0
        let sourceInnerHeight = 26.0
        let middleY = 13.0
        let count = min(5, max(0, notchCount))
        let spreadValue = min(127, max(0, spread))
        let feedbackValue = min(127, max(0, feedback))

        // Stałe z przełącznika NotchCount w oryginalnym Draw().
        let shoulderFactors = [6.0, 5.0, 4.0, 3.0, 2.0, 1.0]
        let spacingFactors = [10.0, 9.0, 8.0, 7.0, 6.0, 5.0]
        let leadingXValues = [-11.0, -11.0, -13.0, -16.0, -18.0, -21.0]
        let spacing = spacingFactors[count] * Double(spreadValue) / 127.0
        let shoulder = shoulderFactors[count] * Double(spreadValue) / 127.0 * 0.8125
        let firstCenterX = Double(Int(
            ((sourceWidth - 5.0) - Double(count + 1) * spacing) * 0.5 + 0.5
        ))
        let outerHandleX = Double(25 - spreadValue * 20 / 127) * 0.8125
        let leadingX = leadingXValues[count]

        // Feedback Flt koduje trzy typy przez cztery przesunięcia pionowe.
        // Zachowujemy rozgałęzienia względem środka FB=64 dokładnie tak,
        // jak robią to tryby Notch, Peak i Deep w oryginale.
        let feedbackDelta = Double(feedbackValue - 64) / 64.0
        var firstEndOffset = 0.0
        var toothOffset = 0.0
        let toothControlOffset = 0.0
        let shoulderOffset = 0.0
        var pathStartY = middleY

        switch min(2, max(0, type)) {
        case 0:
            if feedbackValue > 63 {
                firstEndOffset = feedbackDelta * 15.0
            } else {
                toothOffset = (1.0 - Double(feedbackValue) / 64.0) * 15.0
                pathStartY = middleY + toothOffset
            }
        case 1:
            if feedbackValue < 64 {
                firstEndOffset = feedbackDelta * 15.0
            } else {
                toothOffset = feedbackDelta * -15.0
                pathStartY = middleY + toothOffset
            }
        default:
            toothOffset = feedbackDelta * -15.0
            firstEndOffset = feedbackDelta * 15.0
            if feedbackValue >= 64 {
                pathStartY = middleY + toothOffset
            }
        }

        /// Współrzędne Clavii są liczone na buforze 50×26 wewnątrz
        /// ramki 52×28. Punktów poza buforem nie zaciskamy: oryginał je
        /// przycina, dzięki czemu krzywa naturalnie wchodzi i wychodzi z ekranu.
        func sourcePoint(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(
                x: rect.minX + CGFloat(x / sourceInnerWidth) * rect.width,
                y: rect.minY + CGFloat(y / sourceInnerHeight) * rect.height
            )
        }

        func rounded(_ value: Double) -> Double {
            Double(Int(value + 0.5))
        }

        var clipped = ctx
        clipped.clip(to: Path(rect))

        var baseline = Path()
        baseline.move(to: sourcePoint(0.0, rounded(middleY)))
        baseline.addLine(to: sourcePoint(sourceWidth, rounded(middleY)))
        clipped.stroke(
            baseline,
            with: .color(UIColor.graphBaseline.opacity(0.75)),
            lineWidth: 0.5
        )

        var path = Path()
        let firstPoint = sourcePoint(leadingX, rounded(pathStartY))
        path.move(to: firstPoint)
        path.addCurve(
            to: sourcePoint(firstCenterX, rounded(middleY + firstEndOffset)),
            control1: sourcePoint(
                rounded(leadingX + outerHandleX),
                rounded(middleY)
            ),
            control2: sourcePoint(
                rounded(firstCenterX - 3.0),
                rounded(middleY + firstEndOffset * 0.5)
            )
        )

        for index in 0 ..< count {
            let leftX = Double(index * 2) * spacing + firstCenterX
            let centerX = leftX + spacing
            let rightX = leftX + spacing * 2.0
            path.addCurve(
                to: sourcePoint(rounded(centerX), rounded(middleY + toothOffset)),
                control1: sourcePoint(
                    rounded(leftX + shoulder),
                    rounded(middleY + shoulderOffset)
                ),
                control2: sourcePoint(
                    rounded(centerX),
                    rounded(middleY + toothOffset + toothControlOffset)
                )
            )
            path.addCurve(
                to: sourcePoint(rounded(rightX), rounded(middleY + firstEndOffset)),
                control1: sourcePoint(rounded(centerX), rounded(middleY + toothOffset)),
                control2: sourcePoint(
                    rounded(rightX - shoulder),
                    rounded(middleY + shoulderOffset)
                )
            )
        }

        let trailingX = (sourceWidth - 2.0) - leadingX
        let lastPoint = sourcePoint(rounded(trailingX), rounded(pathStartY))
        path.addCurve(
            to: lastPoint,
            control1: sourcePoint(
                rounded(sourceWidth + 1.0 - firstCenterX),
                rounded(middleY + firstEndOffset / 3.0)
            ),
            control2: sourcePoint(
                rounded(trailingX - outerHandleX),
                rounded(middleY)
            )
        )

        fillUnderGraph(clipped, path: path, first: firstPoint, last: lastPoint, rect: rect)
        strokeGraphPath(clipped, path)
    }

    // MARK: - Vocoder

    /// GraphFunc 8 — port Vocoder Graph (Draw)(): dolny koniec każdej
    /// kreski odpowiada pasmu syntezy 1...16, a górny wskazuje wybrane pasmo
    /// analizy 1...16. Wartość 0 wyłącza dane połączenie.
    private func drawVocoderBands(_ ctx: GraphicsContext, values: [Int], rect: CGRect) {
        let sourceScale = PatchLayout.bverhuePixelScale
        let inner = rect.insetBy(dx: sourceScale, dy: sourceScale)

        PanelFace.recessed(ctx, Path(rect), fill: UIColor.graphBackground,
                           border: UIColor.graphBorder, shaded: panelShading)

        var clipped = ctx
        clipped.clip(to: Path(inner))

        func point(_ sourceX: CGFloat, _ sourceY: CGFloat) -> CGPoint {
            CGPoint(
                x: inner.minX + sourceX / 192.0 * inner.width,
                y: inner.minY + sourceY / 45.0 * inner.height
            )
        }

        var bands = Path()
        for index in 0 ..< min(16, values.count) {
            let value = min(16, max(0, values[index]))
            guard value != 0 else { continue }
            bands.move(to: point(CGFloat(6 + index * 12), 45))
            bands.addLine(to: point(CGFloat(value * 12 - 6), -1))
        }
        clipped.stroke(
            bands,
            with: .color(UIColor.graphLine),
            style: StrokeStyle(lineWidth: UIMetrics.graphLineWidth, lineCap: .butt)
        )
    }

    /// GraphFunc 22 — Vocoder Preset tworzy siedem widoków potomnych po
    /// 22 piksele Gen1: -2, -1, 0, +1, +2, Inv i Rnd.
    private func drawVocoderPresetButtons(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        let labels = ["-2", "-1", "0", "+1", "+2", "Inv", "Rnd"]
        let buttonRects = vocoderPresetButtonRects(in: rect)
        let selectedPreset = vocoderSelectedPreset[module.id]
            ?? matchingVocoderPreset(parameters: module.parameters)

        for (index, label) in labels.enumerated() {
            let buttonRect = buttonRects[index]
            let isSelected = selectedPreset == index
            let path = Path(roundedRect: buttonRect, cornerRadius: UIMetrics.buttonFlatCornerRadius)
            PanelFace.raised(ctx, path, fill: isSelected ? UIColor.buttonTextOn : UIColor.buttonNeutral,
                             shaded: panelShading)
            ctx.draw(
                Text(label)
                    .font(.system(size: UIFont.buttonLabel, weight: .bold))
                    .fontWidth(.condensed)
                    .foregroundColor(isSelected ? .white : Color(white: 0.25)),
                at: CGPoint(x: buttonRect.midX, y: buttonRect.midY),
                anchor: .center
            )
        }
    }

    /// GraphFunc 11 (LevScaler) — krzywa skalowania poziomu wg nuty/prędkości uderzenia.
    /// L/R: dB/oktawę wg InfoFunc 70 (-8..+8dB, formuła jak w g2InfoFunction case 70).
    /// BP: punkt przegięcia na osi 0-127 (InfoFunc:13 — ta sama domena co "Note").
    /// Poziom w BP = 0dB; w lewo/prawo zmienia się liniowo o L/R dB na oktawę (12 nut).
    /// Oś pionowa ograniczona do ±24dB (jak inne wykresy EQ w tym pliku) — poza tym
    /// zakresem linia jest po prostu przycinana do krawędzi wykresu.
    /// Kierunek nachylenia potwierdzony wizualnie 2026-08-03: L=0 (-8dB/oct) → krzywa
    /// zaczyna się od dołu po lewej stronie.
    private func drawLevelScalerCurve(_ ctx: GraphicsContext,
                                      left: Int, breakpoint: Int, right: Int, rect: CGRect)
    {
        func dBPerOctave(_ raw: Int) -> Double {
            -8.0 + 16.0 * Double(raw) / 127.0
        }
        let bp = Double(min(127, max(0, breakpoint)))
        let dbRange = 24.0

        func yFor(_ dB: Double) -> CGFloat {
            let norm = max(-1.0, min(1.0, dB / dbRange))
            return rect.midY - CGFloat(norm) * (rect.height * 0.5)
        }
        func xFor(_ note: Double) -> CGFloat {
            rect.minX + CGFloat(note / 127.0) * rect.width
        }

        // Pozioma linia 0dB
        var grid = Path()
        grid.move(to: CGPoint(x: rect.minX, y: rect.midY))
        grid.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        ctx.stroke(grid, with: .color(UIColor.graphBaseline.opacity(0.75)), lineWidth: 0.5)

        // Lewa strona: dystans liczony OD lewej krawędzi DO breakpointu (bp - 0), nie odwrotnie —
        // potwierdzone wizualnie (2026-08-03): L=0 (-8dB/oct) → krzywa zaczyna się od dołu.
        let leftDB = dBPerOctave(left) * (bp - 0) / 12.0
        let rightDB = dBPerOctave(right) * (127 - bp) / 12.0
        let xk = xFor(bp)
        let yk = yFor(0)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: yFor(leftDB)))
        path.addLine(to: CGPoint(x: xk, y: yk))
        path.addLine(to: CGPoint(x: rect.maxX, y: yFor(rightDB)))
        strokeGraphPath(ctx, path)

        // Kropka na punkcie przegięcia (breakpoint)
        let dotR: CGFloat = 0.9
        ctx.fill(Path(ellipseIn: CGRect(x: xk - dotR, y: yk - dotR, width: dotR * 2, height: dotR * 2)),
                 with: .color(UIColor.graphLine))
    }

    // MARK: - Ekrany korektorów (port Eq*Graph)

    /// Wspólne rysowanie kształtu zwróconego przez `EqGraphGeometry`.
    /// Bufor Clavii ma 50×26 punktów; punktów poza nim nie zaciskamy, bo
    /// oryginał wypuszcza końce ścieżki poza widoczną ramkę i przycina je
    /// dopiero ekranem.
    private func drawEqShape(_ ctx: GraphicsContext,
                             shape: EqGraphGeometry.Shape, rect: CGRect)
    {
        func point(_ source: EqGraphGeometry.SourcePoint) -> CGPoint {
            CGPoint(
                x: rect.minX + CGFloat(source.x / EqGraphGeometry.innerWidth) * rect.width,
                y: rect.minY + CGFloat(source.y / EqGraphGeometry.innerHeight) * rect.height
            )
        }

        var clipped = ctx
        clipped.clip(to: Path(rect))

        // Linia 0 dB biegnie w tych ekranach dokładnie przez środek.
        let baselineY = rect.minY
            + CGFloat(EqGraphGeometry.baseline / EqGraphGeometry.innerHeight) * rect.height
        var baseline = Path()
        baseline.move(to: CGPoint(x: rect.minX, y: baselineY))
        baseline.addLine(to: CGPoint(x: rect.maxX, y: baselineY))
        clipped.stroke(baseline, with: .color(UIColor.graphBaseline.opacity(0.75)), lineWidth: 0.5)

        var path = Path()
        let first = point(shape.start)
        path.move(to: first)
        for element in shape.elements {
            switch element {
            case let .line(target):
                path.addLine(to: point(target))
            case let .curve(segment):
                path.addCurve(to: point(segment.end),
                              control1: point(segment.control1),
                              control2: point(segment.control2))
            }
        }

        fillUnderGraph(clipped, path: path, first: first, last: point(shape.end), rect: rect)
        strokeGraphPath(clipped, path)
    }

    /// GraphFunc 36 — port Eq Hi Lo Graph (Draw)(). Zależnościami są wyłącznie
    /// oba wzmocnienia; punkty załamania półek są w oryginale stałe, więc
    /// przełączniki częstotliwości nie zmieniają kształtu ekranu.
    private func drawEq2Band(_ ctx: GraphicsContext,
                             loGain: Int, hiGain: Int, rect: CGRect)
    {
        drawEqShape(ctx,
                    shape: EqGraphGeometry.twoBand(lowGain: loGain, highGain: hiGain),
                    rect: rect)
    }

    /// GraphFunc 10 — port Eq Mid Graph (Draw)(). Pasmo dzwonowe składa się
    /// z dwóch krzywych o punktach kontrolnych leżących na linii 0 dB, dzięki
    /// czemu wierzchołek pozostaje ostry niezależnie od `BW`.
    private func drawEqPeak(_ ctx: GraphicsContext,
                            freq: Int, gain: Int, bandwidth: Int, rect: CGRect)
    {
        drawEqShape(ctx,
                    shape: EqGraphGeometry.peak(frequency: freq, gain: gain,
                                                bandwidth: bandwidth),
                    rect: rect)
    }

    /// GraphFunc 37 — port Eq Hi Mid Lo Graph (Draw)(). Pasmo środkowe wędruje
    /// między punktami załamania półek i styka się z nimi tylko na krańcach
    /// swojej skali częstotliwości.
    private func drawEq3Band(_ ctx: GraphicsContext,
                             loGain: Int, midGain: Int, midFreq: Int, hiGain: Int,
                             rect: CGRect)
    {
        drawEqShape(ctx,
                    shape: EqGraphGeometry.threeBand(lowGain: loGain, midGain: midGain,
                                                     midFrequency: midFreq,
                                                     highGain: hiGain),
                    rect: rect)
    }

    // MARK: - Waveform shape display

    /// Rysuje uproszczoną falę dla Graph Func 32/34 (OscShpA/LfoShpA).
    private func drawGraphWaveShape(_ ctx: GraphicsContext, waveIndex: Int, rect: CGRect) {
        let nPoints = 64
        let w = rect.width, h = rect.height
        let cy = rect.minY + h * 0.5
        let amp = h * 0.42

        var path = Path()
        for i in 0 ..< nPoints {
            let t = Double(i) / Double(nPoints - 1) // 0..1 = one cycle
            let phase = t * 2.0 * .pi
            let y: Double = switch waveIndex % 6 {
            case 0: sin(phase) // sine
            case 1: t < 0.5 ? 1.0 : -1.0 // square
            case 2: 1.0 - 2.0 * t // sawtooth down
            case 3: t < 0.5 ? 4.0 * t - 1.0 : 3.0 - 4.0 * t // triangle
            case 4: t < 0.25 ? 1.0 : -1.0 // narrow pulse
            default: 1.0 - t // ramp up
            }
            let px = rect.minX + CGFloat(t) * w
            let py = cy - CGFloat(y) * amp
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) } else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        strokeGraphPath(ctx, path)
    }

    /// GraphFunc 19 (Pulse Osc Graph). Panel przekazuje Width jako pierwszą
    /// zależność i wybór okresu jako drugą. Wykres nie reaguje na Track ani
    /// Phase — zgodnie z UpdateGraphics oryginału odczytującym tylko te dwa pola.
    private func drawPulseOscWave(_ ctx: GraphicsContext, width: Int, waveform: Int, rect: CGRect) {
        let duty = min(max(CGFloat(width) / 127.0, 0.08), 0.92)
        switch waveform {
        case 0:
            drawSampledOscWave(ctx, rect: rect) { t in CGFloat(sin(Double(t) * 2.0 * .pi)) }
        case 1:
            // Modulated Sine: Width ściska dodatnią połówkę i rozciąga ujemną.
            drawDualSineShape(ctx, firstHalf: duty, shape: 0, rect: rect)
        case 2:
            drawTweakedTriangleShape(ctx, shape: duty * 2.0 - 1.0, rect: rect)
        case 3:
            drawPulseShape(ctx, duty: duty, rect: rect)
        case 4:
            drawPulseOscSaw(ctx, peak: duty, rect: rect)
        case 5:
            drawPulseOscSaw(ctx, peak: 0, rect: rect)
        case 6:
            drawTweakedTriangleShape(ctx, shape: duty * 2.0 - 1.0, rect: rect)
        default:
            break
        }
    }

    private func drawPulseOscSaw(_ ctx: GraphicsContext, peak: CGFloat, rect: CGRect) {
        let x0 = rect.minX
        let amp = rect.height * 0.42
        let reset = min(max(peak, 0), 0.92)
        var path = Path()
        path.move(to: CGPoint(x: x0, y: rect.midY + amp))
        path.addLine(to: CGPoint(x: x0 + rect.width * reset, y: rect.midY - amp))
        path.addLine(to: CGPoint(x: x0 + rect.width * reset, y: rect.midY + amp))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + amp))
        strokeGraphPath(ctx, path)
    }

    /// GraphFunc 33 (Lfo B Graph). Phase przesuwa start fali, a Output type
    /// odwraca jej polaryzację dla wartości nieparzystych — dokładnie te trzy
    /// zależności są odczytywane przez oryginalny UpdateGraphics.
    private func drawLfoBWaveShape(_ ctx: GraphicsContext,
                                   waveIndex: Int,
                                   phase: Int,
                                   outputType: Int,
                                   rect: CGRect)
    {
        drawLfoWave(ctx, waveIndex: waveIndex, phase: phase, outputType: outputType, rect: rect)
    }

    private func drawLfoWave(_ ctx: GraphicsContext,
                             waveIndex: Int,
                             phase: Int,
                             outputType: Int,
                             rect: CGRect,
                             color: Color = UIColor.graphLine,
                             lineWidth: CGFloat = UIMetrics.graphLineWidth)
    {
        let phaseOffset = CGFloat(min(max(phase, 0), 127)) / 128.0
        let inverted = outputType % 2 == 1
        let amplitudeSign: CGFloat = inverted ? -1 : 1
        drawSampledOscWave(ctx, rect: rect, amplitudeFraction: 0.5,
                           color: color, lineWidth: lineWidth)
        { t in
            let wrapped = (t + phaseOffset).truncatingRemainder(dividingBy: 1)
            let value: CGFloat = switch waveIndex {
            case 0: CGFloat(sin(Double(wrapped) * 2.0 * .pi))
            // Trójkąt startuje w POŁOWIE wysokości i idzie w GÓRĘ: `DrawTri` z
            // oryginału rysuje kolejno (x₀, środek) → (x₀+¼okresu, góra) →
            // (x₀+¾okresu, dół) → (x₀+okres, środek). Wcześniej zaczynaliśmy na dole,
            // czyli o ćwierć okresu za wcześnie.
            case 1: wrapped < 0.25 ? wrapped * 4.0
                : (wrapped < 0.75 ? 2.0 - wrapped * 4.0 : wrapped * 4.0 - 4.0)
            case 2: 1.0 - wrapped * 2.0
            default: wrapped < 0.5 ? 1.0 : -1.0
            }
            return value * amplitudeSign
        }
    }

    // MARK: - LfoShpA — sześć fal wg oryginału

    /// Znormalizowana wartość fali LfoShpA: 0 = dolna krawędź ekranu, 1 = górna.
    ///
    /// Odwzorowanie 1:1 czterech funkcji z oryginalnego edytora (`Global`: `Sin2Saw`,
    /// `CosBell`, `TriBell`, `Tri2Saw`), wywoływanych przez
    /// Lfo C Graph (Draw) → Waveform Graph ABC (DrawNormalizedGraph).
    /// Mimo nazwy klasy to panel LfoShpA — to on ma sześć fal, Shape i Phase.
    ///
    /// `x` to pozycja w cyklu (0…1) POWIĘKSZONA o fazę, `s` = Shape/128 (0…0,992;
    /// domyślne 0,5 = gałka na godzinie 12, potwierdzone konstruktorem
    /// Waveform Graph ABC zerującym surowe pole Shape).
    static func lfoShpASample(waveIndex: Int, x: Double, shape s: Double) -> Double {
        switch waveIndex {
        case 0: // Sin2Saw — trójkąt o wierzchołku w `s`, wygładzony raised-cosine
            let u = x > 1 ? x - 1 : x
            let d = s <= u ? 1.0 - (u - s) / (1.0 - s) : u / s
            return (1.0 - cos(d * .pi)) * 0.5

        case 1: // CosBell — dzwon cosinusowy szerokości `s`, wyśrodkowany w x=0,5
            var u = s * 0.5 + 0.5 + x
            if u > 2 { u -= 1 }
            if u > 1 { u -= 1 }
            guard u < s else { return 0 }
            return (1.0 - cos(2.0 * .pi * u / s)) * 0.5

        case 2: // TriBell — dzwon TRÓJKĄTNY szerokości `s`, wyśrodkowany w x=0,5
            var u = 0.5 + s * 0.5 + x
            if u > 2 { u -= 1 }
            if u > 1 { u -= 1 }
            if u >= s * 0.5 {
                guard u < s else { return 0 }
                return ((u - s * 0.5) / s) * -2.0 + 1.0
            }
            return 2.0 * u / s

        default: // 3 = Tri2Saw — czysty trójkąt o wierzchołku w `s` (piła na skrajach)
            let u = x > 1 ? x - 1 : x
            return s <= u ? 1.0 - (u - s) / (1.0 - s) : u / s
        }
    }

    /// GraphFunc 34 — ekran LfoShpA. Sześć fal, wszystkie na PEŁNEJ wysokości ekranu
    /// (`DrawNormalizedGraph`: `y = (h-2) − v·(h-4)`), Phase przesuwa przebieg w lewo,
    /// a Output type nieparzysty (PosInv/NegInv/BipInv) odwraca go pionowo (`v = 1−v`).
    /// Fale 4 (SqrTri) i 5 (Square) mają w oryginale pionowe zbocza, więc powstają jako
    /// łamana z jawnych punktów załamania, a nie z próbkowania.
    private func drawLfoShpAWaveShape(_ ctx: GraphicsContext,
                                      waveIndex: Int,
                                      shape: Int,
                                      phase: Int,
                                      outputType: Int,
                                      rect: CGRect,
                                      color: Color = UIColor.graphLine,
                                      lineWidth: CGFloat = UIMetrics.graphLineWidth)
    {
        let s = Double(min(max(shape, 0), 127)) / 128.0
        let phaseFrac = Double(min(max(phase, 0), 127)) / 128.0
        let inverted = outputType % 2 == 1
        // Skrajne wartości (0 i 1) leżą na samej krawędzi ekranu, więc płaskie odcinki
        // Sqr2Tri i Square traciły przy klipowaniu POŁOWĘ swojej grubości i wychodziły
        // wyraźnie cieńsze od pionów i skosów. Oryginał ma ten sam zapas (`DrawNormalizedGraph`
        // rysuje od `h-2` do `2`, nie od krawędzi do krawędzi) — mieścimy więc przebieg
        // o pół grubości krzywej do środka.
        let edgeInset = lineWidth / 2
        let usableHeight = max(0, rect.height - 2 * edgeInset)
        func yFor(_ v: Double) -> CGFloat {
            let clamped = min(max(inverted ? 1.0 - v : v, 0), 1)
            return rect.maxY - edgeInset - CGFloat(clamped) * usableHeight
        }

        guard waveIndex >= 4 else {
            drawSampledOscWave(ctx, rect: rect, amplitudeFraction: 0.5,
                               color: color, lineWidth: lineWidth)
            { t in
                let v = Self.lfoShpASample(waveIndex: waveIndex,
                                           x: Double(t) + phaseFrac, shape: s)
                return CGFloat(inverted ? 1.0 - v : v) * 2.0 - 1.0
            }
            return
        }

        // Punkty załamania jednego okresu (t, wartość 0…1).
        // SqrTri (`DrawSqrTri`): start w połowie, `q = okres/4`, ramiona o szerokości `s·q`.
        // Square (`DrawSquare`): start na GÓRZE, wypełnienie = `s`.
        let breakpoints: [(Double, Double)] = waveIndex == 4
            ? [(0, 0.5), (s / 4, 1), ((2 - s) / 4, 1), ((2 + s) / 4, 0), ((4 - s) / 4, 0), (1, 0.5)]
            : [(0, 1), (s, 1), (s, 0), (1, 0), (1, 1)]

        var path = Path()
        var started = false
        for period in -1 ... 1 {
            for (t, v) in breakpoints {
                let x = rect.minX + CGFloat(t + Double(period) - phaseFrac) * rect.width
                let point = CGPoint(x: x, y: yFor(v))
                if started { path.addLine(to: point) } else { path.move(to: point)
                    started = true
                }
            }
        }
        // Rysujemy trzy okresy (poprzedni/bieżący/następny), żeby przy dowolnej fazie
        // przebieg wypełniał ekran od krawędzi do krawędzi — nadmiar obcinamy.
        var clipped = ctx
        clipped.clip(to: Path(rect))
        strokeEvenly(clipped, path, color: color, lineWidth: lineWidth)
    }

    /// Wartość Shape jest w patchu kodowana jako 0...127, a w oryginalnym
    /// Waveform Graph ABC używana jako wartość bipolarna. Środek zakresu
    /// zachowuje podstawowy kształt; skraje przesuwają punkty załamania.
    private func oscShapeBipolarValue(_ shape: Int) -> CGFloat {
        let clamped = CGFloat(min(max(shape, 0), 127))
        return (clamped - 63.5) / 63.5
    }

    private func drawOscShpAWaveShape(_ ctx: GraphicsContext, waveIndex: Int, shape: Int, rect: CGRect) {
        drawOscShapeWave(ctx, waveIndex: waveIndex, shape: shape, isShapeB: false, rect: rect)
    }

    private func drawOscShpBWaveShape(_ ctx: GraphicsContext, waveIndex: Int, shape: Int, rect: CGRect) {
        drawOscShapeWave(ctx, waveIndex: waveIndex, shape: shape, isShapeB: true, rect: rect)
    }

    /// Osc Sin Shape Graph (Draw) (GraphFunc 32) i Osc C Graph (Draw)
    /// (GraphFunc 18) mają identyczny przełącznik — ten sam zestaw prymitywów
    /// Waveform Graph ABC, OscC/OscShpB dokłada tylko Double Saw i Square.
    /// Wartość Shape trafia do prymitywów SUROWA (0…127): oryginał dzieli ją
    /// wewnątrz przez 127, 128 lub 256 — zależnie od kształtu.
    private func drawOscShapeWave(_ ctx: GraphicsContext,
                                  waveIndex: Int,
                                  shape: Int,
                                  isShapeB: Bool,
                                  rect: CGRect)
    {
        drawClaviaWaveShape(ctx, waveIndex: waveIndex, shape: shape, isShapeB: isShapeB, rect: rect)
    }

    /// Dzieli waveIndex (0…7, OscShpA ma tylko 0…5) na prymitywy Clavii. Wspólne dla
    /// ekranu wykresu (kolor/grubość domyślne) i ikon selektora (kolor/grubość z listy
    /// PartSelector) — jeden wiersz wywołania na miejsce, żeby oba renderowały to samo.
    private func drawClaviaWaveShape(_ ctx: GraphicsContext,
                                     waveIndex: Int,
                                     shape: Int,
                                     isShapeB: Bool,
                                     rect: CGRect,
                                     color: Color = UIColor.graphLine,
                                     lineWidth: CGFloat = UIMetrics.graphLineWidth)
    {
        switch waveIndex {
        case 0: claviaDualSine(ctx, phase: 0.25, shape: shape, rect: rect, color: color, lineWidth: lineWidth)
        case 1: claviaDualSine(ctx, phase: 0.0, shape: shape, rect: rect, color: color, lineWidth: lineWidth)
        case 2: claviaDsf(ctx, harmonic: 1, shape: shape, rect: rect, color: color, lineWidth: lineWidth)
        case 3: claviaDsf(ctx, harmonic: 2, shape: shape, rect: rect, color: color, lineWidth: lineWidth)
        case 4: claviaTweekTri(ctx, shape: shape, rect: rect, color: color, lineWidth: lineWidth)
        case 5 where isShapeB: claviaDoubleSaw(ctx, shape: shape, rect: rect, color: color, lineWidth: lineWidth)
        case 6 where isShapeB: claviaSquare(ctx, shape: shape, rect: rect, color: color, lineWidth: lineWidth)
        case 7 where isShapeB: claviaPulse(ctx, shape: shape, rect: rect, color: color, lineWidth: lineWidth)
        case 5: claviaPulse(ctx, shape: shape, rect: rect, color: color, lineWidth: lineWidth)
        default: claviaBlank(ctx, rect: rect, color: color, lineWidth: lineWidth)
        }
    }

    // MARK: - Prymitywy fal Clavii (Waveform Graph ABC)

    /// Polilinia jest liczona w pikselach panelu Gen1. Współczynniki kształtu
    /// (−2, −3, ×0.5, /127, /128 i /256) działają w tych jednostkach, dlatego
    /// dopiero gotowe punkty są skalowane do prostokąta Canvasu.
    private struct ClaviaWavePlot {
        let rect: CGRect
        let w: CGFloat
        let h: CGFloat
        private var path = Path()
        private var started = false

        init(rect: CGRect) {
            self.rect = rect
            w = max(6, rect.width / PatchLayout.bverhuePixelScale)
            h = max(6, rect.height / PatchLayout.bverhuePixelScale)
        }

        private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / w * rect.width,
                    y: rect.minY + y / h * rect.height)
        }

        mutating func line(_ x: CGFloat, _ y: CGFloat) {
            guard x.isFinite, y.isFinite else { return }
            if started { path.addLine(to: point(x, y)) } else {
                path.move(to: point(x, y))
                started = true
            }
        }

        mutating func move(_ x: CGFloat, _ y: CGFloat) {
            guard x.isFinite, y.isFinite else { return }
            path.move(to: point(x, y))
            started = true
        }

        var result: Path {
            path
        }
    }

    /// Oryginał rzutuje każdą współrzędną float→int, bo rysuje do bitmapy o rozmiarze
    /// ekranu (jeden punkt = jeden piksel panelu). U nas rysunek jest wektorowy
    /// i skalowalny, więc **świadomie pomijamy te zaokrąglenia**: zostawione dawały
    /// schodki przy powiększeniu i skokowe przeskoki fali przy kręceniu gałką Shape
    /// (kształt przeskakiwał dopiero co pełny piksel panelu). Okresy, ograniczenia
    /// i wzór DSF pozostają bez zmian, natomiast współrzędne zachowują część ułamkową.
    /// Krok próbkowania podpikselowego dla fal liczonych punkt po punkcie.
    private static let claviaWaveSampleStep: CGFloat = 0.2

    /// Oryginał rysuje do bitmapy `fScratchPad` o rozmiarze wykresu, więc wszystko
    /// poza ekranem jest przycięte. `DrawDualSine` zaczyna świadomie przed lewą
    /// krawędzią, dlatego bez tego przycięcia fala wychodziłaby na panel.
    private func strokeClaviaWave(
        _ ctx: GraphicsContext, _ plot: ClaviaWavePlot, rect: CGRect,
        color: Color = UIColor.graphLine, lineWidth: CGFloat = UIMetrics.graphLineWidth
    ) {
        // Prymitywy zostawiają tylko ~1 jednostkę Gen1px marginesu (mimikra oryginalnej,
        // dokładnie jednopikselowej linii) — przy grubszym, skalowalnym obrysie (zwłaszcza
        // powiększonym `hoverScale` na liście rozwijanej) zaokrąglona końcówka linii wychodziła
        // poza tę wąską rezerwę i była ucinana przez przycięcie do `rect` (płaski, ścięty
        // wierzchołek u góry/dołu ekranu). Przycinamy więc do rect powiększonego o połowę
        // szerokości linii — sam przebieg nadal mieści się w oryginalnym marginesie, tylko
        // krawędź obrysu ma gdzie się zaokrąglić.
        var clipped = ctx
        clipped.clip(to: Path(rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)))
        clipped.stroke(plot.result, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
    }

    /// `DrawDualSine` — dwie połówki sinusa o różnych okresach. Shape przesuwa
    /// podział między nimi (ratio 0.1…1.9), przez co symetryczna sinusoida
    /// przechodzi w falę o długim zboczu i krótkim powrocie.
    /// `phase`: 0.25 dla pierwszej fali selektora, 0.0 dla drugiej.
    private func claviaDualSine(
        _ ctx: GraphicsContext, phase: CGFloat, shape: Int, rect: CGRect,
        color: Color = UIColor.graphLine, lineWidth: CGFloat = UIMetrics.graphLineWidth
    ) {
        var plot = ClaviaWavePlot(rect: rect)
        let w = plot.w, h = plot.h
        let span = w - 2
        guard span > 2 else { return }
        // this[0x8c] == 4 (konstruktor Waveform Graph ABC) → grupa masek 0x15.
        let offset: CGFloat = 1
        let ratio = min(max(CGFloat(shape) / 127.0 + 1.0, 0.1), 1.9)
        let spanA = ratio * span
        let spanB = (2.0 - ratio) * span
        guard spanA > 0.5, spanB > 0.5 else { return }
        let stepA = 2 * Double.pi / Double(spanA)
        let stepB = 2 * Double.pi / Double(spanB)
        let phaseA = -spanA * phase
        let phaseB = -spanB * (phase + 0.5)
        let amp = (h - 3) * 0.5
        let sample = Self.claviaWaveSampleStep

        var x = phase * spanB - w
        plot.move(x, (h - 1) * 0.5)
        var cycles = 0
        while x < w - 1, cycles < 8 {
            cycles += 1
            for (halfSpan, halfStep, halfPhase) in [(spanA, stepA, phaseA), (spanB, stepB, phaseB)] {
                var i: CGFloat = 0
                while i <= halfSpan * 0.5 {
                    let y = abs((1 - CGFloat(sin(Double(i - halfPhase) * halfStep))) * amp + offset)
                    plot.line(x + i, y)
                    i += sample
                }
                x += halfSpan * 0.5
            }
        }
        strokeClaviaWave(ctx, plot, rect: rect, color: color, lineWidth: lineWidth)
    }

    /// `DrawDsf` — klasyczna suma dyskretna sin(t)/(1 + a² − 2a·cos(m·t)),
    /// gdzie a = Shape/128, a m to numer harmonicznej (1 lub 2). Amplituda to
    /// ćwiartka wysokości, bo przy a→1 wartości uciekają i są obcinane do ramki.
    private func claviaDsf(
        _ ctx: GraphicsContext, harmonic: Int, shape: Int, rect: CGRect,
        color: Color = UIColor.graphLine, lineWidth: CGFloat = UIMetrics.graphLineWidth
    ) {
        var plot = ClaviaWavePlot(rect: rect)
        let w = plot.w, h = plot.h
        let period = w - 2
        guard period > 1 else { return }
        let a = CGFloat(shape) / 128.0
        let mid = h / 2
        let amp = mid * 0.5
        var x: CGFloat = 0
        while x < w - 1 {
            let t = Double(x / period) * 2 * Double.pi
            let denominator = cos(t * Double(harmonic)) * Double(-2 * a) + 1 + Double(a * a)
            let raw = CGFloat(sin(t) / denominator) * amp
            // Przy a → 1 mianownik dąży do zera i wartości uciekają poza ekran —
            // oryginał obcina je do ramki i to obcięcie widać jako płaskie szczyty.
            let value = min(max(raw.isFinite ? mid + raw : h - 1, 2), h - 1)
            plot.line(x, h - value)
            x += Self.claviaWaveSampleStep
        }
        strokeClaviaWave(ctx, plot, rect: rect, color: color, lineWidth: lineWidth)
    }

    /// `DrawTweekTri` — trójkąt o przesuwanych wierzchołkach. k = 1 + Shape/128:
    /// przy k=1 wierzchołki są w ¼ i ¾ okresu (symetryczny trójkąt), przy k→2
    /// zbiegają się do krawędzi i fala staje się opadającą piłą.
    private func claviaTweekTri(
        _ ctx: GraphicsContext, shape: Int, rect: CGRect,
        color: Color = UIColor.graphLine, lineWidth: CGFloat = UIMetrics.graphLineWidth
    ) {
        var plot = ClaviaWavePlot(rect: rect)
        let w = plot.w, h = plot.h
        let span = w - 2
        guard span > 1 else { return }
        let quarter = span * 0.25
        let half = quarter + quarter
        let peak = quarter * (CGFloat(shape) / 128.0 + 1.0)
        let midY = h * 0.5 - 1
        let bottom = h - 2
        var x: CGFloat = 0
        plot.move(x, midY)
        while x < span {
            plot.line(x + half - peak, 1)
            plot.line(x + half + peak, bottom)
            x += span
            plot.line(x, midY)
        }
        strokeClaviaWave(ctx, plot, rect: rect, color: color, lineWidth: lineWidth)
    }

    /// `DrawPulse` — impuls o szerokości span·(0.5 − Shape/256): góra, dół tej
    /// samej długości, a resztę okresu wypełnia linia środkowa. Shape=0 daje
    /// zwykły prostokąt 50%, Shape=127 wąską iglicę na linii zera.
    private func claviaPulse(
        _ ctx: GraphicsContext, shape: Int, rect: CGRect,
        color: Color = UIColor.graphLine, lineWidth: CGFloat = UIMetrics.graphLineWidth
    ) {
        var plot = ClaviaWavePlot(rect: rect)
        let w = plot.w, h = plot.h
        let span = w - 2
        guard span > 1 else { return }
        let pulse = span * 0.5 - CGFloat(shape) / 256.0 * span
        let midY = h * 0.5 - 1
        let bottom = h - 2
        var x: CGFloat = 0
        plot.move(x, midY)
        while x < span {
            plot.line(x, 1)
            let rise = x + pulse
            plot.line(rise, 1)
            plot.line(rise, bottom)
            let fall = x + pulse + pulse
            plot.line(fall, bottom)
            plot.line(fall, midY)
            x += span
            plot.line(x, midY)
        }
        strokeClaviaWave(ctx, plot, rect: rect, color: color, lineWidth: lineWidth)
    }

    /// `DrawSquare` — prostokąt o wypełnieniu span·(1 + Shape/128)/2.
    private func claviaSquare(
        _ ctx: GraphicsContext, shape: Int, rect: CGRect,
        color: Color = UIColor.graphLine, lineWidth: CGFloat = UIMetrics.graphLineWidth
    ) {
        var plot = ClaviaWavePlot(rect: rect)
        let w = plot.w, h = plot.h
        let span = w - 2
        guard span > 1 else { return }
        let high = span * (CGFloat(shape) / 128.0 + 1.0) * 0.5
        let bottom = h - 4
        var x: CGFloat = 0
        plot.move(x, 1)
        while x < span {
            plot.line(x, 1)
            let edge = x + high
            plot.line(edge, 1)
            plot.line(edge, bottom)
            x += span
            plot.line(x, bottom)
            plot.line(x, 1)
        }
        strokeClaviaWave(ctx, plot, rect: rect, color: color, lineWidth: lineWidth)
    }

    /// `DrawDoubleSaw` — dwie opadające piły przecinające linię środkową;
    /// Shape przesuwa fazę drugiej względem pierwszej.
    private func claviaDoubleSaw(
        _ ctx: GraphicsContext, shape: Int, rect: CGRect,
        color: Color = UIColor.graphLine, lineWidth: CGFloat = UIMetrics.graphLineWidth
    ) {
        var plot = ClaviaWavePlot(rect: rect)
        let w = plot.w, h = plot.h
        let right = w - 2
        guard right > 2 else { return }
        let quarter = (h - 3) * 0.25
        let halfSpan = quarter + quarter
        let quarterSpan = halfSpan / 2
        let sample = Self.claviaWaveSampleStep
        let slope = halfSpan / w * sample
        let baseY = halfSpan + 1
        var offset = (CGFloat(shape) / 127.0 - 1.0) * quarterSpan
        var ramp = quarterSpan

        // Linia bazowa (BackLineTo) — oryginał kreśli ją przed obiema piłami, zunifikowanym
        // kolorem `graphBaseline` (ten sam co 0dB/oś zera na innych ekranach wykresów),
        // wyraźnie przygaszonym względem właściwej fali — nie tym samym `color`, inaczej
        // wygląda jak zbędna, dodatkowa kreska na fali.
        var baseline = ClaviaWavePlot(rect: rect)
        baseline.move(1, baseY)
        baseline.line(right, baseY)
        strokeClaviaWave(ctx, baseline, rect: rect, color: UIColor.graphBaseline.opacity(0.75), lineWidth: 0.5)

        let bias = halfSpan * abs(2 * CGFloat(shape) / 127.0 - 1) / 3.0
        plot.move(1, halfSpan * 0.5 + baseY + bias)
        var x: CGFloat = 1
        while x < right {
            plot.line(x, baseY - (ramp + offset))
            if offset <= -quarterSpan {
                plot.line(x, baseY - (ramp + quarterSpan))
                offset = quarterSpan
            }
            ramp -= slope
            offset -= slope
            x += sample
        }
        strokeClaviaWave(ctx, plot, rect: rect, color: color, lineWidth: lineWidth)
    }

    /// `DrawBlank` — pozioma linia na wysokości zera dla nieznanego kształtu.
    private func claviaBlank(
        _ ctx: GraphicsContext, rect: CGRect,
        color: Color = UIColor.graphLine, lineWidth: CGFloat = UIMetrics.graphLineWidth
    ) {
        var plot = ClaviaWavePlot(rect: rect)
        let midY = plot.h * 0.5 - 1
        plot.move(1, midY)
        plot.line(plot.w - 3, midY)
        strokeClaviaWave(ctx, plot, rect: rect, color: color, lineWidth: lineWidth)
    }

    /// Waveform Graph ABC (DrawDualSine): Shape przesuwa podział obu połówek
    /// sinusoidy, zachowując jeden okres i wysokość wykresu.
    private func drawDualSineShape(_ ctx: GraphicsContext, firstHalf: CGFloat, shape: CGFloat, rect: CGRect) {
        let split = min(max(firstHalf + shape * 0.20, 0.25), 0.75)
        drawSampledOscWave(ctx, rect: rect) { t in
            let phase: CGFloat = if t <= split {
                0.5 * t / split
            } else {
                0.5 + 0.5 * (t - split) / (1 - split)
            }
            return CGFloat(sin(Double(phase) * 2.0 * .pi))
        }
    }

    /// Przybliżenie trójkąta dla PulseOsc (Pulse Osc Graph ma własne
    /// implementacje rysowania — nie dzieli ich z Waveform Graph ABC).
    private func drawTweakedTriangleShape(_ ctx: GraphicsContext, shape: CGFloat, rect: CGRect) {
        let x0 = rect.minX
        let x1 = rect.maxX
        let amp = rect.height * 0.42
        let peak = min(max(0.50 + shape * 0.24, 0.16), 0.84)
        var path = Path()
        path.move(to: CGPoint(x: x0, y: rect.midY + amp))
        path.addLine(to: CGPoint(x: x0 + rect.width * peak, y: rect.midY - amp))
        path.addLine(to: CGPoint(x: x1, y: rect.midY + amp))
        strokeGraphPath(ctx, path)
    }

    /// Przybliżenie prostokąta dla PulseOsc (patrz uwaga przy trójkącie wyżej).
    private func drawPulseShape(_ ctx: GraphicsContext, duty: CGFloat, rect: CGRect) {
        let clampedDuty = min(max(duty, 0.10), 0.90)
        let x0 = rect.minX
        let x1 = rect.maxX
        let high = rect.midY - rect.height * 0.42
        let low = rect.midY + rect.height * 0.42
        let edge = x0 + rect.width * clampedDuty
        var path = Path()
        path.move(to: CGPoint(x: x0, y: low))
        path.addLine(to: CGPoint(x: x0, y: high))
        path.addLine(to: CGPoint(x: edge, y: high))
        path.addLine(to: CGPoint(x: edge, y: low))
        path.addLine(to: CGPoint(x: x1, y: low))
        strokeGraphPath(ctx, path)
    }

    /// `amplitudeFraction` — połowa rozpiętości przebiegu jako ułamek wysokości ekranu.
    /// Domyślne 0,42 to nasz starszy, „bezpieczny" margines dla oscylatorów; ekrany LFO
    /// używają 0,5, bo Waveform Graph ABC rysuje je od krawędzi do krawędzi.
    private func drawSampledOscWave(_ ctx: GraphicsContext,
                                    rect: CGRect,
                                    amplitudeFraction: CGFloat = 0.42,
                                    color: Color = UIColor.graphLine,
                                    lineWidth: CGFloat = UIMetrics.graphLineWidth,
                                    sample: (CGFloat) -> CGFloat)
    {
        // Gęstość próbek nie zależy od rozmiaru ekranu na panelu, tylko od tego, jak
        // gładko ma wyglądać krzywa po powiększeniu canvasu — stąd stała, wysoka
        // wartość zamiast „jedna próbka na piksel panelu" jak w oryginale.
        let samples = 480
        // Fale LFO idą pełną wysokością ekranu (amplitudeFraction 0.5) — bez zapasu
        // pół grubości krzywej ich szczyty leżałyby dokładnie na krawędzi i traciły
        // połowę grubości (patrz `drawLfoShpAWaveShape`).
        let amplitude = max(0, rect.height * amplitudeFraction - lineWidth / 2)
        var path = Path()
        for index in 0 ... samples {
            let t = CGFloat(index) / CGFloat(samples)
            let point = CGPoint(x: rect.minX + rect.width * t,
                                y: rect.midY - sample(t) * amplitude)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        strokeGraphPath(ctx, path, color: color, lineWidth: lineWidth)
    }

    // MARK: - PartSelector wave images

    /// FltLP/FltHP mają sześciopozycyjny selektor trybu osadzony przy żywym wykresie.
    func isSmallFilterSlopeSelector(moduleTypeID: Int, selector: BVPartSelector) -> Bool {
        let shortName = moduleDefinition(moduleTypeID)?.shortName ?? ""
        return (shortName == "FltLP" || shortName == "FltHP")
            && !selector.usesParameter
            && selector.codeRef == 0
            && selector.imageCount == 6
    }

    /// Rozpoznaje selektory fal po nazwie pola domenowego, a nie po liczbie obrazków.
    /// Dzięki temu np. siedmiopozycyjny wybór zakresu Delay nie udaje listy fal.
    func isWavePartSelector(moduleTypeID: Int, selector: BVPartSelector) -> Bool {
        guard let definition = moduleDefinition(moduleTypeID) else { return false }
        let names = selector.usesParameter ? definition.paramNames : definition.modeNames
        guard names.indices.contains(selector.codeRef) else { return false }
        return names[selector.codeRef].localizedCaseInsensitiveContains("wave")
    }

    /// Czterostanowy `Type` z PM Driver ma własny atlas (`Reed/Bow/Lip/Malet`).
    /// Nie jest selektorem fal, ale ekran i rozwinięta lista korzystają z tego
    /// samego wektorowego renderera, więc traktujemy go jak selektor graficzny.
    func isPMDriverPartSelector(moduleTypeID: Int, selector: BVPartSelector) -> Bool {
        moduleDefinition(moduleTypeID)?.shortName == "Driver"
            && !selector.usesParameter
            && selector.codeRef == 0
            && selector.imageCount == 4
    }

    /// Nazwy z definicji parametrów G2 (g2ools `params.py`). Dla dodatkowych modułów,
    /// które nie mają publicznej tabeli nazw, dymek pozostaje jednoznaczny i numerowany.
    func waveSelectorLabel(moduleTypeID: Int, value: Int, optionCount: Int) -> String {
        let shortName = moduleDefinition(moduleTypeID)?.shortName ?? ""
        if shortName == "Driver" {
            let labels = ["Reed", "Bow", "Lip", "Malet"]
            return labels[min(max(value, 0), labels.count - 1)]
        }
        if shortName == "FltLP" || shortName == "FltHP" {
            return "\((min(5, max(0, value)) + 1) * 6) dB/Oct"
        }
        let labels: [String] = switch shortName {
        case "LfoC":
            ["Sine", "Triangle", "Saw", "Square", "Random Step", "Random",
             "Random Pulse", "Rounded Random Pulse"]
        case "OscShpB":
            ["Sine 1", "Sine 2", "Sine 3", "Sine 4", "Triangle/Saw",
             "Double Saw", "Pulse", "Symmetric Pulse"]
        case "OscC", "OscD":
            ["Sine", "Triangle", "Saw", "Square", "Pulse 25%", "Pulse 10%"]
        case "OscPM":
            ["Sine", "Triangle"]
        case "RndPattern":
            ["Step", "Pulse"]
        case "SyncOsc":
            ["Sine", "Triangle", "Saw", "Square"]
        default:
            []
        }
        if labels.indices.contains(value) { return labels[value] }
        return "Wave \(min(max(value, 0), max(optionCount - 1, 0)) + 1)"
    }

    /// Wektorowe odtworzenie czterech klatek `Image:` z PM Driver. Nazwa jest
    /// częścią grafiki, a stany Lip/Malet dokładają czerwone krzywe modelu.
    /// Ta funkcja jest jedynym źródłem obrazu dla zamkniętego ekranu i menu.
    func drawPMDriverSelectorIcon(_ ctx: GraphicsContext,
                                  rect: CGRect,
                                  value: Int,
                                  color: Color,
                                  accentColor: Color,
                                  fontSize: CGFloat,
                                  inset: CGFloat = 1.0)
    {
        let index = min(3, max(0, value))
        let labels = ["Reed", "Bow", "Lip", "Malet"]
        let label = labels[index]
        // Napis dostaje CAŁY ekran — dokładnie tak jak pozostałe ekrany tekstowe,
        // więc font wypada tej samej wielkości. Inset dotyczy tylko krzywych.
        // Rozmiar PO dopasowaniu do ekranu — „Malet" nie mieści się w pełnym foncie,
        // a piksele przekreślenia muszą być z tej samej matrycy co litery.
        let fittedSize = drawLcdText(ctx, text: label, box: rect, fontSize: fontSize,
                                     color: color, centered: true)

        guard index >= 2 else { return }

        // Atlas Clavii przekreśla niedostępne tryby krzyżykiem z dwóch wygiętych
        // krzywych. Na ekranie LCD, gdzie piksel jest tej samej wielkości co piksel
        // litery, taki krzyżyk zasłaniał napis — zostaje jedna prosta ukośna.
        let line = rect.insetBy(dx: inset, dy: inset)
        drawLcdPixelLine(ctx,
                         from: CGPoint(x: line.minX, y: line.maxY),
                         to: CGPoint(x: line.maxX, y: line.minY),
                         in: line, fontSize: fittedSize, color: accentColor)
    }

    /// Rysuje odcinek kwadratowymi pikselami z matrycy Matrix Sans Screen — tego
    /// samego fontu, którym piszemy na ekranach. W .ttf każdy glif to zbiór
    /// kwadratów o boku 86/1000 em, rozstawionych co 100/1000 em; te same dwie
    /// liczby wyznaczają siatkę tutaj, więc czerwone przekreślenie PM Drivera jest
    /// z tej samej matrycy co napis pod nim, a nie gładką linią wektorową.
    /// Siatka jest zaczepiona w środku `rect`, żeby przy każdym zoomie wypadała
    /// symetrycznie względem ekranu.
    private func drawLcdPixelLine(_ ctx: GraphicsContext,
                                  from p0: CGPoint, to p1: CGPoint,
                                  in rect: CGRect,
                                  fontSize: CGFloat,
                                  color: Color)
    {
        struct Cell: Hashable { let col: Int
            let row: Int
        }

        let pitch = fontSize * 0.100
        let dot = fontSize * 0.086
        guard pitch > 0 else { return }

        // Krok próbkowania mniejszy od połowy komórki — przy rzadszym linia się rwie.
        var cells = Set<Cell>()
        let steps = max(24, Int((abs(p1.x - p0.x) + abs(p1.y - p0.y)) / (pitch / 2)))
        for i in 0 ... steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t)
            cells.insert(Cell(col: Int(((p.x - rect.midX) / pitch).rounded()),
                              row: Int(((p.y - rect.midY) / pitch).rounded())))
        }

        ctx.drawLayer { layer in
            layer.clip(to: Path(rect))
            for cell in cells {
                let center = CGPoint(x: rect.midX + CGFloat(cell.col) * pitch,
                                     y: rect.midY + CGFloat(cell.row) * pitch)
                layer.fill(Path(CGRect(x: center.x - dot / 2, y: center.y - dot / 2,
                                       width: dot, height: dot)),
                           with: .color(color))
            }
        }
    }

    /// Wektorowy odpowiednik stanów `Image:`. Wygląd oryginału służy wyłącznie jako
    /// referencja; ekran i lista korzystają z tych samych skalowalnych krzywych.
    func drawWaveSelectorIcon(_ ctx: GraphicsContext,
                              rect: CGRect,
                              moduleTypeID: Int,
                              value: Int,
                              color: Color,
                              lineWidth: CGFloat = UIMetrics.graphLineWidth,
                              infoFunc: Int = 0)
    {
        // Kształt obwiedni (InfoFunc 136) nie zależy od modułu — pięć modułów Env
        // dzieli ten sam zestaw czterech krzywych. To samo przesunięcie value→ikona
        // co na zamkniętym ekranie (drawBVPartSelectors), żeby lista pokazywała
        // dokładnie te obrazki, które po wyborze wskoczą na ekran.
        if infoFunc == 136 {
            drawEnvShapeIcon(ctx, rect: rect, shapeType: (value + 1) % 4,
                             color: color, lw: lineWidth, solidFill: true)
            return
        }
        let shortName = moduleDefinition(moduleTypeID)?.shortName ?? ""
        switch shortName {
        case "FltLP", "FltHP":
            drawSmallFilterSlopeIcon(ctx, rect: rect, slopeMode: value,
                                     highPass: shortName == "FltHP",
                                     color: color, lineWidth: lineWidth)
        case "LfoC":
            drawWaveIcon(ctx, rect: rect, infoFunc: 200, waveIndex: value,
                         color: color, lw: lineWidth)
        case "OscShpB":
            drawOscShpBSelectorIcon(ctx, rect: rect, value: value, color: color, lineWidth: lineWidth)
        case "RndPattern":
            drawRandomPatternSelectorIcon(ctx, rect: rect, value: value, color: color, lineWidth: lineWidth)
        default:
            drawWaveIcon(ctx, rect: rect, infoFunc: 0, waveIndex: value,
                         color: color, lw: lineWidth)
        }

        // OscC/OscD: dwa ostatnie obrazy PartSelectora zawierają w oryginalnym
        // panelu cyfry „25” i „10”, wskazujące wypełnienie krótkiego impulsu.
        // Rysuj je niezależnie od skali zarówno w zamkniętym selektorze, jak i na
        // każdej pozycji rozwiniętej listy.
        let dutyLabel: String? = switch (shortName, value) {
        case ("OscC", 4), ("OscD", 4):
            "25"
        case ("OscC", 5), ("OscD", 5):
            "10"
        default:
            nil
        }
        if let dutyLabel {
            let fontSize = min(rect.height * 0.42, rect.width * 0.30)
            ctx.draw(
                Text(dutyLabel)
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(color),
                at: CGPoint(x: rect.maxX - rect.width * 0.03,
                            y: rect.minY + rect.height * 0.04),
                anchor: .topTrailing
            )
        }
    }

    /// Wektorowy odpowiednik sześciu ikon menu slope z oryginalnego panelu.
    /// Cyfra jest częścią ikony; pełnego opisu „dB/Oct” nie pokazujemy w menu.
    private func drawSmallFilterSlopeIcon(_ ctx: GraphicsContext, rect: CGRect,
                                          slopeMode: Int, highPass: Bool,
                                          color: Color, lineWidth: CGFloat)
    {
        let index = min(5, max(0, slopeMode))
        let slopeValue = (index + 1) * 6
        let baselineY = rect.minY + rect.height * 0.25
        let bottomY = rect.minY + rect.height * 0.86
        let left = rect.minX + rect.width * 0.04
        let kneeX = highPass
            ? rect.minX + rect.width * 0.52
            : rect.minX + rect.width * 0.24
        let endX = highPass
            ? rect.minX + rect.width * (0.04 + CGFloat(index) * 0.06)
            : rect.minX + rect.width * (0.70 - CGFloat(index) * 0.06)
        let lineEndX = rect.minX + rect.width * 0.70

        var icon = Path()
        if highPass {
            icon.move(to: CGPoint(x: endX, y: bottomY))
            icon.addCurve(
                to: CGPoint(x: kneeX, y: baselineY),
                control1: CGPoint(x: endX, y: rect.minY + rect.height * 0.52),
                control2: CGPoint(x: kneeX, y: baselineY)
            )
            icon.addLine(to: CGPoint(x: lineEndX, y: baselineY))
        } else {
            icon.move(to: CGPoint(x: left, y: baselineY))
            icon.addLine(to: CGPoint(x: kneeX, y: baselineY))
            icon.addCurve(
                to: CGPoint(x: endX, y: bottomY),
                control1: CGPoint(x: kneeX, y: baselineY),
                control2: CGPoint(x: endX, y: rect.minY + rect.height * 0.52)
            )
        }
        ctx.stroke(icon, with: .color(color),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

        let numberBox = CGRect(x: rect.minX + rect.width * 0.72,
                               y: rect.minY + rect.height * 0.04,
                               width: rect.width * 0.26,
                               height: rect.height * 0.44)
        drawLcdText(ctx, text: String(slopeValue), box: numberBox,
                    fontSize: UIFont.lcdDisplay(boxHeight: numberBox.height),
                    color: color, centered: true)
    }

    /// Reprezentatywna wartość Shape dla ikon-podglądów listy/przycisków (nie ekranu
    /// wykresu — tam zawsze prawdziwa wartość gałki). Shape=0 wygląda naturalnie jako
    /// „neutralny" wybór, ale w Dsf a=Shape/128=0 zeruje różnicę między harmonicznymi
    /// (mianownik 1+a²−2a·cos(m·t) nie zależy wtedy od m) — Dsf(1) i Dsf(2) byłyby
    /// nierozróżnialnymi ikonami. 64 (wyświetlane jako „75%” — TextFunc 126:
    /// `50 + 50·Shape/128`) pokazuje wyraźnie ukształtowane, łatwo odróżnialne
    /// warianty wszystkich fal (mocniej niż poprzednie 32/„62%”), na tyle daleko od
    /// skrajów (0%/99%), żeby żaden kształt nie spłaszczał się do zdegenerowanego
    /// przypadku granicznego.
    private static let claviaIconShape = 64

    /// Ikony listy PartSelector = miniatury tych samych prymitywów co ekran wykresu
    /// (GraphFunc 18, `drawClaviaWaveShape`). Do 2026-08-11 rysowały tu inne,
    /// przybliżone kształty (N-cykli sinusa dla wartości 0…3, cudzy zestaw ikon
    /// OscA/OscB dla 4…7) — nie odpowiadały żadnej z ośmiu rzeczywistych fal OscShpB.
    private func drawOscShpBSelectorIcon(_ ctx: GraphicsContext,
                                         rect: CGRect,
                                         value: Int,
                                         color: Color,
                                         lineWidth: CGFloat)
    {
        drawClaviaWaveShape(ctx, waveIndex: value, shape: Self.claviaIconShape, isShapeB: true, rect: rect,
                            color: color, lineWidth: lineWidth)
    }

    private func drawRandomPatternSelectorIcon(_ ctx: GraphicsContext,
                                               rect: CGRect,
                                               value: Int,
                                               color: Color,
                                               lineWidth: CGFloat)
    {
        if value == 0 {
            drawRandomPatternStepIcon(ctx, rect: rect, color: color, lineWidth: lineWidth)
        } else {
            drawRandomPatternPulseIcon(ctx, rect: rect, color: color, lineWidth: lineWidth)
        }
    }

    /// „Step" (wartość 0): nieregularny przebieg schodkowy — losowy wzór poziomów
    /// sekwencera, każda kolumna to jeden krok. Kształt odtworzony ze zrzutu
    /// dostarczonego przez użytkownika (16 kroków, dwa wysokie szczyty przesunięte
    /// w lewo od środka, potem schodkowe opadanie z małym garbem przy końcu).
    /// Sama linia (bez wypełnienia, bez podstawy na dole) — poprawione 2026-08-21:
    /// pierwsza wersja zamykała kontur do dołu i wypełniała, czego oryginał nie ma.
    private func drawRandomPatternStepIcon(_ ctx: GraphicsContext, rect: CGRect,
                                           color: Color, lineWidth: CGFloat)
    {
        let heights: [CGFloat] = [
            0.35, 0.35, 0.55, 0.28, 0.95, 0.95, 0.78, 0.62,
            0.62, 0.42, 0.28, 0.42, 0.28, 0.15, 0.15, 0.25,
        ]
        let colW = rect.width / CGFloat(heights.count)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * heights[0]))
        for i in heights.indices {
            let xEnd = rect.minX + CGFloat(i + 1) * colW
            let y = rect.maxY - rect.height * heights[i]
            path.addLine(to: CGPoint(x: xEnd, y: y))
            if i + 1 < heights.count {
                path.addLine(to: CGPoint(x: xEnd, y: rect.maxY - rect.height * heights[i + 1]))
            }
        }
        ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    /// „Pulse" (wartość 1): rząd pionowych kresek JEDNAKOWEJ wysokości na wspólnej
    /// podstawie (podkreślenie na dole) — wzorzec bramek, nie poziomów. Poprawione
    /// 2026-08-21: użytkownik potwierdził wszystkie kreski tej samej wysokości
    /// (pierwsza wersja miała jedną skróconą, błędnie odczytaną ze zrzutu).
    private func drawRandomPatternPulseIcon(_ ctx: GraphicsContext, rect: CGRect,
                                            color: Color, lineWidth: CGFloat)
    {
        // Ta sama grubość co reszta ekranów w aplikacji (`lineWidth`, domyślnie
        // `UIMetrics.graphLineWidth`) — poprzednia wersja pogrubiała kreski do
        // `rect.width * 0.045`, wyraźnie grubszej niż wszędzie indziej.
        let tickX: [CGFloat] = [0.06, 0.22, 0.30, 0.38, 0.52, 0.66, 0.72, 0.86, 0.94]
        let ticks = tickX.map { (x: $0, h: CGFloat(0.75)) }
        var baseline = Path()
        let baselineY = rect.maxY - lineWidth / 2
        baseline.move(to: CGPoint(x: rect.minX, y: baselineY))
        baseline.addLine(to: CGPoint(x: rect.maxX, y: baselineY))
        ctx.stroke(baseline, with: .color(color), lineWidth: lineWidth)
        for tick in ticks {
            let x = rect.minX + rect.width * tick.x
            var line = Path()
            line.move(to: CGPoint(x: x, y: rect.maxY))
            line.addLine(to: CGPoint(x: x, y: rect.maxY - rect.height * tick.h))
            ctx.stroke(line, with: .color(color), lineWidth: lineWidth)
        }
    }

    // MARK: - Envelope shape icons (infoFunc 136)

    /// Rysuje wektorową ikonę kształtu koperty dla PartSelectora i dropdownu.
    /// shapeType: 0=LinLin (trójkąt), 1=LogExp (kopuła), 2=LinExp (prosta+krzywa), 3=ExpExp (szpic Λ)
    /// solidFill=true: pełne wypełnienie bez obrysu (ekranik PartSelector).
    /// solidFill=false: wypełnienie 42% opacity + obrys (dropdown).
    func drawEnvShapeIcon(_ ctx: GraphicsContext, rect: CGRect,
                          shapeType: Int, color: Color, lw: CGFloat,
                          solidFill: Bool = false)
    {
        // Margines tylko dla wariantu z obrysem — pół grubości linii, żeby kreska nie
        // wychodziła poza pole. Wypełnienie bez obrysu (ekranik) korzysta z całego
        // prostokąta: przy polu ~10×5pt każde pół punktu z każdej strony było widocznym
        // ubytkiem wielkości kształtu.
        let inset: CGFloat = solidFill ? 0 : 0.5
        let x0 = rect.minX + inset
        let xPeak = rect.midX // wierzchołek wycentrowany względem podstawy
        let xEnd = rect.maxX - inset
        let yBase = rect.maxY - inset
        let yPeak = rect.minY + inset

        var path = Path()
        path.move(to: CGPoint(x: x0, y: yBase))

        switch shapeType % 4 {
        case 0: // LinLin — prosta góra, prosta dół (symetryczny trójkąt)
            path.addLine(to: CGPoint(x: xPeak, y: yPeak))
            path.addLine(to: CGPoint(x: xEnd, y: yBase))

        case 1: // LogExp — gwałtowne wzniesienie (Exp D), eksponencjalny spadek
            path.addQuadCurve(to: CGPoint(x: xPeak, y: yPeak),
                              control: CGPoint(x: x0, y: yPeak))
            path.addQuadCurve(to: CGPoint(x: xEnd, y: yBase),
                              control: CGPoint(x: xPeak, y: yBase))

        case 2: // LinExp — liniowy atak, eksponencjalny spadek
            path.addLine(to: CGPoint(x: xPeak, y: yPeak))
            path.addQuadCurve(to: CGPoint(x: xEnd, y: yBase),
                              control: CGPoint(x: xPeak, y: yBase))

        default: // 3: ExpExp — wolny start, strzela ku górze, eksponencjalny spadek
            path.addCurve(to: CGPoint(x: xPeak, y: yPeak),
                          control1: CGPoint(x: x0 + (xPeak - x0) * 0.88, y: yBase),
                          control2: CGPoint(x: xPeak, y: yPeak + (yBase - yPeak) * 0.05))
            path.addQuadCurve(to: CGPoint(x: xEnd, y: yBase),
                              control: CGPoint(x: xPeak, y: yBase))
        }

        path.closeSubpath()
        if solidFill {
            // Ekranik: pełne wypełnienie kolorem LCD, bez obrysu
            ctx.fill(path, with: .color(color))
        } else {
            // Dropdown: półprzezroczyste wypełnienie + obrys
            ctx.fill(path, with: .color(color.opacity(0.42)))
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Power icon (Active parameter)

    func drawPowerIcon(_ ctx: GraphicsContext, in rect: CGRect, isOn: Bool) {
        let cx = rect.midX
        let cy = rect.midY + rect.height * 0.08 // lekko w dół żeby zmieścić linię
        let r = min(rect.width, rect.height) * 0.30
        let color: Color = isOn ? UIColor.powerIconOn : UIColor.powerIconOff
        let lw: CGFloat = 0.65

        // Okrąg z luką na górze (od -50° do 230°)
        var arc = Path()
        arc.addArc(center: CGPoint(x: cx, y: cy),
                   radius: r,
                   startAngle: .degrees(-50), endAngle: .degrees(230),
                   clockwise: false)
        ctx.stroke(arc, with: .color(color),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round))

        // Pionowa kreska w górę — przez lukę
        var stem = Path()
        stem.move(to: CGPoint(x: cx, y: cy - r * 1.35))
        stem.addLine(to: CGPoint(x: cx, y: cy - r * 0.25))
        ctx.stroke(stem, with: .color(color),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round))
    }

    // MARK: - ButtonRadio pixel icon renderer

    /// Tworzy NSImage z danych pikselowych dla jednej ikony przycisku radio.
    /// Biały (ffffff) = przezroczysty; czarny (000000) = kolor ikony; szary (a0a0a0) = półton.
    func makeRadioButtonImage(pixels: [String], iconW: Int, iconH: Int,
                              buttonCount _: Int, index: Int,
                              selected: Bool,
                              tint: (UInt8, UInt8, UInt8)? = nil) -> NSImage
    {
        // Kolor ikony: tint jeśli podany; inaczej biały gdy zaznaczony, ciemnoszary gdy nie
        let r: UInt8 = tint?.0 ?? (selected ? 255 : 30)
        let g: UInt8 = tint?.1 ?? (selected ? 255 : 30)
        let b: UInt8 = tint?.2 ?? (selected ? 255 : 30)

        // Ikony są przechowywane SEKWENCYJNIE w Image: (icon0 blok, icon1 blok, …)
        // Każda ikona zajmuje iconW × iconH pikseli jeden po drugim.
        let base = index * iconW * iconH

        var rgba = [UInt8](repeating: 0, count: iconW * iconH * 4)
        for row in 0 ..< iconH {
            for col in 0 ..< iconW {
                let srcIdx = base + row * iconW + col
                guard srcIdx < pixels.count else { continue }
                let hex = pixels[srcIdx]
                let dstIdx = (row * iconW + col) * 4
                // Tło .txt ma różne jasne kolory: ffffff, e6e6e6, bdbebd itp.
                // Piksele ikon: 000000, 008080, a0a0a0, 292829 i inne ciemne/kolorowe.
                // Reguła: wszystkie kanały >= 180 → tło (przezroczysty); reszta → ikona.
                if hex.count == 6,
                   let rv = UInt8(hex.prefix(2), radix: 16),
                   let gv = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
                   let bv = UInt8(hex.suffix(2), radix: 16),
                   !(rv >= 180 && gv >= 180 && bv >= 180)
                {
                    let alpha: UInt8 = min(rv, min(gv, bv)) < 100 ? 255 : 160
                    rgba[dstIdx] = r
                    rgba[dstIdx + 1] = g
                    rgba[dstIdx + 2] = b
                    rgba[dstIdx + 3] = alpha
                } else {
                    rgba[dstIdx] = 0
                    rgba[dstIdx + 1] = 0
                    rgba[dstIdx + 2] = 0
                    rgba[dstIdx + 3] = 0
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let cgImg = CGImage(
                  width: iconW, height: iconH,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: iconW * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent
              )
        else {
            return NSImage(size: NSSize(width: iconW, height: iconH))
        }

        return NSImage(cgImage: cgImg, size: NSSize(width: iconW, height: iconH))
    }

    // MARK: - Module header color (page color + user override)

    /// Zwraca kolor nagłówka modułu: user override (module.color 1–24) lub kolor strony.
    /// Źródło: ModuleColors[0..24] z BVE.NMG2Types.pas, format Delphi $00BBGGRR.
    /// Indeks 0 = brak koloru użytkownika → fallback na kolor kategorii (pageColor).
    func moduleHeaderColor(_ module: G2Module, def: ModuleDef?) -> Color {
        switch module.color {
        // Domyślny: szary panel; ikonka trójkąta bierze kolor kategorii.
        case 0: UIColor.modulePanelGray
        case 1 ... 24: ModuleColorPalette.color(module.color)
        default: pageColor(def?.page ?? "")
        }
    }

    // MARK: - ButtonRadio icons

    /// Ikony sześciu przycisków fal LfoShpA — obrys 1:1 z oryginalnej bitmapy
    /// (`LfoShpA.txt`, ButtonRadio InfoFunc:165, 6 ikon 15×11 px), tylko rysowany
    /// krzywymi zamiast pikselami, żeby nie „pikselozował" przy powiększeniu.
    ///
    /// To NIE są miniatury ekranu przy Shape z gałki: oryginalne piktogramy pokazują
    /// każdą falę przy MAŁYM Shape (wąski dzwon / stromy trapez / wąski impuls),
    /// bo dopiero wtedy sześć kształtów jest od siebie wyraźnie odróżnialnych.
    ///
    /// Współrzędne poniżej to kolumna/wiersz oryginalnej bitmapy (rysunek zajmuje
    /// kolumny 1…13 i wiersze 2…8), więc proporcje i marginesy zostają jak w oryginale.
    private func drawLfoShpAWaveIcon(_ ctx: GraphicsContext, rect: CGRect,
                                     waveIndex: Int, color: Color, lineWidth: CGFloat)
    {
        func pt(_ col: CGFloat, _ row: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (col + 0.5) / 15.0 * rect.width,
                    y: rect.minY + (row + 0.5) / 11.0 * rect.height)
        }

        var p = Path()
        switch waveIndex {
        case 0: // Sin2Saw — stromy narost, zaokrąglony szczyt, wyhamowujący spadek
            p.move(to: pt(2, 8))
            p.addLine(to: pt(3.4, 2))
            p.addLine(to: pt(6, 2))
            p.addCurve(to: pt(10, 8), control1: pt(7.4, 3.2), control2: pt(8.6, 8))
            p.addLine(to: pt(12.5, 8))

        case 1: // CosBell — wąski dzwon cosinusowy, płaskie dno, początek następnego
            p.move(to: pt(1, 5.5))
            p.addLine(to: pt(2, 2))
            p.addCurve(to: pt(5, 8), control1: pt(3.0, 5.0), control2: pt(4.0, 8))
            p.addLine(to: pt(10, 8))
            p.addCurve(to: pt(12.4, 4.6), control1: pt(11.0, 8), control2: pt(11.8, 6.2))

        case 2: // TriBell — wąski dzwon TRÓJKĄTNY, potem płaskie dno
            p.move(to: pt(2, 8))
            p.addLine(to: pt(4, 2))
            p.addLine(to: pt(7, 8))
            p.addLine(to: pt(12.4, 8))

        case 3: // Tri2Saw — trójkąt o wierzchołku przesuniętym w lewo (bliżej piły)
            p.move(to: pt(2, 8))
            p.addLine(to: pt(4, 2))
            p.addLine(to: pt(12.4, 8))

        case 4: // SqrTri — trapez: strome zbocza, płaski szczyt
            p.move(to: pt(2, 8))
            p.addLine(to: pt(4, 2))
            p.addLine(to: pt(10, 2))
            p.addLine(to: pt(12.4, 8))

        default: // Square — wąski impuls prostokątny
            p.move(to: pt(2, 8))
            p.addLine(to: pt(2, 2))
            p.addLine(to: pt(5, 2))
            p.addLine(to: pt(5, 8))
            p.addLine(to: pt(12.4, 8))
            p.addLine(to: pt(12.4, 2))
        }
        strokeEvenly(ctx, p, color: color, lineWidth: lineWidth)
    }

    /// Rysuje ikonę w przycisku radio na podstawie InfoFunc, indeksu i łącznej liczby opcji.
    ///
    /// InfoFunc z .txt determinuje rodzaj ikon:
    ///   Fale (LFO/Osc):  58, 106, 155, 156, 164, 165  → kształty fal
    ///   Filtry:          73, 75, 93                    → charakterystyki LP/BP/HP/Notch
    ///   Pozostałe:       fallback rysunku zależnego od indeksu/liczby
    func drawRadioIcon(_ ctx: GraphicsContext, rect: CGRect,
                       infoFunc: Int, count: Int, index: Int, color: Color)
    {
        // Grubość linii ikon = ta sama co krzywych na ekranach. Przy 0.5pt idealnie
        // poziome odcinki (górna belka trapezu, dach impulsu) trafiały między rzędy
        // pikseli i wychodziły bledsze/cieńsze niż skosy, które zawsze pokrywają
        // pełne piksele — przy 0.65pt różnica przestaje być widoczna.
        let lw = UIMetrics.graphLineWidth

        switch infoFunc {
        // ── Kształty fal LFO i oscylatorów ───────────────────────────────────
        case 155: // OscShpA — te same prymitywy co ekran wykresu (GraphFunc 32)
            drawClaviaWaveShape(ctx, waveIndex: index, shape: Self.claviaIconShape, isShapeB: false, rect: rect,
                                color: color, lineWidth: lw)

        case 58, // OscA (6 fal)
             106, // LfoA (6 fal)
             156, // OscB (5 fal)
             164, // LfoB (4 fale)
             200: // LfoC PartSelector (8 fal) — wewnętrzny alias
            drawWaveIcon(ctx, rect: rect, infoFunc: infoFunc, waveIndex: index, color: color, lw: lw)

        // LfoShpA (6 fal): oryginał (Lfo C Graph — mimo nazwy to klasa LfoShpA,
        // patrz Docs/ui/bverhue-behavior) pokazuje, że to NIE jest ta sama rodzina fal
        // co LfoA/LfoB/OscA/OscB (sinus/trójkąt/piła/kwadrat), tylko Sin2Saw/CosBell/
        // TriBell/Tri2Saw/SqrTri/Square — te same prymitywy co ekran wykresu tego
        // modułu (GraphFunc 34, `drawLfoCWaveShape`/`drawLfoWave(isLfoC:true)`).
        case 165:
            drawLfoShpAWaveIcon(ctx, rect: rect, waveIndex: index, color: color, lineWidth: lw)

        // ── Prostowniki sinusoidy (Rect) ─────────────────────────────────────
        case 83: // Rect (4 kształty: ½sin+, ½sin−, 2×sin+, 2×sin−)
            drawRectIcon(ctx, rect: rect, index: index, color: color, lw: lw)

        // ── Krzywe kształtu (ShpStatic) ───────────────────────────────────────
        case 84: // ShpStatic (4 krzywe transferu waveshapera)
            drawShpStaticIcon(ctx, rect: rect, index: index, color: color, lw: lw)

        // ── Charakterystyki filtrów ───────────────────────────────────────────
        case 73, // FltMulti (2: np. stereo/mono)
             75, // FltNord / FltStatic (2/3/4: LP BP HP Notch)
             93: // FltClassic (3: LP BP HP)
            drawFilterIcon(ctx, rect: rect, count: count, index: index, color: color, lw: lw)

        // ── Kształty koperty (EnvADSR / EnvAHD / EnvADR — 4 typy) ───────────
        case 136:
            drawEnvShapeIcon(ctx, rect: rect, shapeType: index % 4, color: color, lw: lw)

        // ── Pozostałe — fallback geometryczny ────────────────────────────────
        default:
            drawGenericIcon(ctx, rect: rect, count: count, index: index, color: color, lw: lw)
        }
    }

    // MARK: Fale

    /// Rysuje ikonę kształtu fali na podstawie danych referencyjnych z plików .txt.
    ///
    /// Kształty zweryfikowane pikselowo z Gen1/Bin/Modules/*.txt:
    ///   0 = sinus (jeden pełny cykl)
    ///   1 = trójkąt ∧ (szczyt na środku, podstawa po bokach)
    ///   2 = piła opadająca (reset + linia opadająca)
    ///   3 = kwadrat 50% (HIGH lewo, LOW prawo)
    ///   4 = LFO→S&H staircase | OscB→podwójna piła | OscC/D→puls 25%
    ///   5 = LFO→S&G gładkie garby | OscC/D→puls 10%
    func drawWaveIcon(_ ctx: GraphicsContext, rect: CGRect,
                      infoFunc: Int, waveIndex: Int, color: Color, lw: CGFloat)
    {
        if infoFunc == 200 {
            drawLfoCWaveIcon(ctx, rect: rect, waveIndex: waveIndex, color: color, lw: lw)
            return
        }

        let x0 = rect.minX
        let x1 = rect.maxX
        let w = rect.width
        let my = rect.midY
        let amp = rect.height * 0.42
        var p = Path()

        let isLfoA = (infoFunc == 106)
        let isOscB = (infoFunc == 156)

        switch waveIndex {
        // ── 0 Sinus — pełen cykl ─────────────────────────────────────────────
        case 0:
            let hx = w * 0.25
            p.move(to: CGPoint(x: x0, y: my))
            p.addCurve(
                to: CGPoint(x: x0 + w * 0.5, y: my),
                control1: CGPoint(x: x0 + hx, y: my - amp),
                control2: CGPoint(x: x0 + w * 0.5 - hx, y: my - amp)
            )
            p.addCurve(
                to: CGPoint(x: x1, y: my),
                control1: CGPoint(x: x0 + w * 0.5 + hx, y: my + amp),
                control2: CGPoint(x: x1 - hx, y: my + amp)
            )

        // ── 1 Trójkąt ∧ — szczyt na środku ──────────────────────────────────
        case 1:
            p.move(to: CGPoint(x: x0, y: my + amp))
            p.addLine(to: CGPoint(x: x0 + w * 0.5, y: my - amp))
            p.addLine(to: CGPoint(x: x1, y: my + amp))

        // ── 2 Piła opadająca — reset (pionowo) + opad ────────────────────────
        case 2:
            // Lewa krawędź = reset (skok w górę), potem liniowy opad w prawo
            p.move(to: CGPoint(x: x0, y: my + amp)) // dół (koniec poprzedniego cyklu)
            p.addLine(to: CGPoint(x: x0, y: my - amp)) // reset: skok na górę
            p.addLine(to: CGPoint(x: x1, y: my + amp)) // opad do dołu

        // ── 3 Kwadrat 50% — wznosząca krawędź od środka, HIGH, opad, LOW ───────
        case 3:
            let mid = x0 + w * 0.5
            p.move(to: CGPoint(x: x0, y: my)) // midline (przed impulsem)
            p.addLine(to: CGPoint(x: x0, y: my - amp)) // krawędź wznosząca
            p.addLine(to: CGPoint(x: mid, y: my - amp)) // top HIGH
            p.addLine(to: CGPoint(x: mid, y: my + amp)) // opad
            p.addLine(to: CGPoint(x: x1, y: my + amp)) // bottom LOW
            p.addLine(to: CGPoint(x: x1, y: my)) // krawędź opadająca (koniec okresu)

        // ── 4 — zależy od modułu ─────────────────────────────────────────────
        case 4:
            if isLfoA {
                // S&H (Sample & Hold) — 4 kroki schodkowe
                // Wzorzec z LfoA.txt Icon[4], kolumny 1/3/5/7/9/11 z 13px:
                // mid → 25%→top → 42%→+1/3 → 58%→−1/3 → 75%→bottom → 92%
                let s1 = x0 + w * 0.25
                let s2 = x0 + w * 0.42
                let s3 = x0 + w * 0.58
                let s4 = x0 + w * 0.75
                let h1 = my // midline start
                let h2 = my - amp // HIGH (near top)
                let h3 = my + amp / 3 // below midline
                let h4 = my - amp / 3 // above midline
                let h5 = my + amp // LOW (near bottom)
                p.move(to: CGPoint(x: x0, y: h1))
                p.addLine(to: CGPoint(x: s1, y: h1))
                p.addLine(to: CGPoint(x: s1, y: h2))
                p.addLine(to: CGPoint(x: s2, y: h2))
                p.addLine(to: CGPoint(x: s2, y: h3))
                p.addLine(to: CGPoint(x: s3, y: h3))
                p.addLine(to: CGPoint(x: s3, y: h4))
                p.addLine(to: CGPoint(x: s4, y: h4))
                p.addLine(to: CGPoint(x: s4, y: h5))
                p.addLine(to: CGPoint(x: x1, y: h5))
            } else if isOscB {
                // Podwójna piła opadająca (dwa szybkie zęby)
                // Wzorzec z OscB.txt Icon[4]: pionowy reset + dwa równoległe opady
                let mid = x0 + w * 0.5
                p.move(to: CGPoint(x: x0, y: my + amp))
                p.addLine(to: CGPoint(x: x0, y: my - amp))
                p.addLine(to: CGPoint(x: mid, y: my + amp))
                p.addLine(to: CGPoint(x: mid, y: my - amp))
                p.addLine(to: CGPoint(x: x1, y: my + amp))
            } else {
                // OscC/OscD: puls 25% — krawędź wznosząca od midline, HIGH 25%, LOW 75%
                let hiEnd = x0 + w * 0.28
                p.move(to: CGPoint(x: x0, y: my))
                p.addLine(to: CGPoint(x: x0, y: my - amp))
                p.addLine(to: CGPoint(x: hiEnd, y: my - amp))
                p.addLine(to: CGPoint(x: hiEnd, y: my + amp))
                p.addLine(to: CGPoint(x: x1, y: my + amp))
                p.addLine(to: CGPoint(x: x1, y: my))
            }

        // ── 5 — zależy od modułu ─────────────────────────────────────────────
        default:
            if isLfoA {
                /// Rnd — gładka fala o nierównych garbach, ta sama rodzina co ostatnia
                /// ikona LfoC. Obrys wprost z bitmapy `LfoA.txt` (6 ikon 13×9, rysunek w
                /// kolumnach 1…11, wierszach 1…7): start (1,6) | OSTRY szczyt (3.5,1)
                /// | dolina (6.5,7) | niższy, zaokrąglony szczyt (9.5,4) | koniec (11,6).
                func ax(_ c: CGFloat) -> CGFloat {
                    x0 + (c + 0.5) / 13.0 * w
                }
                func ay(_ r: CGFloat) -> CGFloat {
                    rect.minY + (r + 0.5) / 9.0 * rect.height
                }
                p.move(to: CGPoint(x: ax(1), y: ay(6)))
                p.addCurve(to: CGPoint(x: ax(3.5), y: ay(1)),
                           control1: CGPoint(x: ax(1.8), y: ay(4.3)),
                           control2: CGPoint(x: ax(2.8), y: ay(1.7)))
                p.addCurve(to: CGPoint(x: ax(6.5), y: ay(7)),
                           control1: CGPoint(x: ax(4.2), y: ay(2.4)),
                           control2: CGPoint(x: ax(5.8), y: ay(7.0)))
                p.addCurve(to: CGPoint(x: ax(9.5), y: ay(4)),
                           control1: CGPoint(x: ax(7.2), y: ay(7.0)),
                           control2: CGPoint(x: ax(8.6), y: ay(4.0)))
                p.addCurve(to: CGPoint(x: ax(11), y: ay(6)),
                           control1: CGPoint(x: ax(10.2), y: ay(4.0)),
                           control2: CGPoint(x: ax(10.7), y: ay(5.2)))
            } else {
                // OscC/OscD: puls 10% — krawędź wznosząca od midline, HIGH 10%, LOW 90%
                let pw = w * 0.12
                p.move(to: CGPoint(x: x0, y: my))
                p.addLine(to: CGPoint(x: x0, y: my - amp))
                p.addLine(to: CGPoint(x: x0 + pw, y: my - amp))
                p.addLine(to: CGPoint(x: x0 + pw, y: my + amp))
                p.addLine(to: CGPoint(x: x1, y: my + amp))
                p.addLine(to: CGPoint(x: x1, y: my))
            }
        }

        strokeEvenly(ctx, p, color: color, lineWidth: lw)
    }

    // MARK: LfoC — 8 kształtów fal

    /// 0=Sine 1=Triangle 2=Saw 3=Square 4=RandomStep 5=Random 6=RandomPulse
    /// 7=RoundedRandomPulse — obrys 1:1 z oryginalnej bitmapy PartSelectora
    /// (`LfoC.txt`, 8 ikon 22×18 px), rysowany krzywymi zamiast pikselami, żeby nie
    /// „pikselozował" przy powiększeniu interfejsu.
    private func drawLfoCWaveIcon(_ ctx: GraphicsContext, rect: CGRect,
                                  waveIndex: Int, color: Color, lw: CGFloat)
    {
        // Współrzędne = kolumna/wiersz oryginalnej bitmapy 22×18 px (rysunek zajmuje
        // kolumny 2…20 i wiersze 2…15).
        let scX = rect.width / 22.0
        let scY = rect.height / 18.0
        let ox = rect.minX, oy = rect.minY
        func cx(_ c: CGFloat) -> CGFloat {
            ox + c * scX
        }
        func cy(_ r: CGFloat) -> CGFloat {
            oy + r * scY
        }

        var p = Path()
        switch waveIndex {
        case 0: // Sinus — pełny cykl (wzrost→szczyt→spadek→dolina)
            // Zerowe przejścia: col 2, 11, 19 | szczyt: row 2.5 | dolina: row 15
            let ym = cy(8.5), yp = cy(2.5), yt = cy(15)
            let xa = cx(2), xb = cx(11), xc = cx(20)
            let d1 = (xb - xa) * 0.45, d2 = (xc - xb) * 0.45
            p.move(to: CGPoint(x: xa, y: ym))
            p.addCurve(to: CGPoint(x: xb, y: ym),
                       control1: CGPoint(x: xa + d1, y: yp),
                       control2: CGPoint(x: xb - d1, y: yp))
            p.addCurve(to: CGPoint(x: xc, y: ym),
                       control1: CGPoint(x: xb + d2, y: yt),
                       control2: CGPoint(x: xc - d2, y: yt))

        case 1: // Trójkąt — odwrócone V (wierzchołek górny-środek, nogi dolne-boki)
            p.move(to: CGPoint(x: cx(3), y: cy(15)))
            p.addLine(to: CGPoint(x: cx(11), y: cy(2.5)))
            p.addLine(to: CGPoint(x: cx(19), y: cy(15)))

        case 2: // Piła opadająca — rampa w dół + natychmiastowy reset
            p.move(to: CGPoint(x: cx(4), y: cy(15))) // dół resetu
            p.addLine(to: CGPoint(x: cx(4), y: cy(2))) // skok w górę
            p.addLine(to: CGPoint(x: cx(17), y: cy(15))) // rampa w dół

        case 3: // Kwadrat — poziom wysoki (lewa połowa) i niski (prawa połowa)
            p.move(to: CGPoint(x: cx(2), y: cy(8)))
            p.addLine(to: CGPoint(x: cx(2), y: cy(2))) // wzrost
            p.addLine(to: CGPoint(x: cx(11), y: cy(2))) // poziom wysoki
            p.addLine(to: CGPoint(x: cx(11), y: cy(15))) // spadek
            p.addLine(to: CGPoint(x: cx(20), y: cy(15))) // poziom niski
            p.addLine(to: CGPoint(x: cx(20), y: cy(8))) // częściowy wzrost

        case 4: // Random Step — schodki na losowych wysokościach
            // Bitmapa: col2 r10-12 | r10 col2-6 | col6 r3-10 | r3 col6-10 | col10 r3-11
            // | r11 col10-14 | col14 r7-11 | r7 col14-18 | col18 r7-14 | r14 col18-20
            p.move(to: CGPoint(x: cx(2), y: cy(12)))
            p.addLine(to: CGPoint(x: cx(2), y: cy(10))) // lewa krawędź
            p.addLine(to: CGPoint(x: cx(6), y: cy(10))) // górna krawędź niskiego
            p.addLine(to: CGPoint(x: cx(6), y: cy(3))) // wzrost do wysokiego
            p.addLine(to: CGPoint(x: cx(10), y: cy(3))) // górna krawędź wysokiego
            p.addLine(to: CGPoint(x: cx(10), y: cy(11))) // prawa krawędź wysokiego
            p.addLine(to: CGPoint(x: cx(14), y: cy(11))) // łącznik
            p.addLine(to: CGPoint(x: cx(14), y: cy(7))) // wzrost do średniego
            p.addLine(to: CGPoint(x: cx(18), y: cy(7))) // górna krawędź średniego
            p.addLine(to: CGPoint(x: cx(18), y: cy(14))) // prawa krawędź
            p.addLine(to: CGPoint(x: cx(20), y: cy(14))) // mała półka dolna

        case 5: // Random — gładka fala o nierównych garbach: duży, dolina, mniejszy
            // Punkty wprost z bitmapy: start (2,11) | OSTRY szczyt (6,2) | dolina
            // (11.5,13) | niższy, zaokrąglony szczyt (15.5,8) | koniec (20,15).
            // Krzywe PRZECHODZĄ przez te punkty (wcześniej były tylko punktami
            // kontrolnymi, więc fala nie dochodziła ani do góry, ani do dołu ikony).
            p.move(to: CGPoint(x: cx(2), y: cy(11)))
            // Narost prawie prosty, z lekko złagodzonym szczytem
            p.addCurve(to: CGPoint(x: cx(6), y: cy(2)),
                       control1: CGPoint(x: cx(3.3), y: cy(8.0)),
                       control2: CGPoint(x: cx(4.9), y: cy(3.4)))
            // Ostry kąt na szczycie (styczne po obu stronach NIE są lustrzane)
            p.addCurve(to: CGPoint(x: cx(11.5), y: cy(13)),
                       control1: CGPoint(x: cx(7.2), y: cy(4.4)),
                       control2: CGPoint(x: cx(10.2), y: cy(13.0)))
            // Z doliny w górę do niższego garba (styczne lustrzane → gładko)
            p.addCurve(to: CGPoint(x: cx(15.5), y: cy(8)),
                       control1: CGPoint(x: cx(12.8), y: cy(12.8)),
                       control2: CGPoint(x: cx(14.3), y: cy(8.0)))
            p.addCurve(to: CGPoint(x: cx(20), y: cy(15)),
                       control1: CGPoint(x: cx(16.7), y: cy(8.0)),
                       control2: CGPoint(x: cx(18.6), y: cy(12.6)))

        case 6: // Random Pulse — impulsy prostokątne o nierównej szerokości
            // Bitmapa: col2 r3-14 | r14 col2-8 | col8 r3-14 | r3 col8-10 | col10 r3-14
            // | r14 col10-14 | col14 r3-14 | r3 col14-19 | col19 r3-14
            let yT6 = cy(3), yB6 = cy(14)
            p.move(to: CGPoint(x: cx(2), y: yT6))
            p.addLine(to: CGPoint(x: cx(2), y: yB6))
            p.addLine(to: CGPoint(x: cx(8), y: yB6))
            p.addLine(to: CGPoint(x: cx(8), y: yT6))
            p.addLine(to: CGPoint(x: cx(10), y: yT6))
            p.addLine(to: CGPoint(x: cx(10), y: yB6))
            p.addLine(to: CGPoint(x: cx(14), y: yB6))
            p.addLine(to: CGPoint(x: cx(14), y: yT6))
            p.addLine(to: CGPoint(x: cx(19), y: yT6))
            p.addLine(to: CGPoint(x: cx(19), y: yB6))

        default: // Rounded Random Pulse — ten sam rytm impulsów, ale z zaokrąglonymi
            // szczytami i dnami (bitmapa: dna wypłaszczone w r13, szczyty w r2)
            p.move(to: CGPoint(x: cx(2), y: cy(3)))
            p.addLine(to: CGPoint(x: cx(2), y: cy(11)))
            p.addQuadCurve(to: CGPoint(x: cx(8), y: cy(11)), control: CGPoint(x: cx(5), y: cy(15)))
            p.addLine(to: CGPoint(x: cx(8), y: cy(3)))
            p.addQuadCurve(to: CGPoint(x: cx(10), y: cy(3)), control: CGPoint(x: cx(9), y: cy(1)))
            p.addLine(to: CGPoint(x: cx(10), y: cy(11)))
            p.addQuadCurve(to: CGPoint(x: cx(14), y: cy(11)), control: CGPoint(x: cx(12), y: cy(15)))
            p.addLine(to: CGPoint(x: cx(14), y: cy(4)))
            p.addQuadCurve(to: CGPoint(x: cx(19), y: cy(4)), control: CGPoint(x: cx(16.5), y: cy(0)))
            p.addLine(to: CGPoint(x: cx(19), y: cy(11)))
        }
        strokeEvenly(ctx, p, color: color, lineWidth: lw)
    }

    // MARK: Rect — prostowniki sinusoidy (InfoFunc:83)

    /// Cztery krzywe są przerysowaniem pikselowych wzorów `Rect.txt` (13×9),
    /// z zachowaniem ich punktów bazowych: x=1...12, y=1...4.
    private func drawRectIcon(_ ctx: GraphicsContext, rect: CGRect,
                              index: Int, color: Color, lw: CGFloat)
    {
        func x(_ value: CGFloat) -> CGFloat {
            rect.minX + rect.width * value / 12
        }
        func y(_ value: CGFloat) -> CGFloat {
            rect.minY + rect.height * value / 8
        }
        let baseline = y(4)
        var p = Path()
        switch index {
        case 0:
            p.move(to: CGPoint(x: x(1), y: baseline))
            p.addQuadCurve(to: CGPoint(x: x(6), y: baseline),
                           control: CGPoint(x: x(3.5), y: y(0.35)))
            p.addLine(to: CGPoint(x: x(12), y: baseline))
        case 1:
            p.move(to: CGPoint(x: x(1), y: baseline))
            p.addQuadCurve(to: CGPoint(x: x(6), y: baseline),
                           control: CGPoint(x: x(3.5), y: y(7.65)))
            p.addLine(to: CGPoint(x: x(12), y: baseline))
        case 2:
            p.move(to: CGPoint(x: x(1), y: baseline))
            p.addQuadCurve(to: CGPoint(x: x(6.5), y: baseline),
                           control: CGPoint(x: x(3.75), y: y(0.35)))
            p.addQuadCurve(to: CGPoint(x: x(12), y: baseline),
                           control: CGPoint(x: x(9.25), y: y(0.35)))
        default:
            p.move(to: CGPoint(x: x(1), y: baseline))
            p.addQuadCurve(to: CGPoint(x: x(6.5), y: baseline),
                           control: CGPoint(x: x(3.75), y: y(7.65)))
            p.addQuadCurve(to: CGPoint(x: x(12), y: baseline),
                           control: CGPoint(x: x(9.25), y: y(7.65)))
        }
        ctx.stroke(p, with: .color(color),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
    }

    // MARK: ShpStatic — krzywe kształtu (InfoFunc:84)

    /// Cztery krzywe przerysowane z `ShpStatic.txt` (19×12). Nie opisują one
    /// ogólnego „S”, lecz cztery konkretne stałe charakterystyki Clavii.
    private func drawShpStaticIcon(_ ctx: GraphicsContext, rect: CGRect,
                                   index: Int, color: Color, lw: CGFloat)
    {
        func x(_ value: CGFloat) -> CGFloat {
            rect.minX + rect.width * value / 18
        }
        func y(_ value: CGFloat) -> CGFloat {
            rect.minY + rect.height * value / 11
        }
        var p = Path()
        switch index {
        case 0:
            p.move(to: CGPoint(x: x(3), y: y(9)))
            p.addLine(to: CGPoint(x: x(6), y: y(9)))
            p.addQuadCurve(to: CGPoint(x: x(9), y: y(6)),
                           control: CGPoint(x: x(9), y: y(8)))
            p.addLine(to: CGPoint(x: x(9), y: y(5)))
            p.addQuadCurve(to: CGPoint(x: x(12), y: y(2)),
                           control: CGPoint(x: x(9), y: y(3)))
            p.addLine(to: CGPoint(x: x(15), y: y(2)))
        case 1:
            p.move(to: CGPoint(x: x(3), y: y(9)))
            p.addLine(to: CGPoint(x: x(5), y: y(9)))
            p.addCurve(to: CGPoint(x: x(10), y: y(4)),
                       control1: CGPoint(x: x(8), y: y(8)),
                       control2: CGPoint(x: x(9), y: y(6)))
            p.addCurve(to: CGPoint(x: x(13), y: y(1)),
                       control1: CGPoint(x: x(10), y: y(2)),
                       control2: CGPoint(x: x(12), y: y(1)))
            p.addLine(to: CGPoint(x: x(15), y: y(1)))
        default:
            let exponent = index == 2 ? 2.0 : 3.0
            for step in 0 ... 48 {
                let position = Double(step) / 48.0
                let input = position * 2.0 - 1.0
                let shaped = input < 0
                    ? -pow(-input, exponent)
                    : pow(input, exponent)
                let point = CGPoint(
                    x: x(3 + 12 * CGFloat(position)),
                    y: y(5 - 4 * CGFloat(shaped))
                )
                if step == 0 {
                    p.move(to: point)
                } else {
                    p.addLine(to: point)
                }
            }
        }
        ctx.stroke(p, with: .color(color),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
    }

    // MARK: Filtry

    /// Charakterystyki filtrów: LP/BP/HP/Notch
    private func drawFilterIcon(_ ctx: GraphicsContext, rect: CGRect,
                                count: Int, index: Int, color: Color, lw: CGFloat)
    {
        var p = Path()
        let x0 = rect.minX, x1 = rect.maxX, w = rect.width
        let yLo = rect.maxY - 0.5 // -6dB line (dolna, linia "pass")
        let yHi = rect.minY + 0.5 // górna (linia "stop")
        let knee = w * 0.35 // szerokość "kolana" charakterystyki

        // Dla 2 przycisków: tylko LP i HP
        let filterType: Int = if count == 2 {
            index == 0 ? 0 : 2 // LP lub HP
        } else {
            index // 0=LP 1=BP 2=HP 3=Notch
        }

        switch filterType {
        case 0: // LP — płasko w lewo, opad w prawo
            p.move(to: CGPoint(x: x0, y: yLo))
            p.addLine(to: CGPoint(x: x0 + w * 0.45, y: yLo))
            p.addCurve(to: CGPoint(x: x0 + w * 0.55 + knee, y: yHi),
                       control1: CGPoint(x: x0 + w * 0.45 + knee * 0.4, y: yLo),
                       control2: CGPoint(x: x0 + w * 0.55, y: yHi))
            p.addLine(to: CGPoint(x: x1, y: yHi))

        case 2: // HP — opad w lewo, płasko w prawo
            p.move(to: CGPoint(x: x0, y: yHi))
            p.addLine(to: CGPoint(x: x0 + w * 0.45 - knee, y: yHi))
            p.addCurve(to: CGPoint(x: x0 + w * 0.55, y: yLo),
                       control1: CGPoint(x: x0 + w * 0.45, y: yHi),
                       control2: CGPoint(x: x0 + w * 0.55 - knee * 0.4, y: yLo))
            p.addLine(to: CGPoint(x: x1, y: yLo))

        case 1: // BP — wypukłość w środku
            let pk = rect.height * 0.85
            p.move(to: CGPoint(x: x0, y: yHi))
            p.addCurve(to: CGPoint(x: x0 + w * 0.5, y: yHi + pk),
                       control1: CGPoint(x: x0 + w * 0.2, y: yHi),
                       control2: CGPoint(x: x0 + w * 0.35, y: yHi + pk))
            p.addCurve(to: CGPoint(x: x1, y: yHi),
                       control1: CGPoint(x: x0 + w * 0.65, y: yHi + pk),
                       control2: CGPoint(x: x0 + w * 0.8, y: yHi))

        default: // Notch — wycięcie w środku
            p.move(to: CGPoint(x: x0, y: yLo))
            p.addLine(to: CGPoint(x: x0 + w * 0.38, y: yLo))
            p.addCurve(to: CGPoint(x: x0 + w * 0.5, y: yHi),
                       control1: CGPoint(x: x0 + w * 0.44, y: yLo),
                       control2: CGPoint(x: x0 + w * 0.46, y: yHi))
            p.addCurve(to: CGPoint(x: x0 + w * 0.62, y: yLo),
                       control1: CGPoint(x: x0 + w * 0.54, y: yHi),
                       control2: CGPoint(x: x0 + w * 0.56, y: yLo))
            p.addLine(to: CGPoint(x: x1, y: yLo))
        }

        ctx.stroke(p, with: .color(color),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
    }

    // MARK: Pozostałe (fallback)

    /// Dla nieznanych InfoFunc: proste ikony geometryczne.
    private func drawGenericIcon(_ ctx: GraphicsContext, rect: CGRect,
                                 count _: Int, index: Int, color: Color, lw: CGFloat)
    {
        // Używamy kształtów fal jako generic fallback — wygląda lepiej niż numery
        drawWaveIcon(ctx, rect: rect, infoFunc: 58, waveIndex: index % 6, color: color, lw: lw)
    }

    // MARK: - LED

    /// Rysuje diody LED (BVerhue type: Green lub Sequencer). Przy View ▸ 3D Buttons
    /// and Screens są wklęsłe jak ekrany i Mini VU.
    func drawBVLEDs(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return }

        if module.typeID == 150 {
            // Compressor: dziesięć segmentów Gain Reduction w geometrii `LedGeometry` —
            // tej samej, w której `LiveIndicatorLayer` zapala je na żywo.
            for bar in LedGeometry.compressorMeterBars(ui: ui, rect: rect) {
                PanelFace.recessed(ctx, bar, cornerRadius: 0.4,
                                   fill: UIColor.compressorSegmentOff,
                                   border: .black.opacity(0.55), lineWidth: 0.35, shaded: panelShading)
            }
            return
        }

        // Wszystkie diody rysujemy ZGASZONE. Zapaloną dokłada na wierzch
        // `LiveIndicatorLayer` — dzięki temu kanwa nie zależy od strumienia z urządzenia.
        // Geometria (i tylko ona) jest wspólna dla obu warstw: `LedGeometry`.
        for led in ui.leds {
            let ledRect = LedGeometry.rect(for: led, typeID: module.typeID, in: rect)
            LedGeometry.draw(ctx, rect: ledRect, type: led.type, lit: false, shaded: panelShading)
        }
    }

    // MARK: - MiniVU

    /// Rysuje wskaźniki poziomu sygnału **wygaszone** (ramka + 12 diod, 3 strefy
    /// kolorów). Segmenty zapalone dokłada na wierzch `LiveIndicatorLayer` — dzięki temu
    /// kanwa nie zależy od strumienia z urządzenia i nie przerysowuje się 20×/s
    /// (patrz tamten plik). Wysokość zwiększona o 1/3 względem BVerhue.
    ///
    /// Ramkę malujemy jako wypełnienie CAŁEGO obrysu, a segmenty kładziemy na niej —
    /// widoczna zostaje sama obwódka, bez szpar na łączeniach i bez zmiany rozmiaru
    /// wskaźnika (segmenty siedzą w jej wnętrzu, patrz `MiniVUGeometry`).
    ///
    /// Ramka ma zaokrąglone rogi, a wskaźnik — przy View ▸ 3D Buttons and Screens — jest
    /// wgłębiony jak ekrany: ciemniejsza lewa i górna krawędź, jaśniejsza prawa i dolna
    /// (prośba użytkownika 2026-09-27; wcześniej przez chwilę rzucał cień na zewnątrz).
    func drawBVMiniVUs(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        for def in MiniVUDatabase.defs(forModuleID: module.typeID) {
            let bounds = MiniVUGeometry.bounds(def: def, in: rect)
            ctx.fill(Path(roundedRect: bounds, cornerRadius: MiniVUGeometry.cornerRadius),
                     with: .color(MiniVUGeometry.frameColor))
            for (index, segment) in MiniVUGeometry.segments(def: def, in: rect).enumerated() {
                ctx.fill(Path(segment), with: .color(MiniVUGeometry.color(segment: index, lit: false)))
            }
            if panelShading { Bevel.recess(ctx, bounds, cornerRadius: MiniVUGeometry.cornerRadius) }
        }
    }
}
