// DSPVoiceAllocation.swift
// Ile głosów dostanie każdy slot — przydział kopii obszarów na procesory, tak jak robi to Nord.
//
// Po co: Nord niczego nie odmawia. Gdy performance się nie mieści, po cichu zabiera głosy,
// a slot zbity do zera milczy. Oryginalny edytor pokazywał tylko wynik po fakcie („4 (6)”,
// czerwień przy zerze). Ten kalkulator liczy przydział z samego pliku, bez Norda, i dla
// dwóch wariantów sprzętu: bez karty rozszerzeń (4 DSP) i z kartą albo G2X (8 DSP).
//
// Algorytm przepisany z firmware'u 1.62 (opis → [[Docs/context/firmware-resources]]
// „Przydział głosów”):
//   1. Każdy slot to N kopii obszaru voice (N głosów, Mono/Legato = 1) i jedna kopia fx.
//      Slot, którego jedna kopia nie mieści się w jednym DSP, nie dostaje nic.
//   2. Przed każdym procesorem bilans całości: czy reszta mieści się w pozostałych DSP-ach.
//      Jeśli nie — zabiera po głosie slotowi, który ma ich najwięcej, potem próbuje oddać,
//      i zaczyna rozkładać od pierwszego procesora.
//   3. Procesor po procesorze: przeszukanie wszystkich zestawów kopii, które się mieszczą,
//      i wybór tego, który zjada najwięcej cykli.
// Dwie pozycje strony zerowej płaci tylko pierwsza kopia obszaru danego slotu na danym
// procesorze — to liczniki rodzajów parametrów obszaru, patrz `Request.sharedZeroPage`.
//
// Przeniesione wiernie, łącznie z jednym dziwactwem firmware'u: cofnięcie kopii w
// przeszukiwaniu zwraca wspólną pulę dopiero, gdy slot nie ma kopii NA ŻADNYM procesorze.
// Na drugim i dalszych DSP-ach pula w trakcie szukania więc „przyrasta” — tak liczy Nord.

import Foundation

public struct DSPVoiceAllocation: Sendable, Equatable {
    /// Jedna kopia obszaru na procesorze: jeden głos slotu albo jego część FX.
    public struct Copy: Sendable, Equatable {
        public let slot: Int
        public let area: PatchArea
    }

    /// Co slot zamawia i ile kosztuje jedna kopia każdego obszaru.
    public struct Request: Sendable, Equatable {
        /// Zamówione głosy; 0 = slot nie gra.
        public var voices: Int
        public var voice: G2PatchLoad
        public var fx: G2PatchLoad
        /// Część strony zerowej, którą płaci tylko pierwsza kopia na procesorze.
        public var voiceSharedZeroPage: Int
        public var fxSharedZeroPage: Int

        public init(voices: Int, voice: G2PatchLoad, fx: G2PatchLoad,
                    voiceSharedZeroPage: Int = 0, fxSharedZeroPage: Int = 0)
        {
            self.voices = voices
            self.voice = voice
            self.fx = fx
            self.voiceSharedZeroPage = voiceSharedZeroPage
            self.fxSharedZeroPage = fxSharedZeroPage
        }

        /// Żądanie slotu z patcha. Mono i Legato grają jednym głosem, jak w firmwarze.
        /// Polifonia to pole `voices` z pliku plus jeden — emulator firmware'u 1.62 dał
        /// slotowi z polem 8 dziewięć głosów (2026-10-30), oryginał przyjmuje 1…32.
        public init(patch: G2Patch, playing: Bool) {
            let description = patch.description
            self.init(
                voices: playing ? (description.monopoly != 0 ? 1 : min(32, description.voices + 1)) : 0,
                voice: .estimate(area: .voice, patch: patch),
                fx: .estimate(area: .fx, patch: patch),
                voiceSharedZeroPage: Self.sharedZeroPage(patch.modules(in: .voice)),
                fxSharedZeroPage: Self.sharedZeroPage(patch.modules(in: .fx))
            )
        }

        /// Część strony zerowej płacona raz na procesor: firmware liczy ją z rodzajów
        /// parametrów obszaru. Reguła z pomiaru
        /// (2026-10-30, 30 obszarów z 7 performance'ów, wszystkie zgodne): 1, gdy obszar ma
        /// jakikolwiek typ z puli; +4, gdy ma LFO albo Random (pula 9); +7 za Device i MonoKey.
        /// Keyboard (6) płaci każdy głos osobno.
        public static func sharedZeroPage(_ modules: [G2Module]) -> Int {
            let types = Set(modules.map(\.typeID))
            let pool = types.compactMap { ModuleResourceCostDatabase.poolZeroPage[$0] }.max()
            let device = types.contains { ModuleResourceCostDatabase.onceZeroPage[$0] == 7 }
            return (pool == nil ? 0 : 1) + ((pool ?? 0) >= 9 ? 4 : 0) + (device ? 7 : 0)
        }
    }

    /// Ile procesorów ma Nord: 4 bez karty rozszerzeń, 8 z kartą i w G2X.
    public let dspCount: Int
    /// Zamówione głosy slotów (0 = slot nie gra).
    public let requested: [Int]
    /// Przydzielone głosy slotów. 0 przy zamówionych > 0 znaczy, że slot milczy.
    public let voices: [Int]
    /// Zawartość każdego procesora.
    public let dsps: [[Copy]]
    /// Obciążenie każdego procesora — moc i najciaśniejsza pamięć, w procentach.
    public let loads: [(cycles: Double, memory: Double)]

    public static func == (lhs: DSPVoiceAllocation, rhs: DSPVoiceAllocation) -> Bool {
        lhs.dspCount == rhs.dspCount && lhs.requested == rhs.requested && lhs.voices == rhs.voices
            && lhs.dsps == rhs.dsps
    }

    public init(requests: [Request], dspCount: Int) {
        var allocator = Allocator(requests: requests, dspCount: dspCount)
        let dsps = allocator.run()
        self.dspCount = dspCount
        requested = requests.map(\.voices)
        voices = requests.indices.map { allocator.voices(of: $0) }
        self.dsps = dsps.map { $0.map { Copy(slot: $0 / 2, area: $0 % 2 == Allocator.voice ? .voice : .fx) } }
        loads = dsps.map { copies in
            var sum = Spec()
            var seen = Set<Int>()
            for copy in copies {
                sum.add(allocator.costs[copy], shared: seen.insert(copy).inserted)
            }
            return (sum.cyclesPercent, sum.memoryPercent)
        }
    }
}

/// Koszt kopii albo suma kopii — pola, które firmware sumuje przy przydziale.
private struct Spec {
    var red = 0, blue = 0, zeroPage = 0, sharedZeroPage = 0
    var x = 0, y = 0, program = 0, q = 0, r = 0

    init() {}

    init(_ load: G2PatchLoad, shared: Int) {
        red = load.cyclesRed
        blue = load.cyclesBlue
        sharedZeroPage = min(shared, load.zeroPageMemory)
        zeroPage = load.zeroPageMemory - sharedZeroPage
        x = load.xMemory
        y = load.yMemory
        program = load.programMemory
        q = load.qMemory
        r = load.rMemory
    }

    mutating func add(_ other: Spec, shared: Bool, sign: Int = 1) {
        red += sign * other.red
        blue += sign * other.blue
        zeroPage += sign * other.zeroPage
        x += sign * other.x
        y += sign * other.y
        program += sign * other.program
        q += sign * other.q
        r += sign * other.r
        if shared { sharedZeroPage += sign * other.sharedZeroPage }
    }

    /// Mieści się w `n` procesorach — stałe pojemności jednego DSP z firmware'u.
    func fits(in n: Int) -> Bool {
        x <= n * 4336 && y <= n * 2992 && program <= n * 6498 && zeroPage + sharedZeroPage <= n * 128
            && red + (blue + 3) >> 2 <= n * 1371 && q <= n * 260_096 && r <= n * 256
    }

    /// Cykle tak, jak porównuje je przeszukiwanie (blue/4 w dół).
    var searchCycles: Int { red + blue >> 2 }

    var cyclesPercent: Double { (Double(red) + Double(blue) * 0.25) * 100 / 1371 }

    var memoryPercent: Double {
        [Double(x) / 4336, Double(y) / 2992, Double(program) / 6498,
         Double(zeroPage + sharedZeroPage) / 128, Double(q) / 260_096, Double(r) / 256].max()! * 100
    }
}

/// Stan przydziału — liczniki per slot i obszar jak w strukturze firmware'u, spłaszczone:
/// indeks `slot * 2 + obszar` (obszar 0 = fx, 1 = voice).
private struct Allocator {
    static let fx = 0
    static let voice = 1

    let costs: [Spec]
    let slotCount: Int
    let dspCount: Int
    var requested: [Int]
    var placed: [Int]
    var remaining: [Int]

    // Przeszukiwanie jednego procesora. `onDSP` liczy kopie na tym procesorze — firmware
    // przegląda w tym celu listę, wynik jest ten sam.
    var current = Spec()
    var list: [Int] = []
    var onDSP: [Int]
    var best = Spec()
    var bestList: [Int] = []

    init(requests: [DSPVoiceAllocation.Request], dspCount: Int) {
        self.dspCount = dspCount
        slotCount = requests.count
        let costs = requests.flatMap {
            [Spec($0.fx, shared: $0.fxSharedZeroPage), Spec($0.voice, shared: $0.voiceSharedZeroPage)]
        }
        self.costs = costs
        // Slot, którego jedna kopia nie mieści się w jednym DSP, nie dostaje nic.
        let requested = requests.indices.flatMap { slot in
            let fits = costs[slot * 2].fits(in: 1) && costs[slot * 2 + 1].fits(in: 1)
            let voices = fits ? requests[slot].voices : 0
            return [voices > 0 ? 1 : 0, voices]
        }
        self.requested = requested
        placed = requested.map { _ in 0 }
        remaining = requested
        onDSP = requested.map { _ in 0 }
    }

    func voices(of slot: Int) -> Int {
        requested[slot * 2 + Self.voice]
    }

    mutating func run() -> [[Int]] {
        var dsps = [[Int]](repeating: [], count: dspCount)
        var dsp = 0
        var restarts = 0
        while dsp < dspCount {
            if remaining.allSatisfy({ $0 == 0 }) { break }
            // Zabezpieczenie przed zapętleniem, którego firmware nie ma: bilans, który
            // zabiera i oddaje ten sam głos, kazałby zaczynać od nowa w nieskończoność.
            if restarts < 64, reduceToFit(dspsLeft: dspCount - dsp) {
                restarts += 1
                dsps = dsps.map { _ in [] }
                dsp = 0
                placed = requested.map { _ in 0 }
                remaining = requested
            }
            current = Spec()
            list = []
            best = Spec()
            bestList = []
            search(from: 0)
            dsps[dsp] = bestList
            for copy in bestList {
                placed[copy] += 1
                remaining[copy] -= 1
            }
            dsp += 1
        }
        return dsps
    }

    /// Przeszukanie zestawów kopii dla jednego procesora; zapamiętuje ten, który zjada
    /// najwięcej cykli (przy remisie — więcej strony zerowej).
    private mutating func search(from start: Int) {
        for slot in start ..< slotCount where remaining[slot * 2] + remaining[slot * 2 + 1] != 0 {
            guard add(slot) else { continue }
            if best.searchCycles < current.searchCycles
                || (best.searchCycles == current.searchCycles && best.zeroPage <= current.zeroPage)
            {
                best = current
                bestList = list
            }
            search(from: slot)
            undo()
        }
    }

    /// Dokłada kopię slotu: najpierw głosy, część FX dopiero po wszystkich głosach.
    private mutating func add(_ slot: Int) -> Bool {
        let copy = slot * 2 + (remaining[slot * 2 + Self.voice] == 0 ? Self.fx : Self.voice)
        let shared = onDSP[copy] == 0
        current.add(costs[copy], shared: shared)
        guard current.fits(in: 1) else {
            current.add(costs[copy], shared: shared, sign: -1)
            return false
        }
        list.append(copy)
        onDSP[copy] += 1
        placed[copy] += 1
        remaining[copy] -= 1
        return true
    }

    /// Cofa ostatnią kopię. Pulę zwraca tylko, gdy slot nie ma kopii na żadnym
    /// procesorze — tak jest w firmwarze (patrz nagłówek pliku).
    private mutating func undo() {
        let copy = list.removeLast()
        onDSP[copy] -= 1
        placed[copy] -= 1
        remaining[copy] += 1
        current.add(costs[copy], shared: placed[copy] == 0, sign: -1)
    }

    /// Bilans całości przed procesorem: gdy reszta nie mieści się w `n` procesorach,
    /// zabiera głosy slotowi, który ma ich najwięcej (remis — dalszy slot), a potem
    /// po kolei próbuje oddać. Zwraca, czy cokolwiek zabrał.
    private mutating func reduceToFit(dspsLeft n: Int) -> Bool {
        var total = Spec()
        var sharedVoices = [Int](repeating: 0, count: slotCount)
        for copy in costs.indices {
            for index in 0 ..< remaining[copy] {
                total.add(costs[copy], shared: index < n)
            }
        }
        for slot in 0 ..< slotCount {
            sharedVoices[slot] = min(remaining[slot * 2 + Self.voice], n)
        }

        var trims = [Int](repeating: 0, count: slotCount)
        var mostTrimmed = 0
        var mostTrims = 0
        var trimmed = false
        while !total.fits(in: n) {
            var slot = 0
            for index in 0 ..< slotCount where voices(of: slot) <= voices(of: index) {
                slot = index
            }
            let voice = slot * 2 + Self.voice
            let fx = slot * 2 + Self.fx
            guard requested[voice] > 0 else { break }
            trimmed = true
            requested[voice] -= 1
            trims[slot] += 1
            if trims[slot] > mostTrims {
                mostTrimmed = slot
                mostTrims = trims[slot]
            }
            total.add(costs[voice], shared: false, sign: -1)
            if remaining[voice] - trims[slot] < sharedVoices[slot] {
                total.sharedZeroPage -= costs[voice].sharedZeroPage
                sharedVoices[slot] -= 1
            }
            if requested[voice] == 0, requested[fx] != 0 {
                total.add(costs[fx], shared: true, sign: -1)
                requested[fx] -= 1
            }
            if placed[voice] > requested[voice] { break }
        }
        guard trimmed else { return false }

        // Oddawanie: po kolei od slotu, który stracił najwięcej.
        var eligible = trims.map { $0 > 0 }
        var slot = mostTrimmed
        while eligible.contains(true) {
            if eligible[slot] {
                let voice = slot * 2 + Self.voice
                let fx = slot * 2 + Self.fx
                let restoresFX = requested[voice] == 0
                let sharesPool = sharedVoices[slot] < n
                total.add(costs[voice], shared: sharesPool)
                if restoresFX { total.add(costs[fx], shared: true) }
                if total.fits(in: n) {
                    if sharesPool { sharedVoices[slot] += 1 }
                    if restoresFX { requested[fx] += 1 }
                    requested[voice] += 1
                    trims[slot] -= 1
                    if trims[slot] == 0 { eligible[slot] = false }
                } else {
                    total.add(costs[voice], shared: sharesPool, sign: -1)
                    if restoresFX { total.add(costs[fx], shared: true, sign: -1) }
                    eligible[slot] = false
                }
            }
            slot = (slot + 1) % slotCount
        }
        return true
    }
}
