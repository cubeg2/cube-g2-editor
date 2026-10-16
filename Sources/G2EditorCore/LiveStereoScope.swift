// LiveStereoScope.swift
// Wykres X-Y (goniometr) tego, co emulowany G2 gra w tej chwili: lewy kanał na osi X,
// prawy na osi Y — jak „X-Y Plot" w MOTU CueMix. Mono daje ukośną kreskę, szerokie
// stereo chmurę, a kreska w poprzek (L = −R) to przeciwfaza, która w mono zniknie.
// Do tego mierniki poziomu L/R i korelacji — też jak w CueMiksie.
//
// Dźwięk z tego samego źródła co spektrogram (`LiveAudioSource`): podsłuch wirtualnego G2
// albo dwa wejścia interfejsu audio, do których podpięty jest Nord.

import Foundation
import Observation

@MainActor
@Observable
public final class LiveStereoScope {
    public static let shared = LiveStereoScope()

    /// Ramki jednego tyknięcia: lewy i prawy kanał, każda próbka dźwięku raz.
    public struct Chunk: Sendable, Equatable {
        public let left: [Float]
        public let right: [Float]
    }

    /// Ostatnie tyknięcia, od najstarszego do najświeższego. Wykres barwi je wiekiem —
    /// jak MOTU CueMix: najświeższe czerwone, potem żółte, zielone i niebieskie, zanim
    /// znikną. Ile z nich pokazać, wybiera okno (suwak Length).
    public private(set) var history: [Chunk] = []

    /// Najdłuższy ślad: 16 × 1/30 s ≈ 0,53 s dźwięku.
    public nonisolated static let historyTicks = 16
    /// 30 obrazów na sekundę — płynnie dla oka, a przy 96 kHz to 3200 punktów na obraz.
    public nonisolated static let ticksPerSecond = 30.0

    /// Czy źródło jest otwarte i dźwięk płynie.
    public private(set) var isPlaying = false

    /// Wykres stoi (Pause), ale mierniki chodzą dalej — jak w CueMiksie.
    public var isPaused = false

    /// Szczyt kanału w dB (0 = pełna skala), opadający jak wskaźnik wychyłowy.
    public private(set) var leftLevel = LiveStereoScope.meterFloorDB
    public private(set) var rightLevel = LiveStereoScope.meterFloorDB
    /// Korelacja kanałów −1…+1, wygładzona; `nil` przy ciszy (nie ma czego porównać).
    public private(set) var correlation: Double?

    /// Dół skali mierników.
    public nonisolated static let meterFloorDB = -60.0
    /// Opadanie wskazań: 0,8 dB na tyknięcie = 24 dB/s.
    private static let meterFallPerTick = 0.8

    private var tap: LiveAudioReader?
    private var source = LiveAudioSource.virtualG2
    private var timer: Timer?
    private var viewers = 0

    private init() {}

    /// Zegar chodzi tylko wtedy, gdy okno jest otwarte — zamknięte nie kosztuje nic.
    public func addViewer() {
        viewers += 1
        guard viewers == 1 else { return }
        let ticker = Timer(timeInterval: 1 / Self.ticksPerSecond, repeats: true) { _ in
            MainActor.assumeIsolated { LiveStereoScope.shared.tick() }
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
        isPaused = false
        history = []
        resetMeters()
    }

    private func resetMeters() {
        leftLevel = Self.meterFloorDB
        rightLevel = Self.meterFloorDB
        correlation = nil
    }

    private func tick() {
        let wanted = LiveAudioSource.stored
        if tap == nil || wanted != source {
            if wanted != source { history = [] }
            source = wanted
            tap = wanted.open()
        }
        guard let current = tap else {
            if isPlaying { isPlaying = false }
            return
        }
        let frames = Int(current.sampleRate / Self.ticksPerSecond)
        guard current.isPlaying, let samples = current.latestStereo(frames: frames) else {
            // Źródło stanęło — zamknięte otworzymy na nowo, gdy wróci.
            if isPlaying {
                isPlaying = false
                resetMeters()
            }
            if !current.isPlaying { tap = nil }
            return
        }
        isPlaying = true
        leftLevel = max(Self.peakDecibels(samples.left), leftLevel - Self.meterFallPerTick)
        rightLevel = max(Self.peakDecibels(samples.right), rightLevel - Self.meterFallPerTick)
        if let fresh = Self.correlation(left: samples.left, right: samples.right) {
            // Wygładzenie: sama korelacja jednego tyknięcia skacze przy basie.
            correlation = correlation.map { $0 * 0.7 + fresh * 0.3 } ?? fresh
        } else {
            correlation = nil
        }
        guard !isPaused else { return }
        history.append(Chunk(left: samples.left, right: samples.right))
        if history.count > Self.historyTicks {
            history.removeFirst(history.count - Self.historyTicks)
        }
    }

    /// Szczyt w dB, nie niżej niż dół skali.
    nonisolated static func peakDecibels(_ samples: [Float]) -> Double {
        let peak = Double(samples.lazy.map(abs).max() ?? 0)
        guard peak > 0 else { return meterFloorDB }
        return max(meterFloorDB, 20 * log10(peak))
    }

    /// Korelacja Pearsona bez odejmowania średniej — tak liczą mierniki korelacji
    /// w studiu: +1 = te same kanały (mono), 0 = niezależne, −1 = przeciwfaza.
    /// `nil`, gdy któryś kanał milczy (poniżej −80 dB średnio).
    nonisolated static func correlation(left: [Float], right: [Float]) -> Double? {
        let count = min(left.count, right.count)
        guard count > 0 else { return nil }
        var product = 0.0, leftEnergy = 0.0, rightEnergy = 0.0
        for index in 0 ..< count {
            let (l, r) = (Double(left[index]), Double(right[index]))
            product += l * r
            leftEnergy += l * l
            rightEnergy += r * r
        }
        let silence = 1e-8 * Double(count)
        guard leftEnergy > silence, rightEnergy > silence else { return nil }
        return max(-1, min(1, product / (leftEnergy * rightEnergy).squareRoot()))
    }
}
