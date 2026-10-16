// G2VisualLayout.swift
// Gdzie w strumieniu `0x3A`/`0x39` leży który moduł — policzone RAZ na patch.
//
// Komunikaty wizualne nie niosą żadnej adresacji (patrz `G2VisualStream`), więc przypisanie
// wartości do modułów wynika wyłącznie z zawartości slotu. Do 2026-09-06 liczyliśmy je
// **od nowa przy każdym pakiecie**: `modulesInStreamOrder` sortowało oba obszary, a dla
// każdego modułu szła jeszcze kwerenda do `MiniVUDatabase` i `ModuleUIDatabase`. Przy
// ~40 pakietach na sekundę i dwóch strumieniach dawało to kilkadziesiąt tysięcy zapytań
// do tabel na minutę — za każdym razem po ten sam, niezmienny wynik.
//
// Oryginał tego nie robi: `CLedDataList::PopulateList` buduje listę widżetów raz, przy
// otwarciu patcha, a strumień jest już tylko ciągiem wartości pod gotowe indeksy. Tak samo
// tutaj — plan powstaje przy zmianie STRUKTURY patcha, a dekodowanie pakietu to przebieg
// po trzech płaskich tablicach.

import Foundation

/// Rozkład wpisów strumienia wizualnego dla jednej zawartości slotu.
public struct G2VisualLayout: Sendable, Equatable {
    /// Wskaźniki VU jednego modułu: `count` kolejnych wpisów od `firstEntry`.
    public struct MeterEntry: Sendable, Equatable {
        public let area: PatchArea
        public let moduleID: Int
        public let firstEntry: Int
        public let count: Int
    }

    /// Grupa diod jednego modułu — zawsze jeden wpis (patrz `G2LedGroupReading`).
    public struct GroupEntry: Sendable, Equatable {
        public let area: PatchArea
        public let moduleID: Int
        public let entry: Int
    }

    /// Pojedyncza dioda ze strumienia `0x39` — `index` liczony od początku tablicy diod.
    public struct LedEntry: Sendable, Equatable {
        public let area: PatchArea
        public let moduleID: Int
        public let codeRef: Int
        public let index: Int
    }

    public let meters: [MeterEntry]
    public let groups: [GroupEntry]
    public let leds: [LedEntry]
    /// Odcisk struktury, dla której plan policzono. Zmiana modułu (dodanie, skasowanie,
    /// podmiana typu) zmienia go, a przesunięcie albo zmiana nazwy — nie, bo kolejność
    /// w strumieniu ich nie dotyczy.
    public let signature: Int

    public init(patch: G2Patch) {
        var meters: [MeterEntry] = []
        var groups: [GroupEntry] = []
        var leds: [LedEntry] = []
        var entry = 0
        var ledIndex = 0
        for module in G2VisualStream.modulesInStreamOrder(patch) {
            let meterCount = MiniVUDatabase.defs(forModuleID: module.typeID).count
            if meterCount > 0 {
                meters.append(MeterEntry(area: module.area, moduleID: module.id,
                                         firstEntry: entry, count: meterCount))
                entry += meterCount
            }
            if G2VisualStream.ledGroupModuleTypes.contains(module.typeID) {
                groups.append(GroupEntry(area: module.area, moduleID: module.id, entry: entry))
                entry += 1
            }
            for led in G2VisualStream.singleLeds(typeID: module.typeID) {
                leds.append(LedEntry(area: module.area, moduleID: module.id,
                                     codeRef: led.codeRef, index: ledIndex))
                ledIndex += 1
            }
        }
        self.meters = meters
        self.groups = groups
        self.leds = leds
        signature = Self.signature(of: patch)
    }

    /// Ile wpisów zajęłaby pełna zawartość patcha — diagnostyka (`USBProbe --listen`),
    /// pozwala zobaczyć, ile modułów wypada poza pojemność komunikatu.
    public var entryCount: Int {
        meters.reduce(0) { $0 + $1.count } + groups.count
    }

    /// Tani odcisk struktury: kolejność i typy modułów, czyli dokładnie to, od czego
    /// zależy rozkład wpisów. Liczony bez alokacji, więc wolno go sprawdzać przy
    /// każdym pakiecie i przebudować plan dopiero wtedy, gdy naprawdę się zmienił.
    public static func signature(of patch: G2Patch) -> Int {
        var hasher = Hasher()
        for area in [PatchArea.voice, .fx] {
            hasher.combine(area)
            for module in patch.modules(in: area) {
                hasher.combine(module.id)
                hasher.combine(module.typeID)
            }
        }
        return hasher.finalize()
    }
}
