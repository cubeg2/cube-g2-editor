// MasterClockView.swift
// Globalny Run/Stop i tempo w pasku narzędzi. Wszystkie trzy odtworzone edytory kładą tę
// kontrolkę w tym samym miejscu — w belce nad slotami, zaraz za nazwą performance'u —
// i budują ją tak samo: odczyt BPM, strzałki po ±1 i JEDEN przełącznik `Run`
// (Clavia TB Window, BVerhue `gdMasterClock` + `btClockRun`, g2fx `mkGlobalBar`)
// → [[Docs/ui/master-clock]].
//
// Zachowania przepisane z oryginału:
//   • zakres 30…240 BPM
//   • zegar zewnętrzny → odczyt na CZERWONO i strzałki martwe (`ChangeClockRate` wychodzi
//     bez wysłania czegokolwiek, gdy `IsClockExternal()`)
//   • nie ma czego pokazać → `---`

import G2Core
import G2EditorCore
import SwiftUI

struct MasterClockView: View {
    @Bindable var state: PatchState
    let device: DeviceConnection

    var body: some View {
        HStack(spacing: 6) {
            // Dwa wiersze, jak w oryginale (TB Window (Draw) wypisuje „Master" i „Clock"
            // jedno pod drugim) i jak w g2fx (`Master\nClock`) — etykieta zajmuje wtedy
            // wysokość belki zamiast jej szerokości, której w pasku narzędzi brakuje.
            TopBarCaption(text: "Master", secondLine: "Clock")

            TopBarValueField(text: bpm.map(String.init) ?? "---", width: 40)
                // Czerwień znaczy „tempo przychodzi z zewnątrz, nie ruszasz go" — tak samo
                // sygnalizują to oba odtworzone edytory (Clavia maluje tło na czerwono,
                // BVerhue ustawia `gdMasterClock.Font.Color := clRed`).
                .foregroundStyle(device.clockIsExternal ? Color.red : Color.primary)
                // Tempo gra od razu w trakcie ruchu — słychać, dokąd się jedzie.
                .topBarDragAdjust(value: bpm, range: G2UsbProtocol.masterClockRange,
                                  pointsPerStep: 2, isEnabled: canEditTempo) { setBPM($0) }

            TopBarStepper(
                canIncrement: canEditTempo && (bpm ?? 0) < G2UsbProtocol.masterClockRange.upperBound,
                canDecrement: canEditTempo && (bpm ?? 0) > G2UsbProtocol.masterClockRange.lowerBound,
                onIncrement: { setBPM((bpm ?? 120) + 1) },
                onDecrement: { setBPM((bpm ?? 120) - 1) }
            )

            // Zegar chodzi → napis i ramka na zielono, jak dioda transportu.
            TopBarButton(content: .text("Run"),
                         isOn: running,
                         tint: .green,
                         isEnabled: canEditRun) { toggleRun() }
        }
        .help(helpText)
    }

    // MARK: - Skąd wartości

    /// Podłączony Nord jest źródłem prawdy — zegar jest jego, nie pliku. Bez urządzenia
    /// pokazujemy i edytujemy to, co niesie otwarty performance (sekcja 0x11 pliku `.prf2`);
    /// `.pch2` zegara głównego nie ma wcale, więc wtedy jest `---`.
    private var bpm: Int? {
        if device.status == .connected { return device.clockBPM }
        return state.hasPerformanceSettings ? state.performance.masterClock : nil
    }

    private var running: Bool {
        device.status == .connected ? device.clockRunning : state.performance.masterClockRunning
    }

    private var canEditTempo: Bool {
        bpm != nil && !device.clockIsExternal
    }

    private var canEditRun: Bool {
        device.status == .connected || state.hasPerformanceSettings
    }

    private var helpText: String {
        if device.clockIsExternal {
            return "The G2 is following an external MIDI clock — the tempo cannot be changed from here."
        }
        return canEditRun
            ? "Master clock: tempo in BPM (30–240) and Run/Stop."
            : "A patch file has no master clock — open a performance or connect the G2."
    }

    // MARK: - Zmiany

    /// Zmiana idzie do OBU miejsc, które mogą ją przechować: do urządzenia (żeby było
    /// słychać) i do modelu performance'u (żeby Save zapisał to, co widać na pasku).
    private func setBPM(_ value: Int) {
        guard canEditTempo else { return }
        let clamped = G2UsbProtocol.clampedBPM(value)
        if state.hasPerformanceSettings { state.performance.masterClock = clamped }
        guard device.status == .connected else { return }
        Task { await device.setMasterClock(clamped) }
    }

    private func toggleRun() {
        Self.toggleRun(state: state, device: device)
    }

    /// Start/stop zegara. Statyczna, bo to samo robi klawisz `R` z tabeli skrótów
    /// („Toggle Master Clock", instrukcja str. 132) — a ten nie ma pod ręką widoku.
    static func toggleRun(state: PatchState, device: DeviceConnection) {
        let running = device.status == .connected
            ? device.clockRunning
            : state.performance.masterClockRunning
        let next = !running
        if state.hasPerformanceSettings { state.performance.masterClockRunning = next }
        guard device.status == .connected else { return }
        Task { await device.setClockRunning(next) }
    }
}
