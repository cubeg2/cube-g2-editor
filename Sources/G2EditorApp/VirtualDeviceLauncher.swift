// VirtualDeviceLauncher.swift
// Uruchomienie wirtualnego G2 z menu Tools — jednym kliknięciem.
//
// Wirtualny G2 to osobny program spoza edytora; edytor go tylko uruchamia i zatrzymuje.
// Edytor szuka go pod `~/Library/Application Support/G2Editor/virtual-g2` (zwykle dowiązanie
// do właściwego programu) albo pod ścieżką ze zmiennej `G2_EMULATOR_BINARY`. Gdy nie ma ani
// jednego, pozycji w menu nie ma wcale — tak wygląda wersja publiczna
// → [[Docs/context/public-release-checklist]].
//
// **Start samoczynny** (decyzja użytkownika 2026-09-24, ustawienie „Start Virtual G2
// Automatically", domyślnie włączone). Do tego dnia wirtualny G2 celowo NIE wstawał sam —
// trzy powody i co z nimi teraz:
//
//  1. Znikało „No G2": Nord, który nie budzi się na kablu, wyglądałby jak sukces. Teraz belka
//     pisze „Virtual G2" innym kolorem, a start czeka 5 s bez Norda w gnieździe USB.
//  2. ~2 rdzenie i ciepły laptop przy każdym otwarciu pliku — emulator jest już dużo
//     lżejszy (plan chłodzenia), użytkownik przyjął koszt.
//  3. Gniazdo jest JEDNO: edytor nie startuje własnego, gdy łączy się z cudzym (połączenie
//     z urządzeniem jest wtedy już nawiązane).
//  **Nord ma pierwszeństwo:** pojawi się w gnieździe → samoczynnie uruchomiony wirtualny G2
//  gaśnie, a edytor łączy się ze sprzętem. Nieudany start samoczynny nie jest ponawiany.
//
// Proces jest dzieckiem edytora i ginie razem z nim — TAKŻE
// gdy edytor nie zdąży się pożegnać (Stop w Xcode, wymuszone zamknięcie, crash):
// program idzie przez `/bin/sh`, który co sekundę sprawdza, czy edytor żyje, i sam go
// kończy, gdy nie. Bez tego 2026-09-16 wirtualny G2 grał dalej po zamknięciu edytora.

import AppKit
import Foundation
import G2Core
import G2EditorCore
import Observation

@MainActor
@Observable
final class VirtualDeviceLauncher {
    static let shared = VirtualDeviceLauncher()

    /// Log wirtualnego G2 — obok logu USB, żeby diagnostyka leżała w jednym miejscu.
    /// Bez niego powód nieudanego startu (najczęściej: gniazdo trzyma już ktoś inny)
    /// przepadałby razem z procesem.
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/G2Editor/virtual-g2.log")

    private(set) var isRunning = false
    private var process: Process?

    /// Klucz ustawienia „Start Virtual G2 Automatically" (domyślnie włączone).
    static let autoStartKey = "g2_auto_virtual_g2"
    /// Ile procesorów DSP ma wirtualny G2: 4 = goły G2, 8 = z kartą rozszerzeń (domyślnie).
    /// Cztery to mniej więcej połowa obciążenia Maca, ale duże patche się nie zmieszczą.
    /// Program pod dowiązaniem dostaje liczbę w zmiennej `G2_DSPS` (decyzja 2026-09-25).
    static let dspCountKey = "g2_virtual_dsp_count"
    static let dspCountChoices = [4, 8]

    static var dspCount: Int {
        let stored = UserDefaults.standard.integer(forKey: dspCountKey)
        return dspCountChoices.contains(stored) ? stored : 8
    }

    /// Uruchomiony przez edytor sam — tylko taki ustępuje Nordowi.
    private var startedAutomatically = false
    /// Start samoczynny się nie udał — nie ponawiamy do końca sesji, żeby nie mnożyć alertów.
    private var automaticFailed = false
    private weak var device: DeviceConnection?
    private var watchTimer: Timer?
    /// Od kiedy nie ma ani połączenia, ani Norda w gnieździe.
    private var idleSince: Date?

    private init() {
        // Wirtualny G2 ma odejść razem z edytorem, który go uruchomił. Bez tego zostaje
        // proces trzymający gniazdo, a następny start łączy się z „urządzeniem",
        // którego użytkownik nigdzie nie widzi.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { VirtualDeviceLauncher.shared.stop() }
        }
    }

    /// Program wirtualnego G2. `G2_EMULATOR_BINARY` ma pierwszeństwo, potem stałe miejsce
    /// w Application Support — jedno dowiązanie na Maca, kod nie zna ścieżki właściwego programu.
    static var binaryURL: URL? {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["G2_EMULATOR_BINARY"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/G2Editor/virtual-g2").path
        )
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Pilnuje startu samoczynnego — co 2 s, jak pętla łączenia `DeviceConnection`.
    func watch(_ device: DeviceConnection) {
        self.device = device
        guard watchTimer == nil else { return }
        UserDefaults.standard.register(defaults: [Self.autoStartKey: true])
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in VirtualDeviceLauncher.shared.checkAutomatic() }
        }
    }

    private func checkAutomatic() {
        guard let device, Self.binaryURL != nil else { return }
        let nord = G2HardwareProbe.isNordPluggedIn()
        if isRunning, startedAutomatically, nord {
            // Sprzęt wygrywa: po zniknięciu gniazda pętla łączenia znajdzie Norda.
            stop()
            return
        }
        let enabled = UserDefaults.standard.bool(forKey: Self.autoStartKey)
        let busy = device.status == .connected || device.status == .connecting
        guard enabled, !isRunning, !automaticFailed, !busy, !nord else {
            idleSince = nil
            return
        }
        let since = idleSince ?? Date()
        idleSince = since
        guard Date().timeIntervalSince(since) >= 5 else { return }
        idleSince = nil
        start(automatically: true)
    }

    func start(automatically: Bool = false) {
        guard !isRunning else { return }
        startedAutomatically = automatically
        guard let binary = Self.binaryURL else {
            report("Virtual G2 is not available.", "The virtual G2 program was not found on this Mac.")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", Self.guardian, "virtual-g2", binary.path]
        var environment = ProcessInfo.processInfo.environment
        environment["G2_DSPS"] = String(Self.dspCount)
        task.environment = environment
        let log = openLog()
        task.standardOutput = log
        task.standardError = log
        // Leci z innego wątku niż główny, więc `assumeIsolated` by tu pękło.
        task.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor in VirtualDeviceLauncher.shared.processDidExit(status: status) }
        }
        do {
            try task.run()
        } catch {
            report("Virtual G2 could not start.", error.localizedDescription)
            return
        }
        process = task
        isRunning = true
        // Połączenia nie wymuszamy: pętla `DeviceConnection` i tak zagląda pod gniazdo
        // co 2 s, a wymuszenie ominęłoby regułę „najpierw sprzęt".
    }

    /// Opiekun między edytorem a wirtualnym G2. `$PPID` to edytor; gdy zniknie (także po
    /// SIGKILL, którego nie da się przechwycić), opiekun kończy dziecko. SIGTERM ze `stop()`
    /// przekazuje dalej. macOS nie ma „zabij dziecko razem z rodzicem" jak Linux, stąd
    /// pętla z `sleep 1` — a nie zmiana w samym programie wirtualnego G2, żeby działało
    /// dla każdego programu pod dowiązaniem.
    private static let guardian = """
    "$1" & child=$!
    finish() { kill -TERM "$child" 2>/dev/null; wait "$child"; exit $?; }
    trap finish TERM INT HUP
    while kill -0 "$child" 2>/dev/null; do
        kill -0 "$PPID" 2>/dev/null || finish
        sleep 1
    done
    wait "$child"
    """

    /// Nowa liczba procesorów działa dopiero od startu, więc chodzący wirtualny G2 wstaje
    /// od nowa. Patch wraca sam: po połączeniu z wirtualnym G2 edytor wgrywa swój dokument (#121).
    func setDSPCount(_ count: Int) {
        guard Self.dspCountChoices.contains(count), count != Self.dspCount else { return }
        UserDefaults.standard.set(count, forKey: Self.dspCountKey)
        guard isRunning else { return }
        let automatically = startedAutomatically
        stop()
        start(automatically: automatically)
    }

    func stop() {
        guard let task = process else { return }
        // Najpierw stan, potem sygnał: `terminationHandler` ma wtedy po czym poznać,
        // że to my go zamknęliśmy, i nie pokazuje alertu o „zatrzymaniu".
        isRunning = false
        process = nil
        task.terminate()
        task.waitUntilExit()
    }

    private func processDidExit(status: Int32) {
        guard isRunning else { return } // zamknięty przez `stop()` — nic się nie stało
        isRunning = false
        process = nil
        guard status != 0 else { return }
        if startedAutomatically { automaticFailed = true }
        // Wyjaśnienie po angielsku (interfejs jest angielski), a pod nim surowa linia
        // z logu wirtualnego G2 — jako cytat z innego programu, nie jako nasz tekst.
        // Najczęstsza przyczyna: gniazdo trzyma już ktoś inny.
        report("Virtual G2 stopped.", """
        It could not start, or it quit on its own. The usual cause is that something else \
        already holds the socket — another virtual G2, or another program using it.

        \(lastLogLine() ?? "Exit code \(status).")

        Full log: \(Self.logURL.path)
        """)
    }

    private func openLog() -> FileHandle {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: Self.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        manager.createFile(atPath: Self.logURL.path, contents: nil)
        return (try? FileHandle(forWritingTo: Self.logURL)) ?? FileHandle.nullDevice
    }

    private func lastLogLine() -> String? {
        guard let text = try? String(contentsOf: Self.logURL, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func report(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
