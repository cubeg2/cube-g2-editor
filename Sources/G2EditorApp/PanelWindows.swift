// PanelWindows.swift
// Pływające okna paneli — druga połowa punktu 0.1. Tak otwierają się klawiatura
// i obciążenie DSP: przy patchu, w miejscu wybranym przez użytkownika, także na drugim
// monitorze — bez zabierania miejsca canvasowi.
//
// Czemu AppKit, a nie druga scena SwiftUI: panel pokazuje ten sam `PatchState`
// i `DeviceConnection`, co okno edytora. Osobna scena musiałaby dostać je przez
// środowisko sceny, czyli wyprowadzić stan z `RootView` na poziom `App` — przebudowa
// całego startu aplikacji po to, żeby otworzyć jedno okno. `NSHostingController`
// bierze te same obiekty wprost i nic poza tym plikiem nie musi o tym wiedzieć.

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

@MainActor
final class PanelWindows {
    static let shared = PanelWindows()

    private var windows: [PanelController.Panel: NSWindow] = [:]
    private var delegates: [PanelController.Panel: WindowDelegate] = [:]
    private var editorWindowObserver: NSObjectProtocol?
    private var activationObservers: [NSObjectProtocol] = []

    private init() {}

    /// Doprowadza okna do zgodności z `panels.windows`. Wołane przy każdej zmianie
    /// tego zbioru — otwiera brakujące, zamyka zbędne.
    func sync(panels: PanelController, context: PanelContext) {
        for panel in panels.windows where windows[panel] == nil {
            open(panel, panels: panels, context: context)
        }
        for (panel, window) in windows where !panels.windows.contains(panel) {
            delegates[panel] = nil // najpierw delegat, żeby zamknięcie nie wołało w kółko
            windows[panel] = nil
            window.close()
        }
        if windows.isEmpty { stopWatchingEditorWindow() }
    }

    private func open(_ panel: PanelController.Panel,
                      panels: PanelController,
                      context: PanelContext)
    {
        let fixed = panel.fixedWindowSize
        let scales = fixed != nil && panel.scalesProportionally
        let resizable = fixed == nil || scales
        let body = PanelBody(panels: panels, panel: panel, context: context,
                             showsHeader: false)
        // Rozmiar bazowy czytany w `body`, więc wysunięcie panelu mutatora przebudowuje
        // widok, a `onBaseChange` dociąga do niego samo okno.
        let root = ScalablePanel(base: { scales ? panels.baseWindowSize(of: panel) : nil },
                                 // X-Y: mniej niż `squareMinSide` przycinało opcje pod
                                 // wykresem (uwaga użytkownika 2026-09-27).
                                 minSize: CGSize(width: fixed?.width ?? panel.wrappingMinWidth
                                     ?? (panel.squareWindowFooter == nil
                                         ? PanelController.minPanelWidth : Self.squareMinSide),
                                     height: fixed?.height ?? 200),
                                 resizable: resizable,
                                 onBaseChange: { [weak self] base in
                                     if let window = self?.windows[panel] { Self.fit(window, to: base) }
                                 },
                                 content: { body })
        let controller = NSHostingController(rootView: root)
        // `NSPanel`, nie `NSWindow`: panel edytora ma stać NAD patchem, tak jak
        // pływające okna oryginału. Zwykłe okno chowa się pod głównym przy każdym
        // kliknięciu w canvas.
        let window = FloatingPanel(contentViewController: controller)
        window.title = panel.title
        window.styleMask = resizable
            ? [.titled, .closable, .resizable, .utilityWindow]
            : [.titled, .closable, .utilityWindow]
        window.isFloatingPanel = true
        // Okna, które nie mają własnych skrótów, nie przejmują focusu — inaczej klik
        // w panel odbierał głównemu oknu status kluczowego i połowa menu się wyszarzała.
        window.becomesKeyOnlyIfNeeded = !panel.needsKeyboardFocus
        // Poziom okna idzie za aktywnością aplikacji: nad patchem, gdy pracujemy
        // w edytorze, i pod Finderem czy przeglądarką, gdy przechodzimy gdzie indziej.
        window.level = NSApp.isActive ? .floating : .normal
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let base = panels.baseWindowSize(of: panel)
        let size = base ?? NSSize(width: panels.width(of: panel), height: panel.defaultWindowHeight)
        window.setContentSize(size)
        if let fixed = base {
            // Zawartość to siatka o znanych wymiarach — mniejsze okno mogłoby ją tylko
            // przyciąć, więc `fixed` jest zawsze dolną granicą. Panele skalowalne wolno
            // powiększać, ale tylko z zachowaniem proporcji (`contentAspectRatio`).
            window.contentMinSize = fixed
            if scales {
                window.contentAspectRatio = fixed
            } else {
                window.contentMaxSize = fixed
            }
        }
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("g2_panel_window_\(panel.rawValue)")
        // Zapamiętana ramka mogła powstać przy innym stanie panelu mutatora.
        if scales, let base { Self.fit(window, to: base) }
        // Sztywne okno: zapamiętana ramka mogła mieć stary rozmiar (Colors do 2026-09-27).
        if !scales, let base { Self.resize(window, to: base) }
        if let footer = panel.squareWindowFooter { Self.makeSquare(window, footer: footer) }
        // Zawijane opcje (Spectrum): wysokość, jakiej treść potrzebuje przy danej szerokości.
        let fitContent: ((CGFloat) -> NSSize)? = panel.wrappingMinWidth.map { minWidth in
            { [weak controller] width in
                let width = max(minWidth, width)
                let height = controller?.sizeThatFits(in: CGSize(width: width, height: 0)).height ?? 0
                return NSSize(width: width, height: height)
            }
        }
        // Zapamiętana ramka mogła być za mała (do 2026-09-27 nic jej nie pilnowało).
        if let fitContent {
            let content = window.contentRect(forFrameRect: window.frame)
            let needed = fitContent(content.width)
            Self.resize(window, to: NSSize(width: needed.width, height: max(content.height, needed.height)))
        }

        let delegate = WindowDelegate(squareFooter: { panel.squareWindowFooter },
                                      fitContent: fitContent, onClose: { [weak self] in
                                          self?.windows[panel] = nil
                                          self?.delegates[panel] = nil
                                          panels.closeWindow(panel)
                                          if self?.windows.isEmpty == true { self?.stopWatchingEditorWindow() }
                                      })
        window.delegate = delegate
        delegates[panel] = delegate
        windows[panel] = window
        window.makeKeyAndOrderFront(nil)
        startWatchingEditorWindow(panels: panels)
        startWatchingActivation()
    }

    /// Najwęższy kwadrat X-Y — tyle potrzebują podpisy i mierniki w pasie pod wykresem.
    static let squareMinSide: CGFloat = 240

    /// Pas pod kwadratem zmienił wysokość (X-Y: opcje rozwinięte albo zwinięte) — okno
    /// idzie za nim, kwadrat zostaje.
    func refitSquare(_ panel: PanelController.Panel) {
        guard let window = windows[panel], let footer = panel.squareWindowFooter else { return }
        Self.makeSquare(window, footer: footer)
    }

    /// Okno z kwadratowym wykresem: wysokość treści = szerokość + `footer`. Przy
    /// przeciąganiu pilnuje tego `WindowDelegate.windowWillResize` (proporcja AppKitu nie
    /// umie „plus stała"); tu wyrównujemy zapamiętaną ramkę. Lewy górny róg stoi.
    private static func makeSquare(_ window: NSWindow, footer: CGFloat) {
        let side = squareMinSide
        window.contentMinSize = NSSize(width: side, height: side + footer)
        let content = window.contentRect(forFrameRect: window.frame)
        let width = max(side, content.width)
        guard content.height != width + footer || content.width != width else { return }
        var frame = window.frameRect(forContentRect: NSRect(
            origin: content.origin, size: NSSize(width: width, height: width + footer)
        ))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true)
    }

    /// Ustawia treść okna dokładnie na `size`; lewy górny róg stoi.
    private static func resize(_ window: NSWindow, to size: CGSize) {
        let content = window.contentRect(forFrameRect: window.frame)
        guard content.size != size else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: content.origin, size: size))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true)
    }

    /// Dociąga okno skalowalnego panelu do nowego rozmiaru bazowego przy zachowaniu
    /// bieżącej skali (liczonej z wysokości, która się nie zmienia). Lewy górny róg
    /// stoi w miejscu — panel mutatora wysuwa się w prawo.
    private static func fit(_ window: NSWindow, to base: CGSize) {
        let content = window.contentRect(forFrameRect: window.frame)
        let scale = max(1, content.height / base.height)
        window.contentMinSize = base
        window.contentAspectRatio = base
        var frame = window.frameRect(forContentRect: NSRect(
            origin: content.origin,
            size: NSSize(width: base.width * scale, height: base.height * scale)
        ))
        frame.origin.y = window.frame.maxY - frame.height
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true)
    }

    // MARK: - Nad patchem, ale nie nad cudzą aplikacją

    /// `NSPanel` na poziomie `.floating` stoi nad oknami **wszystkich** aplikacji —
    /// także nad Finderem czy przeglądarką, w których użytkownik właśnie pracuje.
    /// Panel ma być nad patchem, więc poziom podnosimy tylko wtedy, gdy edytor jest
    /// aplikacją aktywną, a poza tym wraca do zwykłego.
    private func startWatchingActivation() {
        guard activationObservers.isEmpty else { return }
        let centre = NotificationCenter.default
        for (name, level) in [(NSApplication.didBecomeActiveNotification, NSWindow.Level.floating),
                              (NSApplication.didResignActiveNotification, .normal)]
        {
            activationObservers.append(centre.addObserver(forName: name, object: nil,
                                                          queue: .main)
            { _ in
                MainActor.assumeIsolated {
                    for window in PanelWindows.shared.windows.values {
                        window.level = level
                    }
                }
                })
        }
    }

    private func stopWatchingActivation() {
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activationObservers.removeAll()
    }

    // MARK: - Okno edytora zamyka panele razem z sobą

    /// Okno panelu jest okienkiem pomocniczym edytora. Zostawione samo po zamknięciu
    /// okna głównego trzymałoby aplikację przy życiu (`applicationShouldTerminate…`
    /// liczy wszystkie okna) i pokazywałoby patch, którego już nie ma.
    private func startWatchingEditorWindow(panels: PanelController) {
        // Okno slotu (układ okien) też nie jest oknem głównym — zamknięcie zakładki B
        // nie ma zamykać paneli.
        guard editorWindowObserver == nil,
              let editor = SlotWindows.shared.editorWindow ?? NSApp.windows.first(where: {
                  $0.isVisible && !isPanelWindow($0) && !SlotWindows.shared.isSlotWindow($0)
              })
        else { return }
        editorWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: editor, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (panel, window) in self.windows {
                    self.delegates[panel] = nil
                    panels.closeWindow(panel)
                    window.close()
                }
                self.windows.removeAll()
                self.stopWatchingEditorWindow()
            }
        }
    }

    private func stopWatchingEditorWindow() {
        if let editorWindowObserver {
            NotificationCenter.default.removeObserver(editorWindowObserver)
        }
        editorWindowObserver = nil
        stopWatchingActivation()
    }

    private func isPanelWindow(_ window: NSWindow) -> Bool {
        windows.values.contains(window)
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        private let onClose: () -> Void
        /// Pas pod kwadratowym wykresem — patrz `makeSquare`. `nil` = zwykłe okno.
        /// Czytany przy każdym ruchu, bo X-Y zmienia go przy rozwinięciu opcji.
        private let squareFooter: () -> CGFloat?
        /// Okno z zawijanymi opcjami — patrz `Panel.wrappingMinWidth`. Dla szerokości treści
        /// zwraca szerokość nie mniejszą od minimum i wysokość, której treść wtedy potrzebuje.
        private let fitContent: ((CGFloat) -> NSSize)?
        init(squareFooter: @escaping () -> CGFloat? = { nil }, fitContent: ((CGFloat) -> NSSize)? = nil,
             onClose: @escaping () -> Void)
        {
            self.squareFooter = squareFooter
            self.fitContent = fitContent
            self.onClose = onClose
        }

        /// Kwadrat nie może urosnąć wyżej niż ekran. Bez tego przyciągnięcie okna do
        /// górnej krawędzi (macOS: „wypełnij ekran") brało pełną szerokość, a wysokość
        /// = szerokość + pas wychodziła daleko pod dolną krawędź (uwaga 2026-09-27).
        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            let chrome = sender.frame.height - sender.contentRect(forFrameRect: sender.frame).height
            // Zwężenie okna przenosi opcje do kolejnych rzędów — okno rośnie w dół razem z nimi,
            // zamiast je przycinać.
            if let fitContent {
                let needed = fitContent(frameSize.width)
                return NSSize(width: needed.width, height: max(frameSize.height, needed.height + chrome))
            }
            guard let squareFooter = squareFooter() else { return frameSize }
            var width = frameSize.width
            if let screen = (sender.screen ?? NSScreen.main)?.visibleFrame {
                width = min(width, screen.height - squareFooter - chrome)
            }
            width = max(PanelWindows.squareMinSide, width)
            // Przycięte nie ręką — to „wypełnij ekran". Zapamiętujemy ramkę sprzed niego, bo
            // macOS przyciętego okna nie uważa za dopasowane do ekranu i sam nie przywraca go
            // przy ściągnięciu (uwaga użytkownika 2026-09-27). Nie `inLiveResize`: animowane
            // wypełnienie macOS też zgłasza jako live resize, więc ramka nigdy się nie zapisywała.
            if width < frameSize.width, !resizingByHand, frameBeforeFill == nil {
                frameBeforeFill = sender.frame
            }
            return NSSize(width: width, height: width + squareFooter + chrome)
        }

        /// Ramka sprzed „wypełnij ekran” — patrz `windowWillResize`. `nil` = nie wypełnione.
        private var frameBeforeFill: NSRect?
        /// Live resize z wciśniętym przyciskiem myszy — ciągnięcie krawędzi, nie animacja.
        private var resizingByHand = false

        func windowWillStartLiveResize(_: Notification) {
            resizingByHand = NSEvent.pressedMouseButtons & 1 != 0
        }

        /// Ręczna zmiana rozmiaru kończy stan „wypełnione”; koniec animacji wypełnienia — nie.
        func windowDidEndLiveResize(_: Notification) {
            if resizingByHand { frameBeforeFill = nil }
            resizingByHand = false
        }

        /// Chwycone za pasek tytułu po „wypełnij ekran” — wraca do dawnego rozmiaru, jak
        /// inne okna macOS: kursor zostaje w tym samym miejscu paska (proporcjonalnie).
        func windowWillMove(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, let saved = frameBeforeFill,
                  NSEvent.pressedMouseButtons & 1 != 0 else { return }
            frameBeforeFill = nil
            let mouse = NSEvent.mouseLocation
            let current = window.frame
            let grip = current.width > 0 ? (mouse.x - current.minX) / current.width : 0.5
            var frame = saved
            frame.origin.x = mouse.x - grip * saved.width
            frame.origin.y = current.maxY - saved.height
            window.setFrame(frame, display: true)
        }

        func windowWillClose(_: Notification) {
            onClose()
        }
    }
}

/// Treść panelu w oknie. Panele o stałej siatce (`base`) skalują się proporcjonalnie
/// wraz z oknem — rysują się zawsze w swoim własnym układzie, a powiększa je dopiero
/// `scaleEffect`, więc żaden element nie rozjeżdża się względem pozostałych.
private struct ScalablePanel<Content: View>: View {
    let base: () -> CGSize?
    let minSize: CGSize
    /// Okno da się skalować — w prawym dolnym rogu rysujemy znacznik do chwycenia.
    let resizable: Bool
    let onBaseChange: (CGSize) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        panel.overlay(alignment: .bottomTrailing) {
            if resizable { ResizeGrip().padding(2) }
        }
    }

    @ViewBuilder private var panel: some View {
        if let base = base() {
            GeometryReader { geometry in
                let scale = max(1, min(geometry.size.width / base.width,
                                       geometry.size.height / base.height))
                content()
                    .frame(width: base.width, height: base.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: base.width * scale, height: base.height * scale,
                           alignment: .topLeading)
            }
            .frame(minWidth: base.width, minHeight: base.height)
            .onChange(of: base) { _, newBase in onBaseChange(newBase) }
        } else {
            content()
                .frame(minWidth: minSize.width, minHeight: minSize.height)
        }
    }
}

/// Pływający panel edytora. `canBecomeKey` jest nadpisane, bo `NSPanel` z tytułem
/// bywa niepodatny na focus klawiatury — a mutator ma własne skróty (`E`, `U`, `N`…).
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// Znacznik skalowania w prawym dolnym rogu okna — trzy ukośne kreski, jak dawny
/// „grow box" macOS. Od macOS 10.7 róg nic nie pokazuje, choć chwyta; użytkownik prosił
/// o widoczny znak (2026-09-27). Tylko obrazek: chwyt robi sam AppKit, klik przechodzi.
private struct ResizeGrip: View {
    var body: some View {
        Canvas { context, size in
            for step in 1 ... 3 {
                let offset = size.width * CGFloat(step) / 3
                var line = Path()
                line.move(to: CGPoint(x: size.width - offset, y: size.height))
                line.addLine(to: CGPoint(x: size.width, y: size.height - offset))
                context.stroke(line, with: .color(Color.primary.opacity(0.4)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
        .frame(width: 10, height: 10)
        .allowsHitTesting(false)
    }
}
