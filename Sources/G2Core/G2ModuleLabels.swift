// G2ModuleLabels.swift
// Sekcja 0x5B obszaru Voice/FX — dodatkowe dane modułów, rozpisane na wpisy według numeru modułu.
//
// Treść wpisu przenosimy surowo: to własne podpisy parametrów (kanały miksów, pozycje
// przełączników — po 7 znaków), a dla SeqNote ustawienia widoku klawiatury. Model ich nie
// zna; wystarczy, że wpis jedzie za swoim modułem, kiedy ten zmienia numer (Building Blocks).
//
// Układ (g2ools `Labels.parse_area`): 2 bity obszaru, 8 bitów liczby modułów, potem dla
// każdego modułu 8 bitów numeru, 8 bitów długości i tyle bajtów treści. Bez wyrównania
// do bajtu — całość jest przesunięta o dwa bity obszaru. Nazwy morfów (obszar 2) mają
// inny układ i tu nie wchodzą.

import Foundation

public struct G2ModuleLabelSection: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var moduleID: Int
        public var content: [UInt8]

        public init(moduleID: Int, content: [UInt8]) {
            self.moduleID = moduleID
            self.content = content
        }
    }

    /// Dwubitowy numer obszaru z początku sekcji: 1 = Voice, 0 = FX, 2 = ustawienia patcha
    /// (tam jeden „moduł" numer 1 z nazwami morfów — ten sam układ).
    public var area: UInt8
    public var entries: [Entry]

    public init(area: UInt8, entries: [Entry] = []) {
        self.area = area
        self.entries = entries
    }

    /// `nil`, gdy sekcja nie ma tego układu albo urywa się w środku wpisu — wtedy jej
    /// nie ruszamy.
    public init?(raw: [UInt8]) {
        var bits = BitStream(data: raw)
        func read(_ count: Int) -> Int? {
            guard bits.currentBitPosition + count <= raw.count * 8 else { return nil }
            return (try? bits.readBits(count)).map(Int.init)
        }
        guard let area = read(2), area < 3, let count = read(8) else { return nil }
        var entries: [Entry] = []
        for _ in 0 ..< count {
            guard let moduleID = read(8), let length = read(8) else { return nil }
            var content: [UInt8] = []
            for _ in 0 ..< length {
                guard let byte = read(8) else { return nil }
                content.append(UInt8(byte))
            }
            entries.append(Entry(moduleID: moduleID, content: content))
        }
        self.init(area: UInt8(area), entries: entries)
    }

    /// Bajty sekcji; ostatni bajt dopełniony zerami, jak w plikach z edytora Clavii.
    public var raw: [UInt8] {
        var bits = BitStream(data: [])
        try? bits.writeBits(2, value: UInt32(area))
        try? bits.writeBits(8, value: UInt32(entries.count))
        for entry in entries {
            try? bits.writeBits(8, value: UInt32(entry.moduleID))
            try? bits.writeBits(8, value: UInt32(entry.content.count))
            for byte in entry.content {
                try? bits.writeBits(8, value: UInt32(byte))
            }
        }
        return bits.toBytes()
    }
}

public extension G2Patch {
    /// Wpisy sekcji 0x5B obszaru; `nil`, gdy patch jej nie ma albo nie da się jej rozczytać.
    func moduleLabels(in area: PatchArea) -> G2ModuleLabelSection? {
        moduleCustomData[area.rawValue].flatMap(G2ModuleLabelSection.init(raw:))
    }
}

// MARK: - Nazwy morfów (obszar 2)

/// Sekcja 0x5B obszaru 2 — nazwy ośmiu morfów (g2ools `Labels.parse_morphs`): 2 bity obszaru,
/// nagłówek `[1][1][0x50]`, potem osiem razy `[1][1][8 + morf]` i 7 bajtów nazwy dopełnionej
/// zerami. Taki kształt ma każda z 224 sekcji paczki Building Blocks (84 bajty).
public struct G2MorphLabelSection: Equatable, Sendable {
    public static let nameLength = 7
    private static let headerBits = 2 + 24
    private static let entryBits = 24 + nameLength * 8

    public private(set) var raw: [UInt8]

    public init?(raw: [UInt8]) {
        guard raw.count * 8 >= Self.headerBits + G2Morph.count * Self.entryBits else { return nil }
        var bits = BitStream(data: raw)
        guard (try? bits.readBits(2)) == 2,
              (try? [bits.readBits(8), bits.readBits(8), bits.readBits(8)]) == [1, 1, 0x50]
        else { return nil }
        self.raw = raw
    }

    /// Sekcja z nazwami domyślnymi — dla patcha, który nie ma jej w modelu.
    public static var standard: G2MorphLabelSection {
        var bits = BitStream(data: [])
        try? bits.writeBits(2, value: 2)
        for byte in [1, 1, 0x50] {
            try? bits.writeBits(8, value: UInt32(byte))
        }
        for morph in 0 ..< G2Morph.count {
            for byte in [1, 1, 8 + morph] {
                try? bits.writeBits(8, value: UInt32(byte))
            }
            for byte in Self.padded(defaultNames[morph]) {
                try? bits.writeBits(8, value: UInt32(byte))
            }
        }
        // `init?(raw:)` przyjmie własny wynik — układ jest ten sam, który sprawdza.
        return G2MorphLabelSection(raw: bits.toBytes())!
    }

    /// Nazwy, które zapisuje sam edytor Clavii (w pliku „G.Wh 2" ze spacją).
    public static let defaultNames = ["Wheel", "Vel", "Keyb", "Aft.Tch", "Sust.Pd", "Ctrl.Pd", "P.Stick", "G.Wh 2"]

    /// Nazwa, której nikt nie nadał: domyślna Clavii albo jedna z dwóch serii, które w plikach
    /// zostawiły inne edytory („Src Gr1"…, „Group 1"…).
    public static func isDefault(_ name: String, morph: Int) -> Bool {
        name.isEmpty || (defaultNames.indices.contains(morph) && name == defaultNames[morph])
            || name == "Src Gr\(morph + 1)" || name == "Group \(morph + 1)"
    }

    public func name(_ morph: Int) -> String {
        guard (0 ..< G2Morph.count).contains(morph) else { return "" }
        var bits = BitStream(data: raw, startBit: Self.nameBit(morph))
        let bytes = (0 ..< Self.nameLength).map { _ in UInt8((try? bits.readBits(8)) ?? 0) }
        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .ascii) ?? ""
    }

    public mutating func setName(_ name: String, morph: Int) {
        guard (0 ..< G2Morph.count).contains(morph) else { return }
        var bits = BitStream(data: raw, startBit: Self.nameBit(morph))
        for byte in Self.padded(name) {
            try? bits.writeBits(8, value: UInt32(byte))
        }
        raw = bits.toBytes()
    }

    private static func nameBit(_ morph: Int) -> Int {
        headerBits + morph * entryBits + 24
    }

    private static func padded(_ name: String) -> [UInt8] {
        let ascii = Array(name.utf8.filter { $0 < 0x80 }.prefix(nameLength))
        return ascii + Array(repeating: 0, count: nameLength - ascii.count)
    }
}

public extension G2Patch {
    /// Nazwy morfów patcha; `nil`, gdy sekcji nie da się rozczytać. Brak sekcji w modelu =
    /// nazwy domyślne (szablon pustego patcha ma właśnie takie).
    var morphLabels: G2MorphLabelSection? {
        guard let raw = moduleCustomData[2] else { return .standard }
        return G2MorphLabelSection(raw: raw)
    }

    /// Nazwa morfu do pokazania: ta z patcha (sekcja 0x5B obszaru 2, np. „DL Cut"), tak jak
    /// ją zapisał autor — także serie „Group 1"/„Src Gr1" innych edytorów, bo tak widzi je
    /// Clavia. Pusta albo nieczytelna sekcja → nazwa domyślna.
    func morphName(_ morph: Int) -> String {
        G2Morph.names.indices.contains(morph) ? morphNames[morph] : "Morph \(morph + 1)"
    }

    /// Wszystkie osiem naraz — sekcja czytana raz (nagłówek slotu liczy je przy każdej zmianie).
    var morphNames: [String] {
        let labels = morphLabels
        return G2Morph.names.indices.map { morph in
            let name = labels?.name(morph) ?? ""
            return name.isEmpty ? G2Morph.names[morph] : name
        }
    }

    /// Dopisuje wpisy modułów, które właśnie dostały nowe numery (`idMap`: stary → nowy).
    /// Wpis patcha pod numerem nowego modułu to pozostałość po skasowanym module — znika.
    /// Sekcji, której nie da się rozczytać, nie ruszamy.
    mutating func addModuleLabels(_ entries: [G2ModuleLabelSection.Entry], idMap: [Int: Int], in area: PatchArea) {
        let moved = entries.compactMap { entry in
            idMap[entry.moduleID].map { G2ModuleLabelSection.Entry(moduleID: $0, content: entry.content) }
        }
        guard !moved.isEmpty else { return }
        var ours: G2ModuleLabelSection
        if moduleCustomData[area.rawValue] == nil {
            ours = G2ModuleLabelSection(area: area.rawValue)
        } else if let parsed = moduleLabels(in: area) {
            ours = parsed
        } else {
            return
        }
        let newIDs = Set(idMap.values)
        ours.entries.removeAll { newIDs.contains($0.moduleID) }
        ours.entries += moved
        ours.entries.sort { $0.moduleID < $1.moduleID }
        moduleCustomData[area.rawValue] = ours.raw
    }
}
