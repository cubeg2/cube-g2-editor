// G2TextDisplay.swift
// G2Core — funkcje formatowania wartości parametrów do wyświetlenia w TextField
//
// Źródło: g2_file.pas (Bruno Verhue NMG2Editor, open source)
//   TextFunction() — konwersja wg TextFunctionIndex + Dependencies
//   InfoFunction()  — konwersja wg InfoFunctionIndex (używana przez TextFunc:0)

import Foundation

// MARK: - Tablica rezonancji filtru (FILTER_RESONANCE)

/// Indeks 0–127 → wartość Q. Źródło: g2_types.pas.
private let filterResonance: [Double] = [
    0.50, 0.51, 0.51, 0.52, 0.53, 0.54, 0.55, 0.55,
    0.56, 0.57, 0.58, 0.59, 0.60, 0.61, 0.62, 0.63,
    0.64, 0.64, 0.66, 0.67, 0.68, 0.69, 0.70, 0.71,
    0.73, 0.74, 0.75, 0.76, 0.78, 0.79, 0.81, 0.82,
    0.84, 0.84, 0.87, 0.88, 0.90, 0.92, 0.94, 0.95,
    0.97, 0.99, 1.01, 1.03, 1.06, 1.08, 1.10, 1.12,
    1.15, 1.17, 1.20, 1.23, 1.25, 1.28, 1.31, 1.34,
    1.37, 1.41, 1.44, 1.48, 1.51, 1.55, 1.59, 1.63,
    1.67, 1.72, 1.76, 1.81, 1.86, 1.91, 1.97, 2.03,
    2.08, 2.15, 2.21, 2.28, 2.35, 2.42, 2.50, 2.58,
    2.67, 2.76, 2.85, 2.95, 3.05, 3.16, 3.28, 3.40,
    3.53, 3.67, 3.81, 3.96, 4.13, 4.30, 4.49, 4.68,
    4.89, 5.12, 5.36, 5.61, 5.89, 6.19, 6.51, 6.85,
    7.23, 7.64, 8.08, 8.56, 9.08, 9.66, 10.0, 11.0,
    12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 19.0, 20.0,
    22.0, 25.0, 27.0, 30.0, 34.0, 38.0, 44.0, 50.0,
]

// MARK: - Tablica czasów koperty (ENV_TIMES)

/// Indeks 0–127 → czas w sekundach. Źródło: g2_types.pas.
private let envTimes: [Double] = [
    0.0005, 0.0006, 0.0007, 0.0009, 0.0011, 0.0013, 0.0015, 0.0018,
    0.0021, 0.0025, 0.0030, 0.0035, 0.0040, 0.0047, 0.0055, 0.0063,
    0.0073, 0.0084, 0.0097, 0.0111, 0.0127, 0.0145, 0.0165, 0.0187,
    0.0212, 0.0240, 0.0271, 0.0306, 0.0344, 0.0387, 0.0434, 0.0486,
    0.0543, 0.0606, 0.0676, 0.0752, 0.0836, 0.0928, 0.1030, 0.1140,
    0.1260, 0.1390, 0.1530, 0.1690, 0.1860, 0.2040, 0.2240, 0.2460,
    0.2690, 0.2950, 0.3220, 0.3520, 0.3840, 0.4190, 0.4560, 0.4960,
    0.5400, 0.5860, 0.6360, 0.6900, 0.7480, 0.8100, 0.8760, 0.9470,
    1.0200, 1.1000, 1.1900, 1.2800, 1.3800, 1.4900, 1.6000, 1.7200,
    1.8500, 1.9900, 2.1300, 2.2800, 2.4600, 2.6200, 2.8100, 3.0000,
    3.2100, 3.4300, 3.6600, 3.9100, 4.1700, 4.4500, 4.7400, 5.0500,
    5.3700, 5.7200, 6.0800, 6.4700, 6.8700, 7.3000, 7.7500, 8.2200,
    8.7200, 9.2500, 9.8000, 10.400, 11.000, 11.600, 12.300, 13.000,
    13.800, 14.600, 15.400, 16.200, 17.100, 18.100, 19.100, 20.100,
    21.200, 22.400, 23.500, 24.800, 26.100, 27.500, 28.900, 30.400,
    32.000, 33.600, 35.300, 37.100, 38.900, 40.900, 42.900, 45.000,
]

// MARK: - Tablice modułów Level

/// Czasy EnvFollow i NoiseGate w milisekundach. Źródło: `g2_types.pas`;
/// wartości potwierdzone funkcjami ParamText Clavii 129, 130, 159 i 160.
private let envFollowAttackMs: [Double] = [
    0.00, 0.53, 0.56, 0.60, 0.64, 0.67, 0.72, 0.76,
    0.81, 0.86, 0.91, 0.97, 1.03, 1.09, 1.16, 1.23,
    1.30, 1.38, 1.47, 1.56, 1.66, 1.76, 1.87, 1.98,
    2.10, 2.23, 2.37, 2.52, 2.67, 2.84, 3.01, 3.20,
    3.39, 3.60, 3.83, 4.06, 4.31, 4.58, 4.86, 5.16,
    5.48, 5.82, 6.18, 6.56, 6.96, 7.39, 7.85, 8.33,
    8.84, 9.39, 9.97, 10.6, 11.2, 11.9, 12.7, 13.4,
    14.3, 15.2, 16.1, 17.1, 18.1, 19.3, 20.4, 21.7,
    23.0, 24.5, 26.0, 27.6, 29.3, 31.1, 33.0, 35.0,
    37.2, 39.5, 41.9, 44.5, 47.3, 50.2, 53.3, 56.5,
    60.0, 63.7, 67.7, 71.8, 76.3, 81.0, 86.0, 91.3,
    96.9, 103, 109, 116, 123, 131, 139, 147,
    156, 166, 176, 187, 199, 211, 224, 238,
    253, 268, 285, 302, 321, 341, 362, 384,
    408, 433, 459, 488, 518, 550, 584, 620,
    659, 699, 742, 787, 837, 888, 942, 1000,
]

private let envFollowReleaseMs: [Double] = [
    10.0, 10.5, 10.9, 11.4, 12.0, 12.5, 13.1, 13.7,
    14.3, 15.0, 15.7, 16.4, 17.1, 17.9, 18.8, 19.6,
    20.5, 21.5, 22.4, 23.5, 24.6, 25.7, 26.9, 28.1,
    29.4, 30.7, 32.1, 33.6, 35.2, 36.8, 38.5, 40.2,
    42.1, 44.0, 46.0, 48.2, 50.4, 52.7, 55.1, 57.6,
    60.3, 63.1, 66.0, 69.0, 72.2, 75.5, 78.9, 82.6,
    86.3, 90.3, 94.5, 98.8, 103, 108, 113, 118,
    124, 129, 135, 142, 148, 155, 162, 169,
    177, 185, 194, 203, 212, 222, 232, 243,
    254, 265, 278, 291, 304, 318, 332, 347,
    363, 380, 398, 416, 435, 455, 476, 498,
    521, 545, 570, 596, 624, 652, 682, 713,
    747, 780, 816, 854, 894, 934, 977, 1020,
    1070, 1120, 1170, 1220, 1280, 1340, 1400, 1460,
    1530, 1600, 1680, 1760, 1840, 1920, 2010, 2100,
    2200, 2300, 2410, 2520, 2630, 2760, 2870, 3000,
]

private let noiseGateAttackMs: [Double] = [
    0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 0.9, 1.0,
    1.2, 1.4, 1.6, 1.7, 2.0, 2.2, 2.4, 2.6,
    2.9, 3.1, 3.4, 3.7, 4.0, 4.3, 4.6, 4.9,
    5.3, 5.6, 6.0, 6.3, 6.7, 7.1, 7.5, 7.9,
    8.4, 8.8, 9.3, 9.7, 10.2, 10.7, 11.2, 11.7,
    12.2, 12.7, 13.3, 13.8, 14.4, 14.9, 15.5, 16.1,
    16.7, 17.4, 18.0, 18.6, 19.3, 19.9, 20.6, 21.3,
    22.0, 22.7, 23.4, 24.1, 24.9, 25.6, 26.4, 27.2,
    28.0, 28.8, 29.6, 30.4, 31.2, 32.1, 32.9, 33.8,
    34.6, 35.5, 36.4, 37.3, 38.3, 39.2, 40.1, 41.1,
    42.0, 43.0, 44.0, 45.0, 46.0, 47.0, 48.1, 49.1,
    50.2, 51.2, 52.3, 53.4, 54.5, 55.6, 56.7, 57.9,
    59.0, 60.2, 61.3, 62.5, 63.7, 64.9, 66.1, 67.3,
    68.6, 69.8, 71.1, 72.3, 73.6, 74.9, 76.2, 77.5,
    78.8, 80.2, 81.5, 82.9, 84.2, 85.6, 87.0, 88.4,
    89.8, 91.2, 92.7, 94.1, 95.6, 97.0, 98.5, 100,
]

private let noiseGateReleaseMs: [Double] = [
    0.5, 0.59, 0.67, 0.76, 0.87, 0.98, 1.11, 1.25,
    1.40, 1.57, 1.75, 1.95, 2.17, 2.41, 2.66, 2.94,
    3.25, 3.57, 3.92, 4.30, 4.71, 5.15, 5.62, 6.12,
    6.66, 7.24, 7.85, 8.51, 9.21, 9.96, 10.7, 11.6,
    12.5, 13.4, 14.4, 15.5, 16.6, 17.8, 19.1, 20.4,
    21.8, 23.3, 24.9, 26.5, 28.2, 30.0, 32.0, 34.0,
    36.1, 38.3, 40.6, 43.0, 45.5, 48.2, 51.0, 53.9,
    56.9, 60.1, 63.4, 66.8, 70.4, 74.2, 78.1, 82.2,
    86.4, 90.9, 95.5, 100, 105, 110, 116, 121,
    127, 133, 139, 146, 153, 160, 167, 174,
    182, 190, 198, 207, 216, 225, 234, 244,
    254, 265, 275, 286, 298, 310, 322, 335,
    348, 361, 375, 389, 404, 419, 434, 450,
    467, 484, 501, 519, 537, 556, 578, 596,
    616, 638, 659, 682, 705, 728, 752, 777,
    802, 828, 855, 883, 911, 940, 970, 1000,
]

/// Tabela dB LevAmp. Źródło: tablica Clavii `ampGainNew`, niezależnie
/// potwierdzona przez ParamConstants.LEV_AMP_DB w G2FX.
private let levAmpDb: [Double] = [
    -.infinity, -39.6, -33.6, -30.1, -27.6, -25.7, -24.1, -22.7,
    -21.6, -20.6, -19.6, -18.8, -18.1, -17.4, -16.7, -16.1,
    -15.6, -15.0, -14.5, -14.1, -13.6, -13.2, -12.8, -12.4,
    -12.0, -11.7, -11.4, -11.1, -10.8, -10.5, -10.2, -9.9,
    -9.6, -9.3, -9.0, -8.7, -8.4, -8.1, -7.8, -7.5,
    -7.2, -6.9, -6.6, -6.3, -6.0, -5.7, -5.4, -5.1,
    -4.8, -4.5, -4.2, -3.9, -3.6, -3.3, -3.0, -2.7,
    -2.4, -2.1, -1.8, -1.5, -1.2, -0.9, -0.6, -0.3,
    0.0, 0.2, 0.4, 0.6, 0.8, 0.9, 1.1, 1.3,
    1.5, 1.7, 1.9, 2.1, 2.3, 2.4, 2.6, 2.8,
    3.0, 3.2, 3.4, 3.6, 3.8, 4.0, 4.1, 4.3,
    4.5, 4.7, 4.9, 5.1, 5.3, 5.5, 5.6, 5.8,
    6.0, 6.2, 6.4, 6.6, 6.8, 7.0, 7.2, 7.4,
    7.6, 7.8, 8.0, 8.2, 8.4, 8.5, 8.7, 8.9,
    9.1, 9.3, 9.5, 9.7, 9.9, 10.1, 10.3, 10.5,
    10.7, 10.9, 11.1, 11.3, 11.5, 11.7, 11.8, 12.0,
]

// MARK: - Tablica czasów Glide (GLIDE_TIME)

/// Indeks 0–127 → czas w milisekundach. Źródło: g2_types.pas GLIDE_TIME[].
private let glideTime: [Double] = [
    0.2, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.9,
    1.0, 1.2, 1.4, 1.7, 2.0, 2.3, 2.7, 3.1,
    3.6, 4.2, 4.8, 5.5, 6.3, 7.2, 8.2, 9.3,
    11, 12, 14, 15, 17, 19, 22, 24,
    27, 30, 34, 38, 42, 46, 51, 57,
    63, 69, 77, 84, 93, 102, 112, 123,
    135, 147, 161, 178, 192, 209, 228, 248,
    270, 293, 318, 345, 374, 405, 438, 473,
    511, 552, 595, 642, 691, 744, 800, 860,
    924, 992, 1100, 1100, 1200, 1300, 1400, 1500,
    1600, 1700, 1800, 2000, 2100, 2200, 2400, 2500,
    2700, 2900, 3000, 3200, 3400, 3600, 3900, 4100,
    4400, 4600, 4900, 5200, 5500, 5800, 6100, 6500,
    6900, 7300, 7700, 8000, 8600, 9000, 9500, 10100,
    10600, 11100, 11700, 12400, 13000, 13700, 14400, 15200,
    15800, 16800, 17500, 18300, 19200, 20200, 21200, 22400,
]

// MARK: - Tablica czasów Glide dla Shape:Lin (zmierzona empirycznie)

/// Glide Shape:Lin NIE ma tabeli w źródle referencyjnym (reimplementacja Bruno Verhue
/// nigdy nie rozróżnia Log/Lin przy formatowaniu Time — potwierdzona luka, bug #18
/// w Docs/context/bug-history.md). Punkty kotwiczące zmierzone przez użytkownika na
/// oryginalnym oprogramowaniu Clavia (WINE), ta sama pozycja gałki, Log↔Lin:
///   index 0   → Log≈0.2m    Lin≈0.2m/oct  (nierozróżnialne przy tej precyzji)
///   index 43  → Log=84m     Lin=79m/oct
///   index 64  → Log=511m    Lin=480m/oct
///   index 79  → Log=1.5s    Lin=1.4s/oct
///   index 96  → Log=4.4s    Lin=4.1s/oct
///   index 110 → Log=9.5s    Lin=9.1s/oct
///   index 127 → Log=22.4s   Lin=23.5s/oct
/// Interpolacja liniowa między kotwicami — dokładna wartość między nimi nieznana,
/// ale to najlepsze dostępne przybliżenie bez wymyślonego wzoru.
private let glideTimeLinAnchors: [(idx: Int, ms: Double)] = [
    (0, 0.2), (43, 79), (64, 480), (79, 1400), (96, 4100), (110, 9100), (127, 23500),
]

private func glideTimeLin(_ index: Int) -> Double {
    let v = max(0, min(127, index))
    let anchors = glideTimeLinAnchors
    if v <= anchors[0].idx { return anchors[0].ms }
    if v >= anchors[anchors.count - 1].idx { return anchors[anchors.count - 1].ms }
    for i in 0 ..< anchors.count - 1 {
        let a = anchors[i], b = anchors[i + 1]
        if v >= a.idx, v <= b.idx {
            let t = Double(v - a.idx) / Double(b.idx - a.idx)
            return a.ms + t * (b.ms - a.ms)
        }
    }
    return anchors[anchors.count - 1].ms
}

// MARK: - Publiczne accessory do tablic

/// Zwraca wartość Q rezonancji filtra dla parametru 0–127.
/// Źródło: g2_types.pas FILTER_RESONANCE[]. Zakres: 0.50–50.
public func g2FilterResonance(_ index: Int) -> Double {
    filterResonance[max(0, min(127, index))]
}

/// Zwraca czas koperty (w sekundach) dla wartości parametru 0–127.
/// Używane przez rendering wykresu ADSR.
public func g2EnvTime(_ index: Int) -> Double {
    envTimes[max(0, min(127, index))]
}

// MARK: - Pomocnicze formatowanie

// Źródło: zrzut prawdziwego edytora Clavii od użytkownika (2026-08-13) — MasterOsc
// pokazuje "67.3Hz" dla ~67.34Hz. BVerhue (DrumSynth.txt, TextField ID15/16) deklaruje
// dla MasterOsc i SlaveOsc IDENTYCZNĄ szerokość pola (Width:40) — ekran nie skaluje
// fontu ani nie ściska odstępów (jak wcześniej zakładaliśmy), tylko obcina w pełni
// precyzyjną wartość do stałej liczby znaków mieszczącej się w polu. "67.3" to
// dokładnie 4 znaki (cyfry+kropka) — stąd G2FloatToStrFixed(hz, 4), nie 5 (dawało 2
// miejsca: "67.34") ani stałe "%.2f" (dawało też 2 miejsca, błędne dla tej wartości).
private func g2Freq(_ hz: Double) -> String {
    if hz >= 1000 { return g2FloatToStrFixed(hz / 1000, 4) + "kHz" }
    return g2FloatToStrFixed(hz, 4) + "Hz"
}

private func g2Time(_ s: Double) -> String {
    if s < 1.0 { return String(format: "%.3gm", s * 1000) }
    return String(format: "%.3gs", s)
}

/// Oryginał Clavii przechowuje teksty czasów obwiedni w osobnej tabeli po 6 znaków.
/// W przeciwieństwie do ogólnego formattera nie obcina zera dla całych sekund.
private func g2EnvelopeTime(_ s: Double) -> String {
    if s < 1.0 { return String(format: "%.3gm", s * 1000) }
    if s == s.rounded() { return String(format: "%.1fs", s) }
    return String(format: "%.3gs", s)
}

/// Format czasu stosowany przez FloatToStrTime.
private func g2LevelTime(_ milliseconds: Double) -> String {
    if milliseconds < 10 { return String(format: "%.2fm", milliseconds) }
    if milliseconds < 100 { return String(format: "%.1fm", milliseconds) }
    if milliseconds < 1000 { return String(format: "%.0fm", milliseconds) }
    if milliseconds < 10000 { return String(format: "%.2fs", milliseconds / 1000) }
    return String(format: "%.1fs", milliseconds / 1000)
}

/// NoiseGate Attack w Clavii pochodzi z gotowej tabeli napisów. Wartości mają
/// zmienną precyzję i nie są dopełniane zerami (np. domyślne "0.2m").
private func g2NoiseGateAttackTime(_ milliseconds: Double) -> String {
    g2FloatToStr(milliseconds, 4) + "m"
}

private func g2Signed(_ v: Int) -> String {
    v >= 0 ? "+\(v)" : "\(v)"
}

/// Odpowiednik G2FloatToStr(aValue, aLen) z g2_types.pas.
/// aLen = łączna liczba znaków w liczbie (cyfry + kropka dziesiętna).
/// Np. aLen=4: 699→"699", 62.9→"62.9", 0.26→"0.26", 0.026→"0.026"
private func g2FloatToStr(_ value: Double, _ len: Int) -> String {
    let absVal = abs(value)
    var fl = 1
    var intpart = absVal
    while intpart > 10 {
        fl += 1
        intpart /= 10
    }
    let decimals = len - (fl + 1)
    if decimals > 0 {
        let p = pow(10.0, Double(decimals))
        let t = (value * p).rounded()
        var result = String(format: "%.\(decimals)f", t / p)
        while result.last == "0" {
            result.removeLast()
        }
        if result.last == "." { result.removeLast() }
        return result
    } else {
        return String(Int(value.rounded()))
    }
}

/// Odpowiednik G2FloatToStrFixed(aValue, aLen) z g2_types.pas.
/// Jak g2FloatToStr, ale zawsze dopełnia zerami do dokładnie aLen znaków.
/// Np. aLen=4: 50.0→"50.0", 0.5→"0.50", 2.08→"2.08"
private func g2FloatToStrFixed(_ value: Double, _ len: Int) -> String {
    let absVal = abs(value)
    var fl = 1
    var intpart = absVal
    while intpart >= 10 {
        fl += 1
        intpart /= 10
    }
    let decimals = len - (fl + 1)
    if decimals > 0 {
        let p = pow(10.0, Double(decimals))
        let t = (value * p).rounded()
        var s = String(format: "%.\(decimals)f", t / p)
        // dopełnij zerami jeśli FloatToStr obciął (np. "0.5" → "0.50")
        let targetLen = value < 0 ? len + 1 : len
        while s.count < targetLen {
            s += "0"
        }
        return s
    } else {
        return String(Int(value.rounded()))
    }
}

// MARK: - Czasy Delay

/// Odpowiednik `DelayDispValue(0)` z BVerhue: DlySingleA/B, DelayDual i DelayQuad.
private func g2DelayStaticTime(value: Int, range: Int) -> String {
    let value = max(0, min(127, value))
    let range = max(0, min(6, range))
    if value == 0 { return "0.01m" }

    let limits: [(min: Double, max: Double)] = [
        (0.05, 5.3), (0.21, 25.1), (0.8, 100), (3.95, 500),
        (7.89, 1000), (15.8, 2000), (21.3, 2700),
    ]
    let limit = limits[range]
    let milliseconds = limit.min + (limit.max - limit.min) * Double(value - 1) / 126.0

    switch range {
    case 4 where value == 127:
        return "1.000s"
    case 5 where value >= 64, 6 where value >= 48:
        return g2FloatToStr(milliseconds / 1000.0, 5) + "s"
    case 6:
        return g2FloatToStr(milliseconds, 5) + "m"
    default:
        return g2FloatToStr(milliseconds, 4) + "m"
    }
}

/// Odpowiednik `DelayDispValue(1)` z BVerhue: DlyEight.
private func g2DelayEightTime(value: Int, range: Int) -> String {
    let maximums: [Double] = [0.66, 3.14, 12.6, 62.5, 125, 250, 338]
    let maximum = maximums[max(0, min(6, range))]
    return g2FloatToStr(maximum * Double(max(0, min(127, value))) / 127.0, 4) + "m"
}

/// Odpowiednik `DelayDispValue(2)` z BVerhue: DlyA i DlyB.
private func g2DelayTime(value: Int, range: Int) -> String {
    g2LinearDelayTime(value: value, range: range, maximums: [500, 1000, 2000, 2700],
                      secondsFrom: [128, 127, 64, 48])
}

/// Odpowiednik `DelayDispValue(3)` z BVerhue: DlyStereo.
private func g2DelayStereoTime(value: Int, range: Int) -> String {
    g2LinearDelayTime(value: value, range: range, maximums: [500, 1000, 1351],
                      secondsFrom: [128, 127, 95])
}

private func g2LinearDelayTime(value: Int, range: Int, maximums: [Double], secondsFrom: [Int]) -> String {
    let value = max(0, min(127, value))
    let range = max(0, min(maximums.count - 1, range))
    if value == 0 { return "0.01m" }
    if range == 1, value == 127 { return "1.00s" }

    let milliseconds = maximums[range] * Double(value) / 127.0
    if value >= secondsFrom[range] {
        return g2FloatToStr(milliseconds / 1000.0, 5) + "s"
    }
    return g2FloatToStr(milliseconds, 4) + "m"
}

/// Odpowiednik `DelayDispValue(4)` z BVerhue. Różni się od synchronizacji LFO.
func g2DelayClockSync(_ value: Int) -> String {
    let values = [
        "1/64T", "1/64", "1/32T", "1/64D", "1/32", "1/16T", "1/32D", "1/16",
        "1/16", "1/8T", "1/8T", "1/16D", "1/16D", "1/8", "1/8", "1/4T",
        "1/4T", "1/8D", "1/8D", "1/4", "1/4", "1/2T", "1/2T", "1/4D",
        "1/4D", "1/2", "1/2", "1/1T", "1/2D", "1/1", "1/1D", "2/1",
    ]
    return values[max(0, min(127, value)) / 4]
}

private func g2PulseDelayTime(value: Int, range: Int) -> String {
    let source = g2PulseDelayRange[max(0, min(127, value))]
    let milliseconds: Double = switch range {
    case 0: source / 100
    case 1: source / 10
    default: source
    }
    if milliseconds < 1000 { return g2FloatToStrFixed(milliseconds, 4) + "m" }
    return g2FloatToStrFixed(milliseconds / 1000, 4) + "s"
}

private func g2FreqShift(value: Int, range: Int) -> String {
    let index = max(0, min(127, value))
    let values = switch range {
    case 0: g2FreqShiftSub
    case 1: g2FreqShiftLo
    default: g2FreqShiftHi
    }
    // Clavia zachowuje trzy miejsca po przecinku dokładnie przy zerze ("0.000Hz"),
    // ale dla pozostałych wartości nie dopisuje sztucznych zer (np. "8.78Hz").
    let frequency = values[index]
    let text = frequency == 0 ? "0.000" : g2FloatToStr(frequency, 5)
    return text + "Hz"
}

/// Pitch Ratio modułu Scratch. Parametr jest symetryczny wokół zera, z osobnym
/// znakiem przed prefiksem „x” po stronie ujemnej ("-x4.00", nie "x-4.00").
public func g2ScratchPitchRatio(_ value: Int) -> String {
    let v = max(0, min(127, value))
    if v == 0 { return "-x4.00" }
    if v == 127 { return "x4.00" }

    let ratio = Double(v - 64) / 16.0
    let prefix = ratio < 0 ? "-x" : "x"
    return prefix + String(format: "%.2f", abs(ratio))
}

/// Brightness Reverbu jest skalą 0...100 bez znaku procenta na ekranie Clavii.
public func g2ReverbBrightness(_ value: Int) -> String {
    let v = max(0, min(127, value))
    return "\(Int((100.0 * Double(v) / 127.0).rounded()))"
}

/// Rezonans FltClassic zachowuje skalę poziomu 0...100, ale ekran nie pokazuje
/// części dziesiętnej. Wartość 127 jest osobnym końcem skali równym 100.
public func g2FltClassicResonanceText(_ value: Int) -> String {
    let v = max(0, min(127, value))
    return v == 127 ? "100" : "\(v * 100 / 128)"
}

/// Tablice `COMPR_*_TIMES` ze źródeł referencyjnych Clavii. Są celowo tabelami,
/// ponieważ oryginał nie używa pojedynczego równania dla całego zakresu.
private let compressorAttackTimes = [
    "Fast", "0.53m", "0.56m", "0.59m", "0.63m", "0.67m", "0.71m", "0.75m",
    "0.79m", "0.84m", "0.89m", "0.94m", "1.00m", "1.06m", "1.12m", "1.19m",
    "1.26m", "1.33m", "1.41m", "1.50m", "1.59m", "1.68m", "1.78m", "1.89m",
    "2.00m", "2.12m", "2.24m", "2.38m", "2.52m", "2.67m", "2.83m", "3.00m",
    "3.17m", "3.36m", "3.56m", "3.78m", "4.00m", "4.24m", "4.49m", "4.76m",
    "5.04m", "5.34m", "5.66m", "5.99m", "6.35m", "6.73m", "7.13m", "7.55m",
    "8.00m", "8.48m", "8.98m", "9.51m", "10.1m", "10.7m", "11.3m", "12.0m",
    "12.7m", "13.5m", "14.3m", "15.1m", "16.0m", "17.0m", "18.0m", "19.0m",
    "20.2m", "21.4m", "22.6m", "24.0m", "25.4m", "26.9m", "28.5m", "30.2m",
    "32.0m", "33.9m", "35.9m", "38.1m", "40.3m", "42.7m", "45.3m", "47.9m",
    "50.8m", "53.8m", "57.0m", "60.4m", "64.0m", "67.8m", "71.8m", "76.1m",
    "80.6m", "85.4m", "90.5m", "95.9m", "102m", "108m", "114m", "121m",
    "128m", "136m", "144m", "152m", "161m", "171m", "181m", "192m",
    "203m", "215m", "228m", "242m", "256m", "271m", "287m", "304m",
    "323m", "342m", "362m", "384m", "406m", "431m", "456m", "483m",
    "512m", "542m", "575m", "609m", "645m", "683m", "724m", "767m",
]

private let compressorReleaseTimes = [
    "125m", "129m", "134m", "139m", "144m", "149m", "154m", "159m",
    "165m", "171m", "177m", "183m", "189m", "196m", "203m", "210m",
    "218m", "225m", "233m", "241m", "250m", "259m", "268m", "277m",
    "287m", "297m", "308m", "319m", "330m", "342m", "354m", "366m",
    "379m", "392m", "406m", "420m", "435m", "451m", "467m", "483m",
    "500m", "518m", "536m", "555m", "574m", "595m", "616m", "637m",
    "660m", "683m", "707m", "732m", "758m", "785m", "812m", "841m",
    "871m", "901m", "933m", "966m", "1.00s", "1.04s", "1.07s", "1.11s",
    "1.15s", "1.19s", "1.23s", "1.27s", "1.32s", "1.37s", "1.41s", "1.46s",
    "1.52s", "1.57s", "1.62s", "1.68s", "1.74s", "1.80s", "1.87s", "1.93s",
    "2.00s", "2.07s", "2.14s", "2.22s", "2.30s", "2.38s", "2.46s", "2.55s",
    "2.64s", "2.73s", "2.83s", "2.93s", "3.03s", "3.14s", "3.25s", "3.36s",
    "3.48s", "3.61s", "3.73s", "3.86s", "4.00s", "4.14s", "4.29s", "4.44s",
    "4.59s", "4.76s", "4.92s", "5.10s", "5.28s", "5.46s", "5.66s", "5.86s",
    "6.06s", "6.28s", "6.50s", "6.73s", "6.96s", "7.21s", "7.46s", "7.73s",
    "8.00s", "8.28s", "8.57s", "8.88s", "9.19s", "9.51s", "9.85s", "10.2s",
]

/// POPRAWIONE 2026-08-13: prosta formuła `(value+9)%12` / `(value+9)/12 - 1`, BEZ dodatkowego
/// przesunięcia i BEZ trójkąta stałoprzecinkowego z Semitone. Wcześniejsza wersja
/// (oparta o DXBreakPoint→`Semitone`) miała
/// dodatkowe +3 i przybliżenie stałoprzecinkowe oktawy — mimo pozornej zgodności,
/// funkcja DXBreakPoint okazała się NIE być tą, której realnie używa BrPoint Operatora (błędne
/// dopasowanie mimo zgodności z mapą TextFunc 197 → prawdopodobnie inny wariant/kontekst tej
/// samej etykiety TextFunc w różnych klasach). Rozstrzygnięte przez użytkownika zrzutami
/// prawdziwego edytora: wartość 0 → "A-1", wartość 99 → "C8" — ta prosta formuła jest jedyną
/// spójną z OBU skrajnymi wartościami I z wcześniej potwierdzonym środkiem (wartość 50 → "B3",
/// czyli oryginalna wartość domyślna z generatora, którą błędnie "naprawiono" na 47 pod starą,
/// mylną formułę — przywrócona w ModuleDefaultsDatabase.swift).
private func g2OperatorBreakPoint(_ value: Int) -> String {
    let v = max(0, min(99, value)) + 9
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let noteIndex = v % 12
    let octave = v / 12 - 1
    return "\(names[noteIndex])\(octave)"
}

private func g2OperatorFrequency(value: Int, detune: Int, mode: Int) -> String {
    if mode == 0 {
        let base = value == 0 ? 0.5 : Double(value)
        return "x" + g2FloatToStrFixed(base + base * Double(detune) / 100.0, 4)
    }
    let frequency = pow(10.0, Double(max(0, value) % 4))
    if frequency >= 1000 { return g2FloatToStrFixed(frequency / 1000.0, 5) + "kHz" }
    return g2FloatToStrFixed(frequency, 5) + "Hz"
}

/// Odpowiednik G2BPM(aValue) z g2_types.pas — integer lookup BPM.
private func g2BPM(_ v: Int) -> String {
    if v <= 32 { return "\(24 + 2 * v)" }
    if v <= 96 { return "\(88 + v - 32)" }
    return "\(152 + (v - 96) * 2)"
}

// MARK: - InfoFunction (konwersja jednego parametru wg indeksu funkcji)

/// Formatuje wartość `val` (0–127) wg kodu InfoFunction.
/// Odpowiada TG2FileParameter.InfoFunction(aIndex) z g2_file.pas.
private func g2LevelFrom0to100(_ value: Int) -> String {
    switch value {
    case 0: "0"
    case 32: "25"
    case 64: "50"
    case 96: "75"
    case 127: "100"
    default: String(format: "%.1f", Double(value) * 100.0 / 128.0)
    }
}

/// Odczyt poziomu miksera w decybelach — dB jak w oryginalnym edytorze.
/// Wartości brzegowe są w oryginale wpisane na sztywno, reszta to
/// logarytm z wartości znormalizowanej do pełnej skali.
///
/// Oryginał liczy `log10(x·C1 + x³·C2) · C3`, a stałych nie dało się odczytać wprost.
/// Rozstrzygnął je zrzut z oryginalnego edytora (2026-08-27): przy domyślnym
/// poziomie 100 MixFader pokazuje `-6.2`, co daje `C1 = 0, C2 = 1, C3 = 20`,
/// czyli **argumentem logarytmu jest x³** — poziom miksera jest sześcienny,
/// nie liniowy. Potwierdzają to też wartości brzegowe: przy tej skali `v = 1`
/// wypada na −126 dB, a `v = 2` na −108 dB, więc oryginał podmienia je na umowne
/// dno „-99.9"/„-99.0"; przy zwykłym `20·log10(x)` (−42 i −36 dB) te stałe nie
/// miałyby sensu.
public func g2MixerDecibels(_ value: Int) -> String {
    switch value {
    case 0: return "-oo"
    case 1: return "-99.9"
    case 2: return "-99.0"
    case 127: return "-0"
    default:
        let x = Double(value) / 127.0
        let decibels = 20 * log10(x * x * x)
        let decimals = decibels < -1 ? 1 : 0
        return String(format: "%.*f", decimals, decibels)
    }
}

/// Przełączniki grupy Mixer — wydzielone z głównego przełącznika tak samo jak
/// odczyty kategorii Level, żeby nie rozrastać złożoności `g2InfoFunction`.
/// Oba mają po TRZY pozycje; wcześniej zwracały tylko dwie pierwsze.
private func g2MixerInfoFunction(_ infoFunc: Int, value: Int) -> String? {
    switch infoFunc {
    case 169: // ExpLin — Table("Exp","Lin","dB"). Miksery mają wszystkie
        // trzy pozycje; ModAmt tylko dwie (`Text:"Exp,Lin"`), więc trzecia nie wypadnie.
        switch value {
        case 0: "Exp"
        case 1: "Lin"
        default: "dB"
        }
    case 57, 188: // dB_0_6_12 (Mix8-1A) i Pad (Mix4-1C,
        // Mix8-1B, MixFader) — ta sama treść, `Text:" 0dB,-6dB,-12dB"` w Gen1.
        switch value {
        case 0: "0dB"
        case 1: "-6dB"
        default: "-12dB"
        }
    default:
        nil
    }
}

/// Funkcje tekstowe specyficzne dla kategorii Level, wydzielone z głównego
/// przełącznika, aby zachować czytelność i limit złożoności `g2InfoFunction`.
private func g2LevelInfoFunction(_ infoFunc: Int, value: Int) -> String? {
    switch infoFunc {
    case 129: // EnvFollow Attack
        if value == 0 { return "Fast" }
        return g2LevelTime(envFollowAttackMs[value])
    case 130: // EnvFollow Release
        return g2LevelTime(envFollowReleaseMs[value])
    case 159: // NoiseGate Attack
        return g2NoiseGateAttackTime(noiseGateAttackMs[value])
    case 160: // NoiseGate Release
        return g2LevelTime(noiseGateReleaseMs[value])
    case 220: // NoiseGate Threshold / PitchTrack Threshold
        if value == 0 { return "-oo" }
        if value == 127 { return "-0dB" }
        let decibels = 20 * log10(Double(value) / 127.0)
        let decimals = decibels < -1 ? 1 : 0
        return String(format: "%.*fdB", decimals, decibels)
    default:
        return nil
    }
}

public func g2InfoFunction(_ infoFunc: Int, val: Int) -> String {
    let v = max(0, min(127, val))
    if let levelText = g2LevelInfoFunction(infoFunc, value: v) {
        return levelText
    }
    if let mixerText = g2MixerInfoFunction(infoFunc, value: v) {
        return mixerText
    }
    switch infoFunc {
    // 500 to numer, którego oryginał w ogóle nie zna — BVerhue Gen1 wpisał go
    // szesnastu suwakom SeqCtr (jedyne wystąpienie w całej bazie 192 plików).
    // Oryginalny panel Clavii (SeqVolt) ma tam InfoFunc:0, więc suwaki mają pokazywać
    // zwykłą skalę 0–100, tak samo jak kroki SeqLev i SeqVal.
    // 56 to X-Fade z Mux8-1X — jedyne wystąpienie tego numeru w całej bazie Gen1.
    // Jego ParamDef (Id 71) ma RangeType `Level_100`, więc surowe 0…127 ma się
    // pokazywać jako 0…100, dokładnie tak jak przy InfoFunc 0.
    case 0, 56, 500: // Level 0–100 bez sufiksu, From0to100
        return g2LevelFrom0to100(v)

    case 2: // SeqLen / DlyClk → indeks+1
        return "\(v + 1)"

    case 11: // Note count
        return v == 0 ? "Off" : "\(v)"

    case 12: // Raw int
        return "\(v)"

    case 17: // Bipolar –64..64 (BiPol nie dopisuje znaku plus)
        let i = v == 127 ? 64 : v - 64
        return "\(i)"

    case 19: // Pan –64..+64
        let p = v - 64
        if p == 0 { return "0" }
        return g2Signed(p)

    case 21: // DrumSynth NoiseFltFreq
        let freq = 440.0 * pow(2.0, Double(v - 65) / 12.0)
        return g2Freq(freq)

    case 22: // DrumSynth MasterFreq
        return g2Freq(20.02 * pow(2.0, Double(v) / 24.0))

    case 28: // Env Attack/Decay/Release czasy
        let t = v < envTimes.count ? envTimes[v] : 45.0
        return g2EnvelopeTime(t)

    case 35: // Note quant range
        if v == 0 { return "0" }
        if v == 127 { return "±64" }
        return String(format: "±%.1f", Double(v) / 2.0)

    case 36: // EqPeak Gain dB
        let db = (v == 127 ? 64.0 : Double(v - 64)) / 3.55555
        return String(format: "%.1fdB", db)

    case 38: // EqPeak Freq
        return g2Freq(20.0 * pow(2.0, Double(v) / 13.169))

    case 39: // FltPhase Freq
        return g2Freq(100.0 * pow(2.0, Double(v) / 17.34515804))

    case 123: // Flt Freq (FltNord, FltClassic, FltLP, FltHP…)
        // Źródło: g2_file.pas case 123 — Exponent=(v-60)/12, Freq=440*2^Exponent
        // v=0 → 13.75 Hz,  v=127 → ≈21.1 kHz
        return g2Freq(440.0 * pow(2.0, Double(v - 60) / 12.0))

    case 124: // Flt Resonance
        // Źródło: g2_file.pas case 124: G2FloatToStrFixed(FILTER_RESONANCE[v], 4)
        // Wartości <10 → 2 miejsca dziesiętne ("0.50"…"9.66")
        // Wartości ≥10 → integer ("10"…"50") — tabela zawiera tylko liczby całkowite ≥10
        let q = v < filterResonance.count ? filterResonance[v] : 50.0
        if q >= 10.0 { return String(Int(q.rounded())) }
        return g2FloatToStrFixed(q, 4)

    case 191: // Flt Freq Mod (pokrętło modulacji częstotliwości)
        // Źródło: g2_file.pas case 191 — 200*v/127 %
        return String(format: "%.1f%%", 200.0 * Double(v) / 127.0)

    case 7: // Muted/Active (ButtonText mono/poly)
        return v == 0 ? "Muted" : "Active"

    case 47: // General On/Off
        return v == 0 ? "Off" : "On"

    case 126: // OscShpA Shape: 50%–99% (50 + 50*val/128)
        return "\(Int(50.0 + 50.0 * Double(v) / 128.0))%"

    case 128: // LfoShpA Shape: 1%–97% (1 + 97*val/127)
        return "\(Int(1.0 + 97.0 * Double(v) / 127.0))%"

    case 52: // Fade2-1 Mix
        let t52 = v - 64
        if t52 == 0 { return "Mute" }
        if t52 == -64 { return "I1:127" }
        if t52 < 0 { return "I1:\(-t52 * 2)" }
        if t52 == 63 { return "I2:127" }
        return "I2:\(t52 * 2)"

    // ── Następujące case'y ze źródła g2_file.pas ──────────────────────────────

    case 3: // KB tracking: Off/On
        return v == 0 ? "Off" : "On"

    case 4: // Voice mode
        return v == 0 ? "Poly" : "Mono"

    case 5: // Mixer polarity
        return v == 0 ? "Normal" : "Inverted"

    case 8: // Bypass/Active (filtry, efekty)
        return v == 0 ? "Bypass" : "Active"

    case 9: // Seq cycles
        return v == 0 ? "1-Cycle" : "Loop"

    case 13: // Note name — GetKeyName: oktawa = v div 12 - 1 (g2_types.pas), tak samo
        // jak Semitone w oryginale. Mieliśmy tu -2, więc dymek suwaka
        // SeqNote pokazywał nutę o oktawę niżej niż ekran nuty tego samego modułu.
        let noteNamesG = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(noteNamesG[v % 12])\(v / 12 - 1)"

    case 16: // Env Sustain (uproszczone — bez kontekstu LevelShift → Pos)
        // Oryginał pokazuje jedno miejsce po przecinku ("50.0"), nie samo "50".
        return String(format: "%.1f", Double(v) / 2.0)

    case 18: // Polarity
        return v == 0 ? "Bipol" : "Unipol"

    case 23: // DrumSynth SlaveRatio — zrzut prawdziwego edytora Clavii pokazuje "X1.24"
        // (2026-08-13); pole ma tę samą szerokość co MasterOsc (BVerhue Width:40), więc
        // ten sam limit 4 znaków (cyfry+kropka) co g2Freq(), nie zmienna "%.4g".
        if v == 0 { return "1:1" }
        if v == 48 { return "2:1" }
        if v == 96 { return "4:1" }
        return "x" + g2FloatToStrFixed(pow(2.0, Double(v) / 48.0), 4)

    case 26: // Osc KBT
        return v == 0 ? "KBT Off" : "KBT On"

    case 30: // FreqShift Range
        switch v { case 0: return "Sub"
        case 1: return "Lo"
        default: return "Hi" }

    case 43: // Env/Seq Gate/Trigger
        return v == 0 ? "Trig" : "Gate"

    case 46: // LevelShift output type
        switch v {
        case 0: return "Pos"
        case 1: return "PosInv"
        case 2: return "Neg"
        case 3: return "NegInv"
        case 4: return "Bip"
        default: return "BipInv"
        }

    case 49: // Env L1/L2
        return v == 0 ? "L1" : "L2"

    case 50: // Env L1/L2/L3/Trg
        switch v { case 0: return "L1"
        case 1: return "L2"
        case 2: return "L3"
        default: return "Trg" }

    case 53: // Fade1-2 Mix (O1/O2)
        let t53 = v - 64
        if t53 == 0 { return "Mute" }
        if t53 == -64 { return "O1:127" }
        if t53 < 0 { return "O1:\(-t53 * 2)" }
        if t53 == 63 { return "O2:127" }
        return "O2:\(t53 * 2)"

    case 55: // LevMod ModType
        switch v { case 0: return "None"
        case 64: return "Am"
        case 127: return "Rm"
        default: return "\(v)" }

    case 58: // Osc Waveform (OscA podstawowy)
        switch v {
        case 0: return "Sine"
        case 1: return "Tri"
        case 2: return "Saw"
        case 3: return "Sqr50"
        case 4: return "Sqr25"
        default: return "Sqr10"
        }

    case 59: // Osc Fine (centy) — (v-64)*100/128
        let cents = (v - 64) * 100 / 128
        return cents >= 0 ? "+\(cents)" : "\(cents)"

    case 63: // Osc Freq mode
        switch v { case 0: return "Semi"
        case 1: return "Freq"
        case 2: return "Factor"
        default: return "Partial" }

    case 64: // Switch selector (1-based)
        return "\(v + 1)"

    case 68: // PartQuant range
        if v > 64 { return "±\(v / 2)*" }
        return "±\(v / 2)"

    case 69: // NoteScaler range
        if v == 127 { return "±64.0" }
        let r69 = String(format: "±%.1f", Double(v) / 2.0)
        if v % 24 == 0 { return r69 + "-Oct" }
        if v % 24 % 20 == 0 { return r69 + "-7th" }
        if v % 24 % 14 == 0 { return r69 + "-5th" }
        return r69

    case 70: // LevelScaler Gain dB
        if v == 64 { return "0.0dB" }
        return String(format: "%.1fdB", -8.0 + 16.0 * Double(v) / 127.0)

    case 71: // Flt KBT
        switch v {
        case 0: return "KBT Off"
        case 1: return "KBT 25%"
        case 2: return "KBT 50%"
        case 3: return "KBT75%"
        default: return "KBT 100%"
        }

    case 72: // Flt GainCompensation
        return v == 0 ? "GC Off" : "GC On"

    case 73: // Flt Slope
        return v == 0 ? "6dB" : "12dB"

    case 74: // FltNord dB/Oct
        return v == 0 ? "12dB" : "24dB"

    case 75: // FltNord FilterType: 0=LP 1=BP 2=HP 3=BR
        switch v { case 0: return "LP"
        case 1: return "BP"
        case 2: return "HP"
        default: return "BR" }

    case 76: // EqPeak BandWidth
        return String(format: "%.2fOct", (128.0 - Double(v)) / 64.0)

    case 78: // FltVoice Vowel
        let vowels = ["A", "E", "I", "O", "U", "Y", "AA", "AE", "OE"]
        return v < vowels.count ? vowels[v] : "\(v)"

    case 79: // Vocoder BandSel
        return v == 0 ? "Off" : "\(v)"

    case 80: // Vocoder Emphasis
        return v == 0 ? "Off" : "On"

    case 81: // Vocoder Monitor
        return v == 0 ? "Active" : "Monitor"

    case 82: // Clip shape
        return v == 0 ? "Asym" : "Sym"

    case 83: // Rect Mode
        switch v { case 0: return "HalfPos"
        case 1: return "HalfNeg"
        case 2: return "FullPos"
        default: return "FullNeg" }

    case 84: // ShpStatic Mode
        switch v { case 0: return "Inv x3"
        case 1: return "Inv x2"
        case 2: return "x2"
        default: return "x3" }

    case 88: // Digitizer Rate: 440*2^((v-45)/12)
        return g2Freq(440.0 * pow(2.0, Double(v - 45) / 12.0))

    case 90: // Reverb RoomType
        switch v { case 0: return "Small"
        case 1: return "Medium"
        case 2: return "Large"
        default: return "Hall" }

    case 93: // FltClassic dB/Oct
        switch v { case 0: return "12dB"
        case 1: return "18dB"
        default: return "24dB" }

    case 104: // LFO Range
        switch v { case 0: return "Sub"
        case 1: return "Lo"
        case 2: return "Hi"
        case 3: return "BPM"
        default: return "Clk" }

    case 105: // LfoA KBT
        switch v {
        case 0: return "KBT off"
        case 1: return "KBT 25%"
        case 2: return "KBT 50%"
        case 3: return "KBT 75%"
        default: return "KBT 100"
        }

    case 106: // LfoA Wave
        switch v {
        case 0: return "Sine"
        case 1: return "Tri"
        case 2: return "Saw"
        case 3: return "Sqr"
        case 4: return "RndStep"
        default: return "Rnd"
        }

    case 108: // MIDI Channel Send — PatchMIDIOutChannel, tabela 21 pozycji
        switch v {
        case 0 ... 15: return "\(v + 1)"
        case 16: return "This"
        case 17: return "Slot A"
        case 18: return "Slot B"
        case 19: return "Slot C"
        default: return "Slot D"
        }

    case 109: // MIDI Channel Receive — PatchMIDIInChannel, tabela 18 pozycji
        switch v {
        case 0 ... 15: return "\(v + 1)"
        case 16: return "This"
        default: return "Keyb"
        }

    case 114: // ValSw2-1
        return v == 63 ? "64" : "\(v)"

    case 125: // Osc FM Mod
        return v == 0 ? "FM Lin" : "FM Trk"

    case 127: // LevConv InputType
        switch v { case 0: return "Bipol"
        case 1: return "Pos"
        default: return "Neg" }

    case 134: // SeqCtrl XFade — XFade: Off / 25% / 50% / 100%
        switch v { case 0: return "Off"
        case 1: return "25%"
        case 2: return "50%"
        default: return "100%" }

    case 136: // Env Shape
        switch v { case 0: return "LogExp"
        case 1: return "LinExp"
        case 2: return "ExpExp"
        default: return "LinLin" }

    case 138: // Env Normal/Reset
        return v == 0 ? "Normal" : "Reset"

    case 139: // Env AD/AR
        return v == 0 ? "AD" : "AR"

    case 144: // Dly Time/ClkSync
        return v == 0 ? "Time" : "ClkSync"

    case 148: // LevAmp Type
        return v == 0 ? "Lin" : "dB"

    case 149: // FX In pad
        switch v { case 0: return "+6dB"
        case 1: return "0dB"
        case 2: return "-6dB"
        default: return "-12dB" }

    case 150: // 2-In source
        switch v { case 0: return "In 1/2"
        case 1: return "In 3/4"
        case 2: return "Bus 1/2"
        default: return "Bus 3/4" }

    case 152: // FX In source
        return v == 0 ? "Fx 1/2" : "Fx 3/4"

    case 155: // OscA Waveform
        switch v {
        case 0: return "Sine1"
        case 1: return "Sine2"
        case 2: return "Sine3"
        case 3: return "Sine4"
        case 4: return "TriSaw"
        default: return "Pulse"
        }

    case 156: // OscB Waveform
        switch v {
        case 0: return "Sine"
        case 1: return "Tri"
        case 2: return "Saw"
        case 3: return "Sqr"
        default: return "DualSaw"
        }

    case 157: // Glide shape
        return v == 0 ? "Log" : "Lin"

    case 163, 185: // LFO/Osc phase (°): round(v/128*360)
        return "\(Int((Double(v) / 128.0 * 360.0).rounded()))°"

    case 164: // LFO wave (LfoC/LfoB)
        switch v { case 0: return "Sine"
        case 1: return "Tri"
        case 2: return "Saw"
        default: return "Sqr" }

    case 165: // LfoShpA Wave
        switch v {
        case 0: return "Sine"
        case 1: return "CosBell"
        case 2: return "TriBell"
        case 3: return "Saw2Tri"
        case 4: return "Sqr2Tri"
        default: return "Sqr"
        }

    case 166: // ClkGen BeatSync
        switch v { case 0: return "1"
        case 1: return "2"
        case 2: return "4"
        case 3: return "8"
        case 4: return "16"
        default: return "32" }

    case 167: // Overdrive Type
        switch v { case 0: return "Soft"
        case 1: return "Hard"
        case 2: return "Fat"
        default: return "Heavy" }

    case 168: // Overdrive Shape
        return v == 0 ? "Asym" : "Sym"

    case 170: // Phaser Type
        return v == 0 ? "Type I" : "Type II"

    case 172: // FltPhase Type (1-6)
        return "\(v + 1)"

    case 173: // FltComb Freq: 440*2^((v-69)/12)
        return g2Freq(440.0 * pow(2.0, Double(v - 69) / 12.0))

    case 174, 175: // Compressor Attack / Release
        return [compressorAttackTimes, compressorReleaseTimes][infoFunc - 174][v]

    case 176: // Compressor Threshold
        return v == 42 ? "Off" : "\(v - 30)dB"

    case 177: // Compressor Ratio
        if v < 10 { return String(format: "%.1f:1", 1.0 + Double(v) / 10.0) }
        if v < 25 { return String(format: "%.1f:1", Double(v) / 5.0) }
        if v < 35 { return String(format: "%.0f:1", 5.0 + Double(v - 25) / 2.0) }
        if v < 45 { return "\(10 + (v - 35)):1" }
        if v < 60 { return "\(20 + (v - 45) * 2):1" }
        return "\(50 + (v - 60) * 5):1"

    case 178: // Compressor RefLevel
        return "\(v - 30)dB"

    case 180: // Out Pad
        switch v { case 0: return "0dB"
        case 1: return "+6dB"
        case 2: return "+12dB"
        default: return "+18dB" }

    case 181: // MonoKey priority
        switch v { case 0: return "Last"
        case 1: return "Low"
        default: return "High" }

    case 182: // Out destination
        switch v {
        case 0: return "Out 1/2"
        case 1: return "Out 3/4"
        case 2: return "Fx 1/2"
        case 3: return "Fx 3/4"
        case 4: return "Bus 1/2"
        default: return "Bus 3/4"
        }

    case 183: // 4-Out destination
        switch v { case 0: return "Out"
        case 1: return "Fx"
        default: return "Bus" }

    case 184: // Eq3Band MidFreq: 100*2^(v/20.089)
        return g2Freq(100.0 * pow(2.0, Double(v) / 20.089))

    case 187: // ClkGen Source
        return v == 0 ? "Intern" : "Master"

    case 189: // ModAmt InvertMode
        return v == 0 ? "m" : "1-m"

    case 190: // ClkGen Swing
        return String(format: "%.1f%%", 50.0 + 25.0 * Double(v) / 127.0)

    case 192: // ShpExp Curve
        switch v { case 0: return "x2"
        case 1: return "x3"
        case 2: return "x4"
        default: return "x5" }

    case 194: // Key Quant capture
        return v == 0 ? "Closest" : "Evenly"

    case 195: // Digitizer Bits
        return v == 12 ? "Off" : "\(v + 1)"

    case 196: // Operator FreqDetune
        return "\(v - 7)"

    case 200: // Operator freq mode
        return v == 0 ? "Ratio" : "Fixed"

    case 202: // PShift Delay
        switch v { case 0: return "12.5m"
        case 1: return "25m"
        case 2: return "50m"
        default: return "100m" }

    case 203: // Random Step
        switch v { case 0: return "0%"
        case 1: return "25%"
        case 2: return "50%"
        case 3: return "75%"
        default: return "100%" }

    case 204: // RandomA OutType
        switch v { case 0: return "Bip"
        case 1: return "Pos"
        default: return "Neg" }

    case 205, 212: // Random Clk Step / RndTrig Step
        return "\(100 * v / 127)%"

    case 207: // RandomA Step
        switch v { case 0: return "25%"
        case 1: return "50%"
        case 2: return "75%"
        default: return "100%" }

    case 210: // NoteZone ThruMode
        return v == 0 ? "Notes" : "Note+CC"

    case 211: // Automate Echo
        return v == 0 ? "EchoOff" : "EchoOn"

    case 213: // Eq2Band LoFreq
        switch v { case 0: return "80Hz"
        case 1: return "110Hz"
        default: return "160Hz" }

    case 214: // Eq2Band HiFreq
        switch v { case 0: return "6kHz"
        case 1: return "8kHz"
        default: return "12kHz" }

    case 215: // Flanger Rate (tablica FLANGER_RATE z g2_types.pas)
        let flangerRate: [Double] = [
            0.01, 0.02, 0.05, 0.07, 0.09, 0.11, 0.14, 0.16,
            0.18, 0.21, 0.23, 0.25, 0.27, 0.30, 0.32, 0.34,
            0.37, 0.39, 0.41, 0.43, 0.46, 0.48, 0.50, 0.53,
            0.55, 0.57, 0.60, 0.62, 0.64, 0.66, 0.69, 0.71,
            0.73, 0.76, 0.78, 0.80, 0.82, 0.85, 0.87, 0.89,
            0.92, 0.94, 0.96, 0.98, 1.01, 1.03, 1.05, 1.08,
            1.10, 1.12, 1.14, 1.17, 1.19, 1.21, 1.24, 1.26,
            1.28, 1.30, 1.33, 1.35, 1.37, 1.40, 1.42, 1.44,
            1.46, 1.49, 1.51, 1.53, 1.56, 1.58, 1.60, 1.63,
            1.65, 1.67, 1.69, 1.72, 1.74, 1.76, 1.79, 1.81,
            1.83, 1.85, 1.88, 1.90, 1.92, 1.95, 1.97, 1.99,
            2.01, 2.04, 2.06, 2.08, 2.11, 2.13, 2.15, 2.17,
            2.20, 2.22, 2.24, 2.27, 2.29, 2.31, 2.33, 2.36,
            2.38, 2.40, 2.43, 2.45, 2.47, 2.49, 2.52, 2.54,
            2.56, 2.59, 2.61, 2.63, 2.66, 2.68, 2.70, 2.72,
            2.75, 2.77, 2.79, 2.82, 2.84, 2.86, 2.88, 2.91,
        ]
        return String(format: "%.4gHz", v < flangerRate.count ? flangerRate[v] : 2.91)

    case 216: // Phaser Freq (tablica PHASER_FREQ z g2_types.pas)
        let phaserFreq: [Double] = [
            0.05, 0.05, 0.05, 0.05, 0.06, 0.06, 0.07, 0.08,
            0.09, 0.10, 0.12, 0.13, 0.15, 0.17, 0.19, 0.21,
            0.23, 0.25, 0.28, 0.30, 0.33, 0.36, 0.39, 0.42,
            0.46, 0.49, 0.53, 0.57, 0.61, 0.65, 0.69, 0.73,
            0.78, 0.82, 0.87, 0.92, 0.97, 1.02, 1.08, 1.13,
            1.19, 1.25, 1.31, 1.37, 1.43, 1.49, 1.56, 1.63,
            1.69, 1.76, 1.83, 1.91, 1.98, 2.05, 2.13, 2.21,
            2.29, 2.37, 2.45, 2.53, 2.62, 2.71, 2.80, 2.88,
            2.98, 3.07, 3.16, 3.26, 3.35, 3.45, 3.55, 3.65,
            3.75, 3.86, 3.96, 4.07, 4.18, 4.29, 4.40, 4.51,
            4.62, 4.74, 4.86, 4.97, 5.09, 5.21, 5.34, 5.46,
            5.58, 5.71, 5.84, 5.97, 6.10, 6.23, 6.37, 6.50,
            6.64, 6.77, 6.92, 7.06, 7.20, 7.34, 7.49, 7.63,
            7.78, 7.93, 8.08, 8.23, 8.39, 8.54, 8.70, 8.86,
            9.02, 9.18, 9.34, 9.50, 9.67, 9.84, 10.0, 10.2,
            10.3, 10.5, 10.7, 10.9, 11.0, 11.2, 11.4, 11.6,
        ]
        return String(format: "%.4gHz", v < phaserFreq.count ? phaserFreq[v] : 11.6)

    case 218: // DrumSynth NoiseFltMode
        switch v { case 0: return "LP"
        case 1: return "BP"
        default: return "HP" }

    default:
        return "\(v)"
    }
}

// MARK: - Herce gałek, z których da się nazwać nutę

/// Częstotliwość w hercach stojąca za odczytem gałki — tylko tam, gdzie da się z niej
/// nazwać nutę: odcięcie filtrów (`123`, 440 Hz przy 60) i FltComb (`173`, 440 Hz przy 69).
/// Każdy z tych modułów ma inne odniesienie, więc nuty nie liczy się z wartości gałki,
/// tylko właśnie z herców. `nil` dla wszystkiego innego — także dla czasów, BPM i Digitizer
/// Rate, gdzie nuta nic nie znaczy.
public func g2PitchedHertz(infoFunc: Int, value: Int) -> Double? {
    switch infoFunc {
    case 123: 440.0 * pow(2.0, Double(value - 60) / 12.0)
    case 173: 440.0 * pow(2.0, Double(value - 69) / 12.0)
    default: nil
    }
}

/// To samo dla LFO (`TextFunc 103`) — wyłącznie w trybie **Rate Hi** (mode 2), który sięga
/// pasma słyszalnego (0,26–392 Hz) i bywa używany jako oscylator. Rate Sub, Rate Lo,
/// BPM i Clk zostają bez nuty: pierwsze dwa chodzą w sekundach, dwa ostatnie w tempie.
public func g2LFOHighRateHertz(mode: Int, value: Int) -> Double? {
    guard mode == 2 else { return nil }
    return 0.2555 * pow(2.0, Double(value) / 12.0)
}

// MARK: - FreqDispValue (konwersja częstotliwości oscylatora)

/// Formatuje wyświetlanie częstotliwości oscylatora.
/// mode 0=Semi, 1=Freq, 2=Fac, 3=Part, 4=SemiPShift
public func g2FreqDispValue(mode: Int, course: Int, fine: Int) -> String {
    switch mode {
    case 0: // Semi: ±semitony  ±centy
        let semi = course - 64
        let cent = (fine - 64) * 100 / 128
        return "\(g2Signed(semi))  \(g2Signed(cent))"

    case 1: // Freq: Hz/kHz (A=440Hz przy course=69, fine=64)
        let exp = (Double(course - 69) + Double(fine - 64) / 128.0) / 12.0
        return g2Freq(440.0 * pow(2.0, exp))

    case 2: // Fac: multiplikator relative — Clavia SlaveMult, param_3=3: zawsze
        // 3 miejsca po kropce (nie zmienna liczba cyfr znaczących jak wcześniejsze "%.4g").
        // UWAGA: to NIE jest ścieżka używana przez DrumSynth MasterOsc/SlaveOsc (te idą
        // przez TextFunc:0 → g2InfoFunction case 23 "DrumSynth SlaveRatio" — osobna
        // funkcja, patrz tam) — mode 2 tutaj obsługuje inne moduły dzielące TextFunc:60.
        let exp = (Double(course - 64) + Double(fine - 64) / 128.0) / 12.0
        return String(format: "x%.3f", pow(2.0, exp))

    case 3: // Part: stosunek lub Hz dla niskich wartości
        if course <= 32 {
            let exp = -(Double((32 - course) * 4) + 77.0 - Double(fine - 64) / 128.0) / 12.0
            return g2Freq(440.0 * pow(2.0, exp))
        }
        let num = course <= 64 ? "1:\(64 - course + 1)" : "\(course - 64 + 1):1"
        let cent = (fine - 64) * 100 / 128
        return "\(num)  \(g2Signed(cent))"

    default: // 4 = Semi PShift (±semitony/4)
        let semi = course - 64
        let cent = (fine - 64) * 100 / 128
        return String(format: "%.2f  %@", Double(semi) / 4.0, g2Signed(cent))
    }
}

// MARK: - LFO clock sync values

func g2LFOClockStr(_ val: Int) -> String {
    switch val {
    case 0 ... 3: "64/1"
    case 4 ... 7: "48/1"
    case 8 ... 11: "32/1"
    case 12 ... 15: "24/1"
    case 16 ... 19: "16/1"
    case 20 ... 23: "12/1"
    case 24 ... 27: "8/1"
    case 28 ... 31: "6/1"
    case 32 ... 35: "4/1"
    case 36 ... 39: "3/1"
    case 40 ... 43: "2/1"
    case 44 ... 47: "1/1D"
    case 48 ... 51: "1/1"
    case 52 ... 55: "1/2D"
    case 56 ... 59: "1/1T"
    case 60 ... 63: "1/2"
    case 64 ... 67: "1/4D"
    case 68 ... 71: "1/2T"
    case 72 ... 75: "1/4"
    case 76 ... 79: "1/8D"
    case 80 ... 83: "1/4T"
    case 84 ... 87: "1/8"
    case 88 ... 91: "1/16D"
    case 92 ... 95: "1/8T"
    case 96 ... 99: "1/16"
    case 100 ... 103: "1/32D"
    case 104 ... 107: "1/16T"
    case 108 ... 111: "1/32"
    case 112 ... 115: "1/64D"
    case 116 ... 119: "1/32T"
    case 120 ... 123: "1/64"
    default: "1/64T"
    }
}

// MARK: - TextFunction (główny punkt wejścia)

/// Etykieta tekstowa dla trybu PartSelectora (mode-type selectors wyświetlające tekst, nie ikony).
/// Zwraca nil gdy brak hardcoded etykiety (→ fallback do bitmap icons).
/// modeName: wartość ModuleDef.modeNames[modeIndex] (np. "DelayRange").
public func g2ModeLabel(modeName: String, value: Int) -> String? {
    switch modeName {
    case "DelayRange":
        // DelayRange_2: 0=500m, 1=1.0s, 2=2.0s, 3=2.7s (DelayA/B — Dual/Quad
        // używają DelayRange_3, 7 stanów, patrz case "DelayRange3" niżej)
        switch value { case 0: "500m"
        case 1: "1.0s"
        case 2: "2.0s"
        default: "2.7s" }

    case "DelayRange3":
        // DelayRange_3: 0=5m, 1=25m, 2=100m, 3=500m, 4=1.0s, 5=2.0s, 6=2.7s
        // (DlySingleA/B, DelayDual, DelayQuad, DlyEight)
        switch value { case 0: "5m"
        case 1: "25m"
        case 2: "100m"
        case 3: "500m"
        case 4: "1.0s"
        case 5: "2.0s"
        default: "2.7s" }

    case "DelayRange1":
        // DelayRange_1: 0=500m, 1=1.0s, 2=1.35s (DlyStereo)
        switch value { case 0: "500m"
        case 1: "1.0s"
        default: "1.35s" }

    // ── Tekstowe selektory trybów (g2ools params.py → definitions) ────────
    case "RoomType":
        // id=12 Reverb. RoomType: 0=Small, 1=Medium, 2=Large, 3=Hall
        switch value { case 0: "Small"
        case 1: "Med"
        case 2: "Large"
        default: "Hall" }

    case "GateMode1", "GateMode2":
        // id=64 Gate (dwa selektory). GateMode: AND/NAND/OR/NOR/XOR/XNOR
        switch value { case 0: "AND"
        case 1: "NAND"
        case 2: "OR"
        case 3: "NOR"
        case 4: "XOR"
        default: "XNOR" }

    case "DivMode":
        // id=69 ClkDiv. ClkDivMode: 0=Gated, 1=Toggled
        switch value { case 0: "Gated"
        default: "Toggled" }

    case "SlopeMode":
        // id=87, 134 FltHP/FltLP. HpLpSlopeMode: 6-36 dB/Oct
        switch value { case 0: "6dB/Oct"
        case 1: "12dB/Oct"
        case 2: "18dB/Oct"
        case 3: "24dB/Oct"
        case 4: "30dB/Oct"
        default: "36dB/Oct" }

    case "OperationMode":
        // id=91 FlipFlop. FlipFlopMode: 0=D type, 1=SR type
        switch value { case 0: "D type"
        default: "SR type" }

    case "Character":
        // id=206 RndClkA. Rnd_1: 0=Rnd1, 1=Rnd2
        switch value { case 0: "Rnd1"
        default: "Rnd2" }

    case "PulseMode":
        // id=38 Pulse. PulseMode: 0=Positive edge trigger, 1=Negative edge trigger
        switch value { case 0: "Pos"
        default: "Neg" }

    case "LogicDelayMode":
        // id=42 Logic Delay. LogicDelayMode: 0=Pos edge, 1=Neg edge, 2=Cycle delay
        switch value { case 0: "Pos edge"
        case 1: "Neg edge"
        default: "Cycle" }

    default: nil
    }
}

/// Oblicza string do wyświetlenia w TextField.
///
/// - textFunc:    wartość "Text Func:" z .txt
/// - deps:        indeksy do params[] (int ≥ 0) lub do modes[] (int < 0, kodowanie: -n-1 = modes[n])
/// - params:      tablica wartości parametrów modułu (module.parameters)
/// - modes:       tablica trybów modułu (module.modes)
/// - knobInfoFunc: InfoFunc knoba o codeRef == masterRef (dla textFunc=0)
public func g2TextFunction(
    textFunc: Int,
    deps: [Int],
    params: [Int],
    modes: [Int] = [],
    knobInfoFunc: Int
) -> String {
    func depVal(_ i: Int) -> Int {
        guard i < deps.count else { return 0 }
        let idx = deps[i]
        // idx < 0: jest to referencja do modes[] (kodowanie: -n-1 = modes[n])
        if idx < 0 {
            let modeIdx = -idx - 1
            return modeIdx < modes.count ? modes[modeIdx] : 0
        }
        return idx < params.count ? params[idx] : 0
    }

    let v = depVal(0)

    switch textFunc {
    // ── 0: delegacja do InfoFunction knoba (kurs/fine/att/dec/rel etc.) ──────
    case 0:
        return g2InfoFunction(knobInfoFunc, val: v)

    // ── 2: SeqLen / DlyClk — indeks+1 (MIDI 0 = "1", 15 = "16") ─────────────
    case 2:
        return "\(v + 1)"

    // ── 13: Filter freq Nord (alias InfoFunc 13) ─────────────────────────────
    case 13:
        return g2InfoFunction(13, val: v)

    // ── 60: Osc freq — kurs(deps[0]) fine(deps[1]) mode(deps[2]) ─────────────
    case 60:
        let course = depVal(0)
        let fine = depVal(1)
        let mode = depVal(2)
        return g2FreqDispValue(mode: mode, course: course, fine: fine)

    // ── 96: Constant/LevAdd — zależne od BiP/Uni ─────────────────────────────
    case 96:
        if depVal(1) == 0 {
            return "\(v == 127 ? 64 : v - 64)"
        }
        return String(format: "%.1f", v == 127 ? 64.0 : Double(v) / 2.0)

    // ── 99–101: Switch selectors (×4 scaling) ────────────────────────────────
    case 99, 100, 101:
        return "\(v * 4)"

    // ── 102: poziom miksera — value(deps[0]) tryb Exp/Lin/dB(deps[1]) ────────
    // Źródło: dBLin w oryginalnym edytorze (GetDualDependencyTextFunction,
    // case 0x66) — `if (mode == 2) dB(v) else From0to100(v)`. Trzecia pozycja
    // przełącznika „Exp,Lin,dB" (InfoFunc:169) przestawia CAŁY odczyt na decybele;
    // Exp i Lin pokazują ten sam procent 0–100.
    case 102:
        return depVal(1) == 2 ? g2MixerDecibels(v) : g2InfoFunction(0, val: v)

    // ── 103: LFO freq — value(deps[0]) mode(deps[1]) ─────────────────────────
    // Źródło: g2_file.pas case 103 + G2BPM/G2FloatToStr z g2_types.pas
    // mode: 0=Rate Sub, 1=Rate Lo, 2=Rate Hi, 3=BPM, 4=Clk
    case 103:
        let mode = depVal(1)
        switch mode {
        case 0: // Rate Sub — zawsze w sekundach
            return g2FloatToStr(699.0 / Double(v + 1), 4) + "s"
        case 1: // Rate Lo — <32: sekundy, ≥32: Hz
            if v < 32 {
                return g2FloatToStr(1.0 / (0.0159 * pow(2.0, Double(v) / 12.0)), 4) + "s"
            } else {
                return g2FloatToStr(0.0159 * pow(2.0, Double(v) / 12.0), 4) + "Hz"
            }
        case 2: // Rate Hi — zawsze Hz
            return g2FloatToStr(0.2555 * pow(2.0, Double(v) / 12.0), 4) + "Hz"
        case 3: // BPM — tabela integer z g2_types.pas
            return g2BPM(v)
        default: // Clk — clock sync strings
            return g2LFOClockStr(v)
        }

    // ── 107: Reverb time ─────────────────────────────────────────────────────
    case 107:
        let range = depVal(1)
        let mult: Double = [3.0, 6.0, 9.0, 12.0][min(range, 3)]
        let t = mult / 127.0 * Double(v)
        return g2Time(t)

    // ── 109: MIDI channel ────────────────────────────────────────────────────
    // ── 109: kanał MIDI wejściowy (CtrlRcv, NoteRcv, NoteZone RcvCh) ─────────
    // PatchMIDIInChannel w oryginale to tabela **18** pozycji
    // (`Table(…, 0x12, …)`), tak jak `PatchMIDIOutChannel` ma 21 (`0x15`).
    // Numeracja zaczyna się od zera = kanał 1, potem „This" i „Keyb" —
    // identycznie jak w definicjach g2ools dla MidiCh_16/17/20.
    // Wcześniejsze „Any" dla zera nie występuje w oryginale w ogóle (nie ma
    // takiego napisu w tablicy stringów Clavii) i przesuwało całą numerację o 1.
    case 109:
        switch v {
        case 0 ... 15: return "\(v + 1)"
        case 16: return "This"
        default: return "Keyb"
        }

    // ── 133: SeqVal bipolar/unipolar ─────────────────────────────────────────
    case 133:
        let polar = depVal(1)
        if polar == 0 { return g2Signed(v - 64) } // bipolar
        return "\(v)" // unipolar

    // ── 137: Env Sustain (może zależeć od LevelShift mode) ───────────────────
    case 137:
        let lsMode = depVal(1)
        if lsMode >= 4 { return g2Signed(v - 64) } // bipolar (mode 4/5)
        return String(format: "%.1f", Double(v) / 2.0) // unipolar (mode 0-3)

    // ── 17/27/39: delegacje do sprawdzonych InfoFunction ─────────────────────
    case 17:
        return g2InfoFunction(17, val: v)

    case 27:
        return g2InfoFunction(126, val: v)

    case 39:
        return g2InfoFunction(39, val: v)

    // ── 140: DelayQuad — czas lub synchronizacja zegara ──────────────────────
    case 140:
        return depVal(1) == 0 ? g2DelayStaticTime(value: v, range: depVal(2)) : g2DelayClockSync(v)

    // ── 141: DlySingleA/B i DelayDual — czas zależny od 7-pozycyjnego Range ─
    case 141:
        return g2DelayStaticTime(value: v, range: depVal(1))

    // ── 145: DlyEight — liniowe zakresy 0.66–338 ms ──────────────────────────
    case 145:
        return g2DelayEightTime(value: v, range: depVal(1))

    // ── 146: DlyStereo — czas lub synchronizacja zegara ──────────────────────
    case 146:
        return depVal(1) == 0 ? g2DelayStereoTime(value: v, range: depVal(2)) : g2DelayClockSync(v)

    // ── 147: LevAmp Gain — Lin jako mnożnik, dB jako poziom ───────────────────
    case 147:
        let db = levAmpDb[v]
        if depVal(1) == 0 {
            if v == 0 { return "x0.00" }
            let gain = v == 127 ? 4.0 : pow(10.0, db / 20.0)
            return String(format: "x%.2f", gain)
        }
        return db.isInfinite ? "-oo" : String(format: "%.1f", db)

    // ── 179: MIDIValue — surowa liczba ───────────────────────────────────────
    // W oryginale MIDIValue to jedno wywołanie `IntToStr(value)`.
    // Nazwę nuty daje osobny `TextFunc 13` (Semitone). Wcześniej 179
    // renderowało nutę, przez co „Vel" w NoteSend pokazywało E6 zamiast 100,
    // a „Ctrl"/„Value" w CtrlSend i Automate — nazwy nut zamiast numerów MIDI.
    // Operator i DXRouter miały z tego powodu własne obejścia; są już zbędne.
    case 179:
        return "\(v)"

    // ── 143: Dly Time — deps[0]=Time(0-127), deps[1]=TimeClk(0/1), deps[2]=Range mode ──
    // Deps w .txt: "timeIdx,clkIdx,S0" → S0 kodowane jako -1 (modes[0]=Range)
    case 143:
        let timeClk = depVal(1)
        let range = depVal(2) // modes[0] — DelayRange
        if timeClk == 1 {
            return g2DelayClockSync(v)
        }
        return g2DelayTime(value: v, range: range)

    // ── 108: MIDI destination ───────────────────────────────────────────────
    case 108:
        return g2InfoFunction(108, val: v)

    // ── 110: ClkGen Tempo — zależny od aktywności i źródła zegara ────────────
    case 110:
        if depVal(1) == 0 { return "--" }
        return depVal(2) == 1 ? "MASTER" : g2BPM(v) + " BPM"

    // ── 122: Logic Pulse/Delay — trzy skale czasu ────────────────────────────
    case 122:
        return g2PulseDelayTime(value: v, range: depVal(1))

    // ── 142: Frequency Shift — tabelaryczne zakresy Sub/Lo/Hi ────────────────
    case 142:
        return g2FreqShift(value: v, range: depVal(1))

    // ── 166/173: delegacje do sprawdzonych InfoFunction ──────────────────────
    case 166:
        return g2InfoFunction(166, val: v)

    case 173:
        return g2InfoFunction(173, val: v)

    // ── 197/198/201: wyświetlacze operatora i Pitch Shifter ──────────────────
    case 197:
        return g2OperatorBreakPoint(v)

    case 198:
        return g2OperatorFrequency(value: v, detune: depVal(1), mode: depVal(2))

    case 201:
        // PShift: półtony (Semi, krok 0,25) i centy Fine — oryginał
        // PitchShift: "%+2.1f %+4.0f", (semi-64)*0.25 i (fine-64)*50/64
        // (stałe jak w oryginalnym edytorze; BVerhue pokazuje to samo, tylko ucina centy).
        // Do 2026-09-27 ekran pomijał Fine — kręcenie nim niczego nie zmieniało.
        return String(format: "%+2.1f %+4.0f", Double(v - 64) * 0.25, Double(depVal(1) - 64) * 50 / 64)

    // ── 217: Glide time — <1000 → "m", inaczej /1000 → "s" ──────────────────
    // Log: GLIDE_TIME[v] z g2_types.pas (potwierdzone dokładnie zrzutami z oryginału).
    // Lin: reimplementacja Bruno Verhue nie ma tej tabeli (potwierdzona luka, bug #18) —
    // używamy `glideTimeLin()`, interpolacji liniowej między 7 zmierzonymi punktami.
    case 217:
        let shape = depVal(1)
        let isLin = shape == 1
        let t = isLin ? glideTimeLin(v) : glideTime[max(0, min(127, v))]
        let suffix = isLin ? "/oct" : ""
        if t < 1000 {
            return g2FloatToStrFixed(t, 4) + "m" + suffix
        }
        return g2FloatToStrFixed(t / 1000, 4) + "s" + suffix

    default:
        return "\(v)"
    }
}
