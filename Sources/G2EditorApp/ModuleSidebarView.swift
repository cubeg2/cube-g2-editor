// ModuleSidebarView.swift
// Rozwijany panel boczny z biblioteką modułów G2.
//
// Układ:
//   ┌─ 🔍 Szukaj… ───────────────┐
//   │ ⭐ Ulubione            (N) │
//   │ 🕐 Ostatnio użyte      (N) │
//   │ ▼ Env                  (N) │
//   │    EnvADSR  Envelope ADSR  │
//   │    EnvAD    Envelope AD    │
//   │ ▶ Osc                  (N) │
//   └────────────────────────────┘
//
// Drag & Drop: każdy wiersz modułu jest przeciągalny (ModuleDragItem).
//   Drag preview i hover = podgląd modułu z ModulePreviewCache.
// Podwójny klik = dodaj moduł na domyślnej pozycji (kolumna 0, dół).
// Przycisk serca = dodaj/usuń z ulubionych (persisted via AppStorage).
//
import AppKit
import G2Core
import G2EditorCore
import SwiftUI

// MARK: - Environment: canvasZoom

/// Przekazywany przez .environment(\.canvasZoom, currentZoom) z ContentView.
/// NSViewRepresentable gwarantuje updateNSView przy każdej zmianie env —
/// eliminuje ryzyko nieaktualnego zoom w NSView podczas draga.
private struct CanvasZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 2.0
}

extension EnvironmentValues {
    var canvasZoom: CGFloat {
        get { self[CanvasZoomKey.self] }
        set { self[CanvasZoomKey.self] = newValue }
    }
}

// MARK: - View mode

private enum SidebarViewMode: String {
    case compact, visual

    var icon: String {
        switch self {
        case .compact: "list.bullet"
        case .visual: "rectangle.grid.1x2"
        }
    }

    var helpText: String {
        switch self {
        case .compact: "Compact list — click for visual browser"
        case .visual: "Visual browser — click for compact list"
        }
    }
}

/// Mierzy faktyczną szerokość content area ScrollView (uwzględnia scrollbar legacy/overlay).
private struct ScrollContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    /// max() — jeśli kilka dzieci raportuje szerokość, bierzemy największą (nie 0).
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Ramki nagłówków kategorii w przestrzeni widocznego obszaru ScrollView.
private struct HeaderFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension Notification.Name {
    /// Przeciąganie modułu z palety skończone (upuszczony albo anulowany).
    static let sidebarModuleDragEnded = Notification.Name("G2SidebarModuleDragEnded")
}

/// Ramki nagłówków w klasie, nie w @State: zmieniają się przy każdym kroku scrolla
/// i nie mogą za każdym razem przebudowywać całego panelu.
private final class HeaderFramesBox {
    var frames: [String: CGRect] = [:]
}

/// Obszar otwartej kategorii (nazwa + moduły) — mówi, kiedy kursor z niego zjechał.
///
/// AppKit, nie `.onHover`: tracking area działa po samym prostokącie, więc nie gubi
/// kursora nad wierszami modułów, które same są widokami AppKit (`ImmediateDragNSView`).
private struct CategoryLeaveDetector: NSViewRepresentable {
    /// `below` = kursor zjechał dołem, na następne kategorie.
    let onLeave: (_ below: Bool) -> Void

    func makeNSView(context _: Context) -> CategoryLeaveView {
        let v = CategoryLeaveView()
        v.onLeave = onLeave
        return v
    }

    func updateNSView(_ v: CategoryLeaveView, context _: Context) {
        v.onLeave = onLeave
    }
}

private final class CategoryLeaveView: NSView {
    var onLeave: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var dragEndObserver: NSObjectProtocol?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Przezroczysty dla kliknięć — tylko słucha kursora.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func mouseExited(with _: NSEvent) {
        // Podczas przeciągania kategoria zostaje — o zwinięciu decyduje koniec draga.
        guard !ImmediateDragNSView.anyDragging else { return }
        leaveIfOutside()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let dragEndObserver { NotificationCenter.default.removeObserver(dragEndObserver) }
        dragEndObserver = nil
        guard window != nil else { return }
        dragEndObserver = NotificationCenter.default.addObserver(
            forName: .sidebarModuleDragEnded, object: nil, queue: .main
        ) { [weak self] _ in self?.leaveIfOutside() }
    }

    private func leaveIfOutside() {
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let visible = visibleRect
        guard !visible.contains(p) else { return }
        let below = p.x >= visible.minX && p.x <= visible.maxX
            && (isFlipped ? p.y > visible.maxY : p.y < visible.minY)
        onLeave?(below)
    }
}

// MARK: - ModuleSidebarView

struct ModuleSidebarView: View {
    /// Wywołane gdy użytkownik dwukliknie lub użyje przycisku "Dodaj" — brak pozycji.
    let onAdd: (_ typeID: Int) -> Void
    /// Ghost drag — wywoływane z każdą pozycją kursora podczas draga (ContentView coordinates).
    var onGhostMove: ((Int, CGPoint) -> Void)?
    /// Ghost drag — wywoływane gdy drag się kończy.
    var onGhostEnd: (() -> Void)?
    /// Obciążenie obu obszarów PO dorzuceniu modułu tego typu — pod podgląd chwyconego
    /// modułu. `nil` znaczy „użytkownik wyłączył ten pasek w menu View".
    var patchLoadPreview: ((Int) -> (voice: G2PatchLoad?, fx: G2PatchLoad?))?

    /// Zoom czytany z env — SwiftUI re-renderuje body gdy canvasZoom się zmienia,
    /// co propaguje aktualną wartość jako prop do wszystkich SidebarModuleRow.
    @Environment(\.canvasZoom) private var zoom

    @AppStorage("g2_favorites") private var favoritesRaw: String = ""

    @State private var search: String = ""
    /// Rozwinięte kategorie i ulubione wracają po ponownym uruchomieniu takie, jak
    /// zostały przy zamknięciu (prośba użytkownika 2026-10-09).
    @State private var expandedCategories = ModuleSidebarView.restoredExpandedCategories()
    @AppStorage("g2_sidebar_fav_expanded") private var favExpanded: Bool = true
    /// Tryb widoku sidebaru: compact (nazwa + hover podgląd) lub visual (wyrenderowane moduły inline).
    @AppStorage("g2_sidebar_view_mode") private var viewMode: SidebarViewMode = .visual
    /// Wspólny hover — tylko jeden wiersz może być podświetlony naraz.
    @State private var hoveredModuleID: Int?
    /// Aktualna szerokość content area ScrollView (może być mniejsza od frame gdy scrollbar legacy).
    @State private var scrollContentW: CGFloat = 292
    /// Kategoria otwiera się kliknięciem i sama zwija, gdy kursor z niej zjedzie; otwarta
    /// jest tylko jedna. Przeciągany moduł trzyma ją otwartą do upuszczenia (prośba 2026-09-28).
    @AppStorage("g2_sidebar_auto_collapse") private var autoCollapse = true
    @State private var headerFrames = HeaderFramesBox()

    private static let scrollSpace = "moduleSidebarScroll"

    // MARK: Derived data

    private var favorites: [Int] {
        favoritesRaw.split(separator: ",").compactMap { Int($0) }
    }

    private func isFav(_ id: Int) -> Bool {
        favorites.contains(id)
    }

    private func toggleFav(_ id: Int) {
        var f = favorites
        if let i = f.firstIndex(of: id) { f.remove(at: i) } else { f.append(id) }
        favoritesRaw = f.map(String.init).joined(separator: ",")
    }

    private var allCategories: [String] {
        ModuleCatalogOrder.orderedCategories(from: ModuleDatabase.all)
    }

    private func mods(for cat: String) -> [ModuleDef] {
        let filtered = ModuleDatabase.all.filter { $0.page == cat && matchesSearch($0) }
        return ModuleCatalogOrder.orderedModules(in: cat, from: filtered)
    }

    private func matchesSearch(_ d: ModuleDef) -> Bool {
        search.isEmpty
            || d.shortName.localizedCaseInsensitiveContains(search)
            || d.longName.localizedCaseInsensitiveContains(search)
    }

    private var searchResults: [ModuleDef] {
        let filtered = ModuleDatabase.all.filter { matchesSearch($0) }
        return ModuleCatalogOrder.orderedModules(from: filtered)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            footer
            Divider()
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            if !search.isEmpty {
                                flatSearchResults
                            } else {
                                favSection
                                allCategorySections(proxy: proxy, viewportH: viewport.size.height)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // GeometryReader mierzy faktyczną szerokość content area (po odjęciu scrolla).
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: ScrollContentWidthKey.self, value: geo.size.width)
                        })
                    }
                    .coordinateSpace(name: Self.scrollSpace)
                    // ScrollbarFlush zeruje scrollerInsets NSScrollView — scrollbar dotyka prawej krawędzi.
                    .background(ScrollbarFlush())
                    // Ignoruj 0 — może pojawić się przed pierwszym pełnym layoutem.
                    .onPreferenceChange(ScrollContentWidthKey.self) { w in if w > 50 { scrollContentW = w } }
                    .onPreferenceChange(HeaderFramesKey.self) { headerFrames.frames = $0 }
                }
            }
        }
        .frame(width: viewMode == .visual ? PanelController.Panel.drawerWidth : 190)
        .background(Color(nsColor: .windowBackgroundColor))
        // Kółko na kursorze tylko nad biblioteką i tylko dopóki podglądy się rysują.
        .onContinuousHover { phase in
            switch phase {
            case .active: LoadingCursor.shared.show()
            case .ended: LoadingCursor.shared.hide()
            }
        }
        .onChange(of: expandedCategories) { _, expanded in
            UserDefaults.standard.set(expanded.sorted().joined(separator: "|"), forKey: Self.expandedKey)
        }
    }

    private static let expandedKey = "g2_sidebar_expanded_categories"

    /// Kategorie otwarte przy ostatnim zamknięciu. Bez zapisu (pierwsze uruchomienie):
    /// z auto-zwijaniem wszystkie zwinięte, bez niego wszystkie otwarte.
    private static func restoredExpandedCategories() -> Set<String> {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: expandedKey) {
            return Set(raw.split(separator: "|").map(String.init))
        }
        let autoCollapse = defaults.object(forKey: "g2_sidebar_auto_collapse") as? Bool ?? true
        return autoCollapse ? [] : Set(ModuleCatalogOrder.categories)
    }

    // MARK: - Auto collapse

    /// Kursor zjechał z otwartej kategorii — zwiń ją. Gdy zjechał dołem, nazwa następnej
    /// kategorii zostaje pod kursorem; bez tego zwinięcie długiej listy powyżej
    /// wyrzuciłoby ją daleko w górę, spod ręki.
    private func collapseOnLeave(_ cat: String, below: Bool,
                                 proxy: ScrollViewProxy, viewportH: CGFloat)
    {
        guard autoCollapse, search.isEmpty, expandedCategories.contains(cat) else { return }
        let visible = allCategories.filter { !mods(for: $0).isEmpty }
        let next = visible.firstIndex(of: cat).flatMap { i in i + 1 < visible.count ? visible[i + 1] : nil }
        let anchor = below ? next.flatMap { n in headerFrames.frames[n].map { (n, $0) } } : nil
        // Zwinięcie i przewinięcie w jednej animacji: obie idą tą samą krzywą,
        // więc nazwa pod kursorem stoi w miejscu.
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedCategories.remove(cat)
            guard let (n, frame) = anchor, viewportH > frame.height else { return }
            // scrollTo stawia punkt `u` nagłówka w punkcie `u` widoku: góra = u·(V − h).
            let u = min(1, max(0, frame.minY / (viewportH - frame.height)))
            proxy.scrollTo(Self.headerID(n), anchor: UnitPoint(x: 0, y: u))
        }
    }

    private static func headerID(_ cat: String) -> String {
        "category-header-\(cat)"
    }

    // MARK: - Module row factory

    /// Zwraca odpowiedni wiersz dla bieżącego viewMode.
    @ViewBuilder
    private func moduleRow(for def: ModuleDef) -> some View {
        if viewMode == .visual {
            VisualModuleRow(
                def: def,
                isFav: isFav(def.id),
                zoom: zoom,
                contentW: scrollContentW,
                onAdd: { onAdd(def.id) },
                onToggleFav: { toggleFav(def.id) },
                onGhostMove: onGhostMove,
                onGhostEnd: onGhostEnd,
                patchLoadPreview: patchLoadPreview
            )
        } else {
            SidebarModuleRow(
                def: def,
                isFav: isFav(def.id),
                zoom: zoom,
                hoveredModuleID: $hoveredModuleID,
                onAdd: { onAdd(def.id) },
                onToggleFav: { toggleFav(def.id) },
                onGhostMove: onGhostMove,
                onGhostEnd: onGhostEnd,
                patchLoadPreview: patchLoadPreview
            )
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search modules…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onChange(of: search) { _, val in
                    if !val.isEmpty {
                        expandedCategories = Set(allCategories)
                    } else if autoCollapse {
                        expandedCategories = []
                    }
                }
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Flat search results

    @ViewBuilder
    private var flatSearchResults: some View {
        SidebarSectionHeader(
            title: "Results",
            isExpanded: .constant(true),
            accentColor: .secondary,
            canCollapse: false
        )
        ForEach(searchResults, id: \.id) { def in
            moduleRow(for: def)
        }
        if searchResults.isEmpty {
            Text("No results")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        }
    }

    // MARK: - Favorites section

    @ViewBuilder
    private var favSection: some View {
        let defs = favorites.compactMap { ModuleDatabase.module(id: $0) }
        if !defs.isEmpty {
            SidebarSectionHeader(
                title: "Favorites",
                isExpanded: $favExpanded,
                accentColor: .black
            )
            if favExpanded {
                ForEach(defs, id: \.id) { def in
                    moduleRow(for: def)
                }
            }
        }
    }

    // MARK: - All category sections

    private func allCategorySections(proxy: ScrollViewProxy, viewportH: CGFloat) -> some View {
        ForEach(allCategories, id: \.self) { cat in
            let catMods = mods(for: cat)
            if !catMods.isEmpty {
                let isExpanded = Binding<Bool>(
                    get: { expandedCategories.contains(cat) },
                    set: { exp in
                        if !exp {
                            expandedCategories.remove(cat)
                        } else if autoCollapse {
                            expandedCategories = [cat]
                        } else {
                            expandedCategories.insert(cat)
                        }
                    }
                )
                VStack(alignment: .leading, spacing: 0) {
                    SidebarSectionHeader(
                        title: cat,
                        isExpanded: isExpanded,
                        accentColor: categoryColor(cat),
                        alwaysAccented: true
                    )
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: HeaderFramesKey.self,
                                               value: [cat: geo.frame(in: .named(Self.scrollSpace))])
                    })
                    .id(Self.headerID(cat))
                    if expandedCategories.contains(cat) {
                        // Clavia oddziela grupy pustymi ToolbarIndex. Normalny odstęp
                        // ma 2 pt, a na granicy grupy łącznie 6 pt (3× więcej).
                        VStack(spacing: viewMode == .visual ? 2 : 0) {
                            ForEach(catMods, id: \.id) { def in
                                moduleRow(for: def)
                                    .padding(.top, viewMode == .visual
                                        && ModuleCatalogOrder.startsSeparatedVisualGroup(typeID: def.id, in: cat)
                                        ? 4 : 0)
                            }
                        }
                        .background(viewMode == .visual ? categoryColor(cat) : Color.clear)
                    }
                }
                .background {
                    if autoCollapse, expandedCategories.contains(cat) {
                        CategoryLeaveDetector { below in
                            collapseOnLeave(cat, below: below, proxy: proxy, viewportH: viewportH)
                        }
                    }
                }
                // Odstęp między kategoriami — bez niego paski zlewały się w jeden blok.
                .padding(.top, 3)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(ModuleDatabase.all.count) modules")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Spacer()

            // Samozwijanie kategorii po zjechaniu kursorem — włącz/wyłącz
            Button {
                autoCollapse.toggle()
                if autoCollapse {
                    withAnimation(.easeInOut(duration: 0.15)) { expandedCategories = [] }
                }
            } label: {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 11))
                    .foregroundStyle(autoCollapse ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(autoCollapse
                ? "A category closes when the pointer leaves it — click to keep categories open"
                : "Categories stay open — click to close each one when the pointer leaves it")

            Divider().frame(height: 12)

            // View mode: compact (nazwy + hover) ↔ visual (wyrenderowane moduły)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewMode = viewMode == .compact ? .visual : .compact
                }
            } label: {
                Image(systemName: viewMode.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(viewMode == .visual ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(viewMode.helpText)

            Divider().frame(height: 12)

            // Rozwiń / zwiń wszystkie kategorie
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expandedCategories.count == allCategories.count {
                        expandedCategories.removeAll()
                    } else {
                        expandedCategories = Set(allCategories)
                    }
                }
            } label: {
                Image(systemName: expandedCategories.count == allCategories.count
                    ? "rectangle.compress.vertical"
                    : "rectangle.expand.vertical")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(expandedCategories.count == allCategories.count
                ? "Collapse all categories"
                : "Expand all categories")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // MARK: - Category colors

    private func categoryColor(_ cat: String) -> Color {
        switch cat {
        case "In/Out": Color(red: 0.392, green: 0.392, blue: 0.392)
        case "Note": Color(red: 0.549, green: 0.008, blue: 0.992)
        case "Osc": Color(red: 0.792, green: 0.000, blue: 0.000)
        case "LFO": Color(red: 0.000, green: 0.000, blue: 0.792)
        case "Rnd": Color(red: 0.000, green: 0.588, blue: 0.902)
        case "Env": Color(red: 0.000, green: 0.733, blue: 0.733)
        case "Filter": Color(red: 0.000, green: 0.510, blue: 0.518)
        case "FX": Color(red: 0.918, green: 0.392, blue: 0.690)
        case "Delay": Color(red: 0.514, green: 0.349, blue: 1.000)
        case "Shaper": Color(red: 0.808, green: 0.443, blue: 0.451)
        case "Level": Color(red: 0.251, green: 0.627, blue: 0.000)
        case "Mixer": Color(red: 1.000, green: 0.502, blue: 0.251)
        case "Switch": Color(red: 0.400, green: 0.851, blue: 1.000)
        case "Logic": Color(red: 0.961, green: 0.918, blue: 0.004)
        case "Seq": Color(red: 0.996, green: 0.812, blue: 0.255)
        case "MIDI": Color(red: 0.753, green: 0.502, blue: 0.000)
        case "PM": Color(red: 0.200, green: 0.600, blue: 0.400)
        default: .secondary
        }
    }
}

// MARK: - ScrollbarFlush

/// Zeruje scrollerInsets NSScrollView aby scrollbar dotykał prawej krawędzi panelu.
/// Używa NSViewRepresentable — traweruje hierarchię widoków w górę do pierwszego NSScrollView.
private struct ScrollbarFlush: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            var cur: NSView? = v.superview
            while let node = cur {
                if let sv = node as? NSScrollView {
                    sv.scrollerInsets = NSEdgeInsetsZero
                    sv.automaticallyAdjustsContentInsets = false
                    break
                }
                cur = node.superview
            }
        }
        return v
    }

    func updateNSView(_: NSView, context _: Context) {}
}

// MARK: - Text outline helper

private extension View {
    /// Symuluje outline tekstu przez 8 kierunkowych cieni z radius=0.
    func textOutline(color: Color, width: CGFloat = 0.6) -> some View {
        self
            .shadow(color: color, radius: 0, x: -width, y: -width)
            .shadow(color: color, radius: 0, x: width, y: -width)
            .shadow(color: color, radius: 0, x: -width, y: width)
            .shadow(color: color, radius: 0, x: width, y: width)
            .shadow(color: color, radius: 0, x: 0, y: -width)
            .shadow(color: color, radius: 0, x: 0, y: width)
            .shadow(color: color, radius: 0, x: -width, y: 0)
            .shadow(color: color, radius: 0, x: width, y: 0)
    }
}

// MARK: - Section Header

struct SidebarSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    let accentColor: Color
    var canCollapse: Bool = true
    var alwaysAccented: Bool = false
    var onClear: (() -> Void)?

    @State private var hovered = false

    private var hasAccentBackground: Bool {
        isExpanded || alwaysAccented
    }

    var body: some View {
        HStack(spacing: 5) {
            if canCollapse {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hasAccentBackground ? .white : accentColor)
                    .frame(width: 10)
                    .animation(.easeInOut(duration: 0.15), value: isExpanded)
            } else {
                Spacer().frame(width: 15)
            }

            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(hasAccentBackground ? .white : .primary)
                .textOutline(color: hasAccentBackground ? .black.opacity(0.75) : .clear)

            Spacer()

            // "Wyczyść" — tylko dla sekcji z onClear, widoczny na hover
            if let clear = onClear, hovered {
                Button {
                    withAnimation { clear() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(hasAccentBackground ? .white.opacity(0.7) : .secondary)
                }
                .buttonStyle(.plain)
                .help("Clear history")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hasAccentBackground ? accentColor : Color.secondary.opacity(hovered ? 0.10 : 0.06))
        .contentShape(Rectangle())
        .onTapGesture {
            guard canCollapse else { return }
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }
        .onHover { hovered = $0 }
    }
}

// MARK: - Immediate drag (AppKit)

// NSViewRepresentable overlay: drag startuje przy pierwszym pikselu ruchu przez
// beginDraggingSession — bez SwiftUI gesture disambiguation i konkurencji ze scrollem.

private final class ImmediateDragNSView: NSView, NSDraggingSource {
    /// Współdzielona przez WSZYSTKIE instancje — blokuje hover na każdym widoku podczas draga.
    /// Instancyjna flaga nie wystarczy: inne wiersze mają isDragging=false i odpaliłyby onHover.
    static var anyDragging = false

    var typeID: Int = 0
    var shortName: String = ""
    var longName: String = ""
    var pageColor: NSColor = .gray
    var moduleHeight: Int = 1
    var zoom: CGFloat = 1.0
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onStartDrag: (() -> Void)?
    /// Wywoływane przy każdym ruchu kursora podczas draga — pozycja w ContentView coords.
    var onGhostMove: ((Int, CGPoint) -> Void)?
    /// Wywoływane gdy drag się kończy.
    var onGhostEnd: (() -> Void)?
    /// Obciążenie po dorzuceniu tego modułu — rysowane pod podglądem w palecie.
    /// `nil` = pasek wyłączony w menu.
    var patchLoadPreview: ((Int) -> (voice: G2PatchLoad?, fx: G2PatchLoad?))?

    private var trackingArea: NSTrackingArea?
    private var isDragging = false

    /// Gdy true — przy hover pokazuje NSPanel z podglądem modułu obok kursora.
    /// Używane tylko w trybie compact (visual pokazuje obrazki inline).
    var showHoverPreview: Bool = false

    /// Jeden panel współdzielony przez WSZYSTKIE instancje — zapobiega mnożeniu paneli podczas scrollu.
    /// Scroll przesuwa nowe wiersze pod kursor → każdy odpala mouseEntered → każda instancja
    /// nadpisuje ten sam static, zamykając panel poprzednika.
    private static var sharedHoverPanel: NSWindow?
    /// Blokuje mouseEntered podczas scrollu — resetowany po 0.3s od ostatniego scroll eventu.
    private static var isScrolling = false
    private static var scrollResetWork: DispatchWorkItem?

    /// Pływające okno zastępujące natywny drag image AppKit.
    /// AppKit automatycznie skaluje drag image gdy kursor opuszcza source view —
    /// nie da się tego wyłączyć. Rozwiązanie: 1×1 przezroczysty obraz dla AppKit (brak wizualizacji),
    /// a własny NSPanel śledzi kursor i pokazuje pełnowymiarowy podgląd modułu.
    private var dragFloatWindow: NSWindow?
    private var dragPreviewSize: NSSize = .zero

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !ImmediateDragNSView.anyDragging, !ImmediateDragNSView.isScrolling else { return }
        onHover?(true)
        if showHoverPreview { showHoverPanel(mouseInWindow: event.locationInWindow) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard showHoverPreview, ImmediateDragNSView.sharedHoverPanel != nil else { return }
        updateHoverPanelPosition(mouseInWindow: event.locationInWindow)
    }

    override func mouseExited(with _: NSEvent) {
        guard !ImmediateDragNSView.anyDragging else { return }
        onHover?(false)
        hideHoverPanel()
    }

    override func scrollWheel(with event: NSEvent) {
        // Scroll: ukryj panel i zablokuj mouseEntered przez 0.3s (czas animacji scrollu).
        // Bez blokady: nowe wiersze scrollujące pod kursor odpalaJą mouseEntered → mnożą panele.
        ImmediateDragNSView.hideSharedHoverPanel()
        ImmediateDragNSView.isScrolling = true
        ImmediateDragNSView.scrollResetWork?.cancel()
        let work = DispatchWorkItem { ImmediateDragNSView.isScrolling = false }
        ImmediateDragNSView.scrollResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        super.scrollWheel(with: event)
    }

    // MARK: Hover preview panel

    private func showHoverPanel(mouseInWindow: NSPoint) {
        ImmediateDragNSView.hideSharedHoverPanel()
        guard let img = ModulePreviewCache.shared.images[typeID] else { return }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: img.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.hasShadow = true

        let iv = NSImageView(frame: NSRect(origin: .zero, size: img.size))
        iv.image = img
        iv.imageScaling = .scaleNone
        panel.contentView = iv

        ImmediateDragNSView.sharedHoverPanel = panel
        updateHoverPanelPosition(mouseInWindow: mouseInWindow)
        panel.orderFront(nil)
    }

    /// Przesuwa panel podglądu tak aby jego lewy górny róg był przy kursorze myszy.
    private func updateHoverPanelPosition(mouseInWindow: NSPoint) {
        guard let panel = ImmediateDragNSView.sharedHoverPanel else { return }
        let screenMouse = window?.convertPoint(toScreen: mouseInWindow) ?? NSEvent.mouseLocation
        // Lewy górny róg panelu = pozycja kursora (NSScreen: y=0 u dołu → odejmij wysokość)
        panel.setFrameOrigin(NSPoint(x: screenMouse.x, y: screenMouse.y - panel.frame.height))
    }

    private func hideHoverPanel() {
        ImmediateDragNSView.hideSharedHoverPanel()
    }

    private static func hideSharedHoverPanel() {
        sharedHoverPanel?.orderOut(nil)
        sharedHoverPanel = nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point is in SUPERVIEW coordinate space; bounds is in VIEW coordinate space.
        // Only point.x is safe to compare with bounds.width (both use the same x scale
        // when frame.origin.x == 0, which it is for full-width rows in a VStack).
        // super.hitTest handles full coordinate conversion for the containment check.
        if bounds.width > 30, point.x >= bounds.width - 30 { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        isDragging = true
        ImmediateDragNSView.anyDragging = true
        hideHoverPanel() // zamknij podgląd hover przed startem draga
        onStartDrag?()

        // Pobierz pełny obraz modułu (z cache lub rysuj)
        let preview = ModulePreviewCache.shared.images[typeID] ?? buildPreviewImage()
        // Pasek z obciążeniem siedzi POD obrazkiem, więc okno jest o niego wyższe —
        // a kursor i tak trzyma się lewego górnego rogu samego modułu.
        let loadStrip = buildLoadStripView(width: preview.size.width)
        dragPreviewSize = NSSize(
            width: preview.size.width,
            height: preview.size.height + (loadStrip?.frame.height ?? 0)
        )

        // --- Pływające okno z podglądem modułu ---
        // Zastępuje natywny drag image AppKit (który skaluje obraz poza source view).
        // NSPanel: borderless, non-activating, ignoruje mysz, poziom floating+1.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: dragPreviewSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.hasShadow = true

        // Obrazek na górze, pasek pod nim (NSView nie jest flipped → y=0 u dołu).
        let content = NSView(frame: NSRect(origin: .zero, size: dragPreviewSize))
        let stripH = loadStrip?.frame.height ?? 0
        let iv = NSImageView(frame: NSRect(x: 0, y: stripH,
                                           width: preview.size.width, height: preview.size.height))
        iv.image = preview
        iv.imageScaling = .scaleNone
        content.addSubview(iv)
        if let loadStrip { content.addSubview(loadStrip) }
        panel.contentView = content

        // Pozycja: lewy górny róg = pozycja kursora (ekran, NSScreen: y=0 u dołu)
        let screenPt = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        // NSWindow.origin = lewy dolny róg → przesuń o wysokość CAŁEGO okna w górę
        let origin = NSPoint(x: screenPt.x, y: screenPt.y - dragPreviewSize.height)
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        dragFloatWindow = panel

        // --- Dla AppKit: 1×1 przezroczysty obraz — tylko transfer danych, zero wizualizacji ---
        let transparent = NSImage(size: NSSize(width: 1, height: 1))
        let pb = NSPasteboardItem()
        pb.setString("\(typeID)", forType: .string)
        let draggingItem = NSDraggingItem(pasteboardWriter: pb)
        let mouseInView = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(
            CGRect(x: mouseInView.x, y: mouseInView.y, width: 1, height: 1),
            contents: transparent
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    /// Pasek z obciążeniem PO dorzuceniu tego modułu — pod podglądem w palecie.
    ///
    /// Szerokość równa szerokości ciała modułu w podglądzie (bez marginesu canvasu),
    /// więc skala bierze się z podziału tej szerokości przez naturalną szerokość paska.
    /// `nil`, gdy przełącznik w menu jest wyłączony.
    ///
    /// NSHostingView działa tu, bo panel jest oknem — inaczej niż przy rysowaniu obrazu
    /// drag image, gdzie trzeba było zejść do AppKit (patrz `buildPreviewImage`).
    private func buildLoadStripView(width fullWidth: CGFloat) -> NSView? {
        guard let load = patchLoadPreview?(typeID) else { return nil }
        let z: CGFloat = 2.0
        let bodyWidth = PatchLayout.moduleWidth * z
        let scale = PatchLoadMetrics.previewScale(fittingWidth: bodyWidth)
        // Odstęp nad i pod miernikami — bez niego liczby siedzą na krawędzi tła.
        let height = PatchLoadMetrics.previewHeight * scale + 8

        let root = PatchLoadReadout(
            voice: load.voice, fx: load.fx, layout: .preview, scale: scale, labelColor: .white
        )
        .frame(width: fullWidth, height: height)
        .background(Color.black.opacity(0.80))

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: fullWidth, height: height)
        return hosting
    }

    /// OS drag image — rysowany przez AppKit (ImageRenderer/NSHostingView nie działają
    /// poza hierarchy okna). Wygląd identyczny jak na canvasie: ciemne tło, szary panel,
    /// kolorowy nagłówek z nazwą, ramka 3D.
    private func buildPreviewImage() -> NSImage {
        // Zawsze zoom=2.0 — spójne z ModulePreviewCache, niezależne od aktualnego canvasZoom.
        // Wcześniej używało `zoom` (= canvasZoom) co dawało mały obraz przy zoomie < 2.0.
        let z: CGFloat = 2.0
        let pad = PatchLayout.padding * z
        let modW = PatchLayout.moduleWidth * z
        let modH = CGFloat(moduleHeight) * PatchLayout.ySpan * z
        let headerH = PatchLayout.headerH * z
        let sz = NSSize(width: modW + 2 * pad, height: modH + 2 * pad)

        let image = NSImage(size: sz)
        // lockFocusFlipped(true) = y=0 u góry (jak SwiftUI/Canvas)
        image.lockFocusFlipped(true)

        // 1. Tło canvasu — ciemny szary
        NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.16, alpha: 1).setFill()
        NSRect(origin: .zero, size: sz).fill()

        // 2. Ciało modułu — szary panel
        let modRect = NSRect(x: pad, y: pad, width: modW, height: modH)
        NSColor(calibratedRed: 0.741, green: 0.741, blue: 0.741, alpha: 1).setFill()
        modRect.fill()

        // 3. Pasek nagłówka — kolor kategorii, na górze modułu
        let hRect = NSRect(x: pad, y: pad, width: modW, height: headerH)
        pageColor.setFill()
        hRect.fill()

        // Cienka jasna linia na górze nagłówka (highlight)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSRect(x: pad, y: pad, width: modW, height: 0.5 * z).fill()

        // 4. Nazwa modułu
        let fontSize = min(headerH * 0.62, 5.5 * z)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(4, fontSize), weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let nameStr = NSAttributedString(string: shortName, attributes: attrs)
        nameStr.draw(at: NSPoint(x: pad + 3 * z,
                                 y: pad + (headerH - fontSize) * 0.5))

        // 5. Ramka 3D — lw proporcjonalne do zoom
        let lw = max(0.5, 0.7 * z)
        let half = lw / 2
        let x1 = modRect.minX + half, y1 = modRect.minY + half
        let x2 = modRect.maxX - half, y2 = modRect.maxY - half

        // Górna + lewa (jasna)
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let hl = NSBezierPath()
        hl.lineWidth = lw
        hl.move(to: NSPoint(x: x1, y: y1))
        hl.line(to: NSPoint(x: x2, y: y1)) // góra
        hl.move(to: NSPoint(x: x1, y: y1))
        hl.line(to: NSPoint(x: x1, y: y2)) // lewa
        hl.stroke()

        // Dolna + prawa (cień)
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let sh = NSBezierPath()
        sh.lineWidth = lw
        sh.move(to: NSPoint(x: x1, y: y2))
        sh.line(to: NSPoint(x: x2, y: y2)) // dół
        sh.move(to: NSPoint(x: x2, y: y1))
        sh.line(to: NSPoint(x: x2, y: y2)) // prawa
        sh.stroke()

        image.unlockFocus()
        return image
    }

    func draggingSession(_: NSDraggingSession,
                         sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation
    {
        .copy
    }

    /// Śledzi pozycję kursora podczas całego draga.
    /// Sidebar: pływające okno widoczne, ghost ukryty.
    /// Canvas: pływające okno ukryte, ghost widoczny.
    func draggingSession(_: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let window, let cv = window.contentView else { return }
        // Punkt sesji opisuje ruch draga, ale tylko mouseLocation jest bieżącym
        // położeniem szczytu systemowego kursora niezależnym od ramki drag image.
        let mouseScreenPoint = NSEvent.mouseLocation
        let cursorScreenPoint = mouseScreenPoint.x.isFinite && mouseScreenPoint.y.isFinite
            ? mouseScreenPoint
            : screenPoint
        let windowPoint = window.convertPoint(fromScreen: cursorScreenPoint)
        let sourceInWindow = self.convert(bounds, to: nil)
        let cursorInSidebar = windowPoint.x <= sourceInWindow.maxX

        if cursorInSidebar {
            // Kursor w sidebarze — pokaż panel, przesuń go za kursorem, wyczyść ghost
            let floatOrigin = NSPoint(
                x: cursorScreenPoint.x,
                y: cursorScreenPoint.y - dragPreviewSize.height
            )
            if dragFloatWindow?.isVisible == false { dragFloatWindow?.orderFront(nil) }
            dragFloatWindow?.setFrameOrigin(floatOrigin)
            DispatchQueue.main.async { [weak self] in self?.onGhostEnd?() }
        } else {
            // Kursor na canvasie — ukryj panel, pokaż ghost overlay
            if dragFloatWindow?.isVisible == true { dragFloatWindow?.orderOut(nil) }
            let cvPoint = cv.convert(windowPoint, from: nil)
            let swiftuiY = cv.isFlipped ? cvPoint.y : cv.bounds.height - cvPoint.y
            // window.contentView obejmuje także bezpieczny obszar pod paskiem
            // tytułu/narzędzi, a korzeń SwiftUI zaczyna się dopiero pod nim.
            // Bez tej korekty ghost był niżej od kursora dokładnie o top inset.
            let safeInsets = cv.safeAreaInsets
            let pt = CGPoint(
                x: cvPoint.x - safeInsets.left,
                y: swiftuiY - safeInsets.top
            )
            onGhostMove?(typeID, pt)
        }
    }

    /// Drag zakończony — zamknij pływające okno podglądu i wyczyść ghost.
    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint,
                         operation _: NSDragOperation)
    {
        // Zamknij i zwolnij pływające okno podglądu
        dragFloatWindow?.orderOut(nil)
        dragFloatWindow = nil

        isDragging = false
        ImmediateDragNSView.anyDragging = false
        // Otwarta kategoria sprawdza, czy kursor jest jeszcze nad nią — jeśli nie, zwija się.
        NotificationCenter.default.post(name: .sidebarModuleDragEnded, object: nil)
        onHover?(false)
        DispatchQueue.main.async { [weak self] in
            self?.onGhostEnd?()
        }
    }
}

private struct ImmediateDragOverlay: NSViewRepresentable {
    // zoom przekazywany jako prop (nie @Environment) — SwiftUI woła updateNSView
    // gdy prop się zmieni, co gwarantuje aktualny zoom w NSView podczas draga.
    let zoom: CGFloat
    let typeID: Int
    let shortName: String
    let longName: String
    let pageColor: NSColor
    let moduleHeight: Int
    /// Gdy true — hover pokazuje NSPanel z podglądem modułu (tylko tryb compact).
    var showHoverPreview: Bool = false
    let onDoubleClick: () -> Void
    let onHover: (Bool) -> Void
    let onStartDrag: () -> Void
    var onGhostMove: ((Int, CGPoint) -> Void)?
    var onGhostEnd: (() -> Void)?
    var patchLoadPreview: ((Int) -> (voice: G2PatchLoad?, fx: G2PatchLoad?))?

    func makeNSView(context _: Context) -> ImmediateDragNSView {
        apply(to: ImmediateDragNSView())
    }

    func updateNSView(_ v: ImmediateDragNSView, context _: Context) {
        _ = apply(to: v)
    }

    @discardableResult
    private func apply(to v: ImmediateDragNSView) -> ImmediateDragNSView {
        v.typeID = typeID
        v.shortName = shortName
        v.longName = longName
        v.pageColor = pageColor
        v.moduleHeight = moduleHeight
        v.zoom = zoom
        v.showHoverPreview = showHoverPreview
        v.onDoubleClick = onDoubleClick
        v.onHover = onHover
        v.onStartDrag = onStartDrag
        v.onGhostMove = onGhostMove
        v.onGhostEnd = onGhostEnd
        v.patchLoadPreview = patchLoadPreview
        return v
    }
}

// MARK: - Module Row (compact)

struct SidebarModuleRow: View {
    let def: ModuleDef
    let isFav: Bool
    let zoom: CGFloat // prop (nie env) — SwiftUI woła updateNSView przy zmianie
    /// Wspólny dla całego sidebaru — gwarantuje max jedno podświetlenie naraz.
    @Binding var hoveredModuleID: Int?
    let onAdd: () -> Void
    let onToggleFav: () -> Void
    var onGhostMove: ((Int, CGPoint) -> Void)?
    var onGhostEnd: (() -> Void)?
    var patchLoadPreview: ((Int) -> (voice: G2PatchLoad?, fx: G2PatchLoad?))?

    private var hovered: Bool {
        hoveredModuleID == def.id
    }

    var body: some View {
        HStack(spacing: 0) {
            // Kolorowy pasek kategorii (4pt)
            Rectangle()
                .fill(categoryColor)
                .frame(width: 4)

            // Informacja o module
            VStack(alignment: .leading, spacing: 2) {
                Text(def.shortName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(def.longName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 8)
            .padding(.vertical, 5)

            Spacer()

            // Przycisk gwiazdki — widoczny na hover lub gdy ulubiony
            if hovered || isFav {
                Button { onToggleFav() } label: {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundStyle(isFav ? Color.yellow : Color.secondary.opacity(0.5))
                        .symbolEffect(.bounce, value: isFav)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .background(hovered ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .overlay(
            ImmediateDragOverlay(
                zoom: zoom,
                typeID: def.id,
                shortName: def.shortName,
                longName: def.longName,
                pageColor: NSColor(categoryColor),
                moduleHeight: def.height,
                showHoverPreview: true,
                onDoubleClick: onAdd,
                onHover: { h in
                    if h {
                        hoveredModuleID = def.id
                    } else {
                        if hoveredModuleID == def.id { hoveredModuleID = nil }
                    }
                },
                onStartDrag: {
                    if hoveredModuleID == def.id { hoveredModuleID = nil }
                },
                onGhostMove: onGhostMove,
                onGhostEnd: onGhostEnd,
                patchLoadPreview: patchLoadPreview
            )
        )
    }

    private var categoryColor: Color {
        switch def.page {
        case "In/Out": Color(red: 0.392, green: 0.392, blue: 0.392)
        case "Note": Color(red: 0.549, green: 0.008, blue: 0.992)
        case "Osc": Color(red: 0.792, green: 0.000, blue: 0.000)
        case "LFO": Color(red: 0.000, green: 0.000, blue: 0.792)
        case "Rnd": Color(red: 0.000, green: 0.588, blue: 0.902)
        case "Env": Color(red: 0.000, green: 0.733, blue: 0.733)
        case "Filter": Color(red: 0.000, green: 0.510, blue: 0.518)
        case "FX": Color(red: 0.918, green: 0.392, blue: 0.690)
        case "Delay": Color(red: 0.514, green: 0.349, blue: 1.000)
        case "Shaper": Color(red: 0.808, green: 0.443, blue: 0.451)
        case "Level": Color(red: 0.251, green: 0.627, blue: 0.000)
        case "Mixer": Color(red: 1.000, green: 0.502, blue: 0.251)
        case "Switch": Color(red: 0.400, green: 0.851, blue: 1.000)
        case "Logic": Color(red: 0.961, green: 0.918, blue: 0.004)
        case "Seq": Color(red: 0.996, green: 0.812, blue: 0.255)
        case "MIDI": Color(red: 0.753, green: 0.502, blue: 0.000)
        default: .secondary
        }
    }
}

// MARK: - Loading cursor

/// Kręcące się kółko na kursorze nad biblioteką modułów, dopóki nie wszystkie podglądy
/// są gotowe (prośba użytkownika 2026-10-09). Gotowość sprawdza zegar, nie `body` —
/// odczyt `isComplete` w `body` przerysowywałby cały pasek przy każdym obrazku.
@MainActor
private final class LoadingCursor {
    static let shared = LoadingCursor()

    private var timer: Timer?
    private var step = 0
    private static let frames: [NSCursor] = (0 ..< 12).map(makeFrame)

    /// Kursor wszedł albo ruszył się nad biblioteką.
    func show() {
        guard !ModulePreviewCache.shared.isComplete else { return hide() }
        Self.frames[step].set()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { _ in
            MainActor.assumeIsolated { LoadingCursor.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        NSCursor.arrow.set()
    }

    private func tick() {
        guard !ModulePreviewCache.shared.isComplete else { return hide() }
        step = (step + 1) % Self.frames.count
        Self.frames[step].set()
    }

    /// Klatka kółka: 12 szprych, najjaśniejsza na pozycji `step`, za nią coraz bledsze.
    private static func makeFrame(_ step: Int) -> NSCursor {
        let side: CGFloat = 22
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let centre = NSPoint(x: rect.midX, y: rect.midY)
            for spoke in 0 ..< 12 {
                let angle = CGFloat.pi / 2 - CGFloat(spoke) * .pi / 6
                let age = CGFloat((step - spoke + 12) % 12)
                let dir = NSPoint(x: cos(angle), y: sin(angle))
                let path = NSBezierPath()
                path.move(to: NSPoint(x: centre.x + dir.x * 4.5, y: centre.y + dir.y * 4.5))
                path.line(to: NSPoint(x: centre.x + dir.x * 9, y: centre.y + dir.y * 9))
                path.lineCapStyle = .round
                // Biała obwódka — kółko ma być widać także na ciemnym tle modułów.
                path.lineWidth = 4.5
                NSColor.white.withAlphaComponent(0.9).setStroke()
                path.stroke()
                path.lineWidth = 2.5
                NSColor(white: 0.15, alpha: 1 - age / 12 * 0.85).setStroke()
                path.stroke()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}

// MARK: - Visual module row

/// Wiersz w trybie visual — pokazuje wyrenderowany NSImage z ModulePreviewCache;
/// dopóki go nie ma, puste miejsce w rozmiarze modułu.
/// Obsługuje AppKit drag (ghost) identycznie jak SidebarModuleRow.
struct VisualModuleRow: View {
    let def: ModuleDef
    let isFav: Bool
    let zoom: CGFloat
    var contentW: CGFloat = 292
    let onAdd: () -> Void
    let onToggleFav: () -> Void
    var onGhostMove: ((Int, CGPoint) -> Void)?
    var onGhostEnd: (() -> Void)?
    var patchLoadPreview: ((Int) -> (voice: G2PatchLoad?, fx: G2PatchLoad?))?

    @State private var hovered = false

    var body: some View {
        let img = ModulePreviewCache.shared.image(forTypeID: def.id)
        let exactH = CGFloat(def.height) * PatchLayout.ySpan * 2.0
        // H1 (NameBar) — mniejsza gwiazdka żeby mieściła się w cienkiej wysokości modułu.
        let starSize: CGFloat = def.height == 1 ? 8 : 11
        let starPad: CGFloat = def.height == 1 ? 2 : 5

        HStack(spacing: 0) {
            // Kolorowy pasek kategorii (4pt) — lewa krawędź
            Rectangle()
                .fill(categoryColor)
                .frame(width: 4)

            ZStack(alignment: .topTrailing) {
                if let img {
                    // Wyrenderowany NSImage (off-screen NSWindow) — 1:1 (skala 100%).
                    // capPad=1pt dodaje ciemne tło do każdej krawędzi — clip do exactH usuwa je z góry/dołu.
                    // imgW = contentW - 4 (lewy) - 4 (prawy) = contentW - 8.
                    let imgW = min(img.size.width, max(1, contentW - 8))
                    Image(nsImage: img)
                        .frame(width: imgW, height: exactH)
                        .clipped()
                } else {
                    // Podgląd jeszcze się rysuje: puste miejsce w rozmiarze modułu, żeby
                    // lista nie skakała, gdy obrazki wskakują po kolei od góry.
                    Color.clear
                }

                // Gwiazdka ulubionych — jako overlay żeby nie wpływała na wysokość ZStack.
                // Nieaktywna (hover): szare wypełnienie + czarny obrys.
                // Aktywna (isFav):    żółte wypełnienie + czarny obrys.
                if hovered || isFav {
                    Button { onToggleFav() } label: {
                        ZStack {
                            Image(systemName: "star.fill")
                                .font(.system(size: starSize))
                                .foregroundStyle(isFav ? Color.yellow : Color(white: 0.55))
                            Image(systemName: "star")
                                .font(.system(size: starSize))
                                .foregroundStyle(Color.black.opacity(0.7))
                        }
                        .symbolEffect(.bounce, value: isFav)
                    }
                    .buttonStyle(.plain)
                    .padding(starPad)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            // Kluczowe: ZStack nie może rosnąć ponad wysokość modułu —
            // bez tego gwiazdka (gdy pojawia się przy hover) rozpycha sąsiednie wiersze.
            .frame(height: exactH)
            .clipped()

            // Kolorowy pasek kategorii (4pt) — prawa krawędź
            Rectangle()
                .fill(categoryColor)
                .frame(width: 4)
        }
        .contentShape(Rectangle())
        .background(hovered ? Color.accentColor.opacity(0.12) : Color.clear)
        // AppKit drag overlay — ghost identyczny jak w trybie compact
        .overlay(
            ImmediateDragOverlay(
                zoom: zoom,
                typeID: def.id,
                shortName: def.shortName,
                longName: def.longName,
                pageColor: NSColor(categoryColor),
                moduleHeight: def.height,
                onDoubleClick: onAdd,
                onHover: { h in withAnimation(.easeInOut(duration: 0.1)) { hovered = h } },
                onStartDrag: {},
                onGhostMove: onGhostMove,
                onGhostEnd: onGhostEnd,
                patchLoadPreview: patchLoadPreview
            )
        )
    }

    private var categoryColor: Color {
        switch def.page {
        case "In/Out": Color(red: 0.392, green: 0.392, blue: 0.392)
        case "Note": Color(red: 0.549, green: 0.008, blue: 0.992)
        case "Osc": Color(red: 0.792, green: 0.000, blue: 0.000)
        case "LFO": Color(red: 0.000, green: 0.000, blue: 0.792)
        case "Rnd": Color(red: 0.000, green: 0.588, blue: 0.902)
        case "Env": Color(red: 0.000, green: 0.733, blue: 0.733)
        case "Filter": Color(red: 0.000, green: 0.510, blue: 0.518)
        case "FX": Color(red: 0.918, green: 0.392, blue: 0.690)
        case "Delay": Color(red: 0.514, green: 0.349, blue: 1.000)
        case "Shaper": Color(red: 0.808, green: 0.443, blue: 0.451)
        case "Level": Color(red: 0.251, green: 0.627, blue: 0.000)
        case "Mixer": Color(red: 1.000, green: 0.502, blue: 0.251)
        case "Switch": Color(red: 0.400, green: 0.851, blue: 1.000)
        case "Logic": Color(red: 0.961, green: 0.918, blue: 0.004)
        case "Seq": Color(red: 0.996, green: 0.812, blue: 0.255)
        case "MIDI": Color(red: 0.753, green: 0.502, blue: 0.000)
        default: .secondary
        }
    }
}

// MARK: - Module drag preview

/// Renderuje pojedynczy moduł dokładnie tak jak PatchCanvasView — używany jako OS drag image.
/// Tworzy minimalny G2Patch z jednym modułem i renderuje przez ten sam kod co canvas.
struct ModulePreviewCanvas: View {
    let typeID: Int
    let zoom: CGFloat

    private var previewModule: G2Module {
        var m = G2Module(id: 0, typeID: typeID, area: .voice)
        // Domyślne parametry z ModuleDefaultsDatabase — knobs w prawidłowych pozycjach
        let defaults = ModuleDefaultsDatabase.defaults(forTypeID: typeID)
        if let def = ModuleDatabase.module(id: typeID) {
            m.parameters = defaults.isEmpty
                ? Array(repeating: 0, count: def.paramNames.count)
                : defaults
            m.modes = Array(repeating: 0, count: def.modeNames.count)
        }
        return m
    }

    private var previewPatch: G2Patch {
        var p = G2Patch()
        p.voiceModules = [previewModule]
        return p
    }

    private var frameSize: CGSize {
        let def = ModuleDatabase.module(id: typeID)
        let modH = CGFloat(def?.height ?? 2) * PatchLayout.ySpan
        let pad = PatchLayout.padding
        return CGSize(
            width: (PatchLayout.moduleWidth + 2 * pad) * zoom,
            height: (modH + 2 * pad) * zoom
        )
    }

    var body: some View {
        let sz = frameSize
        // PatchCanvasView jako pełny SwiftUI view (isPreviewMode=true pomija DropTarget i hover).
        // Musi być właściwym SwiftUI view w hierarchii — tylko wtedy @State i Canvas działają
        // poprawnie. previewBody (metoda na struct) miała problemy z inicjalizacją @State.
        PatchCanvasView(patch: previewPatch, area: .voice, zoom: zoom, minSize: sz,
                        isPreviewMode: true)
            .frame(width: sz.width, height: sz.height, alignment: .topLeading)
            .clipped()
    }
}
