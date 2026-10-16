// PatchParser.swift
// Parser for Nord G2 binary .pch2 patch files
// Format reverse-engineered by the community; ported from g2ools (GPL) and G2-Edit (GPL)
//
// File structure:
//   [text header ending with \0]
//   [binary sections: each = type(1B) + length(2B big-endian) + data(length B)]
//
// Section type codes:
//   0x11  PerformanceDescription (tylko .prf2)
//   0x21  PatchDescription
//   0x4a  ModuleList
//   0x52  CableList
//   0x4d  Parameters
//   0x65  MorphParameters
//   0x5f  GlobalKnobAssignments (tylko .prf2)
//   0x62  KnobAssignments
//   0x60  CtrlAssignments
//   0x5b  Labels
//   0x5a  ModuleNames
//   0x6f  TextPad
//   0x69  CurrentNote

import Foundation

// MARK: - Section type constants

private enum SectionType: UInt8 {
    case performanceDescription = 0x11
    case patchDescription = 0x21
    case moduleList = 0x4A
    case cableList = 0x52
    case parameters = 0x4D
    case morphParameters = 0x65
    case globalKnobAssignments = 0x5F
    case knobAssignments = 0x62
    case ctrlAssignments = 0x60
    case labels = 0x5B
    case moduleNames = 0x5A
    case textPad = 0x6F
    case currentNote = 0x69
}

// MARK: - Parser errors

public enum PatchParserError: Error, LocalizedError, CustomStringConvertible {
    case invalidHeader(String)
    case truncatedSection(UInt8, Int, Int)
    case unknownSectionType(UInt8)
    case bitStreamError(BitStreamError)
    case moduleNotFound(Int)
    case notAPatchFile(String)

    public var description: String {
        switch self {
        case let .invalidHeader(s):
            "Invalid header: \(s)"
        case let .truncatedSection(t, have, need):
            "Section 0x\(String(t, radix: 16)) truncated: have \(have) bytes, need \(need)"
        case let .unknownSectionType(t):
            "Unknown section type 0x\(String(t, radix: 16))"
        case let .bitStreamError(e):
            "BitStream error: \(e)"
        case let .moduleNotFound(id):
            "Module instance \(id) not found"
        case let .notAPatchFile(name):
            "\"\(name)\" is not a Nord G2 patch file (.pch2)"
        }
    }

    public var errorDescription: String? {
        description
    }

    public var failureReason: String? {
        switch self {
        case .notAPatchFile: "The selected file does not have a valid G2 patch header."
        case .invalidHeader: "The file header could not be parsed."
        default: nil
        }
    }
}

// MARK: - Patch Parser

public class PatchParser {
    /// Number of variations in a patch (1–8 user + 1 init)
    static let nVariations = 9

    // MARK: Public interface

    // MARK: - Save (patch-in-place: zastępuje sekcje CableList w oryginalnych bajtach)

    /// Nadpisuje sekcje CableList w oryginalnych bajtach pliku.
    /// Zwraca zmodyfikowane `Data` gotowe do zapisu na dysk.
    /// Pozostałe sekcje (moduły, parametry, nazwy) pozostają nienaruszone.
    public static func saveCables(originalData: Data, patches: [G2Patch]) throws -> Data {
        var bytes = [UInt8](originalData)
        let (headerLength, _) = try parseTextHeader(bytes)
        let binaryStart = headerLength + 1 + 2 // \0 + 2 bajty wersji

        var offset = binaryStart

        // Indeks iteracji każdego (typ sekcji × areaFlag) → do mapowania na slot
        var sectionCounts: [UInt16: Int] = [:]

        // Zbieramy zakresy do zamiany: (startByte, endByte, newBytes)
        var replacements: [(range: Range<Int>, newBytes: [UInt8])] = []

        while offset < bytes.count {
            guard offset + 3 <= bytes.count else { break }
            let sectionType = bytes[offset]
            let length = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            let dataStart = offset + 3
            let dataEnd = dataStart + length
            guard dataEnd <= bytes.count else { break }

            if sectionType == SectionType.cableList.rawValue {
                let areaFlag: UInt16 = length > 0 ? UInt16(bytes[dataStart] >> 6) : 0
                let key = UInt16(sectionType) << 2 | areaFlag
                let slotIdx = sectionCounts[key, default: 0]
                sectionCounts[key] = slotIdx + 1
                let target = min(slotIdx, patches.count - 1)

                let area: PatchArea = areaFlag == 1 ? .voice : .fx
                let cables = patches[target].cables(in: area)
                let newSection = try serializeCableSection(cables: cables,
                                                           area: area,
                                                           seed: Array(bytes[dataStart ..< dataEnd]))

                // sekcja = [type(1)] + [len hi(1)] + [len lo(1)] + [data]
                let newLen = newSection.count
                let header = [UInt8(sectionType),
                              UInt8((newLen >> 8) & 0xFF),
                              UInt8(newLen & 0xFF)]
                replacements.append((range: offset ..< dataEnd, newBytes: header + newSection))
            }

            let areaFlag: UInt16 = length > 0 ? UInt16(bytes[dataStart] >> 6) : 0
            let key = UInt16(sectionType) << 2 | areaFlag
            if sectionType != SectionType.cableList.rawValue {
                sectionCounts[key] = (sectionCounts[key] ?? 0) + 1
            }

            offset = dataEnd
        }

        // Aplikuj zamiany od końca żeby nie przesuwać offsetów
        for rep in replacements.reversed() {
            bytes.replaceSubrange(rep.range, with: rep.newBytes)
        }

        let crcStart = headerLength + 1
        let crcLen = bytes.count - 2 - crcStart
        if crcLen > 0, bytes.count >= 2 {
            let crc = calcCRC16(bytes, from: crcStart, length: crcLen)
            bytes[bytes.count - 2] = UInt8((crc >> 8) & 0xFF)
            bytes[bytes.count - 1] = UInt8(crc & 0xFF)
        }

        return Data(bytes)
    }

    // MARK: - Szkielet pustego patcha

    /// Bajty pustego `.pch2` — szkielet, w który `saveAll` wpisuje dowolny patch, gdy nie ma
    /// pliku źródłowego (nowy patch, zawartość odczytana z Norda). Bez niego jedyną drogą do
    /// urządzenia były molekuły: kasowanie modułu po module, ~290 ms na sztukę, czyli
    /// kilkadziesiąt sekund migotania diody „Load Patch". Oryginał tej drogi nie zna —
    /// `CPatch::GetCompletePatchDump` zawsze buduje **plik** i wysyła go jedną komendą 0x37.
    ///
    /// Plik powstał z naszego własnego zapisu (`saveAll(originalData: manyOSCA.pch2,
    /// patches: [G2Patch()])`) i ma kanoniczny kształt bloku
    /// `21 4a 4a 69 52 52 4d 4d 4d 65 62 60 5b 5b 5b 5a 5a 6f`: zero modułów, zero kabli,
    /// żadnych przypisań gałek (0x65), kontrolerów (0x62) ani morfów (0x69) — te sekcje
    /// przechodzą przez `saveAll` nietknięte, więc szkielet musiał być pod nimi czysty.
    public static let emptyPatchFile: Data = {
        guard let url = Bundle.g2Core.url(forResource: "InitPatch", withExtension: "pch2"),
              let data = try? Data(contentsOf: url)
        else {
            assertionFailure("Brak zasobu InitPatch.pch2 w G2Core")
            return Data()
        }
        return data
    }()

    /// Bajty pustego `.prf2` — ten sam szkielet co wyżej, tylko czterokrotny i z sekcją
    /// `0x11` na przedzie. Potrzebny wszędzie tam, gdzie performance nie ma pliku
    /// źródłowego: „Save As" dla nowej performance i dla zawartości odczytanej z Norda.
    ///
    /// Składany z `emptyPatchFile`, żeby bloki slotów były dokładnie tymi samymi bajtami,
    /// które `saveAll` już umie nadpisywać — nic tu nie jest wymyślone poza nagłówkiem
    /// tekstowym (typ pliku = 1) i zerową sekcją `0x11`, której układ opisuje
    /// `parsePerformanceDescription`.
    public static let emptyPerformanceFile: Data = {
        let patch = [UInt8](emptyPatchFile)
        guard let nullIndex = patch.firstIndex(of: 0), patch.count > nullIndex + 4 else {
            assertionFailure("InitPatch.pch2 bez nagłówka tekstowego")
            return Data()
        }
        let slotBlock = Array(patch[(nullIndex + 3) ..< (patch.count - 2)])

        var bytes = Array("Version=Nord Modular G2 File Format 1\r\nType=Performance\r\n".utf8)
        bytes += [0, patch[nullIndex + 1], 1] // wersja formatu jak w patchu, typ = performance
        bytes += emptyPerformanceSection()
        for _ in 0 ..< 4 {
            bytes += slotBlock
        }
        // Sekcja `0x5F` (gałki globalne) kończy każdy `.prf2` Clavii, a `saveAll` nadpisuje
        // tylko sekcje obecne w szkielecie. Bez niej zapis gubił gałki globalne, a `0x1A`
        // leciał bez mapy i Nord go nie potwierdzał (Download Banks, 2026-10-14).
        let knobs = (try? serializeGlobalKnobSection(G2PerformanceSettings())) ?? []
        bytes += [SectionType.globalKnobAssignments.rawValue,
                  UInt8((knobs.count >> 8) & 0xFF), UInt8(knobs.count & 0xFF)] + knobs

        bytes += [0, 0]
        let crcStart = nullIndex + 1
        let crc = calcCRC16(bytes, from: crcStart, length: bytes.count - 2 - crcStart)
        bytes[bytes.count - 2] = UInt8((crc >> 8) & 0xFF)
        bytes[bytes.count - 1] = UInt8(crc & 0xFF)
        return Data(bytes)
    }()

    /// Sekcja `0x11` w stanie „nic nie ustawione": cztery sloty bez nazw, gra i ma klawiaturę
    /// tylko A, zegar 120 BPM zatrzymany — to samo, co `PatchState.newPerformance()`.
    /// `saveAll` i tak wpisze tu bieżące ustawienia; szkielet ma być tylko czytelny.
    private static func emptyPerformanceSection() -> [UInt8] {
        var body: [UInt8] = [0, 0, 0, 120, 0, 0, 0, 0]
        for slot in 0 ..< performanceSlotCount {
            body.append(0) // pusta nazwa + terminator
            body += [slot == 0 ? 1 : 0, slot == 0 ? 1 : 0, 0, 0, 0, 0, 127, 0, 0, 0]
        }
        return [SectionType.performanceDescription.rawValue,
                UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    // MARK: - Save (patch-in-place: zastępuje sekcje ModuleList + CableList)

    /// Nadpisuje sekcje ModuleList (0x4a) i CableList (0x52) — zachowuje pozycje, kable i tryby.
    /// `performance` (sekcja 0x11) przekazuj tylko dla plików `.prf2`, których sekcję
    /// udało się rozczytać — `nil` zostawia ją nietkniętą.
    public static func saveAll(originalData: Data,
                               patches: [G2Patch],
                               performance: G2PerformanceSettings? = nil) throws -> Data
    {
        var bytes = [UInt8](originalData)
        let (headerLength, _) = try parseTextHeader(bytes)
        let binaryStart = headerLength + 1 + 2

        var offset = binaryStart
        var sectionCounts: [UInt16: Int] = [:]
        var replacements: [(range: Range<Int>, newBytes: [UInt8])] = []

        while offset < bytes.count {
            guard offset + 3 <= bytes.count else { break }
            let sectionType = bytes[offset]
            let length = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            let dataStart = offset + 3
            let dataEnd = dataStart + length
            guard dataEnd <= bytes.count else { break }

            // Ten sam podział co w parseBinarySections — patrz sectionHasNoAreaBits.
            let areaFlag: UInt16 = sectionHasNoAreaBits(sectionType)
                ? 0
                : (length > 0 ? UInt16(bytes[dataStart] >> 6) : 0)
            let key = UInt16(sectionType) << 2 | areaFlag
            let slotIdx = sectionCounts[key, default: 0]
            let target = min(slotIdx, patches.count - 1)
            let area: PatchArea = areaFlag == 1 ? .voice : .fx

            // Sekcje obszarów 0/1 (fx/voice) budujemy od zera z modelu; sekcje
            // obszaru 2 (Patch Settings) i opis patcha nadpisujemy w miejscu, bo
            // niosą też pola, których jeszcze nie modelujemy (morfy, unk2).
            // Do 2026-09-03 areaFlag zwijał 2 do 0 i warunek `areaFlag <= 1` był
            // zawsze prawdziwy: sekcja ustawień patcha była nadpisywana
            // parametrami obszaru FX, czyli kasowana przy każdym zapisie.
            // Sekcje bitowe budujemy na kopii oryginalnych bajtów — patrz `finishSection`.
            let seed = Array(bytes[dataStart ..< dataEnd])

            let newSectionData: [UInt8]? = switch sectionType {
            case SectionType.moduleList.rawValue where areaFlag <= 1:
                try serializeModuleSection(modules: patches[target].modules(in: area),
                                           area: area,
                                           seed: seed)
            case SectionType.cableList.rawValue where areaFlag <= 1:
                try serializeCableSection(cables: patches[target].cables(in: area),
                                          area: area,
                                          seed: seed)
            case SectionType.parameters.rawValue where areaFlag <= 1:
                try serializeParametersSection(
                    modules: patches[target].modules(in: area),
                    area: area,
                    emptyVariationCount: patches[target].parameterVariationCount[area] ?? 0,
                    seed: seed
                )
            case SectionType.moduleNames.rawValue where areaFlag <= 1:
                try serializeModuleNamesSection(modules: patches[target].modules(in: area),
                                                area: area,
                                                seed: seed)
            case SectionType.parameters.rawValue where areaFlag == 2:
                try rewriteSettingsSection(original: Array(bytes[dataStart ..< dataEnd]),
                                           settings: patches[target].variationSettings)
            case SectionType.morphParameters.rawValue:
                try serializeMorphSection(patches[target], seed: seed)
            case SectionType.globalKnobAssignments.rawValue:
                try performance.map { try serializeGlobalKnobSection($0, seed: seed) }
            case SectionType.knobAssignments.rawValue:
                try serializeKnobSection(patches[target], seed: seed)
            case SectionType.ctrlAssignments.rawValue:
                try serializeMidiControllerSection(patches[target], seed: seed)
            case SectionType.patchDescription.rawValue:
                try rewriteDescriptionSection(original: Array(bytes[dataStart ..< dataEnd]),
                                              description: patches[target].description)
            case SectionType.textPad.rawValue:
                textPadBytes(patches[target].notes)
            case SectionType.labels.rawValue:
                patches[target].moduleCustomData[UInt8(areaFlag)]
            case SectionType.performanceDescription.rawValue:
                performance.flatMap {
                    rewritePerformanceSection(original: Array(bytes[dataStart ..< dataEnd]), performance: $0)
                }
            default:
                nil
            }
            if let sec = newSectionData {
                let header = [sectionType, UInt8((sec.count >> 8) & 0xFF), UInt8(sec.count & 0xFF)]
                replacements.append((range: offset ..< dataEnd, newBytes: header + sec))
            }

            sectionCounts[key] = slotIdx + 1
            offset = dataEnd
        }

        for rep in replacements.reversed() {
            bytes.replaceSubrange(rep.range, with: rep.newBytes)
        }

        // Aktualizuj CRC-16 na końcu pliku (ostatnie 2 bajty).
        // CRC obejmuje binarną część pliku od bajtu po \0 (włącznie z version+type)
        // do przedostatniego bajtu (z wyłączeniem samego CRC).
        let crcStart = headerLength + 1
        let crcLen = bytes.count - 2 - crcStart
        if crcLen > 0, bytes.count >= 2 {
            let crc = calcCRC16(bytes, from: crcStart, length: crcLen)
            bytes[bytes.count - 2] = UInt8((crc >> 8) & 0xFF)
            bytes[bytes.count - 1] = UInt8(crc & 0xFF)
        }

        return Data(bytes)
    }

    // MARK: - CRC-16/CCITT (poly 0x1021, seed 0) — identyczny z G2-Edit/src/utils.c

    private static func crcIterator(seed: Int32, val: Int32) -> UInt16 {
        var crc: Int32 = 0
        var k: Int32 = (((seed >> 8) ^ val) & 255) << 8
        for _ in 0 ..< 8 {
            if (crc ^ k) & 0x8000 != 0 {
                crc = (crc << 1) ^ 0x1021
            } else {
                crc = crc << 1
            }
            k = k << 1
        }
        return UInt16(truncatingIfNeeded: (seed << 8) ^ crc)
    }

    private static func calcCRC16(_ bytes: [UInt8], from start: Int, length: Int) -> UInt16 {
        var crc: Int32 = 0
        for i in 0 ..< length {
            crc = Int32(crcIterator(seed: crc, val: Int32(bytes[start + i])))
        }
        return UInt16(truncatingIfNeeded: crc)
    }

    /// Zamyka sekcję: przycina bufor do faktycznie zapisanych bitów.
    ///
    /// Sekcje bitowe budujemy na kopii oryginalnych bajtów (`seed`), więc bity,
    /// których format nie definiuje — dopełnienie ostatniego bajtu i sześć bitów
    /// w nagłówku 0x5a — zostają takie, jakie były w pliku. Oryginał zostawia tam
    /// zawartość swojego bufora (`Skip`, nie `WriteBits`), czyli wartość, której
    /// nie da się wyliczyć: w kolekcji referencyjnej dopełnienie jest niezerowe
    /// w 27 z ~18 000 sekcji wersji 23, a nagłówek 0x5a w ponad połowie sekcji.
    /// Przy pustym `seed` (wysyłka przez USB) wychodzą zera, jak dotąd.
    private static func finishSection(_ bs: BitStream) -> [UInt8] {
        Array(bs.toBytes().prefix((bs.currentBitPosition + 7) / 8))
    }

    /// Serializuje listę modułów dla jednego obszaru do bajtów sekcji 0x4a.
    private static func serializeModuleSection(modules: [G2Module],
                                               area: PatchArea,
                                               seed: [UInt8] = []) throws -> [UInt8]
    {
        var bs = BitStream(data: seed)
        let areaVal: UInt32 = area == .voice ? 1 : 0
        try bs.writeBits(2, value: areaVal)
        try bs.writeBits(8, value: UInt32(modules.count))
        for module in modules {
            try bs.writeBits(8, value: UInt32(module.typeID))
            try bs.writeBits(8, value: UInt32(module.id))
            try bs.writeBits(7, value: UInt32(module.column))
            try bs.writeBits(7, value: UInt32(module.row))
            try bs.writeBits(8, value: UInt32(module.color))
            try bs.writeBits(1, value: module.uprate ? 1 : 0)
            try bs.writeBits(1, value: module.leds ? 1 : 0)
            try bs.writeBits(6, value: 0) // reserved
            try bs.writeBits(4, value: UInt32(module.modes.count))
            for modeVal in module.modes {
                try bs.writeBits(6, value: UInt32(modeVal))
            }
        }
        return finishSection(bs)
    }

    /// Serializuje listę kabli dla jednego obszaru do bajtów sekcji 0x52.
    private static func serializeCableSection(cables: [G2Cable],
                                              area: PatchArea,
                                              seed: [UInt8] = []) throws -> [UInt8]
    {
        var bs = BitStream(data: seed)
        let areaVal: UInt32 = area == .voice ? 1 : 0
        try bs.writeBits(2, value: areaVal) // area
        try bs.writeBits(12, value: 0) // unknown (TBits12)
        try bs.writeBits(10, value: UInt32(cables.count)) // TBits10
        for cable in cables {
            try bs.writeBits(3, value: UInt32(cable.color.rawValue))
            try bs.writeBits(8, value: UInt32(cable.fromModule))
            try bs.writeBits(6, value: UInt32(cable.fromConnector))
            try bs.writeBits(1, value: cable.sourceIsOutput ? 1 : 0) // linkType
            try bs.writeBits(8, value: UInt32(cable.toModule))
            try bs.writeBits(6, value: UInt32(cable.toConnector))
        }
        return finishSection(bs)
    }

    /// Serializuje sekcję parametrów (0x4d) dla jednego obszaru.
    /// Zapisuje wszystkie warianty z parameterVariations (lub var 0 × nVariations gdy brak danych).
    ///
    /// Kolejność i liczba wariantów idą za Module Param Data 11 (WriteStream)
    /// (oryginalny edytor Clavii): moduły wychodzą z posortowanego drzewa, czyli rosnąco
    /// po `id` — nie w kolejności z sekcji 0x4a, która sortowana nie jest.
    /// Licznik wariantów to licznik faktycznie dodanych zestawów, więc dla sekcji
    /// bez modułów prawie zawsze wynosi 0, a nie 9 — ale nie zawsze, dlatego dla
    /// pustej sekcji bierzemy `emptyVariationCount` odczytany z pliku.
    private static func serializeParametersSection(modules: [G2Module],
                                                   area: PatchArea,
                                                   emptyVariationCount: Int = 0,
                                                   seed: [UInt8] = []) throws -> [UInt8]
    {
        var bs = BitStream(data: seed)
        let areaVal: UInt32 = area == .voice ? 1 : 0
        // Moduły z parametrami plus te, które mają w sekcji wpis pusty (patrz `hasParameterEntry`)
        let mods = modules.filter { $0.hasParameterEntry || !$0.parameters.isEmpty }
            .sorted { $0.id < $1.id }
        // Nord podaje w pustej sekcji 10 (wariacje + bufor roboczy); plik zna tylko 0 albo 9.
        let n = mods.isEmpty ? clamp(emptyVariationCount, nVariations) : nVariations
        try bs.writeBits(2, value: areaVal)
        try bs.writeBits(8, value: UInt32(mods.count))
        try bs.writeBits(8, value: UInt32(n))
        for mod in mods {
            let nParams = mod.parameters.count
            try bs.writeBits(8, value: UInt32(mod.id))
            try bs.writeBits(7, value: UInt32(nParams))
            for v in 0 ..< n {
                try bs.writeBits(8, value: UInt32(v))
                let varParams: [Int] = if v < mod.parameterVariations.count {
                    mod.parameterVariations[v]
                } else {
                    mod.parameters // fallback: var 0 dla brakujących wariantów
                }
                for p in 0 ..< nParams {
                    let val = p < varParams.count ? varParams[p] : 0
                    try bs.writeBits(7, value: UInt32(max(0, min(127, val))))
                }
            }
        }
        return finishSection(bs)
    }

    /// Serializuje sekcję nazw modułów (0x5a).
    ///
    /// Za Module Name Data 11 (WriteStream) (oryginalny edytor Clavii): wpisy wychodzą
    /// z posortowanej mapy, czyli rosnąco po `id`, i obejmują **każdy** wpis mapy —
    /// również taki z pustą nazwą.
    private static func serializeModuleNamesSection(modules: [G2Module],
                                                    area: PatchArea,
                                                    seed: [UInt8] = []) throws -> [UInt8]
    {
        var bs = BitStream(data: seed)
        let areaVal: UInt32 = area == .voice ? 1 : 0
        let named = modules.filter { $0.hasNameEntry || !$0.label.isEmpty }.sorted { $0.id < $1.id }
        try bs.writeBits(2, value: areaVal)
        bs.skip(6) // oryginał robi tu `Skip(6)` — patrz `finishSection`
        try bs.writeBits(8, value: UInt32(named.count))
        for mod in named {
            try bs.writeBits(8, value: UInt32(mod.id))
            // Null-terminated ASCII, max 16 znaków (format BVerhue WriteName / pch2csd):
            // - krótsze niż 16: zapis znaków + \0
            // - dokładnie 16: zapis znaków bez \0 (brak miejsca)
            var nameBytes = [UInt8](mod.label.utf8.prefix(16))
            if nameBytes.count < 16 { nameBytes.append(0) }
            for b in nameBytes {
                try bs.writeBits(8, value: UInt32(b))
            }
        }
        return finishSection(bs)
    }

    /// Parse a .pch2 file from disk.
    public static func parse(url: URL) throws -> [G2Patch] {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            throw PatchParserError.notAPatchFile(url.lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    /// Parse the section stream from a USB `GetPatchSlot` response into a single patch.
    /// The wire format is byte-identical to the on-disk .pch2 binary sections — see
    /// reference/G2-Edit/src/usbComms.c `parse_patch()`, which dispatches on the same
    /// type codes as `SectionType` (0x21/0x4a/0x52/0x4d/0x5a/0x6f), each framed as
    /// `[type:1B][length:2B BE][data]`. `sectionBytes` must start at that first type
    /// byte (i.e. the response's `subCommand` byte prepended back onto its `payload`).
    public static func parseUsbPatchSlot(sectionBytes: [UInt8]) throws -> G2Patch {
        // Odpowiedź USB niesie sekcje jednego slotu, ale tablicę trzymamy
        // czteroelementową jak w parse(data:): gdyby sprzęt przysłał powtórzony
        // komplet sekcji, nadmiarowe wystąpienie trafi do slotu 1–3, zamiast
        // nadpisać slot 0.
        var slots = [G2Patch(), G2Patch(), G2Patch(), G2Patch()]
        var performance: G2PerformanceSettings?
        try parseBinarySections(&slots, performance: &performance, bytes: sectionBytes)
        slots[0].ensureRuntimeVariations()
        slots[0].syncParametersToActiveVariation()
        return slots[0]
    }

    /// Nagłówek performance'u odczytany Z URZĄDZENIA (Performance Header Request, 0x10).
    /// Stąd — i tylko stąd — wiadomo, **które sloty grają i który dostaje klawiaturę**;
    /// komunikat slotowy 0x07 niesie samą selekcję → [[Docs/usb/slots]].
    ///
    /// Odpowiedź to JEDNA ramka z DWOMA komunikatami (zmierzone na żywym Nordzie
    /// 2026-09-04, `USBProbe --slottest`): nazwa performance'u (podkomenda 0x29,
    /// 16 bajtów, bez terminatora przy pełnej długości), a zaraz za nią sekcja `0x11`
    /// w formacie **identycznym z plikiem `.prf2`** — z własnym nagłówkiem `[typ][długość:2B]`.
    /// `payload` to zawartość odpowiedzi po bajcie podkomendy.
    ///
    /// Oddajemy też **surową sekcję** (z nagłówkiem `[typ][długość]`): to jedyny szkielet
    /// nagłówka, jaki mamy dla performance'u bez pliku, a zapis idzie zawsze przez
    /// przepisanie gotowych bajtów — patrz `performanceHeaderSection`.
    public static func parseUsbPerformanceHeader(payload: [UInt8])
        -> (name: String, settings: G2PerformanceSettings, section: [UInt8])?
    {
        // Pole nazwy jest ZMIENNEJ długości: znaki do bajtu 0 włącznie, a przy pełnych
        // 16 znakach bez terminatora (tak samo jak nazwy slotów w sekcji 0x11 i tak samo
        // czyta to `g2ools.parse_name`). Stałe 16 bajtów przesuwałoby początek sekcji.
        let nameBytes = payload.prefix(performanceNameBytes).prefix { $0 != 0 }
        let name = String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
        let consumed = nameBytes.count < performanceNameBytes ? nameBytes.count + 1 : performanceNameBytes
        let rest = Array(payload.dropFirst(consumed))
        guard rest.count >= 3, rest[0] == SectionType.performanceDescription.rawValue else { return nil }
        let length = Int(rest[1]) << 8 | Int(rest[2])
        let body = Array(rest.dropFirst(3).prefix(length))
        guard body.count == length, let settings = parsePerformanceDescription(data: body) else { return nil }
        return (name, settings, Array(rest.prefix(3 + length)))
    }

    /// Gałki globalne odczytane Z URZĄDZENIA (`0x5E` → `0x5F`). `section` zaczyna się od
    /// nagłówka `[typ][długość:2B]` — układ jest ten sam co w pliku `.prf2`.
    public static func parseUsbGlobalKnobMap(section: [UInt8],
                                             into performance: inout G2PerformanceSettings) throws
    {
        guard section.count >= 3, section[0] == SectionType.globalKnobAssignments.rawValue else {
            throw PatchParserError.unknownSectionType(section.first ?? 0)
        }
        try parseGlobalKnobAssignments(&performance, data: Array(section.dropFirst(3)))
    }

    /// Notatnik slotu odczytany Z URZĄDZENIA (`0x6E` → `0x6F`), sekcja z nagłówkiem.
    public static func parseUsbTextpad(section: [UInt8]) throws -> String {
        guard section.count >= 3, section[0] == SectionType.textPad.rawValue else {
            throw PatchParserError.unknownSectionType(section.first ?? 0)
        }
        var patch = G2Patch()
        parseTextPad(&patch, data: Array(section.dropFirst(3)))
        return patch.notes
    }

    /// Nazwa performance'u w odpowiedzi 0x29 zajmuje stałe 16 bajtów, tak samo jak
    /// nazwy slotów w sekcji 0x11.
    private static let performanceNameBytes = 16

    // MARK: - Write (USB upload sections — module params / names)

    /// Sekcja 0x4a (ModuleList) w formacie gotowym do wysłania przez USB —
    /// identyczny układ bitów jak `write_module_list` w
    /// reference/G2-Edit/src/protocol.c (nagłówek [typ][długość] + treść).
    public static func writeModuleList(modules: [G2Module], area: PatchArea) throws -> [UInt8] {
        let body = try serializeModuleSection(modules: modules, area: area)
        return sectionHeader(type: SectionType.moduleList.rawValue, length: body.count) + body
    }

    /// Sekcja 0x52 (CableList) w formacie gotowym do wysłania przez USB —
    /// odpowiednik `write_cable_list` w reference/G2-Edit/src/protocol.c.
    public static func writeCableList(cables: [G2Cable], area: PatchArea) throws -> [UInt8] {
        let body = try serializeCableSection(cables: cables, area: area)
        return sectionHeader(type: SectionType.cableList.rawValue, length: body.count) + body
    }

    /// Sekcja 0x4d (Parameters) w formacie gotowym do wysłania przez USB —
    /// identyczny układ bitów jak `write_param_list` w
    /// reference/G2-Edit/src/protocol.c (nagłówek [typ][długość] + treść).
    public static func writeParamList(modules: [G2Module], area: PatchArea) throws -> [UInt8] {
        let body = try serializeParametersSection(modules: modules, area: area)
        return sectionHeader(type: SectionType.parameters.rawValue, length: body.count) + body
    }

    /// Sekcja 0x5a (ModuleNames) w formacie gotowym do wysłania przez USB —
    /// odpowiednik `write_module_names` w reference/G2-Edit/src/protocol.c.
    public static func writeModuleNames(modules: [G2Module], area: PatchArea) throws -> [UInt8] {
        let body = try serializeModuleNamesSection(modules: modules, area: area)
        return sectionHeader(type: SectionType.moduleNames.rawValue, length: body.count) + body
    }

    private static func sectionHeader(type: UInt8, length: Int) -> [UInt8] {
        [type, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
    }

    // MARK: - Zrzut odsłuchu Mutatora (0x4D ×3 + 0x65, jeden zestaw parametrów)

    /// Cały bufor odsłuchu Mutatora w **jednej molekule**, tak jak robi to oryginał
    /// (Muta Param Dump (WriteStream)): `0x4D` obszaru 2, `0x4D` Voice, `0x4D` FX
    /// i `0x65` z mapą morfów — każda sekcja z JEDNYM zestawem parametrów o numerze
    /// `variation` zamiast dziewięciu. Opis bajtów i drugie źródło → [[Docs/usb/mutator-dump]].
    ///
    /// Kolejność sekcji jest kolejnością pól molekuły (`+0x08` obszar 2, `+0x4C` Voice,
    /// `+0x90` FX, `+0xD4` mapa morfów), nie tą z pliku. Każda sekcja jest samodzielna:
    /// własny bajt typu, własna dwubajtowa długość, licznik bitów zerowany na starcie —
    /// dokładnie jak sekcje w strumieniu `0x37`.
    ///
    /// Wysyłką zajmuje się `G2UsbProtocol.paramDumpPayload`, które zdejmuje wiodący bajt
    /// typu pierwszej sekcji i robi z niego podkomendę.
    public static func writeMutatorParamDump(_ patch: G2Patch, variation: Int) throws -> [UInt8] {
        let settings = variation < patch.variationSettings.count
            ? patch.variationSettings[variation]
            : G2VariationSettings()
        var bytes = try singleSetSettingsSection(settings, variation: variation)
        for area in [PatchArea.voice, PatchArea.fx] {
            bytes += try singleSetParametersSection(modules: patch.modules(in: area),
                                                    area: area, variation: variation)
        }
        bytes += try singleSetMorphSection(patch.morphs(in: variation), variation: variation)
        return bytes
    }

    /// Sekcja `0x4D` obszaru 0/1 z jednym zestawem — ten sam układ pól co
    /// `serializeParametersSection`, tyle że `liczbaZestawów` = 1, a numer zestawu
    /// jest podany, zamiast biec od zera.
    private static func singleSetParametersSection(modules: [G2Module], area: PatchArea,
                                                   variation: Int) throws -> [UInt8]
    {
        var bs = BitStream(data: [])
        let mods = modules.filter { $0.hasParameterEntry || !$0.parameters.isEmpty }
            .sorted { $0.id < $1.id }
        try bs.writeBits(2, value: area == .voice ? 1 : 0)
        try bs.writeBits(8, value: UInt32(mods.count))
        try bs.writeBits(8, value: 1)
        for mod in mods {
            let values = variation < mod.parameterVariations.count
                ? mod.parameterVariations[variation]
                : mod.parameters
            try bs.writeBits(8, value: UInt32(clamp(mod.id, 255)))
            try bs.writeBits(7, value: UInt32(clamp(mod.parameters.count, 127)))
            try bs.writeBits(8, value: UInt32(clamp(variation, 255)))
            for index in 0 ..< mod.parameters.count {
                try bs.writeBits(7, value: UInt32(clamp(index < values.count ? values[index] : 0, 127)))
            }
        }
        return section(.parameters, finishSection(bs))
    }

    /// Sekcja `0x4D` obszaru 2 (ustawienia patcha) z jednym zestawem. Grupy i ich wpisy
    /// biorą się z tej samej tablicy co przy odczycie (`settingsGroup`), więc plik,
    /// magistrala i zrzut mówią o tym samym miejscu tym samym adresem.
    private static func singleSetSettingsSection(_ settings: G2VariationSettings,
                                                 variation: Int) throws -> [UInt8]
    {
        var bs = BitStream(data: [])
        let groups = settingsGroupIDs
        try bs.writeBits(2, value: 2)
        try bs.writeBits(8, value: UInt32(groups.count))
        try bs.writeBits(8, value: 1)
        for group in groups {
            let fields = settingsGroup(group)
            let entryCount = group == morphSettingsGroup ? 2 * G2Morph.count : (fields?.count ?? 0)
            try bs.writeBits(8, value: UInt32(clamp(group, 255)))
            try bs.writeBits(7, value: UInt32(clamp(entryCount, 127)))
            try bs.writeBits(8, value: UInt32(clamp(variation, 255)))
            for entry in 0 ..< entryCount {
                let value: Int = if group == morphSettingsGroup {
                    entry < G2Morph.count
                        ? settings.morphDials[entry]
                        : settings.morphModes[entry - G2Morph.count]
                } else {
                    fields.map { settings[keyPath: $0[entry]] } ?? 0
                }
                try bs.writeBits(7, value: UInt32(clamp(value, 127)))
            }
        }
        return section(.parameters, finishSection(bs))
    }

    /// Sekcja `0x65` z jednym zestawem. Nagłówek jest ten sam strumień bitów co w pliku,
    /// inaczej pogrupowany: `liczbaZestawów(8) liczbaMorfów(4) 8×tryb(2)`, a numer zestawu
    /// zajmuje pełne 8 bitów (w pliku widać jego dolną połówkę jako „wariacja(4)", a górną
    /// jako część rezerwy) → [[Docs/usb/mutator-dump]]. Czterobitowej przerwy na końcu nie
    /// ma: plik wstawia ją MIĘDZY zestawami, a tu zestaw jest jeden.
    private static func singleSetMorphSection(_ entries: [G2MorphAssignment],
                                              variation: Int) throws -> [UInt8]
    {
        var bs = BitStream(data: [])
        try bs.writeBits(8, value: 1)
        try bs.writeBits(4, value: UInt32(G2Morph.count))
        try bs.writeBits(16, value: 0) // tryby ośmiu morfów — w plikach zawsze zero
        try bs.writeBits(8, value: UInt32(clamp(variation, 255)))
        try bs.writeBits(32, value: 0)
        try bs.writeBits(24, value: 0)
        try bs.writeBits(8, value: UInt32(min(255, entries.count)))
        for entry in entries.prefix(255) {
            try bs.writeBits(2, value: UInt32(entry.location & 0x03))
            try bs.writeBits(8, value: UInt32(clamp(entry.moduleID, 255)))
            try bs.writeBits(7, value: UInt32(clamp(entry.paramIndex, 127)))
            try bs.writeBits(4, value: UInt32(clamp(entry.morph, 15)))
            let range = max(-128, min(127, entry.range))
            try bs.writeBits(8, value: UInt32(range < 0 ? range + 256 : range))
        }
        return section(.morphParameters, finishSection(bs))
    }

    /// Numery grup sekcji ustawień w kolejności zapisu: najpierw morfy (grupa 1),
    /// potem po jednej grupie na moduł obszaru 2.
    private static let settingsGroupIDs: [Int] =
        [morphSettingsGroup] + Set(G2PatchSetting.allCases.map(\.module)).sorted()

    private static func section(_ type: SectionType, _ body: [UInt8]) -> [UInt8] {
        sectionHeader(type: type.rawValue, length: body.count) + body
    }

    /// Strumień sekcji JEDNEGO slotu — dokładnie ta treść, którą oryginał wysyła do
    /// urządzenia po molekule Dump Bubble Destination (0x37), czyli cały patch naraz.
    ///
    /// Clavia składa tę wysyłkę tak: `CPatch::GetCompletePatchDump` → `PatchToFile`
    /// (ten sam obiekt pliku, co przy zapisie `.pch2`) → `CPatch::FileToBubble`, które
    /// zapisuje plik do strumienia (Patch File 13 (WriteMolecules)) i **od razu czyta
    /// go z powrotem**, robiąc z każdej sekcji osobną molekułę. Treść komunikatu to
    /// więc binarna część pliku bez dwóch bajtów wersji/typu i bez końcowego CRC —
    /// `reference/g2ools/g2ctl.py` `cmd_loadslot` robi to samo (`data[3:-2]`).
    ///
    /// `.prf2` niesie sekcje czterech slotów po kolei; **blok jednego slotu zaczyna sekcja
    /// opisu patcha 0x21**. Poza blokami leżą dwie sekcje całego pliku, nie slotu:
    /// 0x11 (ustawienia performance'u) i 0x5a-podobne 0x5f (mapa gałek performance'u).
    ///
    /// Pomiar na kolekcji referencyjnej (4 649 czytelnych plików, 7 718 bloków): **każdy**
    /// blok ma ten sam kształt `21 4a 4a 69 52 52 4d 4d 4d 65 62 60 5b 5b 5b 5a 5a 6f`,
    /// a jedyne sekcje poza blokami to wymienione 0x11 i 0x5f. Dlatego dzielimy po 0x21,
    /// a nie licznikiem wystąpień jak `saveAll`: bajt obszaru sekcji 0x69 i 0x60 nie jest
    /// polem obszaru (pierwszy bajt niesie dane), więc licznik rozrzucał je między sloty.
    /// Sekcja `0x11` z pliku `.prf2` — **z własnym nagłówkiem `[typ][długość:2B]`**, czyli
    /// dokładnie w tej postaci, w której idzie do urządzenia i w której z niego wraca.
    /// Performance Header Dump (WriteStream) nie dokłada nic od siebie: oddaje strumień
    /// prosto do `CPerformanceHeader_11::WriteStream`, a ten pisze sekcję razem z typem —
    /// dlatego numer molekuły `0x11` to po prostu bajt typu sekcji → [[Docs/usb/slots]].
    ///
    /// Pusta tablica = plik tej sekcji nie ma (zwykły `.pch2`).
    public static func performanceSectionStream(fileData: Data) throws -> [UInt8] {
        let bytes = [UInt8](fileData)
        let (headerLength, _) = try parseTextHeader(bytes)
        var offset = headerLength + 1 + 2
        while offset + 3 <= bytes.count {
            let dataEnd = offset + 3 + (Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]))
            guard dataEnd <= bytes.count else { break }
            if bytes[offset] == SectionType.performanceDescription.rawValue {
                return Array(bytes[offset ..< dataEnd])
            }
            offset = dataEnd
        }
        return []
    }

    /// Ustawienia performance'u wpisane w **gotowe bajty sekcji `0x11`** — wzięte z pliku
    /// albo z odpowiedzi urządzenia. Zmieniamy tylko pola, które rozumiemy; nazwy slotów
    /// i nierozpoznane bajty nagłówka sekcji zostają bajt w bajt, tak samo jak przy
    /// zapisie do pliku (`rewritePerformanceSection` — jeden kod dla obu dróg).
    ///
    /// `nil` = to nie jest sekcja 0x11 albo jej układ nie zgadza się z opisanym; wtedy
    /// lepiej nie wysłać nic, niż wysłać do Norda zgadywane bajty.
    public static func performanceHeaderSection(originalSection: [UInt8],
                                                performance: G2PerformanceSettings) -> [UInt8]?
    {
        guard originalSection.count >= 3,
              originalSection[0] == SectionType.performanceDescription.rawValue else { return nil }
        let length = Int(originalSection[1]) << 8 | Int(originalSection[2])
        let body = Array(originalSection.dropFirst(3).prefix(length))
        guard body.count == length,
              let rewritten = rewritePerformanceSection(original: body, performance: performance)
        else { return nil }
        return Array(originalSection.prefix(3)) + rewritten
    }

    public static func slotSectionStream(fileData: Data, slot: Int) throws -> [UInt8] {
        let bytes = [UInt8](fileData)
        let (headerLength, _) = try parseTextHeader(bytes)
        var offset = headerLength + 1 + 2
        var blockIndex = -1
        var stream: [UInt8] = []

        // Ostatnie dwa bajty pliku to CRC — pętla kończy się na nich sama, bo nie mieszczą
        // już nagłówka sekcji.
        while offset + 3 <= bytes.count {
            let sectionType = bytes[offset]
            let dataEnd = offset + 3 + (Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]))
            guard dataEnd <= bytes.count else { break }

            let belongsToFile = sectionType == SectionType.performanceDescription.rawValue
                || sectionType == performanceKnobsSection
            if sectionType == SectionType.patchDescription.rawValue { blockIndex += 1 }
            if !belongsToFile, blockIndex == slot {
                stream += bytes[offset ..< dataEnd]
            }
            offset = dataEnd
        }
        return stream
    }

    /// 0x5f — Performance Knob Map Dump, mapa gałek CAŁEGO performance'u. Leży w `.prf2`
    /// raz, za blokiem ostatniego slotu, i nie należy do żadnego z nich.
    static let performanceKnobsSection: UInt8 = 0x5F

    /// Sekcja `0x5F` z pliku, z bajtem typu i długością — tak jak
    /// `performanceSectionStream` oddaje sekcję `0x11`. Pusta tablica = plik jej nie ma
    /// (`.pch2`, albo performance bez ani jednej globalnej gałki).
    public static func performanceKnobMapStream(fileData: Data) throws -> [UInt8] {
        let bytes = [UInt8](fileData)
        let (headerLength, _) = try parseTextHeader(bytes)
        var offset = headerLength + 1 + 2
        while offset + 3 <= bytes.count {
            let dataEnd = offset + 3 + (Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]))
            guard dataEnd <= bytes.count else { break }
            if bytes[offset] == performanceKnobsSection {
                return Array(bytes[offset ..< dataEnd])
            }
            offset = dataEnd
        }
        return []
    }

    /// Zawartość pliku: sloty + ustawienia performance'u (`nil` dla `.pch2`,
    /// a także dla `.prf2`, którego sekcji 0x11 nie da się rozczytać — wtedy
    /// zapis zostawia ją nietkniętą).
    public struct ParsedPatchFile {
        public let patches: [G2Patch]
        public let performance: G2PerformanceSettings?
    }

    /// Parse a .pch2/.prf2 file. Returns 1 patch for .pch2, up to 4 for .prf2.
    public static func parse(data: Data) throws -> [G2Patch] {
        try parseFile(data: data).patches
    }

    /// Jak `parse(data:)`, ale zwraca też ustawienia performance'u (sekcja 0x11).
    public static func parseFile(data: Data) throws -> ParsedPatchFile {
        let bytes = [UInt8](data)
        let (headerLength, _) = try parseTextHeader(bytes)
        let binaryStart = headerLength + 1 + 2
        let binaryBytes = Array(bytes[binaryStart...])
        var slots = [G2Patch(), G2Patch(), G2Patch(), G2Patch()]
        var performance: G2PerformanceSettings?
        let slotCount = try parseBinarySections(&slots, performance: &performance, bytes: binaryBytes)
        // Nazwy patchy w slotach performance'u leżą wyłącznie w sekcji 0x11.
        for (index, slot) in (performance?.slots ?? []).enumerated() where index < slots.count {
            slots[index].name = slot.name
        }
        // Gałki mają pokazywać wariację, którą patch faktycznie gra — sekcja parametrów
        // bywa czytana zanim poznamy jej numer z sekcji opisu, więc wyrównanie robimy
        // dopiero tutaj, na komplecie sekcji.
        for index in slots.indices {
            // Plik przynosi dziewięć zestawów parametrów; dziesiąty jest buforem
            // Patch Mutatora i powstaje dopiero tutaj → [[Docs/ui/mutator]].
            slots[index].ensureRuntimeVariations()
            slots[index].syncParametersToActiveVariation()
        }
        // Ile slotów ma plik = ile kompletów sekcji w nim leży (.pch2 → 1, .prf2 → 4).
        // Pusty slot MUSI zostać w tablicy: indeks patcha to numer slotu w pliku,
        // a `saveAll` zapisuje sekcje N-tego slotu z `patches[N]`. Do 2026-09-03
        // puste sloty były odfiltrowywane, a w kolekcji referencyjnej 70 plików
        // .prf2 ma pusty slot PRZED używanym — po otwarciu i zapisaniu takiego
        // pliku moduły slotu D lądowały w sekcjach slotu C.
        return ParsedPatchFile(patches: Array(slots.prefix(max(1, min(slotCount, slots.count)))),
                               performance: performance)
    }

    /// Kategoria patcha (Acoustic, Bass… — `G2PatchCategory`) z samej sekcji opisu `0x21`,
    /// bez czytania reszty pliku. Przeglądarka Disk pyta o nią każdy plik w folderze,
    /// a folder bywa na dziesiątki tysięcy patchy, więc wystarcza jej początek pliku.
    /// `nil`, gdy sekcji opisu nie ma w podanych bajtach (performance, ucięty plik).
    public static func category(ofPatchFileHead data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let (headerLength, _) = try? parseTextHeader(bytes) else { return nil }
        var offset = headerLength + 1 + 2
        while offset + 3 <= bytes.count {
            let length = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            let dataStart = offset + 3
            guard dataStart + length <= bytes.count else { return nil }
            if bytes[offset] == SectionType.patchDescription.rawValue {
                var patch = G2Patch()
                guard (try? parsePatchDescription(&patch, data: Array(bytes[dataStart ..< dataStart + length]))) != nil
                else { return nil }
                return patch.description.category
            }
            offset = dataStart + length
        }
        return nil
    }

    // MARK: - Text header

    /// Returns (length of header text before \0, header string)
    private static func parseTextHeader(_ bytes: [UInt8]) throws -> (Int, String) {
        // The header must contain a null terminator within the first 4096 bytes
        let searchRange = min(4096, bytes.count)
        guard let nullIdx = bytes[..<searchRange].firstIndex(of: 0) else {
            throw PatchParserError.invalidHeader(whyThisIsNotAPatch(bytes))
        }
        let headerBytes = Array(bytes[..<nullIdx])
        let header = String(bytes: headerBytes, encoding: .ascii) ?? ""
        guard header.contains("G2") || header.contains("Nord Modular") else {
            throw PatchParserError.invalidHeader(
                "Header does not look like a Nord G2 file: \"\(String(header.prefix(60)))\""
            )
        }
        return (nullIdx, header)
    }

    /// Plik bez ani jednego bajtu zerowego to zwykle nie uszkodzony patch, tylko coś, co
    /// patchem nigdy nie było. Najczęstszy przypadek — w zbiorze użytkownika 116 plików
    /// z 4580 (2026-09-23): strona HTML „nie masz uprawnień do pobrania załącznika"
    /// zapisana pod nazwą `.pch2` przy masowym ściąganiu z forum bez zalogowania.
    /// Wszystkie mają identyczny rozmiar, bo wszystkie są tą samą stroną błędu.
    /// Komunikat o „null terminatorze" opisywał objaw w kategoriach parsera i nie dawał
    /// żadnej wskazówki, co z tym zrobić — a odpowiedź jest prosta i praktyczna.
    private static func whyThisIsNotAPatch(_ bytes: [UInt8]) -> String {
        let head = String(decoding: bytes.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if head.hasPrefix("<!doctype") || head.hasPrefix("<html") || head.hasPrefix("<?xml") {
            return "this is a web page, not a patch — most likely a download that saved "
                + "the site's error page under a .pch2 name"
        }
        return "no patch header in the first 4096 bytes — probably not a .pch2 file"
    }

    // MARK: - Section dispatch loop

    /// Sekcje, których pierwszy bajt NIE zaczyna się od dwóch bitów obszaru —
    /// wyliczony z nich `areaFlag` rozjeżdża mapowanie slotów w plikach .prf2:
    /// - `0x6f` TextPad to goły tekst, więc notatka zaczynająca się od litery
    ///   (0x40–0x7F) wpadała do kubełka „voice",
    /// - `0x21` PatchDescription zaczyna 7 bajtów nieznanych danych; w kolekcji
    ///   referencyjnej 4 z 7 718 sekcji mają tam bajt ≥ 0x40 (m.in. `Burn.prf2`,
    ///   gdzie dwa z czterech opisów slotów lądowały w osobnym liczniku
    ///   i nadpisywały opis slotu A).
    /// - `0x11` PerformanceDescription zaczyna bajt nieznanych danych (w całej
    ///   kolekcji zerowy, ale to nie jest pole obszaru).
    private static func sectionHasNoAreaBits(_ type: UInt8) -> Bool {
        type == SectionType.textPad.rawValue
            || type == SectionType.patchDescription.rawValue
            || type == SectionType.performanceDescription.rawValue
            || type == SectionType.globalKnobAssignments.rawValue
            || type == SectionType.ctrlAssignments.rawValue
    }

    /// Parse all binary sections into up to 4 slots.
    /// In a .pch2 file there is exactly one set of sections (→ slots[0]).
    /// In a .prf2 performance file each slot (A-D) has its own set of
    /// ModuleList / CableList / Parameters / ModuleNames sections which
    /// appear sequentially.  We detect the slot boundary by counting how
    /// many times each (sectionType × area) combination has been seen:
    /// the N-th occurrence (0-based) is routed to slots[N].
    /// Zwraca liczbę kompletów sekcji (slotów) w strumieniu — liczoną po sekcji
    /// ModuleList, bo to ona wyznacza istnienie slotu, także pustego (0 modułów).
    @discardableResult
    private static func parseBinarySections(_ slots: inout [G2Patch],
                                            performance: inout G2PerformanceSettings?,
                                            bytes: [UInt8]) throws -> Int
    {
        var offset = 0
        // key = (sectionType << 2) | areaFlag  →  count seen so far
        var sectionCounts: [UInt16: Int] = [:]
        var slotCount = 0

        while offset < bytes.count {
            // USB-only quirk (never seen in .pch2/.prf2 files): section type 0x2d is a bare
            // 2-byte marker `[0x2d][1 byte]`, not `[type][length:2B][data]` like every other
            // section. Confirmed against reference/G2-Edit/src/usbComms.c parse_patch(),
            // case 0x2d: it forces count = -1, netting a 2-byte total advance (type + 1 byte)
            // instead of the normal 3-byte header. Skipping it wrong (as a real TLV header)
            // desyncs every section that follows in the same GetPatchSlot response.
            if bytes[offset] == 0x2D {
                guard offset + 2 <= bytes.count else { break }
                offset += 2
                continue
            }

            guard offset + 3 <= bytes.count else { break }

            let sectionType = bytes[offset]
            let length = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            let dataStart = offset + 3
            let dataEnd = dataStart + length

            guard dataEnd <= bytes.count else {
                // Known section truncated mid-file = real corruption → throw.
                // Unknown section at end of file (e.g. type 0x04 with garbage length in
                // some community patches) = stop parsing gracefully, keep what we have.
                if SectionType(rawValue: sectionType) != nil {
                    throw PatchParserError.truncatedSection(sectionType, bytes.count - dataStart, length)
                }
                break
            }

            let sectionData = Array(bytes[dataStart ..< dataEnd])

            // The first two bits of the section payload encode the area:
            //   0 = fx, 1 = voice, 2 = patch settings.
            // Wszystkie TRZY muszą mieć osobny klucz. Do 2026-09-03 obszar 2 był
            // zwijany do 0, więc sekcja parametrów FX wypadała jako *drugie*
            // wystąpienie klucza (0x4d, 0) i trafiała do slotu 1 — w pliku .pch2
            // slot pusty, czyli komplet parametrów obszaru FX przepadał po cichu.
            // Sekcje bez bitów obszaru → patrz sectionHasNoAreaBits.
            let areaFlag: UInt16 = sectionHasNoAreaBits(sectionType)
                ? 0
                : (sectionData.isEmpty ? 0 : UInt16(sectionData[0] >> 6))
            let key = UInt16(sectionType) << 2 | areaFlag

            let slotIdx = sectionCounts[key, default: 0]
            sectionCounts[key] = slotIdx + 1
            let target = min(slotIdx, slots.count - 1)
            if sectionType == SectionType.moduleList.rawValue {
                slotCount = max(slotCount, slotIdx + 1)
            }

            switch sectionType {
            case SectionType.moduleList.rawValue:
                try parseModuleList(&slots[target], data: sectionData)
            case SectionType.cableList.rawValue:
                try parseCableList(&slots[target], data: sectionData)
            case SectionType.parameters.rawValue:
                try parseParameters(&slots[target], data: sectionData)
            case SectionType.moduleNames.rawValue:
                try parseModuleNames(&slots[target], data: sectionData)
            case SectionType.morphParameters.rawValue:
                try parseMorphParameters(&slots[target], data: sectionData)
            case SectionType.globalKnobAssignments.rawValue:
                if performance == nil { performance = G2PerformanceSettings() }
                try parseGlobalKnobAssignments(&performance!, data: sectionData)
            case SectionType.knobAssignments.rawValue:
                try parseKnobAssignments(&slots[target], data: sectionData)
            case SectionType.ctrlAssignments.rawValue:
                try parseMidiControllerAssignments(&slots[target], data: sectionData)
            case SectionType.patchDescription.rawValue:
                try parsePatchDescription(&slots[target], data: sectionData)
            case SectionType.textPad.rawValue:
                parseTextPad(&slots[target], data: sectionData)
            case SectionType.labels.rawValue:
                slots[target].moduleCustomData[UInt8(areaFlag)] = sectionData
            case SectionType.performanceDescription.rawValue:
                let globalKnobs = performance?.globalKnobAssignments
                performance = parsePerformanceDescription(data: sectionData)
                if let globalKnobs { performance?.globalKnobAssignments = globalKnobs }
            default:
                break
            }

            offset = dataEnd
        }
        return slotCount
    }

    // MARK: - Section 0x21: PatchDescription

    private static func parsePatchDescription(_ patch: inout G2Patch, data: [UInt8]) throws {
        // Skip 7 bytes of unknown/reserved data at start (matches g2ools offset 7*8)
        var bs = BitStream(data: data, startBit: 7 * 8)
        do {
            var d = G2PatchDescription()
            _ = try bs.readBits(5) // reserved
            d.voices = try Int(bs.readBits(5))
            d.height = try Int(bs.readBits(14))
            _ = try bs.readBits(3) // unk2
            d.redVisible = try bs.readBits(1) == 1
            d.blueVisible = try bs.readBits(1) == 1
            d.yellowVisible = try bs.readBits(1) == 1
            d.orangeVisible = try bs.readBits(1) == 1
            d.greenVisible = try bs.readBits(1) == 1
            d.purpleVisible = try bs.readBits(1) == 1
            d.whiteVisible = try bs.readBits(1) == 1
            d.monopoly = try Int(bs.readBits(2))
            d.variation = try Int(bs.readBits(8))
            d.category = try Int(bs.readBits(8))
            patch.description = d
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    // MARK: - Section 0x4a: ModuleList

    // Binary layout (g2ools ModuleList.parse_area):
    //   area(2), nModules(8)
    //   per module:
    //     typeID(8), index(8), horiz(7), vert(7), color(8),
    //     uprate(1), leds(1), reserved(6), nModes(4)
    //     per mode: value(6)

    private static func parseModuleList(_ patch: inout G2Patch, data: [UInt8]) throws {
        var bs = BitStream(data: data)
        do {
            let areaRaw = try bs.readBits(2)
            let area = areaRaw == 1 ? PatchArea.voice : PatchArea.fx
            let nModules = try Int(bs.readBits(8))

            for _ in 0 ..< nModules {
                let typeID = try Int(bs.readBits(8))
                var module = G2Module(id: 0, typeID: typeID, area: area)

                module.id = try Int(bs.readBits(8))
                module.column = try Int(bs.readBits(7))
                module.row = try Int(bs.readBits(7))
                module.color = try UInt8(bs.readBits(8))
                module.uprate = try bs.readBits(1) == 1
                module.leds = try bs.readBits(1) == 1
                _ = try bs.readBits(6) // reserved

                let nModes = try Int(bs.readBits(4))
                module.modes = []
                for _ in 0 ..< nModes {
                    try module.modes.append(Int(bs.readBits(6)))
                }
                // parameters are filled in later by the Parameters section
                patch.add(module: module)
            }
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    // MARK: - Section 0x52: CableList

    // Binary layout:
    //   area(2), unknown(12), nCables(10)
    //   per cable:
    //     color(3), srcModule(8), srcConn(6), linkType(1), dstModule(8), dstConn(6)
    //
    // Podział nagłówka potwierdzony w trzech niezależnych źródłach:
    // BVerhue g2_file.pas:341 (`FUnknown : TBits12; FCableCount : TBits10`),
    // BVerhue g2_mess.pas:4805 (`WriteBits(Unknown, 12); WriteBits(Count, 10)`)
    // oraz G2-Edit protocol.c `parse_cable_list` (2 / 12 / 10).
    // Wcześniej mieliśmy tu 6 + 16 — łącznie tyle samo bitów, więc dla plików
    // z zerowym `unknown` i liczbą kabli < 1024 wynik był ten sam, ale plik
    // z niezerowym `unknown` dawał absurdalną liczbę kabli i psuł cały odczyt.

    private static func parseCableList(_ patch: inout G2Patch, data: [UInt8]) throws {
        var bs = BitStream(data: data)
        do {
            let areaRaw = try bs.readBits(2)
            let area = areaRaw == 1 ? PatchArea.voice : PatchArea.fx
            _ = try bs.readBits(12) // unknown
            let nCables = try Int(bs.readBits(10))

            for _ in 0 ..< nCables {
                let colorRaw = try UInt8(bs.readBits(3))
                let srcModule = try Int(bs.readBits(8))
                let srcConn = try Int(bs.readBits(6))
                // linkType: 1 = źródło jest wyjściem, 0 = źródło jest wejściem
                let sourceIsOutput = try bs.readBits(1) == 1
                let dstModule = try Int(bs.readBits(8))
                let dstConn = try Int(bs.readBits(6))

                let color = CableColor(rawValue: colorRaw) ?? .red
                let cable = G2Cable(fromModule: srcModule, fromConnector: srcConn,
                                    toModule: dstModule, toConnector: dstConn,
                                    color: color, area: area,
                                    sourceIsOutput: sourceIsOutput)
                patch.add(cable: cable)
            }
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    // MARK: - Section 0x4d: Parameters

    // Binary layout (g2ools Parameters.parse_area):
    //   area(2), nModules(8), nVariations(8)
    //   per module:
    //     moduleIndex(8), nParams(7)
    //     per variation:
    //       variationIndex(8), param0(7), param1(7), …

    private static func parseParameters(_ patch: inout G2Patch, data: [UInt8]) throws {
        var bs = BitStream(data: data)
        do {
            let areaRaw = try Int(bs.readBits(2))
            // areaRaw: 2=settings, 1=voice, 0=fx
            guard areaRaw == 1 || areaRaw == 0 else {
                try parseSettings(&patch, data: data)
                return
            }
            let area = areaRaw == 1 ? PatchArea.voice : PatchArea.fx
            let nModules = try Int(bs.readBits(8))
            let nVariations = try Int(bs.readBits(8))
            patch.parameterVariationCount[area] = nVariations

            for _ in 0 ..< nModules {
                let moduleIndex = try Int(bs.readBits(8))
                let nParams = try Int(bs.readBits(7))

                // Find the module in our patch
                let moduleRef: G2Module? = if area == .voice {
                    patch.voiceModules.first(where: { $0.id == moduleIndex })
                } else {
                    patch.fxModules.first(where: { $0.id == moduleIndex })
                }

                // Read all variation data — store all variations and var 0 as active
                var allVariations = [[Int]](repeating: [Int](repeating: 0, count: nParams),
                                            count: nVariations)
                for v in 0 ..< nVariations {
                    let variationIdx = try Int(bs.readBits(8))
                    for p in 0 ..< nParams {
                        allVariations[v][p] = try Int(bs.readBits(7))
                    }
                    // Re-order: store by variationIdx in case file has non-sequential order
                    if variationIdx < nVariations {
                        allVariations[variationIdx] = allVariations[v]
                    }
                }

                if moduleRef != nil {
                    if area == .voice {
                        if let idx = patch.voiceModules.firstIndex(where: { $0.id == moduleIndex }) {
                            patch.voiceModules[idx].parameters = allVariations[0]
                            patch.voiceModules[idx].parameterVariations = allVariations
                            patch.voiceModules[idx].hasParameterEntry = true
                        }
                    } else {
                        if let idx = patch.fxModules.firstIndex(where: { $0.id == moduleIndex }) {
                            patch.fxModules[idx].parameters = allVariations[0]
                            patch.fxModules[idx].parameterVariations = allVariations
                            patch.fxModules[idx].hasParameterEntry = true
                        }
                    }
                }
            }
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    // MARK: - Section 0x4d, obszar 2: Patch Settings

    /// Układ (g2ools nord/g2/file.py — Parameters.parse_settings/format_settings):
    ///   area(2)=2, nSections(8)=7, nVariations(8)=9
    ///   × nSections:      group(8), nEntries(7)
    ///     × nVariations:  variation(8), × nEntries: value(7)
    ///
    /// Grupa 1 ma 16 wpisów: osiem gałek morfu, potem osiem źródeł
    /// (`G2VariationSettings.morphDials` / `.morphModes`) → [[Docs/ui/morphs]].
    /// Kształt potwierdzony na 7 716 sekcjach z kolekcji referencyjnej: wszystkie
    /// co do jednej mają 7 grup, 9 wariacji i wpisy 16/2/2/2/3/4/2.
    /// Grupa morfów w sekcji ustawień — jedyna, której wpisy nie są polami
    /// `G2VariationSettings`, tylko dwiema tablicami po osiem wartości.
    private static let morphSettingsGroup = 1

    /// Układ grup bierzemy z `G2PatchSetting` — tej samej tablicy, z której korzysta
    /// wysyłka na żywo. Numer grupy jest numerem modułu, pozycja w grupie numerem
    /// parametru, więc plik i magistrala mówią o tym samym miejscu tym samym adresem.
    private static func settingsGroup(_ group: Int) -> [WritableKeyPath<G2VariationSettings, Int>]? {
        G2PatchSetting.fields(inModule: group)
    }

    private static func parseSettings(_ patch: inout G2Patch, data: [UInt8]) throws {
        var bs = BitStream(data: data)
        do {
            _ = try bs.readBits(2) // area = 2 (settings)
            let groupCount = try Int(bs.readBits(8))
            let variationCount = try Int(bs.readBits(8))
            guard groupCount > 0, variationCount > 0 else { return }

            var settings = [G2VariationSettings](repeating: G2VariationSettings(),
                                                 count: G2Patch.runtimeVariationCount)
            for _ in 0 ..< groupCount {
                let group = try Int(bs.readBits(8))
                let entryCount = try Int(bs.readBits(7))
                let fields = settingsGroup(group)
                for _ in 0 ..< variationCount {
                    let variation = try Int(bs.readBits(8))
                    for entry in 0 ..< entryCount {
                        let value = try Int(bs.readBits(7))
                        guard variation < settings.count else { continue }
                        if group == morphSettingsGroup {
                            if entry < G2Morph.count {
                                settings[variation].morphDials[entry] = value
                            } else if entry < 2 * G2Morph.count {
                                settings[variation].morphModes[entry - G2Morph.count] = value
                            }
                            continue
                        }
                        guard let fields, entry < fields.count else { continue }
                        settings[variation][keyPath: fields[entry]] = value
                    }
                }
            }
            // BitStream czyta poza końcem bufora jako zera (jak g2ools), więc obcięta
            // sekcja dałaby komplet wyzerowanych ustawień zamiast błędu — wolimy zostawić
            // wartości domyślne modelu i nie ruszać takiej sekcji przy zapisie.
            guard bs.currentBitPosition <= data.count * 8 else { return }
            patch.variationSettings = settings
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    /// Wpisuje ustawienia z modelu w istniejące bity sekcji 0x4d obszaru 2.
    /// Sekcja zachowuje długość, a wszystko czego nie modelujemy (grupa morfów,
    /// nagłówki grup, bity wyrównania na końcu) zostaje bit w bit. `nil` = układ
    /// sekcji nie zgadza się z opisanym wyżej, więc zapis zostawia oryginał.
    private static func rewriteSettingsSection(original: [UInt8],
                                               settings: [G2VariationSettings]) throws -> [UInt8]?
    {
        var bs = BitStream(data: original)
        do {
            guard try bs.readBits(2) == 2 else { return nil }
            let groupCount = try Int(bs.readBits(8))
            let variationCount = try Int(bs.readBits(8))
            guard groupCount > 0, variationCount > 0 else { return nil }

            for _ in 0 ..< groupCount {
                let group = try Int(bs.readBits(8))
                let entryCount = try Int(bs.readBits(7))
                let fields = settingsGroup(group)
                for _ in 0 ..< variationCount {
                    let variation = try Int(bs.readBits(8))
                    for entry in 0 ..< entryCount {
                        guard variation < settings.count else {
                            bs.skip(7)
                            continue
                        }
                        if group == morphSettingsGroup {
                            let morphs = settings[variation]
                            if entry < G2Morph.count {
                                try bs.writeBits(7, value: UInt32(clamp(morphs.morphDials[entry], 127)))
                            } else if entry < 2 * G2Morph.count {
                                try bs.writeBits(7, value: UInt32(clamp(morphs.morphModes[entry - G2Morph.count], 127)))
                            } else {
                                bs.skip(7)
                            }
                            continue
                        }
                        guard let fields, entry < fields.count else {
                            bs.skip(7)
                            continue
                        }
                        try bs.writeBits(7, value: UInt32(clamp(settings[variation][keyPath: fields[entry]], 127)))
                    }
                }
            }
            guard bs.currentBitPosition <= original.count * 8 else { return nil }
            return bs.toBytes()
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    // MARK: - Sekcja 0x65: przypisania morfów

    /// Układ (g2ools `MorphParameters`, BVerhue `TMorphParameters.Read`):
    ///   nVariations(8), nMorphs(4), rezerwa(20)
    ///   × nVariations: wariacja(4), 56 bitów zer, liczba(8),
    ///                  × liczba: obszar(2), moduł(8), parametr(7), morf(4), zakres(8)
    ///                  + 4 bity rezerwy (po KAŻDEJ poza ostatnią)
    ///
    /// Zmierzone na 3 628 sekcjach kolekcji referencyjnej: nVariations zawsze 9,
    /// nMorphs zawsze 8, obie rezerwy zawsze zerowe, a długość sekcji to dokładnie
    /// zaokrąglenie bitów w górę do bajtu. Dlatego zapis buduje sekcję od zera —
    /// nie ma tu pola, którego nie znamy, a długość i tak się zmienia z liczbą przypisań.
    private static func parseMorphParameters(_ patch: inout G2Patch, data: [UInt8]) throws {
        var bs = BitStream(data: data)
        do {
            let variationCount = try Int(bs.readBits(8))
            _ = try bs.readBits(4) // liczba morfów — zawsze 8
            _ = try bs.readBits(20) // rezerwa
            // Plik ma 9 wariacji, urządzenie oddaje 10 (dziewiąta+1 to bufor roboczy).
            // Do 2026-10-14 granica była 9 i sekcja z Norda wypadała w całości, więc
            // patch odczytany z urządzenia nie miał ani jednego przypisania morfu.
            guard variationCount > 0, variationCount <= G2Patch.runtimeVariationCount else { return }

            var assignments = [[G2MorphAssignment]](repeating: [], count: G2Patch.runtimeVariationCount)
            for i in 0 ..< variationCount {
                let variation = try Int(bs.readBits(4))
                bs.skip(56) // zera — patrz komentarz wyżej
                let count = try Int(bs.readBits(8))
                for _ in 0 ..< count {
                    let location = try UInt8(bs.readBits(2))
                    let moduleID = try Int(bs.readBits(8))
                    let paramIndex = try Int(bs.readBits(7))
                    let morph = try Int(bs.readBits(4))
                    let rawRange = try Int(bs.readBits(8))
                    guard assignments.indices.contains(variation) else { continue }
                    assignments[variation].append(
                        G2MorphAssignment(location: location, moduleID: moduleID,
                                          paramIndex: paramIndex, morph: morph,
                                          range: rawRange > 127 ? rawRange - 256 : rawRange)
                    )
                }
                if i < variationCount - 1 { bs.skip(4) }
            }
            // Obcięta sekcja czyta się jako zera (BitStream nie rzuca poza końcem),
            // więc lepiej zostawić model pusty niż wpisać wymyślone przypisania.
            guard bs.currentBitPosition <= data.count * 8 else { return }
            patch.morphAssignments = assignments
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    /// Buduje sekcję 0x65 z modelu, w kolejności, w jakiej wpisy siedzą w modelu —
    /// czyli tej z pliku. Porządek pliku to rosnąco **(obszar, moduł, parametr, morf)**:
    /// klucz Morph Spec w drzewie Morph Map Data 11 Clavii (zmierzone na kolekcji
    /// referencyjnej: 10 642 wariacje zgodne, 75 nie — pliki z innych narzędzi,
    /// bo g2ools sortuje tylko po numerze modułu). Nowe przypisania wstawia w to
    /// miejsce `G2Patch.setMorphRange`, więc serializer niczego nie przestawia
    /// i plik nietknięty wraca bajt w bajt.
    ///
    /// `seed` to oryginalne bajty sekcji — jak w pozostałych serializerach, po to,
    /// żeby bity dopełnienia ostatniego bajtu zostały takie, jakie były w pliku.
    /// Nie są zawsze zerowe: oryginał zostawia tam zawartość swojego bufora
    /// (`Auto309.pch2`, `gabbahey3.pch2` i kilka innych z kolekcji referencyjnej).
    private static func serializeMorphSection(_ patch: G2Patch, seed: [UInt8] = []) throws -> [UInt8] {
        var bs = BitStream(data: seed)
        do {
            try bs.writeBits(8, value: UInt32(nVariations))
            try bs.writeBits(4, value: UInt32(G2Morph.count))
            try bs.writeBits(20, value: 0)
            for variation in 0 ..< nVariations {
                try bs.writeBits(4, value: UInt32(variation))
                try bs.writeBits(32, value: 0)
                try bs.writeBits(24, value: 0)
                let entries = patch.morphs(in: variation)
                try bs.writeBits(8, value: UInt32(min(255, entries.count)))
                for entry in entries.prefix(255) {
                    try bs.writeBits(2, value: UInt32(entry.location & 0x03))
                    try bs.writeBits(8, value: UInt32(clamp(entry.moduleID, 255)))
                    try bs.writeBits(7, value: UInt32(clamp(entry.paramIndex, 127)))
                    try bs.writeBits(4, value: UInt32(clamp(entry.morph, 15)))
                    let range = max(-128, min(127, entry.range))
                    try bs.writeBits(8, value: UInt32(range < 0 ? range + 256 : range))
                }
                if variation < nVariations - 1 { try bs.writeBits(4, value: 0) }
            }
            return finishSection(bs)
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    // MARK: - Sekcja 0x62: gałki stron parametrów

    /// Układ (g2ools `KnobAssignments`): `liczba(16)`, potem dla każdej gałki
    /// `przypisana(1)` i — gdy przypisana — `obszar(2) moduł(8) isLed(2) parametr(7)`.
    ///
    /// Zmierzone na 3 628 sekcjach z plików `.pch2` i 4 094 z `.prf2`: liczba zawsze
    /// 120, długość sekcji to zaokrąglenie bitów w górę, ogon zawsze zerowy.
    /// **Plik `.prf2` ma cztery takie sekcje, po jednej na slot, i żadna nie niesie
    /// dwóch bitów numeru slotu**, które dokłada g2ools dla performance'ów — czytamy
    /// je więc tak samo jak w patchu, sekcja po sekcji do kolejnych slotów.
    private static func parseKnobAssignments(_ patch: inout G2Patch, data: [UInt8]) throws {
        var bs = BitStream(data: data)
        do {
            let count = try Int(bs.readBits(16))
            guard count > 0, count <= G2KnobPages.knobCount else { return }
            var knobs = [G2KnobAssignment?](repeating: nil, count: G2KnobPages.knobCount)
            for index in 0 ..< count {
                guard try bs.readBits(1) == 1 else { continue }
                let location = try UInt8(bs.readBits(2))
                let moduleID = try Int(bs.readBits(8))
                let isLed = try Int(bs.readBits(2))
                let paramIndex = try Int(bs.readBits(7))
                knobs[index] = G2KnobAssignment(location: location, moduleID: moduleID,
                                                paramIndex: paramIndex, isLed: isLed)
            }
            guard bs.currentBitPosition <= data.count * 8 else { return }
            patch.knobAssignments = knobs
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    /// Buduje sekcję 0x62 z modelu. Jak przy morfach — na `seed`, żeby bity
    /// dopełnienia ostatniego bajtu zostały takie, jakie były w pliku.
    private static func serializeKnobSection(_ patch: G2Patch, seed: [UInt8] = []) throws -> [UInt8] {
        var bs = BitStream(data: seed)
        do {
            try bs.writeBits(16, value: UInt32(G2KnobPages.knobCount))
            for index in 0 ..< G2KnobPages.knobCount {
                guard let knob = patch.knobAssignment(at: index) else {
                    try bs.writeBits(1, value: 0)
                    continue
                }
                try bs.writeBits(1, value: 1)
                try bs.writeBits(2, value: UInt32(knob.location & 0x03))
                try bs.writeBits(8, value: UInt32(clamp(knob.moduleID, 255)))
                try bs.writeBits(2, value: UInt32(clamp(knob.isLed, 3)))
                try bs.writeBits(7, value: UInt32(clamp(knob.paramIndex, 127)))
            }
            return finishSection(bs)
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    // MARK: - Section 0x60: MIDI controller assignments

    /// The section starts with a seven-bit entry count. Each entry stores the
    /// controller number, location, module and parameter in that order.
    private static func parseMidiControllerAssignments(_ patch: inout G2Patch,
                                                       data: [UInt8]) throws
    {
        var bs = BitStream(data: data)
        do {
            let count = try Int(bs.readBits(7))
            guard count <= G2MidiControllers.count else { return }
            var assignments = [G2MidiControllerAssignment?](
                repeating: nil,
                count: G2MidiControllers.count
            )
            for _ in 0 ..< count {
                let cc = try Int(bs.readBits(7))
                let location = try UInt8(bs.readBits(2))
                let moduleID = try Int(bs.readBits(8))
                let paramIndex = try Int(bs.readBits(7))
                guard assignments.indices.contains(cc) else { continue }
                assignments[cc] = G2MidiControllerAssignment(
                    location: location,
                    moduleID: moduleID,
                    paramIndex: paramIndex
                )
            }
            guard bs.currentBitPosition <= data.count * 8 else { return }
            patch.midiControllerAssignments = assignments
        } catch let error as BitStreamError {
            throw PatchParserError.bitStreamError(error)
        }
    }

    private static func serializeMidiControllerSection(_ patch: G2Patch,
                                                       seed: [UInt8] = []) throws -> [UInt8]
    {
        var bs = BitStream(data: seed)
        do {
            let entries = patch.midiControllerAssignments.enumerated().compactMap { cc, assignment in
                assignment.map { (cc, $0) }
            }
            try bs.writeBits(7, value: UInt32(entries.count))
            for (cc, assignment) in entries {
                try bs.writeBits(7, value: UInt32(cc))
                try bs.writeBits(2, value: UInt32(assignment.location & 0x03))
                try bs.writeBits(8, value: UInt32(clamp(assignment.moduleID, 255)))
                try bs.writeBits(7, value: UInt32(clamp(assignment.paramIndex, 127)))
            }
            return finishSection(bs)
        } catch let error as BitStreamError {
            throw PatchParserError.bitStreamError(error)
        }
    }

    // MARK: - Sekcja 0x5F: globalne gałki performance'u

    /// Mapa globalna ma ten sam nagłówek i pola co 0x62, a każde przypisanie kończy
    /// dwubitowy numer slotu A…D. Źródło: BVerhue `TGlobalKnob.Read/Write` oraz
    /// Clavia `Format_11::W_GlobalKnobMapData`.
    private static func parseGlobalKnobAssignments(_ performance: inout G2PerformanceSettings,
                                                   data: [UInt8]) throws
    {
        var bs = BitStream(data: data)
        do {
            let count = try Int(bs.readBits(16))
            guard count > 0, count <= G2KnobPages.knobCount else { return }
            var knobs = [G2GlobalKnobAssignment?](repeating: nil, count: G2KnobPages.knobCount)
            for index in 0 ..< count {
                guard try bs.readBits(1) == 1 else { continue }
                let location = try UInt8(bs.readBits(2))
                let moduleID = try Int(bs.readBits(8))
                let isLed = try Int(bs.readBits(2))
                let paramIndex = try Int(bs.readBits(7))
                let slot = try Int(bs.readBits(2))
                knobs[index] = G2GlobalKnobAssignment(slot: slot, location: location,
                                                      moduleID: moduleID, paramIndex: paramIndex,
                                                      isLed: isLed)
            }
            guard bs.currentBitPosition <= data.count * 8 else { return }
            performance.globalKnobAssignments = knobs
        } catch let error as BitStreamError {
            throw PatchParserError.bitStreamError(error)
        }
    }

    private static func serializeGlobalKnobSection(_ performance: G2PerformanceSettings,
                                                   seed: [UInt8] = []) throws -> [UInt8]
    {
        var bs = BitStream(data: seed)
        do {
            try bs.writeBits(16, value: UInt32(G2KnobPages.knobCount))
            for index in 0 ..< G2KnobPages.knobCount {
                guard performance.globalKnobAssignments.indices.contains(index),
                      let knob = performance.globalKnobAssignments[index]
                else {
                    try bs.writeBits(1, value: 0)
                    continue
                }
                try bs.writeBits(1, value: 1)
                try bs.writeBits(2, value: UInt32(knob.location & 0x03))
                try bs.writeBits(8, value: UInt32(clamp(knob.moduleID, 255)))
                try bs.writeBits(2, value: UInt32(clamp(knob.isLed, 3)))
                try bs.writeBits(7, value: UInt32(clamp(knob.paramIndex, 127)))
                try bs.writeBits(2, value: UInt32(clamp(knob.slot, 3)))
            }
            return finishSection(bs)
        } catch let error as BitStreamError {
            throw PatchParserError.bitStreamError(error)
        }
    }

    /// Wpisuje opis patcha w istniejące bity sekcji 0x21 — w miejscu, bez zmiany
    /// długości; 7 bajtów nieznanych danych i pole `unk2` zostają nietknięte.
    /// Układ pól: g2ools PatchDescription.description_attrs.
    private static func rewriteDescriptionSection(original: [UInt8],
                                                  description: G2PatchDescription) throws -> [UInt8]?
    {
        // 7 bajtów nieznanych danych + 52 bity pól
        guard original.count * 8 >= 7 * 8 + 52 else { return nil }
        var bs = BitStream(data: original, startBit: 7 * 8)
        do {
            bs.skip(5) // reserved
            try bs.writeBits(5, value: UInt32(clamp(description.voices, 31)))
            try bs.writeBits(14, value: UInt32(clamp(description.height, 16383)))
            bs.skip(3) // unk2
            for visible in [description.redVisible, description.blueVisible, description.yellowVisible,
                            description.orangeVisible, description.greenVisible,
                            description.purpleVisible, description.whiteVisible]
            {
                try bs.writeBits(1, value: visible ? 1 : 0)
            }
            try bs.writeBits(2, value: UInt32(clamp(description.monopoly, 3)))
            // Bufor mutatora (9) i `Init` (8) nie są wariacjami do grania. Oryginał
            // ostrzega o tym w instrukcji: „If none of the eight Patch Variations is
            // selected during Save, the Patch will open with the first Patch Variation
            // selected" — czyli zapisuje się wtedy zero.
            let savedVariation = description.variation > 7 ? 0 : description.variation
            try bs.writeBits(8, value: UInt32(clamp(savedVariation, 255)))
            try bs.writeBits(8, value: UInt32(clamp(description.category, 255)))
            return bs.toBytes()
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    /// Ile bajtów ma ciało sekcji `0x21`: 7 nieznanych + 52 bity pól + 12 bitów na końcu,
    /// razem 120 bitów. Tę samą liczbę wpisuje wprost `reference/G2-Edit/src/protocol.c`
    /// (`write_patch_descr`: „Length of following in bytes" = 15).
    public static let descriptionSectionBytes = 15

    /// Ciało sekcji `0x21` zbudowane z modelu — to samo, co idzie do pliku, tylko bez
    /// nagłówka `[typ][długość]`. Używa go wysyłka opisu patcha na żywo
    /// (`G2UsbProtocol.setPatchDescriptionPayload`).
    ///
    /// `original` to podkład, na który wartości wchodzą **w miejsce**: dzięki niemu
    /// 7 bajtów nieznanych danych, `unk2` i 12 bitów na końcu przeżywają wysyłkę.
    /// Bez niego podkładem jest 15 zer — tyle ma 3 619 z 3 625 sekcji kolekcji
    /// referencyjnej (99,83 %) → [[Docs/usb/protocol-map]].
    public static func descriptionSectionBody(_ description: G2PatchDescription,
                                              original: [UInt8]? = nil) throws -> [UInt8]
    {
        let base = original ?? [UInt8](repeating: 0, count: descriptionSectionBytes)
        guard let body = try rewriteDescriptionSection(original: base, description: description) else {
            throw PatchParserError.truncatedSection(SectionType.patchDescription.rawValue,
                                                    base.count, descriptionSectionBytes)
        }
        return body
    }

    private static func clamp(_ value: Int, _ maxValue: Int) -> Int {
        max(0, min(maxValue, value))
    }

    // MARK: - Section 0x11: PerformanceDescription (.prf2)

    /// Sekcja jest w całości bajtowa (żadne pole nie łamie bajtu), więc czytamy ją
    /// indeksem, nie BitStreamem — inaczej niż resztę pliku. Układ:
    ///
    ///   unk1(8) · unk2(4) focus(2) unk3(2) · rangeEnabled(8) · bpm(8)
    ///   split(8) · clockRun(8) · unk4(8) · unk5(8)
    ///   × 4 sloty: nazwa (0–16 znaków, `\0` gdy krótsza) + 10 bajtów pól
    ///
    /// Potwierdzone w dwóch źródłach (g2ools `PerformanceDescription`, BVerhue
    /// `TG2FilePerformance.Read`) i zmierzone na 1 022 plikach `.prf2` z kolekcji:
    /// każdy plik konsumuje sekcję co do bajtu, bpm mieści się w 30…240, a pola
    /// unk1/unk2/split/unk4/unk5 i dwa ostatnie bajty slotu są zawsze zerowe.
    private static let performanceHeaderBytes = 8
    private static let performanceSlotFieldBytes = 10
    private static let performanceSlotCount = 4

    /// Offsety pól w sekcji 0x11 — nazwy slotów mają zmienną długość, więc trzeba je
    /// przejść. `nil` = sekcja nie ma opisanego układu (za krótka, nieterminowana nazwa).
    private static func performanceSlotOffsets(_ data: [UInt8]) -> [(name: Range<Int>, fields: Int)]? {
        guard data.count >= performanceHeaderBytes else { return nil }
        var offset = performanceHeaderBytes
        var result: [(name: Range<Int>, fields: Int)] = []
        for _ in 0 ..< performanceSlotCount {
            let start = offset
            while offset < data.count, offset - start < 16, data[offset] != 0 {
                offset += 1
            }
            let nameRange = start ..< offset
            if offset - start < 16 {
                offset += 1 // bajt terminatora — nie ma go tylko przy pełnych 16 znakach
            }
            guard offset + performanceSlotFieldBytes <= data.count else { return nil }
            result.append((name: nameRange, fields: offset))
            offset += performanceSlotFieldBytes
        }
        return result
    }

    private static func parsePerformanceDescription(data: [UInt8]) -> G2PerformanceSettings? {
        guard let offsets = performanceSlotOffsets(data) else { return nil }
        var performance = G2PerformanceSettings()
        performance.focusedSlot = Int((data[1] >> 2) & 0x03)
        performance.globalPagesEnabled = data[1] & 0x03 != 0
        performance.keyboardRangeEnabled = data[2] != 0
        performance.masterClock = Int(data[3])
        performance.masterClockRunning = data[5] != 0
        for (index, offset) in offsets.enumerated() {
            var slot = G2PerformanceSlot()
            slot.name = String(bytes: data[offset.name], encoding: .isoLatin1) ?? ""
            let base = offset.fields
            slot.enabled = data[base] != 0
            slot.keyboard = data[base + 1] != 0
            slot.hold = data[base + 2] != 0
            slot.bank = Int(data[base + 3])
            slot.patch = Int(data[base + 4])
            slot.keyRangeLow = Int(data[base + 5])
            slot.keyRangeHigh = Int(data[base + 6])
            performance.slots[index] = slot
        }
        return performance
    }

    /// Składa sekcję 0x11 od nowa z ustawień performance'u. Pięć nieznanych pól
    /// nagłówka i po trzy nieznane bajty każdego slotu przepisujemy z oryginału;
    /// `nil` = układ sekcji inny niż opisany, więc zapis zostawia oryginał.
    ///
    /// Nazwy slotów są **zmiennej długości**, więc sekcja bywa po zapisie dłuższa
    /// albo krótsza niż była — `saveAll` wpisuje nowy nagłówek długości, więc to
    /// bezpieczne. Bez tego nie dałoby się przemianować patcha w performance,
    /// a instrukcja opisuje to jako zwykłą czynność (str. 97).
    private static func rewritePerformanceSection(original: [UInt8],
                                                  performance: G2PerformanceSettings) -> [UInt8]?
    {
        guard let offsets = performanceSlotOffsets(original) else { return nil }
        var bytes = Array(original[0 ..< performanceHeaderBytes])
        bytes[1] = (bytes[1] & ~0x0F)
            | UInt8(clamp(performance.focusedSlot, 3) << 2)
            | (performance.globalPagesEnabled ? 1 : 0)
        bytes[2] = performance.keyboardRangeEnabled ? 1 : 0
        bytes[3] = UInt8(clamp(performance.masterClock, 255))
        bytes[5] = performance.masterClockRunning ? 1 : 0

        for (index, offset) in offsets.enumerated() {
            let slot = index < performance.slots.count ? performance.slots[index] : G2PerformanceSlot()
            // ISO-Latin1 — tym samym kodowaniem sekcja jest czytana, więc nazwa
            // wraca bajt w bajt także wtedy, gdy ma znak spoza ASCII.
            let name = Array((slot.name.data(using: .isoLatin1) ?? Data())
                .prefix(G2PatchName.maxLength))
            bytes.append(contentsOf: name)
            // Terminatora nie ma tylko przy pełnych szesnastu znakach — tak samo
            // czyta tę sekcję `performanceSlotOffsets`.
            if name.count < G2PatchName.maxLength { bytes.append(0) }

            var fields = Array(original[offset.fields ..< offset.fields + performanceSlotFieldBytes])
            fields[0] = slot.enabled ? 1 : 0
            fields[1] = slot.keyboard ? 1 : 0
            fields[2] = slot.hold ? 1 : 0
            fields[3] = UInt8(clamp(slot.bank, 255))
            fields[4] = UInt8(clamp(slot.patch, 255))
            fields[5] = UInt8(clamp(slot.keyRangeLow, 127))
            fields[6] = UInt8(clamp(slot.keyRangeHigh, 127))
            bytes.append(contentsOf: fields)
        }

        // Ogon za czwartym slotem (jeśli sekcja go ma) idzie bez zmian.
        if let last = offsets.last {
            let tailStart = last.fields + performanceSlotFieldBytes
            if tailStart < original.count {
                bytes.append(contentsOf: original[tailStart...])
            }
        }
        return bytes
    }

    // MARK: - Section 0x5a: ModuleNames

    // Binary layout: area(2), nModules(8), per module: moduleIndex(8), name(17 bytes ASCII)

    private static func parseModuleNames(_ patch: inout G2Patch, data: [UInt8]) throws {
        var bs = BitStream(data: data)
        do {
            let areaRaw = try Int(bs.readBits(2))
            guard areaRaw == 1 || areaRaw == 0 else { return }
            let area = areaRaw == 1 ? PatchArea.voice : PatchArea.fx
            _ = try bs.readBits(6) // sześć bitów, których oryginał nie wypełnia — patrz zapis sekcji
            let nModules = try Int(bs.readBits(8))

            for _ in 0 ..< nModules {
                let moduleIndex = try Int(bs.readBits(8))
                let name = try bs.readNullTermString(maxChars: 16)

                if area == .voice {
                    if let idx = patch.voiceModules.firstIndex(where: { $0.id == moduleIndex }) {
                        patch.voiceModules[idx].label = name
                        patch.voiceModules[idx].hasNameEntry = true
                    }
                } else {
                    if let idx = patch.fxModules.firstIndex(where: { $0.id == moduleIndex }) {
                        patch.fxModules[idx].label = name
                        patch.fxModules[idx].hasNameEntry = true
                    }
                }
            }
        } catch let e as BitStreamError {
            throw PatchParserError.bitStreamError(e)
        }
    }

    // MARK: - Section 0x6f: TextPad (patch notes)

    // Binary layout (g2ools TextPad.parse): the whole section payload IS the text,
    // no length prefix or null terminator — the 2-byte section length already is it.

    /// Notatki są w pliku ośmiobitowe (G2 nie zna UTF-8). Latin-1 odwzorowuje bajty
    /// 0…255 na znaki U+0000…U+00FF jeden do jednego, więc odczyt i zapis oddają
    /// dowolną treść bajt w bajt; wcześniejszy odczyt Latin-1 z zapisem w UTF-8
    /// wydłużał sekcję o bajt na każdym znaku spoza ASCII.
    private static func parseTextPad(_ patch: inout G2Patch, data: [UInt8]) {
        patch.notes = String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    /// Bajty notatek do zapisu. Znaki spoza Latin-1 (użytkownik może je wkleić)
    /// nie mają ośmiobitowego odpowiednika — wtedy zapisujemy UTF-8.
    static func textPadBytes(_ notes: String) -> [UInt8] {
        if let latin1 = notes.data(using: .isoLatin1) { return [UInt8](latin1) }
        return Array(notes.utf8)
    }
}
