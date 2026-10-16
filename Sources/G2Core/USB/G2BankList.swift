// G2BankList.swift
// Zawartość banków w pamięci Norda: co jest pod którym numerem.
//
// Do 2026-09-06 uważaliśmy to za nierozłożoną część protokołu („podsystem flash").
// Rozkłada ją BVerhue Gen3 (`TG2Synth.AddMsgListMessage` + `ProcessMsgListAddNames`),
// który czyta całą zawartość banków jako **krok inicjalizacji** połączenia.
//
// Rozmowa jest kursorowa, nie jednorazowa: pytamy „podaj od (typ, bank, patch)",
// urządzenie odsyła tyle nazw, ile mu się mieści w ramce, i mówi bajtem sterującym,
// od czego pytać dalej. Koniec, gdy typ pliku dojdzie do 2.
//
// **Zmierzone na sprzęcie 2026-09-07**: 723 pozycje z 13 banków patchy i 4 banków
// performance'ów, numeracja zgodna z frontem. Odczyt jest nieniszczący, ale pętla ma
// twardy limit obiegów, żeby błąd w odczycie bajtu sterującego nie zapętlił edytora
// → [[Docs/usb/protocol-map]].

import Foundation

/// Co siedzi w jednym miejscu banku.
public struct G2BankEntry: Sendable, Equatable, Identifiable {
    /// Banki patchy i banki performance'ów są numerowane osobno.
    public enum Kind: UInt8, Sendable {
        case patch = 0
        case performance = 1
    }

    public let kind: Kind
    /// Numer banku liczony od 0; front Norda pokazuje go jako 1…8.
    public let bank: Int
    /// Miejsce w banku, od 0; front pokazuje 1…32.
    public let patch: Int
    public let name: String
    /// Kategoria z listy Clavii (Bass, Lead, …) — 0 znaczy „brak".
    public let category: Int

    public var id: String {
        "\(kind.rawValue)-\(bank)-\(patch)"
    }

    /// Numeracja widoczna na froncie urządzenia.
    public var displayLocation: String {
        "\(bank + 1):\(patch + 1)"
    }

    public init(kind: Kind, bank: Int, patch: Int, name: String, category: Int) {
        self.kind = kind
        self.bank = bank
        self.patch = patch
        self.name = name
        self.category = category
    }
}

/// Kolejność pozycji WEWNĄTRZ banku w panelu Banks. Banki zawsze stoją po kolei
/// (najpierw patche, potem performance'y), jak na froncie urządzenia.
public enum G2BankSort: String, CaseIterable, Sendable {
    case location
    case name
    case category

    public var title: String {
        switch self {
        case .location: "Location"
        case .name: "Name"
        case .category: "Category"
        }
    }
}

/// Jeden bank w panelu Banks: nagłówek i jego pozycje po filtrach i sortowaniu.
public struct G2BankGroup: Sendable, Equatable, Identifiable {
    public let kind: G2BankEntry.Kind
    public let bank: Int
    public let entries: [G2BankEntry]

    public var id: String {
        "\(kind.rawValue)-\(bank)"
    }

    public var title: String {
        "\(kind == .patch ? "Patch" : "Performance") Bank \(bank + 1)"
    }

    /// Lista z urządzenia pocięta na banki. Bank bez pozycji po filtrach znika —
    /// pusty nagłówek przy szukaniu wyglądałby na trafienie.
    ///
    /// `category` zostawia tylko patche tej kategorii: performance'y kategorii nie mają
    /// (urządzenie podaje 0), więc przy włączonym filtrze ich banki znikają. Kategoria
    /// sortuje w kolejności listy Clavii (tej z frontu), remisy rozstrzyga miejsce.
    public static func grouped(
        _ entries: [G2BankEntry], query: String = "", category: Int? = nil,
        sort: G2BankSort = .location, reversed: Bool = false
    ) -> [G2BankGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let visible = entries.filter { entry in
            (trimmed.isEmpty || entry.name.localizedCaseInsensitiveContains(trimmed))
                && (category.map { entry.kind == .patch && entry.category == $0 } ?? true)
        }
        let banks = Dictionary(grouping: visible) { BankKey(kind: $0.kind.rawValue, bank: $0.bank) }
        return banks.keys.sorted { ($0.kind, $0.bank) < ($1.kind, $1.bank) }.map { key in
            let ordered = (banks[key] ?? []).sorted { lhs, rhs in
                switch sort {
                case .location:
                    return lhs.patch < rhs.patch
                case .name:
                    let order = lhs.name.localizedStandardCompare(rhs.name)
                    return order == .orderedSame ? lhs.patch < rhs.patch : order == .orderedAscending
                case .category:
                    return (lhs.category, lhs.patch) < (rhs.category, rhs.patch)
                }
            }
            return G2BankGroup(kind: G2BankEntry.Kind(rawValue: key.kind) ?? .patch, bank: key.bank,
                               entries: reversed ? ordered.reversed() : ordered)
        }
    }

    private struct BankKey: Hashable {
        let kind: UInt8
        let bank: Int
    }
}

/// Bank z Norda na dysk w układzie Clavii — „Synth ▸ Bank Upload (From Modular)”
/// (instrukcja v1.4 s. 123): każda pozycja osobnym plikiem plus lista `.pchList`
/// z miejscami w banku, żeby dało się je wgrać z powrotem na te same miejsca.
/// Ten sam układ ma bank fabryczny v1.24 (`PatchBank2/PatchBank2.pchList`) i ten sam
/// czyta `USBProbe --storebanks` → [[Docs/usb/bank-dump]].
public enum G2BankDump {
    /// Pierwsza linia listy, bajt w bajt jak u Clavii.
    public static let listHeader = "Version=Nord Modular G2 Bank Dump"

    /// Domyślna nazwa oryginału — zarazem folder banku i nazwa pliku listy.
    public static func bankName(kind: G2BankEntry.Kind, bank: Int) -> String {
        (kind == .patch ? "PatchBank" : "PerfBank") + "\(bank + 1)"
    }

    public static func fileExtension(_ kind: G2BankEntry.Kind) -> String {
        kind == .patch ? "pch2" : "prf2"
    }

    /// Nazwy plików dla pozycji jednego banku, w kolejności `entries`. Nazwa pliku to
    /// nazwa patcha — przy wgrywaniu z listy z niej bierze się nazwa w banku. Powtórki
    /// dostają przyrostek liczbowy, jak u Clavii; porównanie bez wielkości liter, bo
    /// dysk Maca ich nie rozróżnia.
    public static func fileNames(for entries: [G2BankEntry]) -> [String] {
        var used: Set<String> = []
        return entries.map { entry in
            var base = entry.name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            if base.hasPrefix(".") { base = "_" + base.dropFirst() }
            if base.isEmpty { base = "No name" }
            let ext = fileExtension(entry.kind)
            var name = "\(base).\(ext)"
            var counter = 2
            while used.contains(name.lowercased()) {
                name = "\(base) \(counter).\(ext)"
                counter += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }

    /// Treść `.pchList`: nagłówek i linie `bank:miejsce: plik` liczone od 1, końce linii
    /// CRLF — tak wygląda każda lista banku fabrycznego.
    public static func listFile(entries: [G2BankEntry], fileNames: [String]) -> Data {
        var lines = [listHeader]
        for (entry, file) in zip(entries, fileNames) {
            lines.append("\(entry.bank + 1):\(entry.patch + 1): \(file)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

/// Skąd urządzenie ma podać dalszy ciąg listy.
public struct G2BankCursor: Sendable, Equatable {
    public let kind: UInt8
    public let bank: Int
    public let patch: Int

    /// Typ pliku 2 znaczy „przejrzane wszystko" (`pftEnd` u BVerhue).
    public var isFinished: Bool {
        kind > G2BankEntry.Kind.performance.rawValue
    }

    public init(kind: UInt8, bank: Int, patch: Int) {
        self.kind = kind
        self.bank = bank
        self.patch = patch
    }

    public static let start = G2BankCursor(kind: 0, bank: 0, patch: 0)
}

public extension G2UsbProtocol {
    /// Jeden odczyt listy: nazwy z tej ramki i miejsce, od którego pytać dalej.
    struct BankListPage: Sendable, Equatable {
        public let entries: [G2BankEntry]
        public let next: G2BankCursor
    }

    /// SUB_COMMAND (0x14, `Q_LIST_NAMES`) — **podaj zawartość banków od tego miejsca**.
    /// Komunikat systemowy, jak `PlayNote` (BVerhue buduje go przez `Synth.InitMsg`).
    ///
    /// Układ `[0x14][typ pliku][bank][patch]` z BVerhue `TG2Synth.AddMsgListMessage`;
    /// numer zgadza się z Flash Data Request (0x14, typ 2 = zapytanie) w rejestrze
    /// komunikatów Clavii. **Zmierzone na sprzęcie 2026-09-07.**
    static func listBankNamesPayload(cursor: G2BankCursor) -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subListBankNames,
         cursor.kind, UInt8(cursor.bank), UInt8(cursor.patch)]
    }

    /// SUB_COMMAND (0x0A, Flash Load Command / `S_RETREIVE`) — **załaduj patch z banku
    /// do slotu**. `slot` 0–3 to sloty, **4 znaczy performance**.
    ///
    /// Układ potwierdzony dwoma źródłami: Flash Load Command(slot, Flash Entry)
    /// w oryginalnym edytorze Clavii i BVerhue `TG2Synth.AddMsgRetrieveMessage`
    /// (`S_RETREIVE = $0A`, `slot, bank, patch`). **Zweryfikowane na żywym Nordzie**
    /// 2026-09-18 i powtórnie 2026-10-13 (`USBProbe --banktest-slot D`).
    static func loadFromBankPayload(slot: UInt8, bank: Int, patch: Int) -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subLoadFromBank, slot, UInt8(bank), UInt8(patch)]
    }

    /// SUB_COMMAND (0x0B, Flash Store Command / `S_STORE`) — **zapisz zawartość slotu
    /// do banku** pod to miejsce. `slot` 0–3 to sloty, **4 znaczy performance**.
    ///
    /// Układ z oryginalnego edytora Clavii (Flash Store Command: slot + Flash Entry)
    /// i BVerhue `TG2Synth.AddMsgStoreMessage`. Sprawdzone WYŁĄCZNIE na wirtualnym G2
    /// (2026-09-26) — do prawdziwego Norda zapis do banków jest wyłączony
    /// (`G2MidiManager.storeToBank`) → [[Docs/usb/bank-dump]].
    static func storeToBankPayload(slot: UInt8, bank: Int, patch: Int) -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subStoreToBank, slot, UInt8(bank), UInt8(patch)]
    }

    /// Kod wyniku z `R_STORE` (0x0D): `[flaga][bank][miejsce][typ][wynik]`, układ
    /// z Flash Command Result (ReadStream) oryginału. Urządzenie wkleja go na koniec
    /// ramki `0x13` z nowym wpisem listy nazw, więc szukamy go od końca.
    ///
    /// Znaczenie wyniku wg oryginału (Flash Data (HandleFlashCommandResult)):
    /// 0, 2, 5 — w porządku; 1 „Can't load from flash"; 3 „Flash memory full";
    /// 4 „Memory protect on".
    static func storeResult(payload: [UInt8], subCommand: UInt8) -> UInt8? {
        let bytes = subCommand == subResponseStore ? [subResponseStore] + payload : payload
        guard bytes.count >= 6, bytes[bytes.count - 6] == subResponseStore else { return nil }
        return bytes[bytes.count - 1]
    }

    static func storeSucceeded(_ result: UInt8) -> Bool {
        [0, 2, 5].contains(result)
    }

    /// Wyłuskuje treść `R_ADD_NAMES` z payloadu odpowiedzi.
    ///
    /// Urządzenie potrafi wcisnąć w jedną ramkę dwa komunikaty: `0x13` z dwoma bajtami,
    /// których znaczenia BVerhue też nie zna, a zaraz za nimi właściwe `0x16`. Nasz
    /// dekoder ramki rozpoznaje tylko pierwszy, więc drugi trzeba znaleźć samemu —
    /// dokładnie tak, jak robi to pętla `repeat aMsg.Read(SubCmd, 1)`.
    ///
    /// Pomiar 2026-09-07: G2 (firmware 1.62) odpowiada **wyłącznie** w tej postaci —
    /// każda z 60 ramek zaczynała się `13 04 16 …`. Samo `0x16` nie przyszło ani razu,
    /// więc ta gałąź nie jest wariantem awaryjnym, tylko drogą normalną.
    static func bankNamesBody(payload: [UInt8], subCommand: UInt8) -> [UInt8]? {
        if subCommand == subResponseBankNames { return payload }
        guard subCommand == subResponseBankListInfo,
              payload.count > 3, payload[2] == subResponseBankNames else { return nil }
        return Array(payload.dropFirst(3))
    }

    /// Rozkłada treść `R_ADD_NAMES` (0x16) na nazwy i kursor następnego pytania.
    ///
    /// Układ, wprost z `TG2Synth.ProcessMsgListAddNames`: dwa bajty nagłówka
    /// (`0` po zapisie / `1` po liście; potem typ pliku), a dalej strumień, w którym
    /// bajty **0x01–0x05 są sterujące**, `0x00` kończy nazwę, a wszystko inne jest
    /// jej znakiem. Po każdej nazwie idzie bajt kategorii, a numer miejsca rośnie o jeden.
    ///
    /// | bajt | znaczenie |
    /// |---|---|
    /// | `0x01` + `[patch]` | przestaw kursor na to miejsce |
    /// | `0x02` | koniec ramki (znaczenie nieznane też BVerhue) |
    /// | `0x03` + `[bank][patch]` | przestaw kursor na ten bank i miejsce |
    /// | `0x04` | koniec tego typu plików — dalej performance'y, a po nich koniec |
    /// | `0x05` | koniec ramki, pytaj dalej od bieżącego kursora |
    ///
    /// Nazwa ma najwyżej 16 znaków; po szesnastym bajt kategorii idzie bez zera.
    static func decodeBankNames(_ body: [UInt8]) -> BankListPage? {
        guard body.count >= 2 else { return nil }
        var kind = body[1]
        var bank = 0
        var patch = 0
        var entries: [G2BankEntry] = []
        var name: [UInt8] = []
        var index = 2

        /// Nazwa domknięta: czyta bajt kategorii i przesuwa się na następne miejsce.
        func finishName() {
            let category = index < body.count ? Int(body[index]) : 0
            index += 1
            if let kindValue = G2BankEntry.Kind(rawValue: kind), !name.isEmpty {
                entries.append(G2BankEntry(
                    kind: kindValue, bank: bank, patch: patch,
                    name: String(decoding: name, as: UTF8.self), category: category
                ))
            }
            name = []
            patch += 1
        }

        while index < body.count {
            let byte = body[index]
            index += 1
            switch byte {
            case 0x01:
                guard index < body.count else { break }
                patch = Int(body[index])
                index += 1
            case 0x02, 0x05:
                return BankListPage(entries: entries,
                                    next: G2BankCursor(kind: kind, bank: bank, patch: patch))
            case 0x03:
                guard index + 1 < body.count else { break }
                bank = Int(body[index])
                patch = Int(body[index + 1])
                index += 2
            case 0x04:
                kind += 1
                return BankListPage(entries: entries,
                                    next: G2BankCursor(kind: kind, bank: 0, patch: 0))
            case 0x00:
                finishName()
            default:
                name.append(byte)
                if name.count == 16 { finishName() }
            }
        }
        return BankListPage(entries: entries,
                            next: G2BankCursor(kind: kind, bank: bank, patch: patch))
    }
}
