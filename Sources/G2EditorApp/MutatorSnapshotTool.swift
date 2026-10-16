// MutatorSnapshotTool.swift
// Zdjęcie okna Patch Mutator do pliku PNG — „przed / po" przy zmianach wyglądu okna.
//
// Użycie:
//   swift run G2EditorApp --snapshot-mutator <plik.png>              # panel zwinięty
//   swift run G2EditorApp --snapshot-mutator <plik.png> --expanded   # panel wysunięty
//   … --expanded --tab Session --patch <plik.pch2> --breed 3          # zakładka i hodowla
//   … --dark                                                          # tryb nocny
//
// Rysuje pusty mutator (nowy patch, domyślne ustawienia) w rozmiarze bazowym okna,
// w skali 2×. Dwa zdjęcia porównuje się bajt po bajcie (`cmp`) — render jest deterministyczny.
// `--patch` wczytuje patch, `--breed N` robi N pokoleń Mutate (każde z dziecka 3), żeby
// obejrzeć sekcje, które bez dźwięków są puste (drzewo ewolucji); ten render jest losowy.

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

enum MutatorSnapshot {
    /// Zwraca kod wyjścia, gdy rozpoznał swój tryb; `nil` = zwykły start aplikacji.
    static func handleCommandLine(_ args: [String]) -> Int32? {
        guard let flag = args.firstIndex(of: "--snapshot-mutator") else { return nil }
        guard args.indices.contains(flag + 1) else {
            print("❌ Podaj plik: --snapshot-mutator <plik.png>")
            return 2
        }
        let url = URL(fileURLWithPath: (args[flag + 1] as NSString).expandingTildeInPath)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if args.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
        AppFonts.register()
        app.finishLaunching()

        return MainActor.assumeIsolated {
            // Własny, chwilowy magazyn ustawień — zdjęcie nie może zależeć od tego,
            // jak użytkownik zostawił panel w aplikacji.
            let suite = "g2.mutator-snapshot"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let panels = PanelController(defaults: UserDefaults(suiteName: suite) ?? .standard)
            panels.mutatorSettingsOpen = args.contains("--expanded")
            if let tab = args.firstIndex(of: "--tab"), args.indices.contains(tab + 1) {
                UserDefaults(suiteName: suite)?.set(args[tab + 1], forKey: "g2_mutator_settings_tab")
            }
            let state = PatchState()
            if let flag = args.firstIndex(of: "--patch"), args.indices.contains(flag + 1),
               let data = try? Data(contentsOf: URL(fileURLWithPath: (args[flag + 1] as NSString).expandingTildeInPath)),
               let patch = try? PatchParser.parse(data: data).first
            {
                state.slots = [patch]
            }
            if let flag = args.firstIndex(of: "--breed"), args.indices.contains(flag + 1),
               let generations = Int(args[flag + 1])
            {
                for generation in 0 ..< generations {
                    state.mutatorMutate(from: generation == 0 ? nil : .child(2))
                }
            }
            let size = panels.baseWindowSize(of: .mutator) ?? .zero
            let view = MutatorPanel(state: state, panels: panels)
                .environment(\.mutatorSnapshot, true)
                .environment(\.colorScheme, args.contains("--dark") ? .dark : .light)
                .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  (try? png.write(to: url, options: .atomic)) != nil
            else {
                print("❌ Nie mogę zapisać \(url.path)")
                return 2
            }
            print("✅ Mutator zapisany: \(url.path)")
            return 0
        }
    }
}

/// Render do pliku nie umie przewijać: `ImageRenderer` zostawia `ScrollView` pusty. Widoki,
/// które przewijają (drzewo ewolucji), rysują się w zdjęciu bez przewijania.
private struct MutatorSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var mutatorSnapshot: Bool {
        get { self[MutatorSnapshotKey.self] }
        set { self[MutatorSnapshotKey.self] = newValue }
    }
}
