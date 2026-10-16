// PluginHost.swift
// Edytor jako zaplecze wtyczek DAW (plan: Docs/Plan projektu/05-wtyczka-daw.md §2 pkt 6).
//
// Wtyczka uruchamia edytor sama, z `--background`: bez okna i bez ikony w Docku. Okno
// pokazuje się dopiero na prośbę („Open in Editor" we wtyczce albo ponowne uruchomienie
// edytora). Edytor w tle, którego żadna wtyczka nie potrzebuje przez minutę, zamyka się sam.

import AppKit
import Foundation
import G2EditorCore

@MainActor
enum PluginHost {
    static let bridge = PluginBridge()

    /// Uruchomiony przez wtyczkę i jeszcze niepokazany użytkownikowi.
    private(set) static var isBackground = CommandLine.arguments.contains("--background")

    /// Ile edytor w tle czeka bez żadnej wtyczki, zanim się zamknie.
    private static let idleLimit: TimeInterval = 60
    private static var idleSince: Date?
    private static var idleTimer: Timer?

    /// Wołane raz, na starcie aplikacji.
    static func start() {
        let path = PluginBridge.defaultSocketPath
        if PluginBridgeServer.isListening(at: path) {
            // Wtyczki już mają swój edytor. Drugi w tle byłby tylko kłótnią o USB.
            if isBackground { exit(0) }
            // Uruchomiony ręcznie przejmuje wtyczki od edytora w tle. Od edytora z otwartym
            // oknem nie przejmuje — tamten zostaje ich edytorem, jak było.
            guard askBackgroundEditorToQuit(path) else {
                NSLog("PluginHost: another editor serves DAW plugins — this one does not")
                return
            }
        }
        writeLaunchHint()
        bridge.onShowEditor = { showEditor() }
        bridge.onQuitRequest = {
            guard isBackground else { return false }
            // Chwila na wysłanie odpowiedzi, zanim proces zniknie.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return true
        }
        do {
            try bridge.start()
        } catch {
            NSLog("PluginHost: cannot listen — \(error)")
            return
        }
        PluginQuestionPanel.watch(bridge)
        // Okno schowane albo przykryte DAW-em to dla macOS program do uśpienia (App Nap:
        // liczniki czasu spóźniają się o minuty) i do zamknięcia bez pytania (Automatic
        // Termination). Edytor, który słucha wtyczek, nie może ani spać, ani zniknąć.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Serving DAW plugins"
        )
        // Całkiem, nie `disableAutomaticTermination`: SwiftUI sam przełącza ten licznik przy
        // oknach i po chwili system znów widział edytor jako „do zamknięcia”.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        if isBackground { startIdleWatch() }
    }

    private static var activity: NSObjectProtocol?

    /// Okno edytora uruchomionego w tle wychodzi na wierzch i od teraz to zwykły edytor.
    static func showEditor() {
        isBackground = false
        idleTimer?.invalidate()
        idleTimer = nil
        NSApp.setActivationPolicy(.regular)
        SlotWindows.shared.editorWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Wtyczka musi mieć co uruchomić. Edytor nie jest jeszcze instalowaną aplikacją (Etap 7),
    /// więc przy każdym starcie zostawia starter `G2 Editor.app`: skrypt, który odpala ten
    /// program z `--background`.
    ///
    /// Musi to być aplikacja otwierana przez system, nie proces uruchomiony przez wtyczkę:
    /// Logic trzyma AU w piaskownicy, a dziecko procesu z piaskownicy dziedziczy ją — edytor
    /// nie mógł wczytać libusb i padał (2026-09-24). Aplikację otwiera `launchd`, bez piaskownicy.
    private static func writeLaunchHint() {
        guard let executable = Bundle.main.executablePath else { return }
        let app = URL(fileURLWithPath: path(named: "G2 Editor.app"))
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try? FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "io.github.cubeg2.editor.launcher",
            "CFBundleName": "G2 Editor",
            "CFBundleExecutable": "G2 Editor",
            "CFBundlePackageType": "APPL",
            // Bez ikony w Docku już od startu — edytor w tle sam pokazuje ją dopiero z oknem.
            "LSUIElement": true,
            // Spectrum i X-Y mogą słuchać wejść interfejsu audio — bez tego opisu macOS
            // nie zapyta o zgodę na mikrofon, tylko po cichu poda ciszę.
            "NSMicrophoneUsageDescription": "Spectrum and X-Y Plot can show the sound coming into "
                + "your audio interface, for example from a Nord G2.",
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        }
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let script = macOS.appendingPathComponent("G2 Editor")
        try? Data("#!/bin/sh\nexec \(quoted) \"$@\"\n".utf8).write(to: script, options: .atomic)
        chmod(script.path, 0o755)
    }

    private static func path(named name: String) -> String {
        URL(fileURLWithPath: PluginBridge.defaultSocketPath).deletingLastPathComponent()
            .appendingPathComponent(name).path
    }

    private static func startIdleWatch() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in checkIdle() }
        }
    }

    private static func checkIdle() {
        guard isBackground, bridge.clients.isEmpty else {
            idleSince = nil
            return
        }
        let since = idleSince ?? Date()
        idleSince = since
        if Date().timeIntervalSince(since) >= idleLimit {
            NSLog("PluginHost: no plugin for \(Int(idleLimit)) s — quitting the background editor")
            NSApp.terminate(nil)
        }
    }

    /// Prosi edytor słuchający na gnieździe o ustąpienie. `true` = zamknął się (był w tle).
    private static func askBackgroundEditorToQuit(_ path: String) -> Bool {
        guard let fd = PluginBridgeServer.connectSocket(path) else { return true }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = #"{"type":"hello","protocol":1,"client":"G2 Editor"}"# + "\n"
            + #"{"type":"quit_if_background"}"# + "\n"
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.filter({ $0 == 0x0A }).count < 2 {
            let got = read(fd, &buffer, buffer.count)
            if got <= 0 { break }
            received.append(contentsOf: buffer[0 ..< got])
        }
        guard String(decoding: received, as: UTF8.self).contains(#""type":"quitting""#) else { return false }
        for _ in 0 ..< 50 where PluginBridgeServer.isListening(at: path) {
            usleep(100_000)
        }
        return true
    }
}
