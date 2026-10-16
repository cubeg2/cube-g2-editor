// PanelController.swift
// Jeden system dla WSZYSTKICH paneli edytora — punkt 0.1 planu udoskonaleń.
//
// Powód, dla którego to jest osobna klasa, a nie `@State` w widoku: każdy kolejny panel
// (biblioteka modułów, przeglądarka patchy, obciążenie DSP, klawiatura…) kusi, żeby
// dorobić mu własny przełącznik i własne miejsce w oknie. Po trzech takich panelach nie
// da się już powiedzieć, który jest otwarty ani czemu dwa zasłaniają się nawzajem.
//
// Panel ma jedno z dwóch miejsc — i to miejsce wynika z tego, DO CZEGO służy:
//
//   • szuflada z lewej (`drawer`) — rzeczy, z których się WYBIERA i przeciąga na patch:
//     biblioteka modułów i przeglądarka patchy. Obie zajmują ten sam pas ekranu, więc
//     wysunięta jest **dokładnie jedna** — kto szuka patcha, nie szuka w tej chwili modułu.
//   • pływające okno (`window`) — rzeczy, których używa się PRZY patchu i które chce się
//     mieć pod ręką w wybranym miejscu ekranu (klawiatura, obciążenie DSP).
//     Okien może być otwartych ile się chce; nie zabierają miejsca canvasowi.
//
// Wariacje panelem NIE są: pasek 1–8 siedzi w górnej belce, tak jak w oryginale
// (`VariationBarView`) — bez niego nie da się odczytać gałek.
//
// Stan (co wysunięte, jakie okna, jaka szerokość) należy do APLIKACJI, nie do patcha —
// nie zapisuje się do `.pch2` ani do żadnego sidecara, tylko do `UserDefaults`.

import CoreGraphics
import Foundation
import G2Core
import Observation

@MainActor
@Observable
public final class PanelController {
    /// Panele edytora. Kolejność `allCases` jest kolejnością skrótów `⌘⌥1`…`⌘⌥9`.
    public enum Panel: String, CaseIterable, Identifiable, Sendable {
        case modules
        case banks
        case dsp
        case keyboard
        case parameterPages
        case mutator
        case parameterOverview
        case patchAdjuster
        case colors
        /// Spektrogram na żywo z emulatora — okno albo tło kanwy. Bez emulatora nie ma
        /// czego pokazać, więc przycisk w belce jest wtedy wyszarzony.
        case spectrogram
        /// Wykres X-Y (goniometr) dźwięku emulatora — lewy kanał w poziomie, prawy w pionie.
        /// Jak spektrogram: bez emulatora przycisk w belce jest wyszarzony.
        case xyPlot
        /// Drzewo ewolucji Mutatora w osobnym oknie — otwierane przyciskiem „Window" w panelu
        /// Mutation settings, nie z belki ani z menu (to okno pomocnicze Mutatora).
        case mutatorTree

        /// Szerokość pasa szuflad. **Obie szuflady zajmują ten sam pas ekranu**, więc mają
        /// tę samą szerokość — a bierze się ona z biblioteki modułów z podglądami, bo tam
        /// wynika z rozmiaru samego podglądu modułu i nie da się jej wybrać dowolnie.
        public static let drawerWidth: CGFloat = 292

        public var id: String {
            rawValue
        }

        public var placement: Placement {
            switch self {
            case .modules, .banks: .drawer
            default: .window
            }
        }

        /// Nazwa w dymku i w menu View. **Po angielsku** — to interfejs użytkownika.
        ///
        /// „Patches", nie „Banks": panel pokazuje patche z pamięci Norda i z folderu na
        /// dysku, a użytkownik szuka w nim patcha, nie banku.
        public var title: String {
            switch self {
            case .modules: "Modules"
            case .banks: "Patches"
            case .dsp: "DSP Load"
            case .keyboard: "Virtual Keyboard"
            case .parameterPages: "Parameter Pages"
            case .mutator: "Patch Mutator"
            case .parameterOverview: "Parameter Overview"
            case .patchAdjuster: "Patch Adjuster"
            case .colors: "Colors"
            case .spectrogram: "Spectrum"
            case .xyPlot: "X-Y Plot"
            case .mutatorTree: "Evolution Tree"
            }
        }

        /// Symbol SF na przycisku w pasku narzędzi.
        public var symbol: String {
            switch self {
            case .modules: "sidebar.leading"
            case .banks: "square.stack.3d.up.fill"
            case .dsp: "bolt.fill"
            case .keyboard: "pianokeys"
            case .parameterPages: "dial.medium"
            case .mutator: "dice"
            case .parameterOverview: "square.grid.3x3"
            case .patchAdjuster: "slider.horizontal.3"
            // ⚠️ NIE `paintbucket` — tego symbolu NIE MA na macOS 15 (wchodzi dopiero
            // w 26), a `Image(systemName:)` na nieznaną nazwę rysuje NIC, bez słowa
            // ostrzeżenia. Kropla farby jest od macOS 11 i wygląda tak samo na obu
            // Makach → [[Docs/ui/top-bar]].
            case .colors: "drop.fill"
            // `waveform` jest od macOS 11 — sprawdzone na obu Makach. Fala pasma,
            // nie `waveform.path.ecg`: ten siedzi już na „shake cables".
            case .spectrogram: "waveform"
            // Celownik — osie X i Y przez środek, jak na samym wykresie. Od macOS 11.
            case .xyPlot: "scope"
            case .mutatorTree: "arrow.triangle.branch"
            }
        }

        /// Klawisz skrótu (z ⌘⌥). Ten sam skrót zamyka to, co otworzył.
        public var shortcutKey: Character {
            switch self {
            case .modules: "1"
            case .banks: "2"
            case .dsp: "3"
            case .keyboard: "4"
            case .parameterPages: "5"
            case .mutator: "6"
            case .parameterOverview: "7"
            case .patchAdjuster: "8"
            case .colors: "9"
            case .spectrogram: "0"
            case .xyPlot: "x"
            // Bez skrótu i bez pozycji w menu — okno otwiera panel Mutatora. Ta sama
            // litera co spektrogram nie szkodzi: skrótu nabiera dopiero panel z menu.
            case .mutatorTree: "0"
            }
        }

        /// Szerokość, z jaką panel otwiera się po raz pierwszy. Obie szuflady biorą
        /// wspólną `drawerWidth` — biblioteka modułów zwęża się sama, gdy przełączy się
        /// ją w tryb listy.
        var defaultWidth: CGFloat {
            switch self {
            case .modules, .banks: Self.drawerWidth
            case .dsp: 260
            case .keyboard: 740
            case .parameterPages: 530
            case .mutator: 496
            case .parameterOverview: 530
            case .patchAdjuster: 530
            case .colors: 217
            // Spectrum szersze: opcje leżą poziomo i przy 640 mieszczą się w dwóch rzędach.
            case .spectrogram: 640
            case .xyPlot: 300
            case .mutatorTree: 420
            }
        }

        /// Czy panel potrzebuje focusu klawiatury. Tylko Patch Mutator — ma własne
        /// skróty (`E`, `U`, `N`, `1`–`8`…). Reszta okien nie przejmuje focusu, dzięki
        /// czemu główne okno zostaje kluczowe i menu (New Patch, Open…) działa dalej.
        public var needsKeyboardFocus: Bool {
            self == .mutator
        }

        /// Panele o **stałym rozmiarze okna**: ich zawartość jest siatką o z góry
        /// znanych wymiarach (kratki mutatora, klawisze), więc zmniejszanie okna
        /// mogłoby ją tylko przyciąć. `nil` = okno zmienia rozmiar swobodnie.
        public var fixedWindowSize: CGSize? {
            switch self {
            case .parameterPages: CGSize(width: 530, height: 144)
            case .mutator: CGSize(width: 496, height: 492)
            // Belka 22 + klamra 12 + klawisze 64 + odstępy i marginesy → patrz `KeyboardPanel`.
            case .keyboard: CGSize(width: 740, height: 128)
            case .parameterOverview: CGSize(width: 530, height: 765)
            case .patchAdjuster: CGSize(width: 530, height: 84)
            // Siatka 6 × 4 próbek z paskiem pod spodem i marginesem 12 pt dookoła — patrz
            // `ColorsPanel`. Do 2026-09-27 okno było 232 × 190: pusty pas z prawej i u dołu.
            case .colors: CGSize(width: 217, height: 176)
            default: nil
            }
        }

        /// Wysokość okna panelu przy pierwszym otwarciu — dla paneli o stałym
        /// rozmiarze to po prostu ich wysokość.
        public var defaultWindowHeight: CGFloat {
            fixedWindowSize?.height ?? (squareWindowFooter.map { defaultWidth + $0 } ?? 420)
        }

        /// Okno z kwadratem na górze, przy każdym powiększeniu — wykres X-Y ma dwie osie tej
        /// samej skali. Wysokość = szerokość + ten stały pas pod kwadratem (mierniki
        /// i opcje); `nil` = okno bez tej reguły. W odróżnieniu od `scalesProportionally`
        /// treść się NIE powiększa jak obrazek, tylko układa na nowo.
        public var squareWindowFooter: CGFloat? {
            guard self == .xyPlot else { return nil }
            return Self.xyPlotFooter(optionsShown: UserDefaults.standard.bool(forKey: Self.xyPlotOptionsKey))
        }

        /// Opcje X-Y (kropki/linie, pauza, Length, Fade, Colors) chowają się pod przyciskiem obok
        /// „Input" (od 2026-09-27; wcześniej zawsze widoczne, pas stały 140 pt).
        public static let xyPlotOptionsKey = "xyPlotOptionsShown"

        /// Pas X-Y: wiersz Input + trzy mierniki (74), z opcjami o 92 wyżej (od 2026-09-28
        /// cztery rzędy — doszedł suwak Colors). Z marginesem 12 u dołu, żeby znacznik
        /// skalowania w rogu nie wchodził na podpisy.
        public static func xyPlotFooter(optionsShown: Bool) -> CGFloat {
            optionsShown ? 166 : 74
        }

        /// Okno, którego opcje zawijają się do kolejnych rzędów (Spectrum): najwęższa
        /// szerokość, przy której wszystko jeszcze wygląda porządnie. Wysokość nie ma stałego
        /// minimum — im węższe okno, tym więcej rzędów, więc `PanelWindows` dociąga ją do
        /// treści (uwaga użytkownika 2026-09-27: opcje i wykres były przycięte). `nil` = nie.
        public var wrappingMinWidth: CGFloat? {
            self == .spectrogram ? 420 : nil
        }

        /// Panele, które wolno powiększać — ale wyłącznie **proporcjonalnie** i nigdy
        /// poniżej `fixedWindowSize`, bo ich zawartość to siatka o stałych proporcjach.
        /// Klawiatura zostaje sztywna: jej klawisze mają rozmiar prawdziwych klawiszy.
        public var scalesProportionally: Bool {
            switch self {
            case .parameterPages, .mutator, .parameterOverview, .patchAdjuster: true
            default: false
            }
        }
    }

    /// Gdzie panel się pokazuje.
    public enum Placement: Sendable {
        /// Szuflada przy lewej krawędzi okna — wysunięta jest dokładnie jedna.
        case drawer
        /// Własne pływające okno, także na drugim monitorze.
        case window
    }

    public static let minPanelWidth: CGFloat = 200
    public static let maxPanelWidth: CGFloat = 560

    /// Wysunięta szuflada; `nil` = żadna. **Wysunięta jest dokładnie jedna.**
    public private(set) var drawer: Panel? {
        didSet {
            guard drawer != oldValue else { return }
            defaults.set(drawer?.rawValue ?? "", forKey: Self.drawerKey)
        }
    }

    /// Szuflada zapamiętana jako wysunięta, ale jeszcze schowana: biblioteka modułów
    /// czeka przy starcie, aż podglądy będą gotowe, i dopiero wtedy się wysuwa (prośba
    /// użytkownika 2026-10-09). `drawer` i jego zapis zostają nietknięte — zamknięcie
    /// aplikacji w trakcie niczego nie gubi.
    public private(set) var drawerHeld = false

    /// Panele otwarte we własnych oknach. Zapamiętywane między uruchomieniami.
    public private(set) var windows: Set<Panel> = [] {
        didSet {
            guard windows != oldValue else { return }
            defaults.set(windows.map(\.rawValue).sorted(), forKey: Self.windowsKey)
        }
    }

    /// Wysunięty panel „Mutation settings" z prawej strony okna Patch Mutator.
    /// Zwinięty = okno dokładnie takie jak Standard. Zapamiętany między uruchomieniami.
    public var mutatorSettingsOpen: Bool {
        didSet {
            guard mutatorSettingsOpen != oldValue else { return }
            defaults.set(mutatorSettingsOpen, forKey: Self.mutatorSettingsKey)
        }
    }

    /// Ustawienia wysuwanego panelu (np. „Only audible"). Zapamiętane między uruchomieniami.
    public var mutatorPanelSettings: G2MutatorPanelSettings {
        didSet {
            guard mutatorPanelSettings != oldValue else { return }
            defaults.set(mutatorPanelSettings.onlyAudible, forKey: Self.onlyAudibleKey)
            defaults.set(mutatorPanelSettings.poolSize, forKey: Self.poolSizeKey)
            defaults.set(mutatorPanelSettings.poolOperations.map(\.rawValue).sorted(), forKey: Self.poolOperationsKey)
            let weights = G2MutatorGroup.allCases.map { ($0.rawValue, mutatorPanelSettings.groupWeights[$0]) }
            defaults.set(Dictionary(uniqueKeysWithValues: weights), forKey: Self.groupWeightsKey)
            let anchors = mutatorPanelSettings.anchors
            defaults.set(anchors.knobAssigned, forKey: Self.anchorKnobsKey)
            defaults.set(anchors.rootPitch ?? -1, forKey: Self.anchorPitchKey)
            defaults.set(anchors.loudness ?? 0, forKey: Self.anchorLoudnessKey)
            defaults.set(anchors.tempoGrid, forKey: Self.anchorTempoKey)
            defaults.set(mutatorPanelSettings.axisTarget.rawValue, forKey: Self.axisTargetKey)
            defaults.set(mutatorPanelSettings.familySpacing.rawValue, forKey: Self.familySpacingKey)
            defaults.set(mutatorPanelSettings.smoothAxis.rawValue, forKey: Self.smoothAxisKey)
        }
    }

    /// Ustawienia panelu, które obowiązują teraz — zwinięty panel = Standard.
    public var effectiveMutatorSettings: G2MutatorPanelSettings {
        mutatorPanelSettings.effective(panelOpen: mutatorSettingsOpen)
    }

    /// Szerokość wysuwanego panelu mutatora w układzie bazowym okna (nieco ponad
    /// połowa okna Standard); przy powiększonym oknie skaluje się razem z nim.
    public static let mutatorSettingsWidth: CGFloat = 270

    /// Rozmiar bazowy okna panelu — `fixedWindowSize` poszerzony o wysunięty panel
    /// mutatora. `nil` = okno bez stałego rozmiaru.
    public func baseWindowSize(of panel: Panel) -> CGSize? {
        guard var size = panel.fixedWindowSize else { return nil }
        if panel == .mutator, mutatorSettingsOpen {
            size.width += Self.mutatorSettingsWidth
        }
        return size
    }

    private var widths: [Panel: CGFloat]
    private let defaults: UserDefaults

    private static let drawerKey = "g2_panel_drawer"
    private static let windowsKey = "g2_panel_windows"
    private static let mutatorSettingsKey = "g2_mutator_settings_open"
    private static let onlyAudibleKey = "g2_mutator_only_audible"
    private static let poolSizeKey = "g2_mutator_pool_size"
    private static let poolOperationsKey = "g2_mutator_pool_operations"
    private static let groupWeightsKey = "g2_mutator_group_weights"
    private static let anchorKnobsKey = "g2_mutator_anchor_knobs"
    private static let anchorPitchKey = "g2_mutator_anchor_pitch"
    private static let anchorLoudnessKey = "g2_mutator_anchor_loudness"
    private static let anchorTempoKey = "g2_mutator_anchor_tempo"
    private static let axisTargetKey = "g2_mutator_axis_target"
    private static let familySpacingKey = "g2_mutator_family_spacing"
    private static let smoothAxisKey = "g2_mutator_smooth_axis"
    /// Klucz sprzed rozdzielenia paneli na szufladę i okna — czytany raz, przy pierwszym
    /// starcie nowego układu, żeby biblioteka modułów została tam, gdzie ją zostawiono.
    private static let legacySidebarKey = "g2_sidebar_shown"
    private static func widthKey(_ panel: Panel) -> String {
        "g2_panel_width_\(panel.rawValue)"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.drawerKey) {
            let stored = Panel(rawValue: raw)
            drawer = stored?.placement == .drawer ? stored : nil
        } else {
            let sidebarWasShown = (defaults.object(forKey: Self.legacySidebarKey) as? Bool) ?? true
            drawer = sidebarWasShown ? .modules : nil
        }
        windows = Set((defaults.stringArray(forKey: Self.windowsKey) ?? [])
            .compactMap(Panel.init(rawValue:))
            .filter { $0.placement == .window })
        mutatorSettingsOpen = defaults.bool(forKey: Self.mutatorSettingsKey)
        let defaultPanel = G2MutatorPanelSettings()
        mutatorPanelSettings = G2MutatorPanelSettings(
            onlyAudible: defaults.object(forKey: Self.onlyAudibleKey) as? Bool ?? defaultPanel.onlyAudible,
            poolSize: (defaults.object(forKey: Self.poolSizeKey) as? Int)
                .flatMap { G2MutatorPanelSettings.poolSizes.contains($0) ? $0 : nil } ?? defaultPanel.poolSize,
            poolOperations: defaults.stringArray(forKey: Self.poolOperationsKey)
                .map { Set($0.compactMap(G2MutatorPanelSettings.PoolOperation.init(rawValue:))) }
                ?? defaultPanel.poolOperations,
            groupWeights: (defaults.dictionary(forKey: Self.groupWeightsKey) as? [String: Double])
                .map { stored in
                    G2MutatorGroupWeights(Dictionary(uniqueKeysWithValues: G2MutatorGroup.allCases.compactMap { group in
                        stored[group.rawValue].map { (group, $0) }
                    }))
                } ?? defaultPanel.groupWeights,
            anchors: G2MutatorAnchors(
                knobAssigned: defaults.object(forKey: Self.anchorKnobsKey) as? Bool
                    ?? defaultPanel.anchors.knobAssigned,
                rootPitch: (defaults.object(forKey: Self.anchorPitchKey) as? Int)
                    .map { G2MutatorAnchors.pitchWindows.contains($0) ? $0 : nil } ?? defaultPanel.anchors.rootPitch,
                loudness: (defaults.object(forKey: Self.anchorLoudnessKey) as? Double)
                    .map { G2MutatorAnchors.loudnessWindows.contains($0) ? $0 : nil } ?? defaultPanel.anchors.loudness,
                tempoGrid: defaults.object(forKey: Self.anchorTempoKey) as? Bool ?? defaultPanel.anchors.tempoGrid
            ),
            axisTarget: defaults.string(forKey: Self.axisTargetKey).flatMap(G2MutationAxis.Target.init(rawValue:))
                ?? defaultPanel.axisTarget,
            familySpacing: defaults.string(forKey: Self.familySpacingKey).flatMap(G2FamilySpacing.init(rawValue:))
                ?? defaultPanel.familySpacing,
            smoothAxis: (defaults.object(forKey: Self.smoothAxisKey) as? Int).map(G2SmoothAxis.init(rawValue:))
                ?? defaultPanel.smoothAxis
        )
        var widths: [Panel: CGFloat] = [:]
        for panel in Panel.allCases {
            let stored = defaults.double(forKey: Self.widthKey(panel))
            widths[panel] = stored > 0 ? CGFloat(stored) : panel.defaultWidth
        }
        self.widths = widths
    }

    // MARK: - Otwieranie i zamykanie

    /// Klik w przycisk paska albo skrót. Szuflada się wysuwa (chowając poprzednią),
    /// okno się otwiera; ten sam ruch drugi raz zamyka.
    public func toggle(_ panel: Panel) {
        switch panel.placement {
        case .drawer:
            // Klik w czekającą szufladę wysuwa ją od razu, zamiast zamykać.
            if drawerHeld {
                drawerHeld = false
                if drawer == panel { return }
            }
            drawer = (drawer == panel) ? nil : panel
        case .window:
            if windows.contains(panel) { windows.remove(panel) } else { windows.insert(panel) }
        }
    }

    /// `Esc` i „zamknij" w nagłówku szuflady. Okien nie dotyczy — te zamyka się
    /// własnym przyciskiem okna.
    public func close() {
        drawerHeld = false
        drawer = nil
    }

    /// Chowa wysuniętą szufladę do `releaseDrawer` — patrz `drawerHeld`.
    public func holdDrawer() {
        drawerHeld = drawer != nil
    }

    public func releaseDrawer() {
        drawerHeld = false
    }

    /// Czy panel jest teraz widoczny — wysunięty jako szuflada albo otwarty w oknie.
    public func isOpen(_ panel: Panel) -> Bool {
        switch panel.placement {
        case .drawer: !drawerHeld && drawer == panel
        case .window: windows.contains(panel)
        }
    }

    /// Zamknięcie okna panelu jego własnym przyciskiem.
    public func closeWindow(_ panel: Panel) {
        windows.remove(panel)
    }

    // MARK: - Szerokość

    /// Szerokość zapamiętana dla tego panelu — każdy ma własną, bo lista patchy
    /// potrzebuje innej niż klawiatura.
    public func width(of panel: Panel) -> CGFloat {
        widths[panel] ?? panel.defaultWidth
    }

    public func setWidth(_ width: CGFloat, for panel: Panel) {
        let clamped = min(max(width, Self.minPanelWidth), Self.maxPanelWidth)
        guard widths[panel] != clamped else { return }
        widths[panel] = clamped
        defaults.set(Double(clamped), forKey: Self.widthKey(panel))
    }
}
