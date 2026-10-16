// SmallKnob.swift
// Gałka 0–127 poza kanwą — jedna dla paska morfów, pola „Patch Level" (instrukcja
// str. 62), Parameter Pages, Patch Adjustera i Patch Mutatora. W oknach ma rozmiar
// `panelSize`, ten sam co w kafelkach Morph Groups; do 2026-09-27 każde okno miało
// własną kopię gałki i własny rozmiar (Adjuster 40 pt, Pages i Mutator ~34 pt).
//
// Geometria jak na gałkach w patchu: wskaźnik zaczyna 135° i przechodzi 270°
// do wartości maksymalnej; przeciąganie w pionie, 1 px = 1 krok.
//
// Tarcza, wskaźnik i kreseczki min/max są te same co w modułach, Parameter
// Pages i Mutatorze (`KnobFace`, styl z Setup ▸ Options ▸ Knob style). Do 2026-09-27
// była tu osobna, płaska ciemna tarcza z czarnym wskaźnikiem (uwaga użytkownika).

import G2EditorCore
import SwiftUI

struct SmallKnob: View {
    /// Gałka w oknach i w kafelkach morfów — dość duża, żeby łatwo w nią trafić.
    static let panelSize: CGFloat = 34

    var value: Int
    var range: ClosedRange<Int> = 0 ... 127
    var size: CGFloat = TopBarMetrics.knobSize
    /// Kolorowa obwódka wokół tarczy — morf z przypisaniami. `nil` = bez obwódki.
    var ringColor: Color?
    var ringWidth: CGFloat = TopBarMetrics.knobRingWidth
    /// Wieniec czerwonych diod wzdłuż skali zamiast kreseczek min/max, jak na gałce
    /// Wheel w oryginale. Zapala się tyle, ile wynosi wartość. 0 = kreseczki.
    var ledCount = 0
    /// Zabarwienie morfu na tarczy — jak na gałce modułu (Parameter Pages).
    var morph: MorphIndicator.Tint?
    /// Nieprzypisana gałka Parameter Pages: przygaszony wskaźnik, bez przeciągania.
    var enabled = true
    /// Ile kroków wartości na punkt ruchu myszy. Parameter Pages bierze 0,4 — tyle co
    /// gałka modułu na kanwie (instrukcja str. 126: gałka okna ma działać jak modułu).
    var stepsPerPoint = 1.0
    var onBegin: () -> Void = {}
    var onChange: (Int) -> Void
    var onEnd: () -> Void = {}

    @State private var dragStart: Int?
    @AppStorage(KnobStyle.storageKey) private var knobStyle = KnobStyle.light.rawValue
    @AppStorage(KnobRangeSegments.storageKey) private var rangeSegments = KnobRangeSegments.line.rawValue
    @AppStorage(KnobRangeColor.storageKey) private var rangeColor = KnobRangeColor.green.rawValue
    @AppStorage(GlowAmount.storageKey) private var glow = 0.0
    @AppStorage(KnobMorphRange.storageKey) private var morphRange = KnobMorphRange.full.rawValue

    var body: some View {
        Canvas { ctx, canvasSize in draw(ctx, canvasSize) }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        guard enabled else { return }
                        if dragStart == nil {
                            dragStart = value
                            onBegin()
                        }
                        let delta = Int((-gesture.translation.height * stepsPerPoint).rounded())
                        let raw = (dragStart ?? value) + delta
                        onChange(max(range.lowerBound, min(range.upperBound, raw)))
                    }
                    .onEnded { _ in
                        guard dragStart != nil else { return }
                        dragStart = nil
                        onEnd()
                    }
            )
            .disabled(!enabled)
    }

    private func draw(_ ctx: GraphicsContext, _ canvasSize: CGSize) {
        // Tarcza nie wypełnia całej ramki: poza nią sterczą jeszcze kreseczki min/max
        // albo wieniec diod.
        let radius = min(canvasSize.width, canvasSize.height) / 2 * 0.72
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        // Wskaźnik zawsze czarny (w Light): biały słabo odcinał się od jasnej tarczy na
        // szarym tle okien (uwaga użytkownika 2026-09-27). W Dark zostaje biały.
        let look = KnobLook(style: KnobStyle(rawValue: knobStyle) ?? .light,
                            rangeSegments: KnobRangeSegments(rawValue: rangeSegments) ?? .line,
                            rangeColor: KnobRangeColor(rawValue: rangeColor) ?? .green,
                            glow: glow,
                            pointerColor: .black,
                            morphRange: KnobMorphRange(rawValue: morphRange) ?? .full)
        let span = max(1, range.upperBound - range.lowerBound)
        let shown = morph?.displayValue ?? value
        let fraction = Double(max(range.lowerBound, min(range.upperBound, shown)) - range.lowerBound)
            / Double(span)
        let face = KnobFace.draw(ctx, center: center, radius: radius, style: look, fraction: fraction)
        if let ringColor {
            let outer = radius + ringWidth / 2
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x - outer, y: center.y - outer,
                                              width: outer * 2, height: outer * 2)),
                       with: .color(ringColor), lineWidth: ringWidth)
        }
        // Wieniec diod tylko w Light i Dark — w Future wartość pokazuje już pasek w pierścieniu.
        if ledCount > 1, look.style != .future {
            drawLeds(ctx, center: center, radius: radius, fraction: fraction)
        } else {
            drawScaleTicks(ctx, center: center, radius: radius)
        }
        if let morph {
            MorphIndicator.draw(ctx, cx: center.x, cy: center.y, faceRadius: face, tint: morph, look: look)
        }
        KnobFace.drawPointer(ctx, center: center, radius: radius, face: face, fraction: fraction,
                             style: look, dimmed: !enabled)
    }

    /// Diody od 7:30 do 4:30 (te same 270° co wskaźnik). Zapalonych jest tyle, ile
    /// wynosi wartość zaokrąglona do diody: 0 = żadna, maksimum = wszystkie. Zgaszone
    /// zostają widoczne jako ciemnoczerwone, żeby było widać całą skalę.
    private func drawLeds(_ ctx: GraphicsContext, center: CGPoint, radius: CGFloat, fraction: Double) {
        let lit = Int((fraction * Double(ledCount)).rounded())
        let orbit = radius * 1.22
        let dot = max(1.5, radius * 0.16)
        let on = Color(red: 1, green: 0.16, blue: 0.1)
        for index in 0 ..< ledCount {
            let degrees = 135.0 + 270.0 * Double(index) / Double(ledCount - 1)
            let angle = CGFloat(degrees) * .pi / 180
            let point = CGPoint(x: center.x + cos(angle) * orbit, y: center.y + sin(angle) * orbit)
            let rect = CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)
            ctx.fill(Path(ellipseIn: rect), with: .color(index < lit ? on : on.opacity(0.22)))
        }
    }

    /// Początek i koniec skali — dwie kreseczki pod tarczą, w tych samych miejscach
    /// i tej samej grubości co w Parameter Pages (135° = 7:30 i 405° = 4:30). Leżą na tle
    /// okna, więc biorą kolor treści, żeby nie znikać w trybie nocnym.
    private func drawScaleTicks(_ ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let width = max(0.4, radius * 0.12)
        for degrees in [135.0, 405.0] as [CGFloat] {
            let angle = degrees * .pi / 180.0
            var tick = Path()
            tick.move(to: CGPoint(x: center.x + cos(angle) * (radius + width),
                                  y: center.y + sin(angle) * (radius + width)))
            tick.addLine(to: CGPoint(x: center.x + cos(angle) * radius * 1.30,
                                     y: center.y + sin(angle) * radius * 1.30))
            ctx.stroke(tick, with: .color(Color.primary.opacity(0.75)),
                       style: StrokeStyle(lineWidth: width * 1.6, lineCap: .round))
        }
    }
}
