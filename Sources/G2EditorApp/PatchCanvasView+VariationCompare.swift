import AppKit
import G2Core
import G2EditorCore
import SwiftUI

// Porównanie dwóch wariacji (Shift-klik w pasku wariacji, życzenie z forum, wątek 11302).
// Grająca wariacja zostaje na kanwie taka jak zwykle; wszystko, co w porównywanej jest
// takie samo, gaśnie pod mgiełką, a różnice dostają turkus porównywanej wariacji:
// druga wskazówka na gałce, kreska na suwaku, obwódka przycisku, który świeciłby tam,
// i ramka ekranu, który pokazałby co innego. Dymek pod myszką (albo wszystkie naraz
// z przytrzymanym ⌥) podaje obie wartości. Decyzje użytkownika 2026-10-30.
//
// Warstwa leży NAD gotowymi obrazkami modułów (`ModuleRasterCache`), jak mgiełka
// „Only audible" — same moduły rysują się bez zmian.

/// Jeden ślad porównywanej wariacji na kanwie.
struct VariationCompareMark {
    enum Shape {
        /// Druga wskazówka gałki — `fraction` jak w `drawKnob` (0 = 7:30, 1 = 4:30).
        case pointer(center: CGPoint, radius: CGFloat, fraction: Double)
        /// Uchwyt suwaka w miejscu wartości porównywanej wariacji.
        case faderThumb(CGRect)
        /// Obwódka przycisku albo ramka ekranu.
        case outline(CGRect)
    }

    let shape: Shape
    /// Obszar, który nie gaśnie pod mgiełką — cała kontrolka albo cały ekran.
    let uncovered: CGRect
}

/// Dymek porównania: gdzie stoi (prawy dolny róg kontrolki/ekranu, pt kanwy) i co mówi.
struct VariationCompareBubbleItem {
    let key: String
    let anchor: CGPoint
    /// Prostokąt ekranu — dla dymka pod myszką; `.zero` przy kontrolkach.
    let box: CGRect
    let lines: (playing: String, compared: String)
    /// Klucz parametru ekranu: gdy jego kontrolka ma już dymek, ekran swojego nie dostaje.
    var coveredKey = ""
}

extension PatchCanvasView {
    func drawVariationComparison(_ ctx: GraphicsContext) {
        guard let compared = comparedVariation, !isPreviewMode else { return }
        let ro = rowOffset
        let mods = modules
        let clip = ctx.clipBoundingRect
        let fog = UIColor.canvasBackground.opacity(0.6)
        for module in mods {
            let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)
            guard rect.intersects(clip) else { continue }
            let differing = module.parametersDiffering(fromVariation: compared)
            guard !differing.isEmpty, let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else {
                ctx.fill(Path(rect), with: .color(fog))
                continue
            }
            let marks = variationCompareMarks(module: module, ui: ui, rect: rect,
                                              differing: differing, compared: compared)
            var holes = Path()
            for mark in marks {
                // Gałka odsłania koło — kwadratowe okienko wyglądało jak jasna kratka.
                if case .pointer = mark.shape {
                    holes.addEllipse(in: mark.uncovered)
                } else {
                    holes.addRoundedRect(in: mark.uncovered.insetBy(dx: -0.8, dy: -0.8),
                                         cornerSize: CGSize(width: 1, height: 1))
                }
            }
            var fogged = ctx
            fogged.clip(to: holes, options: .inverse)
            fogged.fill(Path(rect), with: .color(fog))
            for mark in marks {
                drawVariationCompareMark(ctx, mark.shape)
            }
        }
    }

    func variationCompareMarks(module: G2Module, ui: ModuleUIDef, rect: CGRect,
                               differing: Set<Int>, compared: Int) -> [VariationCompareMark]
    {
        var marks: [VariationCompareMark] = []
        func other(_ index: Int) -> Int {
            module.parameterValue(index, inVariation: compared) ?? 0
        }
        for knob in ui.knobs where differing.contains(knob.codeRef) {
            let origin = knobOrigin(module: module, knob: knob)
            let tlx = rect.minX + origin.x
            let tly = rect.minY + origin.y
            if knob.type.isRotary {
                let off = knob.type.centerOffsetPt
                let r = knob.type.radiusPt
                let maxValue = max(1, ParameterRangeDatabase.range(moduleTypeID: module.typeID,
                                                                   codeRef: knob.codeRef)?.upperBound ?? 127)
                let fraction = Double(max(0, min(maxValue, other(knob.codeRef)))) / Double(maxValue)
                let center = CGPoint(x: tlx + off.x, y: tly + off.y)
                marks.append(.init(shape: .pointer(center: center, radius: r, fraction: fraction),
                                   uncovered: CGRect(x: center.x - r * 1.35, y: center.y - r * 1.35,
                                                     width: r * 2.7, height: r * 2.7)))
            } else if knob.type == .slider || knob.type == .seqSlider {
                let track = faderLayout(module: module, knob: knob, ui: ui, rect: rect).track
                // Nuty SeqNote leżą na przewijanej siatce — tam sama ramka toru, wartość w dymku.
                guard knob.infoFunc != 13 else {
                    marks.append(.init(shape: .outline(track), uncovered: track))
                    continue
                }
                // Ta sama droga uchwytu co w `drawSeqSlider`.
                let thumbH: CGFloat = 3
                let norm = CGFloat(max(0, min(127, other(knob.codeRef)))) / 127
                let thumb = CGRect(x: track.minX, y: track.minY + (track.height - thumbH) * (1 - norm),
                                   width: track.width, height: thumbH)
                marks.append(.init(shape: .faderThumb(thumb), uncovered: track))
            } else {
                let size = knob.type.sliderSizePt
                let box = CGRect(x: tlx, y: tly, width: size.width, height: size.height)
                marks.append(.init(shape: .outline(box), uncovered: box))
            }
        }
        for btn in ui.buttonsRadio where differing.contains(btn.codeRef) && btn.buttonCount > 0 {
            let rects = radioButtonRects(btn, module: module, ui: ui, rect: rect)
            let group = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            marks.append(.init(shape: .outline(rects[radioButtonPosition(btn, value: other(btn.codeRef))]),
                               uncovered: group))
        }
        // Pozostałe przyciski — obwódka całej kontrolki; wartość mówi dymek.
        let buttonRefs = ui.buttonsFlat.map(\.codeRef) + ui.buttonsText.map(\.codeRef)
            + ui.incDecButtons.map(\.codeRef) + ui.levelShifts.map(\.codeRef)
            + ui.partSelectors.filter(\.usesParameter).map(\.codeRef)
        for index in Set(buttonRefs).intersection(differing) {
            guard let box = parameterControlRect(module: module, paramIndex: index, ui: ui, rect: rect)
            else { continue }
            marks.append(.init(shape: .outline(box), uncovered: box))
        }
        // Ekrany: pole z wartością dostaje ramkę, gdy jego napis byłby inny; wykres — gdy
        // różni się którykolwiek parametr, od którego zależy (ujemny indeks to tryb, wspólny
        // dla wariacji). Klawiatura i nuta oktawy SeqNote pokazują widok siatki, nie wartość.
        var other = module
        other.parameters = module.parameterValues(inVariation: compared)
        for field in ui.textFields where differing.contains(field.masterRef)
            || field.dependencies.contains(where: differing.contains)
        {
            guard G2ParameterText.fieldText(field, module: module) != G2ParameterText.fieldText(field, module: other)
            else { continue }
            let box = textFieldBoxRect(field, module: module, ui: ui, rect: rect)
            marks.append(.init(shape: .outline(box), uncovered: box))
        }
        for graph in ui.graphs where graph.graphFunc != 25 && graph.graphFunc != 26
            && graph.dependencies.contains(where: differing.contains)
        {
            let box = graphRect(graph, module: module, ui: ui, rect: rect)
            marks.append(.init(shape: .outline(box), uncovered: box))
        }
        return marks
    }

    /// Krzywa porównywanej wariacji na ekranie wykresu — przerywana, turkusowa, na tym,
    /// co ekran pokazuje teraz (pomysł użytkownika 2026-10-30). Kreski płyną jak ramka
    /// zaznaczenia, żeby było je lepiej widać — dlatego to osobna, animowana warstwa nad
    /// modułami (jak `selectionOverlayView`), a nie część `drawModules`.
    @ViewBuilder
    var variationCompareCurvesOverlay: some View {
        let curves = variationCompareCurves()
        if !curves.isEmpty {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                Canvas { ctx, _ in
                    ctx.scaleBy(x: zoom, y: zoom)
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let phase = CGFloat((t * 3).truncatingRemainder(dividingBy: Double(Self.compareDashPeriod)))
                    for curve in curves {
                        drawVariationCompareCurve(ctx, curve, phase: phase)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Wykresy, które w porównywanej wariacji pokazałyby inną krzywą — z modułem
    /// przestawionym na jej wartości.
    private func variationCompareCurves() -> [(graph: BVGraph, module: G2Module, box: CGRect)] {
        guard let compared = comparedVariation, !isPreviewMode else { return [] }
        // Ekrany bez krzywej: klawiatura i nuta SeqNote, presety DrumSynth, wokoder.
        let notCurves: Set = [8, 22, 25, 26, 46]
        let ro = rowOffset
        let mods = modules
        var curves: [(graph: BVGraph, module: G2Module, box: CGRect)] = []
        for module in mods {
            let differing = module.parametersDiffering(fromVariation: compared)
            guard !differing.isEmpty, let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { continue }
            let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)
            var other = module
            other.parameters = module.parameterValues(inVariation: compared)
            for graph in ui.graphs where !notCurves.contains(graph.graphFunc)
                && graph.dependencies.contains(where: differing.contains)
            {
                curves.append((graph, other, graphRect(graph, module: module, ui: ui, rect: rect)))
            }
        }
        return curves
    }

    /// Ekranów jest ponad 40 rodzajów, więc nie rysujemy każdego od nowa: wykres drugiej
    /// wariacji idzie do warstwy, z której zostają tylko jasne piksele krzywej (`graphLine`,
    /// zielony kanał ponad 0,6 — tło, wypełnienie pod krzywą i ramka odpadają),
    /// przemalowane na turkus i pocięte ukośnymi paskami w kreski.
    private func drawVariationCompareCurve(_ ctx: GraphicsContext,
                                           _ curve: (graph: BVGraph, module: G2Module, box: CGRect),
                                           phase: CGFloat)
    {
        var layer = ctx
        layer.clip(to: variationCompareDashes(in: curve.box, phase: phase))
        var curveOnly = ColorMatrix()
        curveOnly.a1 = 0
        curveOnly.a2 = 2.5
        curveOnly.a3 = 0
        curveOnly.a4 = 0
        curveOnly.a5 = -1.5
        // Filtr dodany później działa na rysunku PIERWSZY — próg idzie więc przed macierzą.
        layer.addFilter(.alphaThreshold(min: 0.3, color: UIColor.variationCompare))
        layer.addFilter(.colorMatrix(curveOnly))
        layer.drawLayer { sub in
            drawGraph(sub, graph: curve.graph, module: curve.module, rect: curve.box)
        }
    }

    private static let compareDashPeriod: CGFloat = 1.7

    /// Ukośne paski — przecięta nimi krzywa wygląda jak przerywana linia w każdym kierunku.
    /// `phase` przesuwa je w prawo, więc kreski płyną wzdłuż krzywej.
    private func variationCompareDashes(in box: CGRect, phase: CGFloat) -> Path {
        let period = Self.compareDashPeriod
        let dash: CGFloat = 1.0
        var path = Path()
        var x = box.minX - box.height - period + phase
        while x < box.maxX {
            path.move(to: CGPoint(x: x, y: box.maxY))
            path.addLine(to: CGPoint(x: x + box.height, y: box.minY))
            path.addLine(to: CGPoint(x: x + box.height + dash, y: box.minY))
            path.addLine(to: CGPoint(x: x + dash, y: box.maxY))
            path.closeSubpath()
            x += period
        }
        return path
    }

    private func drawVariationCompareMark(_ ctx: GraphicsContext, _ shape: VariationCompareMark.Shape) {
        let color = UIColor.variationCompare
        let shadow = Color.black.opacity(0.7)
        switch shape {
        case let .pointer(center, radius, fraction):
            // 135° = 7:30, +270° do 4:30 — jak wskazówka gałki w `drawKnob`.
            let angle = CGFloat(135 + 270 * fraction) * .pi / 180
            var line = Path()
            line.move(to: center)
            line.addLine(to: CGPoint(x: center.x + cos(angle) * radius * 1.15,
                                     y: center.y + sin(angle) * radius * 1.15))
            let width = max(0.6, radius * 0.22)
            ctx.stroke(line, with: .color(shadow), style: StrokeStyle(lineWidth: width + 0.6, lineCap: .round))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        case let .faderThumb(thumb):
            let path = Path(roundedRect: thumb, cornerRadius: 1)
            ctx.stroke(path, with: .color(shadow), lineWidth: 1.3)
            ctx.stroke(path, with: .color(color), lineWidth: 0.7)
        case let .outline(box):
            let path = Path(roundedRect: box.insetBy(dx: -0.4, dy: -0.4), cornerRadius: 1.2)
            ctx.stroke(path, with: .color(shadow), lineWidth: 1.3)
            ctx.stroke(path, with: .color(color), lineWidth: 0.7)
        }
    }

    // MARK: - Dymki

    /// Nazwa wariacji w dymku — „Mutator" albo „Fader", gdy gra bufor odsłuchu.
    func variationCompareName(_ variation: Int) -> String {
        variation == G2Patch.mutatorVariation ? bufferName : "Var \(variation + 1)"
    }

    /// Dymek porównania dla kontrolki pod myszką; `nil`, gdy wartości są równe.
    func variationCompareLines(for hit: ParamHoverHit) -> (playing: String, compared: String)? {
        guard let compared = comparedVariation, !hit.usesModes,
              let module = modules.first(where: { $0.id == hit.moduleID }),
              let current = module.parameters.indices.contains(hit.paramIndex) ? module.parameters[hit.paramIndex] : nil,
              let other = module.parameterValue(hit.paramIndex, inVariation: compared), other != current
        else { return nil }
        var playing = hintValueText(hit, params: module.parameters, value: current)
        var comparedText = hintValueText(hit, params: module.parameterValues(inVariation: compared), value: other)
        // Napis bez liczby (sama nazwa, np. „Length") albo ten sam w obu — wtedy surowe wartości.
        if playing.isEmpty || playing == comparedText {
            playing = "\(current)"
            comparedText = "\(other)"
        }
        return ("\(variationCompareName(patch.activeVariation)): \(playing)",
                "\(variationCompareName(compared)): \(comparedText)")
    }

    func variationCompareBubble(_ lines: (playing: String, compared: String)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(lines.playing)
            Text(lines.compared).foregroundColor(UIColor.variationCompare)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.80)))
    }

    /// Z przytrzymanym ⌥ — dymki wszystkich różnic naraz, każdy przy swojej kontrolce.
    @ViewBuilder
    var variationCompareAllBubbles: some View {
        if comparedVariation != nil, OptionKeyMonitor.shared.isDown {
            variationCompareBubbleLayer(variationCompareBubbles())
        }
    }

    /// Ekran z wartością (np. „C3", „0") pod myszką — to nie kontrolka, więc zwykły dymek
    /// go nie obsługuje; w porównaniu pokazuje napis z obu wariacji.
    @ViewBuilder
    var variationCompareFieldHoverBubble: some View {
        if comparedVariation != nil, hoverInCanvas, hoverHit == nil, !OptionKeyMonitor.shared.isDown {
            let point = CGPoint(x: hoverScreenPt.x / zoom, y: hoverScreenPt.y / zoom)
            variationCompareBubbleLayer(variationCompareFieldBubbles().filter { $0.box.contains(point) })
        }
    }

    private func variationCompareBubbleLayer(_ items: [VariationCompareBubbleItem]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(items, id: \.key) { item in
                variationCompareBubble(item.lines)
                    .fixedSize()
                    .offset(x: item.anchor.x * zoom + 2, y: item.anchor.y * zoom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Dymki kontrolek z różnicą plus ekranów, których napisu nie mówi już dymek ich
    /// kontrolki (gałka z ekranem tej samej wartości ma jeden dymek, nie dwa).
    private func variationCompareBubbles() -> [VariationCompareBubbleItem] {
        var covered: [String: String] = [:]
        var items: [VariationCompareBubbleItem] = []
        for item in variationCompareHits() {
            guard let lines = variationCompareLines(for: item.hit) else { continue }
            covered[item.key] = lines.playing + lines.compared
            items.append(.init(key: item.key, anchor: item.hit.tooltipAnchor, box: .zero, lines: lines))
        }
        items += variationCompareFieldBubbles().filter {
            covered[$0.coveredKey] != $0.lines.playing + $0.lines.compared
        }
        return items
    }

    /// Ekrany z wartością, które w porównywanej wariacji pokazałyby inny napis.
    private func variationCompareFieldBubbles() -> [VariationCompareBubbleItem] {
        guard let compared = comparedVariation else { return [] }
        let ro = rowOffset
        let mods = modules
        var items: [VariationCompareBubbleItem] = []
        for module in mods {
            let differing = module.parametersDiffering(fromVariation: compared)
            guard !differing.isEmpty, let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { continue }
            let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)
            var other = module
            other.parameters = module.parameterValues(inVariation: compared)
            for field in ui.textFields where differing.contains(field.masterRef)
                || field.dependencies.contains(where: differing.contains)
            {
                let playing = G2ParameterText.fieldText(field, module: module)
                let comparedText = G2ParameterText.fieldText(field, module: other)
                guard playing != comparedText else { continue }
                let box = textFieldBoxRect(field, module: module, ui: ui, rect: rect)
                items.append(.init(key: "\(module.id)-field\(field.id)",
                                   anchor: CGPoint(x: box.maxX, y: box.maxY), box: box,
                                   lines: ("\(variationCompareName(patch.activeVariation)): \(playing)",
                                           "\(variationCompareName(compared)): \(comparedText)"),
                                   coveredKey: "\(module.id)-\(field.masterRef)"))
            }
        }
        return items
    }

    /// Kontrolki z różnicą, odnalezione tą samą drogą co dymek pod myszką — środek
    /// kontrolki idzie do `findHoverHit`, więc napis jest dokładnie ten sam.
    private func variationCompareHits() -> [(key: String, hit: ParamHoverHit)] {
        guard let compared = comparedVariation else { return [] }
        let ro = rowOffset
        let mods = modules
        var hits: [(key: String, hit: ParamHoverHit)] = []
        for module in mods {
            let differing = module.parametersDiffering(fromVariation: compared)
            guard !differing.isEmpty, let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { continue }
            let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)
            for index in differing.sorted() {
                guard let point = variationCompareProbe(module: module, paramIndex: index, ui: ui, rect: rect),
                      let hit = findHoverHit(at: point),
                      hit.moduleID == module.id, hit.paramIndex == index, !hit.usesModes
                else { continue }
                hits.append(("\(module.id)-\(index)", hit))
            }
        }
        return hits
    }

    /// Punkt, który trafia w kontrolkę parametru — środek gałki albo przycisku.
    private func variationCompareProbe(module: G2Module, paramIndex: Int, ui: ModuleUIDef,
                                       rect: CGRect) -> CGPoint?
    {
        if let knob = ui.knobs.first(where: { $0.codeRef == paramIndex }), knob.type.isRotary {
            let origin = knobOrigin(module: module, knob: knob)
            let off = knob.type.centerOffsetPt
            return CGPoint(x: rect.minX + origin.x + off.x, y: rect.minY + origin.y + off.y)
        }
        if let btn = ui.buttonsRadio.first(where: { $0.codeRef == paramIndex }), btn.buttonCount > 0 {
            let first = radioButtonRects(btn, module: module, ui: ui, rect: rect)[0]
            return CGPoint(x: first.midX, y: first.midY)
        }
        return parameterControlRect(module: module, paramIndex: paramIndex, ui: ui, rect: rect)
            .map { CGPoint(x: $0.midX, y: $0.midY) }
    }
}

/// Czy ⌥ jest wciśnięty — kanwa pokazuje wtedy wszystkie dymki porównania wariacji.
/// Samo przytrzymanie ⌥ nie robiło dotąd nic (⌥ działa tylko z przeciąganiem i kółkiem).
@MainActor @Observable
final class OptionKeyMonitor {
    static let shared = OptionKeyMonitor()

    private(set) var isDown = false
    @ObservationIgnored private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.isDown = event.modifierFlags.contains(.option)
            return event
        }
        // Puszczony ⌥ w innej aplikacji nie wraca tu jako flagsChanged.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.isDown = false }
        }
    }
}
