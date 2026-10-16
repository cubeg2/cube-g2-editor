// LiveAudioSourceMenu.swift
// Wybór, czego słuchają Spectrum i X-Y: wirtualnego G2 albo dwóch wejść interfejsu audio,
// do których podpięty jest Nord. Jedno ustawienie dla obu okien (`LiveAudioSource`).
// Bez wirtualnego G2 na Macu (wersja dla testerów) zostają same wejścia (2026-10-16).
//
// Menu zamiast trzech list (urządzenie, L, R): pary wejść 1–2, 3–4… i pojedyncze wejścia
// mono mieszczą się w jednym podmenu na urządzenie, a okno X-Y ma miejsce tylko na jeden
// mały przycisk na wykresie.

import AVFoundation
import G2EditorCore
import SwiftUI

/// Lista urządzeń z wejściami, odświeżana, gdy ktoś wepnie albo odepnie interfejs.
@MainActor
@Observable
final class AudioInputDevices {
    static let shared = AudioInputDevices()

    private(set) var devices: [LiveAudioInput.Device] = []
    @ObservationIgnored private var observer: AnyObject?

    private init() {
        devices = LiveAudioInput.devices()
        observer = LiveAudioInput.observeDevices {
            Task { @MainActor in AudioInputDevices.shared.devices = LiveAudioInput.devices() }
        }
    }
}

/// Opisy źródła do przycisku i wierszy stanu.
enum LiveAudioSourceText {
    /// Nazwa urządzenia zapamiętana przy wyborze — żeby odpięty interfejs dało się nazwać.
    static let deviceNameKey = "liveAudioInputDeviceName"

    static func inputs(left: Int, right: Int) -> String {
        left == right ? "input \(left + 1)" : "inputs \(left + 1)–\(right + 1)"
    }

    static func deviceName(_ uid: String, in devices: [LiveAudioInput.Device]) -> String {
        devices.first { $0.uid == uid }?.name
            ?? UserDefaults.standard.string(forKey: deviceNameKey) ?? "Audio interface"
    }

    /// „Virtual G2" albo „Scarlett 18i20 · 1–2" — na przycisk.
    @MainActor
    static func short(_ source: LiveAudioSource, devices: [LiveAudioInput.Device]) -> String {
        switch source {
        case .virtualG2:
            return virtualG2Available ? "Virtual G2" : "Choose Input"
        case let .interface(uid, left, right):
            let channels = left == right ? "\(left + 1)" : "\(left + 1)–\(right + 1)"
            return "\(deviceName(uid, in: devices)) · \(channels)"
        }
    }

    /// „the virtual G2" albo „Scarlett 18i20, inputs 1–2" — do zdań w wierszu stanu.
    static func long(_ source: LiveAudioSource, devices: [LiveAudioInput.Device]) -> String {
        switch source {
        case .virtualG2:
            "the virtual G2"
        case let .interface(uid, left, right):
            "\(deviceName(uid, in: devices)), \(inputs(left: left, right: right))"
        }
    }

    /// Wirtualnego G2 nie ma na tym Macu (wersja dla testerów): źródło „Virtual G2” znika
    /// z menu, a zapamiętany albo domyślny wybór prosi o wskazanie wejść interfejsu.
    @MainActor
    static var virtualG2Available: Bool {
        VirtualDeviceLauncher.shared.isRunning || VirtualDeviceLauncher.binaryURL != nil
    }

    /// Nie ma czego słuchać, dopóki użytkownik nie wybierze wejść.
    @MainActor
    static func needsChoice(_ source: LiveAudioSource) -> Bool {
        source == .virtualG2 && !virtualG2Available
    }

    static let chooseInputs = "Choose the audio interface inputs the Nord is plugged into."

    /// Wybrany interfejs nie jest podpięty.
    static func isMissing(_ source: LiveAudioSource, devices: [LiveAudioInput.Device]) -> Bool {
        guard case let .interface(uid, _, _) = source else { return false }
        return !devices.contains { $0.uid == uid }
    }

    /// macOS odmówił nagrywania — system podaje wtedy ciszę bez żadnego błędu, więc to
    /// jedyne miejsce, w którym użytkownik się o tym dowie. Okna pytają przy każdej klatce,
    /// a system wystarczy pytać co dwie sekundy.
    @MainActor
    static var permissionHint: String? {
        if Date().timeIntervalSince(permissionCheckedAt) > 2 {
            permissionCheckedAt = Date()
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            permissionDenied = status == .denied || status == .restricted
        }
        return permissionDenied
            ? "macOS blocks audio input for the editor — allow it in System Settings ▸ Privacy & Security ▸ Microphone."
            : nil
    }

    @MainActor private static var permissionCheckedAt = Date.distantPast
    @MainActor private static var permissionDenied = false
}

/// Menu źródła dźwięku. Wygląd przycisku daje okno (`label` dostaje krótki opis źródła).
struct LiveAudioSourceMenu<Label: View>: View {
    @ViewBuilder var label: (String) -> Label

    @AppStorage(LiveAudioSource.kindKey) private var kind = LiveAudioSource.virtualKind
    @AppStorage(LiveAudioSource.deviceKey) private var deviceUID = ""
    @AppStorage(LiveAudioSource.leftKey) private var left = 0
    @AppStorage(LiveAudioSource.rightKey) private var right = 1
    @AppStorage(LiveAudioSourceText.deviceNameKey) private var deviceName = ""
    private var devices = AudioInputDevices.shared

    init(@ViewBuilder label: @escaping (String) -> Label) {
        self.label = label
    }

    var body: some View {
        Menu {
            if LiveAudioSourceText.virtualG2Available {
                Toggle("Virtual G2", isOn: Binding(
                    get: { kind != LiveAudioSource.interfaceKind },
                    set: { _ in kind = LiveAudioSource.virtualKind }
                ))
                Divider()
            }
            if devices.devices.isEmpty {
                Text("No audio inputs found")
            }
            ForEach(devices.devices) { device in
                Menu(device.name) { inputs(of: device) }
            }
        } label: {
            label(LiveAudioSourceText.short(source, devices: devices.devices))
        }
        .help(LiveAudioSourceText.virtualG2Available
            ? "Where Spectrum and X-Y take the sound from: the virtual G2, or two inputs "
            + "of an audio interface the Nord is plugged into"
            : "Where Spectrum and X-Y take the sound from: two inputs of an audio interface "
            + "the Nord is plugged into")
    }

    private var source: LiveAudioSource {
        guard kind == LiveAudioSource.interfaceKind, !deviceUID.isEmpty else { return .virtualG2 }
        return .interface(deviceUID: deviceUID, left: left, right: right)
    }

    /// Pary 1–2, 3–4… (stereo) i pojedyncze wejścia (mono na oba kanały).
    @ViewBuilder
    private func inputs(of device: LiveAudioInput.Device) -> some View {
        if device.channels > 1 {
            Section("Stereo") {
                ForEach(Array(stride(from: 0, to: device.channels - 1, by: 2)), id: \.self) { first in
                    choice(device, left: first, right: first + 1)
                }
            }
        }
        Section("Mono") {
            ForEach(0 ..< device.channels, id: \.self) { channel in
                choice(device, left: channel, right: channel)
            }
        }
    }

    private func choice(_ device: LiveAudioInput.Device, left newLeft: Int, right newRight: Int) -> some View {
        // Nazwa od sterownika tylko wtedy, gdy mówi coś ponad numer („Analog 1", nie „1").
        let names = Set([newLeft, newRight]).sorted()
            .map { (device.channelNames[$0], "\($0 + 1)") }
            .filter { !$0.0.isEmpty && $0.0 != $0.1 }
            .map(\.0)
        let title = LiveAudioSourceText.inputs(left: newLeft, right: newRight).capitalized
            + (names.isEmpty ? "" : "  (\(names.joined(separator: " / ")))")
        return Toggle(title, isOn: Binding(
            get: { source == .interface(deviceUID: device.uid, left: newLeft, right: newRight) },
            set: { _ in
                deviceUID = device.uid
                deviceName = device.name
                left = newLeft
                right = newRight
                kind = LiveAudioSource.interfaceKind
            }
        ))
    }
}
