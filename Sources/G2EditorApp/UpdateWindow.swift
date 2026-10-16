import AppKit
import G2EditorCore
import SwiftUI

// Sprawdzanie aktualizacji po stronie aplikacji (logika: `UpdateCheck` w G2EditorCore).
// Przy starcie po cichu, najwyżej raz na dobę; ręcznie z menu aplikacji („Check for
// Updates…”) albo z Settings ▸ Updates. Automatycznej instalacji nie ma — bez podpisu
// Apple sprawiałaby więcej kłopotów niż pożytku (Docs/Plan projektu/06 C.8).

@MainActor
@Observable
final class AppUpdates {
    static let shared = AppUpdates()
    static let autoKey = "g2_update_check_automatically"
    static let lastCheckedKey = "g2_update_last_checked"
    private static let skippedKey = "g2_update_skipped_version"

    private(set) var isChecking = false

    /// Numer z `Info.plist` — nadaje go skrypt budujący `.app`. Przy `swift run`
    /// go nie ma: wtedy przy starcie nic nie sprawdzamy (każda wersja byłaby „nowsza”).
    static var versionText: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var versionLabel: String { versionText ?? "Development build" }

    private var current: AppVersion { Self.versionText.flatMap(AppVersion.init) ?? AppVersion("0")! }

    func checkAtLaunch() {
        let defaults = UserDefaults.standard
        guard Self.versionText != nil, defaults.object(forKey: Self.autoKey) as? Bool ?? true else { return }
        let last = defaults.double(forKey: Self.lastCheckedKey)
        guard UpdateCheck.isDue(lastChecked: last > 0 ? Date(timeIntervalSince1970: last) : nil) else { return }
        Task {
            // Chwila oddechu, żeby okienko nie wskakiwało w otwieranie okien edytora.
            try? await Task.sleep(for: .seconds(3))
            let result = await UpdateCheck.fetchNewest()
            guard result != .failed else { return } // brak sieci = cisza, spróbujemy przy następnym starcie
            markChecked()
            let skipped = defaults.string(forKey: Self.skippedKey).flatMap(AppVersion.init)
            if case let .found(release) = result,
               let offer = UpdateCheck.offer(release, current: current, skipped: skipped)
            {
                UpdateWindow.show(.available(offer, current: Self.versionLabel))
            }
        }
    }

    /// Ręcznie zawsze pokazuje wynik — także „masz najnowszą” i „nie udało się”.
    /// Pominiętą wersję też pokazuje: użytkownik sam o nią pyta.
    func checkNow() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let result = await UpdateCheck.fetchNewest()
            isChecking = false
            switch result {
            case let .found(release) where release.version > current:
                markChecked()
                UpdateWindow.show(.available(release, current: Self.versionLabel))
            case .found, .noReleases:
                markChecked()
                UpdateWindow.show(.upToDate(Self.versionLabel))
            case .failed:
                UpdateWindow.show(.failed)
            }
        }
    }

    func skip(_ release: AppRelease) {
        UserDefaults.standard.set(release.version.description, forKey: Self.skippedKey)
    }

    private func markChecked() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckedKey)
    }
}

@MainActor
enum UpdateWindow {
    enum Content {
        case available(AppRelease, current: String)
        /// Po Download: strona wydania otwarta w przeglądarce, tu instrukcja instalacji.
        case installing(AppRelease)
        case upToDate(String)
        case failed
    }

    private static var window: NSWindow?

    static func show(_ content: Content) {
        let view = UpdateView(content: content)
        if let window, let host = window.contentViewController as? NSHostingController<UpdateView> {
            host.rootView = view
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: view)
        let window = NSPanel(contentViewController: host)
        window.title = "Software Update"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }
}

/// Jeden stały rozmiar dla wszystkich stanów; przyciski z górnej belki (`TopBarButton`).
struct UpdateView: View {
    let content: UpdateWindow.Content

    private static let width: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch content {
            case let .available(release, current):
                available(release, current: current)
            case let .installing(release):
                installing(release)
            case let .upToDate(version):
                message("You're up to date",
                        "Cube G2 Editor \(version) is the newest version available.")
            case .failed:
                message("Couldn't check for updates",
                        "The update server could not be reached. Check your internet connection and try again later.")
            }
        }
        .padding(20)
        .frame(width: Self.width, height: hasNotes ? 380 : nil, alignment: .topLeading)
    }

    /// Wydanie (lista zmian, instrukcja) ma stałą wysokość; krótki komunikat — własną.
    private var hasNotes: Bool {
        switch content {
        case .available, .installing: true
        case .upToDate, .failed: false
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func available(_ release: AppRelease, current: String) -> some View {
        header("Cube G2 Editor \(release.version) is available", "You have \(current).")
        Text("What's New").font(.subheadline.bold())
        ScrollView {
            Text(Self.notes(release.notes))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        HStack(spacing: 8) {
            TopBarButton(content: .text("Skip This Version")) {
                AppUpdates.shared.skip(release)
                UpdateWindow.close()
            }
            Spacer()
            TopBarButton(content: .text("Later")) { UpdateWindow.close() }
            TopBarButton(content: .text("Download"), isOn: true, tint: .green) {
                NSWorkspace.shared.open(release.pageURL)
                UpdateWindow.show(.installing(release))
            }
        }
    }

    @ViewBuilder
    private func installing(_ release: AppRelease) -> some View {
        header("Installing Cube G2 Editor \(release.version)",
               "The download page opened in your browser. Download the .dmg file, then:")
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Open the downloaded .dmg file.")
            step(2, "Drag Cube G2 Editor to the Applications folder and choose Replace.")
            step(3, "Quit this editor and open Cube G2 Editor from Applications.")
        }
        Text("Your settings and patches stay as they are.")
            .foregroundStyle(.secondary)
        // Bez podpisu Apple ta przeszkoda wraca przy KAŻDEJ wersji (C.8).
        Text("If macOS says it can't check the app for malware: open System Settings ▸ Privacy & Security, "
            + "scroll down and click Open Anyway. This is needed once for every new version.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
        Spacer(minLength: 0)
        HStack(spacing: 8) {
            TopBarButton(content: .text("Open Privacy & Security")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer()
            TopBarButton(content: .text("Done"), isOn: true) { UpdateWindow.close() }
        }
    }

    @ViewBuilder
    private func message(_ title: String, _ text: String) -> some View {
        header(title, text)
        HStack {
            Spacer()
            TopBarButton(content: .text("OK"), isOn: true) { UpdateWindow.close() }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Opis wydania z GitHuba to Markdown. Pogrubienia i linki zostają; nagłówki „##”
    /// stają się pogrubionym wierszem (pełnego Markdownu `Text` nie rysuje).
    static func notes(_ markdown: String) -> AttributedString {
        let text = markdown.isEmpty ? "No release notes." : markdown
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        let cleaned = lines.map { line -> String in
            let heading = line.drop { $0 == "#" }
            guard heading.count < line.count else { return String(line) }
            return "**\(heading.trimmingCharacters(in: .whitespaces))**"
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(cleaned)
    }
}
