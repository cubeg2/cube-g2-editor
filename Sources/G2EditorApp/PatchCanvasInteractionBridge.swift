import AppKit
import G2Core
import G2EditorCore
import SwiftUI

// MARK: - AppKit drop destination (zastępuje SwiftUI .onDrop)

//
// SwiftUI .onDrop wywoływało updateDraggingItemsForDrop wewnętrznie i zmniejszało
// drag image. Własny NSDraggingDestination daje pełną kontrolę:
//   • updateDraggingItemsForDrop — powiększa drag image do canvas-zoom
//   • hitTest zwraca nil       — nie przechwytuje normalnych zdarzeń myszy
//   • performDragOperation     — odczytuje typeID ze schowka, oblicza pozycję gridu
//   • pliki z Findera          — `.pch2`/`.prf2` otwierają się (`FinderOpen`), jak w reszcie okna

final class DropTargetNSView: NSView {
    var zoom: CGFloat = 1.0
    var rowOffset: Int = 0
    var onDropModule: ((Int, Int, Int) -> Void)? // typeID, col, row
    var onDropParameterPageKnob: ((Int, CGPoint) -> Bool)?
    var onDropModuleColor: ((UInt8, CGPoint) -> Bool)?
    /// Building Block z listy Blocks — plik, kolumna i wiersz lewego górnego rogu.
    var onDropBlock: ((URL, Int, Int) -> Bool)?
    /// Blok wisi nad kanwą (`nil` = wyszedł albo upuszczony) — dla ducha bloku.
    var onBlockHover: ((BlockDropHover?) -> Void)?
    private var lastBlockHover: BlockDropHover?
    /// Koniec przeciągania bloku wyciągniętego z kanwy — kanwa wraca do zwykłych gestów.
    var onBlockExportEnded: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string, .fileURL])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// y=0 na górze (jak w SwiftUI/Canvas) — convert(_, from: nil) zwróci pozycję
    /// zgodną z układem canvas content w SwiftUI, bez odwracania Y.
    override var isFlipped: Bool {
        true
    }

    /// Nie przechwytuj normalnych zdarzeń myszy — canvas obsługuje je sam.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Moduły wyciągnięte z tej kanwy jako blok — wracają na nią bez skutku.
        if let string = sender.draggingPasteboard.string(forType: .string),
           BlockExportDragData.isExport(string) { return [] }
        // Plik z Findera zostaje z obrazkiem Findera — otwiera się, ducha nie ma.
        if let files = FinderOpen.files(on: sender.draggingPasteboard) {
            return FinderOpen.patchFile(in: files) == nil ? [] : .copy
        }
        if let string = sender.draggingPasteboard.string(forType: .string) {
            // Gałka strony parametrów i kwadracik koloru niosą własny obrazek
            // przeciągania — tylko moduł z biblioteki dostaje ducha rysowanego
            // przez SwiftUI, więc tylko jemu chowamy obrazek systemowy.
            if ParameterPageDragData.parse(string) != nil { return .move }
            if ModuleColorDragData.parse(string) != nil { return .copy }
            // Blok ma własnego ducha (`BlockDropGhost`) — obrazek wiersza listy by go zasłaniał.
            if let url = BuildingBlockDragData.parse(string) {
                hideDragImage(sender)
                reportBlockHover(url, sender)
                return .copy
            }
        }
        // Ukryj OS drag image — SwiftUI ghost przejmuje nad canvasem.
        hideDragImage(sender)
        return .copy
    }

    private func hideDragImage(_ sender: NSDraggingInfo) {
        let tiny = NSImage(size: NSSize(width: 1, height: 1))
        sender.enumerateDraggingItems(options: [], for: self,
                                      classes: [NSPasteboardItem.self],
                                      searchOptions: [:])
        { item, _, _ in
            item.setDraggingFrame(CGRect(x: -200, y: -200, width: 1, height: 1), contents: tiny)
        }
    }

    /// Zgłasza nową pozycję bloku tylko przy zmianie pola siatki — ruch myszy w obrębie
    /// jednego pola nie przerysowuje ducha.
    private func reportBlockHover(_ url: URL, _ sender: NSDraggingInfo) {
        let loc = convert(sender.draggingLocation, from: nil)
        let grid = PatchLayout.gridPosition(at: CGPoint(x: loc.x / zoom, y: loc.y / zoom), rowOffset: rowOffset)
        let hover = BlockDropHover(url: url, column: grid.column, row: grid.row)
        guard hover != lastBlockHover else { return }
        lastBlockHover = hover
        onBlockHover?(hover)
    }

    private func endBlockHover() {
        guard lastBlockHover != nil else { return }
        lastBlockHover = nil
        onBlockHover?(nil)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let string = sender.draggingPasteboard.string(forType: .string),
           BlockExportDragData.isExport(string) { return [] }
        if let files = FinderOpen.files(on: sender.draggingPasteboard) {
            return FinderOpen.patchFile(in: files) == nil ? [] : .copy
        }
        if let string = sender.draggingPasteboard.string(forType: .string) {
            if ParameterPageDragData.parse(string) != nil { return .move }
            if let url = BuildingBlockDragData.parse(string) { reportBlockHover(url, sender) }
        }
        return .copy
    }

    override func draggingExited(_: NSDraggingInfo?) {
        endBlockHover()
    }

    override func concludeDragOperation(_: NSDraggingInfo?) {
        endBlockHover()
    }

    override func prepareForDragOperation(_: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // convert nil = z układu okna do układu tego NSView (uwzględnia scroll offset)
        let loc = convert(sender.draggingLocation, from: nil)
        let logicalPoint = CGPoint(x: loc.x / zoom, y: loc.y / zoom)

        if let files = FinderOpen.files(on: sender.draggingPasteboard) {
            guard let url = FinderOpen.patchFile(in: files) else { return false }
            // Pytanie o zapis zmian dopiero po zakończeniu przeciągania — modalne okno
            // w trakcie trzymałoby Findera w zawieszeniu.
            DispatchQueue.main.async { FinderOpen.shared.open(url) }
            return true
        }
        guard let string = sender.draggingPasteboard.string(forType: .string) else { return false }
        if let payload = ParameterPageDragData.parse(string) {
            return onDropParameterPageKnob?(payload.index, logicalPoint) ?? false
        }
        if let color = ModuleColorDragData.parse(string) {
            return onDropModuleColor?(color, logicalPoint) ?? false
        }
        if let url = BuildingBlockDragData.parse(string) {
            // Duch znika przed okienkiem przypisań — inaczej wisiałby nad nim.
            endBlockHover()
            let grid = PatchLayout.gridPosition(at: logicalPoint, rowOffset: rowOffset)
            return onDropBlock?(url, grid.column, grid.row) ?? false
        }

        guard let typeID = Int(string) else { return false }
        // Kursor = lewy górny róg modułu
        let grid = PatchLayout.gridPosition(
            at: logicalPoint,
            rowOffset: rowOffset
        )

        onDropModule?(typeID, grid.column, grid.row)
        return true
    }
}

// MARK: - Moduły wyciągnięte z kanwy jako blok

/// Widok, który zaczyna systemowe przeciąganie bloku — kanwa sięga po niego z gestu SwiftUI.
@MainActor
final class CanvasDragSource {
    weak var view: DropTargetNSView?
}

extension DropTargetNSView: NSDraggingSource {
    /// Kursor poza widocznym kawałkiem kanwy (np. nad panelem Patches obok).
    var pointerLeftVisibleCanvas: Bool {
        guard let window, let event = NSApp.currentEvent, event.window === window else { return false }
        return !visibleRect.contains(convert(event.locationInWindow, from: nil))
    }

    /// Zaczyna przeciąganie bloku z bieżącego ruchu myszy; `false`, gdy to nie ruch myszy.
    func beginBlockExport(_ payload: String, image: NSImage, ended: @escaping () -> Void) -> Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDragged else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: payload as NSString)
        item.setDraggingFrame(NSRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height),
                              contents: image)
        onBlockExportEnded = ended
        beginDraggingSession(with: [item], event: event, source: self)
        return true
    }

    func draggingSession(_: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation
    {
        context == .withinApplication ? .copy : []
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        // Sesja przeciągania połyka puszczenie przycisku, więc gest kanwy (SwiftUI) czekał na nie
        // dalej i zjadał następne kliknięcie — pierwsze przesunięcie modułu po zapisie bloku
        // nie działało (sprawdzone 2026-10-23). Oddajemy mu to puszczenie.
        if let window, let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: window.mouseLocationOutsideOfEventStream, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ) {
            window.sendEvent(up)
        }
        onBlockExportEnded?()
        onBlockExportEnded = nil
    }
}

struct DropTargetRepresentable: NSViewRepresentable {
    let zoom: CGFloat
    let rowOffset: Int
    let onDropModule: ((Int, Int, Int) -> Void)?
    let onDropParameterPageKnob: ((Int, CGPoint) -> Bool)?
    let onDropModuleColor: ((UInt8, CGPoint) -> Bool)?
    let onDropBlock: ((URL, Int, Int) -> Bool)?
    let onBlockHover: ((BlockDropHover?) -> Void)?
    let dragSource: CanvasDragSource

    func makeNSView(context _: Context) -> DropTargetNSView {
        let view = DropTargetNSView()
        dragSource.view = view
        return view
    }

    func updateNSView(_ v: DropTargetNSView, context _: Context) {
        v.zoom = zoom
        v.rowOffset = rowOffset
        v.onDropModule = onDropModule
        v.onDropParameterPageKnob = onDropParameterPageKnob
        v.onDropModuleColor = onDropModuleColor
        v.onDropBlock = onDropBlock
        v.onBlockHover = onBlockHover
    }
}

// MARK: - SeqNote scroll wheel handler (⌥+scroll)

/// NSView przechwytujący zdarzenia scroll wheel z klawiszem ⌥ nad obszarem SeqNote.
/// Nie przechwytuje kliknięć ani zwykłego scrollu — nie koliduje z panem canvasu.
final class SeqScrollWheelNSView: NSView {
    var zoom: CGFloat = 1.0
    var rowOffset: Int = 0
    var modules: [G2Module] = []
    /// Callback: (moduleID, deltaSemitony) — wywołany na main thread
    var onSeqScroll: ((Int, Int) -> Void)?

    private var monitor: Any?
    /// Akumulator ułamkowych deltaSemitonów (osobny per moduł)
    private var accumulator: [Int: CGFloat] = [:]

    override var isFlipped: Bool {
        true
    }

    /// Przezroczysty dla kliknięć — obsługa wyłącznie przez NSEvent monitor
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            // guard let self — NIE `self?.handleScrollEvent(event) ?? event`: optional
            // chaining spłaszcza `NSEvent??`, więc zwrócone przez handler `nil`
            // ("skonsumuj") jest nie do odróżnienia od zwolnionego self i `?? event`
            // przywraca zdarzenie — canvas przewijałby się razem ze zmianą zakresu nut.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handleScrollEvent(event)
            }
        } else if window == nil, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
        // Tylko ⌥+scroll, tylko w tym oknie
        guard event.modifierFlags.contains(.option),
              let myWindow = window,
              event.window === myWindow
        else { return event }

        // convert(from: nil) przelicza punkt okna na układ tego NSView (z uwzględnieniem
        // flipping, scroll offset ScrollView i wszystkich transformacji w hierarchii).
        let winPt = event.locationInWindow
        let viewPt = convert(winPt, from: nil) // flipped → y rośnie w dół od lewego-górnego rogu
        let logicalPt = CGPoint(x: viewPt.x / zoom, y: viewPt.y / zoom)

        for module in modules {
            guard let uid = ModuleUIDatabase.shared.uiDef(forID: module.typeID),
                  let def = ModuleDatabase.module(id: module.typeID)
            else { continue }
            let noteKnobs = uid.seqNoteKnobs
            guard !noteKnobs.isEmpty else { continue }

            let rect = PatchLayout.moduleRect(module, def: def,
                                              rowOffset: rowOffset, allModules: modules)
            // Strefa = cały moduł (wystarczy być nad sekwencerem)
            guard rect.insetBy(dx: -2, dy: -2).contains(logicalPt) else { continue }

            // Czułość: trackpad (hasPreciseScrollingDeltas) → dzielnik 4; mysz wheel → 2
            let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 4.0 : 2.0
            accumulator[module.id, default: 0] += event.scrollingDeltaY
            let steps = Int(accumulator[module.id]! / sensitivity)
            if steps != 0 {
                accumulator[module.id]! -= CGFloat(steps) * sensitivity
                onSeqScroll?(module.id, steps)
            }
            return nil // skonsumuj — nie przekazuj do pana canvasu
        }
        return event // brak SeqNote pod kursorem → przepuść
    }
}

struct SeqScrollHandlerRepresentable: NSViewRepresentable {
    let zoom: CGFloat
    let rowOffset: Int
    let modules: [G2Module]
    var onSeqScroll: ((Int, Int) -> Void)?

    init(_ zoom: CGFloat = 1, _ rowOffset: Int = 0, _ modules: [G2Module],
         onSeqScroll: ((Int, Int) -> Void)? = nil)
    {
        self.zoom = zoom
        self.rowOffset = rowOffset
        self.modules = modules
        self.onSeqScroll = onSeqScroll
    }

    func makeNSView(context _: Context) -> SeqScrollWheelNSView {
        SeqScrollWheelNSView()
    }

    func updateNSView(_ v: SeqScrollWheelNSView, context _: Context) {
        v.zoom = zoom
        v.rowOffset = rowOffset
        v.modules = modules
        v.onSeqScroll = onSeqScroll
    }
}

// MARK: - Prawy klawisz i dwuklik nad kanwą

/// Przechwytuje `rightMouseDown` i drugie kliknięcie lewym nad kanwą i podaje punkt
/// w układzie patcha. Ta sama konstrukcja co `SeqScrollWheelNSView`: `hitTest` zwraca
/// nil, więc widok jest przezroczysty dla zwykłych kliknięć, a zdarzenie łapie lokalny
/// monitor.
///
/// Dwuklik czytamy z `clickCount` zdarzenia, a nie z gestu SwiftUI: gest dwukliku
/// wstrzymywałby każde pojedyncze kliknięcie na kanwie, aż minie czas na drugie.
final class CanvasRightClickNSView: NSView {
    var zoom: CGFloat = 1.0
    /// Zwraca `true`, gdy klik został obsłużony — wtedy zdarzenie nie leci dalej.
    var onRightClick: ((CGPoint) -> Bool)?
    var onDoubleClick: ((CGPoint) -> Bool)?

    private var monitor: Any?

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            // guard let self, nie optional chaining — patrz komentarz przy
            // SeqScrollWheelNSView: `NSEvent??` spłaszczone do `nil` jest nie do
            // odróżnienia od zwolnionego self i `?? event` przywracałoby zdarzenie.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handleClick(event)
            }
        } else if window == nil, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func handleClick(_ event: NSEvent) -> NSEvent? {
        guard let myWindow = window, event.window === myWindow else { return event }
        let handler = event.type == .rightMouseDown ? onRightClick
            : event.clickCount == 2 ? onDoubleClick : nil
        guard let handler else { return event }
        let viewPt = convert(event.locationInWindow, from: nil)
        // Poza kanwą (paski, panele boczne) nie ma czego trafiać.
        guard bounds.contains(viewPt) else { return event }
        let logicalPt = CGPoint(x: viewPt.x / zoom, y: viewPt.y / zoom)
        return handler(logicalPt) ? nil : event
    }
}

struct CanvasRightClickRepresentable: NSViewRepresentable {
    let zoom: CGFloat
    var onRightClick: ((CGPoint) -> Bool)?
    var onDoubleClick: ((CGPoint) -> Bool)?

    func makeNSView(context _: Context) -> CanvasRightClickNSView {
        CanvasRightClickNSView()
    }

    func updateNSView(_ v: CanvasRightClickNSView, context _: Context) {
        v.zoom = zoom
        v.onRightClick = onRightClick
        v.onDoubleClick = onDoubleClick
    }
}

// MARK: - Zoom do kursora (pinch + ⌘scroll) i Space+drag pan ("rączka")

/// Uchwyt do programowego wywoływania zoomu z przycisków/skrótów SwiftUI (ContentView),
/// bez trzymania w SwiftUI referencji do samej instancji NSView.
final class CanvasZoomPanController: CanvasZoomRequesting {
    fileprivate weak var view: CanvasZoomPanNSView?
    /// Fallback zanim `view` się zamontuje (pierwsza klatka) — utrzymywany w sync przez
    /// CanvasZoomPanRepresentable, żeby przyciski zoomu działały nawet przed makeNSView.
    var onZoomChange: ((CGFloat) -> Void)?

    /// Zoom z przycisku/skrótu klawiszowego — bez pozycji kursora, centruje się
    /// na środku aktualnie widocznego obszaru.
    func requestZoom(_ newZoom: CGFloat) {
        if let view {
            view.applyZoomChange(to: newZoom, anchorDocPoint: nil)
        } else {
            onZoomChange?(newZoom)
        }
    }
}

/// Przechwytuje trackpad pinch (magnify) i ⌘+scroll nad canvasem — zoom zawsze
/// wycentrowany na pozycji kursora, nie na lewym-górnym rogu (domyślne zachowanie
/// SwiftUI `ScrollView` przy zmianie rozmiaru contentu). Dodatkowo: przytrzymanie
/// SPACE + drag = "rączka" (pan całego widoku), jak w Photoshopie.
///
/// Zoom-do-kursora: dokument w `NSScrollView` skaluje się wokół (0,0) (lewy-górny róg),
/// więc sama zmiana zoomu bez korekty scrolla zawsze "ucieka" w tamtą stronę. Rozwiązanie:
/// przed zmianą zoomu zapamiętaj logiczny punkt pod kursorem (niezależny od zoomu),
/// po zmianie (i przeliczeniu layoutu przez SwiftUI, stąd `DispatchQueue.main.async`)
/// przesuń scroll tak, by ten sam punkt logiczny wrócił pod kursor.
final class CanvasZoomPanNSView: NSView {
    var zoom: CGFloat = 1.0
    var onZoomChange: ((CGFloat) -> Void)?
    /// True podczas edycji nazwy modułu (TextField) — wtedy SPACE ma wpisywać spację,
    /// a nie aktywować rączkę.
    var isEditingText: Bool = false

    private var isSpaceDown = false
    private var isPanning = false
    private var panStartMouse: NSPoint = .zero
    private var panStartOrigin: NSPoint = .zero

    private var keyMonitor: Any?
    private var magnifyMonitor: Any?
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    private var firstKeyObserver: NSObjectProtocol?
    private var initialFocusReleased = false

    /// Punkt do przywrócenia pod kursorem po tym, jak SwiftUI przeliczy rozmiar canvasu.
    private var pendingAnchor: (logical: NSPoint, localOffset: NSPoint, zoom: CGFloat)?
    private var frameObserver: NSObjectProtocol?
    private weak var observedDocumentView: NSView?

    override var isFlipped: Bool {
        true
    }

    /// Przezroczysty dla zwykłych kliknięć (canvas obsługuje je sam przez własne gesty) —
    /// wyjątek: gdy trzymany SPACE, przejmuje WSZYSTKIE zdarzenia myszy nad canvasem (pan),
    /// żeby drag nie trafił jednocześnie w moduł/kabel/rubber-band selection.
    override func hitTest(_: NSPoint) -> NSView? {
        isSpaceDown ? self : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            installMonitorsIfNeeded()
            releaseInitialTextFocus(in: window)
        } else {
            removeMonitors()
            isSpaceDown = false
            isPanning = false
            popHandCursor()
        }
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = magnifyMonitor { NSEvent.removeMonitor(m) }
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let o = frameObserver { NotificationCenter.default.removeObserver(o) }
        if let o = firstKeyObserver { NotificationCenter.default.removeObserver(o) }
        while pushedCursorCount > 0 {
            NSCursor.pop()
            pushedCursorCount -= 1
        }
    }

    /// ⚠️ `self?.handler(event) ?? event` NIE działa: optional chaining spłaszcza oba
    /// poziomy `nil`, więc zwrócenie `nil` przez handler ("skonsumuj zdarzenie") jest
    /// nie do odróżnienia od zwolnionego `self` i `?? event` przywraca zdarzenie z powrotem.
    /// Efekt: spacja szła dalej do systemu (pyknięcie), a ⌘+scroll przewijał canvas
    /// równocześnie z zoomowaniem (skakanie). Stąd jawny `guard let self`.
    private func installMonitorsIfNeeded() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                return self.handleKeyEvent(event)
            }
        }
        if magnifyMonitor == nil {
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                guard let self else { return event }
                return self.handleMagnify(event)
            }
        }
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handleScrollZoom(event)
            }
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.releaseOutsideTextField(on: event)
                return event
            }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = magnifyMonitor { NSEvent.removeMonitor(m) }
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        magnifyMonitor = nil
        scrollMonitor = nil
        clickMonitor = nil
    }

    // MARK: - Klik w kanwę zdejmuje kursor z pola tekstowego

    /// Kanwa rysowana w SwiftUI nie przejmuje fokusu, więc po wpisaniu frazy w wyszukiwarkę
    /// (panel Patches, lista modułów) kursor zostawał w polu mimo kliknięcia w patch —
    /// a `KeyEventScope` oddawał wtedy Delete, strzałki i litery polu zamiast kanwie.
    /// Pola leżące NA kanwie (nazwa modułu) kończą edycję same, więc ich nie ruszamy.
    private func releaseOutsideTextField(on event: NSEvent) {
        guard let window, event.window === window,
              let scrollView = enclosingScrollView,
              let editor = window.firstResponder as? NSText,
              let field = editor.delegate as? NSView,
              !field.isDescendant(of: scrollView) else { return }
        let point = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(point) else { return }
        window.makeFirstResponder(nil)
    }

    // MARK: - Start okna bez kursora w polu tekstowym

    /// Przy pierwszym uaktywnieniu okna AppKit sam wstawia kursor w pierwsze pole
    /// tekstowe pętli klawiatury — u nas nazwę patcha w pasie slotu, którą pierwszy
    /// wciśnięty klawisz po cichu nadpisywał (zgłoszenie użytkownika 2026-09-28).
    /// Zdejmujemy go raz, po pierwszym `didBecomeKey`; kliknięcie w pole działa dalej.
    private func releaseInitialTextFocus(in window: NSWindow) {
        guard !initialFocusReleased, firstKeyObserver == nil else { return }
        if window.isKeyWindow {
            releaseTextFocusSoon(in: window)
            return
        }
        firstKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            if let o = self.firstKeyObserver { NotificationCenter.default.removeObserver(o) }
            self.firstKeyObserver = nil
            self.releaseTextFocusSoon(in: window)
        }
    }

    /// Z opóźnieniem, bo SwiftUI ustawia fokus pola już po samym `didBecomeKey`,
    /// a moment nie jest gwarantowany; 0,2 s po starcie nikt jeszcze nie pisze.
    private func releaseTextFocusSoon(in window: NSWindow) {
        initialFocusReleased = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if window.firstResponder is NSText { window.makeFirstResponder(nil) }
        }
    }

    // MARK: - Space = rączka (hand tool)

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 49 else { return event } // Space
        guard window?.isKeyWindow == true, !isEditingText else { return event }

        if event.type == .keyDown {
            // isARepeat: system powtarza keyDown przy przytrzymaniu — konsumuj (inaczej
            // pyka), ale nie przestawiaj stanu, bo rączka jest już aktywna.
            if !isSpaceDown {
                isSpaceDown = true
                pushHandCursor(.openHand)
            }
            return nil // konsumuj — SPACE nie ma tu innego znaczenia
        } else {
            isSpaceDown = false
            isPanning = false
            popHandCursor()
            return nil
        }
    }

    // MARK: Kursor rączki

    //
    // `resetCursorRects` tu nie zadziała: dopóki SPACE nie jest wciśnięty, `hitTest`
    // zwraca nil, więc AppKit nie uznaje kursora za znajdujący się nad tym widokiem
    // i nigdy nie pyta o cursor rects. `push()`/`pop()` ustawia kursor natychmiast,
    // niezależnie od hit-testu i bez czekania na ruch myszy.

    /// Ile razy zrobiliśmy `push` — żeby `pop` zawsze zdjął dokładnie nasze kursory
    /// (niesparowany pop przywróciłby kursor innego komponentu).
    private var pushedCursorCount = 0

    private func pushHandCursor(_ cursor: NSCursor) {
        popHandCursor()
        cursor.push()
        pushedCursorCount += 1
    }

    private func popHandCursor() {
        while pushedCursorCount > 0 {
            NSCursor.pop()
            pushedCursorCount -= 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isSpaceDown, let scrollView = enclosingScrollView else { return }
        isPanning = true
        pendingAnchor = nil // pan unieważnia niedokończoną korektę zoomu
        pushHandCursor(.closedHand)
        panStartMouse = event.locationInWindow
        panStartOrigin = scrollView.contentView.bounds.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning, let scrollView = enclosingScrollView else { return }
        let cur = event.locationInWindow
        let dx = cur.x - panStartMouse.x
        let dy = cur.y - panStartMouse.y
        // Okno: y rośnie w górę. Dokument: isFlipped=true, y rośnie w dół.
        // Stąd różne znaki dla X i Y przy przenoszeniu delty myszy na scroll offset.
        scrollTo(NSPoint(x: panStartOrigin.x - dx, y: panStartOrigin.y + dy), in: scrollView)
    }

    override func mouseUp(with _: NSEvent) {
        guard isPanning else { return }
        isPanning = false
        if isSpaceDown { pushHandCursor(.openHand) } else { popHandCursor() }
    }

    // MARK: - Zoom do kursora (magnify + ⌘scroll)

    private func handleMagnify(_ event: NSEvent) -> NSEvent? {
        guard window?.isKeyWindow == true else { return event }
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return event }
        applyZoomChange(to: clampZoom(zoom * (1.0 + event.magnification)), anchorDocPoint: local)
        return nil // skonsumuj — inaczej SwiftUI/ScrollView dołoży własną reakcję
    }

    private func handleScrollZoom(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.command) else { return event }
        guard window?.isKeyWindow == true else { return event }
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return event }
        // Skok mnożnikowy (exp), nie addytywny: ten sam ruch kółka daje ten sam procentowy
        // przyrost niezależnie od bieżącego zoomu, więc tempo jest równomierne na całym
        // zakresie. Kółko myszy generuje delty ~×10 większe niż trackpad — stąd dwa mnożniki.
        let step = event.hasPreciseScrollingDeltas ? 0.004 : 0.02
        applyZoomChange(to: clampZoom(zoom * exp(event.scrollingDeltaY * step)), anchorDocPoint: local)
        return nil // skonsumuj — nie przewijaj canvasu podczas zoomu
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat {
        max(0.25, min(8.0, z))
    }

    /// Ustawia scroll offset, przycinając go do rzeczywistych granic dokumentu —
    /// `NSClipView.scroll(to:)` sam nie klampuje i potrafi wyjechać poza treść.
    private func scrollTo(_ origin: NSPoint, in scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let doc = scrollView.documentView?.frame.size ?? clip.bounds.size
        let maxX = max(0, doc.width - clip.bounds.width)
        let maxY = max(0, doc.height - clip.bounds.height)
        clip.setBoundsOrigin(NSPoint(x: min(max(0, origin.x), maxX),
                                     y: min(max(0, origin.y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Zmienia zoom zachowując pozycję `anchorDocPoint` (w lokalnych/document coords,
    /// czyli tych samych co reszta mostków AppKit w tym pliku) pod kursorem — lub środek
    /// widocznego obszaru, gdy `anchorDocPoint == nil` (zoom z przycisku/skrótu).
    func applyZoomChange(to newZoom: CGFloat, anchorDocPoint: NSPoint?) {
        let oldZoom = zoom
        guard abs(oldZoom - newZoom) > 0.0001 else { return }
        guard let scrollView = enclosingScrollView else {
            zoom = newZoom
            onZoomChange?(newZoom)
            return
        }
        let clipView = scrollView.contentView
        let anchor = anchorDocPoint ?? NSPoint(x: clipView.bounds.midX, y: clipView.bounds.midY)
        // Punkt logiczny = niezależny od zoomu; po przeskalowaniu ma wrócić dokładnie
        // w to samo miejsce ekranu, czyli `localOffset` od lewego-górnego rogu okna widoku.
        pendingAnchor = (
            logical: NSPoint(x: anchor.x / oldZoom, y: anchor.y / oldZoom),
            localOffset: NSPoint(x: anchor.x - clipView.bounds.origin.x,
                                 y: anchor.y - clipView.bounds.origin.y),
            zoom: newZoom
        )
        observeDocumentFrame(scrollView)

        zoom = newZoom
        onZoomChange?(newZoom)
        // Fallback, gdyby rozmiar dokumentu się nie zmienił (zoom przy canvasie mniejszym
        // niż viewport — `minSize` trzyma wtedy stały rozmiar i notyfikacja nie przyjdzie).
        DispatchQueue.main.async { [weak self] in self?.applyPendingAnchor() }
    }

    /// Korekta scrolla musi nastąpić DOKŁADNIE po tym, jak SwiftUI przeliczy rozmiar
    /// canvasu pod nowy zoom — wcześniej granice scrolla są jeszcze stare i offset
    /// zostałby przycięty do nich (to powodowało "skakanie" i ucieczkę do rogu).
    /// Stała jedna klatka opóźnienia tego nie gwarantuje, więc słuchamy zmiany ramki.
    private func observeDocumentFrame(_ scrollView: NSScrollView) {
        guard let doc = scrollView.documentView, doc !== observedDocumentView else { return }
        if let old = frameObserver { NotificationCenter.default.removeObserver(old) }
        doc.postsFrameChangedNotifications = true
        observedDocumentView = doc
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: doc, queue: .main
        ) { [weak self] _ in
            self?.applyPendingAnchor()
        }
    }

    /// Idempotentna — bezpiecznie wołana wielokrotnie (notyfikacja + fallback async)
    /// dla tej samej zmiany zoomu; liczy pozycję od zapamiętanego punktu logicznego,
    /// nie od bieżącego offsetu, więc powtórzenie daje ten sam wynik.
    private func applyPendingAnchor() {
        guard let p = pendingAnchor, let scrollView = enclosingScrollView else { return }
        let newAnchor = NSPoint(x: p.logical.x * p.zoom, y: p.logical.y * p.zoom)
        scrollTo(NSPoint(x: newAnchor.x - p.localOffset.x, y: newAnchor.y - p.localOffset.y),
                 in: scrollView)
    }
}

struct CanvasZoomPanRepresentable: NSViewRepresentable {
    let zoom: CGFloat
    let isEditingText: Bool
    let controller: CanvasZoomPanController
    let onZoomChange: (CGFloat) -> Void

    func makeNSView(context _: Context) -> CanvasZoomPanNSView {
        let v = CanvasZoomPanNSView()
        v.zoom = zoom
        v.isEditingText = isEditingText
        v.onZoomChange = onZoomChange
        controller.view = v
        return v
    }

    func updateNSView(_ v: CanvasZoomPanNSView, context _: Context) {
        v.zoom = zoom
        v.isEditingText = isEditingText
        v.onZoomChange = onZoomChange
        controller.onZoomChange = onZoomChange
    }
}
