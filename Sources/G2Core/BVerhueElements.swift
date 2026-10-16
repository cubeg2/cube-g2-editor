// BVerhueElements.swift
// G2Core — typy UI elementów parsowanych z plików .txt Bruno Verhue (NMG2Editor)
//
// Układ współrzędnych .txt:
//   Gen1 piksel → screen pt:  scale = 140.0 / 256.0 = 0.546875
//   Skalowanie X i Y jest identyczne (izotropowe).
//   Zastosowanie: ptX = XPos * scale,  ptY = YPos * scale
//
// CodeRef dla Input/Output → indeks gniazda w tablicy ModuleDef.inputs[] / .outputs[]
//   (po posortowaniu rosnąco po CodeRef — patrz BVerhueParser)

import CoreGraphics

// MARK: - Typy wyliczeniowe

public enum BVSignalType: String {
    case audio = "Audio"
    case control = "Control"
    case logic = "Logic"
    // Typy bikolorowe (protokół G2, nie BVerhue .txt — tworzone programowo z g2ools)
    case pitchOrControl // blue_red=4: lewa=czerwona, prawa=niebieska
    case logicOrControl // yellow_orange=5: lewa=żółta, prawa=pomarańczowa
}

public enum BVKnobType: String {
    case small = "Small"
    case medium = "Medium"
    case big = "Big"
    case resetMedium = "Reset/medium"
    case reset = "Reset"
    case sequencer = "Sequencer"
    case slider = "Slider"
    case seqSlider = "SeqSlider"
    case push = "Push"
    case box = "Box"
    case leftRight = "Left/Right"
    case amplifier = "Amplifier"
    case attack = "Attack"
    case decay = "Decay"

    /// Promień gałki w screen pt; 0 = nie rysuj jako knob.
    /// Źródło: GetKnobMetrics (BVE.NMG2TexturesGL.pas) — aKnobRect.Width/2 × (140/256).
    ///   ktBig d=22 → r=11 × 0.546875 = 6.016pt
    ///   ktMedium d=20 → r=10 × 0.546875 = 5.469pt
    ///   ktSmall d=18 → r=9 × 0.546875 = 4.922pt
    public var radiusPt: CGFloat {
        let s = CGFloat(140.0 / 256.0)
        switch self {
        case .big: return 11 * s // 6.016 pt
        case .medium: return 10 * s // 5.469 pt
        case .small: return 9 * s // 4.922 pt
        case .resetMedium: return 10 * s // same dial size as medium
        case .reset: return 9 * s // same dial size as small
        case .amplifier: return 10 * s // medium-sized
        case .attack: return 10 * s
        case .decay: return 10 * s
        case .leftRight: return 9 * s // compact knob
        case .sequencer: return 7 * s // small sequencer knob
        case .slider: return 0 // rysowany jako prostokąt
        case .seqSlider: return 0
        case .push: return 0
        case .box: return 0
        }
    }

    public var isRotary: Bool {
        radiusPt > 0
    }

    /// Mały trójkąt nad gałką przywraca wartość domyślną parametru.
    /// Źródło: UnitModuleDef.pas, CreateKnob(..., reset: true).
    public var hasResetButton: Bool {
        self == .reset || self == .resetMedium
    }

    /// Offset od XPos/YPos (top-left widget) → centrum gałki w screen pt.
    /// Wartości z GetKnobMetrics (BVE.NMG2TexturesGL.pas):
    ///   center_gen1 = (CalcRect.left + w/2, CalcRect.top + h/2) w jednostkach Gen1
    ///   screen pt = center_gen1 × (140/256)
    public var centerOffsetPt: CGPoint {
        let s = CGFloat(140.0 / 256.0) // scale gen1 → screen pt
        switch self {
        // GetKnobMetrics — aKnobRect = CalcRect(left, top, w, h)
        case .big: return CGPoint(x: 11 * s, y: 11 * s) // CalcRect(0,0,22,22)
        case .medium: return CGPoint(x: 11 * s, y: 10 * s) // CalcRect(1,0,20,20)
        case .small: return CGPoint(x: 11 * s, y: 9 * s) // CalcRect(2,0,18,18)
        case .reset: return CGPoint(x: 11 * s, y: 15 * s) // CalcRect(2,6,18,18)
        case .resetMedium: return CGPoint(x: 11 * s, y: 16 * s) // CalcRect(1,6,20,20)
        // Remaining rotary types — same dial width (22 DU) → X center = 11 DU; assume medium-sized Y
        case .amplifier: return CGPoint(x: 11 * s, y: 10 * s)
        case .attack: return CGPoint(x: 11 * s, y: 10 * s)
        case .decay: return CGPoint(x: 11 * s, y: 10 * s)
        case .leftRight: return CGPoint(x: 11 * s, y: 10 * s)
        case .sequencer: return CGPoint(x: 11 * s, y: 9 * s)
        // Non-rotary: offset not used (isRotary == false)
        default: return .zero
        }
    }

    /// Rozmiar slidera (szer × wys) w screen pt; używany gdy !isRotary
    public var sliderSizePt: CGSize {
        switch self {
        case .slider, .seqSlider: CGSize(width: 8, height: 14)
        case .push: CGSize(width: 8, height: 6)
        case .box: CGSize(width: 12, height: 8)
        default: CGSize(width: 8, height: 8)
        }
    }

    /// Offset Y (od top-left widgetu knoba) do górnej krawędzi paska ▼▲ przycisków (screen pt).
    /// Źródło: GetKnobMetrics — aBtnsRect.Top × (140/256).
    public var btnsTopOffsetPt: CGFloat {
        let s = CGFloat(140.0 / 256.0)
        switch self {
        case .big: return 18 * s
        case .medium, .amplifier,
             .attack, .decay: return 16 * s
        case .small, .leftRight: return 14 * s
        case .reset: return 20 * s
        case .resetMedium: return 22 * s
        case .sequencer: return 12 * s
        case .slider, .seqSlider,
             .push, .box: return 0
        }
    }

    /// Rozmiar paska ▼▲ przycisków inc/dec w screen pt (tylko dla knobów rotacyjnych).
    /// Źródło: GetKnobMetrics — aBtnsRect 22×9 Gen1px dla wszystkich rotary.
    public var btnsSizePt: CGSize {
        guard isRotary else { return .zero }
        let s = CGFloat(140.0 / 256.0)
        return CGSize(width: 22 * s, height: 9 * s)
    }
}

public enum BVLEDType: String {
    case green = "Green"
    case sequencer = "Sequencer"
}

// MARK: - Structs elementów UI

public struct BVKnob {
    public let id: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let codeRef: Int
    public let type: BVKnobType
    public let infoFunc: Int // używany przez TextField TextFunc:0 do formatowania wartości
}

public struct BVConnector {
    public let id: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let codeRef: Int
    public let signalType: BVSignalType
    public let isOutput: Bool
}

/// Przycisk z opcjami tekstowymi, np. "Off,On" lub "Semi,Freq,Fac,Part"
/// Gdy options=[] i imageCount>0 — przycisk wyłącznie ikonowy (np. Loop, Run selector).
public struct BVButtonFlat {
    public let id: Int
    public let xPt: CGFloat
    // Pozycja korygowana przez ModuleUILayout (np. Mix4-1S: „Exp" wyśrodkowany
    // między górną krawędzią panelu a gałką pod nim).
    public internal(set) var yPt: CGFloat
    public let codeRef: Int
    public let options: [String] // podzielone po przecinku z pola Text; [] = tylko ikona
    public let widthPt: CGFloat
    public let infoFunc: Int // InfoFunc z .txt — identyfikuje typ ikon (np. 9 = Loop)
    public let imageCount: Int // liczba stanów z ImageCount (0 = brak ikon)
}

/// Mały przycisk z ikoną (np. "M" = Mono toggle, Check style)
public struct BVButtonText {
    public let id: Int
    public internal(set) var xPt: CGFloat
    public internal(set) var yPt: CGFloat
    public let codeRef: Int
    public let text: String
    public let type: String // "Check" albo chwilowy "Push"
    /// Szerokość korygowana przez ModuleUILayout (np. Mix2-1B: „Inv" zwężony tak,
    /// żeby nie dotykał gniazda ani ekranu obok).
    public internal(set) var widthPt: CGFloat
}

/// Zestaw przycisków radio z grafiką (np. kształty fali LFO)
public struct BVButtonRadio {
    public let id: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let codeRef: Int
    public let buttonCount: Int
    public let buttonWidthPt: CGFloat
    /// InfoFunc z pliku .txt — identyfikuje typ ikon (fale, filtry, kształty…)
    public let infoFunc: Int
    /// "Horizontal" lub "Vertical" — orientacja przycisków
    public let orientation: String
    /// Siatka przycisków. Zwykłe ButtonRadio to jeden rząd (lub jedna kolumna przy
    /// Vertical); `<#ButtonRadioEdit` z grupy Switch ma pełną siatkę kolumn × rzędów.
    public let columns: Int
    public let rows: Int
    /// Etykiety tekstowe z pola Text: (np. ["BR","HP","BP","LP"])
    public let buttonLabels: [String]
    /// Dane pikselowe ikon z pola Image: (hex RGB, separator ":")
    /// Układ: wszystkie ikony obok siebie, szerokość paska = buttonCount × iconWidth
    public let iconPixels: [String]
    /// Szerokość jednej ikony w pikselach (ImageWidth z .txt)
    public let iconWidth: Int
}

/// Dioda LED (zielona lub sekwencerowa)
public struct BVLED {
    public let id: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let codeRef: Int
    public let type: BVLEDType
}

/// Mini VU meter — wskaźnik poziomu sygnału (15 segmentów, 3 strefy: zielona/żółta/czerwona).
/// Pozycje z MiniVUDatabase (statyczna tabela — nie ma ich w plikach .txt modułów).
/// Wartość poziomu 0–15 pochodzi z USB (Faza 2). Faza 1: zawsze 0 (dimmed idle).
public struct BVMiniVUDef {
    public let moduleID: Int
    public let id: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let groupID: Int
}

/// Suwak poziomu (LevelShift)
public struct BVLevelShift {
    public let id: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let codeRef: Int
}

/// Pole tekstowe wyświetlające wartość parametru
public struct BVTextField {
    public let id: Int
    public let xPt: CGFloat
    public internal(set) var yPt: CGFloat
    public internal(set) var masterRef: Int // CodeRef parametru który wyświetla
    public let widthPt: CGFloat
    public let textFunc: Int // indeks funkcji konwersji wartości → string
    public internal(set) var dependencies: [Int] // indeksy dodatkowych parametrów (np. fine, mode)
}

/// Przyciski +/- (inc/dec)
public struct BVButtonIncDec {
    public let id: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let codeRef: Int
    public let infoFunc: Int // InfoFunc:2 = SeqLen (1–16), 0 = raw
    /// Type:"Up/Down" (jeden nad drugim) vs Type:"Left/Right" (obok siebie) — wg oryginału Clavii
    public let isVertical: Bool
}

/// Statyczna etykieta tekstowa (rysowana gdy brak bitmapy PNG)
public struct BVTextLabel {
    public let id: Int
    public let xPt: CGFloat
    public internal(set) var yPt: CGFloat
    public let text: String
    public let fontSize: CGFloat // Gen1 FontSize (piksele), do przeliczenia na pt
}

/// Selektor ikon — pokazuje jedną ikonę na raz (aktualnie wybrany kształt fali, tryb…).
/// Warstwa UI rozwija dla niego listę dostępnych wartości.
/// Układ pikseli Image: sekwencyjny — każda ikona zajmuje imageWidth × iconHeight px.
public struct BVPartSelector {
    public let id: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let codeRef: Int
    public let infoFunc: Int // InfoFunc z .txt — identyfikuje rodzaj ikon (fale, tryby…)
    public let widthPt: CGFloat // szerokość wyświetlacza (Gen1 Width × scale)
    public let heightPt: CGFloat // wysokość jednej ikony (Gen1 Height × scale)
    public let imageCount: Int // liczba ikon / opcji
    public let imageWidth: Int // szerokość ikony w pikselach (Gen1)
    public let iconPixels: [String] // dane pikseli sekwencyjnie hex RGB (separator ":")
    /// true gdy pochodzi z ButtonFlat (codeRef = indeks parametru, nie trybu)
    public let usesParameter: Bool
}

/// Wykres graficzny (koperta ADSR, odpowiedź filtra, kształt fali)
public struct BVGraph {
    public let id: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat
    public let graphFunc: Int // rodzaj wykresu: 3=EnvADSR, 30=FltLP, 32=OscShp …
    /// Indeksy parametrów; stan przycisku Sn jest kodowany jako -n-1 (S0 → -1).
    public let dependencies: [Int]
}

/// Linia dekoracyjna (np. podkreślenie grupy przycisków, "schodek" łączący gałkę z radio-buttonami)
public struct BVLine {
    public let id: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let lengthPt: CGFloat
    public let isHorizontal: Bool
    public let isThick: Bool // Width:"Thick"/"Thin" z .txt
}

/// Ikona dekoracyjna (np. mała strzałka "Trig 1" przed "Sync"). Tylko jawnie
/// obsługiwane Type są rysowane (patrz drawBVSymbols) — inne są pomijane,
/// tak jak wcześniej, gdy Symbol nie był parsowany w ogóle.
public struct BVSymbol {
    public let id: Int
    /// Pozycja korygowana przez ModuleUILayout — strzałki „Trig" stojące zaraz za
    /// gniazdem dostają wszędzie ten sam odstęp od niego.
    public internal(set) var xPt: CGFloat
    public let yPt: CGFloat
    public let widthPt: CGFloat
    public let heightPt: CGFloat
    public let type: String // Type: z .txt, np. "Trig 1", "Amplifier"
}

/// Statyczna bitmapa `<#Bitmap` — schemat trasy sygnału rysowany w oryginale rastrem.
/// Trzymamy wyłącznie położenie i rozmiar źródłowy: same piksele odtwarzamy wektorowo,
/// żeby rysunek skalował się razem z modułem. Rozmiar identyfikuje rysunek
/// (23×16 = przełącznik pojedynczy, 24×16 = przełącznik przełączny, 11×12 = S&H).
public struct BVBitmap {
    public let id: Int
    public let xPt: CGFloat
    public let yPt: CGFloat
    public let widthPx: Int
    public let heightPx: Int
}

// MARK: - Definicja UI modułu

public struct ModuleUIDef {
    public let name: String
    public let fileName: String // FileName: z .txt — klucz do PNG bitmap (module_NNN_FileName.png)
    public let height: Int // wysokość w DB-rows (1 row = 15px Gen1)

    public let knobs: [BVKnob]
    public let inputs: [BVConnector] // posortowane po codeRef
    public let outputs: [BVConnector] // posortowane po codeRef
    /// Pozycja korygowana przez ModuleUILayout (Mix4-1S: „Exp" nad gałką).
    public internal(set) var buttonsFlat: [BVButtonFlat]
    // Pozycja korygowana przez ModuleUILayout (wyrównanie Power do sąsiadujących gniazd).
    public internal(set) var buttonsText: [BVButtonText]
    public let buttonsRadio: [BVButtonRadio]
    public let leds: [BVLED]
    public let levelShifts: [BVLevelShift]
    // Pozycja korygowana przez ModuleUILayout (np. KeyQuant: ekran "Range"
    // wyrównany do przycisku po lewej).
    public internal(set) var textFields: [BVTextField]
    public let incDecButtons: [BVButtonIncDec]
    public internal(set) var textLabels: [BVTextLabel] // statyczne napisy — widoczne gdy brak PNG
    public let graphs: [BVGraph] // wykresy graficzne (ADSR, filtry, kształty)
    public let partSelectors: [BVPartSelector] // selektory ikon (kształty fal, tryby…)
    public let lines: [BVLine] // linie dekoracyjne
    /// Pozycja korygowana przez ModuleUILayout (odstęp strzałek „Trig" od gniazd).
    public internal(set) var symbols: [BVSymbol] // ikony dekoracyjne (strzałki, symbole)
    public let bitmaps: [BVBitmap] // położenia rastrów odtwarzanych wektorowo
}

public extension ModuleUIDef {
    /// Suwaki kroków sekwencera nut — tylko one stoją na siatce pianoli i tylko dla
    /// nich rysujemy ją, przewijamy i przybliżamy.
    ///
    /// Samo `InfoFunc 13` (nazwa nuty) NIE wystarcza do rozpoznania: ma je też zwykła,
    /// OBROTOWA gałka „Note" w NoteSend i NoteRcv, a tam siatka nie ma czego opisywać —
    /// wychodziła zza gałki jako pasiasty prostokąt.
    var seqNoteKnobs: [BVKnob] {
        knobs.filter { $0.infoFunc == 13 && !$0.type.isRotary }
    }
}
