// XYPlotPanel.swift
// Okno „X-Y Plot" (przycisk z celownikiem w górnej belce, Tools ▸ X-Y Plot) — goniometr
// dźwięku wirtualnego G2 albo Norda przez wejścia interfejsu audio (wiersz „Input" pod
// wykresem), jak „X-Y Plot" w MOTU CueMix: amplituda lewego kanału na osi X,
// prawego na osi Y. Dane daje `LiveStereoScope`.
//
// Jak czytać: mono = ukośna kreska z lewego dołu w prawą górę (L = R); szerokie stereo =
// chmura; kreska w drugą stronę (L = −R) = kanały w przeciwfazie, które po zgraniu do
// mono się zniosą.
//
// Wykres jest zawsze kwadratowy: okno trzyma wysokość = szerokość + stały pas pod spodem
// (`PanelController.Panel.squareWindowFooter`). W pasie mierniki L/R i korelacji oraz,
// po rozwinięciu przyciskiem obok „Input", opcje z CueMiksa: kropki albo linie, długość
// śladu, wygaszanie, pauza. Zoom i komunikat „czekam na dźwięk" leżą NA wykresie.

import G2EditorCore
import SwiftUI

struct XYPlotPanel: View {
    private var scope = LiveStereoScope.shared
    private var devices = AudioInputDevices.shared
    /// Czułość: 1× = brzeg wykresu to pełne wysterowanie, 8× = brzeg to 1/8 skali.
    /// Patche G2 grają często dużo ciszej niż pełna skala — bez tego cichy dźwięk to
    /// kropka na środku.
    @AppStorage("xyPlotZoom") private var zoom = 1

    /// Kropki połączone linią (tryb „Line" CueMiksa) zamiast samych kropek.
    @AppStorage("xyPlotLines") private var drawsLines = false
    /// Długość śladu w tyknięciach (1/30 s każde).
    @AppStorage("xyPlotLength") private var length = 8
    /// Jak mocno gaśnie najstarsza część śladu: 0 = tak jasna jak świeża, 1 = znika.
    @AppStorage("xyPlotFade") private var fade = 0.55
    /// Przesunięcie skali barw wieku (0…1 = pełny obrót koła barw). 0 = jak w CueMiksie:
    /// świeże czerwone, najstarsze niebieskie; ok. 0,34 = najstarsze czerwone (prośba
    /// użytkownika 2026-09-28).
    @AppStorage("xyPlotHueShift") private var hueShift = 0.0
    /// Rozwinięte opcje pod miernikami — przycisk obok „Input".
    @AppStorage(PanelController.Panel.xyPlotOptionsKey) private var optionsShown = false

    private static let zooms = [1, 2, 4, 8]

    var body: some View {
        VStack(spacing: 0) {
            plot
                .aspectRatio(1, contentMode: .fit)
                .padding(8)
            footerControls
                .padding(.horizontal, 8)
                .frame(height: PanelController.Panel.xyPlotFooter(optionsShown: optionsShown),
                       alignment: .top)
        }
        .frame(minWidth: PanelWindows.squareMinSide)
        .onAppear { scope.addViewer() }
        .onDisappear { scope.removeViewer() }
        // Pas zmienił wysokość — okno idzie za nim, wykres zostaje kwadratowy.
        .onChange(of: optionsShown) { PanelWindows.shared.refitSquare(.xyPlot) }
    }

    // MARK: - Pas pod wykresem

    private var footerControls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                rowLabel("Input")
                LiveAudioSourceMenu { title in
                    Text(title).lineLimit(1).truncationMode(.middle)
                }
                .controlSize(.small)
                .font(.system(size: 10))
                .fixedSize()
                Toggle(isOn: $optionsShown) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(optionsShown ? "Hide the plot options" : "Show the plot options")
                Spacer(minLength: 0)
            }
            .frame(height: 20)
            meterRow("L", level: scope.leftLevel)
            meterRow("R", level: scope.rightLevel)
            correlationRow
            if optionsShown { options }
        }
    }

    /// Opcje z CueMiksa: kropki albo linie, pauza, długość śladu, wygaszanie; do tego
    /// przesunięcie barw (nasze, CueMix go nie ma).
    @ViewBuilder private var options: some View {
        HStack(spacing: 8) {
            Picker("", selection: $drawsLines) {
                Text("Dots").tag(false)
                Text("Lines").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Draw each sample as a dot, or join them with lines")
            Spacer(minLength: 0)
            Button {
                scope.isPaused.toggle()
            } label: {
                Image(systemName: scope.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10))
                    .frame(width: 22, height: 16)
            }
            .help(scope.isPaused ? "Resume the plot" : "Pause the plot — the meters keep running")
        }
        sliderRow("Length", value: Binding(get: { Double(length) }, set: { length = Int($0.rounded()) }),
                  range: 1 ... Double(LiveStereoScope.historyTicks),
                  caption: "\(Int((Double(length) * 1000 / LiveStereoScope.ticksPerSecond).rounded())) ms")
            .help("How much of the most recent sound stays on the plot")
        sliderRow("Fade", value: $fade, range: 0 ... 1, caption: "\(Int((fade * 100).rounded()))%")
            .help("How much the oldest part of the trail fades out")
        HStack(spacing: 6) {
            rowLabel("Colors")
            Slider(value: $hueShift, in: 0 ... 1).controlSize(.mini)
            agePreview
        }
        .frame(height: 18)
        .help("Shift the colour scale — the preview runs from the newest to the oldest sample")
    }

    /// Podgląd skali barw w miejscu podpisu: od najświeższej próbki (lewo) do najstarszej.
    private var agePreview: some View {
        let stops = (0 ... 8).map { Self.color(age: Double($0) / 8, fade: 0, hueShift: hueShift) }
        return RoundedRectangle(cornerRadius: 2)
            .fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
            .frame(width: Self.captionWidth, height: 8)
    }

    private static let labelWidth: CGFloat = 40
    private static let captionWidth: CGFloat = 44

    /// Ile diod ma miernik L/R: 1,5 dB na diodę w skali −60…0 dB.
    private static let meterSegments = 40

    /// Poziom kanału od −60 do 0 dB jako rząd diod rozdzielonych czarnymi kreskami, jak
    /// miniVU w modułach: zielone, od −12 dB żółte, od −3 dB czerwone. Zgaszone zostają
    /// widoczne w ciemnym odcieniu swojej strefy (od 2026-09-27; wcześniej ciągły pasek).
    private func meterRow(_ title: String, level: Double) -> some View {
        let fraction = (level - LiveStereoScope.meterFloorDB) / -LiveStereoScope.meterFloorDB
        let count = Self.meterSegments
        let lit = Int((max(0, min(1, fraction)) * Double(count)).rounded())
        return HStack(spacing: 6) {
            rowLabel(title)
            Self.ledBar(count: count) { Self.meterColor($0, of: count, lit: $0 < lit) }
            rowCaption(level <= LiveStereoScope.meterFloorDB ? "—" : String(format: "%.0f dB", level))
        }
        .frame(height: 10)
        .help("\(title == "L" ? "Left" : "Right") channel peak level")
    }

    /// Kolor diody według strefy (−12 dB = 0,8 skali, −3 dB = 0,95), odcienie z miniVU.
    private static func meterColor(_ index: Int, of count: Int, lit: Bool) -> Color {
        let position = Double(index) / Double(count)
        let segment = position < 0.8 ? 0 : position < 0.95 ? 7 : 11
        return MiniVUGeometry.color(segment: segment, lit: lit)
    }

    /// Rząd diod rozdzielonych czarnymi kreskami, jak miniVU w modułach.
    private static func ledBar(count: Int, color: @escaping (Int) -> Color) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            let gap: CGFloat = 1
            let width = (size.width - gap * CGFloat(count + 1)) / CGFloat(count)
            for index in 0 ..< count {
                let rect = CGRect(x: gap + CGFloat(index) * (width + gap), y: gap,
                                  width: width, height: size.height - gap * 2)
                context.fill(Path(rect), with: .color(color(index)))
            }
        }
        .frame(height: 8)
    }

    /// Korelacja −1…+1 od środka, też diodami (od 2026-09-27): po 20 w każdą stronę.
    /// W prawo zielone (zgodne kanały), w lewo czerwone (przeciwfaza — po zgraniu do mono
    /// dźwięk zniknie). Zgaszone w ciemnym odcieniu swojej połowy.
    private var correlationRow: some View {
        let value = scope.correlation
        let half = Self.meterSegments / 2
        let lit = Int((abs(value ?? 0) * Double(half)).rounded())
        return HStack(spacing: 6) {
            rowLabel("Corr.")
            Self.ledBar(count: half * 2) { index in
                let right = index >= half
                let step = right ? index - half : half - 1 - index
                let on = value.map { right == ($0 >= 0) } == true && step < lit
                return MiniVUGeometry.color(segment: right ? 0 : 11, lit: on)
            }
            rowCaption(value.map { String(format: "%+.2f", $0) } ?? "—")
        }
        .frame(height: 10)
        .help("Correlation: +1 mono, 0 wide stereo, −1 out of phase (cancels in mono)")
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           caption: String) -> some View
    {
        HStack(spacing: 6) {
            rowLabel(title)
            Slider(value: value, in: range).controlSize(.mini)
            rowCaption(caption)
        }
        .frame(height: 18)
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: Self.labelWidth, alignment: .leading)
    }

    private func rowCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: Self.captionWidth, alignment: .trailing)
    }

    // MARK: - Wykres

    private var plot: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.black)
            .overlay(
                Canvas { context, size in
                    drawGrid(in: &context, size: size)
                    drawSamples(in: &context, size: size)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            )
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.15)))
            .overlay(alignment: .topLeading) { zoomMenu.padding(6) }
            .overlay(alignment: .bottomLeading) {
                Text(edgeLabel)
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(6)
                    .help("Value at the edge of the plot — 1 is full scale")
            }
            .overlay {
                if let message = waitingMessage {
                    Text(message)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                }
            }
    }

    /// Komunikat na środku wykresu, gdy nie ma czego rysować (albo macOS podaje ciszę).
    private var waitingMessage: String? {
        let source = LiveAudioSource.stored
        if LiveAudioSourceText.needsChoice(source) { return LiveAudioSourceText.chooseInputs }
        if source.isInterface, let hint = LiveAudioSourceText.permissionHint { return hint }
        let name = LiveAudioSourceText.long(source, devices: devices.devices)
        if LiveAudioSourceText.isMissing(source, devices: devices.devices) {
            return "\(name) — the interface is not connected"
        }
        return scope.isPlaying ? nil : "Waiting for sound from \(name)"
    }

    private var zoomMenu: some View {
        Menu {
            Picker("Zoom", selection: $zoom) {
                ForEach(Self.zooms, id: \.self) { Text("\($0)×").tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text("Zoom \(zoom)×")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sensitivity — zoom in on quiet patches")
    }

    /// Wartość na brzegu wykresu: ±1 przy 1×, ±0.125 przy 8×.
    private var edgeLabel: String {
        let edge = 1 / Double(max(1, zoom))
        return "±" + (edge == 1 ? "1" : String(format: "%g", edge))
    }

    /// Osie L i R przez środek, przekątne mono (L = R) i przeciwfazy (L = −R), okrąg
    /// pełnej skali. Podpisy na końcach osi.
    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let grid = Color.white.opacity(0.14)
        let (width, height) = (size.width, size.height)
        var axes = Path()
        axes.move(to: CGPoint(x: 0, y: height / 2))
        axes.addLine(to: CGPoint(x: width, y: height / 2))
        axes.move(to: CGPoint(x: width / 2, y: 0))
        axes.addLine(to: CGPoint(x: width / 2, y: height))
        context.stroke(axes, with: .color(grid), lineWidth: 1)

        var diagonals = Path()
        diagonals.move(to: CGPoint(x: 0, y: height))
        diagonals.addLine(to: CGPoint(x: width, y: 0))
        diagonals.move(to: .zero)
        diagonals.addLine(to: CGPoint(x: width, y: height))
        context.stroke(diagonals, with: .color(grid), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        context.stroke(Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)),
                       with: .color(grid), lineWidth: 1)

        let label = Color.white.opacity(0.45)
        context.draw(Text("L").font(.system(size: 10, weight: .semibold)).foregroundStyle(label),
                     at: CGPoint(x: width - 8, y: height / 2 - 9))
        context.draw(Text("R").font(.system(size: 10, weight: .semibold)).foregroundStyle(label),
                     at: CGPoint(x: width / 2 + 9, y: 8))
        context.draw(Text("Mono").font(.system(size: 9)).foregroundStyle(label),
                     at: CGPoint(x: width - 18, y: 14))
        context.draw(Text("Out of phase").font(.system(size: 9)).foregroundStyle(label),
                     at: CGPoint(x: width - 36, y: height - 12))
    }

    /// Na ile kawałków dzielimy jedno tyknięcie przy barwieniu — płynniejsze przejście
    /// kolorów niż jeden kolor na 1/30 s.
    private static let slicesPerChunk = 4

    /// Każda ramka to jedna kropka (albo punkt linii): X = lewy kanał, Y = prawy (w górę
    /// dodatnio). Kolor mówi o wieku, jak w MOTU CueMix: najświeższe czerwone, potem żółte,
    /// zielone, a najstarsze niebieskie i przygaszone (`fade`). Najstarsze rysujemy
    /// pierwsze, żeby świeże leżały na wierzchu. Punkty poza brzegiem (po powiększeniu)
    /// pomijamy — przyklejone do brzegu udawałyby przesterowanie; linia się na nich urywa.
    private func drawSamples(in context: inout GraphicsContext, size: CGSize) {
        let history = scope.history.suffix(max(1, length))
        guard !history.isEmpty else { return }
        let half = CGSize(width: size.width / 2, height: size.height / 2)
        let gain = CGFloat(max(1, zoom))
        let steps = history.count * Self.slicesPerChunk
        func point(_ chunk: LiveStereoScope.Chunk, _ index: Int) -> CGPoint? {
            let left = CGFloat(chunk.left[index]) * gain
            let right = CGFloat(chunk.right[index]) * gain
            guard abs(left) <= 1, abs(right) <= 1 else { return nil }
            return CGPoint(x: half.width * (1 + left), y: half.height * (1 - right))
        }
        for (chunkIndex, chunk) in history.enumerated() {
            let count = min(chunk.left.count, chunk.right.count)
            let sliceLength = max(1, (count + Self.slicesPerChunk - 1) / Self.slicesPerChunk)
            for slice in 0 ..< Self.slicesPerChunk {
                let range = (slice * sliceLength) ..< min(count, (slice + 1) * sliceLength)
                guard !range.isEmpty else { continue }
                var path = Path()
                if drawsLines {
                    // Kawałek zaczyna od ostatniej próbki poprzedniego, żeby linia była ciągła.
                    var previous: CGPoint? = range.lowerBound > 0 ? point(chunk, range.lowerBound - 1) : nil
                    for index in range {
                        let current = point(chunk, index)
                        if let previous, let current {
                            path.move(to: previous)
                            path.addLine(to: current)
                        }
                        previous = current
                    }
                } else {
                    for index in range {
                        guard let dot = point(chunk, index) else { continue }
                        path.addRect(CGRect(x: dot.x - 0.75, y: dot.y - 0.75, width: 1.5, height: 1.5))
                    }
                }
                let step = chunkIndex * Self.slicesPerChunk + slice
                let age = steps > 1 ? 1 - Double(step) / Double(steps - 1) : 0
                let color = Self.color(age: age, fade: fade, hueShift: hueShift)
                if drawsLines {
                    context.stroke(path, with: .color(color), lineWidth: 1)
                } else {
                    context.fill(path, with: .color(color))
                }
            }
        }
    }

    /// Wiek 0 (najświeższe) → czerwony, 1 (najstarsze) → niebieski, przez żółty i zielony;
    /// `hueShift` obraca tę skalę po kole barw. `fade` mówi, ile krycia traci najstarsza
    /// część śladu.
    static func color(age: Double, fade: Double, hueShift: Double) -> Color {
        let hue = (hueShift + 0.66 * age).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.9, brightness: 1, opacity: max(0.05, 1 - fade * age))
    }
}
