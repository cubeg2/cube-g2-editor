import G2Core
import G2EditorCore
import SwiftUI

// Kłódka przy kontrolce z „Lock Across Variations" — ta wartość nie zmienia się
// z wariacją. Pomarańczowa jak „Edit all", bo oba dotyczą wszystkich ośmiu wariacji.
// Moduł bez blokad rysuje się dokładnie tak jak wcześniej.

extension PatchCanvasView {
    func drawVariationLocks(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        guard !module.variationLockedParameters.isEmpty,
              let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return }
        for index in module.variationLockedParameters {
            guard let control = parameterControlRect(module: module, paramIndex: index, ui: ui, rect: rect)
            else { continue }
            drawPadlock(ctx, at: CGPoint(x: control.maxX, y: control.minY), inside: rect)
        }
    }

    /// Prostokąt kontrolki parametru — ta sama geometria, którą trafia `findHoverHit`.
    /// Gałka obrotowa ma tu prostokąt pod kłódkę (niższy), nie samą tarczę.
    func parameterControlRect(module: G2Module, paramIndex: Int, ui: ModuleUIDef,
                              rect: CGRect) -> CGRect?
    {
        if let knob = ui.knobs.first(where: { $0.codeRef == paramIndex }) {
            let origin = knobOrigin(module: module, knob: knob)
            let tlx = rect.minX + origin.x
            let tly = rect.minY + origin.y
            if knob.type.isRotary {
                let off = knob.type.centerOffsetPt
                let r = knob.type.radiusPt
                // Górny brzeg niżej niż szczyt gałki — kłódka staje przy jej prawym boku,
                // nie w pustym rogu nad nią (prośba użytkownika 2026-10-30).
                return CGRect(x: tlx + off.x - r, y: tly + off.y - r * 0.35, width: r * 2, height: r * 1.35)
            }
            if knob.type == .slider || knob.type == .seqSlider {
                return faderLayout(module: module, knob: knob, ui: ui, rect: rect).track
            }
            let size = knob.type.sliderSizePt
            return CGRect(x: tlx, y: tly, width: size.width, height: size.height)
        }
        if let btn = ui.incDecButtons.first(where: { $0.codeRef == paramIndex }) {
            return incDecPairFrame(btn, module: module, rect: rect)
        }
        if let btn = ui.buttonsFlat.first(where: { $0.codeRef == paramIndex }) {
            var x = btn.xPt
            if module.typeID == 7, btn.codeRef == 2,
               let fmLin = ui.buttonsFlat.first(where: { $0.codeRef == 10 })
            {
                x = fmLin.xPt + fmLin.widthPt - btn.widthPt
            }
            return CGRect(x: rect.minX + x, y: rect.minY + flatButtonYPt(module: module, button: btn, ui: ui),
                          width: max(btn.widthPt, 8), height: 7)
        }
        if let btn = ui.buttonsText.first(where: { $0.codeRef == paramIndex }) {
            return CGRect(x: rect.minX + btn.xPt, y: rect.minY + rndClkADiceYPt(module: module, btn: btn, ui: ui),
                          width: max(btn.widthPt, 6), height: buttonTextHeight(module: module, button: btn))
        }
        if let btn = ui.buttonsRadio.first(where: { $0.codeRef == paramIndex }) {
            let rightInset: CGFloat = module.typeID == 163 && btn.orientation == "Horizontal" ? 1.5 : 0
            let bw = max(btn.buttonWidthPt, 6) - rightInset / CGFloat(btn.columns)
            return CGRect(x: rect.minX + btn.xPt, y: rect.minY + btn.yPt,
                          width: bw * CGFloat(btn.columns), height: 7 * CGFloat(btn.rows))
        }
        if let shift = ui.levelShifts.first(where: { $0.codeRef == paramIndex }) {
            return levelShiftRect(shift, moduleTypeID: module.typeID, in: rect)
        }
        if let selector = ui.partSelectors.first(where: { $0.codeRef == paramIndex && $0.usesParameter }) {
            return partSelectorRect(selector, moduleTypeID: module.typeID, in: rect)
        }
        return nil
    }

    /// Kłódka stojąca lewym dolnym rogiem na prawym górnym rogu kontrolki. Przy krawędzi
    /// modułu przesuwa się do środka, żeby nie wystawała poza moduł (prośba użytkownika
    /// 2026-10-30: Exp w Mix4-1S, rząd fal OscB).
    private func drawPadlock(_ ctx: GraphicsContext, at corner: CGPoint, inside moduleRect: CGRect) {
        let width: CGFloat = 3.4
        let bodyHeight: CGFloat = 2.6
        let shackleRise = width * 0.3 + 0.55
        let bounds = moduleRect.insetBy(dx: 1, dy: 1)
        let x = min(max(corner.x - width * 0.65, bounds.minX), bounds.maxX - width)
        let y = min(max(corner.y - bodyHeight * 0.15, bounds.minY + shackleRise), bounds.maxY - bodyHeight)
        let body = CGRect(x: x, y: y, width: width, height: bodyHeight)
        var shackle = Path()
        shackle.addArc(center: CGPoint(x: body.midX, y: body.minY), radius: width * 0.3,
                       startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        let outline = Color.black.opacity(0.7)
        ctx.stroke(shackle, with: .color(outline), lineWidth: 1.1)
        ctx.stroke(shackle, with: .color(.orange), lineWidth: 0.55)
        let bodyPath = Path(roundedRect: body, cornerRadius: 0.5)
        ctx.fill(bodyPath, with: .color(.orange))
        ctx.stroke(bodyPath, with: .color(outline), lineWidth: 0.35)
    }
}
