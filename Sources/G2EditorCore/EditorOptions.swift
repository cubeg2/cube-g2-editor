// EditorOptions.swift
// Ustawienia z okna „Setup ▸ Options" (instrukcja Clavii, str. 125):
// wygląd kabli i sposób, w jaki mysz kręci gałkami.
//
// Trzymane w `UserDefaults` (`@AppStorage` po stronie widoków) — dotyczą programu,
// nie patcha, więc nie mają czego szukać w `PatchState`.

import Foundation

/// „Cable style — choose between Straight 3D, Curved 3D, Straight Thin and Curved Thin."
public enum CableStyle: String, CaseIterable, Sendable {
    case curved3D
    case straight3D
    case curvedThin
    case straightThin

    public static let storageKey = "g2_cable_style"

    public var title: String {
        switch self {
        case .curved3D: "Curved 3D"
        case .straight3D: "Straight 3D"
        case .curvedThin: "Curved Thin"
        case .straightThin: "Straight Thin"
        }
    }

    /// Czy kabel zwisa łukiem, czy biegnie prosto.
    public var isCurved: Bool {
        self == .curved3D || self == .curvedThin
    }

    /// Styl „3D" to gruby kabel z cieniem pod spodem; „Thin" — sama cienka linia.
    public var hasShadow: Bool {
        self == .curved3D || self == .straight3D
    }
}

/// Wygląd tarczy gałek (nasze, nie Clavii): jasne z blikiem — domyślne — ciemne
/// jak we wtyczce DAW albo „Future": czarny pierścień z zielonym paskiem wartości,
/// jasna tarcza z płaskim środkiem i czarny wskaźnik (od 2026-09-27).
public enum KnobStyle: String, CaseIterable, Sendable {
    case light
    case dark
    case future

    public static let storageKey = "g2_knob_style"

    public var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .future: "Future"
        }
    }

    /// Zapisany wybór — dla widoków, które nie dostają go z góry (podglądy modułów).
    public static var stored: KnobStyle {
        UserDefaults.standard.string(forKey: storageKey).flatMap(KnobStyle.init) ?? .light
    }
}

/// Pasek wartości w gałce Future: ciągła linia albo zakres podzielony na 16/32 odcinki
/// z przerwami — zapala się każdy odcinek, w który sięga wartość (od 2026-09-27).
public enum KnobRangeSegments: Int, CaseIterable, Sendable {
    case line = 0
    case sixteen = 16
    case thirtyTwo = 32

    public static let storageKey = "g2_knob_range_segments"

    public var title: String {
        switch self {
        case .line: "Line"
        case .sixteen: "16 segments"
        case .thirtyTwo: "32 segments"
        }
    }

    public static var stored: KnobRangeSegments {
        KnobRangeSegments(rawValue: UserDefaults.standard.integer(forKey: storageKey)) ?? .line
    }
}

/// Kolor paska wartości w gałce Future: zieleń ekranów albo czerwień (pierwsza wersja).
public enum KnobRangeColor: String, CaseIterable, Sendable {
    case green
    case red

    public static let storageKey = "g2_knob_range_color"

    public var title: String {
        switch self {
        case .green: "Green"
        case .red: "Red"
        }
    }

    public static var stored: KnobRangeColor {
        UserDefaults.standard.string(forKey: storageKey).flatMap(KnobRangeColor.init) ?? .green
    }
}

/// Kolor wskaźnika gałki Light: biały (domyślny) albo czarny jak w Future (od 2026-09-27).
public enum KnobPointerColor: String, CaseIterable, Sendable {
    case white
    case black

    public static let storageKey = "g2_knob_pointer_color"

    public var title: String {
        switch self {
        case .white: "White"
        case .black: "Black"
        }
    }

    public static var stored: KnobPointerColor {
        UserDefaults.standard.string(forKey: storageKey).flatMap(KnobPointerColor.init) ?? .white
    }
}

/// Jak wycinek zakresu morfu leży na gałce z wewnętrznym okręgiem (Light, Future) — nasze,
/// od 2026-09-27 na prośbę użytkownika: pełny wycinek zakrywał wewnętrzny okrąg.
/// W Dark tarcza nie ma okręgu, więc tam wycinek zostaje pełny.
public enum KnobMorphRange: String, CaseIterable, Sendable {
    /// Jednolity wycinek na całą tarczę (jak dotąd).
    case full
    /// Wycinek z cieniowaniem tarczy: gradient na obwodzie, płaski ciemniejszy środek.
    case shaded
    /// Tylko pierścień wokół środka — wewnętrzny okrąg zostaje odsłonięty.
    case ring

    public static let storageKey = "g2_knob_morph_range"

    public var title: String {
        switch self {
        case .full: "Full"
        case .shaded: "Shaded"
        case .ring: "Ring"
        }
    }

    public static var stored: KnobMorphRange {
        UserDefaults.standard.string(forKey: storageKey).flatMap(KnobMorphRange.init) ?? .full
    }
}

/// Siła blasku świecących elementów (nasze, od 2026-09-27): pasek wartości gałki Future
/// i zapalone diody. 0 = bez blasku, 1 = najmocniejszy (wychodzi poza czarny pierścień
/// gałki, jaśniejszy środek paska). Suwak w Setup ▸ Options.
public enum GlowAmount {
    public static let storageKey = "g2_glow_amount"
    public static let range: ClosedRange<Double> = 0 ... 1

    public static var stored: Double {
        min(range.upperBound, max(range.lowerBound, UserDefaults.standard.double(forKey: storageKey)))
    }
}

/// Komplet ustawień wyglądu gałek — jedna wartość do porównań kanwy i kluczy podglądów.
public struct KnobLook: Hashable, Sendable {
    public var style: KnobStyle
    public var rangeSegments: KnobRangeSegments
    public var rangeColor: KnobRangeColor
    /// Blask paska (`GlowAmount`, 0…1).
    public var glow: Double
    /// Kolor wskaźnika — tylko styl Light.
    public var pointerColor: KnobPointerColor
    /// Wycinek zakresu morfu — Light i Future (Dark zawsze pełny).
    public var morphRange: KnobMorphRange

    public init(style: KnobStyle, rangeSegments: KnobRangeSegments = .line,
                rangeColor: KnobRangeColor = .green, glow: Double = 0,
                pointerColor: KnobPointerColor = .white, morphRange: KnobMorphRange = .full)
    {
        self.style = style
        self.rangeSegments = rangeSegments
        self.rangeColor = rangeColor
        self.glow = glow
        self.pointerColor = pointerColor
        self.morphRange = morphRange
    }

    /// Zapisany wybór — dla widoków, które nie dostają go z góry (podglądy modułów).
    public static var stored: KnobLook {
        KnobLook(style: .stored, rangeSegments: .stored, rangeColor: .stored, glow: GlowAmount.stored,
                 pointerColor: .stored, morphRange: .stored)
    }

    /// Wskaźnik czarny: zawsze w Future, w Light na życzenie.
    public var blackPointer: Bool {
        style == .future || (style == .light && pointerColor == .black)
    }

    /// Tekst do klucza pamięci podręcznej podglądów.
    public var cacheTag: String {
        "\(style.rawValue)-\(rangeSegments.rawValue)-\(rangeColor.rawValue)-glow\(Int((glow * 100).rounded()))"
            + "-\(pointerColor.rawValue)-\(morphRange.rawValue)"
    }
}

/// Cieniowanie paneli modułów (nasze, nie Clavii): przyciski wypukłe, ekrany wgłębione.
/// Domyślnie włączone; wyłącznik w menu View.
public enum PanelShading {
    public static let storageKey = "g2_panel_shading"

    /// Zapisany wybór — dla widoków, które nie dostają go z góry (podglądy modułów).
    public static var stored: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }
}

/// Jasny albo ciemny wygląd edytora — Settings ▸ Display. `system` idzie za macOS.
public enum AppAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public static let storageKey = "g2_app_appearance"

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Tryb Norda po otwarciu pojedynczego patcha (`.pch2`, New Patch) — Setup ▸ Options.
/// Performance (`.prf2`, New Performance) zawsze przełącza Norda w tryb Performance.
public enum PatchOpenMode: String, CaseIterable, Sendable {
    /// Nord przechodzi w tryb Patch, patch idzie do slotu z focusem, B–D zostają (domyślne).
    case switchToPatch
    /// Tryb zostaje, pozostałe sloty grają dalej.
    case keepMode
    /// Jak oryginał (`CreateDownloadPerformanceFromPatch`): tryb Patch, plik do slotu A,
    /// sloty B–D wyczyszczone (decyzja użytkownika 2026-10-15).
    case likeOriginal

    public static let storageKey = "g2_patch_open_mode"

    public var title: String {
        switch self {
        // „slots B–D" sklejone (twarda spacja, łączniki wokół półpauzy) — w wąskiej
        // kolumnie okna Settings samo „D" spadało do nowej linii (2026-10-15).
        case .switchToPatch: "Switch the G2 to Patch mode, keep slots\u{00A0}B\u{2060}–\u{2060}D"
        case .keepMode: "Keep the G2's mode, other slots keep playing"
        case .likeOriginal: "Like the original editor: patch into slot A, clear slots\u{00A0}B\u{2060}–\u{2060}D"
        }
    }

    public static var stored: PatchOpenMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(PatchOpenMode.init) ?? .switchToPatch
    }

    /// Tryb, w który ma wejść Nord przed wysyłką dokumentu; `nil` = zostaje, jak jest.
    public static func targetMode(performanceDocument: Bool, choice: PatchOpenMode = stored) -> Bool? {
        if performanceDocument { return true }
        return choice == .keepMode ? nil : false
    }
}

/// Co zrobić, gdy Nord się podłącza, a edytor ma już własny patch (plik otwarty bez Norda
/// albo zmiany zrobione po odłączeniu kabla) — Setup ▸ Options. Wirtualny G2 dostaje
/// zawartość edytora zawsze (#121), bo startuje pusty.
public enum ConnectContentMode: String, CaseIterable, Sendable {
    /// Patch z edytora jedzie do Norda — słychać to, co widać (domyślne, decyzja
    /// użytkownika 2026-10-15: bez pytania).
    case sendToDevice
    /// Edytor wczytuje to, co gra Nord; niezapisana praca i tak pyta o zapis.
    case loadFromDevice
    /// Okno z wyborem przy każdym takim podłączeniu.
    case ask

    public static let storageKey = "g2_connect_content_mode"

    public var title: String {
        switch self {
        case .sendToDevice: "Send the editor's patch to the G2"
        case .loadFromDevice: "Load the G2's patch into the editor"
        case .ask: "Ask every time"
        }
    }

    public static var stored: ConnectContentMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ConnectContentMode.init) ?? .sendToDevice
    }
}

/// Co robi zwykłe kliknięcie w slot, który MILCZY (nasze ustawienie, nie Clavii) — Setup ▸ Options.
/// Slot, który już gra, zawsze dostaje tylko focus.
public enum SilentSlotClick: String, CaseIterable, Sendable {
    /// Dokłada slot do grających i daje mu klawiaturę — dotychczasowe grają dalej (domyślne).
    case addToPlaying
    /// Sama biała ramka: slot jest edytowany, ale dalej milczy.
    case focusOnly
    /// Jak oryginał: kliknięty slot staje się jedynym grającym.
    case playAlone

    public static let storageKey = "g2_silent_slot_click"

    public var title: String {
        switch self {
        case .addToPlaying: "Add it to the playing slots"
        case .focusOnly: "Edit it, keep it silent"
        case .playAlone: "Play it alone (original editor)"
        }
    }

    public static var stored: SilentSlotClick {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SilentSlotClick.init) ?? .addToPlaying
    }

    /// Nowe sloty grające i klawiatura po kliknięciu milczącego `slot`; `nil` = bez zmian.
    /// Klawiatura zostaje tylko przy grających, a gdy nikt jej nie ma — dostaje ją pierwszy
    /// grający (tak pilnuje tego oryginał).
    public func selection(clicking slot: Int, playing: [Bool], keyboard: [Bool],
                          slotCount: Int) -> (enabled: [Bool], keyboard: [Bool])?
    {
        let enabled: [Bool]
        switch self {
        case .focusOnly:
            return nil
        case .playAlone:
            enabled = (0 ..< slotCount).map { $0 == slot }
        case .addToPlaying:
            enabled = (0 ..< slotCount).map { $0 == slot || (playing.indices.contains($0) && playing[$0]) }
        }
        var keys = (0 ..< slotCount).map { enabled[$0] && keyboard.indices.contains($0) && keyboard[$0] }
        if self == .addToPlaying { keys[slot] = true }
        if !keys.contains(true), let first = enabled.firstIndex(of: true) { keys[first] = true }
        return (enabled, keys)
    }
}

/// „Knob control — here you select if you want the knob and slider parameters in the
/// Editor Patch window to respond to Circular, Horizontal or Vertical motions."
public enum KnobControl: String, CaseIterable, Sendable {
    case vertical
    case horizontal
    case circular

    public static let storageKey = "g2_knob_control"

    public var title: String {
        switch self {
        case .vertical: "Vertical"
        case .horizontal: "Horizontal"
        case .circular: "Circular"
        }
    }

    /// Wartość dla trybu „Circular": kąt kursora wokół środka tarczy, licząc jak
    /// wskaźnik gałki — 135° (godzina 7:30) to zero, dalej 270° do maksimum.
    /// Stąd opisany w instrukcji przeskok z maksimum na minimum przy 6 godzinie.
    ///
    /// `nil`, gdy kursor stoi na samym środku (kąt nie jest wtedy określony) albo
    /// w martwym wycinku pod tarczą — poza skalą wartości nie ma.
    public static func circularValue(at point: CGPoint, center: CGPoint,
                                     maxValue: Int) -> Int?
    {
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard (dx * dx + dy * dy).squareRoot() > 0.5 else { return nil }
        // atan2 daje −180°…180° z zerem na godzinie 3; przesuwamy tak, żeby zero
        // wypadło tam, gdzie zaczyna się skala.
        var degrees = atan2(dy, dx) * 180 / .pi - 135
        while degrees < 0 {
            degrees += 360
        }
        guard degrees <= 270 else { return nil }
        return Int((degrees / 270 * CGFloat(maxValue)).rounded())
    }
}
