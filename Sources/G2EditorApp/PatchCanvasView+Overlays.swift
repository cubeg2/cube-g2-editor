// PatchCanvasView+Overlays.swift
// Żółte dymki nad kontrolkami patcha — klawisze F5–F8 z instrukcji Clavii (str. 132):
//
//   F5  View Parameter Values          — wartość każdej gałki i suwaka
//   F6  View Morph Groups              — do którego morfu parametr jest przypisany
//   F7  View Knob Assignments          — na której gałce panelu wisi
//   F8  View MIDI CC# Assignments      — jaki numer CC ma przypisany
//
// Nakładka to osobna warstwa nad kanwą modułów: włącza się i gasi jednym klawiszem,
// a gdy jest wygaszona, nie kosztuje nic (widok nie jest w ogóle montowany).

import G2Core
import G2EditorCore
import SwiftUI

extension PatchCanvasView {
    /// Warstwa dymków. Montowana tylko przy włączonej nakładce.
    @ViewBuilder
    var overlayLabelsView: some View {
        if !isPreviewMode, overlayMode != .none {
            Canvas { ctx, _ in
                ctx.scaleBy(x: zoom, y: zoom)
                drawOverlayLabels(ctx)
            }
            .allowsHitTesting(false)
        }
    }

    private func drawOverlayLabels(_ ctx: GraphicsContext) {
        let ro = rowOffset
        let mods = modules
        for module in mods {
            guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { continue }
            let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)
            for knob in ui.knobs {
                guard let text = overlayText(module: module, paramIndex: knob.codeRef) else { continue }
                drawOverlayBadge(ctx, text: text, at: overlayAnchor(module: module, knob: knob, rect: rect))
            }
            // Przyciski też bywają przypisane do gałki panelu i do CC — instrukcja
            // wymienia je obok gałek („a parameter can be … a button, radio buttons
            // or scroll button", str. 90). Wartości przy nich nie pokazujemy: napis
            // na przycisku już ją niesie.
            guard overlayMode != .values else { continue }
            for button in ui.buttonsFlat {
                guard let text = overlayText(module: module, paramIndex: button.codeRef) else { continue }
                let anchor = CGPoint(x: rect.minX + button.xPt,
                                     y: rect.minY + flatButtonYPt(module: module, button: button, ui: ui))
                drawOverlayBadge(ctx, text: text, at: anchor)
            }
        }
    }

    /// Lewy górny róg dymka: tuż nad kontrolką, żeby nie zasłaniać jej wskaźnika.
    private func overlayAnchor(module: G2Module, knob: BVKnob, rect: CGRect) -> CGPoint {
        let origin = knobOrigin(module: module, knob: knob)
        let x = rect.minX + origin.x
        let y = rect.minY + origin.y
        guard knob.type.isRotary else { return CGPoint(x: x, y: y - 1) }
        return CGPoint(x: x + knob.type.centerOffsetPt.x - knob.type.radiusPt,
                       y: y + knob.type.centerOffsetPt.y - knob.type.radiusPt - 1)
    }

    /// Napis w dymku — `nil` znaczy „tu nie ma czego pokazać".
    private func overlayText(module: G2Module, paramIndex: Int) -> String? {
        let location = area.rawValue
        switch overlayMode {
        case .none:
            return nil

        case .values:
            guard module.parameters.indices.contains(paramIndex) else { return nil }
            return "\(module.parameters[paramIndex])"

        case .morphGroups:
            let morphs = patch.morphs(variation: patch.activeVariation, location: location,
                                      moduleID: module.id, paramIndex: paramIndex)
            guard !morphs.isEmpty else { return nil }
            return morphs
                .map { morphName($0.morph) }
                .joined(separator: "+")

        case .knobAssignments:
            guard let index = patch.knobIndex(location: location, moduleID: module.id,
                                              paramIndex: paramIndex) else { return nil }
            let page = index / G2KnobPages.knobsPerPage
            let column = index % G2KnobPages.knobsPerPage + 1
            return "\(G2KnobPages.pageLabel(page)):\(column)"

        case .midiControllers:
            guard let cc = patch.midiController(for: location, moduleID: module.id,
                                                paramIndex: paramIndex) else { return nil }
            return "CC \(cc)"
        }
    }

    /// Sam dymek: żółte pudełko z czarnym napisem, jak w oryginale.
    private func drawOverlayBadge(_ ctx: GraphicsContext, text: String, at point: CGPoint) {
        let resolved = ctx.resolve(
            Text(text)
                .font(.system(size: Self.overlayFontSize, weight: .semibold, design: .monospaced))
                .foregroundColor(.black)
        )
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        let box = CGRect(x: point.x, y: point.y - size.height - 1,
                         width: size.width + 2.4, height: size.height + 1.2)
        ctx.fill(Path(roundedRect: box, cornerRadius: 1.0), with: .color(Self.overlayFill))
        ctx.stroke(Path(roundedRect: box, cornerRadius: 1.0),
                   with: .color(.black.opacity(0.55)), lineWidth: 0.3)
        ctx.draw(resolved, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    private static let overlayFontSize: CGFloat = 4.2
    /// Ten sam żółty co dymki wartości w oryginale.
    private static let overlayFill = Color(red: 1.0, green: 0.94, blue: 0.55)
}
