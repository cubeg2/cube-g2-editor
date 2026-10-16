import CoreGraphics
import G2Core

// MARK: - Layout constants

//
// Panel coordinate system (BVerhue NMG2Data.pas):
//   UNITS_COL = 255,  UNIT_MARGIN = 2,  TOTAL_COL = 259
//   UNITS_ROW = 15,   UNIT_MARGIN = 2,  TOTAL_ROW = 19
//
//   X_SCALE = SW_COL_W / TOTAL_COL = 140 / 259 = 0.54054 pt/unit
//   Y_SCALE = SW_Y_SPAN / TOTAL_ROW = 47.8516 / 19 = 2.5185 pt/unit  (OLD)
//
// Column slot pitch: 1 slot = TOTAL_COL units = 259 * X_SCALE = 140pt exactly.
//   → xSpan = 140pt  (modules placed edge-to-edge in panel space).
//   Module body rect x = col * 140pt + padding.  No extra visual gap — the small
//   gap between adjacent modules comes from the 2-unit margin baked into the
//   X coords of all DB elements (they start ~1pt inside the module).
//
// CBMP bitmaps (256px wide, N×15px tall):
//   bitmap px → screen pt: px * (140/256)
//   1 DB-row in screen pts = 15 * (140/256) = 8.203125 pt/row  (= ySpan)
//   connYScale = 8.203125 / 47.8515625 ≈ 0.17143
//   All DB Y coords × connYScale → screen pts from module rect.minY.
//
// Sizes (knob radius, connector diameter) use X_SCALE, NOT connYScale.

enum PatchLayout {
    static let X_SCALE: CGFloat = 140.0 / 259.0 // 0.54054 pt/panel-unit
    static let moduleWidth: CGFloat = 140 // 256px bitmap width in pt
    static let xSpan: CGFloat = 140 // TOTAL_COL * X_SCALE = 140pt

    /// Skala piksela źródłowego panelu BVerhue/CBMP do punktów ekranu.
    static let bverhuePixelScale: CGFloat = 140.0 / 256.0

    static let ySpan: CGFloat = bverhuePixelScale * 15 // 8.203125 pt per DB-row
    static let yGap: CGFloat = 0
    static let rowHeight: CGFloat = ySpan

    /// DB Y coords (generated at 47.85pt/row) → new 8.203pt/row
    static let connYScale: CGFloat = ySpan / 47.8515625 // ≈ 0.17143

    static let connHorizUnit: CGFloat = moduleWidth / 20.0
    static let connVertUnit: CGFloat = rowHeight

    /// Header strip = exactly 1 DB-row.  Name module (h=1) → only header, no body.
    static let headerH: CGFloat = ySpan

    /// Stała oś przycisku podmiany. Pokrywa się ze środkiem gniazda o XPos=4,
    /// czyli skrajnie lewego gniazda używanego m.in. przez OscA.
    static let replacementIconCenterX: CGFloat = (4 + 5.5) * bverhuePixelScale
    static let replacementIconSize: CGFloat = headerH - 2.8

    /// Stały margines ekranowy chroniący nazwę ghosta przed systemowym kursorem.
    static let dragGhostLabelLeadingPadding: CGFloat = 24

    /// Wąski oddech wokół treści patcha — celowo mały, jak w oryginalnym G2.
    ///
    /// Kusi, żeby powiększyć go do szerokości kolumny i „zrobić miejsce" na wstawianie
    /// modułów przed kolumną 0 / nad wierszem 0. To ślepa uliczka: siatka G2 nie ma
    /// ujemnych indeksów, `rowOffset` i tak dosuwa patch do górnej krawędzi, a kolizje
    /// rozsuwają moduły wyłącznie w pionie. Powstałby pusty obszar, w którym upuszczenie
    /// modułu robi co innego, niż sugeruje jego położenie. Wstawienie kolumny przed
    /// istniejącymi to operacja na danych patcha (przenumerowanie kolumn), nie wolne
    /// miejsce na canvasie.
    ///
    /// ⚠️ Ta stała jest originem `moduleRect`, więc hit-testing, drop, overlaye i miniatury
    /// modułów w sidebarze skalują się razem z nią.
    static let padding: CGFloat = 12

    // MARK: - Authoritative heights from CBMP bitmaps (pixels / 15, 15px = 1 row)

    /// Overrides ModuleDef.height when a bitmap is available (bitmaps extracted from
    /// the original Nord G2 Editor DMG are pixel-perfect and authoritative).
    /// Funkcjonalna wysokość modułu w DB-rows: z definicji ModuleDef.xml.
    static func moduleHeight(typeID _: Int, def: ModuleDef?) -> Int {
        def?.height ?? 2
    }

    /// Efektywna wysokość modułu: min(odstęp do następnego modułu w tej samej kolumnie,
    /// max wysokość z bitmapy). Zapobiega wychodzeniu modułów poza Name Bar.
    static func effectiveHeight(module: G2Module, def: ModuleDef?,
                                allModules: [G2Module]) -> Int
    {
        let maxH = moduleHeight(typeID: module.typeID, def: def)
        // Najbliższy moduł poniżej w tej samej kolumnie. Jedno przejście bez tablic
        // pośrednich — wołane dla każdego modułu przy każdym rysowaniu i trafianiu.
        var nextRow = Int.max
        for other in allModules where other.column == module.column && other.row > module.row {
            nextRow = min(nextRow, other.row)
        }
        return nextRow == Int.max ? maxH : min(nextRow - module.row, maxH)
    }

    // MARK: - Row offset (removes blank space above first module)

    static func minRow(modules: [G2Module]) -> Int {
        modules.map(\.row).min() ?? 0
    }

    // MARK: - Computed geometry

    /// Najbliższa pozycja siatki dla lewego górnego rogu modułu na canvasie.
    static func gridPosition(at point: CGPoint, rowOffset: Int = 0) -> (column: Int, row: Int) {
        let column = max(0, Int(round((point.x - padding) / xSpan)))
        let row = max(0, Int(round((point.y - padding) / ySpan)) + rowOffset)
        return (column, row)
    }

    /// Rect modułu z efektywną wysokością (gap-based).
    static func moduleRect(_ module: G2Module, def: ModuleDef?,
                           rowOffset: Int = 0,
                           allModules: [G2Module] = []) -> CGRect
    {
        let h = allModules.isEmpty
            ? CGFloat(moduleHeight(typeID: module.typeID, def: def))
            : CGFloat(effectiveHeight(module: module, def: def, allModules: allModules))
        return CGRect(
            x: padding + CGFloat(module.column) * xSpan,
            y: padding + CGFloat(module.row - rowOffset) * ySpan,
            width: moduleWidth,
            height: h * ySpan
        )
    }

    static func connectorCenter(
        module: G2Module,
        def: ModuleDef?,
        connIndex: Int,
        isOutput: Bool,
        rowOffset: Int = 0
    ) -> CGPoint {
        let rect = moduleRect(module, def: def, rowOffset: rowOffset)

        // ── BVerhue .txt positions (primary — complete & accurate) ────────────
        // XPos/YPos in .txt = top-left of the 11×11 Gen1px connector widget.
        // Center = top-left + half-size = XPos/YPos + 5.5 Gen1px × (140/256) ≈ +3.008pt.
        // Source: CreateConnectorIn/Out in BVE.NMG2TexturesGL.pas — OuterSize = SCALE_X*11.
        if let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) {
            let list = isOutput ? ui.outputs : ui.inputs
            if connIndex < list.count {
                let conn = list[connIndex]
                let half: CGFloat = 5.5 * (140.0 / 256.0) // ≈ 3.008 pt
                return CGPoint(x: rect.minX + conn.xPt + half,
                               y: rect.minY + conn.yPt + half)
            }
        }

        // Awaryjne przybliżenie dla nieznanego typu modułu. Wszystkie 167 typów,
        // które mają panel, są chronione testem kompletności ModuleUIDatabase.
        let conns = isOutput ? (def?.outputs ?? []) : (def?.inputs ?? [])
        guard connIndex < conns.count else {
            return CGPoint(x: isOutput ? rect.maxX - 4 : rect.minX + 4,
                           y: isOutput ? rect.maxY - 4 : rect.minY + 4)
        }
        let conn = conns[connIndex]
        return CGPoint(x: rect.minX + CGFloat(conn.horiz) * connHorizUnit,
                       y: rect.minY + CGFloat(conn.vert) * connVertUnit)
    }

    static func replacementIconRect(in moduleRect: CGRect) -> CGRect {
        CGRect(
            x: moduleRect.minX + replacementIconCenterX - replacementIconSize / 2,
            y: moduleRect.minY + (headerH - replacementIconSize) / 2,
            width: replacementIconSize,
            height: replacementIconSize
        )
    }

    static func moduleNameStartX(in moduleRect: CGRect) -> CGFloat {
        replacementIconRect(in: moduleRect).maxX + 2.5
    }

    static func canvasSize(modules: [G2Module], defs: (Int) -> ModuleDef?,
                           rowOffset: Int = 0) -> CGSize
    {
        var maxX: CGFloat = 500
        var maxY: CGFloat = 300
        for m in modules {
            let r = moduleRect(m, def: defs(m.typeID), rowOffset: rowOffset)
            maxX = max(maxX, r.maxX + padding)
            maxY = max(maxY, r.maxY + padding)
        }
        return CGSize(width: maxX, height: maxY)
    }
}
