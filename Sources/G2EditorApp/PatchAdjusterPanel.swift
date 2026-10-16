// PatchAdjusterPanel.swift
// Okno Patch Adjustera — osiem gałek „wszystkie ataki / decay / sustain / release /
// mod. rate / barwa / rezonanse / efekty" (instrukcja Clavii, rozdz. 8, str. 113).
//
// Układ wprost ze zrzutu oryginału: jeden rząd gałek, nad każdą zielony trójkącik
// środka, pod każdą podpis. Po czwartej gałce („Release") jest szersza przerwa —
// pierwsza czwórka to obwiednie, reszta to wszystko inne.
//
// Liczenie wartości siedzi w `G2PatchAdjuster` (G2Core), stan gałek i zdjęcie
// odniesienia w `PatchState.setAdjuster` — tutaj jest wyłącznie to, co widać.

import G2Core
import G2EditorCore
import SwiftUI

struct PatchAdjusterPanel: View {
    let state: PatchState

    /// Osiem komórek plus przerwa po „Release" mieszczą się w oknie szerokim jak
    /// Parameter Pages (530 pt minus 2 × 14 pt marginesu).
    private static let cellWidth: CGFloat = 60
    /// Przerwa między obwiedniami a resztą — na zrzucie oryginału wyraźnie szersza.
    private static let groupGap: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(G2AdjusterKnob.allCases.enumerated()), id: \.element) { index, knob in
                if index == 4 { Color.clear.frame(width: Self.groupGap) }
                cell(knob)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Gałki liczą od zdjęcia patcha. Zmiana wariacji, slotu albo liczby modułów
        // to zdjęcie unieważnia: zmiany zostają, gałki wracają na środek (str. 113).
        .onChange(of: state.adjusterContextID) { _, _ in state.commitAdjuster() }
        .disabled(!state.isLoaded)
    }

    private func cell(_ knob: G2AdjusterKnob) -> some View {
        let value = state.adjusterValue(knob)
        return VStack(spacing: 2) {
            centreMarker(knob)
            SmallKnob(
                value: value,
                range: G2PatchAdjuster.range,
                size: SmallKnob.panelSize,
                onBegin: { state.beginParameterGesture() },
                onChange: { state.setAdjuster(knob, to: $0) },
                onEnd: { state.endParameterGesture() }
            )
            Text(knob.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .frame(width: Self.cellWidth)
        .help("\(knob.title) — \(knob.summary)")
    }

    /// Trójkącik środka. Instrukcja: „wystarczy wrócić gałką na środek albo kliknąć
    /// znacznik środka" — więc jest to przycisk, nie ozdoba.
    private func centreMarker(_ knob: G2AdjusterKnob) -> some View {
        Button {
            state.beginParameterGesture()
            state.setAdjuster(knob, to: 0)
            state.endParameterGesture()
        } label: {
            CentreTriangle()
                .fill(Color(red: 0.13, green: 0.85, blue: 0.13))
                .frame(width: 11, height: 6)
        }
        .buttonStyle(.plain)
        .help("Back to the centre — undoes what this knob changed")
    }
}

/// Trójkąt wierzchołkiem w dół, jak znacznik środka w oknie oryginału.
private struct CentreTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
