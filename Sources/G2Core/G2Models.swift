// G2Models.swift
// Core data model for Nord Modular G2 patches
// Based on g2ools (Matt Gerassimoff, GPL) and G2-Edit (Chris Turner, GPL)

import Foundation

// MARK: - Patch Areas

/// `Sendable` jawnie: typ jest publiczny, więc kompilator sam tego nie wywnioskuje,
/// a `G2MeterReading` (struct `Sendable`) trzyma go w polu — w trybie Swift 6 to błąd.
public enum PatchArea: UInt8, CaseIterable, Sendable {
    case fx = 0
    case voice = 1
}

// MARK: - Cable Colors

// Values match the G2 binary protocol encoding (source: g2ools/nord/g2/colors.py)

public enum CableColor: UInt8, CaseIterable {
    case red = 0
    case blue = 1
    case yellow = 2
    case orange = 3
    case green = 4
    case purple = 5
    case white = 6

    public var displayName: String {
        switch self {
        case .red: "Audio (red)"
        case .blue: "Control (blue)"
        case .yellow: "Logic (yellow)"
        case .orange: "Logic HQ (orange)"
        case .green: "User 1 (green)"
        case .purple: "User 2 (purple)"
        case .white: "Unused (white)"
        }
    }
}

// MARK: - Module

public struct G2Module: Equatable {
    /// Instance ID — unique within the patch area
    public var id: Int
    /// Module type number — indexes into ModuleDatabase
    public var typeID: Int
    /// Horizontal grid position (7 bits, 0–127)
    public var column: Int
    /// Vertical grid position (7 bits, 0–127)
    public var row: Int
    /// Display color (8 bits)
    public var color: UInt8
    /// Uprate flag — module runs at audio rate even in control section
    public var uprate: Bool
    /// LED indicator flag
    public var leds: Bool
    /// Parameter values for active variation (variation 0) — used by UI
    public var parameters: [Int]
    /// All variation parameter values [variationIndex][paramIndex] — 9 variations (0–8)
    /// Index 0 is always kept in sync with `parameters`. Used for serialization.
    public var parameterVariations: [[Int]]
    /// Mode values (one per mode defined in ModuleDatabase)
    public var modes: [Int]
    /// User-assigned label — max 16 chars (MODULE_NAME_SIZE in G2 protocol)
    public var label: String
    /// Czy moduł ma wpis w sekcji nazw (0x5a). Oryginał trzyma nazwy w mapie i
    /// zapisuje **każdy** jej wpis, także z pustą nazwą (w kolekcji referencyjnej
    /// 27 477 z 207 040 wpisów w plikach wersji 23), więc samo `label.isEmpty`
    /// nie wystarcza, żeby odtworzyć sekcję bajt w bajt.
    public var hasNameEntry: Bool
    /// Czy moduł ma wpis w sekcji parametrów (0x4d). Bywa wpis z zerem parametrów
    /// (205 wpisów w 20 plikach wersji 23) — samo `parameters.isEmpty` też więc
    /// nie wystarcza. Ustawia to parser; nowy moduł dostaje wpis wraz z wartościami.
    public var hasParameterEntry: Bool
    /// Which patch area this module lives in
    public var area: PatchArea
    /// `Exclude From Mutations` — Patch Mutator nie rusza parametrów tego modułu
    /// (`CModule::IsLocked` oryginału). Część typów jest wyłączona z góry, patrz
    /// `G2Module.isExcludedFromMutationByDefault`.
    ///
    /// **Nie idzie do pliku.** Instrukcja mówi, że ustawienie zapisuje się z patchem,
    /// ale zapis wersji 11 (`Format_11::W_ModuleData::WrModule`) wpisuje w to miejsce
    /// sześć zer i odczyt je pomija — więc oryginał też trzyma to tylko w sesji.
    public var excludedFromMutation: Bool

    public init(id: Int, typeID: Int, area: PatchArea) {
        self.id = id
        self.typeID = typeID
        self.area = area
        self.excludedFromMutation = Self.isExcludedFromMutationByDefault(typeID: typeID)
        self.column = 0
        self.row = 0
        self.color = 0
        self.uprate = false
        self.leds = false
        self.parameters = []
        self.parameterVariations = []
        self.modes = []
        self.label = ""
        self.hasNameEntry = false
        self.hasParameterEntry = false
    }

    /// Moduły, których Patch Mutator nie rusza, dopóki użytkownik sam nie odznaczy
    /// `Exclude From Mutations`. Instrukcja wymienia „moduły wejścia i wyjścia,
    /// większość modułów MIDI, wokoder, 6-kanałowy mikser stereo i kilka innych";
    /// pitch tracker dochodzi z rozdziału o Patch Adjustorze.
    public static func isExcludedFromMutationByDefault(typeID: Int) -> Bool {
        if typeID == 108 || typeID == 48 || typeID == 198 { return true } // Vocoder, MixStereo, PitchTrack
        guard let page = ModuleDatabase.module(id: typeID)?.page else { return false }
        return page == "In/Out" || page == "MIDI"
    }

    /// Efektywna wysokość modułu w wierszach gridu — bierze pod uwagę gap do następnego modułu w kolumnie.
    public func effectiveHeightRows(in allModules: [G2Module]) -> Int {
        let maxH = ModuleDatabase.module(id: typeID)?.height ?? 2
        let nextRow = allModules
            .filter { $0.column == column && $0.row > row && $0.id != id }
            .map(\.row)
            .min()
        if let next = nextRow { return min(next - row, maxH) }
        return maxH
    }
}

// MARK: - Cable

public struct G2Cable: Equatable {
    public var fromModule: Int
    public var fromConnector: Int
    public var toModule: Int
    public var toConnector: Int
    public var color: CableColor
    public var area: PatchArea
    /// Czym jest **źródłowy** koniec kabla. Koniec docelowy jest zawsze wejściem.
    ///
    /// W pliku `.pch2` i w protokole USB to 1-bitowe pole `linkType`:
    /// `1` = wyjście→wejście, `0` = wejście→wejście. Nord pozwala wpiąć kabel
    /// z jednego wejścia w drugie i takie kable realnie występują w patchach.
    ///
    /// Źródła (trzy niezależne, zgodne):
    /// - `reference/G2-Edit/src/protocol.c` `parse_cable_list`:
    ///   `key.linkType = read_bit_stream(...) // 1 = output to input, 0 = input to input`
    /// - BVerhue `g2_file.pas:309`: `FLinkType : TBits1; // 0 - input to input; 1 - output to input`
    /// - BVerhue `g2_mess.pas:6005`: `if aFromConnectorKind = ckInput then aLinkType := 0 else aLinkType := 1`
    ///
    /// Domyślne `true` odpowiada zwykłemu kablowi wyjście→wejście. Każde miejsce,
    /// które zna rodzaj konektora źródłowego, ma podać tę wartość jawnie.
    public var sourceIsOutput: Bool

    public init(fromModule: Int, fromConnector: Int,
                toModule: Int, toConnector: Int,
                color: CableColor, area: PatchArea,
                sourceIsOutput: Bool = true)
    {
        self.fromModule = fromModule
        self.fromConnector = fromConnector
        self.toModule = toModule
        self.toConnector = toConnector
        self.color = color
        self.area = area
        self.sourceIsOutput = sourceIsOutput
    }
}

// MARK: - Patch Description

public struct G2PatchDescription: Equatable {
    public var voices: Int = 0
    public var height: Int = 0 // canvas height
    public var monopoly: Int = 0 // 0=poly, 1=mono, 2=legato
    public var variation: Int = 0 // active variation (0–7, plus init=8)
    public var category: Int = 0
    // cable color visibility flags
    public var redVisible: Bool = true
    public var blueVisible: Bool = true
    public var yellowVisible: Bool = true
    public var orangeVisible: Bool = true
    public var greenVisible: Bool = true
    public var purpleVisible: Bool = true
    public var whiteVisible: Bool = true
}

// MARK: - Variation Settings (Patch Settings sheet — Glide, Bend, Vibrato, Arpeggiator…)

/// Field names/grouping match g2ools nord.g2.file.Settings.groups (source: g2ools/nord/g2/file.py).
/// Stored per-variation (9 = 8 user variations + Init), same convention as G2Module.parameterVariations.
/// Czytane i zapisywane w sekcji 0x4d obszaru 2 — patrz PatchParser.parseSettings /
/// rewriteSettingsSection (grupa morfów z tej samej sekcji nie jest jeszcze modelowana).
public struct G2VariationSettings: Equatable {
    public var patchVolume: Int = 127
    /// **1 = patch gra, 0 = wyciszony** (`VolMute` u BVerhue: `'Off;On'`, init patch = 1;
    /// 172 z 174 plików kolekcji mają 1). Do 2026-09-16 domyślne 0 i przycisk w pasie slotu
    /// czytały to odwrotnie — „Off" świecił przy grającym patchu.
    public var activeMuted: Int = 1
    public var glide: Int = 0
    public var glideTime: Int = 0
    public var bend: Int = 0
    public var semitone: Int = 0
    public var vibrato: Int = 0
    public var vibratoCents: Int = 0
    public var vibratoRate: Int = 0
    public var arpeggiator: Int = 0
    public var arpTime: Int = 0
    public var arpType: Int = 0
    public var arpOctaves: Int = 0
    public var octaveShift: Int = 0
    public var sustain: Int = 0
    /// Wartości ośmiu gałek morfu (0–127). Grupa 1 tej samej sekcji 0x4d, 16 wpisów
    /// na wariację: najpierw osiem gałek, potem osiem źródeł → [[Docs/ui/morphs]].
    public var morphDials: [Int] = Array(repeating: 0, count: G2Morph.count)
    /// Źródła ośmiu morfów: 0 = tylko gałka, 1 = nazwane źródło (tak ma init patch),
    /// 2 = „G Wh 1" — wyłącznie dla morfu 5 i wyłącznie na G2X.
    public var morphModes: [Int] = Array(repeating: 1, count: G2Morph.count)
}

/// Jedno ustawienie patcha z arkusza Patch Settings, razem z miejscem, w którym
/// siedzi w protokole. Adres jest ten sam w pliku i na magistrali: **numer grupy
/// sekcji `0x4d` obszaru 2 jest numerem modułu, a numer wpisu w grupie — numerem
/// parametru**. Stąd jedna tablica obsługuje i parser, i wysyłkę na żywo; rozjazd
/// między nimi przestaje być możliwy.
///
/// Że adresowanie jest właśnie takie, wiadomo z morfów: gałki i źródła to grupa 1
/// tej samej sekcji i idą do urządzenia jako moduł 1, parametry 0-15
/// (`PatchState.setMorphDial`) — sprawdzone na Nordzie → [[Docs/ui/morphs]].
public enum G2PatchSetting: CaseIterable {
    case patchVolume, activeMuted
    case glide, glideTime
    case bend, semitone
    case vibrato, vibratoCents, vibratoRate
    case arpeggiator, arpTime, arpType, arpOctaves
    case octaveShift, sustain

    /// Numer grupy w sekcji `0x4d` = numer modułu w obszarze ustawień patcha.
    public var module: Int {
        switch self {
        case .patchVolume, .activeMuted: 2
        case .glide, .glideTime: 3
        case .bend, .semitone: 4
        case .vibrato, .vibratoCents, .vibratoRate: 5
        case .arpeggiator, .arpTime, .arpType, .arpOctaves: 6
        case .octaveShift, .sustain: 7
        }
    }

    /// Pozycja w grupie = numer parametru.
    public var param: Int {
        switch self {
        case .patchVolume, .glide, .bend, .vibrato, .arpeggiator, .octaveShift: 0
        case .activeMuted, .glideTime, .semitone, .vibratoCents, .arpTime, .sustain: 1
        case .vibratoRate, .arpType: 2
        case .arpOctaves: 3
        }
    }

    public var keyPath: WritableKeyPath<G2VariationSettings, Int> {
        switch self {
        case .patchVolume: \.patchVolume
        case .activeMuted: \.activeMuted
        case .glide: \.glide
        case .glideTime: \.glideTime
        case .bend: \.bend
        case .semitone: \.semitone
        case .vibrato: \.vibrato
        case .vibratoCents: \.vibratoCents
        case .vibratoRate: \.vibratoRate
        case .arpeggiator: \.arpeggiator
        case .arpTime: \.arpTime
        case .arpType: \.arpType
        case .arpOctaves: \.arpOctaves
        case .octaveShift: \.octaveShift
        case .sustain: \.sustain
        }
    }

    /// Etykieta na ekranie — po angielsku, jak reszta interfejsu.
    public var label: String {
        switch self {
        case .patchVolume: "Patch Volume"
        case .activeMuted: "Active Muted"
        case .glide: "Glide"
        case .glideTime: "Glide Time"
        case .bend: "Bend Range"
        case .semitone: "Semitone"
        case .vibrato: "Vibrato"
        case .vibratoCents: "Vibrato Depth"
        case .vibratoRate: "Vibrato Rate"
        case .arpeggiator: "Arpeggiator"
        case .arpTime: "Arp Time"
        case .arpType: "Arp Direction"
        case .arpOctaves: "Arp Octaves"
        case .octaveShift: "Octave Shift"
        case .sustain: "Sustain"
        }
    }

    /// Wartości, które Nord zna. Większość ustawień to wybór z kilku pozycji — do
    /// 2026-10-15 arkusz miał na wszystkich suwak 0–127 i dało się wysłać np. Glide = 87.
    /// Źródło: tabela ustawień patcha w edytorze BVerhue (`AddParam(ptParam, PATCH_…)`).
    public var range: ClosedRange<Int> {
        if let valueNames { return 0 ... valueNames.count - 1 }
        return self == .semitone ? 0 ... 23 : 0 ... 127
    }

    /// Nazwy kolejnych wartości; `nil` = wartość ciągła (suwak).
    /// `activeMuted`: 1 = patch gra — tak zapisują go zwykłe patche, a instrukcja
    /// nazywa ten przycisk On/Off.
    public var valueNames: [String]? {
        switch self {
        case .activeMuted, .bend, .arpeggiator, .sustain: ["Off", "On"]
        case .glide: ["Auto", "Normal", "Off"]
        case .vibrato: ["Wheel", "Aftertouch", "Off"]
        case .arpTime: ["1/8", "1/8T", "1/16", "1/16T"]
        case .arpType: ["Up", "Down", "Up/Down", "Random"]
        case .arpOctaves: ["1", "2", "3", "4"]
        case .octaveShift: ["-2", "-1", "0", "+1", "+2"]
        case .patchVolume, .glideTime, .semitone, .vibratoCents, .vibratoRate: nil
        }
    }

    /// Wartość tak, jak pokazuje ją interfejs. Bend Range liczy się od 1 półtonu.
    public func valueText(_ value: Int) -> String {
        if let valueNames, valueNames.indices.contains(value) { return valueNames[value] }
        return self == .semitone ? "\(value + 1) semi" : "\(value)"
    }

    /// Pola jednej grupy w kolejności zapisu — tego używa parser sekcji `0x4d`.
    public static func fields(inModule module: Int) -> [WritableKeyPath<G2VariationSettings, Int>]? {
        let group = allCases.filter { $0.module == module }.sorted { $0.param < $1.param }
        return group.isEmpty ? nil : group.map(\.keyPath)
    }
}

// MARK: - Performance Settings (sekcja 0x11 pliku .prf2)

/// Ustawienia jednego slotu performance'u (A–D).
/// Nazwy pól za g2ools `PerformanceDescription.slot_attrs`; BVerhue `TG2FileSlot`
/// nazywa je Enabled/Keyboard/Hold/BankIndex/PatchIndex/KeyboardRangeFrom/To.
public struct G2PerformanceSlot: Equatable {
    /// Nazwa patcha w slocie (0–16 znaków) — w pliku trzyma ją wyłącznie sekcja 0x11.
    public var name: String = ""
    /// Slot gra (Active na panelu urządzenia).
    public var enabled: Bool = false
    /// Slot odbiera klawiaturę.
    public var keyboard: Bool = false
    public var hold: Bool = false
    public var bank: Int = 0
    public var patch: Int = 0
    public var keyRangeLow: Int = 0
    public var keyRangeHigh: Int = 127

    public init() {}
}

/// Ustawienia całego performance'u — sekcja `0x11`, obecna tylko w plikach `.prf2`.
/// Pliku nie ma pola nazwy performance'u (nazwą jest nazwa pliku); na urządzeniu
/// nazwa przychodzi osobną odpowiedzią 0x29.
public struct G2PerformanceSettings: Equatable {
    /// Slot pokazany po otwarciu performance'u (g2ools `focus`).
    public var focusedSlot: Int = 0
    public var keyboardRangeEnabled: Bool = false
    /// BPM — w kolekcji referencyjnej wyłącznie 30…240, tak jak na urządzeniu.
    public var masterClock: Int = 120
    public var masterClockRunning: Bool = false
    /// Przycisk `Global Pages` panelu — osiem gałek pokazuje wtedy wspólną mapę
    /// performance'u zamiast mapy patcha. To **ustawienie performance'u**, nie patcha:
    /// u Clavii mieszka w `CPerformanceHeader` (`CPerformance::HandlePerformanceHeaderParam`
    /// dla indeksu 2 pisze do tego samego pola, które `CPerformanceHeader_11::ReadStream`
    /// czyta zaraz za numerem slotu z focusem) → sekcja 0x11, bajt 1, dwa najmłodsze bity.
    public var globalPagesEnabled: Bool = false
    public var slots: [G2PerformanceSlot] = Array(repeating: G2PerformanceSlot(), count: 4)
    /// Wspólny dla czterech slotów zestaw 120 stron globalnych (sekcja 0x5F).
    public var globalKnobAssignments: [G2GlobalKnobAssignment?] =
        Array(repeating: nil, count: G2KnobPages.knobCount)

    public init() {}
}

// MARK: - Patch

public struct G2Patch: Equatable {
    public var description: G2PatchDescription = .init()
    public var name: String = ""
    /// Patch notes (Textpad) — persisted in section 0x6F, plain text, no extra framing.
    public var notes: String = ""
    /// Per-variation settings (Glide/Bend/Vibrato/Arpeggiator…) — see `G2VariationSettings`.
    public var variationSettings: [G2VariationSettings] =
        Array(repeating: G2VariationSettings(), count: G2Patch.runtimeVariationCount)
    /// Przypisania morfów, osobno dla każdej z dziewięciu wariacji (sekcja 0x65).
    /// Operacje na nich → `G2Morph.swift`.
    public var morphAssignments: [[G2MorphAssignment]] =
        Array(repeating: [], count: G2Patch.runtimeVariationCount)
    /// 120 gałek stron parametrów (sekcja 0x62) — 15 stron po 8. `nil` = gałka wolna.
    /// Operacje na nich → `G2Knobs.swift`.
    public var knobAssignments: [G2KnobAssignment?] = Array(repeating: nil, count: G2KnobPages.knobCount)
    /// MIDI Control Change assignments (section 0x60), indexed by CC number 0...119.
    public var midiControllerAssignments: [G2MidiControllerAssignment?] =
        Array(repeating: nil, count: G2MidiControllers.count)

    public var voiceModules: [G2Module] = []
    public var fxModules: [G2Module] = []
    public var voiceCables: [G2Cable] = []
    public var fxCables: [G2Cable] = []

    /// Licznik wariantów z nagłówka sekcji 0x4d, osobno dla każdego obszaru.
    /// Ma znaczenie tylko dla sekcji bez modułów z parametrami: oryginał zapisuje
    /// tam licznik faktycznie dodanych zestawów, czyli zwykle 0 — ale w 28 z 5 119
    /// pustych sekcji kolekcji referencyjnej jest 9. Wartości nie da się wyliczyć,
    /// więc przepisujemy ją z pliku.
    public var parameterVariationCount: [PatchArea: Int] = [:]

    /// Dane modułów (sekcja 0x5B, Module Custom Data Dump) — surowa treść sekcji
    /// według bajtu obszaru: 0 FX, 1 Voice, 2 patch (m.in. nazwy morfów). Nie modelujemy
    /// ich, tylko przenosimy: bez tego zapis patcha bez pliku źródłowego (np. kopia
    /// z Norda) zostawiał puste sekcje szkieletu. Pusty słownik = sekcje pliku nietknięte.
    public var moduleCustomData: [UInt8: [UInt8]] = [:]

    public init() {}

    /// Convenience accessors
    public func modules(in area: PatchArea) -> [G2Module] {
        area == .voice ? voiceModules : fxModules
    }

    public func cables(in area: PatchArea) -> [G2Cable] {
        area == .voice ? voiceCables : fxCables
    }

    public mutating func add(module: G2Module) {
        if module.area == .voice {
            voiceModules.append(module)
        } else {
            fxModules.append(module)
        }
    }

    /// Wstawia nowy moduł z priorytetem pozycji i rozsuwa kolidujące moduły w dół.
    public mutating func insert(module: G2Module) {
        add(module: module)
        moveModule(
            moduleID: module.id,
            newColumn: module.column,
            newRow: module.row,
            in: module.area,
            push: .down
        )
    }

    public mutating func add(cable: G2Cable) {
        if cable.area == .voice {
            voiceCables.append(cable)
        } else {
            fxCables.append(cable)
        }
    }

    public mutating func remove(cable: G2Cable) {
        if cable.area == .voice {
            voiceCables.removeAll {
                $0.fromModule == cable.fromModule && $0.fromConnector == cable.fromConnector &&
                    $0.toModule == cable.toModule && $0.toConnector == cable.toConnector
            }
        } else {
            fxCables.removeAll {
                $0.fromModule == cable.fromModule && $0.fromConnector == cable.fromConnector &&
                    $0.toModule == cable.toModule && $0.toConnector == cable.toConnector
            }
        }
    }

    public enum PushDirection { case down, up }

    /// Przesuwa moduł na nową pozycję gridu i przesuwa kolidujące moduły w zadanym kierunku.
    public mutating func moveModule(moduleID: Int, newColumn: Int, newRow: Int,
                                    in area: PatchArea, push: PushDirection = .down)
    {
        let clampedCol = max(0, newColumn)
        let clampedRow = max(0, newRow)

        if area == .voice {
            guard voiceModules.firstIndex(where: { $0.id == moduleID }) != nil else { return }
            if let i = voiceModules.firstIndex(where: { $0.id == moduleID }) {
                voiceModules[i].column = clampedCol
                voiceModules[i].row = clampedRow
            }
            Self.resolveCollisions(in: &voiceModules, movedID: moduleID, column: clampedCol, push: push)
        } else {
            guard fxModules.firstIndex(where: { $0.id == moduleID }) != nil else { return }
            if let i = fxModules.firstIndex(where: { $0.id == moduleID }) {
                fxModules[i].column = clampedCol
                fxModules[i].row = clampedRow
            }
            Self.resolveCollisions(in: &fxModules, movedID: moduleID, column: clampedCol, push: push)
        }
    }

    /// Iteracyjnie usuwa kolizje w kolumnie.
    /// push == .down → przesuwa kolidujące moduły w dół (drag w dół lub na górną część celu).
    /// push == .up   → przesuwa kolidujące moduły w górę (drag w górę lub na dolną część celu).
    private static func resolveCollisions(in modules: inout [G2Module], movedID: Int,
                                          column: Int, push: PushDirection)
    {
        // Tiebreaker dla stabilnego sortu: originalRow (row PRZED kaskadą).
        // Moduł z niższym originalRow był wyżej w kolumnie → traktowany jako "above".
        // Indeks tablicy jest zawodny (OscB może być wcześniej niż Name w voiceModules).
        let originalRows: [Int: Int] = Dictionary(
            uniqueKeysWithValues: modules.map { ($0.id, $0.row) }
        )

        func stableSorted() -> [G2Module] {
            modules
                .filter { $0.column == column }
                .sorted { lhs, rhs in
                    guard lhs.row == rhs.row else { return lhs.row < rhs.row }
                    let lo = originalRows[lhs.id] ?? lhs.row
                    let ro = originalRows[rhs.id] ?? rhs.row
                    return lo < ro
                }
        }

        var changed = true
        while changed {
            changed = false
            let colMods = stableSorted()

            if push == .down {
                for idx in 1 ..< colMods.count {
                    let above = colMods[idx - 1]
                    let below = colMods[idx]
                    let aboveH = ModuleDatabase.module(id: above.typeID)?.height ?? 2
                    let aboveBottom = above.row + aboveH
                    guard below.row < aboveBottom else { continue }

                    if below.id == movedID {
                        // Przesuwany moduł ma priorytet: "above" jedzie w dół za nim.
                        let belowH = ModuleDatabase.module(id: below.typeID)?.height ?? 2
                        if let ai = modules.firstIndex(where: { $0.id == above.id }) {
                            let newRow = below.row + belowH
                            if modules[ai].row != newRow { modules[ai].row = newRow
                                changed = true
                            }
                        }
                    } else {
                        if let bi = modules.firstIndex(where: { $0.id == below.id }) {
                            modules[bi].row = aboveBottom
                            changed = true
                        }
                    }
                }
            } else {
                // push .up — iteruj od dołu ku górze
                for idx in stride(from: colMods.count - 2, through: 0, by: -1) {
                    let above = colMods[idx]
                    let below = colMods[idx + 1]
                    let aboveH = ModuleDatabase.module(id: above.typeID)?.height ?? 2
                    let aboveBottom = above.row + aboveH
                    guard aboveBottom > below.row else { continue }
                    if let ai = modules.firstIndex(where: { $0.id == above.id }) {
                        let newRow = max(0, below.row - aboveH)
                        if modules[ai].row != newRow { modules[ai].row = newRow
                            changed = true
                        }
                    }
                }
            }
        }

        // Cleanup po push .up: moduły przy floor (row=0) mogą nadal kolidować.
        // originalRows jako tiebreaker: moduł pierwotnie wyżej → "above" → drugi jedzie w dół.
        if push == .up {
            var cleaned = true
            while cleaned {
                cleaned = false
                let colMods = stableSorted()
                for idx in 1 ..< colMods.count {
                    let above = colMods[idx - 1]
                    let below = colMods[idx]
                    let aboveBottom = above.row + (ModuleDatabase.module(id: above.typeID)?.height ?? 2)
                    if below.row < aboveBottom,
                       let bi = modules.firstIndex(where: { $0.id == below.id })
                    {
                        modules[bi].row = aboveBottom
                        cleaned = true
                    }
                }
            }
        }
    }

    /// Zmienia etykietę modułu (max 16 znaków, zgodnie z MODULE_NAME_SIZE protokołu G2).
    public mutating func setLabel(moduleID: Int, label: String, in area: PatchArea) {
        let trimmed = String(label.prefix(16))
        if area == .voice {
            if let i = voiceModules.firstIndex(where: { $0.id == moduleID }) {
                voiceModules[i].label = trimmed
            }
        } else {
            if let i = fxModules.firstIndex(where: { $0.id == moduleID }) {
                fxModules[i].label = trimmed
            }
        }
    }

    /// Usuwa moduł i wszystkie kable do niego podłączone.
    public mutating func deleteModule(moduleID: Int, in area: PatchArea) {
        deleteModules(moduleIDs: [moduleID], in: area)
    }

    /// Usuwa grupę modułów i wszystkie kable podłączone do któregokolwiek z nich — razem
    /// z ich gałkami, CC, morfami i dodatkowymi danymi (0x5B). Bez tego przypisania zostawały
    /// pod numerem skasowanego modułu i przejmował je następny moduł o tym numerze.
    public mutating func deleteModules(moduleIDs: Set<Int>, in area: PatchArea) {
        guard !moduleIDs.isEmpty else { return }
        if area == .voice {
            voiceModules.removeAll { moduleIDs.contains($0.id) }
            voiceCables.removeAll { moduleIDs.contains($0.fromModule) || moduleIDs.contains($0.toModule) }
        } else {
            fxModules.removeAll { moduleIDs.contains($0.id) }
            fxCables.removeAll { moduleIDs.contains($0.fromModule) || moduleIDs.contains($0.toModule) }
        }
        let location = area.rawValue
        for knob in knobAssignments.indices
            where knobAssignments[knob].map({ $0.location == location && moduleIDs.contains($0.moduleID) }) == true
        {
            knobAssignments[knob] = nil
        }
        for cc in midiControllerAssignments.indices
            where midiControllerAssignments[cc]
            .map({ $0.location == location && moduleIDs.contains($0.moduleID) }) == true
        {
            midiControllerAssignments[cc] = nil
        }
        for variation in morphAssignments.indices {
            morphAssignments[variation].removeAll { $0.location == location && moduleIDs.contains($0.moduleID) }
        }
        if var labels = moduleLabels(in: area), labels.entries.contains(where: { moduleIDs.contains($0.moduleID) }) {
            labels.entries.removeAll { moduleIDs.contains($0.moduleID) }
            moduleCustomData[area.rawValue] = labels.raw
        }
    }

    /// Podmienia typ modułu według reguł Clavii, zachowując możliwe parametry i kable.
    @discardableResult
    public mutating func replaceModule(moduleID: Int, with targetTypeID: Int, in area: PatchArea) -> Bool {
        if area == .voice {
            return Self.replaceModule(
                moduleID: moduleID,
                targetTypeID: targetTypeID,
                modules: &voiceModules,
                cables: &voiceCables
            )
        }
        return Self.replaceModule(
            moduleID: moduleID,
            targetTypeID: targetTypeID,
            modules: &fxModules,
            cables: &fxCables
        )
    }

    private static func replaceModule(
        moduleID: Int,
        targetTypeID: Int,
        modules: inout [G2Module],
        cables: inout [G2Cable]
    ) -> Bool {
        guard let moduleIndex = modules.firstIndex(where: { $0.id == moduleID }),
              let targetDefinition = ModuleDatabase.module(id: targetTypeID)
        else { return false }

        let source = modules[moduleIndex]
        let connectedInputs = Set(cables.filter { $0.toModule == moduleID }.map(\.toConnector))
        let connectedOutputs = Set(cables.filter { $0.fromModule == moduleID }.map(\.fromConnector))
        guard let plan = ModuleReplacementDatabase.plan(
            from: source.typeID,
            to: targetTypeID,
            connectedInputs: connectedInputs,
            connectedOutputs: connectedOutputs
        ) else { return false }

        let defaults = ModuleDefaultsDatabase.defaults(forTypeID: targetTypeID)
        var targetDefaults = Array(defaults.prefix(targetDefinition.paramNames.count))
        targetDefaults += Array(repeating: 0, count: max(0, targetDefinition.paramNames.count - targetDefaults.count))

        var replacement = G2Module(id: source.id, typeID: targetTypeID, area: source.area)
        replacement.column = source.column
        replacement.row = source.row
        replacement.color = source.color
        replacement.uprate = source.uprate
        replacement.leds = source.leds
        replacement.label = source.label
        replacement.parameterVariations = Array(repeating: targetDefaults,
                                                count: G2Patch.runtimeVariationCount)

        for variationIndex in replacement.parameterVariations.indices {
            let sourceValues: [Int]
            if source.parameterVariations.indices.contains(variationIndex) {
                sourceValues = source.parameterVariations[variationIndex]
            } else if variationIndex == 0 {
                sourceValues = source.parameters
            } else {
                continue
            }
            // Several source knobs can share one target knob - folding a mono pair
            // into a single stereo channel does exactly that. Walk the map in source
            // order and let a later source overwrite an earlier one, so the higher
            // source index wins and the result never depends on dictionary iteration
            // order.
            //
            // Measured against the original editor on 2026-09-02. A Mixer 8-1 Fader
            // with channels 2,3,6,7 switched on becomes a Mixer 4-1 Stereo with
            // channels 1 and 3 on, which is what the even channel of each folded pair
            // produces. The original copies its parameters the same way, ascending and
            // overwriting (Muta Params (ReplaceModule)).
            for (sourceIndex, targetIndex) in plan.parameterMap.sorted(by: { $0.key < $1.key })
                where sourceValues.indices.contains(sourceIndex) &&
                replacement.parameterVariations[variationIndex].indices.contains(targetIndex)
            {
                replacement.parameterVariations[variationIndex][targetIndex] = sourceValues[sourceIndex]
            }
        }
        replacement.parameters = replacement.parameterVariations[0]

        replacement.modes = Array(repeating: 0, count: targetDefinition.modeNames.count)
        if let sourceDefinition = ModuleDatabase.module(id: source.typeID) {
            for (targetIndex, targetName) in targetDefinition.modeNames.enumerated() {
                guard let sourceIndex = sourceDefinition.modeNames.firstIndex(where: {
                    $0.caseInsensitiveCompare(targetName) == .orderedSame
                }), source.modes.indices.contains(sourceIndex) else { continue }
                replacement.modes[targetIndex] = source.modes[sourceIndex]
            }
        }

        cables = cables.compactMap { cable in
            var remapped = cable
            if cable.fromModule == moduleID {
                guard let connector = plan.outputMap[cable.fromConnector] else { return nil }
                remapped.fromConnector = connector
            }
            if cable.toModule == moduleID {
                guard let connector = plan.inputMap[cable.toConnector] else { return nil }
                remapped.toConnector = connector
            }
            return remapped
        }
        modules[moduleIndex] = replacement
        resolveCollisions(in: &modules, movedID: moduleID, column: replacement.column, push: .down)
        return true
    }

    /// Ustawia kolor wyświetlania modułu (0=kategoria, 1–24=kolor użytkownika).
    public mutating func setModuleColor(moduleID: Int, color: UInt8, in area: PatchArea) {
        if area == .voice {
            if let i = voiceModules.firstIndex(where: { $0.id == moduleID }) {
                voiceModules[i].color = color
            }
        } else {
            if let i = fxModules.firstIndex(where: { $0.id == moduleID }) {
                fxModules[i].color = color
            }
        }
    }

    /// Wariacja, którą patch faktycznie gra — numer z sekcji opisu patcha
    /// (`G2PatchDescription.variation`, u Clavii `activeVariation`). To ONA jest
    /// widoczna na gałkach i to do NIEJ trafia `SUB_COMMAND_SET_PARAM`; do 2026-09-04
    /// edytor zakładał wszędzie wariację 0 i przy patchu grającym np. wariację 4
    /// pokazywał cudze wartości, a zmiany na żywo szły do niesłyszalnej wariacji.
    public var activeVariation: Int {
        max(0, min(description.variation, Self.mutatorVariation))
    }

    /// Ile zestawów parametrów **zapisuje plik**: osiem wariacji użytkownika (0–7)
    /// plus `Init` (8). Tyle wpisuje `Format_11::W_ParamData::WrContext` oryginału.
    public static let storedVariationCount = 9
    /// Wariacja `Init` — źródło przycisku „Init" w pasku (Param Setting Copy(8, →)).
    /// Nie da się jej wybrać do grania.
    public static let initVariation = 8
    /// **Dziesiąty, wewnętrzny zestaw parametrów.** Nie ma go w pliku — powstaje tylko
    /// w edytorze i w syntezatorze. Patch Mutator przesłuchuje w nim dźwięki, żeby
    /// hodowla nie niszczyła ośmiu zapisanych wariacji; instrukcja Clavii nazywa go
    /// „a ninth, internal variation". Oryginalny edytor robi to
    /// Muta Synth Data (GetFocusIndividMolecules): zrzuca dźwięk do zestawu **9**
    /// i wysyła Param Setting Focus(9), czyli `0x6A` z numerem 9.
    public static let mutatorVariation = 9
    /// Ile zestawów trzymamy w pamięci: te z pliku plus bufor mutatora.
    public static let runtimeVariationCount = 10

    /// Przepisuje `parameters` każdego modułu z aktywnej wariacji. Wołane po wczytaniu
    /// patcha (plik lub urządzenie) i po zmianie wariacji — `parameters` to widok na
    /// jedną wariację, `parameterVariations` trzyma pełną prawdę i idzie do zapisu.
    public mutating func syncParametersToActiveVariation() {
        let variation = activeVariation
        for i in voiceModules.indices {
            if voiceModules[i].parameterVariations.indices.contains(variation) {
                voiceModules[i].parameters = voiceModules[i].parameterVariations[variation]
            }
        }
        for i in fxModules.indices {
            if fxModules[i].parameterVariations.indices.contains(variation) {
                fxModules[i].parameters = fxModules[i].parameterVariations[variation]
            }
        }
    }

    /// Zmienia aktywną wariację patcha i pokazuje jej wartości. Używane, gdy urządzenie
    /// zgłosi przełączenie wariacji na froncie (`SUB_COMMAND_SELECT_VARIATION`, 0x6A).
    public mutating func setActiveVariation(_ variation: Int) {
        description.variation = max(0, min(variation, Self.mutatorVariation))
        syncParametersToActiveVariation()
    }

    /// Dorabia brakujące zestawy parametrów do `runtimeVariationCount`. Plik przynosi
    /// dziewięć, bufor mutatora jest dziesiąty — powielamy w nim wariację `Init`,
    /// żeby nie był pusty, zanim mutator cokolwiek do niego wpisze.
    public mutating func ensureRuntimeVariations() {
        for i in voiceModules.indices {
            Self.pad(&voiceModules[i])
        }
        for i in fxModules.indices {
            Self.pad(&fxModules[i])
        }
        while variationSettings.count < Self.runtimeVariationCount {
            variationSettings.append(variationSettings.last ?? G2VariationSettings())
        }
        while morphAssignments.count < Self.runtimeVariationCount {
            morphAssignments.append(morphAssignments.last ?? [])
        }
    }

    private static func pad(_ module: inout G2Module) {
        guard !module.parameterVariations.isEmpty else { return }
        while module.parameterVariations.count < runtimeVariationCount {
            module.parameterVariations.append(module.parameterVariations.last ?? module.parameters)
        }
    }

    /// Moduły, którym plik nie przyniósł ANI JEDNEJ wartości parametru, dostają wartości
    /// domyślne typu — jak moduł świeżo postawiony z palety. W kolekcji to 2 pliki
    /// (m.in. „Very Saxy": cała warstwa FX bez parametrów). Bez tego gałki pokazują zera,
    /// klik w Power nic nie robi (indeks poza tablicą), a Nord dostaje moduły z Active = 0
    /// i warstwa milczy. Parser zostaje wierny plikowi — `PatchCheck` dalej to zgłasza.
    public mutating func fillMissingParameters() {
        for i in voiceModules.indices {
            Self.fillDefaults(&voiceModules[i])
        }
        for i in fxModules.indices {
            Self.fillDefaults(&fxModules[i])
        }
    }

    private static func fillDefaults(_ module: inout G2Module) {
        guard module.parameters.isEmpty,
              let def = ModuleDatabase.module(id: module.typeID),
              !def.paramNames.isEmpty
        else { return }
        var values = Array(ModuleDefaultsDatabase.defaults(forTypeID: module.typeID)
            .prefix(def.paramNames.count))
        values += Array(repeating: 0, count: def.paramNames.count - values.count)
        module.parameters = values
        module.parameterVariations = Array(repeating: values, count: runtimeVariationCount)
    }

    /// Przepisuje całą wariację na inną — parametry wszystkich modułów obu obszarów
    /// i ustawienia patcha (Glide/Bend/Vibrato…, sekcja `0x4d` obszaru 2). Dokładnie
    /// ten sam zestaw kopiuje oryginał: `CPatch::HandleParamSettingCopy` przechodzi po
    /// trzech obszarach (voice, fx, patch) i mapach morfów, BVerhue `TG2Patch.CopyVariation`
    /// po trzech `PatchPart` i liście parametrów patcha.
    ///
    /// Morfy jadą razem z resztą: gałki i źródła siedzą w `variationSettings`,
    /// przypisania w `morphAssignments` — obie rzeczy kopiujemy tak samo jak
    /// oryginał (Morph Map (CopyParamSetting) przepisuje całą mapę wariacji).
    ///
    /// Indeks 8 to wariacja **init** — jest zwykłą wariacją w tablicach, więc kopiowanie
    /// z niej (przycisk „Init") i do niej działa tą samą drogą.
    public mutating func copyVariation(from source: Int, to destination: Int) {
        let range = 0 ... Self.mutatorVariation
        guard source != destination, range.contains(source), range.contains(destination) else { return }
        for i in voiceModules.indices {
            copyVariation(from: source, to: destination, in: &voiceModules[i])
        }
        for i in fxModules.indices {
            copyVariation(from: source, to: destination, in: &fxModules[i])
        }
        if variationSettings.indices.contains(source), variationSettings.indices.contains(destination) {
            variationSettings[destination] = variationSettings[source]
        }
        if morphAssignments.indices.contains(source), morphAssignments.indices.contains(destination) {
            morphAssignments[destination] = morphAssignments[source]
        }
        // Gałki pokazują wariację aktywną — po przepisaniu tej właśnie muszą się odświeżyć.
        if destination == activeVariation { syncParametersToActiveVariation() }
    }

    private func copyVariation(from source: Int, to destination: Int, in module: inout G2Module) {
        guard module.parameterVariations.indices.contains(source),
              module.parameterVariations.indices.contains(destination) else { return }
        module.parameterVariations[destination] = module.parameterVariations[source]
    }

    /// Zmienia wartość parametru modułu (lokalnie — bez wysyłania do sprzętu).
    /// Zapisuje do aktywnej wariacji, nie na sztywno do zerowej.
    public mutating func setParameter(moduleID: Int, paramIndex: Int,
                                      value: Int, in area: PatchArea)
    {
        setParameter(moduleID: moduleID, paramIndex: paramIndex, value: value,
                     in: area, variation: activeVariation)
    }

    /// Jak wyżej, ale do WSKAZANEJ wariacji. Używane, gdy zmianę zgłasza urządzenie:
    /// Nord podaje w powiadomieniu numer wariacji, której dotyczy, i bywa to inna
    /// wariacja niż ta pokazywana w edytorze — wtedy dane trzeba zapisać, ale widoku
    /// (`parameters`) nie ruszać.
    public mutating func setParameter(moduleID: Int, paramIndex: Int,
                                      value: Int, in area: PatchArea, variation: Int)
    {
        let clamped = max(0, min(127, value))
        let isVisible = variation == activeVariation
        if area == .voice {
            if let i = voiceModules.firstIndex(where: { $0.id == moduleID }),
               paramIndex < voiceModules[i].parameters.count
            {
                if isVisible { voiceModules[i].parameters[paramIndex] = clamped }
                if voiceModules[i].parameterVariations.indices.contains(variation) {
                    voiceModules[i].parameterVariations[variation][paramIndex] = clamped
                }
            }
        } else {
            if let i = fxModules.firstIndex(where: { $0.id == moduleID }),
               paramIndex < fxModules[i].parameters.count
            {
                if isVisible { fxModules[i].parameters[paramIndex] = clamped }
                if fxModules[i].parameterVariations.indices.contains(variation) {
                    fxModules[i].parameterVariations[variation][paramIndex] = clamped
                }
            }
        }
    }

    /// Zmienia wartość trybu modułu (mode — np. DelayRange, Waveform).
    public mutating func setMode(moduleID: Int, modeIndex: Int,
                                 value: Int, in area: PatchArea)
    {
        let clamped = max(0, min(127, value))
        if area == .voice {
            if let i = voiceModules.firstIndex(where: { $0.id == moduleID }),
               modeIndex < voiceModules[i].modes.count
            {
                voiceModules[i].modes[modeIndex] = clamped
            }
        } else {
            if let i = fxModules.firstIndex(where: { $0.id == moduleID }),
               modeIndex < fxModules[i].modes.count
            {
                fxModules[i].modes[modeIndex] = clamped
            }
        }
    }
}
