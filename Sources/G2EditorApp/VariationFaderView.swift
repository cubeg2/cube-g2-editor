// VariationFaderView.swift
// Fader wariacji (życzenie z forum #13) — suwak pod ośmioma przyciskami wariacji.
//
// Suwak ma zawsze długość ośmiu przycisków, a przystanki dzielą ją po równo — ile ich
// jest, tyle odcinków. Wariacja identyczna z poprzednią nie ma przystanku (decyzja
// Kuby); które wariacje się mieszają, pokazują podświetlone przyciski. W porównaniu (Shift-klik) przystanki są dwa — grająca
// i porównywana — a suwak świeci turkusem, kolorem porównania. Logika i wysyłka do
// Norda → `PatchState+VariationFader`, [[Docs/ui/variations]] „Variation fader”.

import G2Core
import G2EditorCore
import SwiftUI

struct VariationFaderView: View {
    let state: PatchState
    let slot: Int
    /// Długość suwaka i odległość skrajnych przystanków od jego końców (pół przycisku).
    /// Domyślnie osiem przycisków belki; Mutator podaje osiem swoich kratek wariacji.
    var length: CGFloat = Self.width
    var stopInset: CGFloat = TopBarMetrics.controlSide / 2

    static let height: CGFloat = 14
    /// Odstęp przycisków w pasie wariacji — musi się zgadzać z `VariationBarView`.
    static let buttonSpacing: CGFloat = 3
    private static let pitch = TopBarMetrics.controlSide + buttonSpacing
    static let width = pitch * 8 - buttonSpacing

    @State private var dragging = false
    @Environment(\.colorScheme) private var colorScheme

    /// Przystanki rozłożone równo na całej długości ośmiu przycisków (prośba Kuby
    /// 2026-11-03): pierwszy pod środkiem „1”, ostatni pod środkiem „8”. Przy ośmiu
    /// różnych wariacjach każdy stoi pod swoim przyciskiem; przy porównaniu lewy koniec
    /// to grająca, prawy — porównywana.
    private func x(ofStop index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return stopInset }
        return stopInset + (length - 2 * stopInset) * CGFloat(index) / CGFloat(count - 1)
    }

    var body: some View {
        let stops = state.variationFaderStops(slot: slot)
        let position = state.variationFaderPosition(slot: slot)
        let comparing = state.comparedVariation(slot: slot) != nil
            || state.activeVariationFader(slot: slot)?.comparing == true
        // Nocą zielona jak kontur przycisku „On” w pasku slotu (systemowa zieleń; przez chwilę
        // była zieleń napisów ekranów), w dzień jak obwódka zapalonego przycisku wariacji
        // (kolor akcentu) — prośby Kuby 2026-11-04; przy porównaniu turkus — kolor porównania.
        let tint = comparing ? UIColor.variationCompare
            : colorScheme == .dark ? Color.green : Color.accentColor
        let xs = stops.indices.map { x(ofStop: $0, count: stops.count) }
        let usable = stops.count > 1

        Canvas { context, size in
            let low = x(ofStop: 0, count: 2), high = x(ofStop: 1, count: 2)
            let mid = size.height / 2
            let track = Path(roundedRect: CGRect(x: low, y: mid - 1, width: max(high - low, 0), height: 2),
                             cornerRadius: 1)
            context.fill(track, with: .color(.primary.opacity(0.25)))
            for x in xs {
                context.fill(Path(ellipseIn: CGRect(x: x - 2, y: mid - 2, width: 4, height: 4)),
                             with: .color(.primary.opacity(0.45)))
            }
            // Sam kontur — tor i kropka przystanku widać przez jego środek (prośba Kuby 2026-11-04).
            guard usable, let position, let knob = Self.knobX(position, xs) else { return }
            Self.drawKnob(in: &context, at: CGPoint(x: knob, y: mid), tint: tint)
        }
        .frame(width: length, height: Self.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard usable else { return }
                    if !dragging {
                        dragging = true
                        state.focusSlot(slot)
                    }
                    state.moveVariationFader(to: Self.position(at: drag.location.x, xs), slot: slot)
                }
                .onEnded { _ in
                    guard dragging else { return }
                    dragging = false
                    state.endVariationFaderGesture(slot: slot)
                }
        )
        .opacity(usable ? 1 : 0.4)
        .help(comparing
            ? "Fade between the playing and the compared variation"
            : "Fade smoothly through the variations – identical neighbours are skipped")
    }

    private static let knobRadius: CGFloat = 6

    private static func knobRect(at center: CGPoint) -> CGRect {
        CGRect(x: center.x - knobRadius, y: center.y - knobRadius, width: 2 * knobRadius, height: 2 * knobRadius)
    }

    /// Gałka (prośba Kuby 2026-11-04): sam kontur bez wypełnienia. Wcześniej pełna kulka
    /// z połyskiem i jasnym środkiem.
    private static func drawKnob(in context: inout GraphicsContext, at center: CGPoint, tint: Color) {
        context.stroke(Path(ellipseIn: knobRect(at: center).insetBy(dx: 1, dy: 1)), with: .color(tint), lineWidth: 2)
    }

    /// Gałka między dwoma sąsiednimi przystankami.
    private static func knobX(_ position: Double, _ xs: [CGFloat]) -> CGFloat? {
        guard !xs.isEmpty else { return nil }
        let clamped = min(Double(xs.count - 1), max(0, position))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, xs.count - 1)
        return xs[lower] + (xs[upper] - xs[lower]) * CGFloat(clamped - Double(lower))
    }

    /// Położenie fadera pod kursorem — przystanki stoją w równych odstępach.
    private static func position(at x: CGFloat, _ xs: [CGFloat]) -> Double {
        guard let first = xs.first, let last = xs.last, last > first else { return 0 }
        let fraction = min(1, max(0, (x - first) / (last - first)))
        return Double(fraction) * Double(xs.count - 1)
    }
}
