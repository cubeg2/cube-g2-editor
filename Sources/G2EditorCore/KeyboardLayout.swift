// KeyboardLayout.swift
// Geometria wirtualnej klawiatury i mapa „Musical Typing” — czysta logika bez SwiftUI,
// żeby dało się ją sprawdzić testem. Rysunek klawiatury kłamał do 2026-09-21: białe klawisze
// liczył od `lowestNote` jak od C, więc po przesunięciu widoku o półton czarne klawisze
// zostawały w miejscu, a nuty pod nimi się przesuwały.

import Foundation

public enum KeyboardLayout {
    public struct Key: Identifiable, Equatable {
        public let note: UInt8
        public let isBlack: Bool
        public let rect: CGRect

        public var id: UInt8 {
            note
        }
    }

    public static func isBlack(_ note: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(note % 12)
    }

    /// Klawisze widoczne od `lowest` przez `octaves` oktaw. Każde 12 półtonów to 7 białych
    /// klawiszy niezależnie od tego, od której nuty zaczynamy, więc szerokość białego jest
    /// stała. Czarny siedzi na granicy między sąsiednimi białymi; gdy widok zaczyna się na
    /// czarnym, wystaje on w lewo poza krawędź — jak w oknie oryginału, które przesuwa
    /// jedną bitmapę całego zakresu MIDI (`CKeyboardFloater::SetShift`).
    public static func keys(lowest: Int, octaves: Int, width: CGFloat, height: CGFloat) -> [Key] {
        let whiteWidth = width / CGFloat(octaves * 7)
        let blackWidth = whiteWidth * 0.62
        let blackHeight = height * 0.6
        var keys: [Key] = []
        var whiteIndex = 0
        for note in lowest ..< lowest + octaves * 12 where (0 ... 127).contains(note) {
            if isBlack(note) {
                keys.append(Key(note: UInt8(note), isBlack: true, rect: CGRect(
                    x: CGFloat(whiteIndex) * whiteWidth - blackWidth / 2, y: 0,
                    width: blackWidth, height: blackHeight
                )))
            } else {
                keys.append(Key(note: UInt8(note), isBlack: false, rect: CGRect(
                    x: CGFloat(whiteIndex) * whiteWidth, y: 0,
                    width: whiteWidth - 1, height: height
                )))
                whiteIndex += 1
            }
        }
        return keys
    }

    /// Nuta pod punktem. Czarne leżą na białych, więc sprawdzamy je pierwsze; szczelina
    /// 1 pt między białymi należy do klawisza z lewej, żeby klik nigdy nie trafił w nic.
    public static func note(at point: CGPoint, in keys: [Key]) -> UInt8? {
        if let black = keys.first(where: { $0.isBlack && $0.rect.contains(point) }) {
            return black.note
        }
        return keys.first { key in
            !key.isBlack && CGRect(x: key.rect.minX, y: key.rect.minY,
                                   width: key.rect.width + 1, height: key.rect.height).contains(point)
        }?.note
    }

    /// Przesunięcie o `count` białych klawiszy (ujemne = w dół) z pominięciem czarnych —
    /// tak liczy się przewijanie myszą: jeden biały klawisz rysunku = jeden krok.
    public static func shifted(_ note: Int, byWhiteKeys count: Int) -> Int {
        var note = note
        var remaining = abs(count)
        let step = count < 0 ? -1 : 1
        while remaining > 0 {
            note += step
            if !isBlack(note) { remaining -= 1 }
        }
        return note
    }

    /// Klawisze sprzętowe G2 z 37 klawiszami: C2–C5. Po USB nie widać, który model jest
    /// podłączony (G2X ma 61), więc klamra pokazuje ten, który mamy.
    public static let g2KeyRange = 36 ... 72

    // MARK: - Musical Typing

    /// Litera klawiatury komputera i jej odległość w półtonach od C bazowej oktawy.
    public struct TypingKey: Equatable {
        public let keyCode: UInt16
        public let label: String
        public let offset: Int
    }

    /// Układ jak w Logic i GarageBand: rząd A–' to białe klawisze od C, rząd W–P czarne.
    /// Klucze to fizyczne kody klawiszy (ANSI), więc układ nie zależy od języka klawiatury.
    public static let typingKeys: [TypingKey] = [
        TypingKey(keyCode: 0, label: "A", offset: 0),
        TypingKey(keyCode: 13, label: "W", offset: 1),
        TypingKey(keyCode: 1, label: "S", offset: 2),
        TypingKey(keyCode: 14, label: "E", offset: 3),
        TypingKey(keyCode: 2, label: "D", offset: 4),
        TypingKey(keyCode: 3, label: "F", offset: 5),
        TypingKey(keyCode: 17, label: "T", offset: 6),
        TypingKey(keyCode: 5, label: "G", offset: 7),
        TypingKey(keyCode: 16, label: "Y", offset: 8),
        TypingKey(keyCode: 4, label: "H", offset: 9),
        TypingKey(keyCode: 32, label: "U", offset: 10),
        TypingKey(keyCode: 38, label: "J", offset: 11),
        TypingKey(keyCode: 40, label: "K", offset: 12),
        TypingKey(keyCode: 31, label: "O", offset: 13),
        TypingKey(keyCode: 37, label: "L", offset: 14),
        TypingKey(keyCode: 35, label: "P", offset: 15),
        TypingKey(keyCode: 41, label: ";", offset: 16),
        TypingKey(keyCode: 39, label: "'", offset: 17),
    ]

    /// Z i X — oktawa liter w dół i w górę.
    public static let typingOctaveDownKeyCode: UInt16 = 6
    public static let typingOctaveUpKeyCode: UInt16 = 7

    /// Ile półtonów pokrywają litery: od C do F następnej oktawy.
    public static var typingSpan: Int {
        (typingKeys.map(\.offset).max() ?? 0) + 1
    }

    public static func typingKey(forCode keyCode: UInt16) -> TypingKey? {
        typingKeys.first { $0.keyCode == keyCode }
    }

    public static func typingLabel(offset: Int) -> String? {
        typingKeys.first { $0.offset == offset }?.label
    }
}

/// Akord z jednego kliknięcia myszą w oknie Virtual Keyboard: kliknięty klawisz to pryma,
/// reszta nut idzie razem z nim. Myszą nie da się wcisnąć kilku klawiszy naraz — litery
/// (Caps Lock) grają akordy same, bo każda litera to osobna nuta.
public enum KeyboardChord: String, CaseIterable, Identifiable, Sendable {
    case single, major, minor, seventh, majorSeventh, minorSeventh, sus4, diminished, augmented, octave

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .single: "Single Note"
        case .major: "Major"
        case .minor: "Minor"
        case .seventh: "7"
        case .majorSeventh: "Maj7"
        case .minorSeventh: "m7"
        case .sus4: "Sus4"
        case .diminished: "Dim"
        case .augmented: "Aug"
        case .octave: "Octave"
        }
    }

    /// Odstępy od prymy w półtonach, pryma pierwsza.
    public var intervals: [Int] {
        switch self {
        case .single: [0]
        case .major: [0, 4, 7]
        case .minor: [0, 3, 7]
        case .seventh: [0, 4, 7, 10]
        case .majorSeventh: [0, 4, 7, 11]
        case .minorSeventh: [0, 3, 7, 10]
        case .sus4: [0, 5, 7]
        case .diminished: [0, 3, 6]
        case .augmented: [0, 4, 8]
        case .octave: [0, 12]
        }
    }

    /// Nuty akordu od `root`; to, co wypada ponad MIDI 127, po prostu nie gra.
    public func notes(root: UInt8) -> [UInt8] {
        intervals.map { Int(root) + $0 }.filter { $0 <= 127 }.map(UInt8.init)
    }
}
