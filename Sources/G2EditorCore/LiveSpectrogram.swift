// LiveSpectrogram.swift
// Widmo tego, co emulowany G2 GRA W TEJ CHWILI.
//
// Dźwięk wychodzi z emulatora przez CoreAudio prosto na kartę — edytor nie ma go skąd
// wziąć, chyba że przez drugie urządzenie i trasę w systemie. Zamiast tego emulator
// wystawia ten sam pierścień jeszcze raz, w pliku odwzorowanym w pamięci
// (`firmware/work/g2live.cpp`, funkcje `tapOpen`/`tapPush`). My go tylko CZYTAMY:
// bierzemy najświeższe ramki, liczymy widmo i odkładamy jedną kolumnę obrazu.
//
// Dlaczego nie strumień przez gniazdo USB emulatora: tamtędy idzie protokół G2, a
// prawdziwy Nord dźwięku nie odsyła. Podsłuch jest więc świadomie JEDNOSTRONNY i
// istnieje tylko dla emulatora. Dla Norda jest drugie źródło — dwa wejścia interfejsu
// audio (`LiveAudioInput.swift`); które gra, wybiera `LiveAudioSource`.

import Accelerate
import Foundation
import Observation

/// Pierścień audio emulatora, odwzorowany w pamięci. Otwarty = emulator gra.
public final class LiveAudioTap {
    /// Plik uzgodniony z emulatorem. Powstaje przy starcie dźwięku i znika (traci
    /// znacznik) przy jego zatrzymaniu.
    public static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/G2Editor/live-audio.tap")

    /// „ATG2" — dopóki go nie ma, reszty pliku nie wolno czytać.
    private static let magic: UInt32 = 0x3247_5441
    /// Najstarsza czytana wersja: 2 — od 2026-09-23, razem z licznikami niedoborów. Wersji 1
    /// nie czytamy: nagłówek miał wtedy 24 bajty i pierścień zaczynał się gdzie indziej.
    /// Wersja 3 (2026-09-24) dokłada tylko pola wtyczki DAW w zapasie nagłówka.
    private static let minimumVersion: UInt32 = 2
    /// Stałe 64 bajty z zapasem — kolejne pole nie przesunie dźwięku.
    private static let headerBytes = 64

    private let base: UnsafeRawPointer
    private let mappedBytes: Int
    private let ring: UnsafePointer<Int16>
    private let capacity: Int
    public let sampleRate: Double

    /// `url` jest wymienne wyłącznie dla testów — emulator i edytor umawiają się
    /// na jedną ścieżkę i nikt jej nie wybiera.
    public init?(url: URL = LiveAudioTap.fileURL) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > Self.headerBytes else { return nil }
        let bytes = Int(info.st_size)
        guard let map = mmap(nil, bytes, PROT_READ, MAP_SHARED, descriptor, 0),
              map != MAP_FAILED else { return nil }
        let pointer = UnsafeRawPointer(map)
        let frames = Int(pointer.load(fromByteOffset: 12, as: UInt32.self))
        let rate = Double(pointer.load(fromByteOffset: 8, as: UInt32.self))
        // Pojemność musi być potęgą dwójki — na tym stoi zawijanie pierścienia.
        guard pointer.load(fromByteOffset: 4, as: UInt32.self) >= Self.minimumVersion,
              frames > 0, frames & (frames - 1) == 0, rate > 0,
              Self.headerBytes + frames * 4 <= bytes
        else {
            munmap(map, bytes)
            return nil
        }
        base = pointer
        mappedBytes = bytes
        capacity = frames
        sampleRate = rate
        ring = (pointer + Self.headerBytes).assumingMemoryBound(to: Int16.self)
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), mappedBytes)
    }

    /// Czy emulator wciąż gra. Znacznik zeruje się przy zatrzymaniu dźwięku.
    public var isPlaying: Bool {
        base.load(fromByteOffset: 0, as: UInt32.self) == Self.magic
    }

    /// Stan stanowiska audio — to, czego po samym dźwięku nie widać.
    ///
    /// ⚠️ Oba pierwsze pola liczą **RAMKI, nie zdarzenia** — emulator dolicza tyle ramek,
    /// ile ich zabrakło albo ile wyrzucił, więc jedyny sensowny odczyt to czas.
    ///
    /// `silentFrames` to ramki ciszy wpisane karcie, bo dźwięku nie było na czas —
    /// **to jest trzeszczenie**, którego w widmie nie widać, bo cisza idzie na kartę
    /// obok podsłuchu. `skippedFrames` to przypadek odwrotny: pierścień urósł ponad
    /// limit i nadmiar przepadł, czyli w dźwięku jest sklejka.
    ///
    /// Te dwa chodzą PARAMI (zmierzone 2026-09-23: 116 224 wobec 115 360 przez cały
    /// przebieg). Zegar `g_played` w emulatorze idzie o pełny bufor także przy
    /// niedoborze, więc każda brakująca ramka na stałe podnosi zaległość, a limit
    /// zaraz potem wyrzuca dokładnie tyle samo. Jedno potknięcie = dwa szwy: dziura
    /// i sklejka.
    ///
    /// `backlog` mówi, ile dźwięku czeka w pierścieniu: im bliżej zera, tym bliżej
    /// niedoboru.
    public struct Health {
        public var silentFrames: UInt64
        public var skippedFrames: UInt64
        public var backlogFrames: UInt32
        public var backlogMaxFrames: UInt32
    }

    public var health: Health {
        Health(silentFrames: base.load(fromByteOffset: 24, as: UInt64.self),
               skippedFrames: base.load(fromByteOffset: 32, as: UInt64.self),
               backlogFrames: base.load(fromByteOffset: 40, as: UInt32.self),
               backlogMaxFrames: base.load(fromByteOffset: 44, as: UInt32.self))
    }

    /// Najświeższe `wanted` ramek zmiksowanych do mona, w skali −1…1.
    ///
    /// Piszący nas nie czeka, więc przy bardzo dużym zaległym buforze ostatnia ramka
    /// może się rozjechać w pół próbki. Pierścień ma ~0,7 s, a my bierzemy z niego
    /// ostatnie 43 ms, więc to jedna próbka na tysiące — w widmie niewidoczna.
    public func latest(frames wanted: Int) -> [Float]? {
        guard isPlaying, wanted > 0, wanted <= capacity else { return nil }
        let written = base.load(fromByteOffset: 16, as: UInt64.self)
        guard written >= UInt64(wanted) else { return nil }
        let start = Int(written) - wanted
        var out = [Float](repeating: 0, count: wanted)
        let mask = capacity - 1
        for index in 0 ..< wanted {
            let slot = (start + index) & mask
            let left = Float(ring[2 * slot])
            let right = Float(ring[2 * slot + 1])
            out[index] = (left + right) / 65536
        }
        return out
    }

    /// Najświeższe `wanted` ramek osobno dla lewego i prawego kanału, w skali −1…1 —
    /// dla wykresu X-Y, który żyje z RÓŻNICY między kanałami.
    public func latestStereo(frames wanted: Int) -> (left: [Float], right: [Float])? {
        guard isPlaying, wanted > 0, wanted <= capacity else { return nil }
        let written = base.load(fromByteOffset: 16, as: UInt64.self)
        guard written >= UInt64(wanted) else { return nil }
        let start = Int(written) - wanted
        var left = [Float](repeating: 0, count: wanted)
        var right = [Float](repeating: 0, count: wanted)
        let mask = capacity - 1
        for index in 0 ..< wanted {
            let slot = (start + index) & mask
            left[index] = Float(ring[2 * slot]) / 32768
            right[index] = Float(ring[2 * slot + 1]) / 32768
        }
        return (left, right)
    }
}

/// Spektrogram na żywo w układzie poziomym, jak analizator w MOTU CueMix: **częstotliwość
/// biegnie w prawo**, a **czas płynie w górę** — najnowszy plasterek jest na dole, starsze
/// wysuwają się ku górze. Jedno tyknięcie zegara = jeden plasterek widma = jeden wiersz.
///
/// Widoki czytają `slices` — bajty 0…255, indeks 0 to 20 Hz, ostatni 20 kHz. Który
/// wycinek z tego pokazać, wybiera okno (zakres Min/Max) — analiza jest zawsze pełna,
/// więc zmiana zakresu przestawia także historię, która już jest na ekranie.
@MainActor
@Observable
public final class LiveSpectrogram {
    public static let shared = LiveSpectrogram()

    /// Punkty widma w poziomie. Przy 128 krzywa poziomu wyglądała na schodkowatą; 512,
    /// bo okno potrafi pokazać sam wycinek pasma (np. 100 Hz – 5 kHz) i ma wtedy z czego.
    public nonisolated static let bins = 512
    /// Wysokość historii. Przy 20 plasterkach na sekundę to 12 s przeszłości.
    public nonisolated static let historyRows = 240
    /// Okno analizy — 4096 próbek przy 96 kHz to 43 ms, czyli bin co 23 Hz.
    private static let windowSize = 4096
    /// Pasmo analizy. Okno domyślnie pokazuje z niego 20 Hz – 16 kHz: wyżej emulator ma
    /// obrazy próbkowania rdzeni DSP, a nie barwę, którą ktoś usłyszy (ten sam sufit,
    /// na którym stanęły miary w narzędziach Claude'a). Do 20 kHz — dla Norda przez interfejs.
    public nonisolated static let topHz = 20000.0
    public nonisolated static let bottomHz = 20.0
    /// Dół skali głośności. 84 dB to siedem działek po 12 dB — ta sama podziałka,
    /// co na analizatorze MOTU CueMix, z którego wzięty jest układ.
    public nonisolated static let floorDB = 84.0

    /// Plasterki od najstarszego do najświeższego. Pusta tablica = nic jeszcze nie zagrało.
    public private(set) var slices: [[UInt8]] = []

    /// Szczyty z ostatnich sekund, opadające — druga, cieńsza krzywa. Na niej widać
    /// rezonans filtra i formanty, których chwilowe widmo nie zdąży pokazać.
    public private(set) var peaks: [UInt8] = []

    /// Najświeższe widmo w decybelach (0 … −84) — to rysuje biała krzywa.
    public var latestDecibels: [Double] { Self.decibels(slices.last ?? []) }
    public var peakDecibels: [Double] { Self.decibels(peaks) }

    /// Jasność 0…255 z powrotem na decybele — ta sama skala w obie strony.
    public nonisolated static func decibels(_ levels: [UInt8]) -> [Double] {
        levels.map { Double($0) / 255 * floorDB - floorDB }
    }

    /// Obraz stoi — nowe plasterki nie dochodzą. Analiza też nie chodzi, więc zamrożenie
    /// jest darmowe; służy do przyjrzenia się temu, co właśnie przeleciało.
    public var isFrozen = false
    /// Czy źródło jest otwarte i dźwięk płynie.
    public private(set) var isPlaying = false

    /// Stan stanowiska audio z ostatniego tyknięcia — dziury, sklejki, zaległość. Tylko
    /// dla emulatora; wejścia interfejsu takich liczników nie mają.
    ///
    /// Dwa pierwsze pola są liczone **od chwili otwarcia podglądu**, nie od startu
    /// emulatora. Sam rozruch kosztuje ponad sekundę ciszy (kolejka gra, zanim DSP
    /// cokolwiek policzą), więc liczniki od startu świeciłyby na pomarańczowo zawsze
    /// i nie odpowiadałyby na jedyne ważne pytanie: „czy trzeszczy TERAZ".
    public private(set) var health: LiveAudioTap.Health?

    /// Odczyt z pierwszego tyknięcia — od niego odejmujemy, żeby nie liczyć rozruchu.
    private var healthBase: LiveAudioTap.Health?

    private var tap: LiveAudioReader?
    /// Źródło, z którego otwarto `tap` — gdy użytkownik wybierze inne, otwieramy na nowo.
    private var source = LiveAudioSource.virtualG2
    private var timer: Timer?
    private var viewers = 0
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: LiveSpectrogram.windowSize, isHalfWindow: false)
    /// Plan FFT powstaje RAZ i służy wszystkim kolumnom — jest niezmienny, a tworzenie go
    /// przy każdym tyknięciu byłoby jedyną drogą, którą ten zegar mógłby cokolwiek kosztować.
    /// Zmierzone w wersji wydaniowej: 0,011 ms na kolumnę, czyli 0,2 ms na sekundę obrazu.
    private let dft = try? vDSP.DiscreteFourierTransform(previous: nil,
                                                         count: LiveSpectrogram.windowSize,
                                                         direction: .forward,
                                                         transformType: .complexComplex,
                                                         ofType: Float.self)

    private init() {}

    /// Widok zaczyna patrzeć. Zegar chodzi tylko wtedy, gdy ktoś patrzy — zamknięte okno
    /// i wyłączone tło nie kosztują nic.
    public func addViewer() {
        viewers += 1
        guard viewers == 1 else { return }
        let ticker = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { LiveSpectrogram.shared.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    public func removeViewer() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        tap = nil
        isPlaying = false
        health = nil
        healthBase = nil
        slices = []
        peaks = []
    }

    private func tick() {
        let wanted = LiveAudioSource.stored
        if tap == nil || wanted != source {
            if wanted != source {
                // Inne źródło — stara historia i liczniki emulatora nie mają z nim związku.
                slices = []
                peaks = []
                healthBase = nil
                health = nil
            }
            source = wanted
            tap = wanted.open()
        }
        guard let current = tap else {
            if isPlaying { isPlaying = false }
            return
        }
        guard current.isPlaying, let samples = current.latest(frames: Self.windowSize) else {
            // Emulator stanął albo jeszcze nie zagrał (interfejs zniknął). Obraz zostaje
            // na ekranie, ale zamknięte źródło odkładamy — następne tyknięcie otworzy je
            // na nowo, gdy wróci.
            if isPlaying { isPlaying = false }
            if !current.isPlaying { tap = nil
                healthBase = nil
            }
            return
        }
        isPlaying = true
        if let emulator = current as? LiveAudioTap {
            updateHealth(emulator.health)
        }
        guard !isFrozen else { return }
        let fresh = slice(from: samples, rate: current.sampleRate)
        slices.append(fresh)
        if slices.count > Self.historyRows {
            slices.removeFirst(slices.count - Self.historyRows)
        }
        updatePeaks(with: fresh)
    }

    private func updateHealth(_ now: LiveAudioTap.Health) {
        // Emulator ubity bez wyzerowania znacznika zostawia plik z wysokimi licznikami;
        // po ponownym starcie spadają do zera, a odejmowanie bez tego zabezpieczenia
        // byłoby ujemne — na `UInt64` to pułapka, czyli wywrotka edytora.
        var start = healthBase ?? now
        if now.silentFrames < start.silentFrames || now.skippedFrames < start.skippedFrames {
            start = now
        }
        healthBase = start
        health = LiveAudioTap.Health(silentFrames: now.silentFrames - start.silentFrames,
                                     skippedFrames: now.skippedFrames - start.skippedFrames,
                                     backlogFrames: now.backlogFrames,
                                     backlogMaxFrames: now.backlogMaxFrames)
    }

    /// Szczyt idzie w górę natychmiast, a opada o `peakFallPerTick` — jak wskaźnik
    /// wychyłowy z przytrzymaniem. 3 jednostki na tyknięcie to ~1 dB, czyli pełny
    /// zjazd od zera w cztery sekundy.
    private static let peakFallPerTick: UInt8 = 3

    private func updatePeaks(with fresh: [UInt8]) {
        if peaks.count != fresh.count {
            peaks = fresh
            return
        }
        for index in peaks.indices {
            let fallen = peaks[index] > Self.peakFallPerTick ? peaks[index] - Self.peakFallPerTick : 0
            peaks[index] = Swift.max(fallen, fresh[index])
        }
    }

    /// Jeden plasterek widma: FFT okna, potem odczyt w `bins` punktach rozłożonych
    /// logarytmicznie — tak, jak słyszy ucho i jak opisana jest oś w CueMiksie.
    func slice(from samples: [Float], rate: Double) -> [UInt8] {
        let size = Self.windowSize
        var real = [Float](repeating: 0, count: size)
        for index in 0 ..< min(size, samples.count) {
            real[index] = samples[index] * window[index]
        }
        let imaginary = [Float](repeating: 0, count: size)
        guard let dft else { return [UInt8](repeating: 0, count: Self.bins) }
        let (outReal, outImaginary) = dft.transform(real: real, imaginary: imaginary)
        let scale = 2 / max(window.reduce(0, +), 1)
        let bins = size / 2
        var magnitudes = [Float](repeating: 0, count: bins)
        for index in 0 ..< bins {
            magnitudes[index] = (outReal[index] * outReal[index]
                + outImaginary[index] * outImaginary[index]).squareRoot() * scale
        }

        let binWidth = rate / Double(size)
        // Oś jest stała (20 Hz – 20 kHz) niezależnie od częstotliwości próbkowania, żeby
        // punkt obrazu zawsze znaczył to samo; powyżej połowy próbkowania zostaje czarno.
        let ratio = Self.topHz / Self.bottomHz
        var out = [UInt8](repeating: 0, count: Self.bins)
        let step = pow(ratio, 1 / Double(Self.bins - 1))
        for bin in 0 ..< Self.bins {
            // Punkt 0 = lewa krawędź = 20 Hz; ostatni = sufit pasma.
            let position = Double(bin) / Double(Self.bins - 1)
            let hz = Self.bottomHz * pow(ratio, position)
            // W górze skali jedno pole obrazu obejmuje kilka prążków FFT — bierzemy
            // wtedy NAJGŁOŚNIEJSZY z nich, a nie wartość w jednym punkcie. Inaczej
            // wąski szczyt (harmoniczna, rezonans filtra) migocze i czyta o 2 dB za
            // cicho, zależnie od tego, gdzie akurat wypadł między prążkami.
            let lowHz = hz / step.squareRoot()
            let highHz = hz * step.squareRoot()
            guard hz < rate / 2 else { break }
            let firstBin = Int((lowHz / binWidth).rounded(.up))
            let lastBin = Int((highHz / binWidth).rounded(.down))
            var magnitude: Float = 0
            if lastBin >= firstBin, firstBin >= 1, lastBin < bins {
                for index in firstBin ... lastBin {
                    magnitude = Swift.max(magnitude, magnitudes[index])
                }
            } else {
                // Pasmo węższe niż prążek (dół skali) — liniowo między sąsiadami.
                let place = hz / binWidth
                let low = Int(place)
                guard low >= 0, low + 1 < bins else { continue }
                let fraction = Float(place - Double(low))
                magnitude = magnitudes[low] * (1 - fraction) + magnitudes[low + 1] * fraction
            }
            guard magnitude > 0 else { continue }
            let decibels = 20 * log10(Double(magnitude))
            let level = Swift.max(0, Swift.min(1, (decibels + Self.floorDB) / Self.floorDB))
            out[bin] = UInt8(level * 255)
        }
        return out
    }
}
