// ModuleUILayout.swift
// G2Core — korekty pozycji widżetów, których pliki BVerhue nie wyrównały.
//
// Stosowane RAZ przy ładowaniu bazy (ModuleUIDatabase), więc rysowanie, trafianie
// kursorem i dymki widzą tę samą, poprawioną geometrię.
//
// Reguła: przycisk Power ("Active") wyrównany do sąsiadujących gniazd — na ich
// osi, a między dwoma gniazdami w kolumnie/rzędzie: w równej odległości od obu.

import CoreGraphics

enum ModuleUILayout {
    // Metryki muszą się zgadzać z UIMetrics/PatchLayout w warstwie UI — G2Core ich
    // nie widzi, więc te same wartości są tu powtórzone.
    private static let gen1Scale: CGFloat = 140.0 / 256.0
    private static let connHalf: CGFloat = 5.5 * gen1Scale // 3.008 pt
    private static let buttonTextH: CGFloat = 6.5
    private static let buttonFlatH: CGFloat = 7.0
    private static let textFieldH: CGFloat = 6.5
    private static let incDecH: CGFloat = 10.0 * gen1Scale
    private static let incDecGap: CGFloat = 0.5
    private static let minButtonW: CGFloat = 6.0
    /// Połowa RYSOWANEGO gniazda (kolorowy środek + ciemna obwódka) — większa niż
    /// `connHalf` z danych BVerhue, więc odstępy liczymy od niej.
    private static let socketOuterHalf: CGFloat = 2.8 + 0.6
    /// Wewnętrzna krawędź ramki panelu — ta sama stała co przy tytule LevConv.
    private static let panelTop: CGFloat = 0.7
    /// 1 DB-row w screen pt (= wysokość paska nagłówka) — te same jednostki co
    /// BVerhue XPos/YPos po przeliczeniu przez `gen1Scale`.
    private static let rowHeight: CGFloat = 140.0 * 15.0 / 256.0 // 8.203 pt

    static func aligned(_ ui: ModuleUIDef, def: ModuleDef?) -> ModuleUIDef {
        var ui = ui
        alignPowerButton(&ui, def: def)
        alignKeyQuantRangeScreen(&ui)
        centerKeyQuantKeyboard(&ui, def: def)
        alignFltPhaseFrequencyField(&ui)
        alignMix2InvRow(&ui)
        centerMix4StereoExpButton(&ui)
        alignMixFaderChannelButtons(&ui)
        centerSequencerStepRow(&ui)
        centerSwitchButton(&ui, def: def)
        alignValueSwitchScreen(&ui)
        spaceTrigSymbolsFromSockets(&ui)
        return ui
    }

    // MARK: - Przycisk „Switch" na osi modułu

    /// ConstSwM/ConstSwT oraz chwilowe Sw2-1M/Sw1-2M mają w źródle przycisk „Switch"
    /// odrobinę nad osią panelu, przez co odstawał od rzędu gałka–ekran–rysunek,
    /// który stoi dokładnie na środku. Wstawiamy go na tę samą oś. Występuje tylko
    /// w tych czterech modułach, więc rozpoznajemy go po napisie.
    private static func centerSwitchButton(_ ui: inout ModuleUIDef, def: ModuleDef?) {
        guard let height = def?.height,
              let index = ui.buttonsText.firstIndex(where: { $0.text == "Switch" })
        else { return }
        ui.buttonsText[index].yPt = (CGFloat(height) * rowHeight - buttonTextH) / 2
    }

    // MARK: - ValSw: ekran „Ctrl Value" w jednej linii z parą −/+

    /// Ekran i przyciski −/+ tworzą jeden widżet, ale w źródle ekran stoi 2 piksele
    /// wyżej niż przyciski i rząd wyglądał na przekrzywiony. Wyrównujemy DOLNE
    /// krawędzie — tak samo jak nazwy kanałów MixFader do gniazda Out.
    private static func alignValueSwitchScreen(_ ui: inout ModuleUIDef) {
        guard ui.name == "ValSw1-2" || ui.name == "ValSw2-1",
              let button = ui.incDecButtons.first,
              let index = ui.textFields.indices.first
        else { return }
        let buttonH = button.isVertical ? incDecH * 2 + incDecGap : incDecH
        ui.textFields[index].yPt = button.yPt + buttonH - textFieldH
    }

    // MARK: - Strzałki „Trig" w równym odstępie od gniazda

    /// Strzałka „Trig 1"/„Trig 2" stojąca zaraz za gniazdem jest tym samym
    /// widżetem w 30+ modułach, więc wszędzie musi odstawać od gniazda tak samo.
    /// W plikach BVerhue odstęp waha się od 1 do 3 pikseli Gen1 — przy 1 pikselu
    /// (SeqLev, SeqEvent) strzałka niemal dotyka gniazda, bo rysujemy je odrobinę
    /// większe niż źródłowa ramka 11×11. Normalizujemy do 2 pikseli, czyli do
    /// wartości, którą ma zdecydowana większość modułów (m.in. SeqVal i SeqNote).
    private static func spaceTrigSymbolsFromSockets(_ ui: inout ModuleUIDef) {
        let sockets = ui.inputs + ui.outputs
        let socketBoxW = 11.0 * gen1Scale
        let standardGap = 2.0 * gen1Scale
        let maxSourceGap = 4.0 * gen1Scale
        for index in ui.symbols.indices where ui.symbols[index].type.hasPrefix("Trig") {
            let sym = ui.symbols[index]
            let symCenterY = sym.yPt + sym.heightPt / 2
            func sameRow(_ socket: BVConnector) -> Bool {
                abs(socket.yPt + connHalf - symCenterY) <= sym.heightPt
            }
            // Gniazdo musi stać w tym samym rzędzie i TUŻ przed strzałką — dalsze
            // pary (np. „Park" na drugim końcu panelu) mają własne reguły.
            if let socket = sockets
                .filter({ sameRow($0) && (0 ... maxSourceGap).contains(sym.xPt - ($0.xPt + socketBoxW)) })
                .max(by: { $0.xPt < $1.xPt })
            {
                ui.symbols[index].xPt = socket.xPt + socketBoxW + standardGap
                continue
            }
            // Strzałka stojąca PRZED gniazdem (NoteSend: dwa groty „Trig 2" opisują
            // wejścia po swojej prawej). W źródle prześwit wynosi tam 0-1 piksela,
            // więc przy naszym, nieco szerszym gnieździe grot go dotykał.
            if let socket = sockets
                .filter({ sameRow($0) && (0 ... maxSourceGap).contains($0.xPt - (sym.xPt + sym.widthPt)) })
                .min(by: { $0.xPt < $1.xPt })
            {
                ui.symbols[index].xPt = socket.xPt - standardGap - sym.widthPt
            }
        }
    }

    // MARK: - Sekwencery: rząd przycisków kroku na osi swojej magistrali

    /// Przyciski kroku łączy z gniazdami po bokach pozioma magistrala, więc rząd
    /// musi stać na osi tych gniazd. W źródle YPos przycisku i gniazda różnią się
    /// o piksel, przez co rząd wypadał odrobinę wyżej niż linia, która przez niego
    /// przechodzi. Moduł może mieć kilka takich rzędów (SeqEvent ma dwa) i wcale
    /// nie musi mieć faderów — każdy rząd wyrównujemy osobno.
    private static func centerSequencerStepRow(_ ui: inout ModuleUIDef) {
        let stepIndices = ui.buttonsText.indices.filter { ui.buttonsText[$0].text.isEmpty }
        guard stepIndices.count >= 2 else { return }

        // Rzędy = przyciski o wspólnym YPos (tolerancja na zaokrąglenia źródła).
        var rows: [CGFloat: [Int]] = [:]
        for index in stepIndices {
            let key = (ui.buttonsText[index].yPt * 10).rounded() / 10
            rows[key, default: []].append(index)
        }

        // Rząd kroków sekwencera ma ich kilkanaście — niższy próg łapałby pojedyncze
        // bezimienne przyciski w modułach, które żadnej magistrali nie mają.
        for (_, indices) in rows where indices.count >= 8 {
            // Klucz grupowania jest zaokrąglony — oś liczymy z rzeczywistych pozycji.
            guard let rowTop = indices.map({ ui.buttonsText[$0].yPt }).min() else { continue }
            let rowCenter = rowTop + buttonTextH / 2
            let socketCenters = (ui.inputs + ui.outputs)
                .map { $0.yPt + connHalf }
                .filter { abs($0 - rowCenter) < 4.0 }
            guard !socketCenters.isEmpty else { continue }

            let target = socketCenters.reduce(0, +) / CGFloat(socketCenters.count)
            let delta = target - rowCenter
            guard abs(delta) > 0.01 else { continue }
            for index in indices {
                ui.buttonsText[index].yPt += delta
            }
        }
    }

    // MARK: - MixFader: nazwy kanałów w jednej linii z gniazdem Out

    /// Ch1…Ch8 kończyły się ~1,5pt wyżej niż kwadratowe gniazdo wyjścia w tym samym,
    /// dolnym rzędzie — cały rząd wyglądał na przekrzywiony. Wyrównujemy DOLNE
    /// krawędzie: to one tworzą wspólną linię, a przycisk i gniazdo mają różne
    /// wysokości. Przesunięcie w dół zabiera przy okazji miejsce parze ▲/▼ nad
    /// przyciskami, która wcześniej na nie nachodziła (patrz `faderLayout`).
    private static func alignMixFaderChannelButtons(_ ui: inout ModuleUIDef) {
        guard ui.name == "MixFader",
              let out = ui.outputs.max(by: { $0.yPt < $1.yPt })
        else { return }
        let targetY = out.yPt + connHalf + socketOuterHalf - buttonTextH
        for index in ui.buttonsText.indices where ui.buttonsText[index].text.hasPrefix("Ch") {
            ui.buttonsText[index].yPt = targetY
        }
    }

    // MARK: - Mix2-1B: rząd „Inv" + ekran

    /// BVerhue stawia przyciski „Inv" (Width:18) dokładnie 1 Gen1px od gniazda po
    /// lewej i od ekranu po prawej — przy naszych, nieco większych gniazdach przycisk
    /// styka się z obrysem. Zwężamy oba przyciski do wspólnej szerokości (ta sama para
    /// widżetów musi wyglądać identycznie) i wstawiamy każdy w środek jego własnej
    /// wolnej przestrzeni. Ekrany dostają YPos przycisków — mają tę samą wysokość, więc
    /// cały rząd siada na jednej osi zamiast stać 2 Gen1px wyżej.
    private static func alignMix2InvRow(_ ui: inout ModuleUIDef) {
        guard ui.name == "Mix2-1B" else { return }
        // Prześwit z każdej strony przycisku — na tyle duży, żeby było widać, że
        // przycisk NIE dotyka ani gniazda, ani ramki ekranu.
        let sideGap: CGFloat = 1.2

        var gaps: [Int: (left: CGFloat, right: CGFloat)] = [:]
        for (index, btn) in ui.buttonsText.enumerated() where btn.text == "Inv" {
            guard let socket = ui.inputs
                .filter({ $0.xPt < btn.xPt && abs($0.yPt - btn.yPt) < 4.0 })
                .max(by: { $0.xPt < $1.xPt }),
                let field = ui.textFields
                .filter({ $0.xPt > btn.xPt })
                .min(by: { $0.xPt < $1.xPt })
            else { continue }
            gaps[index] = (socket.xPt + connHalf + socketOuterHalf, field.xPt)
        }
        guard let width = gaps.values.map({ $0.right - $0.left - 2 * sideGap }).min(),
              width >= minButtonW
        else { return }

        for (index, gap) in gaps {
            ui.buttonsText[index].widthPt = width
            ui.buttonsText[index].xPt = (gap.left + gap.right) / 2 - width / 2
        }

        for index in ui.textFields.indices {
            guard let btn = ui.buttonsText
                .filter({ $0.text == "Inv" && $0.xPt < ui.textFields[index].xPt })
                .max(by: { $0.xPt < $1.xPt })
            else { continue }
            ui.textFields[index].yPt = btn.yPt
        }
    }

    // MARK: - Mix4-1S: przycisk „Exp" nad gałką

    /// W źródle przycisk stoi na YPos:4 i jego dolna krawędź dotyka tarczy gałki pod
    /// spodem (zostaje ~0,1pt). Wstawiamy go w środek wolnej przestrzeni między
    /// wewnętrzną krawędzią ramki a górą tarczy — po tyle samo światła u góry i u dołu.
    private static func centerMix4StereoExpButton(_ ui: inout ModuleUIDef) {
        guard ui.name == "Mix4-1S",
              let index = ui.buttonsFlat.firstIndex(where: { $0.options.contains("Exp") })
        else { return }
        let btn = ui.buttonsFlat[index]
        guard let knob = ui.knobs
            .filter({
                $0.type.isRotary && $0.yPt > btn.yPt
                    && $0.xPt < btn.xPt + btn.widthPt
                    && $0.xPt + 2 * $0.type.centerOffsetPt.x > btn.xPt
            })
            .min(by: { $0.yPt < $1.yPt })
        else { return }
        let knobTop = knob.yPt + knob.type.centerOffsetPt.y - knob.type.radiusPt
        let free = knobTop - panelTop - buttonFlatH
        guard free > 0 else { return }
        ui.buttonsFlat[index].yPt = panelTop + free / 2
    }

    // MARK: - FltPhase: różnica Gen1 ↔ oryginalny panel

    private static func alignFltPhaseFrequencyField(_ ui: inout ModuleUIDef) {
        guard ui.name == "FltPhase",
              let index = ui.textFields.firstIndex(where: { $0.id == 11 })
        else { return }
        // Oryginalny panel: częstotliwość odczytuje parametr 0 i zależy od parametru 1.
        // Gen1 błędnie zapisał MasterRef:1 bez Dependencies, przez co LCD nie mógł
        // odzwierciedlać tej samej relacji co oryginalny panel Clavii.
        ui.textFields[index].masterRef = 0
        ui.textFields[index].dependencies = [1]
    }

    // MARK: - Power względem gniazd

    private static func alignPowerButton(_ ui: inout ModuleUIDef, def: ModuleDef?) {
        guard let def else { return }
        let conns = (ui.inputs + ui.outputs).map {
            CGPoint(x: $0.xPt + connHalf, y: $0.yPt + connHalf)
        }
        guard !conns.isEmpty else { return }

        // Ta sama kolumna/rząd: środki nie dalej niż pół gniazda od siebie.
        let axisTolerance: CGFloat = 4.0
        // "Bezpośrednie sąsiedztwo": ok. 2,5 rzędu — dalsze gniazda nie opisują
        // już tego samego miejsca na panelu.
        let reach: CGFloat = 20.0

        ui.buttonsText = ui.buttonsText.map { btn in
            guard def.paramNames.indices.contains(btn.codeRef),
                  def.paramNames[btn.codeRef] == "Active" else { return btn }
            var btn = btn
            let w = max(btn.widthPt, minButtonW)
            var center = CGPoint(x: btn.xPt + w / 2, y: btn.yPt + buttonTextH / 2)

            let column = conns.filter { abs($0.x - center.x) <= axisTolerance && abs($0.y - center.y) <= reach }
            let row = conns.filter { abs($0.y - center.y) <= axisTolerance && abs($0.x - center.x) <= reach }
            let above = column.filter { $0.y < center.y }.max { $0.y < $1.y }
            let below = column.filter { $0.y > center.y }.min { $0.y < $1.y }
            let left = row.filter { $0.x < center.x }.max { $0.x < $1.x }
            let right = row.filter { $0.x > center.x }.min { $0.x < $1.x }

            if let a = above, let b = below {
                center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            } else if let l = left, let r = right {
                center = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
            } else if let c = above ?? below {
                center.x = c.x
            } else if let c = left ?? right {
                center.y = c.y
            } else {
                return btn
            }
            btn.xPt = center.x - w / 2
            btn.yPt = center.y - buttonTextH / 2
            return btn
        }
    }

    // MARK: - KeyQuant: ekran "Range" wyrównany do przycisku "Closest/Evenly"

    /// BVerhue umieszcza ekran "Range" 1-2pt wyżej niż sąsiedni przycisk po lewej
    /// (`ButtonFlat "Closest,Evenly"`), zostawiając za mało miejsca nad ekranem —
    /// etykieta "Range" dotykała jego górnej krawędzi. Przesuwamy ekran w dół do
    /// wysokości przycisku i etykietę "Range" o tę samą deltę, więc oba trzymają
    /// swój wzajemny odstęp.
    private static func alignKeyQuantRangeScreen(_ ui: inout ModuleUIDef) {
        guard ui.name == "KeyQuant",
              let button = ui.buttonsFlat.first(where: { $0.options.contains("Closest") }),
              let fieldIdx = ui.textFields.firstIndex(where: { $0.masterRef == 0 })
        else { return }
        let delta = button.yPt - ui.textFields[fieldIdx].yPt
        guard delta != 0 else { return }
        ui.textFields[fieldIdx].yPt += delta
        if let labelIdx = ui.textLabels.firstIndex(where: { $0.text == "Range" }) {
            ui.textLabels[labelIdx].yPt += delta
        }
    }

    // MARK: - KeyQuant: klawiatura wyśrodkowana na pionowej osi modułu

    /// BVerhue umieszcza obie klawisze (czarny rząd nad białym) bliżej góry
    /// modułu, zostawiając więcej wolnego miejsca pod klawiaturą niż nad nią.
    /// Przesuwamy oba rzędy (wszystkie 12 `ButtonText`) o tę samą deltę, żeby
    /// margines nad i pod klawiaturą był równy.
    private static func centerKeyQuantKeyboard(_ ui: inout ModuleUIDef, def: ModuleDef?) {
        guard ui.name == "KeyQuant", let height = def?.height, !ui.buttonsText.isEmpty else { return }
        let top = ui.buttonsText.map(\.yPt).min()!
        let bottom = ui.buttonsText.map { $0.yPt + buttonTextH }.max()!
        let moduleH = CGFloat(height) * rowHeight
        let margin = (moduleH - (bottom - top)) / 2
        let delta = margin - top
        guard abs(delta) > 0.01 else { return }
        ui.buttonsText = ui.buttonsText.map { btn in
            var btn = btn
            btn.yPt += delta
            return btn
        }
    }
}
