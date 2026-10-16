// PanelSurfaces.swift
// Przycisk i ekran pływających paneli — Parameter Pages, Parameter Overview, Patch
// Mutator i drzewo ewolucji mają jeden wygląd. Do 2026-09-27 każde okno miało własną
// kopię przycisku (inny rozmiar liter w Mutatorze, obrys wychodzący poza przycisk)
// i własny ekran, a żadne nie reagowało na View ▸ 3D Buttons and Screens.
//
// Wypukłość i wgłębienie to ten sam `Bevel` co na kanwie (`PanelFace`), za tym samym
// wyłącznikiem: przycisk wypukły, ekran wklęsły.

import G2EditorCore
import SwiftUI

enum PanelSurface {
    /// Okna pokazują kontrolki modułu w podwójnej skali (`MutatorMetrics.controlScale`),
    /// więc i cień krawędzi jest dwa razy szerszy — w skali 1:1 na dużym przycisku
    /// wyglądałby jak cienka kreska.
    static let bevelScale: CGFloat = 2
    static let screenCornerRadius = UIMetrics.graphCornerRadius * 2
    static let screenBorderWidth: CGFloat = 0.8
}

struct PanelButtonStyle: ButtonStyle {
    let width: CGFloat
    let height: CGFloat
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        let radius = UIMetrics.buttonFlatCornerRadius * 2
        let shape = RoundedRectangle(cornerRadius: radius)
        configuration.label
            .font(.system(size: PanelTypography.button, weight: .bold))
            .fontWidth(.condensed)
            .foregroundStyle(active ? Color.white : Color(white: 0.20))
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .frame(width: width, height: height)
            .background {
                ZStack {
                    shape.fill((active ? UIColor.buttonActive : UIColor.buttonInactive)
                        .opacity(configuration.isPressed ? 0.75 : 1))
                    PanelBevel(cornerRadius: radius, raised: true)
                }
            }
            // `strokeBorder`, nie `stroke`: obwódka ma leżeć w środku, żeby przycisk
            // zajmował dokładnie tyle pikseli co ekran nad nim.
            .overlay(shape.strokeBorder(UIColor.buttonBorder, lineWidth: 0.8))
            .contentShape(shape)
    }
}

extension View {
    /// Ekran okna: tło LCD, obrys i wgłębienie; treść (napis, chromosom) leży na wierzchu.
    func panelScreen(fill: Color = UIColor.lcdBackground,
                     cornerRadius: CGFloat = PanelSurface.screenCornerRadius) -> some View
    {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return background {
            ZStack {
                shape.fill(fill)
                PanelBevel(cornerRadius: cornerRadius, raised: false)
            }
        }
        .overlay(shape.stroke(UIColor.graphBorder, lineWidth: PanelSurface.screenBorderWidth))
        .clipShape(shape)
    }
}

extension View {
    /// Pole grupy (strona A…E w Overview, pas wariacji w Mutatorze) — lekko ciemniejsze
    /// od tła okna w dzień, jaśniejsze w nocy.
    func panelGroupBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelSurface.screenCornerRadius)
        return background(shape.fill(UIColor.panelWell))
            .overlay(shape.stroke(UIColor.graphBorder.opacity(0.55), lineWidth: PanelSurface.screenBorderWidth))
    }
}

/// Krawędzie przycisku (jasna lewa-góra) albo ekranu (ciemna lewa-góra).
private struct PanelBevel: View {
    let cornerRadius: CGFloat
    let raised: Bool
    @AppStorage(PanelShading.storageKey) private var shading = true

    var body: some View {
        if shading {
            Canvas { ctx, size in
                let scale = PanelSurface.bevelScale
                var scaled = ctx
                scaled.scaleBy(x: scale, y: scale)
                let rect = CGRect(x: 0, y: 0, width: size.width / scale, height: size.height / scale)
                if raised {
                    Bevel.raise(scaled, rect, cornerRadius: cornerRadius / scale)
                } else {
                    Bevel.recess(scaled, rect, cornerRadius: cornerRadius / scale)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
