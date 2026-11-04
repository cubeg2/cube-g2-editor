// VoiceAllocationSection.swift
// Górna część zakładki „DSP Load" — ile głosów dostanie każdy slot i co siedzi na którym DSP.
//
// Nord niczego nie odmawia: gdy performance się nie mieści, po cichu zabiera głosy, a slot
// zbity do zera milczy. Oryginalny edytor pokazywał tylko wynik z Norda („4 (6)", czerwień
// przy zerze). Tu liczymy przydział z samego patcha (`DSPVoiceAllocation`) od razu dla obu
// wariantów sprzętu: G2 bez karty (4 DSP) i z kartą albo G2X (8 DSP).
//
// Kolory pastylek jak paski niżej: zielony — wszystkie głosy, pomarańczowy — mniej niż
// zamówione, czerwony — slot milczy.
//
// Przy podłączonym Nordzie dochodzi kolumna „Live" — ile głosów urządzenie naprawdę dało
// (`0x05`), o ile ekran pokazuje to samo, co jest w Nordzie (`mirrorsDevice`).

import G2Core
import G2EditorCore
import SwiftUI

struct VoiceAllocationSection: View {
    let device: DeviceConnection
    let state: PatchState

    /// Czy użytkownik ma kartę rozszerzeń (Settings ▸ General ▸ Your G2) — od tego startują pudełka.
    @AppStorage(ExpansionBoard.storageKey) private var hasExpansion = false
    /// Drugi wariant włączony na chwilę przełącznikiem; `nil` = jak w ustawieniu. Nie zapisuje się,
    /// więc ponownie otwarte okno pokazuje znów sprzęt użytkownika.
    @State private var previewExpansion: Bool?

    var body: some View {
        let requests = self.requests
        let results = VoiceAllocationCache.results(for: requests)
        let showExpansion = previewExpansion ?? hasExpansion
        let shown = showExpansion ? results.expansion : results.plain
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Voices")
                    .font(.system(size: 11, weight: .semibold))
                Text("estimated")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Picker("", selection: Binding(get: { showExpansion }, set: { previewExpansion = $0 })) {
                    Text("4 DSP").tag(false)
                    Text("8 DSP").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .help("4 DSP: G2 without the expansion board. 8 DSP: with the expansion board, or G2X. "
                    + "Starts from Settings ▸ General ▸ Your G2.")
            }
            processors(shown)
            if let lost = lostVoices(shown) {
                Text(lost)
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 0.95, green: 0.1, blue: 0.1))
            }
            slotTable(requests: requests, plain: results.plain, expansion: results.expansion)
        }
        .onChange(of: hasExpansion) { previewExpansion = nil }
    }

    // MARK: - Dane

    /// Slot gra, gdy jest włączony w performance (z Norda, a bez niego — z pliku) i ma
    /// jakiekolwiek moduły. Pusty slot Nord też obsadza, ale nic nie kosztuje.
    private func isPlaying(_ slot: Int) -> Bool {
        let patch = state.slots[slot]
        guard !patch.modules(in: .voice).isEmpty || !patch.modules(in: .fx).isEmpty else { return false }
        if let performance = device.devicePerformance, performance.slots.indices.contains(slot) {
            return performance.slots[slot].enabled
        }
        let slots = state.performance.slots
        return slots.indices.contains(slot) ? slots[slot].enabled : true
    }

    private var requests: [DSPVoiceAllocation.Request] {
        state.slots.indices.map { DSPVoiceAllocation.Request(patch: state.slots[$0], playing: isPlaying($0)) }
    }

    // MARK: - Procesory

    private func processors(_ allocation: DSPVoiceAllocation) -> some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(allocation.dsps.indices, id: \.self) { index in
                VStack(spacing: 2) {
                    processor(allocation, index)
                    Text(String(format: "%.0f%%", allocation.loads[index].cycles))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .help(processorHelp(allocation, index))
            }
        }
    }

    /// Jeden DSP jako słupek: kopie od dołu, wysokość według cykli.
    private func processor(_ allocation: DSPVoiceAllocation, _ index: Int) -> some View {
        let copies = allocation.dsps[index]
        let requests = self.requests
        return GeometryReader { geo in
            VStack(spacing: 1) {
                Spacer(minLength: 0)
                ForEach(Array(copies.enumerated().reversed()), id: \.offset) { _, copy in
                    let load = copy.area == .voice ? requests[copy.slot].voice : requests[copy.slot].fx
                    let height = max(2, geo.size.height * min(load.cyclesPercent, 100) / 100 - 1)
                    ZStack {
                        Rectangle().fill(slotColor(copy.slot).opacity(copy.area == .voice ? 0.55 : 0.25))
                        if height >= 11 {
                            Text(slotLetter(copy.slot) + (copy.area == .fx ? "fx" : ""))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.8))
                        }
                    }
                    .frame(height: height)
                }
            }
        }
        .frame(height: 72)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
    }

    private func processorHelp(_ allocation: DSPVoiceAllocation, _ index: Int) -> String {
        let load = allocation.loads[index]
        return String(format: "DSP %d — cycles %.0f%%, memory %.0f%%", index + 1, load.cycles, load.memory)
    }

    /// Co nie zmieściło się w pokazanym wariancie — pod pudełkami, żeby było widać od razu.
    private func lostVoices(_ allocation: DSPVoiceAllocation) -> String? {
        let parts = allocation.requested.indices.compactMap { slot -> String? in
            let asked = allocation.requested[slot]
            let got = allocation.voices[slot]
            guard got < asked else { return nil }
            if got == 0 { return "\(slotLetter(slot)) silent" }
            let lost = asked - got
            return "\(slotLetter(slot)) −\(lost) voice\(lost == 1 ? "" : "s")"
        }
        return parts.isEmpty ? nil : "Doesn't fit: " + parts.joined(separator: ", ")
    }

    // MARK: - Tabela slotów

    /// Głosy z Norda — tylko gdy to, co widać, jest też w Nordzie; inaczej liczby
    /// opisywałyby inny patch niż ten na ekranie.
    private var liveVoices: [Int]? {
        guard device.status == .connected, state.mirrorsDevice else { return nil }
        return device.assignedVoices
    }

    private func slotTable(requests: [DSPVoiceAllocation.Request], plain: DSPVoiceAllocation,
                           expansion: DSPVoiceAllocation) -> some View
    {
        let live = liveVoices
        return Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
            GridRow {
                Text("")
                Text("Patch")
                Text("G2")
                Text("Expansion")
                if live != nil {
                    Text("Live")
                        .help("Voices the connected G2 actually gave each slot")
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            ForEach(requests.indices, id: \.self) { slot in
                GridRow {
                    Text(slotLetter(slot))
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .background(RoundedRectangle(cornerRadius: 3).fill(slotColor(slot).opacity(0.35)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(patchName(slot))
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .fixedSize()
                        Text(voiceMode(slot, requested: requests[slot].voices))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    pill(asked: plain.requested[slot], got: plain.voices[slot])
                    pill(asked: expansion.requested[slot], got: expansion.voices[slot])
                    if let live, live.indices.contains(slot) {
                        pill(asked: plain.requested[slot], got: live[slot])
                    }
                }
            }
        }
    }

    /// Nazwa w osobnym wierszu, tryb głosów pod nią — 16 znaków nazwy mieści się w minimalnym
    /// oknie (`PanelController.Panel.minWindowSize`), więc nic się nie ucina.
    private func patchName(_ slot: Int) -> String {
        let name = state.slots[slot].name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "No name" : name
    }

    private func voiceMode(_ slot: Int, requested: Int) -> String {
        guard requested > 0 else { return "off" }
        let mode = state.slots[slot].description.monopoly
        return mode == 2 ? "legato" : mode == 1 ? "mono" : "\(requested) voices"
    }

    /// „4 of 6" w kolorze: zielony — wszystkie głosy, pomarańczowy — mniej, czerwony — cisza.
    @ViewBuilder
    private func pill(asked: Int, got: Int) -> some View {
        if asked == 0 {
            Text("—")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        } else {
            let color = got == 0 ? Color(red: 0.95, green: 0.1, blue: 0.1)
                : got < asked ? Color(red: 0.95, green: 0.6, blue: 0.0)
                : Color(red: 0.0, green: 0.75, blue: 0.3)
            Text(got == 0 ? "silent" : "\(got) of \(asked)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.22)))
                .foregroundStyle(color)
        }
    }

    // MARK: - Sloty

    private func slotLetter(_ slot: Int) -> String {
        ["A", "B", "C", "D"][slot]
    }

    private func slotColor(_ slot: Int) -> Color {
        [Color(red: 0.11, green: 0.62, blue: 0.46), Color(red: 0.50, green: 0.47, blue: 0.87),
         Color(red: 0.85, green: 0.35, blue: 0.19), Color(red: 0.83, green: 0.33, blue: 0.49)][slot]
    }
}

/// Czy G2 użytkownika ma kartę rozszerzeń. Nord tego nie zgłasza (odpowiedź na pytanie
/// o wersję niesie tylko model), oryginał też nie pyta — więc mówi to użytkownik, raz.
enum ExpansionBoard {
    static let storageKey = "g2_has_expansion_board"
}

/// Ostatni wynik przydziału — przeszukiwanie trwa do kilkudziesięciu milisekund, a widok
/// przerysowuje się przy każdym ruchu gałki, który kosztów nie zmienia.
@MainActor
private enum VoiceAllocationCache {
    private static var lastRequests: [DSPVoiceAllocation.Request]?
    private static var last: (plain: DSPVoiceAllocation, expansion: DSPVoiceAllocation)?

    static func results(for requests: [DSPVoiceAllocation.Request])
        -> (plain: DSPVoiceAllocation, expansion: DSPVoiceAllocation)
    {
        if requests == lastRequests, let last { return last }
        let results = (DSPVoiceAllocation(requests: requests, dspCount: 4),
                       DSPVoiceAllocation(requests: requests, dspCount: 8))
        lastRequests = requests
        last = results
        return results
    }
}
