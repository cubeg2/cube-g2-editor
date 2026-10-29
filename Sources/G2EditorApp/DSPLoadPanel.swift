// DSPLoadPanel.swift
// Zawartość zakładki „DSP Load" — ile mocy i pamięci zjada patch w tym slocie.
//
// Oryginalny edytor Clavii mówi, ile zostało, DOPIERO po dodaniu modułu. Pierwszy krok
// do odwrócenia tej kolejności to w ogóle pokazać stan bieżący; liczby biorą się
// z komunikatu `0x72`, który Nord nadaje sam po każdej zmianie struktury
// (patrz `G2PatchLoad`).
//
// Bez podłączonego Norda ten sam odczyt liczy `G2PatchLoad.estimate` ze zmierzonej tabeli
// kosztów modułów. Pierwszeństwo ma zawsze urządzenie: ono podaje stan faktyczny. Slot bez
// raportu (Nord odłączony, raport jeszcze nie doszedł, slot nie gra — #167) dostaje
// dopisek „estimated” w nagłówku; wspólny napis na dole kłamał, gdy sloty się różniły.

import G2Core
import G2EditorCore
import SwiftUI

struct DSPLoadPanel: View {
    let device: DeviceConnection
    let state: PatchState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(slots, id: \.self) { slot in
                    slotSection(slot)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Wszystkie cztery sloty, bo limit DSP dzielą między siebie.
    private var slots: [Int] {
        Array(state.slots.indices)
    }

    private func slotSection(_ slot: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(slotLabel(slot))
                    .font(.system(size: 11, weight: .semibold))
                if slot == device.activeSlot {
                    Text("active")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                if let note = estimateNote(slot) {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            areaRows(slot: slot, area: .voice, title: "Voice")
            areaRows(slot: slot, area: .fx, title: "FX")
        }
    }

    private func slotLabel(_ slot: Int) -> String {
        "Slot \(["A", "B", "C", "D"][slot])"
    }

    /// Odczyt ze sprzętu, a gdy go nie ma — policzony z patcha.
    private func load(slot: Int, area: PatchArea) -> G2PatchLoad? {
        if let reported = device.patchLoad(slot: slot, area: area) { return reported }
        guard state.slots.indices.contains(slot) else { return nil }
        return .estimate(area: area, modules: state.slots[slot].modules(in: area),
                         cables: state.slots[slot].cables(in: area))
    }

    /// Dopisek dla slotu, którego liczby pochodzą z tabeli kosztów, a nie z Norda. Slot, który
    /// nie gra, Nord przelicza dopiero po włączeniu — do tego czasu szacunek mówi, ile zajmie.
    private func estimateNote(_ slot: Int) -> String? {
        let reported = [PatchArea.voice, .fx].allSatisfy { device.patchLoad(slot: slot, area: $0) != nil }
        guard !reported else { return nil }
        let playing = device.devicePerformance.map { $0.slots.indices.contains(slot) ? $0.slots[slot].enabled : true }
            ?? true
        return device.status == .connected && !playing ? "estimated — not playing" : "estimated"
    }

    @ViewBuilder
    private func areaRows(slot: Int, area: PatchArea, title: String) -> some View {
        if let load = load(slot: slot, area: area) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                bar(label: "Cycles", percent: load.cyclesPercent)
                bar(label: "Memory", percent: load.memoryPercent)
                // Sam procent nie mówi, o co patch się rozbije. Przy pustym obszarze
                // wszystkie siedem zasobów jest na zerze i „wąskie gardło" nic nie znaczy.
                if load.memoryPercent > 0 {
                    bottleneck(load.criticalResource)
                }
            }
            .padding(.leading, 4)
        } else {
            HStack {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text("—").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.leading, 4)
        }
    }

    /// Który z siedmiu zasobów jest najbliżej limitu, i o ile dokładnie chodzi.
    /// Wcięcie równa się z paskami wyżej: 46 pt etykiety + 6 pt odstępu.
    private func bottleneck(_ critical: DSPCriticalResource) -> some View {
        Text("\(critical.resource.label) \(critical.used)/\(critical.limit)")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.leading, 52)
    }

    private func bar(label: String, percent: Double) -> some View {
        let clamped = min(max(percent, 0), 100)
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 46, alignment: .leading)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.10))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: percent))
                        .frame(width: geo.size.width * clamped / 100)
                }
            }
            .frame(height: 8)
            // Pasek musi się obciąć na krawędzi, ale LICZBA nie: raport `0x72` mówi, ile
            // patch ŻĄDA, i potrafi przekroczyć limit (zmierzone 2026-09-08 — sześć delayów
            // dało 110,8% Qmem, dziesięć 184,6%). Obcinanie liczby zamieniało „jesteś dwa
            // razy ponad budżet" w spokojne „100%".
            Text(String(format: "%3.0f%%", max(percent, 0)))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 34, alignment: .trailing)
        }
    }

    /// Progi są w `DSPLoadLevel` — wspólne z odczytem w belce górnej.
    private func color(for percent: Double) -> Color {
        switch DSPLoadLevel(percent: percent) {
        case .critical: Color(red: 0.95, green: 0.1, blue: 0.1)
        case .warning: Color(red: 0.95, green: 0.6, blue: 0.0)
        case .safe: Color(red: 0.0, green: 0.75, blue: 0.3)
        }
    }
}
