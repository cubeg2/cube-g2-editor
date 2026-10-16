// SpectrogramPanel.swift
// Spektrogram na żywo (Tools ▸ Spectrum, przycisk z falą w górnej belce) — obraz tego,
// co gra wirtualny G2 albo Nord przez wejścia interfejsu audio (`LiveAudioSourceMenu`).
// Dane bierze `LiveSpectrogram`; tutaj jest zamiana
// plasterków na obrazek, krzywa poziomu i dwa miejsca, w których da się to pokazać:
// własne okno albo tło kanwy.
//
// **Układ jak w analizatorze MOTU CueMix**, bo taki użytkownik wskazał: częstotliwość
// biegnie w prawo (logarytmicznie, domyślnie 20 Hz – 16 kHz), czas płynie w górę
// (najnowsze na dole), a na wierzchu leży biała krzywa bieżącego widma ze skalą w dB
// po lewej. Opcje też jak w CueMiksie: sam obraz lub sama krzywa, zakres częstotliwości
// i decybeli, paleta i nasycenie barw.
//
// **Tło kanwy jest OSOBNĄ warstwą, nie częścią rysunku kanwy.** Gdyby spektrogram
// rysować w `Canvas` razem z modułami, każda z dwudziestu klatek na sekundę
// unieważniałaby całą kanwę — a to jest dokładnie ten koszt, przez który gałki
// przestawały się kręcić płynnie (9–10 ms na przerysowanie przy 125 modułach,
// patrz nagłówek `PatchBoundViews.swift`). Jako tło pod `ScrollView` odświeża się
// sam, a moduły i kable leżą nad nim nietknięte.

import G2EditorCore
import SwiftUI

/// Ustawienia podglądu — jedno miejsce na klucze, żeby okno i tło kanwy czytały to samo.
enum SpectrogramSettings {
    static let inCanvasKey = "spectrogramInCanvas"
    static let imageKey = "spectrogramImage"
    static let curveKey = "spectrogramCurve"
    static let peaksKey = "spectrogramPeaks"
    static let contrastKey = "spectrogramContrastDB"
    static let gridKey = "spectrogramGrid"
    static let noteAxisKey = "spectrogramNoteAxis"
    static let backdropOpacityKey = "spectrogramBackdropOpacity"
    static let paletteKey = "spectrogramPalette"
    static let minHzKey = "spectrogramMinHz"
    static let maxHzKey = "spectrogramMaxHz"
    static let topDBKey = "spectrogramTopDB"
    static let bottomDBKey = "spectrogramBottomDB"

    /// Dół skali obrazu w dB. Mniejsza liczba = większy kontrast: ciszej znaczy już czarno.
    static let contrastRange = 36.0 ... LiveSpectrogram.floorDB
    static let defaultContrast = 72.0
    static let defaultBackdropOpacity = 0.45
    /// Widoczność siatki 0…1; 0 chowa ją całkiem. Domyślnie tyle, ile miała przed suwakiem.
    static let defaultGrid = 0.3
    /// Krycie kresek z podpisem przy suwaku na maksimum; pozostałe kreski są słabsze.
    static let gridMaxOpacity = 0.6

    /// Zakresy do wyboru. W patchach syntezatorowych prawie wszystko dzieje się poniżej
    /// 5–8 kHz, więc zawężenie pasma powiększa to, co ważne.
    static let minHzChoices: [Double] = [20, 50, 100, 200, 500]
    static let maxHzChoices: [Double] = [2000, 5000, 8000, 10000, 16000, 20000]
    static let topDBChoices: [Double] = [0, -6, -12, -24]
    static let bottomDBChoices: [Double] = [-36, -48, -60, -72, -84]

    /// Odbicie w zakresie: suwak rośnie w prawo, a dół skali w dB maleje.
    static func contrastFlipped(_ value: Double) -> Double {
        contrastRange.lowerBound + contrastRange.upperBound - value
    }

    static func hzLabel(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%g kHz", hz / 1000) : "\(Int(hz)) Hz"
    }
}

/// Skale wykresu: jaki wycinek pasma i decybeli pokazać. Analiza jest zawsze pełna
/// (20 Hz – 20 kHz, 0 … −84 dB), więc skala to tylko sposób patrzenia.
struct SpectrumScale: Equatable {
    var minHz = 20.0
    var maxHz = 16000.0
    /// Góra i dół krzywej w dB (0 = pełna skala).
    var topDB = 0.0
    var bottomDB = -84.0

    /// Miejsce częstotliwości na osi — 0 to lewa krawędź, 1 prawa.
    func position(ofHz hz: Double) -> Double {
        log(hz / minHz) / log(maxHz / minHz)
    }

    func hz(atPosition position: Double) -> Double {
        minHz * pow(maxHz / minHz, position)
    }

    /// Miejsce poziomu w pionie — 0 to górna krawędź, 1 dolna.
    func position(ofDB decibels: Double) -> Double {
        (topDB - decibels) / (topDB - bottomDB)
    }

    /// Podpisy pod wykresem. Przy pełnym paśmie te same trzy, co na spektrogramach z renderu;
    /// przy zawężonym — szereg 1-2-5, żeby było się czego trzymać.
    var frequencyMarks: [(hz: Double, label: String)] {
        let wide: [Double] = [100, 1000, 10000]
        let fine: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        let marks = maxHz / minHz >= 400 ? wide : fine
        return marks.filter { (0.04 ... 0.96).contains(position(ofHz: $0)) }.map { hz in
            (hz, hz >= 1000 ? String(format: "%gk", hz / 1000) : "\(Int(hz))")
        }
    }

    /// Podpisy w nutach: każde C w zakresie (C1, C2, …), nazewnictwo jak w edytorze (C4 = nuta 60).
    /// Kreska przy C mówi od razu, czy szczyt siedzi na granej nucie, czy oktawę wyżej.
    var noteMarks: [(hz: Double, label: String)] {
        stride(from: 0, through: 132, by: 12).map { note in
            (MusicalPitch.hz(ofMidiNote: note), MusicalPitch.name(ofMidiNote: note))
        }
        .filter { (0.04 ... 0.96).contains(position(ofHz: $0.hz)) }
    }

    /// Podpisy osi w hercach albo w nutach — przełącznik „Axis" w oknie.
    func marks(inNotes: Bool) -> [(hz: Double, label: String)] {
        inNotes ? noteMarks : frequencyMarks
    }

    /// Pionowe kreski siatki jak w CueMiksie: każda wielokrotność dekady
    /// (…, 90, 100, 200, …, 900, 1k, 2k, …) — podpisy dostają tylko `frequencyMarks`.
    var frequencyGridLines: [Double] {
        var lines: [Double] = []
        var decade = pow(10, log10(minHz).rounded(.down))
        while decade < maxHz {
            for step in 1 ... 9 {
                let hz = decade * Double(step)
                if hz > minHz, hz < maxHz { lines.append(hz) }
            }
            decade *= 10
        }
        return lines
    }

    /// Poziome kreski: co 12 dB jak w CueMiksie, przy wąskim zakresie co 6.
    var decibelMarks: [Double] {
        let step = topDB - bottomDB <= 36 ? 6.0 : 12.0
        var marks: [Double] = []
        var decibels = (topDB / step).rounded(.down) * step
        while decibels >= bottomDB {
            marks.append(decibels)
            decibels -= step
        }
        return marks
    }

    /// Z ustawień zapisanych w oknie; niemożliwą parę (Min ≥ Max) prostujemy.
    static func stored(minHz: Double, maxHz: Double, topDB: Double, bottomDB: Double) -> SpectrumScale {
        SpectrumScale(minHz: min(minHz, maxHz / 2), maxHz: maxHz,
                      topDB: topDB, bottomDB: min(bottomDB, topDB - 12))
    }
}

/// Palety obrazu. Pierwsza jest ta sama co w spektrogramach z renderu, żeby to, co widać
/// w edytorze, dało się porównać z obrazkiem z pomiaru.
enum SpectrogramPalette: String, CaseIterable {
    case violetOrange
    case rainbow
    case phosphor
    case ice
    case gray

    var title: String {
        switch self {
        case .violetOrange: "Violet–Orange"
        case .rainbow: "Rainbow"
        case .phosphor: "Green Phosphor"
        case .ice: "Ice Blue"
        case .gray: "Grayscale"
        }
    }

    /// Kolory od ciszy do pełnej skali, rozłożone równo.
    fileprivate var stops: [SpectrogramImage.Pixel] {
        switch self {
        case .violetOrange:
            [.init(8, 8, 20), .init(38, 20, 89), .init(140, 31, 115), .init(235, 107, 46), .init(255, 242, 191)]
        case .rainbow: // jak MOTU: niebieski → zielony → żółty → czerwony
            [.init(4, 6, 40), .init(0, 70, 255), .init(0, 200, 90), .init(255, 230, 0), .init(255, 30, 0)]
        case .phosphor:
            [.init(0, 8, 0), .init(0, 60, 12), .init(20, 160, 40), .init(120, 255, 120), .init(220, 255, 220)]
        case .ice:
            [.init(4, 6, 16), .init(10, 30, 80), .init(30, 100, 180), .init(120, 200, 240), .init(235, 250, 255)]
        case .gray:
            [.init(8, 8, 8), .init(255, 255, 255)]
        }
    }
}

/// Zamiana plasterków na obrazek.
enum SpectrogramImage {
    fileprivate struct Pixel {
        var red: UInt8
        var green: UInt8
        var blue: UInt8

        init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// 256 kolorów palety — liniowo między punktami.
    private static func ramp(_ palette: SpectrogramPalette) -> [Pixel] {
        let stops = palette.stops
        return (0 ..< 256).map { level in
            let position = Double(level) / 255 * Double(stops.count - 1)
            let index = Swift.min(stops.count - 2, Int(position))
            let t = position - Double(index)
            let from = stops[index], to = stops[index + 1]
            func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
                UInt8(Swift.max(0, Swift.min(255, Double(a) + (Double(b) - Double(a)) * t)))
            }
            return Pixel(mix(from.red, to.red), mix(from.green, to.green), mix(from.blue, to.blue))
        }
    }

    /// Obrazek `LiveSpectrogram.bins` × `LiveSpectrogram.historyRows`. Częstotliwość rośnie
    /// w prawo (wycinek `scale`), **najnowszy plasterek leży na dole** — historia wysuwa się
    /// do góry. Dopóki historia się nie zapełni, brakujące wiersze są czarne, więc obraz nie
    /// rozciąga się przez pierwsze sekundy.
    ///
    /// `contrastDB` przesuwa czerń: przy 36 dB widać tylko to, co głośne, przy 84 — wszystko,
    /// łącznie z szumem tła. Przeliczamy TU, a nie przy analizie, więc suwaki i zakres
    /// zmieniają także to, co już jest na ekranie.
    static func make(slices: [[UInt8]], contrastDB: Double, palette: SpectrogramPalette,
                     scale: SpectrumScale) -> CGImage?
    {
        let width = LiveSpectrogram.bins
        let height = LiveSpectrogram.historyRows
        guard width > 0, height > 0, !slices.isEmpty else { return nil }
        let floor = LiveSpectrogram.floorDB
        let span = Swift.max(6, contrastDB)
        // Poziom 0…255 mierzony od −84 dB przeliczony na 0…255 mierzone od −`span` dB.
        let table: [UInt8] = (0 ..< 256).map { level in
            let decibels = Double(level) / 255 * floor - floor
            let scaled = (decibels + span) / span
            return UInt8(Swift.max(0, Swift.min(1, scaled)) * 255)
        }
        let colors = ramp(palette)
        // Kolumna obrazu → punkt analizy (ta ma zawsze pełne pasmo 20 Hz – 20 kHz).
        let fullSpan = log(LiveSpectrogram.topHz / LiveSpectrogram.bottomHz)
        let columns: [Int] = (0 ..< width).map { column in
            let hz = scale.hz(atPosition: Double(column) / Double(width - 1))
            let place = log(hz / LiveSpectrogram.bottomHz) / fullSpan * Double(width - 1)
            return Swift.max(0, Swift.min(width - 1, Int(place.rounded())))
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) {
            pixels[index] = 255
        }
        // Ostatni plasterek ląduje w ostatnim wierszu obrazu (na dole).
        let first = height - slices.count
        for (order, slice) in slices.enumerated() {
            let y = first + order
            guard y >= 0, slice.count == width else { continue }
            for x in 0 ..< width {
                let color = colors[Int(table[Int(slice[columns[x]])])]
                let offset = (y * width + x) * 4
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// Wszystko, co okno i tło kanwy czytają z ustawień — jeden kształt dla obu.
struct SpectrogramLook: Equatable {
    var showsImage = true
    var showsCurve = true
    var showsPeaks = false
    var contrastDB = SpectrogramSettings.defaultContrast
    var grid = SpectrogramSettings.defaultGrid
    /// Oś w nutach zamiast w hercach: kreski i podpisy przy każdym C.
    var noteAxis = false
    var palette = SpectrogramPalette.violetOrange
    var scale = SpectrumScale()
}

/// Wykres: obraz spektrogramu, opcjonalna siatka i opcjonalne krzywe. Ten sam widok
/// stoi w oknie i w tle kanwy — różni je tylko to, co jest włączone.
struct SpectrogramPlot: View {
    var look: SpectrogramLook
    var showsGrid: Bool
    var spectrogram = LiveSpectrogram.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if look.showsImage,
                   let image = SpectrogramImage.make(slices: spectrogram.slices, contrastDB: look.contrastDB,
                                                     palette: look.palette,
                                                     scale: look.scale)
                {
                    Image(image, scale: 1, label: Text("Spectrum"))
                        .resizable()
                        .interpolation(.none)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if showsGrid, look.grid > 0 {
                    grid(in: geo.size)
                }
                if look.showsPeaks {
                    curve(spectrogram.peakDecibels, in: geo.size)
                        .stroke(Color.white.opacity(0.45), lineWidth: 1)
                }
                if look.showsCurve {
                    curve(spectrogram.latestDecibels, in: geo.size)
                        .stroke(Color.white, lineWidth: 1.2)
                }
            }
        }
        .clipped()
        .onAppear { spectrogram.addViewer() }
        .onDisappear { spectrogram.removeViewer() }
    }

    /// Krzywa poziomu: w poziomie częstotliwość (jak obraz), w pionie decybele w zakresie
    /// `scale`. Punkty analizy tuż za brzegami też idą do ścieżki — krzywa dochodzi do
    /// krawędzi zamiast urywać się przed nią (nadmiar obcina `clipped`).
    private func curve(_ decibels: [Double], in size: CGSize) -> Path {
        Path { path in
            guard decibels.count > 1 else { return }
            let scale = look.scale
            let ratio = LiveSpectrogram.topHz / LiveSpectrogram.bottomHz
            let positions = decibels.indices.map { index in
                scale.position(ofHz: LiveSpectrogram.bottomHz
                    * pow(ratio, Double(index) / Double(decibels.count - 1)))
            }
            let first = positions.lastIndex { $0 <= 0 } ?? 0
            let last = positions.firstIndex { $0 >= 1 } ?? decibels.count - 1
            guard first < last else { return }
            for index in first ... last {
                let y = size.height * Swift.max(0, Swift.min(1, scale.position(ofDB: decibels[index])))
                let point = CGPoint(x: size.width * positions[index], y: y)
                if index == first { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    /// Kreski z podpisem (dB i herce pod wykresem) mocniej, pozostałe herce słabiej —
    /// gęsta siatka nie zagłusza wtedy obrazu. Krycie ustawia suwak „Grid". Przy osi
    /// w nutach zostają same kreski przy C — półtony co kilka punktów byłyby tylko szumem.
    private func grid(in size: CGSize) -> some View {
        let scale = look.scale
        let labeled = Set(scale.marks(inNotes: look.noteAxis).map(\.hz))
        let faint = look.noteAxis ? [] : scale.frequencyGridLines
        func vertical(_ path: inout Path, _ hz: Double) {
            let x = size.width * scale.position(ofHz: hz)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        let opacity = look.grid * SpectrogramSettings.gridMaxOpacity
        return ZStack {
            Path { path in
                for hz in faint where !labeled.contains(hz) {
                    vertical(&path, hz)
                }
            }
            .stroke(Color.white.opacity(opacity * 0.55), lineWidth: 0.5)
            Path { path in
                for decibels in scale.decibelMarks {
                    let y = size.height * scale.position(ofDB: decibels)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                for hz in labeled {
                    vertical(&path, hz)
                }
            }
            .stroke(Color.white.opacity(opacity), lineWidth: 0.75)
        }
    }
}

/// Odczyt wszystkich ustawień wyglądu — okno i tło kanwy trzymają ten sam zestaw kluczy.
private struct SpectrogramLookStorage: DynamicProperty {
    @AppStorage(SpectrogramSettings.imageKey) var showsImage = true
    @AppStorage(SpectrogramSettings.curveKey) var showsCurve = true
    @AppStorage(SpectrogramSettings.peaksKey) var showsPeaks = false
    @AppStorage(SpectrogramSettings.contrastKey) var contrastDB = SpectrogramSettings.defaultContrast
    @AppStorage(SpectrogramSettings.gridKey) var grid = SpectrogramSettings.defaultGrid
    @AppStorage(SpectrogramSettings.noteAxisKey) var noteAxis = false
    @AppStorage(SpectrogramSettings.paletteKey) var palette = SpectrogramPalette.violetOrange.rawValue
    @AppStorage(SpectrogramSettings.minHzKey) var minHz = 20.0
    @AppStorage(SpectrogramSettings.maxHzKey) var maxHz = 16000.0
    @AppStorage(SpectrogramSettings.topDBKey) var topDB = 0.0
    @AppStorage(SpectrogramSettings.bottomDBKey) var bottomDB = -84.0

    var look: SpectrogramLook {
        SpectrogramLook(showsImage: showsImage, showsCurve: showsCurve, showsPeaks: showsPeaks,
                        contrastDB: contrastDB, grid: grid, noteAxis: noteAxis,
                        palette: SpectrogramPalette(rawValue: palette) ?? .violetOrange,
                        scale: .stored(minHz: minHz, maxHz: maxHz, topDB: topDB, bottomDB: bottomDB))
    }
}

/// Tło kanwy: ciemne tło edytora, a na nim przygaszony spektrogram. Przygaszony,
/// bo nad nim mają być czytelne kable — nie odwrotnie.
struct SpectrogramBackdrop: View {
    private var storage = SpectrogramLookStorage()
    @AppStorage(SpectrogramSettings.backdropOpacityKey) private var strength = SpectrogramSettings
        .defaultBackdropOpacity

    var body: some View {
        ZStack {
            UIColor.canvasBackground
            SpectrogramPlot(look: storage.look, showsGrid: false)
                .opacity(strength)
        }
    }
}

/// Okno „Spectrum" — wykres ze skalami i opcje pod nim.
struct SpectrogramPanel: View {
    @AppStorage(SpectrogramSettings.inCanvasKey) private var inCanvas = false
    @AppStorage(SpectrogramSettings.backdropOpacityKey) private var backdropOpacity = SpectrogramSettings
        .defaultBackdropOpacity
    private var storage = SpectrogramLookStorage()
    private var spectrogram = LiveSpectrogram.shared
    private var devices = AudioInputDevices.shared

    /// Kursor nad wykresem — pod nim odczyt nuty, herców i poziomu.
    @State private var hoverPoint: CGPoint?

    private static let scaleWidth: CGFloat = 26
    private static let labelWidth: CGFloat = 66

    var body: some View {
        let look = storage.look
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                decibelScale(look.scale)
                VStack(spacing: 2) {
                    plot(look)
                    frequencyScale(look)
                }
            }
            .frame(minHeight: 180)

            options
        }
        .padding(12)
        .frame(minWidth: 420, minHeight: 300)
    }

    private func plot(_ look: SpectrogramLook) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(UIColor.canvasBackground)
            .overlay(
                SpectrogramPlot(look: look, showsGrid: true)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            )
            .overlay(
                GeometryReader { geo in
                    if let hoverPoint {
                        SpectrumHoverReadout(point: hoverPoint, size: geo.size, scale: look.scale)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            )
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.5)))
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): hoverPoint = point
                case .ended: hoverPoint = nil
                }
            }
    }

    /// Decybele przy lewej krawędzi — dotyczą krzywej, nie barwy obrazu.
    private func decibelScale(_ scale: SpectrumScale) -> some View {
        GeometryReader { geo in
            ForEach(scale.decibelMarks, id: \.self) { decibels in
                Text(decibels == 0 ? "0" : "\(Int(decibels))")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: Self.scaleWidth, alignment: .trailing)
                    .position(x: Self.scaleWidth / 2, y: geo.size.height * scale.position(ofDB: decibels))
            }
        }
        .frame(width: Self.scaleWidth)
        .padding(.bottom, 13)
    }

    /// Herce (albo nuty) pod wykresem, w miejscach pionowych kresek siatki.
    private func frequencyScale(_ look: SpectrogramLook) -> some View {
        let scale = look.scale
        return GeometryReader { geo in
            ForEach(scale.marks(inNotes: look.noteAxis), id: \.hz) { mark in
                Text(mark.label)
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .position(x: geo.size.width * scale.position(ofHz: mark.hz), y: 6)
            }
        }
        .frame(height: 11)
    }

    /// Opcje leżą poziomo i zawijają się, gdy okno jest wąskie (`TopBarFlowLayout` —
    /// ten sam układ co górna belka): każda grupa przechodzi niżej w całości.
    @ViewBuilder
    private var options: some View {
        TopBarFlowLayout(spacing: 18, rowSpacing: 8) {
            labeled("Source") {
                LiveAudioSourceMenu { title in
                    Text(title).lineLimit(1)
                }
                .fixedSize()
            }
            labeled("Palette") {
                Picker("Palette", selection: storage.$palette) {
                    ForEach(SpectrogramPalette.allCases, id: \.rawValue) { palette in
                        Text(palette.title).tag(palette.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            labeled("Frequency") {
                rangePickers(low: storage.$minHz, lowChoices: SpectrogramSettings.minHzChoices,
                             high: storage.$maxHz, highChoices: SpectrogramSettings.maxHzChoices,
                             label: SpectrogramSettings.hzLabel)
            }
            .help("Frequency range across the picture — most of a synth patch lives below 5–8 kHz")
            labeled("Axis") {
                Picker("Axis", selection: storage.$noteAxis) {
                    Text("Hz").tag(false)
                    Text("Notes").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .help("Label the frequency axis in hertz or with the C of every octave (C4 = middle C)")
            labeled("Curve") {
                rangePickers(low: storage.$bottomDB, lowChoices: SpectrogramSettings.bottomDBChoices,
                             high: storage.$topDB, highChoices: SpectrogramSettings.topDBChoices,
                             label: { $0 == 0 ? "0 dB" : "\(Int($0)) dB" })
            }
            .help("Level range of the curve, bottom to top")
            // Każdy przełącznik osobno — w wąskim oknie przechodzą niżej pojedynczo.
            Toggle("Spectrogram", isOn: storage.$showsImage)
                .help("The coloured picture; off leaves only the curves")
            Toggle("Spectrum curve", isOn: storage.$showsCurve)
            Toggle("Peak hold", isOn: storage.$showsPeaks)
            Toggle("Freeze", isOn: Binding(get: { spectrogram.isFrozen },
                                           set: { spectrogram.isFrozen = $0 }))
            Toggle("Show behind the patch", isOn: $inCanvas)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .font(.system(size: 11))

        HStack(spacing: 24) {
            // Suwak w prawo = MOCNIEJSZY kontrast, a mocniejszy kontrast to NIŻSZY dół skali,
            // więc wartość jest odbita względem zakresu. Odczyt pokazuje prawdziwe dB.
            slider("Contrast", value: Binding(
                get: { SpectrogramSettings.contrastFlipped(storage.contrastDB) },
                set: { storage.contrastDB = SpectrogramSettings.contrastFlipped($0) }
            ), range: SpectrogramSettings.contrastRange, caption: "\(Int(storage.contrastDB)) dB")
            slider("Grid", value: storage.$grid, range: 0 ... 1,
                   caption: storage.grid == 0 ? "Off" : "\(Int(storage.grid * 100))%")
                .help("Visibility of the frequency and level grid; all the way left hides it")
            if inCanvas {
                slider("Backdrop", value: $backdropOpacity, range: 0.1 ... 1,
                       caption: "\(Int(backdropOpacity * 100))%")
            }
        }
        .controlSize(.small)

        // Stan i liczniki w jednym wierszu, a gdy się nie mieszczą — jeden pod drugim.
        let status = Text(statusText(storage.look.scale))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                status
                healthText
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                status.fixedSize(horizontal: false, vertical: true)
                healthText
            }
        }
    }

    /// Podpis i kontrolka obok siebie — jedna grupa, która zawija się w całości.
    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            content()
        }
        .fixedSize()
    }

    /// Dwie listy „od – do". Wartości spoza list (np. ręcznie zmienione) nie znikają —
    /// lista po prostu nie ma wtedy zaznaczenia.
    private func rangePickers(low: Binding<Double>, lowChoices: [Double],
                              high: Binding<Double>, highChoices: [Double],
                              label: @escaping (Double) -> String) -> some View
    {
        HStack(spacing: 6) {
            Picker("From", selection: low) {
                ForEach(lowChoices, id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Text("to").foregroundStyle(.secondary)
            Picker("To", selection: high) {
                ForEach(highChoices, id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// Suwak z podpisem i odczytem — kilka takich samych wierszy, więc jeden kształt.
    /// Zakres bywa malejący (kontrast: mniej dB = mocniejszy), stąd `range` jako para.
    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, caption: String) -> some View
    {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .frame(width: Self.labelWidth, alignment: .leading)
            Slider(value: value, in: range)
            Text(caption)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func statusText(_ scale: SpectrumScale) -> String {
        let source = LiveAudioSource.stored
        if LiveAudioSourceText.needsChoice(source) { return LiveAudioSourceText.chooseInputs }
        let name = LiveAudioSourceText.long(source, devices: devices.devices)
        if source.isInterface, let hint = LiveAudioSourceText.permissionHint {
            return hint
        }
        if LiveAudioSourceText.isMissing(source, devices: devices.devices) {
            return "\(name) — the interface is not connected."
        }
        if spectrogram.isFrozen {
            return "Frozen — the picture is held, sound keeps playing."
        }
        guard spectrogram.isPlaying else { return "Waiting for sound from \(name)." }
        return "Live from \(name) — \(SpectrogramSettings.hzLabel(scale.minHz)) to "
            + "\(SpectrogramSettings.hzLabel(scale.maxHz)) across, 12 seconds of history upwards."
    }

    /// Stan stanowiska audio. Niedobór to chwila, w której karta nie dostała dźwięku na
    /// czas — **słychać go jako trzask**, a w widmie nie widać go wcale, więc ten wiersz
    /// jest jedynym miejscem, gdzie się o nim dowiesz.
    @ViewBuilder
    private var healthText: some View {
        if let health = spectrogram.health {
            let backlog = Double(health.backlogFrames) / 96
            let worst = Double(health.backlogMaxFrames) / 96
            let clean = health.silentFrames == 0 && health.skippedFrames == 0
            // Liczniki emulatora są w RAMKACH, więc jedyny czytelny odczyt to czas.
            Text(String(format: "Gaps %.0f ms · skipped %.0f ms · buffer %.0f ms (peak %.0f ms)",
                        Double(health.silentFrames) / 96, Double(health.skippedFrames) / 96,
                        backlog, worst))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(clean ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .help("Silence sent to the sound card and audio skipped to catch up, "
                    + "counted since this view opened. Buffer is what waits in the ring.")
        }
    }
}

/// Odczyt pod kursorem: cienka pionowa kreska i dymek z nutą, hercami i poziomem krzywej
/// w tym miejscu. Osobny widok, bo czyta świeże widmo 20 razy na sekundę — okno z opcjami
/// nie przerysowuje się przez to.
private struct SpectrumHoverReadout: View {
    var point: CGPoint
    var size: CGSize
    var scale: SpectrumScale
    var spectrogram = LiveSpectrogram.shared

    private static let boxWidth: CGFloat = 112

    var body: some View {
        let hz = scale.hz(atPosition: point.x / max(1, size.width))
        // Za blisko prawej krawędzi dymek przechodzi na lewą stronę kursora.
        let onLeft = point.x + 10 + Self.boxWidth > size.width
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: point.x, y: 0))
                path.addLine(to: CGPoint(x: point.x, y: size.height))
            }
            .stroke(Color.white.opacity(0.6), lineWidth: 0.75)
            VStack(alignment: .leading, spacing: 1) {
                Text(MusicalPitch.label(forHz: hz))
                    .font(.system(size: 11, weight: .semibold))
                Text(detail(hz))
                    .font(.system(size: 10))
            }
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(width: Self.boxWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)))
            .offset(x: onLeft ? point.x - 10 - Self.boxWidth : point.x + 10,
                    y: min(max(4, point.y - 36), max(4, size.height - 40)))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// „223 Hz · −24 dB" — poziom z białej krzywej; bez dźwięku same herce.
    private func detail(_ hz: Double) -> String {
        let frequency = hz >= 1000 ? String(format: "%.2f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
        let levels = spectrogram.latestDecibels
        guard spectrogram.isPlaying, levels.count > 1 else { return frequency }
        let place = log(hz / LiveSpectrogram.bottomHz) / log(LiveSpectrogram.topHz / LiveSpectrogram.bottomHz)
        let index = max(0, min(levels.count - 1, Int((place * Double(levels.count - 1)).rounded())))
        let decibels = Int(levels[index].rounded())
        return frequency + " · " + (decibels < 0 ? "−\(-decibels)" : "\(decibels)") + " dB"
    }
}
