// MorphIndicator.swift
// Wskaźnik morfu na gałce — zabarwienie tarczy i wycinek zakresu.
//
// Cała reguła siedzi w dwóch funkcjach oryginalnego edytora:
//
// `CPanel::CtrlGetMorphGroup` — pytanie „jakiego koloru jest ta kontrolka":
//   • parametr morfowany przez morf Z FOCUSEM       → `Morph::kGrp1`
//   • parametr morfowany przez którykolwiek inny    → `Morph::kGrp3`
//   • nieprzypisany                                 → 8 (brak)
// To są jedyne dwie wartości, jakie kontrolka dostaje — dlatego kolorów jest DWA,
// choć `GetColors` zna osiem barw (`kBtnFaceGroup1…8`). kGrp1 jest czerwony,
// kGrp3 niebieski (manual v1.4 s. 66: „so this knob shows up in red").
//
// Knob Slider ABC (UpdateGraphics) — skąd bierze się wycinek:
//   delta = `CtrlGetMorphDelta` (zakres, ale TYLKO dla morfu z focusem — dla obcego
//   zwraca 0, więc obca gałka jest sama niebieska, bez wycinka)
//   if delta == 0 || max == 127:  value, start = value, end = value + delta
//   else:                          value = 0, start = 0, end = 127
// Drugi przypadek to parametry o zakresie mniejszym niż 0…127 — przypisanie morfu
// ustawia im wartość bazową 0 i zakres równy maksimum (`GetAssignMorphToParamMolecules`),
// więc oryginał pokazuje pełny obrót → [[Docs/ui/morphs]].

import G2Core
import G2EditorCore
import SwiftUI

enum MorphIndicator {
    /// Co narysować na jednej gałce.
    struct Tint {
        /// Morf z focusem (czerwony) czy którykolwiek z pozostałych (niebieski).
        let focused: Bool
        /// Początek i koniec wycinka na obwodzie, 0…1. Równe = wycinka nie ma.
        let startNorm: CGFloat
        let endNorm: CGFloat
        /// Wartość, którą ma pokazać wskaźnik — zwykle bieżąca, ale dla parametru
        /// o zakresie mniejszym niż 0…127 oryginał zeruje ją razem z wycinkiem.
        let displayValue: Int

        var hasRange: Bool {
            abs(endNorm - startNorm) > 0.0001
        }
    }

    static func color(focused: Bool) -> Color {
        focused ? UIColor.morphFocused : UIColor.morphOther
    }

    static func tint(for assignments: [G2MorphAssignment], focusedMorph: Int,
                     value: Int, maxValue: Int) -> Tint?
    {
        guard !assignments.isEmpty else { return nil }
        let top = max(1, maxValue)
        let delta = assignments.first { $0.morph == focusedMorph }?.range ?? 0
        if delta != 0, maxValue != 127 {
            // Parametr o zakresie mniejszym niż 0…127 — pełny obrót, wskaźnik na zerze.
            return Tint(focused: true, startNorm: 0, endNorm: 1, displayValue: 0)
        }
        let base = min(max(0, value), top)
        let end = min(max(0, value + delta), top)
        return Tint(focused: delta != 0,
                    startNorm: CGFloat(base) / CGFloat(top),
                    endNorm: CGFloat(end) / CGFloat(top),
                    displayValue: base)
    }

    /// Zabarwienie tarczy i wycinek zakresu. Rysowane po tarczy, a przed wskaźnikiem —
    /// w oryginale kreska wartości leży na wycinku, nie pod nim.
    static func draw(_ ctx: GraphicsContext, cx: CGFloat, cy: CGFloat,
                     faceRadius r: CGFloat, tint: Tint, look: KnobLook)
    {
        let color = color(focused: tint.focused)
        let face = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: face), with: .color(color.opacity(0.30)))
        guard tint.hasRange else { return }
        let centre = CGPoint(x: cx, y: cy)
        var wedge = Path()
        wedge.move(to: centre)
        wedge.addArc(center: centre, radius: r,
                     startAngle: .radians(Double(angle(min(tint.startNorm, tint.endNorm)))),
                     endAngle: .radians(Double(angle(max(tint.startNorm, tint.endNorm)))),
                     clockwise: false)
        wedge.closeSubpath()
        // Wewnętrzny okrąg tarczy (`KnobFace`: 0,64 powierzchni w Light i Future). Dark go
        // nie ma, więc tam wycinek zawsze pełny.
        let inner = Path(ellipseIn: face.insetBy(dx: r * 0.36, dy: r * 0.36))
        let range = look.style == .dark ? .full : look.morphRange
        switch range {
        case .full:
            ctx.fill(wedge, with: .color(color.opacity(0.95)))
        case .ring:
            var ring = ctx
            ring.clip(to: inner, options: .inverse)
            ring.fill(wedge, with: .color(color.opacity(0.95)))
        case .shaded:
            ctx.fill(wedge, with: .color(color.opacity(0.95)))
            // Obwód: blik z lewej-góry jak na tarczy; środek płaski i ciemniejszy.
            var outer = ctx
            outer.clip(to: wedge)
            var middle = outer
            outer.clip(to: inner, options: .inverse)
            let reach = r * 0.5.squareRoot()
            outer.fill(Path(ellipseIn: face), with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.38), Color.black.opacity(0.30)]),
                startPoint: CGPoint(x: cx - reach, y: cy - reach),
                endPoint: CGPoint(x: cx + reach, y: cy + reach)
            ))
            middle.clip(to: inner)
            middle.fill(inner, with: .color(Color.black.opacity(0.12)))
        }
    }

    /// Ta sama skala co wskaźnik gałki: 0 przy 135°, pełny zakres po 270°.
    private static func angle(_ norm: CGFloat) -> CGFloat {
        (135.0 + norm * 270.0) * (.pi / 180.0)
    }
}
