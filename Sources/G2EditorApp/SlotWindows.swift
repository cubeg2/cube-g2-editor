// SlotWindows.swift
// Sloty A–D jako zakładki i okna — trzeci układ z View ▸ Slot Layout (`SlotLayout.windows`).
//
// Każdy slot performance'u dostaje własne okno edytora, przypięte na stałe do swojego
// slotu (`ContentView(pinnedSlot:)`): pas slotu, kanwa, szuflady — wszystko o JEDNYM
// patchu. Okno główne (to z `WindowGroup`) jest oknem slotu A; sloty B–D to okna
// AppKit spięte z nim w zakładki systemu (`NSWindow.addTabbedWindow`). Przeciągnięcie
// zakładki robi z niej osobne okno, zamknięcie odpiętego okna wpina je z powrotem —
// slot nie da się „zamknąć", bo slot istnieje w Nordzie niezależnie od okien.
//
// Slot edytowany dla Norda (`0x09`) idzie za OKNEM KLUCZOWYM: klik w zakładkę B albo
// w odpięte okno B przenosi focus na B (`windowDidBecomeKey` → `focusSlot`). W drugą
// stronę też: gdy focus zmieni się poza oknami (Nord przełączył slot na froncie, File ▸
// New To ▸ Slot C), na wierzch wychodzi zakładka tego slotu (`reveal`).
//
// Czemu AppKit, a nie druga scena SwiftUI — ten sam powód co w `PanelWindows`: okna
// mają pokazywać ten sam `PatchState` i `DeviceConnection`, a `NSHostingController`
// bierze te obiekty wprost → [[Docs/ui/slot-layout]].

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

@MainActor
final class SlotWindows {
    static let shared = SlotWindows()

    /// Okno główne aplikacji — rejestruje je `EditorWindowSetup` z `RootView`.
    weak var editorWindow: NSWindow? {
        didSet {
            watchEditorKey()
            pendingSync?()
        }
    }

    private var windows: [Int: NSWindow] = [:]
    private var delegates: [Int: SlotWindowDelegate] = [:]
    /// Zaznaczenia kanwy okien slotów — każde okno ma własne, menu Edit bierze to
    /// z okna kluczowego (`keyWindowContext`).
    private var selections: [Int: CanvasSelectionHub] = [:]
    private var context: PanelContext?
    private var openIntoSlot: Binding<Int?>?
    private var editorObservers: [NSObjectProtocol] = []
    private weak var state: PatchState?
    /// Ostatnie żądanie `sync` — powtarzane, gdy okno główne zarejestruje się później
    /// niż pierwsze wywołanie (okno SwiftUI istnieje dopiero po pierwszym obrocie pętli).
    private var pendingSync: (() -> Void)?
    /// Obserwacje pasów zakładek — każda zmiana (upuszczenie, odpięcie, przestawienie)
    /// kończy się `tidyTabs`.
    private var tabObservers: [NSKeyValueObservation] = []
    private var tidyScheduled = false
    /// `tidyTabs` przestawia okna, a po drodze kluczowym bywa byle które — wtedy focus
    /// slotu nie może za nim iść.
    private var isTidying = false
    /// Czeka na puszczenie przycisku po przeciągnięciu odpiętego okna (`watchDrop`).
    private var dropTimer: Timer?
    /// Strefy upuszczenia widoczne w trakcie przeciągania — po jednej na okno-cel.
    private var dropHints: [ObjectIdentifier: NSWindow] = [:]

    /// Wspólna nazwa grupy zakładek — tylko okna z tą samą wpinają się w jeden pas.
    static let tabbingIdentifier = "g2-slot-windows"

    private init() {
        // `willMove` przychodzi tylko wtedy, gdy okno ciągnie użytkownik — przesunięcia
        // z kodu (spinanie zakładek, `setFrame`) go nie wysyłają.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willMoveNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                SlotWindows.shared.watchDrop(of: window)
            }
        }
    }

    func isSlotWindow(_ window: NSWindow) -> Bool {
        windows.values.contains(window)
    }

    /// Doprowadza okna do zgodności ze stanem: w układzie okien każdy slot poza A ma
    /// swoje okno-zakładkę, w pozostałych układach (i przy zwykłym patchu) nie ma żadnego.
    func sync(layout: SlotLayout, context: PanelContext, openIntoSlot: Binding<Int?>) {
        state = context.state
        self.context = context
        self.openIntoSlot = openIntoSlot
        pendingSync = { [weak self] in self?.sync(layout: layout, context: context, openIntoSlot: openIntoSlot) }
        let wanted = layout == .windows
            ? Array(1 ..< context.state.slots.count)
            : []
        // Focus sprzed przebudowy: zamykanie i spinanie okien czyni po drodze kluczowym
        // byle które z nich, a delegat idzie za oknem kluczowym — więc najpierw
        // delegaci schodzą, a na końcu focus wraca tam, gdzie był.
        let focused = context.state.selectedSlot
        let stale = windows.keys.filter { !wanted.contains($0) }
        for slot in stale {
            windows[slot]?.delegate = nil
            delegates[slot] = nil
        }
        for slot in stale {
            close(slot)
        }
        guard let editor = editorWindow else { return }
        // Zakładki wolno spinać tylko z oknem, które na to pozwala; poza układem okien
        // pas zakładek ma zostać wyłączony (patrz `EditorWindowSetup`).
        editor.tabbingMode = wanted.isEmpty ? .disallowed : .preferred
        guard !wanted.isEmpty else {
            tabObservers.removeAll()
            // Odpięte okno A dostało pasek zakładek na stałe (`tidyTabs`) — zdejmujemy go.
            if editor.tabGroup?.isTabBarVisible == true, editor.tabbedWindows == nil {
                editor.toggleTabBar(nil)
            }
            return
        }
        editor.tabbingIdentifier = Self.tabbingIdentifier
        var anchor = windows.keys.max().flatMap { windows[$0] } ?? editor
        for slot in wanted where windows[slot] == nil {
            let window = open(slot, context: context, openIntoSlot: openIntoSlot)
            // Zakładki w kolejności slotów: każda nowa staje ZA poprzednią.
            anchor.addTabbedWindow(window, ordered: .above)
            window.delegate = delegates[slot]
            anchor = window
        }
        // Po zbudowaniu pasa na wierzch wraca zakładka slotu, który użytkownik edytował.
        context.state.focusSlot(focused)
        reveal(slot: focused)
        watchTabs()
    }

    // MARK: - Kolejność zakładek

    /// Slot okna: okno główne to A, reszta z `windows`.
    private func slot(of window: NSWindow) -> Int? {
        window === editorWindow ? 0 : windows.first { $0.value === window }?.key
    }

    /// Okna wszystkich slotów, łącznie z głównym.
    private var allWindows: [NSWindow] {
        guard !windows.isEmpty else { return [] }
        return [editorWindow].compactMap { $0 } + windows.keys.sorted().compactMap { windows[$0] }
    }

    /// Pilnuje pasów zakładek: zmiana grupy okna (odpięcie, upuszczenie w pasie) i
    /// zmiana kolejności w pasie wołają `tidyTabs`.
    private func watchTabs() {
        tabObservers.removeAll()
        let windows = allWindows
        var groups: [NSWindowTabGroup] = []
        for window in windows {
            tabObservers.append(window.observe(\.tabGroup) { _, _ in
                MainActor.assumeIsolated { SlotWindows.shared.scheduleTidy() }
            })
            if let group = window.tabGroup, !groups.contains(where: { $0 === group }) {
                groups.append(group)
            }
        }
        for group in groups {
            tabObservers.append(group.observe(\.windows) { _, _ in
                MainActor.assumeIsolated { SlotWindows.shared.scheduleTidy() }
            })
        }
    }

    private func scheduleTidy() {
        guard !isTidying, !tidyScheduled else { return }
        tidyScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.tidyScheduled = false
            self?.tidyTabs()
        }
    }

    /// Zakładki zawsze w kolejności slotów A–D, gdziekolwiek użytkownik je upuścił.
    /// Okno samo w swojej grupie (odpięte) dostaje widoczny pasek zakładek — bez niego
    /// nie byłoby czego chwycić, żeby wrzucić je z powrotem do pasa innego okna.
    private func tidyTabs() {
        let windows = allWindows
        guard !windows.isEmpty else { return }
        // W trakcie przeciągania zakładki nie ruszamy pasa — poczekamy na upuszczenie.
        guard NSEvent.pressedMouseButtons == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.scheduleTidy() }
            return
        }
        isTidying = true
        let key = NSApp.keyWindow
        var groups: [NSWindowTabGroup] = []
        for window in windows {
            if let group = window.tabGroup, !groups.contains(where: { $0 === group }) {
                groups.append(group)
            }
        }
        for group in groups {
            let wanted = group.windows.sorted { (slot(of: $0) ?? .max) < (slot(of: $1) ?? .max) }
            if group.windows != wanted {
                let selected = group.selectedWindow
                // Przestawić okno da się tylko wyjmując je i wstawiając — `insertWindow`
                // na oknie, które już jest w grupie, wywraca AppKit.
                for (index, window) in wanted.enumerated() where group.windows[index] !== window {
                    group.removeWindow(window)
                    group.insertWindow(window, at: index)
                }
                if let selected { group.selectedWindow = selected }
            }
            if group.windows.count == 1, !group.isTabBarVisible {
                group.windows[0].toggleTabBar(nil)
            }
        }
        if let key, NSApp.keyWindow !== key {
            key.makeKey()
        }
        isTidying = false
        watchTabs()
    }

    // MARK: - Upuszczenie okna na pas zakładek

    /// Odpięte okno upuszczone na górę innego okna slotu (pasek tytułu, pas zakładek
    /// i kawałek pod nim) wpina się w jego zakładki — jak po zamknięciu czerwoną
    /// kropką. Przeciąganie samej zakładki zostaje systemowi, ale okno chwytane za
    /// pasek tytułu system do pasa zakładek nie wpuszcza.
    private func watchDrop(of window: NSWindow) {
        guard dropTimer == nil, !windows.isEmpty, slot(of: window) != nil,
              (window.tabGroup?.windows.count ?? 1) <= 1
        else { return }
        // Puszczenia przycisku nie widać — okno przesuwa system — więc sprawdzamy co chwilę.
        // Póki przycisk wciśnięty, strefy upuszczenia są widoczne (`showDropHints`) —
        // ale dopiero gdy okno ruszyło, żeby zwykły klik w pasek tytułu nic nie zapalał.
        let origin = window.frame.origin
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                let shared = SlotWindows.shared
                let point = NSEvent.mouseLocation
                guard NSEvent.pressedMouseButtons & 1 == 0 else {
                    if window.frame.origin != origin {
                        shared.showDropHints(dragged: window, hovered: shared.dropTarget(for: window, at: point))
                    }
                    return
                }
                timer.invalidate()
                shared.dropTimer = nil
                shared.hideDropHints(dragged: window)
                shared.drop(window, at: point)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dropTimer = timer
    }

    /// Okna, w których zakładki może wpaść `window`. Z grupy widać tylko wybraną
    /// zakładkę — to ona jest celem.
    private func dropCandidates(for window: NSWindow) -> [NSWindow] {
        guard (window.tabGroup?.windows.count ?? 1) <= 1 else { return [] }
        return allWindows.filter { $0 !== window && $0.isVisible && !$0.isMiniaturized }
    }

    /// Okno, w którego zakładki wpadnie `window` puszczone w `point`.
    private func dropTarget(for window: NSWindow, at point: NSPoint) -> NSWindow? {
        dropCandidates(for: window).first { Self.dropZone(of: $0).contains(point) }
    }

    private func drop(_ window: NSWindow, at point: NSPoint) {
        guard let target = dropTarget(for: window, at: point) else { return }
        target.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    /// Podpowiedź w trakcie przeciągania: każdy pas zakładek, w który można upuścić
    /// okno, ma przerywaną ramkę z napisem; ten pod kursorem świeci pełnym kolorem,
    /// a ciągnięte okno robi się przezroczyste, żeby było widać, gdzie wyląduje.
    private func showDropHints(dragged: NSWindow, hovered: NSWindow?) {
        let targets = dropCandidates(for: dragged)
        let ids = Set(targets.map(ObjectIdentifier.init))
        for (id, hint) in dropHints where !ids.contains(id) {
            hint.orderOut(nil)
        }
        for target in targets {
            let id = ObjectIdentifier(target)
            let hint = dropHints[id] ?? makeDropHint()
            dropHints[id] = hint
            (hint.contentView as? NSHostingView<DropHintView>)?.rootView = DropHintView(active: target === hovered)
            hint.setFrame(Self.dropZone(of: target), display: true)
            hint.orderFront(nil)
        }
        dragged.alphaValue = hovered == nil ? 1 : 0.45
    }

    private func hideDropHints(dragged: NSWindow) {
        for hint in dropHints.values {
            hint.orderOut(nil)
        }
        dropHints.removeAll()
        dragged.alphaValue = 1
    }

    private func makeDropHint() -> NSWindow {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Nad ciągniętym oknem — ono zasłania pas zakładek, na który się celuje.
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: DropHintView(active: false))
        return panel
    }

    /// Góra okna, na którą można upuścić inne okno: pasek tytułu z pasem zakładek
    /// i zapas pod nimi, żeby nie trzeba było celować co do punktu.
    private static func dropZone(of window: NSWindow) -> NSRect {
        let frame = window.frame
        let chrome = frame.height - window.contentLayoutRect.maxY
        let height = chrome + 24
        return NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    struct KeyWindowContext {
        let context: PanelContext
        let openIntoSlot: Binding<Int?>
        let selections: CanvasSelectionHub?
    }

    /// Stan dla menu głównego, gdy kluczowe jest okno slotu B–D — patrz
    /// `MainMenuCommands.fallback`. Poza oknami slotów `nil`: tam menu ma swoje wartości.
    var keyWindowContext: KeyWindowContext? {
        guard let key = NSApp.keyWindow,
              let slot = windows.first(where: { $0.value === key })?.key,
              let context, let openIntoSlot
        else { return nil }
        return KeyWindowContext(context: context, openIntoSlot: openIntoSlot, selections: selections[slot])
    }

    func register(selections hub: CanvasSelectionHub, slot: Int) {
        selections[slot] = hub
    }

    /// Wysuwa na wierzch zakładkę (albo okno) wskazanego slotu. Slot A to okno główne.
    /// Poza układem okien nic nie robi — w jednym oknie nie ma czego wysuwać, a
    /// wyciąganie okna głównego spod pływającego panelu nikomu by nie pomogło.
    func reveal(slot: Int) {
        guard !windows.isEmpty else { return }
        let window = slot == 0 ? editorWindow : windows[slot]
        guard let window, !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
    }

    private func open(_ slot: Int, context: PanelContext, openIntoSlot: Binding<Int?>) -> NSWindow {
        let root = SlotWindowRoot(context: context, openIntoSlot: openIntoSlot, slot: slot)
        let controller = NSHostingController(rootView: root)
        // Rozmiar okna należy do grupy zakładek, nie do treści — bez tego hosting
        // przestawiałby okno przy każdym przerysowaniu pasa.
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.title = Self.title(slot: slot, state: context.state)
        if let editor = editorWindow {
            window.setFrame(editor.frame, display: false)
        }

        let delegate = SlotWindowDelegate(
            onBecameKey: { [weak self] in
                guard let self, !self.isTidying else { return }
                self.state?.focusSlot(slot)
            },
            shouldClose: { [weak self] window in
                // Odpięte okno wraca do pasa zakładek; zakładki nie da się zamknąć.
                guard let self, let editor = self.editorWindow,
                      window.tabGroup?.windows.contains(editor) != true
                else {
                    NSSound.beep()
                    return false
                }
                editor.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
                return false
            }
        )
        // Delegat wchodzi dopiero po wpięciu w zakładki (`sync`) — patrz tam.
        delegates[slot] = delegate
        windows[slot] = window
        return window
    }

    private func close(_ slot: Int) {
        guard let window = windows[slot] else { return }
        delegates[slot] = nil
        selections[slot] = nil
        windows[slot] = nil
        window.delegate = nil
        window.close()
    }

    /// Tytuł zakładki: litera slotu i nazwa patcha — to jedyne, co widać w pasie.
    static func title(slot: Int, state: PatchState) -> String {
        let letters = ["A", "B", "C", "D"]
        let letter = letters.indices.contains(slot) ? letters[slot] : "\(slot + 1)"
        let name = state.header(slot: slot).name
        return name.isEmpty ? "Slot \(letter)" : "Slot \(letter) — \(name)"
    }

    // MARK: - Okno główne

    /// Okno główne jest oknem slotu A: gdy staje się kluczowe, focus wraca na A. Gdy
    /// się zamyka, okna slotów idą z nim — zostawione same trzymałyby aplikację przy
    /// życiu i pokazywały patch, którego już nie ma.
    private func watchEditorKey() {
        for observer in editorObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        editorObservers.removeAll()
        guard let editor = editorWindow else { return }
        let centre = NotificationCenter.default
        editorObservers.append(centre.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: editor, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let shared = SlotWindows.shared
                guard !shared.windows.isEmpty, !shared.isTidying else { return }
                shared.state?.focusSlot(0)
            }
        })
        editorObservers.append(centre.addObserver(
            forName: NSWindow.willCloseNotification, object: editor, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let shared = SlotWindows.shared
                for slot in Array(shared.windows.keys) {
                    shared.close(slot)
                }
            }
        })
    }

    private final class SlotWindowDelegate: NSObject, NSWindowDelegate {
        private let onBecameKey: () -> Void
        private let shouldClose: (NSWindow) -> Bool

        init(onBecameKey: @escaping () -> Void, shouldClose: @escaping (NSWindow) -> Bool) {
            self.onBecameKey = onBecameKey
            self.shouldClose = shouldClose
        }

        func windowDidBecomeKey(_: Notification) {
            onBecameKey()
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldClose(sender)
        }
    }
}

/// Treść okna slotu: pełny edytor przypięty do jednego slotu. Własny kontroler zoomu
/// i własne zaznaczenie — jeden kontroler trzyma jeden `NSView`, a menu Edit czyta
/// zaznaczenie okna kluczowego. Stan patcha, urządzenie, szuflady i widok kanwy
/// (zoom, obszary) są wspólne z oknem głównym.
private struct SlotWindowRoot: View {
    let context: PanelContext
    let openIntoSlot: Binding<Int?>
    let slot: Int
    @State private var zoomPanController = CanvasZoomPanController()
    @State private var selections = CanvasSelectionHub()

    var body: some View {
        ContentView(
            state: context.state,
            viewState: context.viewState,
            zoomPanController: zoomPanController,
            selections: selections,
            device: context.device,
            panels: context.panels,
            library: context.library,
            typing: context.typing,
            fileOpenRequest: context.fileOpenRequest,
            pinnedSlot: slot
        )
        // Okno AppKit nie należy do sceny SwiftUI — menu główne dostaje stan tą samą
        // drogą co panele w oknach (`PanelBody`).
        .focusedValue(\.patchState, context.state)
        .focusedValue(\.canvasViewState, context.viewState)
        .focusedValue(\.canvasSelections, selections)
        .focusedValue(\.fileOpenRequest, context.fileOpenRequest)
        .focusedValue(\.openIntoSlotRequest, openIntoSlot)
        .focusedValue(\.deviceConnection, context.device)
        .focusedValue(\.panelController, context.panels)
        .background(WindowTitle(title: SlotWindows.title(slot: slot, state: context.state)))
        .onAppear { SlotWindows.shared.register(selections: selections, slot: slot) }
    }
}

/// Strefa upuszczenia okna slotu na pas zakładek (`SlotWindows.showDropHints`):
/// przerywana ramka, gdy można tam upuścić, pełne światło, gdy kursor jest nad nią.
private struct DropHintView: View {
    let active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(active ? 0.55 : 0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: active ? 4 : 2, dash: active ? [] : [8, 5])
                )
            )
            .overlay(
                Label(
                    active ? "Release to add as a tab" : "Drop here to add as a tab",
                    systemImage: "rectangle.stack.badge.plus"
                )
                .font(.system(size: active ? 15 : 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(active ? 1 : 0.8)))
            )
            .padding(2)
    }
}

/// Tytuł okna AppKit z drzewa SwiftUI. `navigationTitle` działa na oknie sceny, nie
/// na oknie z `NSHostingController` — tu tytuł zakładki ma iść za nazwą patcha.
private struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context _: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context _: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, window.title != title else { return }
            window.title = title
        }
    }
}
