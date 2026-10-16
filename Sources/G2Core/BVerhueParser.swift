// BVerhueParser.swift
// G2Core — parser plików .txt z NMG2Editor (Bruno Verhue, open source)
//
// Format wejściowy (przykład):
//   <#Module
//     Name:"OscA"
//     Height:3
//     <#Knob
//       ID:4
//       XPos:98
//       YPos:18
//       CodeRef:0
//       Type:"Big"
//     #>
//     <#Input
//       ID:3
//       XPos:4
//       YPos:13
//       CodeRef:0
//       Type:"Audio"
//     #>
//     ...
//   #>
//
// Skalowanie Gen1 piksel → screen pt:
//   scale = 140.0 / 256.0 = 0.546875  (jednolite dla X i Y)

import CoreGraphics

public enum BVerhueParser {
    // MARK: - Stała skalowania

    private static let scale: CGFloat = 140.0 / 256.0 // ≈ 0.546875

    // MARK: - Główna funkcja parsowania

    public static func parse(text: String) -> ModuleUIDef? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var i = 0

        // Znajdź linię <#Module
        while i < lines.count, !lines[i].hasPrefix("<#Module") {
            i += 1
        }
        guard i < lines.count else { return nil }
        i += 1 // pomiń "<#Module"

        var moduleName = ""
        var moduleFileName = "" // FileName: z .txt — identyfikator bitmapy CBMP
        var moduleHeight = 3

        var knobs: [BVKnob] = []
        var inputs: [BVConnector] = []
        var outputs: [BVConnector] = []
        var buttonsFlat: [BVButtonFlat] = []
        var buttonsText: [BVButtonText] = []
        var buttonsRadio: [BVButtonRadio] = []
        var leds: [BVLED] = []
        var levelShifts: [BVLevelShift] = []
        var textFields: [BVTextField] = []
        var incDecButtons: [BVButtonIncDec] = []
        var textLabels: [BVTextLabel] = []
        var graphs: [BVGraph] = []
        var partSelectors: [BVPartSelector] = []
        var bvLines: [BVLine] = []
        var symbols: [BVSymbol] = []
        var bitmaps: [BVBitmap] = []

        // Przetwarzaj linie aż do zamknięcia #> modułu
        while i < lines.count {
            let line = lines[i]
            i += 1

            if line == "#>" { break }

            if line.hasPrefix("<#") {
                // Blok elementu UI
                let tag = String(line.dropFirst(2))
                let f = parseBlock(lines, &i)

                switch true {
                case tag.hasPrefix("Knob"):
                    if let k = makeKnob(f) { knobs.append(k) }
                case tag.hasPrefix("Input"):
                    if let c = makeConnector(f, isOutput: false) { inputs.append(c) }
                case tag.hasPrefix("Output"):
                    if let c = makeConnector(f, isOutput: true) { outputs.append(c) }
                case tag.hasPrefix("ButtonFlat"):
                    // InfoFunc:9 = przycisk Loop/1-Cycle (ikonowy toggle) → buttonsFlat
                    // Inne ButtonFlat z pustym Text i ImageCount>0 = PartSelector (waveform/env selector)
                    if n(f, "InfoFunc") == 9 {
                        if let b = makeButtonFlat(f) { buttonsFlat.append(b) }
                    } else if s(f, "Text").isEmpty, n(f, "ImageCount") > 0 {
                        if let p = makePartSelector(f, usesParameter: true) { partSelectors.append(p) }
                    } else if let b = makeButtonFlat(f) { buttonsFlat.append(b) }
                case tag.hasPrefix("ButtonText"):
                    if let b = makeButtonText(f) { buttonsText.append(b) }
                // Kolejność ma znaczenie: "ButtonRadioEdit" zaczyna się od "ButtonRadio",
                // więc siatka musi być sprawdzona PRZED zwykłym selektorem — inaczej
                // trafia do makeButtonRadio, które wymaga ButtonCount i zwraca nil
                // (sześć selektorów grupy Switch znikało wtedy z panelu bez śladu).
                case tag.hasPrefix("ButtonRadioEdit"):
                    if let b = makeButtonRadioEdit(f) { buttonsRadio.append(b) }
                case tag.hasPrefix("ButtonRadio"):
                    if let b = makeButtonRadio(f) { buttonsRadio.append(b) }
                case tag.hasPrefix("Led"):
                    if let l = makeLED(f) { leds.append(l) }
                case tag.hasPrefix("LevelShift"):
                    if let ls = makeLevelShift(f) { levelShifts.append(ls) }
                case tag.hasPrefix("TextField"):
                    if let tf = makeTextField(f) { textFields.append(tf) }
                case tag.hasPrefix("ButtonIncDec"):
                    if let b = makeButtonIncDec(f) { incDecButtons.append(b) }
                case tag == "Text":
                    if let tl = makeTextLabel(f) { textLabels.append(tl) }
                case tag.hasPrefix("Graph"):
                    if let g = makeGraph(f) { graphs.append(g) }
                case tag.hasPrefix("PartSelector"):
                    if let p = makePartSelector(f) { partSelectors.append(p) }
                // TextEdit = szeroki przycisk toggle (Type:"Check"/"Push") → BVButtonText
                case tag.hasPrefix("TextEdit"):
                    if let b = makeButtonText(f) { buttonsText.append(b) }
                case tag.hasPrefix("Line"):
                    if let l = makeLine(f) { bvLines.append(l) }
                case tag.hasPrefix("Symbol"):
                    if let sym = makeSymbol(f) { symbols.append(sym) }
                case tag.hasPrefix("Bitmap"):
                    if let bmp = makeBitmap(f) { bitmaps.append(bmp) }
                default:
                    // Świadomie pomijane elementy (zaktualizuj przy dodawaniu nowych typów!):
                    //   Frame       — ramka dekoracyjna
                    //   MiniVU      — miernik poziomu sygnału (wymaga live audio, nie parametrów)
                    //   EnvCurve    — krzywa koperty (dekoracja, pokryta przez <#Graph)
                    break
                }

            } else {
                // Pole na poziomie modułu
                if line.hasPrefix("Name:") {
                    moduleName = stringVal(line)
                } else if line.hasPrefix("FileName:") {
                    moduleFileName = stringVal(line)
                } else if line.hasPrefix("Height:") {
                    moduleHeight = intSuffix(line) ?? 3
                }
            }
        }

        // Posortuj Input/Output po CodeRef — musi się zgadzać z indeksami kabli
        let sortedInputs = inputs.sorted { $0.codeRef < $1.codeRef }
        let sortedOutputs = outputs.sorted { $0.codeRef < $1.codeRef }

        return ModuleUIDef(
            name: moduleName,
            fileName: moduleFileName,
            height: moduleHeight,
            knobs: knobs,
            inputs: sortedInputs,
            outputs: sortedOutputs,
            buttonsFlat: buttonsFlat,
            buttonsText: buttonsText,
            buttonsRadio: buttonsRadio,
            leds: leds,
            levelShifts: levelShifts,
            textFields: textFields,
            incDecButtons: incDecButtons,
            textLabels: textLabels,
            graphs: graphs,
            partSelectors: partSelectors,
            lines: bvLines,
            symbols: symbols,
            bitmaps: bitmaps
        )
    }

    // MARK: - Parsowanie bloku <#Tag … #>

    //
    // Na wejściu: i wskazuje na pierwszą linię po "<#Tag"
    // Na wyjściu: i wskazuje na linię PO zamykającym "#>"

    private static func parseBlock(_ lines: [String], _ i: inout Int) -> [String: String] {
        var fields: [String: String] = [:]
        while i < lines.count {
            let line = lines[i]
            i += 1
            if line == "#>" { break }
            // Zagnieżdżony blok — pomiń rekurencyjnie
            if line.hasPrefix("<#") { _ = parseBlock(lines, &i)
                continue
            }
            // Parsuj "Key:Value" lub "Key:"quoted value""
            // Uwaga: klucz "Text Func" zawiera spację — używamy firstIndex(of:)
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[..<colonIdx])
                let rest = String(line[line.index(after: colonIdx)...])
                let val: String = if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
                    String(rest.dropFirst().dropLast())
                } else {
                    rest
                }
                fields[key] = val
            }
        }
        return fields
    }

    // MARK: - Pomocniki ekstrakcji wartości

    /// Wyłuska wartość po pierwszym ":" z całej linii (np. "Name:\"OscA\"")
    private static func stringVal(_ line: String) -> String {
        guard let colonIdx = line.firstIndex(of: ":") else { return "" }
        let rest = String(line[line.index(after: colonIdx)...])
        if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
            return String(rest.dropFirst().dropLast())
        }
        return rest
    }

    /// Wyłuska Int po ":" z linii (np. "Height:3")
    private static func intSuffix(_ line: String) -> Int? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        return Int(String(line[line.index(after: colonIdx)...]))
    }

    /// Skróty dla pól ze słownika
    private static func s(_ f: [String: String], _ k: String) -> String {
        f[k] ?? ""
    }

    private static func n(_ f: [String: String], _ k: String) -> Int {
        Int(f[k] ?? "0") ?? 0
    }

    /// Konwersja XPos/YPos → screen pt
    private static func px(_ f: [String: String], _ k: String) -> CGFloat {
        CGFloat(n(f, k)) * scale
    }

    // MARK: - Fabryki elementów

    private static func makeKnob(_ f: [String: String]) -> BVKnob? {
        let typeStr = s(f, "Type")
        let type = BVKnobType(rawValue: typeStr) ?? .medium
        return BVKnob(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                      codeRef: n(f, "CodeRef"), type: type, infoFunc: n(f, "InfoFunc"))
    }

    private static func makeConnector(_ f: [String: String], isOutput: Bool) -> BVConnector? {
        let sig: BVSignalType = switch s(f, "Type") {
        case "Audio": .audio
        case "Logic": .logic
        case "Control": .control
        default: .control
        }
        return BVConnector(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                           codeRef: n(f, "CodeRef"), signalType: sig, isOutput: isOutput)
    }

    private static func makeButtonFlat(_ f: [String: String]) -> BVButtonFlat? {
        let options = s(f, "Text").components(separatedBy: ",").filter { !$0.isEmpty }
        let imageCount = n(f, "ImageCount")
        // Pomijaj przyciski bez tekstu i bez ikon (nie da się nic narysować)
        guard !options.isEmpty || imageCount > 0 else { return nil }
        return BVButtonFlat(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                            codeRef: n(f, "CodeRef"), options: options,
                            widthPt: CGFloat(n(f, "Width")) * scale,
                            infoFunc: n(f, "InfoFunc"),
                            imageCount: imageCount)
    }

    private static func makeButtonText(_ f: [String: String]) -> BVButtonText? {
        BVButtonText(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                     codeRef: n(f, "CodeRef"), text: s(f, "Text"),
                     type: s(f, "Type"),
                     widthPt: CGFloat(n(f, "Width")) * scale)
    }

    private static func makeButtonRadio(_ f: [String: String]) -> BVButtonRadio? {
        let count = n(f, "ButtonCount")
        guard count > 0 else { return nil }

        // Etykiety z Text: "BR,HP,BP,LP," → ["BR","HP","BP","LP"]
        let rawText = s(f, "Text")
        let labels = rawText.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        // Dane pikselowe z Image: "ffffff:000000:…" → ["ffffff","000000",…]
        let rawImage = s(f, "Image")
        let pixels = rawImage.isEmpty ? [] :
            rawImage.split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)

        return BVButtonRadio(
            id: n(f, "ID"),
            xPt: px(f, "XPos"),
            yPt: px(f, "YPos"),
            codeRef: n(f, "CodeRef"),
            buttonCount: count,
            buttonWidthPt: CGFloat(n(f, "ButtonWidth")) * scale,
            infoFunc: n(f, "InfoFunc"),
            orientation: s(f, "Orientation"), // "Horizontal" lub "Vertical"
            columns: s(f, "Orientation") == "Vertical" ? 1 : count,
            rows: s(f, "Orientation") == "Vertical" ? count : 1,
            buttonLabels: labels,
            iconPixels: pixels,
            iconWidth: n(f, "ImageWidth")
        )
    }

    private static func makeLED(_ f: [String: String]) -> BVLED? {
        let type = BVLEDType(rawValue: s(f, "Type")) ?? .green
        return BVLED(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                     codeRef: n(f, "CodeRef"), type: type)
    }

    private static func makeLevelShift(_ f: [String: String]) -> BVLevelShift? {
        BVLevelShift(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                     codeRef: n(f, "CodeRef"))
    }

    private static func makeTextField(_ f: [String: String]) -> BVTextField? {
        // "Text Func" zawiera spację w nazwie klucza — parser obsługuje to poprawnie
        let tf = n(f, "Text Func")
        // "Dependencies" to lista indeksów parametrów rozdzielona przecinkami, opcjonalnie w ""
        // Token "Sn" (np. S0) = referencja do modes[n] — kodowanie: -n-1 (S0→-1, S1→-2)
        let depsRaw = s(f, "Dependencies")
        let deps: [Int] = depsRaw.components(separatedBy: ",").compactMap { token in
            let t = token.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("s"), let n = Int(t.dropFirst()) { return -n - 1 }
            return Int(t)
        }
        return BVTextField(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                           masterRef: n(f, "MasterRef"),
                           widthPt: CGFloat(n(f, "Width")) * scale,
                           textFunc: tf, dependencies: deps)
    }

    private static func makeLine(_ f: [String: String]) -> BVLine? {
        let len = CGFloat(n(f, "Length"))
        guard len > 0 else { return nil }
        return BVLine(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                      lengthPt: len * scale,
                      isHorizontal: s(f, "Orientation") != "Vertical",
                      isThick: s(f, "Width") != "Thin")
    }

    /// Pole `Data:` (kilka kB pikseli na bitmapę) świadomie pomijamy — rysunki
    /// odtwarzamy wektorowo, potrzebne jest tylko miejsce i rozmiar źródłowy.
    private static func makeBitmap(_ f: [String: String]) -> BVBitmap? {
        let w = n(f, "Width")
        let h = n(f, "Height")
        guard w > 0, h > 0 else { return nil }
        return BVBitmap(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                        widthPx: w, heightPx: h)
    }

    private static func makeSymbol(_ f: [String: String]) -> BVSymbol? {
        let type = s(f, "Type")
        guard !type.isEmpty else { return nil }
        return BVSymbol(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                        widthPt: CGFloat(n(f, "Width")) * scale,
                        heightPt: CGFloat(n(f, "Height")) * scale,
                        type: type)
    }

    private static func makeButtonIncDec(_ f: [String: String]) -> BVButtonIncDec? {
        BVButtonIncDec(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                       codeRef: n(f, "CodeRef"), infoFunc: n(f, "InfoFunc"),
                       isVertical: s(f, "Type") != "Left/Right")
    }

    private static func makeTextLabel(_ f: [String: String]) -> BVTextLabel? {
        let text = s(f, "Text")
        guard !text.isEmpty else { return nil }
        // FontSize w plikach .txt to piksele Gen1 — taka sama skala jak XPos/YPos.
        // Przeliczamy na screen pt: fontSize * scale; min 4pt.
        let fsPx = CGFloat(n(f, "FontSize"))
        let fsPt = max(4.0, fsPx > 0 ? fsPx * scale : 5.5)
        return BVTextLabel(id: n(f, "ID"), xPt: px(f, "XPos"), yPt: px(f, "YPos"),
                           text: text, fontSize: fsPt)
    }

    /// ButtonRadioEdit — siatka selektora (ButtonColumns × ButtonRows), Text:"A,B,C,…".
    /// Używa jej sześć modułów grupy Switch (Sw2-1, Sw4-1, Sw8-1, Sw1-2, Sw1-4, Sw1-8).
    /// Plik .txt nie podaje rozmiaru komórki — BVerhue bierze go z konstruktora
    /// `TG2BtnRadioEdit` (ButtonWidth 43, ButtonHeight 12 w pikselach Gen1).
    private static func makeButtonRadioEdit(_ f: [String: String]) -> BVButtonRadio? {
        let labels = s(f, "Text").components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let cols = max(1, n(f, "ButtonColumns"))
        let rows = max(1, n(f, "ButtonRows"))
        guard !labels.isEmpty else { return nil }
        return BVButtonRadio(
            id: n(f, "ID"),
            xPt: px(f, "XPos"),
            yPt: px(f, "YPos"),
            codeRef: n(f, "CodeRef"),
            buttonCount: cols * rows,
            buttonWidthPt: 43 * scale,
            infoFunc: n(f, "InfoFunc"),
            orientation: "Horizontal",
            columns: cols,
            rows: rows,
            buttonLabels: labels,
            iconPixels: [],
            iconWidth: 0
        )
    }

    private static func makePartSelector(_ f: [String: String],
                                         usesParameter: Bool = false) -> BVPartSelector?
    {
        let count = n(f, "ImageCount")
        let imgW = n(f, "ImageWidth")
        guard count > 0, imgW > 0 else { return nil }
        let rawImage = s(f, "Image")
        let pixels = rawImage.isEmpty ? [] :
            rawImage.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        // Height może być 0 dla ButtonFlat (nie ma pola Height) — wylicz z danych pikseli
        var h = n(f, "Height")
        if h == 0, imgW > 0, count > 0, !pixels.isEmpty {
            h = pixels.count / (imgW * count)
        }
        if h == 0 { h = imgW } // fallback: kwadratowe ikony
        return BVPartSelector(
            id: n(f, "ID"),
            xPt: px(f, "XPos"),
            yPt: px(f, "YPos"),
            codeRef: n(f, "CodeRef"),
            infoFunc: n(f, "InfoFunc"),
            widthPt: CGFloat(n(f, "Width")) * scale,
            heightPt: CGFloat(h) * scale,
            imageCount: count,
            imageWidth: imgW,
            iconPixels: pixels,
            usesParameter: usesParameter
        )
    }

    private static func makeGraph(_ f: [String: String]) -> BVGraph? {
        let w = CGFloat(n(f, "Width"))
        let h = CGFloat(n(f, "Height"))
        guard w > 0, h > 0 else { return nil }
        // Dependencies mogą zawierać tokeny "S0"/"s0" (slot-reference).
        // Kodujemy je tak jak w BVTextField: -n-1 (S0 → -1, S1 → -2), aby
        // renderer wykresu mógł odczytać bieżący stan przycisku z module.modes.
        let depsRaw = s(f, "Dependencies")
        let deps: [Int] = depsRaw.components(separatedBy: ",").compactMap { token in
            let value = token.trimmingCharacters(in: .whitespaces).lowercased()
            if value.hasPrefix("s"), let modeIndex = Int(value.dropFirst()) { return -modeIndex - 1 }
            return Int(value)
        }
        return BVGraph(
            id: n(f, "ID"),
            xPt: px(f, "XPos"),
            yPt: px(f, "YPos"),
            widthPt: w * scale,
            heightPt: h * scale,
            graphFunc: n(f, "Graph Func"),
            dependencies: deps
        )
    }
}
