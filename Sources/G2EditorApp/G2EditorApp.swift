import AppKit
import CoreText
import G2Core
import G2EditorCore
import SwiftUI

extension Bundle {
    /// Zasoby aplikacji (fonty, logo, ikona) — w `.app` z `Contents/Resources`, patrz
    /// `Bundle.appResourceBundle` w G2Core.
    static let app = appResourceBundle("G2Editor_G2EditorApp") ?? .module
}

/// Fonty dołączone do aplikacji. Rejestruje je zarówno normalny start, jak i tryb
/// wiersza poleceń (`--snapshot-modules`) — bez nich wyświetlacze modułów
/// renderowałyby się innym krojem, co dałoby fałszywą regresję wizualną.
enum AppFonts {
    static func register() {
        let fontNames = ["MatrixSansScreen-Regular"]
        for name in fontNames {
            guard let url = Bundle.app.url(forResource: name, withExtension: "ttf") else {
                print("⚠️ Font nie znaleziony: \(name).ttf")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        takeOverOpenDocuments()
        AppFonts.register()
        FilePanels.installEditShortcuts()
        SettingsWindow.applyAppearance(UserDefaults.standard.string(forKey: AppAppearance.storageKey) ?? "")
        // Uruchomiony przez wtyczkę DAW: bez ikony w Docku i bez wychodzenia na wierzch.
        if PluginHost.isBackground {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            // Ikona w Docku także przy uruchomieniu z pakietu Swift (bez .app z plikiem .icns).
            if let url = Bundle.app.url(forResource: "AppIcon", withExtension: "svg") {
                NSApp.applicationIconImage = NSImage(contentsOf: url)
            }
            NSApp.activate(ignoringOtherApps: true)
            // Przy pierwszym uruchomieniu (świeża instalacja) okienko aktualizacji
            // nie przykrywa karty powitalnej.
            if !SplashWindow.showOnFirstLaunch() { AppUpdates.shared.checkAtLaunch() }
        }
        PluginHost.start()
        // Pre-generuj podglądy modułów w tle — żeby hover popup i visual mode były natychmiastowe
        ModulePreviewCache.shared.warmUp()
        // Diagnostyka menu — patrz MenuDump.swift. Liczba po fladze to zwłoka w sekundach:
        // pozycje zależne od URZĄDZENIA (np. „Start Virtual G2") mają swój stan dopiero
        // po połączeniu, a to przy czterech slotach trwa dłużej niż domyślne 1,5 s.
        if let flag = CommandLine.arguments.firstIndex(of: "--dump-menu") {
            let delay = CommandLine.arguments.dropFirst(flag + 1).first.flatMap(TimeInterval.init)
            MenuDump.scheduleDump(after: delay ?? 1.5)
        }
    }

    /// Edytor w tle ma okno schowane, a AppKit liczy schowane jak zamknięte — bez wyjątku
    /// zamykałby się zaraz po starcie. Wychodzi sam po minucie bez wtyczek (`PluginHost`).
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !PluginHost.isBackground
    }

    /// ⌘Q z niezapisanymi zmianami → pytanie jak w każdej aplikacji dokumentowej.
    /// Edytor w tle nie pyta: użytkownik nic w nim nie robił, a patche trzymają wtyczki.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        if PluginHost.isBackground { return .terminateNow }
        return UnsavedChangesGuard.shared.confirmQuit() ? .terminateNow : .terminateCancel
    }

    /// Ponowne uruchomienie edytora, który działa w tle dla wtyczek, pokazuje jego okno.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if PluginHost.isBackground { PluginHost.showEditor() }
        return true
    }

    /// Podwójny klik w Finderze, „Open With”, plik upuszczony na ikonę w Docku. Przy STARCIE
    /// z pliku idzie tędy, a SwiftUI otwiera przy tym jedyne okno edytora (plik czeka
    /// w `FinderOpen`, aż okno się podłączy). Edytor trzyma jeden dokument, więc z kilku
    /// plików otwiera się pierwszy.
    func application(_: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        FinderOpen.shared.open(url)
    }

    /// Plik z Findera przy DZIAŁAJĄCYM edytorze: SwiftUI otwierał dla niego drugie okno
    /// edytora, z własnym stanem i własnym połączeniem z Nordem (sprawdzone 2026-10-23;
    /// `handlesExternalEvents` tego nie zatrzymał). Po starcie przejmujemy więc samo
    /// zdarzenie „otwórz dokumenty”, zanim zobaczy je SwiftUI. Wcześniej nie wolno: przy
    /// starcie z pliku nie powstałoby wtedy żadne okno i edytor by się zamknął.
    private func takeOverOpenDocuments() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openDocuments(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    @objc private func openDocuments(_ event: NSAppleEventDescriptor, withReply _: NSAppleEventDescriptor) {
        guard let files = event.paramDescriptor(forKeyword: keyDirectObject), files.numberOfItems > 0,
              let url = files.atIndex(1)?.fileURLValue ?? files.fileURLValue
        else { return }
        // Zdarzenia Apple przychodzą na głównym wątku.
        MainActor.assumeIsolated { FinderOpen.shared.open(url) }
    }
}

/// Pliki z Findera (`AppDelegate`, plik upuszczony na okno edytora) idą tą samą drogą co
/// File ▸ Open: pytanie o zapis, wczytanie, wysyłka do Norda. `.pch2` upuszczony na okno
/// też się OTWIERA (decyzja użytkownika 2026-10-23) — jako blok wstawia go lista Blocks
/// i File ▸ Insert Patch File…. Plik podany przy starcie przychodzi, zanim okno ma stan —
/// czeka wtedy w `pending`, aż `RootView` się podłączy.
@MainActor
final class FinderOpen {
    static let shared = FinderOpen()

    /// Pliki przeciągnięte z Findera; `nil`, gdy przeciąga się coś innego (moduł, blok z listy).
    nonisolated static func files(on pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    /// Plik, który edytor otwiera: `.pch2` albo `.prf2`; inny (np. `.txt`) daje `nil`.
    nonisolated static func patchFile(in urls: [URL]) -> URL? {
        urls.first { ["pch2", "prf2"].contains($0.pathExtension.lowercased()) }
    }

    private weak var state: PatchState?
    private var device: DeviceConnection?
    private var pending: URL?

    func attach(state: PatchState, device: DeviceConnection) {
        self.state = state
        self.device = device
        if let pending {
            self.pending = nil
            open(pending)
        }
    }

    func open(_ url: URL) {
        guard let state, let device else {
            pending = url
            return
        }
        if PluginHost.isBackground { PluginHost.showEditor() }
        NSApp.activate(ignoringOtherApps: true)
        guard ["pch2", "prf2"].contains(url.pathExtension.lowercased()) else {
            state.errorMessage = "Please open a .pch2 or .prf2 file.\nSelected: \(url.lastPathComponent)"
            return
        }
        guard UnsavedChangesGuard.shared.confirmDiscard(opening: url) else { return }
        let onlySlot = state.load(url: url)
        guard state.errorMessage == nil else { return }
        Task { await device.send(state, onlyFocusedSlot: onlySlot, followDocument: true) }
    }
}

/// Pytanie „zapisać zmiany?" — jedno miejsce dla ⌘Q, czerwonego przycisku okna I każdej
/// podmiany zawartości (Open, Open Recent, New, plik z przeglądarki Disk). Każdy slot ma
/// własny plik, więc pytamy o każdy podmieniany slot osobno — jak Clavia, która pyta o każde
/// okno patcha (`SaveAllPatchesWithAlert`) — a o `.prf2`, gdy znika cała performance.
/// SwiftUI nie ma tu `NSDocument`, więc pytanie zadaje `NSAlert` z układem przycisków macOS:
/// Save (domyślny) · Cancel · Don't Save (⌘D).
@MainActor
final class UnsavedChangesGuard {
    static let shared = UnsavedChangesGuard()
    weak var state: PatchState?

    private static let letters = ["A", "B", "C", "D"]

    /// Setup ▸ Options: czy pytać przy podmianie zawartości (Open, New, plik z Disk).
    /// Wyjście z edytora pyta zawsze — tam nie ma już dokąd wrócić.
    static let askOnReplaceKey = "g2_ask_save_on_replace"

    /// To samo dla przycisków „Init 1"/„Init 2" — osobno, bo szablon przywołuje się
    /// znacznie częściej niż otwiera plik (życzenie z forum, wątek 2988).
    static let askOnInitPatchKey = "g2_ask_save_on_init_patch"

    private var asksOnReplace: Bool {
        UserDefaults.standard.object(forKey: Self.askOnReplaceKey) as? Bool ?? true
    }

    private var asksOnInitPatch: Bool {
        UserDefaults.standard.object(forKey: Self.askOnInitPatchKey) as? Bool ?? true
    }

    /// ⌘Q i zamknięcie okna — pytanie niezależnie od ustawienia.
    func confirmQuit() -> Bool {
        guard let state else { return true }
        return confirmDiscard(slots: Array(state.slots.indices), performance: true)
    }

    /// Cała performance naraz: New Performance, otwarcie `.prf2`.
    /// `true` = można iść dalej (zapisane albo świadomie porzucone), `false` = anulowano.
    func confirmDiscard() -> Bool {
        guard asksOnReplace else { return true }
        return confirmQuit()
    }

    /// Podmiana jednego slotu: New Patch, New To, Open To.
    func confirmDiscard(slot: Int) -> Bool {
        guard asksOnReplace else { return true }
        return confirmDiscard(slots: [slot], performance: false)
    }

    /// Przycisk „Init 1"/„Init 2": szablon wchodzi do jednego slotu, tak jak „Open To".
    func confirmDiscard(initPatchInto slot: Int) -> Bool {
        guard asksOnInitPatch else { return true }
        return confirmDiscard(slots: [slot], performance: false)
    }

    /// Otwarcie pliku: `.pch2` podmienia slot z focusem, `.prf2` — wszystko. Opcja „jak
    /// oryginał” czyści przy `.pch2` wszystkie sloty, więc pyta jak przy `.prf2`.
    func confirmDiscard(opening url: URL) -> Bool {
        guard let state else { return true }
        return url.pathExtension.lowercased() == "prf2" || PatchOpenMode.stored == .likeOriginal
            ? confirmDiscard() : confirmDiscard(slot: state.selectedSlot)
    }

    private func confirmDiscard(slots: [Int], performance: Bool) -> Bool {
        guard let state else { return true }
        for slot in state.unsavedSlots(among: slots) {
            let name = state.slots[slot].name.isEmpty ? "No name" : state.slots[slot].name
            let subject = "\u{201C}\(name)\u{201D} in slot \(Self.letters[slot])"
            guard ask(about: subject, save: { saveSlot(slot, of: state) }) else { return false }
        }
        if performance, state.performanceHasUnsavedChanges {
            let subject = "the performance \u{201C}\(state.performanceName)\u{201D}"
            guard ask(about: subject, save: { savePerformance(of: state) }) else { return false }
        }
        return true
    }

    private func ask(about subject: String, save: () -> Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \(subject)?"
        alert.informativeText = "Your changes will be lost if you don\u{2019}t save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don\u{2019}t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    /// Zapis slotu tak jak ⌘S: do jego pliku, a bez pliku — przez okno zapisu.
    /// Nieudany zapis pokazuje swój błąd w edytorze — iść dalej wtedy nie wolno.
    private func saveSlot(_ slot: Int, of state: PatchState) -> Bool {
        guard SaveActions.save(state, slot: slot) else { return false }
        return state.errorMessage == nil && !state.slotHasUnsavedChanges(slot)
    }

    private func savePerformance(of state: PatchState) -> Bool {
        guard SaveActions.savePerformance(state) else { return false }
        return state.errorMessage == nil && !state.performanceHasUnsavedChanges
    }
}

/// File ▸ Save i Save Performance: do pliku, który już jest, a bez niego — okno zapisu,
/// jak u Clavii (`SavePatch` / `SavePerformance` otwierają wtedy okno „Save As").
@MainActor
enum SaveActions {
    /// `false` = anulowano okno zapisu.
    @discardableResult
    static func save(_ state: PatchState, slot: Int? = nil) -> Bool {
        let slot = slot ?? state.selectedSlot
        if state.canSave(slot: slot) {
            state.save(slot: slot)
            return true
        }
        return saveAs(state, slot: slot)
    }

    @discardableResult
    static func saveAs(_ state: PatchState, slot: Int? = nil) -> Bool {
        let slot = slot ?? state.selectedSlot
        guard let url = FilePanels.saveURL(name: state.suggestedFileName(slot: slot),
                                           extension: "pch2") else { return false }
        state.save(slot: slot, as: url)
        return true
    }

    @discardableResult
    static func savePerformance(_ state: PatchState) -> Bool {
        if state.canSavePerformance {
            state.savePerformance()
            return true
        }
        return savePerformanceAs(state)
    }

    @discardableResult
    static func savePerformanceAs(_ state: PatchState) -> Bool {
        guard let url = FilePanels.saveURL(name: state.suggestedPerformanceFileName,
                                           extension: "prf2") else { return false }
        state.savePerformance(as: url)
        return true
    }
}

/// Czerwony przycisk okna głównego = zamknięcie edytora, więc idzie przez to samo
/// pytanie co ⌘Q. Okno SwiftUI ma już własnego delegata i musi go zachować — ten obiekt
/// przejmuje TYLKO `windowShouldClose`, resztę wiadomości przekazuje dalej.
final class EditorWindowCloseGuard: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        // Bez zmian: okno zamyka się i aplikacja kończy sama (ostatnie okno). Ze zmianami:
        // najpierw pytanie — a odpowiedź „zamknij" kończy od razu całą aplikację.
        guard UnsavedChangesGuard.shared.state?.hasUnsavedChanges == true else { return true }
        NSApp.terminate(nil)
        return false
    }
}

/// Punkt wejścia. Zanim wystartuje interfejs, sprawdzamy tryby narzędziowe
/// (regresja wizualna modułów) — te renderują podglądy i kończą proces.
@main
enum G2EditorMain {
    static func main() {
        if let code = ModuleSnapshot.handleCommandLine(Array(CommandLine.arguments.dropFirst())) {
            exit(code)
        }
        if let code = MutatorSnapshot.handleCommandLine(Array(CommandLine.arguments.dropFirst())) {
            exit(code)
        }
        if let code = SettingsSnapshot.handleCommandLine(Array(CommandLine.arguments.dropFirst())) {
            exit(code)
        }
        // Musi paść TU, przed startem SwiftUI. Pierwsza próba siedziała
        // w `applicationDidFinishLaunching` i była już za późno: okno `WindowGroup`
        // powstaje wcześniej, więc pas zakładek zdążył się pojawić mimo flagi.
        NSWindow.allowsAutomaticWindowTabbing = false
        // AppKit dokleja do menu Edit dwie własne pozycje — „Start Dictation…"
        // i „Emoji & Symbols". Obie należą do systemu, nie do edytora, i nie da się
        // ich usunąć z poziomu `Commands`; wyłącza je para kluczy w domyślnych
        // ustawieniach, czytana w chwili budowania menu — czyli musi paść tutaj,
        // przed startem SwiftUI.
        UserDefaults.standard.register(defaults: [
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])
        G2EditorApp.main()
    }
}

/// Wyłącza pas zakładek na KONKRETNYM oknie i rejestruje je jako okno główne edytora
/// (`SlotWindows.editorWindow`). Sama flaga klasy `NSWindow` okazała się za słaba —
/// pas zakładek pojawia się, gdy w Ustawieniach systemowych „Preferuj karty przy
/// otwieraniu dokumentów" stoi na „zawsze", i wtedy trzeba go zdjąć z okna, które
/// SwiftUI już utworzył. Zakładki włącza z powrotem wyłącznie układ okien slotów
/// (`SlotWindows.sync`), i tylko dla okien slotów. Widok jest zerowej wielkości.
struct EditorWindowSetup: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        register(view)
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        register(view)
    }

    /// `window` jest jeszcze `nil`, gdy widok dopiero powstaje — stąd skok na kolejny
    /// obrót pętli zdarzeń, kiedy okno już jest.
    private func register(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window, SlotWindows.shared.editorWindow !== window else { return }
            window.tabbingMode = .disallowed
            SlotWindows.shared.editorWindow = window
            // Edytor uruchomiony przez wtyczkę: okno istnieje (trzyma stan), ale go nie widać.
            if PluginHost.isBackground { window.orderOut(nil) }
            let closeGuard = EditorWindowCloseGuard()
            closeGuard.original = window.delegate
            window.delegate = closeGuard
            Self.closeGuard = closeGuard // delegat jest `weak` — ktoś musi go trzymać
        }
    }

    private static var closeGuard: EditorWindowCloseGuard?
}

struct G2EditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .commands { MainMenuCommands() }
    }
}
