// G2PatchHeader.swift
// Trzy pola nagłówka patcha, które w oryginale siedzą w pasku narzędzi:
// nazwa, kategoria dźwięku i tryb głosów (instrukcja Clavii, str. 61–62).
//
// Wszystkie trzy mieszkają w sekcji `0x21` pliku (`G2PatchDescription`), poza samą
// nazwą: ta dla `.pch2` jest nazwą pliku, a dla `.prf2` siedzi w sekcji `0x11`.

import Foundation

// MARK: - Kategoria dźwięku

/// Piętnaście kategorii z instrukcji („There are 13+2 different categories") plus
/// pozycja zerowa „None". Numeracja za g2ools `g2categories` i BVerhue `CATEGORIES`
/// — oba źródła zgodne co do kolejności.
public enum G2PatchCategory {
    public static let names = ["None", "Acoustic", "Sequencer", "Bass", "Classic", "Drum",
                               "Fantasy", "FX", "Lead", "Organ", "Pad", "Piano", "Synth",
                               "Audio In", "User1", "User2"]

    public static func name(_ index: Int) -> String {
        names.indices.contains(index) ? names[index] : "\(index)"
    }
}

// MARK: - Tryb głosów

/// Jedna pozycja pokrętła „Voice Mode": Legato, Mono albo liczba głosów.
///
/// Układ przepisany z BVerhue (`TframeSlotStrip.bidVoicesChangeValue` i odczyt
/// `VoiceCount + 2 - MonoPoly - 1`), gdzie jedna wartość 0…32 opisuje oba pola
/// nagłówka naraz:
///
///   0        → Legato  (`voices` = 1, `monopoly` = 2)
///   1        → Mono    (`voices` = 1, `monopoly` = 1)
///   2 … 32   → Poly    (`voices` = wartość − 1, `monopoly` = 0)
///
/// Pole `voices` w pliku ma pięć bitów, więc górną granicą polifonii jest 31 —
/// instrukcja pisze „2-32", ale mówi o pozycjach pokrętła, nie o liczbie głosów.
public enum G2VoiceMode {
    public static let minIndex = 0
    public static let maxIndex = 32

    /// Pozycja pokrętła dla pary (voices, monopoly) z nagłówka patcha.
    public static func index(voices: Int, monopoly: Int) -> Int {
        max(minIndex, min(maxIndex, voices + 1 - monopoly))
    }

    /// Para (voices, monopoly), którą trzeba wpisać do nagłówka dla tej pozycji.
    public static func fields(index: Int) -> (voices: Int, monopoly: Int) {
        switch max(minIndex, min(maxIndex, index)) {
        case 0: (voices: 1, monopoly: 2)
        case 1: (voices: 1, monopoly: 1)
        case let value: (voices: value - 1, monopoly: 0)
        }
    }

    /// Napis w okienku — to, co pokazuje pasek oryginału.
    public static func label(index: Int) -> String {
        switch max(minIndex, min(maxIndex, index)) {
        case 0: "Legato"
        case 1: "Mono"
        case let value: "\(value - 1)"
        }
    }

    public static func label(voices: Int, monopoly: Int) -> String {
        label(index: index(voices: voices, monopoly: monopoly))
    }
}

// MARK: - Nazwa patcha

public enum G2PatchName {
    /// Tyle znaków przyjmuje urządzenie i tyle mieści sekcja `0x11`.
    public static let maxLength = 16

    /// Instrukcja (str. 61): „A standard English character set is available. Any
    /// 'illegal' characters that you may type will be substituted with empty spaces."
    /// Nazwa jedzie do urządzenia i do pliku jako ISO-Latin1, więc przepuszczamy
    /// drukowalne ASCII, a resztę zamieniamy na spację.
    public static func sanitized(_ raw: String) -> String {
        let cleaned = raw.prefix(maxLength).map { character -> Character in
            guard let ascii = character.asciiValue, ascii >= 0x20, ascii < 0x7F else { return " " }
            return character
        }
        return String(cleaned)
    }
}
