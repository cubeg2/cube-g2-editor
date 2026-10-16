// SettingsWindow.swift
// Jedno okno ustawień z zakładkami, jak w Logic Pro (decyzja użytkownika 2026-10-15).
// Zastępuje cztery arkusze: Options, Patch Settings, Performance Settings i Synth Settings.
//
// Okno jednego stałego rozmiaru, szerokie i niskie; stoi nad patchem jak panele.
// Zakładki w czterech grupach, rozdzielonych tą samą kreską co sekcje górnej belki:
// edytor na tym Macu (General, Display, Connection, Shortcuts) | sam Nord (Synth) |
// otwarty plik (Patch, Performance) | program (Updates, Feedback). Okno nie blokuje edytora — można grać i zmieniać.
//
// Czemu AppKit, a nie scena `Settings` SwiftUI: zakładki pokazują ten sam `PatchState`
// i `DeviceConnection`, co okno edytora (patrz `PanelWindows`). Pasek zakładek jest
// własny, bo systemowy nie przyjmuje kresek między grupami.
//
// Użycie (zdjęcia zakładek do porównania przed/po):
//   swift run G2EditorApp --snapshot-settings <katalog> [--dark] [--file <plik.pch2|.prf2>]

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, display, connection, shortcuts, synth, patch, performance, updates, feedback

    var title: String {
        switch self {
        case .general: "General"
        case .display: "Display"
        case .connection: "Connection"
        case .shortcuts: "Shortcuts"
        case .updates: "Updates"
        case .feedback: "Feedback"
        case .synth: "Synth"
        case .patch: "Patch"
        case .performance: "Performance"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .display: "paintpalette"
        case .connection: "cable.connector"
        case .shortcuts: "command"
        case .updates: "arrow.triangle.2.circlepath"
        case .feedback: "ladybug"
        case .synth: "pianokeys"
        case .patch: "doc.text"
        case .performance: "square.stack.3d.up"
        }
    }

    /// Edytor | Nord | otwarty plik | o samym programie (prośba użytkownika 2026-10-16).
    static let groups: [[SettingsTab]] = [[.general, .display, .connection, .shortcuts],
                                          [.synth],
                                          [.patch, .performance],
                                          [.updates, .feedback]]
}

@MainActor
@Observable
final class SettingsSelection {
    private static let key = "g2_settings_tab"

    var tab: SettingsTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.key) }
    }

    init() {
        tab = UserDefaults.standard.string(forKey: Self.key).flatMap(SettingsTab.init) ?? .general
    }
}

@MainActor
enum SettingsWindow {
    /// Okno ma JEDEN stały rozmiar dla wszystkich zakładek (prośba użytkownika
    /// 2026-10-15): zmiana wysokości przy każdym przejściu wyglądała słabo, a pasek
    /// zakładek podskakiwał. Szerokie i niskie — treść idzie w karty obok siebie.
    nonisolated static let contentWidth: CGFloat = 1000
    /// Wysokość części pod paskiem zakładek. `--snapshot-settings` kończy się błędem,
    /// gdy któraś zakładka potrzebuje więcej.
    nonisolated static let pageHeight: CGFloat = 420

    /// Okno się zamyka — zakładki Synth i Performance wysyłają wtedy do Norda to,
    /// co trzymały do wyjścia (jak `TrySendData` przy zamknięciu dialogu oryginału).
    static let willClose = Notification.Name("g2.settingsWindowWillClose")

    private static var window: NSWindow?
    private static var delegate: Delegate?
    private static var activationObservers: [NSObjectProtocol] = []
    private static let selection = SettingsSelection()

    /// `tab == nil` (⌘,) otwiera zakładkę, na której okno zostało zamknięte.
    static func show(_ tab: SettingsTab?, state: PatchState, device: DeviceConnection) {
        if let tab { selection.tab = tab }
        if window == nil { makeWindow(state: state, device: device) }
        window?.title = selection.tab.title
        window?.makeKeyAndOrderFront(nil)
    }

    /// Rozmiar treści okna — do sprawdzenia w `--snapshot-settings`, że okno nie
    /// otwiera się jako kreska (#138) i nie zmienia rozmiaru między zakładkami.
    static var contentSize: CGSize? {
        window.map { $0.contentRect(forFrameRect: $0.frame).size }
    }

    static func applyAppearance(_ raw: String) {
        switch AppAppearance(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private static func makeWindow(state: PatchState, device: DeviceConnection) {
        let root = SettingsRoot(selection: selection, state: state, device: device,
                                onTab: { Self.window?.title = $0.title })
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        // `FloatingPanel` jak panele edytora: okno stoi NAD patchem — zwykłe okno chowało
        // się pod głównym przy każdym kliknięciu w kanwę (zgłoszenie 2026-10-15).
        let window = FloatingPanel(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false // pola tekstowe potrzebują klawiatury
        window.hidesOnDeactivate = false
        window.level = NSApp.isActive ? .floating : .normal
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.isReleasedWhenClosed = false
        let delegate = Delegate()
        window.delegate = delegate
        self.window = window
        self.delegate = delegate
        // Stały rozmiar — liczony raz z `sizeThatFits` (nie z `fittingSize`, który przy
        // wyłączonym `sizingOptions` oddawał prawie zero, #138).
        window.setContentSize(controller.sizeThatFits(in: CGSize(width: contentWidth, height: 10000)))
        // Zapamiętujemy tylko MIEJSCE okna.
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        window.setContentSize(controller.sizeThatFits(in: CGSize(width: contentWidth, height: 10000)))
        startWatchingActivation()
    }

    private static let autosaveName = "g2_settings_window_position"

    /// Nad patchem tylko wtedy, gdy edytor jest aktywny — przy innym programie okno
    /// wraca na zwykły poziom (ta sama zasada co w `PanelWindows`).
    private static func startWatchingActivation() {
        guard activationObservers.isEmpty else { return }
        let centre = NotificationCenter.default
        for (name, level) in [(NSApplication.didBecomeActiveNotification, NSWindow.Level.floating),
                              (NSApplication.didResignActiveNotification, .normal)]
        {
            activationObservers.append(centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { window?.level = level }
            })
        }
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_: Notification) {
            NotificationCenter.default.post(name: SettingsWindow.willClose, object: nil)
        }
    }
}

/// Pasek zakładek + treść wybranej zakładki w polu stałej wysokości.
struct SettingsRoot: View {
    let selection: SettingsSelection
    let state: PatchState
    let device: DeviceConnection
    let onTab: (SettingsTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: selection)
            Divider()
            Self.page(selection.tab, state: state, device: device)
                .frame(width: SettingsWindow.contentWidth, height: SettingsWindow.pageHeight,
                       alignment: .top)
        }
        .fixedSize()
        .onChange(of: selection.tab) { onTab(selection.tab) }
    }

    @ViewBuilder
    static func page(_ tab: SettingsTab, state: PatchState, device: DeviceConnection) -> some View {
        switch tab {
        case .general: GeneralSettingsTab()
        case .display: DisplaySettingsTab()
        case .connection: ConnectionSettingsTab(device: device)
        case .shortcuts: ShortcutsSettingsTab()
        case .updates: UpdatesSettingsTab()
        case .feedback: FeedbackSettingsTab(device: device)
        case .synth: SynthSettingsTab(device: device)
        case .patch: PatchSettingsTab(state: state)
        case .performance: PerformanceSettingsTab(state: state, device: device)
        }
    }
}

/// Ikony z podpisem jak w pasku preferencji macOS; między grupami kreska górnej belki.
private struct SettingsTabBar: View {
    let selection: SettingsSelection

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.groups.indices, id: \.self) { index in
                if index > 0 {
                    // Kreska ma 1,5 pt, więc z równymi marginesami (8 + 1,5 + 8) każda
                    // grupa przesuwała resztę o pół punktu, a pasek wyśrodkowany w oknie
                    // stał na ćwiartkach punktu. Kreski wypadały między pikselami
                    // i wyglądały na cieńsze niż w belce (zgłoszenie 2026-10-16).
                    // Łącznie 18 pt: wszystkie kreski stoją na pełnych punktach.
                    topBarFlowDivider()
                        .padding(.leading, 8)
                        .padding(.trailing, 8.5)
                }
                ForEach(SettingsTab.groups[index], id: \.self) { tab in
                    button(tab)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: SettingsWindow.contentWidth)
    }

    private func button(_ tab: SettingsTab) -> some View {
        let isSelected = selection.tab == tab
        return Button {
            selection.tab = tab
        } label: {
            // Ramka i kolory przycisków górnej belki (`TopBarButton`): wybrana zakładka
            // świeci akcentem jak Voice/FX, pozostałe mają szarą ramkę.
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(tab.title)
                    .font(.system(size: TopBarMetrics.labelSize, weight: .medium))
            }
            .frame(minWidth: 74)
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Zdjęcia zakładek

enum SettingsSnapshot {
    /// Zwraca kod wyjścia, gdy rozpoznał swój tryb; `nil` = zwykły start aplikacji.
    static func handleCommandLine(_ args: [String]) -> Int32? {
        guard let flag = args.firstIndex(of: "--snapshot-settings") else { return nil }
        guard args.indices.contains(flag + 1) else {
            print("❌ Podaj katalog: --snapshot-settings <katalog>")
            return 2
        }
        let directory = URL(fileURLWithPath: (args[flag + 1] as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let dark = args.contains("--dark")
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        AppFonts.register()
        app.finishLaunching()

        return MainActor.assumeIsolated {
            let state = PatchState()
            // Plik .pch2 albo .prf2 — tą samą drogą co File ▸ Open, więc performance
            // zapala zakładkę Performance.
            if let index = args.firstIndex(of: "--file"), args.indices.contains(index + 1) {
                _ = state.load(url: URL(fileURLWithPath: (args[index + 1] as NSString).expandingTildeInPath))
            }
            let device = DeviceConnection()
            // Bez Norda zakładka Synth pokazałaby sam napis — do zdjęcia przykładowe ustawienia.
            SynthSettingsTab.snapshotSettings = G2SynthSettings()
            let selection = SettingsSelection()
            let previous = selection.tab
            defer { selection.tab = previous }
            var tooTall: [String] = []
            for tab in SettingsTab.allCases {
                selection.tab = tab
                let view = SettingsRoot(selection: selection, state: state, device: device,
                                        onTab: { _ in })
                // Tło okna dokładamy sami — bez niego zdjęcie jest przezroczyste.
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                let size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = app.appearance
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = directory.appendingPathComponent("\(tab.rawValue)\(dark ? "-dark" : "").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                // Ile zakładka potrzebuje naprawdę — okno ma stałą wysokość, więc nic nie
                // może z niej wystawać.
                let need = NSHostingView(rootView: SettingsRoot.page(tab, state: state, device: device)).fittingSize.height
                let fits = need <= SettingsWindow.pageHeight
                if !fits { tooTall.append(tab.title) }
                print("\(fits ? "✅" : "❌") \(tab.title): treść \(Int(need)) z \(Int(SettingsWindow.pageHeight)) pt → \(url.lastPathComponent)")
            }
            // Prawdziwe okno, nie tylko zdjęcia: otwarte musi mieć pełny rozmiar (#138)
            // i NIE zmieniać go między zakładkami.
            SettingsWindow.show(.general, state: state, device: device)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let general = SettingsWindow.contentSize ?? .zero
            SettingsWindow.show(.patch, state: state, device: device)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let patch = SettingsWindow.contentSize ?? .zero
            print("Okno: General \(Int(general.width))×\(Int(general.height)), "
                + "Patch \(Int(patch.width))×\(Int(patch.height))")
            if !tooTall.isEmpty { print("❌ Za wysokie: \(tooTall.joined(separator: ", "))") }
            let windowOK = general.width >= SettingsWindow.contentWidth
                && general.height > SettingsWindow.pageHeight && general == patch
            return windowOK && tooTall.isEmpty ? 0 : 1
        }
    }
}
