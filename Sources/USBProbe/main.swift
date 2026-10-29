// USBProbe — ręczne narzędzie diagnostyczne do testowania G2MidiManager na żywym sprzęcie.
// Nie jest częścią `swift test` (wymaga podłączonego G2).
//
//   swift run USBProbe                          # handshake + spis zawartości slotów
//   swift run USBProbe --json                   # to samo, ale jako jeden obiekt JSON
//   swift run USBProbe --fast-connect           # handshake bez czytania slotów (slot A to 18 kB)
//   swift run USBProbe --send "01 0c 00 09 03"  # dowolna komenda bez przebudowy kodu
//   swift run USBProbe --probe-write            # bateria nieniszczących komend
//   swift run USBProbe --loadfile x.pch2 --slot D  # wgranie pliku JEDNĄ komendą (0x37)
//   swift run USBProbe --loadperf x.prf2          # CAŁY performance (4 sloty) jedną komendą (0x1A)
//   swift run USBProbe --verifyfile x.prf2      # czy w slotach Norda leży to, co w pliku
//   swift run USBProbe --stress 15 x.prf2 katalog/  # pętla: performance, wariacje, .pch2, kable (#146)
//   swift run USBProbe --sendtest-slot D        # roundtrip zapisu slotu (molekuła po molekule)
//   swift run USBProbe --structtest-slot D      # zmiany strukturalne na żywo: skasuj moduł i dołóż go z powrotem
//   swift run USBProbe --metatest-slot D        # nazwa/kolor/pozycja modułu + kolor kabla (0x33/0x31/0x34/0x50)
//   swift run USBProbe --miditest-slot D        # przypisanie i skasowanie kontrolera MIDI (0x22/0x23)
//   swift run USBProbe --descriptiontest-slot D # opis patcha: Voices/Poly-Mono/kategoria (0x21)
//   swift run USBProbe --variationtest-slot D   # wariacje i morfy (0x6A/0x44/0x43)
//   swift run USBProbe --play-slot D            # ten slot ma grać i być edytowany (przed --listen)
//   swift run USBProbe --paramtest-slot D       # czy ParamDump zmienia stan urządzenia
//   swift run USBProbe --deletetest-slot D      # DeleteModule/DeleteCable krok po kroku
//   swift run USBProbe --livetest-slot D        # SetParam bez ACK — skutek real-time
//   swift run USBProbe --listen 20              # podsłuch: co Nord nadaje SAM (gałka, slot, VU)
//   swift run USBProbe --slottest               # czy SelectSlot przestawia front Norda
//   swift run USBProbe --setperfname "Empty perf"  # nazwa performance'u DO urządzenia (0x29)
//   swift run USBProbe --perfheadertest         # zapis sekcji 0x11 (Hold/zakres klawiszy), z przywróceniem
//   swift run USBProbe --perfheaderrules        # czy SAMA sekcja 0x11 ustawia sloty i zegar (bez 0x07/0x0F/0x3F)
//   swift run USBProbe --uploadrules x.pch2 --slot D  # czy samo 0x37 zapala slot + zapytania Clavii po wgraniu
//   swift run USBProbe --synthsettings          # ustawienia urządzenia (0x02 → 0x03): odczyt i rozpis pól
//   swift run USBProbe --synthsettings-echo     # odsyła TEN SAM blok (0x03) i sprawdza odczytem — nic nie zmienia
//   swift run USBProbe --synthsettings-write    # ZMIENIA dwa nieszkodliwe pola, sprawdza odczytem i przywraca
//
// `--json` i `--fast-connect` działają dla spisu slotów i `--send`; tryby testowe
// (--sendtest/--paramtest/--deletetest/--livetest/--probe-write) zawsze piszą pełny log tekstowy.
//
// Kod wyjścia: 0 = zrobione, 1 = błąd (brak połączenia, nieczytelny plik…), 2 = `--loadfile`/
// `--loadperf` wysłał, ale odczyt slotów nie zgadza się z plikiem. Na nim polegają skrypty
// wywołujące (ponowienie próby) — do 2026-09-24 błąd kończył się zerem.

import Foundation
import G2Core

/// Mierzy czas między kolejnymi krokami `sendPatch` — diagnostyka timingu na żywym sprzęcie.
final class StepClock: @unchecked Sendable {
    private var last = Date()
    private let lock = NSLock()

    func elapsedSinceLastAndReset() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let elapsed = now.timeIntervalSince(last)
        last = now
        return elapsed
    }
}

/// Zbiera powiadomienia urządzenia w trybie `--listen`. `@unchecked Sendable` + zamek,
/// bo handler wywoływany jest z aktora USB, a raport składamy po jego stronie.
final class NotificationLog: @unchecked Sendable {
    struct Entry {
        let time: Date
        let note: G2Notification
    }

    private var entries: [Entry] = []
    private let lock = NSLock()

    func append(_ note: G2Notification) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(time: Date(), note: note))
    }

    func all() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// Liczy usterki strumienia w trybie `--soak`. `@unchecked Sendable` + zamek z tego
/// samego powodu co `NotificationLog`: log woła aktor USB, a raport składamy po naszej stronie.
final class SoakTally: @unchecked Sendable {
    private var linesSeen = 0
    private var derailmentsSeen = 0
    private var missingAcksSeen = 0
    private let lock = NSLock()

    func note(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        linesSeen += 1
        if line.contains("stream mismatch") { derailmentsSeen += 1 }
        if line.contains("no acknowledgement") { missingAcksSeen += 1 }
    }

    var snapshot: (lines: Int, derailments: Int, missingAcks: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (linesSeen, derailmentsSeen, missingAcksSeen)
    }
}

/// Strumienie ciągłe (VU, LED, obciążenie DSP, zegar) — w raporcie `--listen` liczone,
/// ale nie wypisywane linia po linii, bo lecą dziesiątki razy na sekundę.
let streamSubCommands: Set<UInt8> = [0x39, 0x3A, 0x3F, 0x72, 0x69]

func subCommandName(_ sub: UInt8) -> String {
    switch sub {
    case 0x05: "ASSIGNED_VOICES"
    case 0x09: "SELECT_SLOT"
    case 0x1E: "GLOBAL_PAGE"
    case 0x2F: "SELECT_PARAM"
    case 0x36: "PATCH_VERSION"
    case 0x38: "PATCH_VERSION_CHANGE"
    case 0x39: "LED_DATA"
    case 0x3A: "VOLUME_INDICATOR"
    case 0x3F: "MASTER_CLOCK"
    case 0x40: "PARAM_CHANGE"
    case 0x62: "KNOBS"
    case 0x69: "CURRENT_NOTE"
    case 0x6A: "SELECT_VARIATION"
    case 0x72: "RESOURCES_USED"
    case 0x7E: "ERROR"
    case 0x7F: "OK"
    case 0x80: "MIDI_CC"
    default: ""
    }
}

/// Sekcje wychodzące rozbite na nazwane kawałki — ta sama kolejność i treść co
/// `sectionBytes`, tylko z etykietami, żeby przy niezgodności roundtripu było widać
/// KTÓRA sekcja się rozjechała (moduły / kable / parametry / nazwy), a nie tylko że
/// suma bajtów się różni.
func namedSections(of patch: G2Patch) throws -> [(String, [UInt8])] {
    var sections: [(String, [UInt8])] = []
    for area in PatchArea.allCases {
        try sections.append(("\(area) moduły", PatchParser.writeModuleList(modules: patch.modules(in: area), area: area)))
        try sections.append(("\(area) kable", PatchParser.writeCableList(cables: patch.cables(in: area), area: area)))
        try sections.append(("\(area) parametry", PatchParser.writeParamList(modules: patch.modules(in: area), area: area)))
        try sections.append(("\(area) nazwy", PatchParser.writeModuleNames(modules: patch.modules(in: area), area: area)))
    }
    return sections
}

func sectionBytes(of patch: G2Patch) throws -> [UInt8] {
    try namedSections(of: patch).flatMap(\.1)
}

/// Kolejność wpisów w sekcjach 0x4a i 0x52 **nie niesie znaczenia** — każdy wpis opisuje
/// się sam (id modułu, oba końce kabla). Urządzenie oddaje moduły posortowane po id,
/// a plik zapisuje je w kolejności dodawania: `arpa.pch2` ma w obszarze FX `2,3,4,5,6,7,1`.
/// Bez sprowadzenia obu stron do wspólnego porządku porównanie bajt w bajt krzyczy
/// „rozjazd" przy identycznej treści (zmierzone na sprzęcie 2026-09-05).
/// „A"…„D" — numer slotu tak, jak jest opisany na froncie Norda.
func slotLabel(_ index: Int) -> String {
    ["A", "B", "C", "D"][min(max(index, 0), 3)]
}

func normalized(_ patch: G2Patch) -> G2Patch {
    func cableKey(_ cable: G2Cable) -> [Int] {
        [cable.fromModule, cable.fromConnector, cable.toModule, cable.toConnector,
         cable.sourceIsOutput ? 1 : 0, Int(cable.color.rawValue)]
    }
    var copy = patch
    copy.fxModules.sort { $0.id < $1.id }
    copy.voiceModules.sort { $0.id < $1.id }
    copy.fxCables.sort { cableKey($0).lexicographicallyPrecedes(cableKey($1)) }
    copy.voiceCables.sort { cableKey($0).lexicographicallyPrecedes(cableKey($1)) }
    return copy
}

/// Wypisuje, które sekcje różnią się przed/po zapisie i na którym bajcie zaczyna się różnica.
func printSectionDiff(_ before: G2Patch, _ after: G2Patch) throws {
    let lhs = try namedSections(of: before)
    let rhs = try namedSections(of: after)
    for (left, right) in zip(lhs, rhs) {
        if left.1 == right.1 {
            print("    ✅ \(left.0): identyczne (\(left.1.count)B)")
        } else {
            let firstDiff = left.1.indices.first { $0 >= right.1.count || left.1[$0] != right.1[$0] }
            print("    ❌ \(left.0): \(left.1.count)B → \(right.1.count)B, pierwsza różnica na bajcie \(firstDiff.map(String.init) ?? "—")")
        }
    }
}

/// Porównuje moduły pole po polu — pokazuje dokładnie, co urządzenie przyjęło inaczej
/// niż wysłaliśmy (pozycja, kolor, etykieta, parametry w każdej z 9 wariacji).
func printModuleDiff(_ before: G2Patch, _ after: G2Patch) {
    for area in PatchArea.allCases {
        let old = before.modules(in: area)
        let new = after.modules(in: area)
        for module in old {
            guard let match = new.first(where: { $0.id == module.id }) else {
                print("    [\(area)] id \(module.id) \"\(module.label)\" — ZNIKNĄŁ po zapisie")
                continue
            }
            var differences: [String] = []
            if module.typeID != match.typeID { differences.append("typeID \(module.typeID)→\(match.typeID)") }
            if module.column != match.column { differences.append("column \(module.column)→\(match.column)") }
            if module.row != match.row { differences.append("row \(module.row)→\(match.row)") }
            if module.color != match.color { differences.append("color \(module.color)→\(match.color)") }
            if module.uprate != match.uprate { differences.append("uprate \(module.uprate)→\(match.uprate)") }
            if module.leds != match.leds { differences.append("leds \(module.leds)→\(match.leds)") }
            if module.label != match.label { differences.append("label \"\(module.label)\"→\"\(match.label)\"") }
            if module.hasNameEntry != match.hasNameEntry {
                differences.append("wpis w sekcji nazw \(module.hasNameEntry)→\(match.hasNameEntry)")
            }
            if module.modes != match.modes { differences.append("modes \(module.modes)→\(match.modes)") }
            for variation in 0 ..< min(module.parameterVariations.count, match.parameterVariations.count)
                where module.parameterVariations[variation] != match.parameterVariations[variation]
            {
                differences.append("war.\(variation) \(module.parameterVariations[variation])→\(match.parameterVariations[variation])")
            }
            if !differences.isEmpty {
                print("    [\(area)] id \(module.id) typeID \(module.typeID) \"\(module.label)\":")
                for difference in differences {
                    print("        \(difference)")
                }
            }
        }
        for module in new where !old.contains(where: { $0.id == module.id }) {
            print("    [\(area)] id \(module.id) \"\(module.label)\" — DOSZEDŁ po zapisie")
        }
    }
}

/// Nadaje wszystkim parametrom znany, celowo inny wzór — materiał do sprawdzenia,
/// czy `ParamDump` (0x4D) faktycznie zmienia stan urządzenia, czy tylko dostaje 0x7F.
/// Wartości tylko 0/1: każdy parametr G2 liczy się od zera, więc taki wzór mieści się
/// w zakresie każdego z nich i urządzenie nie ma czego obcinać. Okres 3 i przesunięcie
/// wariacją sprawiają, że pomyłka o jedno pole albo zamiana wariacji od razu rzuca się w oczy.
func withKnownParameterPattern(_ patch: G2Patch) -> G2Patch {
    func mutate(_ modules: [G2Module]) -> [G2Module] {
        modules.map { module in
            var copy = module
            copy.parameterVariations = module.parameterVariations.enumerated().map { variation, values in
                values.indices.map { index in (index + variation) % 3 == 0 ? 1 : 0 }
            }
            copy.parameters = copy.parameterVariations.first ?? copy.parameters
            return copy
        }
    }
    var copy = patch
    copy.voiceModules = mutate(patch.voiceModules)
    copy.fxModules = mutate(patch.fxModules)
    return copy
}

/// Usuwa powtórzone kable — potrzebne, gdy slot na urządzeniu zebrał duplikaty
/// z wcześniejszych diagnostycznych zapisów (`--sendtest-slot D --dedupe`).
func deduplicatingCables(_ patch: G2Patch) -> G2Patch {
    func unique(_ cables: [G2Cable]) -> [G2Cable] {
        var seen = Set<String>()
        return cables.filter { seen.insert("\($0.fromModule):\($0.fromConnector)>\($0.toModule):\($0.toConnector)").inserted }
    }
    var copy = patch
    copy.voiceCables = unique(patch.voiceCables)
    copy.fxCables = unique(patch.fxCables)
    return copy
}

/// Wypisuje wszystkie kable patcha z kierunkiem połączenia — `linkType` jest tym
/// polem, przez które kable wejście-wejście nie dawały się skasować (do 2026-09-03).
func printCables(_ label: String, _ patch: G2Patch) {
    let cables = patch.fxCables + patch.voiceCables
    print("  kable \(label) (\(cables.count)):")
    for cable in cables {
        let kind = cable.sourceIsOutput ? "wy→we" : "WE→WE"
        print("    [\(cable.area)] \(cable.fromModule):\(cable.fromConnector) → \(cable.toModule):\(cable.toConnector)  \(kind)  \(cable.color)")
    }
}

// MARK: - Bajty z linii poleceń i raport JSON

/// Czyta bajty z argumentu `--send`: „62 01 0c", „62010c", „0x62,0x01" — wszystko jedno.
func parseHexBytes(_ text: String) -> [UInt8]? {
    let cleaned = text.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        .split(whereSeparator: { " ,:-_".contains($0) })
        .joined()
    guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index ..< next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return bytes
}

func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

/// Rozpis ustawień urządzenia — obok każdej wartości surowe bajty, żeby dało się
/// porównać z tym, co pokazuje okno oryginalnego edytora na tym samym Nordzie.
func printSynthSettings(_ settings: G2SynthSettings, raw: [UInt8]) {
    let start = G2UsbProtocol.synthSettingsBodyStart(raw)
    print("\n--- Ustawienia urządzenia (0x03, \(raw.count) B) ---")
    print("nazwa:            \(settings.name)")
    print("tryb:             \(settings.performanceMode ? "Performance" : "Patch")")
    for (index, slot) in settings.slots.enumerated() {
        let letter = ["A", "B", "C", "D"][index]
        print("kanał slotu \(letter):    \(slot.channel)\(slot.active ? "" : "  (nieaktywny)")")
    }
    print("kanał globalny:   \(settings.globalChannel.map(String.init) ?? "Off")")
    print("SysEx ID:         \(settings.sysExID.map(String.init) ?? "All")")
    print("Local On:         \(settings.localOn)")
    print("Program Change:   Receive \(settings.programChangeReceive), Send \(settings.programChangeSend)")
    print("Controllers:      Receive \(settings.controllersReceive), Send \(settings.controllersSend)")
    print("zegar:            Send \(settings.sendClock), Ignore External \(settings.ignoreExternalClock)")
    print(String(format: "strojenie:        %.2f Hz (semi %d, cent %d)",
                 settings.masterTuneHz, settings.tuneSemi, settings.tuneCent))
    print("oktawa globalna:  \(settings.globalOctaveShiftEnabled ? "wł." : "wył.") \(settings.globalOctaveShift)")
    print("pedał:            \(settings.pedalPolarityClosed ? "Closed" : "Open"), gain \(settings.controlPedalGainLabel)")
    print("Memory Protect:   \(settings.memoryProtect)")
    print("nazwa zajmuje \(start) B, pola: \(hexString(Array(raw.dropFirst(start))))")
    print("\nPorównaj TO z oknem Synth Settings w oryginalnym edytorze na tym samym Nordzie —")
    print("każda rozbieżność wskazuje bajt, który czytamy nie tam, gdzie trzeba.")
}

/// Zbiera log transportu, żeby w trybie `--json` trafił do pola `log`, a nie na stdout
/// obok obiektu JSON. Logger jest `@Sendable`, stąd zamek.
final class LogCollector: @unchecked Sendable {
    private var collected: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(line)
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

struct SlotReport: Encodable {
    let slot: String
    let name: String
    let version: Int
    let voiceModules: Int
    let voiceCables: Int
    let fxModules: Int
    let fxCables: Int
    let inputToInputCables: Int
}

struct AnswerReport: Encodable {
    let subCommand: String
    let payloadHex: String
}

struct SendReport: Encodable {
    let payloadHex: String
    let frameHex: String
    let packets: Int
    /// Pakiety, które NIE są powiadomieniem — czyli faktyczna odpowiedź na komendę.
    let answers: [AnswerReport]
    /// Powiadomienia po `Start` (0x3A leci ~40×/s): sam licznik per subCommand.
    let notifications: [String: Int]
    let log: [String]
}

struct ProbeReport: Encodable {
    let state: String
    let fastConnect: Bool
    let slots: [SlotReport]
    let send: SendReport?
}

let manager = G2MidiManager()
let args = CommandLine.arguments
func slotArgument(_ flag: String) -> UInt8? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count,
          let letter = args[index + 1].uppercased().first,
          let ascii = letter.asciiValue, ascii >= 65, ascii < 65 + UInt8(G2UsbProtocol.maxSlots)
    else { return nil }
    return ascii - 65
}

/// `--loadfile <plik.pch2|.prf2> [--slot D]` — wgranie pliku do slotu drogą oryginału:
/// jedna komenda 0x37 z całym patchem. Odpowiednik `g2ctl.py loadslot`, do porównania
/// z wysyłką molekułami (`--sendtest-slot`) czasem i skutkiem.
let loadFilePath: String? = {
    guard let index = args.firstIndex(of: "--loadfile"), index + 1 < args.count else { return nil }
    return args[index + 1]
}()

/// `--uploadrules <plik.pch2> [--slot D]` — co Nord robi sam po `0x37` bez selekcji slotów
/// i co odpowiada na zapytania, które Clavia wysyła po wgraniu. Odwracalne.
let uploadRulesPath: String? = {
    guard let index = args.firstIndex(of: "--uploadrules"), index + 1 < args.count else { return nil }
    return args[index + 1]
}()

/// `--loadperf <plik.prf2>` — CAŁY performance jednym komunikatem (`0x1A`), drogą
/// oryginału. Sprawdza się sam: po wysyłce czyta cztery sloty na świeżo i porównuje je
/// z plikiem, więc werdykt nie opiera się na odpowiedzi urządzenia. Działa też przeciw
/// emulatorowi — `G2_FORCE_EMULATOR=1` (atrapa) albo `G2_EMULATOR_SOCKET` (firmware).
/// Zdało egzamin na G2 37 (firmware 1.62) 2026-09-10 i na emulatorze firmware'u 2026-09-20.
/// `--perfdump` to stara nazwa tego samego trybu — myliła się z odczytem, została jako alias.
let performanceDumpPath: String? = {
    guard let index = args.firstIndex(where: { $0 == "--loadperf" || $0 == "--perfdump" }),
          index + 1 < args.count else { return nil }
    return args[index + 1]
}()

/// `--storebanks <katalog>` — banki z dysku do **wirtualnego G2**: każdy plik z list
/// `.pchList` (układ banku Clavii: `bank:miejsce: plik`, numeracja od 1) trafia do slotu A
/// albo — `.prf2` — jako cały performance, a potem komendą `0x0B` na swoje miejsce w banku.
/// Na końcu czyta listę banków na świeżo — to ona jest dowodem, nie kody wyników.
/// Do prawdziwego Norda odmawia (`G2MidiManager.storeToBank`) → [[Docs/usb/bank-dump]].
let storeBanksFolder: String? = {
    guard let index = args.firstIndex(of: "--storebanks"), index + 1 < args.count else { return nil }
    return args[index + 1]
}()

/// `--verifyfile <plik.pch2|.prf2>` — porównanie CZTERECH slotów urządzenia z plikiem.
/// Nic nie wysyła: czyta sloty przy handshake'u i sprawdza, czy leży w nich to, co w pliku.
/// Do sprawdzania wgrań zrobionych z aplikacji — „OK" w odpowiedzi niczego nie dowodzi.
let verifyFilePath: String? = {
    guard let index = args.firstIndex(of: "--verifyfile"), index + 1 < args.count else { return nil }
    return args[index + 1]
}()

/// `--setperfname <nazwa>` — nazwa performance'u DO urządzenia (`0x29`). Sprawdza się
/// sama: czyta nagłówek przed i po, więc werdykt nie opiera się na `OK` (patrz reguła
/// „SUB_RESPONSE_OK nie dowodzi, że komenda zadziałała").
let setPerformanceNameArgument: String? = {
    guard let index = args.firstIndex(of: "--setperfname"), index + 1 < args.count else { return nil }
    return args[index + 1]
}()

let sendTestSlot = slotArgument("--sendtest-slot")
let structTestSlot = slotArgument("--structtest-slot")
/// `--metatest-slot D` — cztery komendy „opisowe" naraz: nazwa modułu (`0x33`),
/// kolor modułu (`0x31`), przesunięcie (`0x34`) i kolor kabla niesiony przez `0x50`.
/// Wszystkie cztery napisano bez sprzętu (2026-09-06) i żadna nie była na nim sprawdzona.
let metaTestSlot = slotArgument("--metatest-slot")
/// `--miditest-slot D` — przypisanie kontrolera MIDI do parametru (`0x22`) i jego
/// skasowanie (`0x23`). Napisane 2026-09-08 z oryginalnego edytora, sprawdzone na
/// sprzęcie 2026-09-18. Obie komendy czekają na `OK`, ale `OK` niczego nie dowodzi — dowodem
/// jest odczyt slotu, w którym przypisanie ma się pojawić, a potem zniknąć.
let midiTestSlot = slotArgument("--miditest-slot")
/// `--settingstest-slot D` — wszystkie 15 suwaków arkusza Patch Settings naraz.
/// Naprawione 2026-09-09 („szły donikąd"), ale nigdy nie sprawdzone na sprzęcie.
/// Każde pole przestawiamy na inną wartość, czytamy slot na świeżo i porównujemy
/// pole po polu; na końcu wracają wartości pierwotne.
let settingsTestSlot = slotArgument("--settingstest-slot")
/// `--descriptiontest-slot D` — opis patcha (`0x21` Patch Header Dump): `Voices`,
/// Poly/Mono/Legato i kategoria. Komenda powstała 2026-09-18 z oryginalnego edytora
/// Clavii i `write_patch_descr` G2-Edita. ✅ **Zmierzone tego samego dnia:** Nord ją
/// potwierdza, molekuła niesie dwubajtową długość, a pól spoza modelu urządzenie od nas
/// nie bierze. Sonda czyta slot na świeżo i przywraca wartości pierwotne.
let descriptionTestSlot = slotArgument("--descriptiontest-slot")
/// `--variationtest-slot D` — trzy komendy wariacji i morfów naraz: przełączenie
/// wariacji (`0x6A`), przepisanie wariacji na wariację (`0x44`) i zakres morfu (`0x43`).
/// Wszystkie napisane 2026-09-06 bez sprzętu. Każdy krok sprawdzany ODCZYTEM slotu,
/// a nie potwierdzeniem; na końcu wartości wracają na swoje miejsce.
let variationTestSlot = slotArgument("--variationtest-slot")
/// `--morphinventory` — nieniszczący spis: ile przypisań morfów i jakie gałki morfu
/// widzimy w każdym z czterech slotów Norda. Odpowiada na pytanie „czy sekcja morfów
/// w ogóle przychodzi w zrzucie slotu", zanim zacznie się szukać winy w komendzie `0x43`.
let morphInventory = args.contains("--morphinventory")
/// `--morphfiletest <plik.pch2> [--slot D]` — rozstrzyga, czy Nord w ogóle ODDAJE
/// przypisania morfów w zrzucie slotu. Wgrywa plik, o którym wiadomo, że morf ma,
/// czyta slot na świeżo i porównuje. Bez tego nie da się powiedzieć, czy `0x43`
/// nie działa, czy tylko jej skutku nie widać. Na końcu wraca pierwotna zawartość slotu.
let morphFileTest: String? = {
    guard let index = args.firstIndex(of: "--morphfiletest"), index + 1 < args.count else { return nil }
    return args[index + 1]
}()

/// `--morphear-slot D [--module N] [--param M] [--note 60]` — **test morfu NA UCHO**,
/// bo odczytem się nie da: Nord nie oddaje przypisań morfów w zrzucie slotu (zmierzone
/// 2026-09-18, `--morphfiletest`). Dwa przebiegi na tym samym patchu: pierwszy BEZ
/// przypisania (kontrolny — nic nie powinno się zmieniać przy kręceniu gałką morfu),
/// drugi PO wysłaniu `0x43`. Gałkę morfu kręci `SET_PARAM` obszaru 2, zweryfikowany
/// na sprzęcie 2026-09-18, więc jedyną niewiadomą przebiegu jest samo przypisanie.
let morphEarSlot = slotArgument("--morphear-slot")
/// `--morphwheel-slot D [--seconds 25]` — wariant testu morfu dla żywego człowieka:
/// przypisanie `0x43` zostaje na kilkanaście sekund, a morfem kręci **użytkownik kołem
/// modulacji** (morf 1 ma źródło „Wheel"). Sonda nic w tym czasie nie wysyła, więc jak
/// dźwięk jedzie za kołem, to jedzie przez nasze przypisanie. Po czasie kasuje je i oddaje
/// ustawienia głośności.
let morphWheelSlot = slotArgument("--morphwheel-slot")
/// `--knobtest-slot D` — gałka strony parametrów przypięta (`0x25`) i zwolniona (`0x26`).
/// Obie napisane 2026-09-08 bez sprzętu. W odróżnieniu od morfów **da się to sprawdzić
/// odczytem**: sekcja gałek (`0x62`) wraca w zrzucie slotu — w patchach użytkownika
/// widać po 23–78 przypisań (`--morphinventory`, 2026-09-18). Wolna gałka, potem
/// zwolnienie, więc stan slotu wraca sam.
let knobTestSlot = slotArgument("--knobtest-slot")
/// `--mutatorbuf-slot D [--variation 9] [--count 1]` — usterka #104. Pierwsze
/// przesłuchanie Mutatora wysyła KAŻDY parametr osobną ramką `0x40` do zestawu 9;
/// w logu użytkownika to 393 ramki w jednej milisekundzie, po których emulowany
/// firmware przestaje odbierać cokolwiek. Sonda rozdziela dwie hipotezy — winny jest
/// NUMER ZESTAWU czy sam ZALEW — bo wysyła dokładnie tyle ramek, ile każesz, do
/// zestawu, który każesz. `0x40` z natury nie odpowiada, więc dowodem jest to, czy
/// urządzenie odpowiada POTEM na coś innego (`GetPatchVersion`). Wartość bierzemy
/// z patcha, żeby nie mieszać trzeciej zmiennej: wartości spoza zakresu.
let mutatorBufferSlot = slotArgument("--mutatorbuf-slot")
/// `--mutatordump-slot D [--variation 9]` — krok 1.5 planu Mutatora: bufor odsłuchu
/// **jedną paczką** (`0x4D` obszaru 2 + `0x4D` Voice + `0x4D` FX + `0x65`, jeden zestaw
/// o numerze 9) zamiast setek `0x40`. Sonda rozstrzyga dwa otwarte pytania
/// [[Docs/usb/mutator-dump]]: czy urządzenie przyjmuje sekcję z JEDNYM zestawem i czy
/// przy okazji nie kasuje zestawów 0–8. Dowodem jest **odczyt slotu po wysyłce**,
/// nie potwierdzenie komendy (reguła z 2026-09-04) — w buforze siedzi wartość-znacznik,
/// więc „skopiowane" nie da się pomylić z „i tak było takie samo".
let mutatorDumpSlot = slotArgument("--mutatordump-slot")
/// `--sweep` — zamiast N razy tej samej ramki przejdź KAŻDY parametr KAŻDEGO modułu
/// wartościami z zestawu 9, czyli wiernie to, co wysyła `PatchState.sendMutatorBuffer`.
/// `--limit N` ucina przebieg po N ramkach — do połowienia, gdy sonda coś zatrzyma.
let sweepBuffer = args.contains("--sweep")
let sweepLimit = args.firstIndex(of: "--limit").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
/// `--saveslot <plik.pch2> [--slot D]` — zrzut zawartości slotu Norda do pliku.
/// Pierwszy klocek zrzutu banków ([[Docs/usb/bank-dump]]) i zarazem siatka bezpieczeństwa:
/// każdy tryb, który NADPISUJE slot, ma się najpierw mieć czym cofnąć (lekcja z 2026-09-18,
/// [[Docs/context/bug-history]]).
let saveSlotPath: String? = {
    guard let index = args.firstIndex(of: "--saveslot"), index + 1 < args.count else { return nil }
    return args[index + 1]
}()

/// `--banktest-slot D` — załadowanie patcha z banku Norda do slotu (`0x0A`). Slot jest
/// najpierw zrzucany do pliku tymczasowego, a po teście wgrywany z powrotem JEDNĄ komendą
/// `0x37` (drogą pewną, nie molekułami). Sprawdzane odczytem: czy w slocie leży patch
/// o nazwie z listy banków.
let bankTestSlot = slotArgument("--banktest-slot")
/// `--soak [ile] [--legacy-drain]` — obciążenie strumienia USB: pętla komend, które
/// dostają odpowiedź, przy chodzących powiadomieniach. Liczy dwie usterki z #91:
/// „stream mismatch" i „no acknowledgement". Domyślnie mierzy to, czym chodzi
/// aplikacja; `--legacy-drain` cofa do zachowania sprzed 2026-09-14 dla porównania.
let soakRounds: Int? = {
    guard let index = args.firstIndex(of: "--soak") else { return nil }
    guard index + 1 < args.count, let rounds = Int(args[index + 1]) else { return 20 }
    return rounds
}()

/// `--play-slot D` — uczyń slot jedynym grającym i edytowanym. Bez tego patch wgrany
/// do slotu innego niż aktywny milczy, a urządzenie nie nadaje dla niego strumienia
/// wskaźników (0x3A/0x39) — patrz `--listen`.
let playSlot = slotArgument("--play-slot")
let paramTestSlot = slotArgument("--paramtest-slot")
let deleteTestSlot = slotArgument("--deletetest-slot")
let liveTestSlot = slotArgument("--livetest-slot")
let labelTestSlot = slotArgument("--labeltest-slot")
let morphNameTestSlot = slotArgument("--morphnametest-slot")
let listenSeconds: Double? = {
    guard let index = args.firstIndex(of: "--listen") else { return nil }
    guard index + 1 < args.count, let seconds = Double(args[index + 1]) else { return 20 }
    return seconds
}()

/// `--dspcost <typeID> [ile] [voice|fx]` — ile jeden typ modułu kosztuje zasobów.
///
/// Buduje patch z `ile` kopiami jednego typu, wgrywa do slotu **D** i czyta `0x72`.
/// Po co: pięć z siedmiu dzielników pamięci mamy wyłącznie z oryginalnego edytora, bo w żadnym
/// dotąd zmierzonym patchu nie były zasobem krytycznym. Żeby je sprawdzić, trzeba patcha
/// szytego pod jeden zasób — a żeby taki uszyć, trzeba wiedzieć, który moduł go obciąża.
///
/// Bez argumentu liczbowego wypisuje listę typów pasujących do podanego tekstu.
let dspCostArgument: (query: String, count: Int, area: PatchArea)? = {
    guard let index = args.firstIndex(of: "--dspcost"), index + 1 < args.count else { return nil }
    let rest = args[(index + 1)...]
    let query = rest.first ?? ""
    let count = rest.dropFirst().compactMap { Int($0) }.first ?? 1
    let area: PatchArea = rest.contains("voice") ? .voice : .fx
    return (query, count, area)
}()

/// `--dsptable [plik.csv]` — koszt zasobów KAŻDEGO typu modułu, zmierzony po kolei.
///
/// Jeden moduł do slotu D, odczyt `0x72`, następny. Wszystko na jednym połączeniu, bo
/// osobne uruchomienie sondy na typ to 168 handshake'ów. Obszar **fx** celowo: jest
/// monofoniczny, więc odpada pytanie, czy liczba głosów mnoży koszt.
let dspTablePath: String? = {
    guard let index = args.firstIndex(of: "--dsptable") else { return nil }
    let next = index + 1 < args.count ? args[index + 1] : nil
    return next?.hasSuffix(".csv") == true ? next : "dsp-module-cost.csv"
}()

/// `--dspcal [plik.csv] [typeID…]` — to, czego `--dsptable` nie widzi: koszt drugiej sztuki
/// tego samego typu, uprate i podłączonych wejść.
///
/// Dla każdego typu: jedna sztuka, dwie sztuki (część pamięci jest wspólna dla typu),
/// jedna z uprate (gdy ma dwukolorowe wejście) i po jednej z kablem od `Constant` do
/// każdego wejścia — bez uprate i z uprate. Sam kabel nic nie kosztuje, ale podłączone
/// wejście bywa, że włącza w module dodatkowy kod (FM oscylatora: +13 cykli). PERfourMER
/// z 2026-10-26: tabela 69 %, Nord 117 % → [[Docs/data/dsp-module-cost]].
/// `--loadcheck plik.pch2…` — szacunek edytora obok odczytu `0x72` dla prawdziwych patchy.
/// Każdy plik idzie do slotu D z flagami uprate przeliczonymi tak jak przy otwarciu
/// w edytorze; wynik to jedna linia na obszar: szacunek, urządzenie, różnica.
let loadCheckFiles: [String]? = {
    guard let index = args.firstIndex(of: "--loadcheck") else { return nil }
    return args[(index + 1)...].filter { $0.hasSuffix(".pch2") || $0.hasSuffix(".prf2") }
}()

// `--make-voicecal szablon.pch2 katalog` — bez urządzenia: po dwa pliki na typ modułu
// (jedna i dwie sztuki w obszarze VOICE, parametry domyślne, bez kabli), do przepuszczenia
// przez `--loadcheck … --drop 5b`. Kalibracja `--dspcal` idzie w fx molekułami i nie widzi
// kosztu modułów głosu (Keyboard, Device) → [[Docs/data/dsp-cost-model]].
if let index = args.firstIndex(of: "--make-voicecal"), index + 2 < args.count {
    let template = args[index + 1]
    let folder = args[index + 2]
    guard let data = FileManager.default.contents(atPath: template),
          let parsed = try? PatchParser.parseFile(data: data),
          var base = parsed.patches.first
    else {
        print("⚠️ nie czytam \(template)")
        exit(1)
    }
    base.fxModules = []
    base.fxCables = []
    base.voiceCables = []
    base.notes = ""
    base.knobAssignments = base.knobAssignments.map { _ in nil }
    base.midiControllerAssignments = base.midiControllerAssignments.map { _ in nil }
    base.morphAssignments = base.morphAssignments.map { _ in [] }
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    var written = 0
    func voiceModule(_ def: ModuleDef, id: Int) -> G2Module {
        var mod = G2Module(id: id, typeID: def.id, area: .voice)
        let defaults = ModuleDefaultsDatabase.defaults(forTypeID: def.id)
        mod.parameters = defaults.isEmpty ? Array(repeating: 0, count: def.paramNames.count) : defaults
        mod.parameterVariations = Array(repeating: mod.parameters, count: 9)
        mod.modes = Array(repeating: 0, count: def.modeNames.count)
        mod.label = def.shortName
        mod.hasParameterEntry = !mod.parameters.isEmpty
        mod.row = (id - 1) * 8
        return mod
    }
    let constantDef = ModuleDatabase.module(id: 43)
    for def in ModuleDatabase.all.sorted(by: { $0.id < $1.id }) {
        // 1 i 2 sztuki; 3 = jedna sztuka ze wszystkimi wejściami od `Constant`.
        for count in 1 ... 3 {
            if count == 3, def.inputs.isEmpty || constantDef == nil { continue }
            var patch = base
            patch.name = "VC\(def.id)x\(count)"
            patch.voiceModules = (1 ... min(count, 2)).map { voiceModule(def, id: $0) }
            if count == 3, let constantDef {
                patch.voiceModules = [voiceModule(def, id: 1), voiceModule(constantDef, id: 2)]
                patch.voiceCables = def.inputs.indices.map {
                    G2Cable(fromModule: 2, fromConnector: 0, toModule: 1, toConnector: $0, color: .blue, area: .voice)
                }
            }
            guard let out = try? PatchParser.saveAll(originalData: data, patches: [patch],
                                                     performance: parsed.performance)
            else {
                print("⚠️ nie zapisuję typu \(def.id)")
                continue
            }
            FileManager.default.createFile(atPath: "\(folder)/vc-\(def.id)-x\(count).pch2", contents: out)
            written += 1
        }
    }
    print("Zapisane: \(written) plików w \(folder)")
    exit(0)
}

/// `--drop 65,62` przy `--loadcheck` — typy sekcji (hex) wycięte ze strumienia, żeby
/// zobaczyć, ile pamięci kosztuje każda z nich. `4d.2` wycina tylko sekcję parametrów
/// o danej lokacji (0 fx, 1 voice, 2 ustawienia patcha i morfy).
let loadCheckDrop: [(type: UInt8, location: UInt8?)] = {
    guard let index = args.firstIndex(of: "--drop"), index + 1 < args.count else { return [] }
    return args[index + 1].split(separator: ",").compactMap { item in
        let parts = item.split(separator: ".")
        guard let type = UInt8(parts[0], radix: 16) else { return nil }
        return (type, parts.count > 1 ? UInt8(parts[1]) : nil)
    }
}()

/// `--strip-type 126` przy `--loadcheck` — moduły tych typów (dziesiętnie) wyjęte z patcha
/// przed wysłaniem razem z ich kablami. Przypisania gałek i morfów zostają — wytnij je
/// `--drop 62,65,60`.
let loadCheckStripTypes: Set<Int> = {
    guard let index = args.firstIndex(of: "--strip-type"), index + 1 < args.count else { return [] }
    return Set(args[index + 1].split(separator: ",").compactMap { Int($0) })
}()

/// `--keep-type 1,43` — odwrotność `--strip-type`: zostają tylko moduły tych typów.
let loadCheckKeepTypes: Set<Int> = {
    guard let index = args.firstIndex(of: "--keep-type"), index + 1 < args.count else { return [] }
    return Set(args[index + 1].split(separator: ",").compactMap { Int($0) })
}()

func droppingSections(_ drop: [(type: UInt8, location: UInt8?)], from stream: [UInt8]) -> [UInt8] {
    guard !drop.isEmpty else { return stream }
    var result: [UInt8] = []
    var offset = 0
    while offset + 3 <= stream.count {
        let end = min(stream.count, offset + 3 + (Int(stream[offset + 1]) << 8 | Int(stream[offset + 2])))
        let location = offset + 3 < end ? stream[offset + 3] >> 6 : nil
        let dropped = drop.contains { $0.type == stream[offset] && ($0.location == nil || $0.location == location) }
        if dropped {
            print("    (bez sekcji 0x\(String(stream[offset], radix: 16)) lokacja \(location.map(String.init) ?? "-"))")
        } else {
            result += stream[offset ..< end]
        }
        offset = end
    }
    return result
}

let dspCalibration: (path: String, typeIDs: Set<Int>)? = {
    guard let index = args.firstIndex(of: "--dspcal") else { return nil }
    let rest = args[(index + 1)...]
    let path = rest.first { $0.hasSuffix(".csv") } ?? "dsp-module-cost-extra.csv"
    return (path, Set(rest.compactMap { Int($0) }))
}()

extension G2PatchLoad {
    /// Te same liczby we wszystkich polach — do odróżnienia świeżego odczytu od poprzedniego.
    func sameCost(as other: G2PatchLoad?) -> Bool {
        guard let other else { return false }
        return cyclesRed == other.cyclesRed && cyclesBlue == other.cyclesBlue && xMemory == other.xMemory
            && yMemory == other.yMemory && programMemory == other.programMemory
            && zeroPageMemory == other.zeroPageMemory && ram == other.ram && qMemory == other.qMemory
            && rMemory == other.rMemory
    }
}

/// `--hidden [typeID…]` — czy Nord przyjmie moduł, którego Clavia nie udokumentowała.
///
/// BVerhue zapisał o sześciu takich typach „doesn't seem to work", ale **nie podał, co
/// dokładnie się dzieje** — a to jest różnica między „urządzenie odrzuca komendę",
/// „przyjmuje i gubi moduł" a „przyjmuje, moduł zostaje, tylko nie gra". Sonda rozstrzyga
/// pierwsze dwie: wysyła `AddModule` (0x30) i **czyta slot na świeżo**, bo `OK` niczego
/// nie dowodzi (reguła z 2026-09-04).
///
/// Trzeciego pytania — czy moduł wydaje dźwięk — żadna sonda nie rozstrzygnie; to trzeba
/// usłyszeć. Ale gdy moduł zostaje w slocie, urządzenie samo podaje jego prawdziwy kształt
/// (liczbę parametrów i trybów), czego nie ma w żadnym znanym nam źródle.
///
/// Pracuje w slocie **D** i tylko w buforze edycji — banków we flashu nie dotyka.
let hiddenTypeIDs: [Int]? = {
    guard let index = args.firstIndex(of: "--hidden") else { return nil }
    let given = args[(index + 1)...].prefix { Int($0) != nil }.compactMap { Int($0) }
    // Domyślnie: sześć z listy BVerhue + ClkDivFix + trzy nietestowane.
    return given.isEmpty ? [10, 14, 77, 101, 104, 120, 207, 209, 213, 203, 201] : Array(given)
}()

let jsonOutput = args.contains("--json")
let fastConnect = args.contains("--fast-connect")

/// Wypisuje tylko w trybie tekstowym — w `--json` na stdout ma wyjść sam obiekt JSON.
func say(_ line: String) {
    if !jsonOutput { print(line) }
}

/// `--notetest <ile> <on_ms> <off_ms>` — nuty `0x56` DOKŁADNIE tak, jak wysyła je okienko
/// klawiatury edytora: `Task { try? await manager.playNote }` z zewnątrz aktora, przy
/// chodzącej pętli poll. Mierzy, KIEDY ramka naprawdę wyszła (znacznik czasu przy `TX`),
/// więc widać, czy „on" i „off" nie skleiły się w jedną chwilę → nuta niesłyszalna.
let noteTest: (count: Int, onMs: Int, offMs: Int)? = {
    guard let index = args.firstIndex(of: "--notetest"), index + 3 < args.count,
          let count = Int(args[index + 1]), let on = Int(args[index + 2]), let off = Int(args[index + 3])
    else { return nil }
    return (count, on, off)
}()

/// `--notepolarity [nuta]` — który bajt `0x56` znaczy „wciśnięty"? Wysyła nutę `on`,
/// potem `off`, a między jednym a drugim słucha, co urządzenie melduje **samo z siebie**:
/// `0x05 ASSIGNED_VOICES` (ile głosów przydzielono) i `0x69 CURRENT_NOTE`. Liczba głosów
/// rośnie dokładnie wtedy, gdy nuta naprawdę brzmi — więc werdykt nie zależy od tego,
/// czy ktoś słyszy Norda. Niczego w ustawieniach urządzenia nie zmienia.
let notePolarity: UInt8? = {
    guard let index = args.firstIndex(of: "--notepolarity") else { return nil }
    guard index + 1 < args.count, let note = UInt8(args[index + 1]) else { return 60 }
    return note
}()

/// `--mutetest` — trzymana nuta `0x56`, w trakcie `Active/Muted` (obszar 2, moduł 2, param 1)
/// na 0, po chwili z powrotem na 1, potem `Patch Volume` (param 0) na 20 i na 100. Skutek
/// widać w WAV emulatora (albo słychać na Nordzie): dziura w dźwięku i spadek poziomu.
let muteTest = args.contains("--mutetest")

/// `--variationcycle <ile> <ms>` — przełącza wariacje slotu A w kółko (1 → 2 → … → 8 → 1)
/// komendą `0x6A`, co `ms` milisekund, `ile` razy; z opcjonalnym `--slot`. Stanowisko
/// do usterki „emulator trzeszczy przy przełączaniu wariacji": WAV emulatora i log
/// z `G2_RATE_STATS` mówią, co się dzieje w chwili przełączenia. Patch ma grać SAM.
let variationCycle: (count: Int, ms: Int)? = {
    guard let index = args.firstIndex(of: "--variationcycle"), index + 2 < args.count,
          let count = Int(args[index + 1]), let ms = Int(args[index + 2])
    else { return nil }
    return (count, ms)
}()

let sendPayload: [UInt8]? = {
    guard let index = args.firstIndex(of: "--send"), index + 1 < args.count else { return nil }
    guard let bytes = parseHexBytes(args[index + 1]), !bytes.isEmpty else {
        fputs("--send: nie umiem odczytać bajtów z \"\(args[index + 1])\"\n", stderr)
        exit(1)
    }
    return bytes
}()

/// `--stress <minuty> <plik.prf2> <katalog z .pch2> [--wait500ms]` — #146: to, co robił tester
/// Kymeia i my 2026-10-21, w pętli, aż Nord zgubi kanał 0x82 albo minie czas. Obieg:
/// performance jedną komendą, wariacje i nuty, kilka `.pch2` jak „Like the original editor”
/// (A z pliku, B–D puste), edycja kabli w slocie A. NADPISUJE bieżące sloty Norda (banków
/// nie). Log z godzinami: `~/Library/Logs/G2Editor/stress-500ms.log` albo `stress-5s.log`;
/// `--wait500ms` wraca do czekania na dane z 0x82 sprzed 2026-10-21 (0,5 s zamiast 5 s).
struct StressPlan {
    let minutes: Double
    let performance: URL
    let patchFiles: [URL]
}

let stressPlan: StressPlan? = {
    guard let index = args.firstIndex(of: "--stress"), index + 3 < args.count,
          let minutes = Double(args[index + 1]) else { return nil }
    let folder = URL(fileURLWithPath: args[index + 3])
    let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == "pch2" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else {
        fputs("--stress: brak plików .pch2 w \(folder.path)\n", stderr)
        exit(1)
    }
    return StressPlan(minutes: minutes, performance: URL(fileURLWithPath: args[index + 2]), patchFiles: files)
}()

/// Log `--stress`: każda linia z godziną, prosto do pliku — sonda nie ma pierścienia edytora.
final class StressLog: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private var missingAcks = 0
    private var mismatches = 0

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        if line.contains("no acknowledgement") { missingAcks += 1 }
        if line.contains("stream mismatch") { mismatches += 1 }
        handle.write(Data("\(stamp.string(from: Date())) \(line)\n".utf8))
    }

    var counts: (missingAcks: Int, mismatches: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (missingAcks, mismatches)
    }
}

let logCollector = LogCollector()
var sendReport: SendReport?
var exitStatus: Int32 = 0

say("Łączenie z G2…")
do {
    try await manager.connect(readPatches: !fastConnect)
    await say("Połączono. Stan: \(manager.state)")
    // Z czym rozmawiamy. Model urządzenia tego NIE zdradza — atrapa przedstawia się
    // tym samym numerem co sprzęt, a wynik sondy znaczy co innego w każdym z tych
    // dwóch przypadków → [[Docs/usb/emulator]].
    await say("Transport: \(manager.isEmulator ? "EMULATOR (wirtualny G2 — niczego nie dowodzi o sprzęcie)" : "USB (sprzęt)")")
    if let identity = await manager.identity {
        let firmware = identity.firmwareText.map { " \($0)" } ?? ""
        let wheels = identity.model?.hasGlobalModulationWheels == true ? "tak" : "nie"
        say("Urządzenie: \(identity.displayName)\(firmware) — koła globalne: \(wheels)")
    } else {
        say("Urządzenie: nie przedstawiło się (brak znacznika 0x0A w odpowiedzi na 0x80)")
    }

    let patches = await manager.patches
    if fastConnect {
        say("--- --fast-connect: sloty NIE zostały odczytane (sam handshake + wersje slotów) ---")
    } else {
        say("--- Patche sparsowane z GetPatchSlot (parseUsbPatchSlot) ---")
    }
    for (slot, patch) in patches.enumerated() where !fastConnect {
        let letter = Character(UnicodeScalar(UInt8(65 + slot)))
        say("Slot \(letter): \"\(patch.name)\" — fx: \(patch.fxModules.count) modułów/\(patch.fxCables.count) kabli, voice: \(patch.voiceModules.count) modułów/\(patch.voiceCables.count) kabli")
        for module in (patch.fxModules + patch.voiceModules).prefix(5) {
            say("    [\(module.area)] id \(module.id) typeID \(module.typeID) \"\(module.label)\" params: \(module.parameters.prefix(6))…")
        }
        // Kable wejście-wejście (linkType = 0) to normalne, poprawne połączenia — G2
        // pozwala rozgałęzić sygnał, wpinając kabel w drugie wejście. Wypisujemy je
        // osobno, bo do 2026-09-03 model ich nie znał i zapisywał jako wyjście→wejście;
        // to one zostawały w slocie przy czyszczeniu. Lista jest kontrolna, nie alarmowa.
        let inputToInput = (patch.fxCables + patch.voiceCables).filter { !$0.sourceIsOutput }
        if !inputToInput.isEmpty {
            say("    · kable wejście-wejście (linkType=0): \(inputToInput.count)")
            for cable in inputToInput {
                say("      [\(cable.area)] \(cable.fromModule):\(cable.fromConnector) → \(cable.toModule):\(cable.toConnector)")
            }
        }
    }

    if muteTest {
        let started = Date()
        let stamp = { String(format: "%8.1f ms", Date().timeIntervalSince(started) * 1000) }
        let slot: UInt8 = 0
        let variation = await manager.patches[0].description.variation
        print("\n--- MUTETEST slot A, wariacja aktywna \(variation) ---")
        // Pierwsza ramka 0x56 po świeżym połączeniu ginie (emulator, 2026-09-16 — do wyjaśnienia),
        // więc najpierw nuta-zapalnik, której nie mierzymy.
        try await manager.playNote(1, on: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        try await manager.playNote(1, on: false)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await manager.playNote(64, on: true)
        print("\(stamp())  nuta 64 ON")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 1, value: 0, variation: variation)
        print("\(stamp())  Active/Muted := 0")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 1, value: 1, variation: variation)
        print("\(stamp())  Active/Muted := 1")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 0, value: 20, variation: variation)
        print("\(stamp())  Patch Volume := 20")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 0, value: 100, variation: variation)
        print("\(stamp())  Patch Volume := 100")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await manager.playNote(64, on: false)
        print("\(stamp())  nuta 64 OFF")
        try await Task.sleep(nanoseconds: 500_000_000)
    } else if let note = notePolarity {
        // Polaryzacja bajtu on/off w `0x56`. Dowodem NIE jest brak błędu przy wysyłce
        // ani czyjeś ucho — jest nim to, co urządzenie melduje samo: przydzielone głosy
        // (`0x05`) i grana nuta (`0x69`). Jeśli po „on" nie dzieje się nic, a po „off"
        // głos wskakuje, to znaczy, że mamy odwrotnie i wystarczy zmienić znak.
        let log = NotificationLog()
        await manager.setNotificationHandler { note in log.append(note) }

        // Co mierzymy w danej fazie. `0x05`/`0x69` byłyby odpowiedzią wprost, ale ten Nord
        // ich sam nie nadaje (zmierzone 2026-09-18), więc rozstrzyga sygnał, który płynie
        // na pewno: szczyt wskaźnika wyjścia (`0x3A`) i liczba zapalonych diod (`0x39`) —
        // obie rosną, gdy nuta naprawdę zabrzmi.
        struct Phase {
            var direct = 0
            var peakMeter = 0
            var litLeds = 0
        }
        var seen = 0
        func snapshot(_ label: String) -> Phase {
            let entries = log.all()
            let fresh = entries.dropFirst(seen)
            seen = entries.count
            var phase = Phase()
            for entry in fresh {
                switch entry.note.subCommand {
                case 0x05, 0x69: phase.direct += 1
                case 0x3A: phase.peakMeter = max(phase.peakMeter, Int(entry.note.payload.max() ?? 0))
                case 0x39: phase.litLeds = max(phase.litLeds, entry.note.payload.filter { $0 != 0 }.count)
                default: break
                }
            }
            print("  \(label): pakietów \(fresh.count), szczyt wskaźnika \(phase.peakMeter), diod zapalonych \(phase.litLeds), zgłoszeń wprost \(phase.direct)")
            return phase
        }

        print("\n--- NOTE POLARITY: nuta \(note), komenda 0x56 ---")
        print("Słucham 700 ms przed wysłaniem czegokolwiek (tło)…")
        try await Task.sleep(nanoseconds: 700_000_000)
        let baseline = snapshot("tło")

        print("Wysyłam nutę jako WCIŚNIĘTĄ (on: true — tak, jak robi to okienko klawiatury)…")
        try await manager.playNote(note, on: true)
        try await Task.sleep(nanoseconds: 900_000_000)
        let afterOn = snapshot("po „wciśnięciu\u{201D}")

        print("Wysyłam tę samą nutę jako PUSZCZONĄ (on: false)…")
        try await manager.playNote(note, on: false)
        try await Task.sleep(nanoseconds: 900_000_000)
        let afterOff = snapshot("po „puszczeniu\u{201D}")

        /// „Zabrzmiało" = wskaźnik albo diody wyraźnie wyżej niż w tle. Próg 2 odsiewa
        /// drgania ostatniego bitu przy patchu, który i tak cicho szumi.
        func rose(_ phase: Phase, over reference: Phase) -> Bool {
            phase.direct > reference.direct
                || phase.peakMeter >= reference.peakMeter + 2
                || phase.litLeds >= reference.litLeds + 2
        }
        let reactedToOn = rose(afterOn, over: baseline)
        let reactedToOff = rose(afterOff, over: afterOn)
        print("\n--- Werdykt ---")
        switch (reactedToOn, reactedToOff) {
        case (true, _):
            print("✅ Nuta wysłana jako „wciśnięta\u{201D} NAPRAWDĘ zabrzmiała — `0x56` działa,")
            print("   a polaryzacja bajtu on/off jest właściwa (tak, jak wysyła ją okienko klawiatury).")
        case (false, true):
            print("❌ Nic nie zabrzmiało po „wciśnij\u{201D}, a zabrzmiało po „puść\u{201D} —")
            print("   POLARYZACJA ODWROTNA. Poprawka to zamiana znaczenia bajtu w `playNote`.")
        case (false, false):
            print("⚠️ Nic nie drgnęło w żadną stronę. To NIE dowodzi, że komenda nie działa:")
            print("   patch w slocie z klawiaturą może nie mieć obwiedni ani bramki,")
            print("   albo wyciszony jest sam slot. Powtórz przy patchu, który realnie gra.")
        }
        await manager.setNotificationHandler(nil)
    } else if let variationCycle {
        let started = Date()
        let stamp = { String(format: "%8.1f ms", Date().timeIntervalSince(started) * 1000) }
        let slot = slotArgument("--slot") ?? 0
        try await manager.selectSlot(slot)
        print("\n--- VARIATIONCYCLE slot \(slot): \(variationCycle.count) przełączeń co \(variationCycle.ms) ms ---")
        for i in 0 ..< variationCycle.count {
            let variation = (i + 1) % 8
            try await manager.selectVariation(slot: slot, variation: variation)
            print("\(stamp())  wariacja \(variation + 1)")
            try await Task.sleep(nanoseconds: UInt64(variationCycle.ms) * 1_000_000)
        }
        try await manager.selectVariation(slot: slot, variation: 0)
        print("\(stamp())  wariacja 1 (powrót)")
        try await Task.sleep(nanoseconds: 500_000_000)
    } else if let noteTest {
        let started = Date()
        let stamp = { String(format: "%8.1f ms", Date().timeIntervalSince(started) * 1000) }
        await manager.setLog { line in
            if line.contains(" 56 ") { print("\(stamp())  \(line.trimmingCharacters(in: .whitespaces))") }
        }
        print("\n--- NOTETEST: \(noteTest.count) nut, on \(noteTest.onMs) ms / off \(noteTest.offMs) ms, przez Task jak z okienka ---")
        for i in 0 ..< noteTest.count {
            let note = UInt8(60 + i % 12)
            print("\(stamp())  klawisz \(note) WCIŚNIĘTY")
            Task { try? await manager.playNote(note, on: true) }
            try await Task.sleep(nanoseconds: UInt64(noteTest.onMs) * 1_000_000)
            print("\(stamp())  klawisz \(note) puszczony")
            Task { try? await manager.playNote(note, on: false) }
            try await Task.sleep(nanoseconds: UInt64(noteTest.offMs) * 1_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
    } else if let payload = sendPayload {
        // Dowolna komenda bez przebudowy kodu — do 2026-09-03 każdy eksperyment
        // („a co odpowie na to?") wymagał dopisania funkcji w Swift i `swift build`.
        // Bajty podajemy jako payload; długość i CRC dokłada `buildFrame`.
        let frame = G2UsbProtocol.buildFrame(payload: payload)
        say("\n--- SEND: payload \(hexString(payload)) ---")
        say("    ramka po dołożeniu długości i CRC: \(hexString(frame))")
        await manager.setLog { line in
            logCollector.append(line)
            if !jsonOutput { print(line) }
        }
        let capture = try await manager.withPollingPaused {
            try await manager.diagnoseCommand(name: "--send", payload: payload, listenSeconds: 2.0)
        }

        // Po `Start` urządzenie samo nadaje powiadomienia (0x3A ~40×/s), więc surowy log
        // tonie w nich niezależnie od tego, co odpowiedziało na naszą komendę. Rozdzielamy.
        let decoded = capture.responses
        let answers = decoded.filter { !G2UsbProtocol.isUnsolicited($0) }
        var notifications: [String: Int] = [:]
        for response in decoded where G2UsbProtocol.isUnsolicited(response) {
            notifications[String(format: "0x%02X", response.subCommand ?? 0), default: 0] += 1
        }

        say("\nOdpowiedzi na komendę: \(answers.count)  ·  powiadomień pominiętych: \(decoded.count - answers.count)")
        for answer in answers {
            let sub = String(format: "0x%02X", answer.subCommand ?? 0)
            let meaning = answer.subCommand == G2UsbProtocol.subResponseOK ? "  (SUB_RESPONSE_OK)"
                : answer.subCommand == G2UsbProtocol.subResponseError ? "  (SUB_RESPONSE_ERROR)" : ""
            say("    \(sub)\(meaning): \(hexString(Array(answer.payload.prefix(32))))")
        }
        if answers.isEmpty {
            say("⚠️ Zero odpowiedzi — urządzenie milczy na tę komendę (powiadomienia lecą dalej).")
        }
        for (sub, count) in notifications.sorted(by: { $0.key < $1.key }) {
            say("    powiadomienie \(sub) × \(count)")
        }

        sendReport = SendReport(payloadHex: hexString(payload),
                                frameHex: hexString(frame),
                                packets: capture.packetCount,
                                answers: answers.map {
                                    AnswerReport(subCommand: String(format: "0x%02X", $0.subCommand ?? 0),
                                                 payloadHex: hexString($0.payload))
                                },
                                notifications: notifications,
                                log: logCollector.lines())
    } else if let path = verifyFilePath {
        // Porównujemy patche wczytane już przy handshake'u — na uporządkowanych kopiach,
        // bo urządzenie oddaje moduły posortowane po id, a plik trzyma je w kolejności
        // dodawania (patrz `normalized`).
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let fromFile = try PatchParser.parseFile(data: data).patches
        print("\n--- VERIFYFILE: \(path) ---")
        print("Plik ma \(fromFile.count) slot(ów), urządzenie oddało \(patches.count).")
        if fastConnect {
            print("⚠️ --fast-connect nie czyta slotów — bez niego nie ma czego porównywać.")
            exit(1)
        }
        var mismatches = 0
        for (slot, filePatch) in fromFile.enumerated() {
            guard slot < patches.count else {
                print("❌ Slot \(slotLabel(slot)): urządzenie nie oddało tego slotu.")
                mismatches += 1
                continue
            }
            let devicePatch = patches[slot]
            let names = filePatch.name == devicePatch.name
                ? "\"\(devicePatch.name)\""
                : "nazwa: plik \"\(filePatch.name)\" ≠ urządzenie \"\(devicePatch.name)\""
            if try sectionBytes(of: normalized(filePatch)) == sectionBytes(of: normalized(devicePatch)) {
                print("✅ Slot \(slotLabel(slot)) zgodny — \(names), fx \(devicePatch.fxModules.count)m/\(devicePatch.fxCables.count)k, voice \(devicePatch.voiceModules.count)m/\(devicePatch.voiceCables.count)k")
            } else {
                print("❌ Slot \(slotLabel(slot)) ROZJAZD — \(names)")
                print("   plik:       fx \(filePatch.fxModules.count)m/\(filePatch.fxCables.count)k, voice \(filePatch.voiceModules.count)m/\(filePatch.voiceCables.count)k")
                print("   urządzenie: fx \(devicePatch.fxModules.count)m/\(devicePatch.fxCables.count)k, voice \(devicePatch.voiceModules.count)m/\(devicePatch.voiceCables.count)k")
                try printSectionDiff(normalized(filePatch), normalized(devicePatch))
                printModuleDiff(normalized(filePatch), normalized(devicePatch))
                mismatches += 1
            }
        }
        print(mismatches == 0
            ? "\n✅ Wszystkie \(fromFile.count) slot(ów) na urządzeniu zgodne z plikiem."
            : "\n❌ Rozjechanych slotów: \(mismatches) z \(fromFile.count).")
    } else if let plan = stressPlan {
        let wait5s = !args.contains("--wait500ms")
        if !wait5s { await manager.setExtendedReadTries(5) }
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/G2Editor/stress-\(wait5s ? "5s" : "500ms").log")
        let log = try StressLog(url: logURL)
        await manager.setLog { log.write($0) }

        let perfData = try Data(contentsOf: plan.performance)
        let perfPatches = try PatchParser.parseFile(data: perfData).patches
        let perfName = plan.performance.deletingPathExtension().lastPathComponent
        let perfHeader = try PatchParser.performanceSectionStream(fileData: perfData)
        let perfKnobs = try PatchParser.performanceKnobMapStream(fileData: perfData)
        let perfStreams = try (0 ..< G2UsbProtocol.maxSlots).map {
            try PatchParser.slotSectionStream(fileData: perfData, slot: $0)
        }
        let emptyStream = try PatchParser.slotSectionStream(fileData: PatchParser.emptyPatchFile, slot: 0)
        let emptyPatch = try PatchParser.parseFile(data: PatchParser.emptyPatchFile).patches.first ?? G2Patch()

        print("\n--- STRESS: \(plan.minutes) min, czekanie na 0x82: \(wait5s ? "5 s (jak oryginał)" : "0,5 s (jak edytor)") ---")
        print("Performance: \(plan.performance.lastPathComponent) · plików .pch2: \(plan.patchFiles.count)")
        print("Log: \(logURL.path)")

        func pause(_ low: Double, _ high: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(Double.random(in: low ... high) * 1_000_000_000))
        }
        func linkDropped() async -> Bool {
            if case .error = await manager.state { return true }
            return false
        }
        /// Jeden krok; błąd komendy nie przerywa testu — przerywa dopiero zerwane łącze.
        func step(_ label: String, _ body: () async throws -> Void) async -> Bool {
            log.write("=== STRESS: \(label) ===")
            do {
                try await body()
            } catch {
                log.write("    ! stress step failed: \(error.localizedDescription)")
            }
            return await !linkDropped()
        }
        func note() async {
            let key = UInt8.random(in: 48 ... 72)
            try? await manager.playNote(key, on: true)
            await pause(0.2, 0.6)
            try? await manager.playNote(key, on: false)
        }

        let started = Date()
        let deadline = started.addingTimeInterval(plan.minutes * 60)
        var performanceMode: Bool?
        var fileIndex = 0
        var round = 0
        var alive = true
        while alive, Date() < deadline {
            round += 1
            alive = await step("round \(round): performance \(perfName)") {
                if performanceMode != true {
                    try await manager.setPerformanceMode(true)
                    performanceMode = true
                }
                _ = try await manager.sendCompletePerformanceDump(
                    name: perfName, headerSection: perfHeader, slotStreams: perfStreams,
                    knobMapSection: perfKnobs, patches: perfPatches
                )
            }
            for _ in 0 ..< 8 where alive {
                let slot = UInt8.random(in: 0 ..< UInt8(G2UsbProtocol.maxSlots))
                let variation = Int.random(in: 0 ... 7)
                alive = await step("variation \(variation + 1) slot \(slot)") {
                    try await manager.selectVariation(slot: slot, variation: variation)
                }
                await note()
                await pause(0.5, 2.0)
            }
            for _ in 0 ..< 3 where alive {
                let file = plan.patchFiles[fileIndex % plan.patchFiles.count]
                fileIndex += 1
                alive = await step("file \(file.lastPathComponent)") {
                    let data = try Data(contentsOf: file)
                    let patches = try PatchParser.parseFile(data: data).patches.map { patch in
                        var patch = patch
                        patch.fillMissingParameters()
                        return patch
                    }
                    guard let patch = patches.first else { return }
                    let current = try PatchParser.saveAll(originalData: data, patches: [patch])
                    let stream = try PatchParser.slotSectionStream(fileData: current, slot: 0)
                    if performanceMode != false {
                        try await manager.setPerformanceMode(false)
                        performanceMode = false
                    }
                    try await manager.sendPatch(patch, toSlot: 0, sectionStream: stream)
                    for slot in 1 ..< UInt8(G2UsbProtocol.maxSlots) {
                        try await manager.sendPatch(emptyPatch, toSlot: slot, sectionStream: emptyStream)
                    }
                    try await manager.setSlotSelection([true, false, false, false],
                                                       keyboard: [true, false, false, false])
                    try await manager.selectSlot(0)
                }
                for _ in 0 ..< 3 where alive {
                    await note()
                    await pause(0.3, 1.5)
                }
            }
            for _ in 0 ..< 4 where alive {
                let original = await manager.patches[0]
                guard !original.voiceCables.isEmpty else { break }
                var edited = original
                edited.voiceCables.removeLast()
                alive = await step("cable off slot A") { _ = try await manager.syncPatch(edited, toSlot: 0) }
                await pause(0.5, 2.0)
                if alive {
                    alive = await step("cable back slot A") { _ = try await manager.syncPatch(original, toSlot: 0) }
                    await pause(0.5, 2.0)
                }
            }
            let counts = log.counts
            let minutes = Date().timeIntervalSince(started) / 60
            print("  obieg \(round) (\(String(format: "%.1f", minutes)) min): brakujących ACK \(counts.missingAcks), "
                + "rozjazdów \(counts.mismatches)")
        }

        let counts = log.counts
        let minutes = String(format: "%.1f", Date().timeIntervalSince(started) / 60)
        if alive {
            print("\n✅ \(minutes) min, \(round) obiegów bez zerwania łącza (brakujących ACK \(counts.missingAcks), "
                + "rozjazdów \(counts.mismatches)).")
        } else {
            print("\n⚠️ ZŁAPANE po \(minutes) min (obieg \(round)): Nord przestał oddawać dane z 0x82 — łącze zerwane.")
            log.write("=== STRESS: link dropped — reconnecting (USB reset), as the editor would ===")
            do {
                try await manager.connect(readPatches: true)
                try await manager.selectSlot(0)
                log.write("=== STRESS: reconnect OK ===")
                print("✅ Ponowne połączenie z resetem USB przywróciło Norda (odczyt slotów i potwierdzenie przeszły).")
            } catch {
                log.write("=== STRESS: reconnect FAILED: \(error.localizedDescription) ===")
                print("❌ Ponowne połączenie NIE przywróciło Norda: \(error.localizedDescription)")
                exitStatus = 2
            }
        }
    } else if let path = performanceDumpPath {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try PatchParser.parseFile(data: data)
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        print("\n--- LOADPERF: \(path) ---")
        guard parsed.patches.count == G2UsbProtocol.maxSlots else {
            print("⚠️ Plik ma \(parsed.patches.count) slot(ów), a performance wymaga czterech.")
            print("   Pojedynczy patch wgraj przez: --loadfile \(path) --slot A")
            exit(1)
        }

        let header = try PatchParser.performanceSectionStream(fileData: data)
        let knobs = try PatchParser.performanceKnobMapStream(fileData: data)
        let streams = try (0 ..< G2UsbProtocol.maxSlots).map {
            try PatchParser.slotSectionStream(fileData: data, slot: $0)
        }
        let total = G2UsbProtocol.completePerformanceDumpPayload(
            name: name, headerSection: header, slotStreams: streams, knobMapSection: knobs
        ).count
        print("Nagłówek 0x11: \(header.count) B · sloty: \(streams.map(\.count)) B · mapa gałek 0x5F: \(knobs.count) B")
        print("Cały komunikat: \(total) B w JEDNEJ komendzie.")

        await manager.setLog { line in print(line) }
        let started = Date()
        let answer = try await manager.sendCompletePerformanceDump(
            name: name, headerSection: header, slotStreams: streams, knobMapSection: knobs,
            patches: parsed.patches
        )
        let elapsed = Date().timeIntervalSince(started)
        let names = answer.map { entry in
            entry.slot < UInt8(G2UsbProtocol.maxSlots)
                ? "slot \(Character(UnicodeScalar(65 + entry.slot)))=\(entry.version)"
                : "performance=\(entry.version)"
        }
        print("Odpowiedź 0x36 — nowe numery sesji: \(names.joined(separator: ", ")) "
            + "(\(String(format: "%.2f", elapsed)) s)")

        print("Czytam cztery sloty na świeżo — to jest dowód, nie odpowiedź powyżej…")
        await manager.disconnect()
        try await manager.connect(readPatches: true)
        let after = await manager.patches
        var mismatches = 0
        for slot in 0 ..< min(after.count, parsed.patches.count) {
            let letter = Character(UnicodeScalar(65 + UInt8(slot)))
            let fromFile = try sectionBytes(of: normalized(parsed.patches[slot]))
            let fromDevice = try sectionBytes(of: normalized(after[slot]))
            if fromFile == fromDevice {
                print("  ✅ slot \(letter) zgodny z plikiem")
            } else {
                mismatches += 1
                print("  ❌ slot \(letter) ROZJAZD")
                try printSectionDiff(normalized(parsed.patches[slot]), normalized(after[slot]))
                printModuleDiff(normalized(parsed.patches[slot]), normalized(after[slot]))
            }
        }
        print(mismatches == 0
            ? "✅ CAŁY PERFORMANCE WSZEDŁ JEDNĄ KOMENDĄ."
            : "❌ \(mismatches) slot(ów) nie zgadza się z plikiem — 0x1A nie jest gotowe.")
        if mismatches > 0 { exitStatus = 2 }
    } else if let path = loadFilePath {
        let slot = slotArgument("--slot") ?? 0
        let letter = Character(UnicodeScalar(65 + slot))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try PatchParser.parseFile(data: data)
        print("\n--- LOADFILE slot \(letter): \(path) ---")
        print("Plik ma \(parsed.patches.count) slot(ów), wgrywam slot 0 pliku do slotu \(letter) urządzenia.")
        if parsed.patches.count > 1 {
            print("⚠️ To jest performance — pozostałe \(parsed.patches.count - 1) slot(y) ZOSTANĄ POMINIĘTE,")
            print("   razem z ustawieniami performance'u (zegar, zakresy klawiszy, mapa gałek).")
            print("   Cały wgrasz jedną komendą: --loadperf \(path)")
        }

        // Tą samą drogą co edytor (`PatchState.load` + `DeviceConnection.sectionStreams`):
        // moduły bez parametrów dostają domyślne, a strumień idzie z pliku po `saveAll`.
        let patches = parsed.patches.map { patch in
            var patch = patch
            patch.fillMissingParameters()
            return patch
        }
        guard let patch = patches.first else {
            print("⚠️ Plik nie zawiera patcha. Przerywam.")
            exit(1)
        }
        let current = try PatchParser.saveAll(originalData: data, patches: patches,
                                              performance: parsed.performance)
        let stream = try PatchParser.slotSectionStream(fileData: current, slot: 0)
        print("Strumień sekcji: \(stream.count) B (pierwszy bajt 0x\(String(format: "%02X", stream.first ?? 0)))")

        await manager.setLog { line in print(line) }
        let clock = StepClock()
        let started = Date()
        try await manager.sendPatch(patch, toSlot: slot, sectionStream: stream) { step in
            print("  → \(step)  (+\(String(format: "%.3f", clock.elapsedSinceLastAndReset()))s)")
        }
        print("✅ Wysłane w \(String(format: "%.2f", Date().timeIntervalSince(started))) s. Czytam slot na świeżo…")

        await manager.disconnect()
        try await manager.connect()
        let after = await manager.patches[Int(slot)]
        print("Na urządzeniu po wgraniu: fx \(after.fxModules.count)m/\(after.fxCables.count)k, voice \(after.voiceModules.count)m/\(after.voiceCables.count)k")
        print("W pliku:                  fx \(patch.fxModules.count)m/\(patch.fxCables.count)k, voice \(patch.voiceModules.count)m/\(patch.voiceCables.count)k")

        // Porównanie na uporządkowanych kopiach — patrz `normalized`.
        let fromFile = try sectionBytes(of: normalized(patch))
        let fromDevice = try sectionBytes(of: normalized(after))
        if fromFile == fromDevice {
            print("✅ ZGODNE — treść slotu na urządzeniu identyczna jak w pliku.")
            if try sectionBytes(of: patch) != sectionBytes(of: after) {
                print("   (kolejność wpisów w sekcjach inna niż w pliku — urządzenie trzyma")
                print("    moduły posortowane po id; nie niesie to żadnej informacji)")
            }
        } else {
            print("❌ ROZJAZD — urządzenie ma coś innego niż plik.")
            try printSectionDiff(normalized(patch), normalized(after))
            printModuleDiff(normalized(patch), normalized(after))
            exitStatus = 2
        }
    } else if let slot = sendTestSlot {
        let letter = Character(UnicodeScalar(65 + slot))
        let before = args.contains("--dedupe") ? deduplicatingCables(patches[Int(slot)]) : patches[Int(slot)]
        let beforeBytes = try sectionBytes(of: before)
        print("\n--- ROUNDTRIP TEST slot \(letter): odsyłam dokładnie to co przed chwilą odczytałem ---")
        print("Przed zapisem: \(beforeBytes.count) bajtów sekcji (fx+voice)")
        printCables("PRZED", before)

        await manager.setLog { line in print(line) }
        let stepClock = StepClock()
        try await manager.sendPatch(before, toSlot: slot) { step in
            print("  → \(step)  (+\(String(format: "%.3f", stepClock.elapsedSinceLastAndReset()))s)")
        }
        print("sendPatch() zakończone bez błędu. Rozłączam i łączę ponownie, żeby odczytać slot na świeżo…")

        await manager.disconnect()
        try await manager.connect()
        let after = await manager.patches[Int(slot)]
        let afterBytes = try sectionBytes(of: after)
        print("Po zapisie:    \(afterBytes.count) bajtów sekcji (fx+voice)")
        printCables("PO", after)

        if beforeBytes == afterBytes {
            print("✅ ROUNDTRIP OK — bajty sekcji identyczne przed i po zapisie.")
        } else {
            print("❌ ROUNDTRIP MISMATCH — bajty sekcji różnią się przed i po zapisie!")
            print("   przed: fx \(before.fxModules.count)m/\(before.fxCables.count)k, voice \(before.voiceModules.count)m/\(before.voiceCables.count)k")
            print("   po:    fx \(after.fxModules.count)m/\(after.fxCables.count)k, voice \(after.voiceModules.count)m/\(after.voiceCables.count)k")
            try printSectionDiff(before, after)
            printModuleDiff(before, after)
        }
    } else if let slot = paramTestSlot {
        // Test skutku `ParamDump` (0x4D). Roundtrip tego samego patcha niczego nie rozstrzyga:
        // gdy odsyłamy wartości, które urządzenie już ma, zgodny odczyt wychodzi tak samo
        // przy działającym dumpie i przy zignorowanym. Dlatego wysyłamy patch o CELOWO
        // zmienionych parametrach i pytamy o dwie rzeczy naraz: czy odczyt zgadza się z tym,
        // co wysłaliśmy, ORAZ czy w ogóle różni się od stanu sprzed zapisu.
        let letter = Character(UnicodeScalar(65 + slot))
        let original = patches[Int(slot)]
        let mutated = withKnownParameterPattern(original)
        print("\n--- PARAMDUMP TEST slot \(letter): wysyłam znany wzór parametrów ---")
        guard try sectionBytes(of: mutated) != sectionBytes(of: original) else {
            print("⚠️ Wzór nie różni się od stanu obecnego — test nic by nie rozstrzygnął. Przerywam.")
            exit(1)
        }

        await manager.setLog { line in print(line) }
        try await manager.sendPatch(mutated, toSlot: slot) { step in print("  → \(step)") }
        await manager.disconnect()
        try await manager.connect()
        let after = await manager.patches[Int(slot)]

        let matchesSent = try sectionBytes(of: after) == sectionBytes(of: mutated)
        let changedOnDevice = try sectionBytes(of: after) != sectionBytes(of: original)
        print("\nOdczyt == wysłany wzór:  \(matchesSent ? "TAK" : "NIE")")
        print("Odczyt != stan sprzed:   \(changedOnDevice ? "TAK" : "NIE")")
        if matchesSent, changedOnDevice {
            print("✅ ParamDump DZIAŁA — urządzenie przyjęło dokładnie wysłane wartości.")
        } else {
            print("❌ ParamDump NIE działa tak, jak zakładamy:")
            try printSectionDiff(mutated, after)
            printModuleDiff(mutated, after)
        }

        print("\n--- Przywracam pierwotną zawartość slotu \(letter) ---")
        try await manager.sendPatch(original, toSlot: slot) { step in print("  → \(step)") }
        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)]
        try print(sectionBytes(of: restored) == sectionBytes(of: original)
            ? "✅ Slot \(letter) przywrócony bit w bit."
            : "⚠️ Slot \(letter) NIE wrócił do stanu pierwotnego — patrz różnice niżej.")
        if try sectionBytes(of: restored) != sectionBytes(of: original) {
            try printSectionDiff(original, restored)
            printModuleDiff(original, restored)
        }
    } else if let slot = deleteTestSlot {
        // Dowód mechanizmu dla „DeleteModule na 2-Out nie dostaje ACK" (2026-09-03).
        // Korelacja była mocna (jedyny kabel, którego nie dało się skasować przed naprawą
        // `linkType`, wisiał właśnie na 2-Out), ale korelacja to nie mechanizm. Tu ten sam
        // moduł kasujemy DWA razy: raz z podpiętymi kablami, raz po ich skasowaniu.
        let letter = Character(UnicodeScalar(65 + slot))
        let original = patches[Int(slot)]
        let cabled = PatchArea.allCases.compactMap { area in
            original.modules(in: area).first { module in
                original.cables(in: area).contains { $0.fromModule == module.id || $0.toModule == module.id }
            }
        }.first
        guard let target = cabled else {
            print("Slot \(letter) nie ma modułu z podpiętym kablem — nie ma czego badać.")
            exit(1)
        }

        await manager.setLog { line in print(line) }
        print("\n--- DELETE TEST slot \(letter): moduł id \(target.id) typeID \(target.typeID) \"\(target.label)\" ---")
        try await manager.withPollingPaused {
            try await manager.diagnoseCommand(name: "SelectSlot \(letter)", payload: G2UsbProtocol.selectSlotPayload(slot: slot))

            // Rekonstrukcja starego błędu: do 2026-09-03 `deleteCablePayload` kodował
            // `linkType` na sztywno jako 1, więc dla kabla wejście-wejście opisywał kabel,
            // którego w slocie nie ma. Chcemy wiedzieć, czym urządzenie odpowiada na taki
            // opis — odmową (0x7E) czy ciszą.
            if let inputToInput = original.cables(in: target.area).first(where: { !$0.sourceIsOutput }) {
                var withWrongLinkType = inputToInput
                withWrongLinkType.sourceIsOutput = true
                print("\n--- A: DeleteCable z BŁĘDNYM linkType (rekonstrukcja starego buga) ---")
                try await manager.diagnoseCommand(
                    name: "DeleteCable \(inputToInput.fromModule):\(inputToInput.fromConnector) → \(inputToInput.toModule):\(inputToInput.toConnector) jako wy→we",
                    payload: G2UsbProtocol.deleteCablePayload(slot: slot, version: manager.slotVersion(slot), cable: withWrongLinkType),
                    listenSeconds: 3.0
                )
            }

            print("\n--- B: DeleteModule Z podpiętymi kablami ---")
            try await manager.diagnoseCommand(
                name: "DeleteModule id \(target.id) z kablami",
                payload: G2UsbProtocol.deleteModulePayload(slot: slot, version: manager.slotVersion(slot), module: target),
                listenSeconds: 3.0
            )

            print("\n--- C: najpierw kable tego modułu, potem ten sam DeleteModule ---")
            for cable in original.cables(in: target.area)
                where cable.fromModule == target.id || cable.toModule == target.id
            {
                try await manager.diagnoseCommand(
                    name: "DeleteCable \(cable.fromModule):\(cable.fromConnector) → \(cable.toModule):\(cable.toConnector)",
                    payload: G2UsbProtocol.deleteCablePayload(slot: slot, version: manager.slotVersion(slot), cable: cable)
                )
            }
            try await manager.diagnoseCommand(
                name: "DeleteModule id \(target.id) bez kabli",
                payload: G2UsbProtocol.deleteModulePayload(slot: slot, version: manager.slotVersion(slot), module: target),
                listenSeconds: 3.0
            )
        }

        await manager.disconnect()
        try await manager.connect()
        let after = await manager.patches[Int(slot)]
        let survived = after.modules(in: target.area).contains { $0.id == target.id }
        print("\nModuł id \(target.id) po teście: \(survived ? "NADAL JEST" : "skasowany")")

        print("\n--- Przywracam pierwotną zawartość slotu \(letter) ---")
        try await manager.sendPatch(original, toSlot: slot)
        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)]
        try print(sectionBytes(of: restored) == sectionBytes(of: original)
            ? "✅ Slot \(letter) przywrócony bit w bit."
            : "⚠️ Slot \(letter) NIE wrócił do stanu pierwotnego.")
    } else if let slot = playSlot {
        let letter = Character(UnicodeScalar(65 + slot))
        print("\n--- PLAY SLOT \(letter) ---")
        let enabled = (0 ..< G2UsbProtocol.maxSlots).map { $0 == slot }
        try await manager.setSlotSelection(enabled, keyboard: enabled)
        try await manager.selectSlot(slot)
        print("✅ Slot \(letter) gra i jest edytowany.")
    } else if let slot = structTestSlot {
        // Zmiany strukturalne na żywo (`G2MidiManager.syncPatch`) — to, co robi edytor po
        // skasowaniu modułu albo wpięciu kabla. Dowodem skutku jest ODCZYT slotu, nie brak
        // błędu przy wysyłce: `SUB_RESPONSE_OK` przychodzi także za skasowanie czegoś,
        // czego w slocie nie ma (zmierzone 2026-09-03).
        //
        // Przebieg: kasujemy jeden moduł z kablami → czytamy slot → dokładamy go z powrotem
        // (ta sama droga, tylko w drugą stronę) → czytamy slot i porównujemy z pierwotnym.
        // Obie strony różnicy przechodzą więc w jednym przebiegu.
        let letter = Character(UnicodeScalar(65 + slot))
        let original = patches[Int(slot)]
        guard let target = PatchArea.allCases.compactMap({ area in
            original.modules(in: area).max(by: { $0.id < $1.id })
        }).last else {
            print("Slot \(letter) jest pusty — wgraj najpierw patch (`--loadfile x.pch2 --slot \(letter)`).")
            exit(1)
        }

        var edited = original
        edited.deleteModules(moduleIDs: [target.id], in: target.area)
        let lostCables = original.cables(in: target.area).count - edited.cables(in: target.area).count

        await manager.setLog { line in print(line) }
        print("\n--- STRUCT TEST slot \(letter) ---")
        print("Slot ma: fx \(original.fxModules.count)m/\(original.fxCables.count)k, voice \(original.voiceModules.count)m/\(original.voiceCables.count)k")
        print("Kasuję [\(target.area)] id \(target.id) typeID \(target.typeID) \"\(target.label)\" — razem z \(lostCables) kablem/kablami.")

        let deleteStarted = Date()
        let deleteFrames = try await manager.syncPatch(edited, toSlot: slot)
        print("✅ Wysłane w \(String(format: "%.2f", Date().timeIntervalSince(deleteStarted))) s, ramek: \(deleteFrames). Czytam slot na świeżo…")

        await manager.disconnect()
        try await manager.connect()
        let afterDelete = await manager.patches[Int(slot)]
        let survived = afterDelete.modules(in: target.area).contains { $0.id == target.id }
        print("Moduł id \(target.id) na urządzeniu: \(survived ? "❌ NADAL JEST" : "✅ skasowany")")
        print("Po skasowaniu: fx \(afterDelete.fxModules.count)m/\(afterDelete.fxCables.count)k, voice \(afterDelete.voiceModules.count)m/\(afterDelete.voiceCables.count)k")
        try print(sectionBytes(of: normalized(afterDelete)) == sectionBytes(of: normalized(edited))
            ? "✅ Zawartość slotu zgadza się z tym, co pokazywałby edytor po skasowaniu."
            : "❌ Slot ma coś innego, niż powinien mieć po skasowaniu.")

        print("\n--- Druga strona różnicy: dokładam moduł z powrotem ---")
        let addStarted = Date()
        let addFrames = try await manager.syncPatch(original, toSlot: slot)
        print("✅ Wysłane w \(String(format: "%.2f", Date().timeIntervalSince(addStarted))) s, ramek: \(addFrames). Czytam slot na świeżo…")

        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)]
        print("Po dołożeniu:  fx \(restored.fxModules.count)m/\(restored.fxCables.count)k, voice \(restored.voiceModules.count)m/\(restored.voiceCables.count)k")
        if try sectionBytes(of: normalized(restored)) == sectionBytes(of: normalized(original)) {
            print("✅ Slot \(letter) wrócił do stanu pierwotnego bit w bit — obie strony różnicy działają.")
        } else {
            print("❌ Slot \(letter) NIE wrócił do stanu pierwotnego.")
            try printSectionDiff(normalized(original), normalized(restored))
            printModuleDiff(normalized(original), normalized(restored))
        }
    } else if let rounds = soakRounds {
        // Usterka #91: odruchowe opróżnianie 0x82 przed i po każdej komendzie potrafi
        // zabrać dane zapowiedzi, która czeka jeszcze w kolejce 0x81. Na emulatorze
        // kosztowało to 135 rozjazdów i gubione `OK`; na Nordzie reguły dotąd nie
        // zmierzono, więc edytor sprząta tam po staremu.
        //
        // Mierzymy przez obciążenie: komendy Z ODPOWIEDZIĄ w pętli, przy chodzącym
        // strumieniu powiadomień — czyli dokładnie sytuacja, w której pary się rozjeżdżają.
        // Wszystkie użyte komendy są NIENISZCZĄCE (wybór slotu, odczyt ustawień, odczyt
        // obciążenia DSP) — nic w Nordzie nie zostaje zmienione.
        // Domyślnie NIE ruszamy ustawienia — mierzymy to, czym naprawdę chodzi aplikacja.
        // `--legacy-drain` cofa do zachowania sprzed 2026-09-14, żeby dało się porównać.
        let legacyDrain = args.contains("--legacy-drain")
        if legacyDrain { await manager.useOrphanOnlyDrain(false) }
        if args.contains("--orphan-rule") { await manager.useOrphanOnlyDrain(true) }

        let tally = SoakTally()
        await manager.setLog { line in tally.note(line) }

        print("\n--- SOAK: \(rounds) obiegów, reguła 0x82: \(legacyDrain ? "STARA (sprzątaj zawsze, sprzed 2026-09-14)" : "#91 — sprzątaj tylko po rozjeździe") ---")
        let started = Date()
        for round in 0 ..< rounds {
            let slot = UInt8(round % Int(G2UsbProtocol.maxSlots))
            try await manager.selectSlot(slot)
            _ = try await manager.readSynthSettings()
            _ = try await manager.readClockInfo()
            if round % 5 == 4 {
                let progress = tally.snapshot
                print("  obieg \(round + 1)/\(rounds): rozjazdów \(progress.derailments), brakujących ACK \(progress.missingAcks)")
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        print("\n--- Wynik ---")
        print("  obiegów:            \(rounds) w \(String(format: "%.1f", elapsed)) s (\(String(format: "%.0f", elapsed / Double(rounds) * 1000)) ms na obieg)")
        let result = tally.snapshot
        print("  linii logu:         \(result.lines)")
        print("  rozjazdów strumienia: \(result.derailments)")
        print("  brakujących ACK:      \(result.missingAcks)")
        print(result.derailments == 0 && result.missingAcks == 0
            ? "✅ Czysto — ani jednego rozjazdu, ani jednego zgubionego potwierdzenia."
            : "⚠️ Strumień się rozjeżdża — porównaj z drugą regułą, zanim coś przestawisz.")
    } else if let slot = settingsTestSlot {
        // Arkusz Patch Settings idzie tą samą komendą co gałka (`SET_PARAM`), tylko
        // w obszarze 2: numer grupy sekcji `0x4d` jest numerem modułu, a pozycja
        // w grupie — numerem parametru. Sprawdzamy wszystkie 15 pól naraz, bo komenda
        // jest jedna; gdyby droga była zepsuta, nie przeszłoby ŻADNE.
        //
        // Wartość testowa to zawsze przeskok między 0 a 1 — obie są w zakresie
        // każdego z tych pól, więc nie trzeba znać piętnastu różnych zakresów,
        // a odczyt i tak musi się różnić od stanu wyjściowego.
        let letter = Character(UnicodeScalar(65 + slot))
        let original = patches[Int(slot)]
        let variation = original.activeVariation
        let before = original.variationSettings[variation]

        print("\n--- PATCH SETTINGS slot \(letter), wariacja \(variation) ---")
        var plan: [(setting: G2PatchSetting, from: Int, to: Int)] = []
        for setting in G2PatchSetting.allCases {
            let current = before[keyPath: setting.keyPath]
            plan.append((setting, current, current == 1 ? 0 : 1))
        }
        for step in plan {
            print("  \(step.setting.label.padding(toLength: 16, withPad: " ", startingAt: 0)) "
                + "moduł \(step.setting.module) param \(step.setting.param): \(step.from) → \(step.to)")
        }

        await manager.setLog { _ in }
        try await manager.selectSlot(slot)
        for step in plan {
            try await manager.setPatchSettingLive(slot: slot, moduleID: step.setting.module,
                                                  paramIndex: step.setting.param,
                                                  value: step.to, variation: variation)
        }
        print("Wysłane (15 × SET_PARAM, bez ACK — komenda go nie wysyła). Czytam slot na świeżo…")
        try await Task.sleep(nanoseconds: 400_000_000)

        await manager.disconnect()
        try await manager.connect()
        let after = await manager.patches[Int(slot)].variationSettings[variation]

        var passed = 0
        print("\n--- Co urządzenie NAPRAWDĘ ma ---")
        for step in plan {
            let seen = after[keyPath: step.setting.keyPath]
            let ok = seen == step.to
            if ok { passed += 1 }
            print("  \(ok ? "✅" : "❌") \(step.setting.label.padding(toLength: 16, withPad: " ", startingAt: 0)) "
                + "wysłano \(step.to), odczytano \(seen)")
        }
        print("\nPrzeszło \(passed)/\(plan.count).")

        print("\n--- Przywracam wartości pierwotne ---")
        try await manager.selectSlot(slot)
        for step in plan {
            try await manager.setPatchSettingLive(slot: slot, moduleID: step.setting.module,
                                                  paramIndex: step.setting.param,
                                                  value: step.from, variation: variation)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)].variationSettings[variation]
        print(restored == before
            ? "✅ Ustawienia slotu \(letter) wróciły do stanu pierwotnego."
            : "❌ Ustawienia slotu \(letter) NIE wróciły — sprawdź arkusz Patch Settings ręcznie.")
    } else if let path = saveSlotPath {
        let slot = slotArgument("--slot") ?? 0
        let letter = slotLabel(Int(slot))
        let patch = patches[Int(slot)]
        let data = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [patch])
        try data.write(to: URL(fileURLWithPath: path))
        print("\n--- ZRZUT SLOTU \(letter) → \(path) ---")
        print("  \"\(patch.name)\": fx \(patch.fxModules.count)m/\(patch.fxCables.count)k, "
            + "voice \(patch.voiceModules.count)m/\(patch.voiceCables.count)k, \(data.count) B")
        print("Wgrasz to z powrotem przez: swift run USBProbe --loadfile \(path) --slot \(letter)")
    } else if let slot = bankTestSlot {
        // `0x0A` — to samo, co PATCH LOAD na froncie Norda. Komenda NADPISUJE slot,
        // więc najpierw zrzut do pliku tymczasowego; przywracamy nim drogą `0x37`,
        // bo droga molekułami potrafi zgubić komendę (2026-09-18).
        let letter = slotLabel(Int(slot))
        let original = patches[Int(slot)]
        let backup = FileManager.default.temporaryDirectory
            .appendingPathComponent("g2-slot-\(letter)-\(Int(Date().timeIntervalSince1970)).pch2")
        let backupData = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [original])
        try backupData.write(to: backup)
        print("\n--- ŁADOWANIE Z BANKU slot \(letter) (0x0A) ---")
        print("Kopia zapasowa slotu: \(backup.path) (\(backupData.count) B)")

        // Log protokołu włączony: przy pierwszym pomiarze `0x0A` trzeba widzieć, CZY
        // urządzenie w ogóle coś odpowiada — brak `OK` nie znaczy, że komenda nie weszła.
        await manager.setLog { line in print(line) }
        let entries = try await manager.readBankList()
        guard let entry = entries.first(where: { $0.kind != .performance && !$0.name.isEmpty }) else {
            print("❌ Lista banków nie ma ani jednego patcha — nie ma czego ładować.")
            exit(1)
        }
        print("Ładuję \(entry.displayLocation) \"\(entry.name)\" do slotu \(letter)…")

        try await manager.loadFromBank(slot: slot, bank: entry.bank, patch: entry.patch)
        await manager.disconnect()
        try await manager.connect()
        let after = await manager.patches[Int(slot)]
        let ok = after.name == entry.name
        print(ok
            ? "  ✅ `0x0A` DZIAŁA — w slocie leży \"\(after.name)\", czyli patch z banku."
            : "  ❌ `0x0A` — w slocie jest \"\(after.name)\", oczekiwano \"\(entry.name)\".")
        print("     fx \(after.fxModules.count)m/\(after.fxCables.count)k, voice \(after.voiceModules.count)m/\(after.voiceCables.count)k")

        print("\n--- Przywracam slot \(letter) z kopii (0x37) ---")
        let saved = try Data(contentsOf: backup)
        let parsedBackup = try PatchParser.parseFile(data: saved)
        guard let restorePatch = parsedBackup.patches.first else {
            print("❌ Kopia zapasowa nie daje się odczytać — plik zostaje: \(backup.path)")
            exit(1)
        }
        let stream = try PatchParser.slotSectionStream(fileData: saved, slot: 0)
        try await manager.sendPatch(restorePatch, toSlot: slot, sectionStream: stream)
        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)]
        if try sectionBytes(of: normalized(restored)) == sectionBytes(of: normalized(original)) {
            print("✅ Slot \(letter) wrócił do stanu pierwotnego bit w bit (\"\(restored.name)\").")
            try? FileManager.default.removeItem(at: backup)
        } else {
            print("❌ Slot \(letter) NIE wrócił — kopia zapasowa ZOSTAJE: \(backup.path)")
            try printSectionDiff(normalized(original), normalized(restored))
        }
    } else if let slot = knobTestSlot {
        // `0x25` Knob Assign i `0x26` Knob Deassign. Dowodem jest odczyt sekcji gałek
        // (`0x62`) ze slotu, nie `OK` — reguła z 2026-09-03.
        let letter = slotLabel(Int(slot))
        let original = patches[Int(slot)]
        guard let area = PatchArea.allCases.first(where: { !original.modules(in: $0).isEmpty }),
              let target = original.modules(in: area).first(where: { !$0.parameters.isEmpty })
        else {
            print("Slot \(letter) nie ma modułu z parametrami — nie ma czego przypiąć.")
            exit(1)
        }
        guard let knob = original.knobAssignments.indices.first(where: { original.knobAssignments[$0] == nil })
        else {
            print("Slot \(letter) ma zajęte wszystkie gałki stron parametrów.")
            exit(1)
        }
        let location = area.rawValue
        let expected = G2KnobAssignment(location: location, moduleID: target.id, paramIndex: 0)

        await manager.setLog { line in print(line) }
        print("\n--- GAŁKI STRON PARAMETRÓW slot \(letter) ---")
        print("Przypinam gałkę \(knob) (strona \(knob / 8 + 1), miejsce \(knob % 8 + 1)) → [\(area)] moduł \(target.id) \"\(target.label)\", parametr 0")

        try await manager.assignKnob(slot: slot, location: location, moduleID: target.id,
                                     paramIndex: 0, knob: knob, isLed: 0)
        await manager.disconnect()
        try await manager.connect()
        let afterAssign = await manager.patches[Int(slot)].knobAssignments[knob]
        print(afterAssign == expected
            ? "  ✅ `0x25` DZIAŁA — przypisanie jest w slocie: \(afterAssign!)"
            : "  ❌ `0x25` — w slocie jest \(afterAssign.map { "\($0)" } ?? "nic"), oczekiwano \(expected)")

        print("\n--- Zwalniam gałkę (0x26) ---")
        try await manager.deassignKnob(slot: slot, knob: knob)
        await manager.disconnect()
        try await manager.connect()
        let afterDeassign = await manager.patches[Int(slot)].knobAssignments[knob]
        print(afterDeassign == nil
            ? "  ✅ `0x26` DZIAŁA — gałka znów wolna."
            : "  ❌ `0x26` — przypisanie ZOSTAŁO: \(afterDeassign!)")

        let restored = await manager.patches[Int(slot)]
        print(restored.knobAssignments == original.knobAssignments
            ? "✅ Mapa gałek slotu \(letter) wróciła do stanu pierwotnego."
            : "❌ Mapa gałek slotu \(letter) NIE wróciła — sprawdź Parameter Pages ręcznie.")
    } else if let slot = mutatorDumpSlot {
        let letter = slotLabel(Int(slot))
        let buffer = args.firstIndex(of: "--variation")
            .flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? G2Patch.mutatorVariation
        // `--nine-sets` — kontrola A/B: ta sama droga i ten sam znacznik, ale sekcjami
        // `writeParamList` z KOMPLETEM dziewięciu zestawów (zweryfikowanymi bit w bit
        // na plikach). Rozdziela „urządzenie nie bierze tej komendy" od „urządzenie
        // nie bierze sekcji z jednym zestawem".
        let nineSets = args.contains("--nine-sets")
        var patch = patches[Int(slot)]
        patch.ensureRuntimeVariations()
        let playing = patch.activeVariation
        // Znacznik musi mieścić się w ZAKRESIE parametru — urządzenie przycina wartości
        // spoza niego i wtedy „nie doszło" wygląda tak samo jak „doszło i zostało
        // przycięte" (2026-09-22: pierwszy przebieg wysłał 40 na parametr o zakresie
        // 0…1 i wrócił z 1). Dlatego szukamy parametru o zakresie szerokim na tyle,
        // żeby pomyłka była niemożliwa.
        // Znacznik musi mieścić się w ZAKRESIE SPRZĘTOWYM parametru — urządzenie
        // przycina resztę i wtedy „nie doszło" wygląda tak samo jak „doszło i zostało
        // przycięte" (2026-09-22: 100 na `2-Out Destination` wróciło jako 5, także
        // sekcją z dziewięcioma zestawami). Naszej bazie zakresów brakuje większości
        // wpisów, więc bierzemy parametr o krzywej wykładniczej — to u Clavii czasy,
        // poziomy i stroje, czyli gałki o pełnej skali, nie selektory.
        let gene = G2MutatorGenome(patch: patch).genes.first {
            $0.curve.isExponential && $0.maxValue >= 100
        }
        guard let gene,
              let target = patch.modules(in: gene.area).first(where: { $0.id == gene.moduleID })
        else {
            print("Slot \(letter) nie ma gałki o pełnej skali — nie ma czym znaczyć.")
            exit(1)
        }
        let area = gene.area
        let paramIndex = gene.paramIndex

        // Stan SPRZED wysyłki — do niego porównujemy odczyt. Znacznik liczymy od tego,
        // co w CELU już leży, żeby dwa przebiegi pod rząd nie wysłały tej samej wartości
        // (wtedy odczyt niczego by nie rozstrzygnął).
        let before = (0 ..< G2Patch.runtimeVariationCount).map { variation in
            patch.modules(in: area).first { $0.id == target.id }?
                .parameterVariations[variation] ?? []
        }
        let marker = before[buffer][paramIndex] > 63 ? 10 : 100
        patch.setParameter(moduleID: target.id, paramIndex: paramIndex, value: marker,
                           in: area, variation: buffer)
        let expected = patch.modules(in: area).first { $0.id == target.id }?
            .parameterVariations[buffer] ?? []

        let sections: [UInt8] = if nineSets {
            try PatchArea.allCases.flatMap {
                try PatchParser.writeParamList(modules: patch.modules(in: $0), area: $0)
            }
        } else {
            try PatchParser.writeMutatorParamDump(patch, variation: buffer)
        }
        let paramCount = PatchArea.allCases.reduce(0) { sum, area in
            sum + patch.modules(in: area).reduce(0) { $0 + $1.parameters.count }
        }

        await manager.setLog { line in print(line) }
        print("\n--- ZRZUT BUFORA slot \(letter) → zestaw \(buffer)"
            + (nineSets ? " (KONTROLA: dziewięć zestawów) ---" : " (jedna paczka) ---"))
        print("Znacznik: [\(area)] moduł \(target.id) \"\(target.label)\" parametr \(paramIndex) = \(marker),"
            + " było \(before[buffer][paramIndex])")
        print("Paczka: \(sections.count) B; pojedynczo byłoby \(paramCount) ramek `0x40`")

        try await manager.sendParamDump(sections, toSlot: slot)
        print("  ✅ urządzenie potwierdziło paczkę — ale to NICZEGO nie dowodzi, czytamy slot")

        let after = try await manager.reloadPatch(slot: slot)
        print("  ✅ urządzenie odpowiada po zrzucie (slot przeczytany)")
        let read = after.modules(in: area).first { $0.id == target.id }?.parameterVariations ?? []
        guard read.count > buffer else {
            print("  ❌ odczyt nie ma zestawu \(buffer)")
            exit(1)
        }

        if buffer < 8 {
            print(read[buffer] == expected
                ? "  ✅ ZESTAW \(buffer) W URZĄDZENIU = to, co wysłaliśmy (ze znacznikiem \(marker))"
                : "  ❌ zestaw \(buffer) w urządzeniu: \(read[buffer]), wysłane: \(expected)")
        } else {
            // Zestawu 9 nie ma w zrzucie slotu (a to, co widać w modelu, dopisuje nam
            // `ensureRuntimeVariations`). Pytamy więc urządzenie o jego własną kopię:
            // `0x44` przepisuje zestaw na zestaw U SIEBIE i jest sprawdzone na Nordzie,
            // więc wariacja-świadek mówi, co naprawdę leży w buforze.
            let witness = 6
            print("  ⬜ zestaw \(buffer) nie wraca w zrzucie slotu — pytam kopią `0x44` → wariacja \(witness)")
            try await manager.copyVariation(slot: slot, from: buffer, to: witness)
            let copied = try await manager.reloadPatch(slot: slot)
            let readWitness = copied.modules(in: area).first { $0.id == target.id }?
                .parameterVariations[witness] ?? []
            print(readWitness == expected
                ? "  ✅ BUFOR \(buffer) W URZĄDZENIU = to, co wysłaliśmy (znacznik \(marker) wrócił przez kopię)"
                : "  ❌ bufor \(buffer) w urządzeniu: \(readWitness), wysłane: \(expected)")

            // Wariacja-świadek wraca na swoje — tym samym zrzutem, który właśnie
            // sprawdziliśmy, zbudowanym ze stanu slotu sprzed sondy.
            try await manager.sendMutatorDump(patches[Int(slot)], toSlot: slot, variation: witness)
            let restored = try await manager.reloadPatch(slot: slot)
                .modules(in: area).first { $0.id == target.id }?.parameterVariations[witness] ?? []
            print(restored == before[witness]
                ? "  ✅ wariacja \(witness) przywrócona"
                : "  ⚠️ wariacja \(witness) NIE wróciła: \(restored) zamiast \(before[witness])")
        }

        let others = (0 ..< 9).filter { $0 != buffer }
        let intact = others.allSatisfy { read[$0] == before[$0] }
        print(intact
            ? "  ✅ POZOSTAŁE ZESTAWY 0–8 NIETKNIĘTE przez zrzut"
            : "  ❌ zestawy 0–8 ZMIENIONE: "
            + others.filter { read[$0] != before[$0] }
            .map { "\($0): \(before[$0]) → \(read[$0])" }.joined(separator: ", "))

        try await manager.selectVariation(slot: slot, variation: playing)
        print("\nWariacja slotu \(letter) wrócona na \(playing).")
    } else if let slot = mutatorBufferSlot {
        let letter = slotLabel(Int(slot))
        let variation = args.firstIndex(of: "--variation").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 9
        let count = args.firstIndex(of: "--count").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 1
        let patch = patches[Int(slot)]
        guard let area = PatchArea.allCases.first(where: { !patch.modules(in: $0).isEmpty }),
              let target = patch.modules(in: area).first(where: { !$0.parameters.isEmpty })
        else {
            print("Slot \(letter) nie ma modułu z parametrami — nie ma czego wysłać.")
            exit(1)
        }
        let value = target.parameters[0]

        await manager.setLog { line in print(line) }
        print("\n--- BUFOR MUTATORA slot \(letter): \(count) × `0x40` → zestaw \(variation) ---")
        print("Cel: [\(area)] moduł \(target.id) \"\(target.label)\", parametr 0, wartość \(value) (bieżąca, więc w zakresie)")

        /// Żywotność sprawdzamy komendą, która MA odpowiadać. Cisza po `0x40` sama z siebie
        /// niczego nie dowodzi — `0x40` nie odpowiada nigdy (reguła z 2026-09-03).
        func stillAlive(_ label: String) async throws -> Bool {
            let capture = try await manager.diagnoseCommand(
                name: "\(label): GetPatchVersion \(letter)",
                payload: G2UsbProtocol.getPatchVersionPayload(slot: slot),
                listenSeconds: 2.0
            )
            print(capture.packetCount > 0
                ? "  ✅ \(label): urządzenie odpowiada (\(capture.packetCount) pakietów)"
                : "  ❌ \(label): CISZA")
            return capture.packetCount > 0
        }

        try await manager.withPollingPaused {
            guard try await stillAlive("PRZED") else {
                print("\nUrządzenie milczało JUŻ PRZED sondą — wynik nic by nie znaczył. Uruchom emulator od nowa.")
                exit(1)
            }
            if sweepBuffer {
                // Wierne powtórzenie pierwszego przesłuchania Mutatora: KAŻDY parametr
                // KAŻDEGO modułu, wartości z zestawu 9 (tam, gdzie patch je ma) —
                // czyli dokładnie to, co robi `PatchState.sendMutatorBuffer`.
                var sent = 0
                var last = "—"
                outer: for sweptArea in [PatchArea.voice, PatchArea.fx] {
                    for module in patch.modules(in: sweptArea) {
                        let values = module.parameterVariations.indices.contains(variation)
                            ? module.parameterVariations[variation] : module.parameters
                        for (index, paramValue) in values.enumerated() {
                            if let limit = sweepLimit, sent >= limit { break outer }
                            try await manager.setParameterLive(slot: slot, area: sweptArea,
                                                               moduleID: module.id, paramIndex: index,
                                                               value: paramValue, variation: variation)
                            sent += 1
                            last = "[\(sweptArea)] moduł \(module.id) \"\(module.label)\" param \(index) = \(paramValue)"
                        }
                    }
                }
                print("  wysłane \(sent) ramek `0x40` do zestawu \(variation); ostatnia: \(last)")
            } else {
                for _ in 0 ..< count {
                    try await manager.setParameterLive(slot: slot, area: area, moduleID: target.id,
                                                       paramIndex: 0, value: value, variation: variation)
                }
                print("  wysłane \(count) ramek `0x40` do zestawu \(variation)")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            let alive = try await stillAlive("PO")
            print(alive
                ? "\n✅ WNIOSEK: \(count) × zestaw \(variation) NIE zatrzymuje urządzenia."
                : "\n🔴 WNIOSEK: \(count) × zestaw \(variation) ZATRZYMUJE urządzenie.")
        }
    } else if let slot = morphWheelSlot {
        // Ten sam dowód co `--morphear-slot`, tylko morfem kręci ucho i ręka użytkownika.
        let letter = slotLabel(Int(slot))
        let patch = patches[Int(slot)]
        let variation = patch.activeVariation
        let seconds = args.firstIndex(of: "--seconds").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 25
        let morph = 0
        let voice = patch.modules(in: .voice)
        guard let target = voice.first(where: { $0.label.hasPrefix("Osc") && !$0.parameters.isEmpty })
            ?? voice.first(where: { !$0.parameters.isEmpty })
        else {
            print("Slot \(letter) nie ma w obszarze Voice modułu z parametrami.")
            exit(1)
        }
        let bounds = ParameterRangeDatabase.range(moduleTypeID: target.typeID, codeRef: 0) ?? 0 ... 127
        let base = target.parameters[0]
        let up = bounds.upperBound - base
        let down = bounds.lowerBound - base
        let range = abs(up) >= abs(down) ? up : down
        let settings = patch.variationSettings[variation]

        await manager.setLog { _ in }
        try await manager.selectSlot(slot)
        if settings.activeMuted == 0 {
            try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 1, value: 1, variation: variation)
        }
        if settings.patchVolume < 40 {
            try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 0, value: 100, variation: variation)
        }
        // Gałka morfu na zero, żeby koło startowało od stanu „nic nie zmienione".
        try await manager.setPatchSettingLive(slot: slot, moduleID: 1, paramIndex: morph, value: 0, variation: variation)
        try await manager.setMorphRangeLive(slot: slot, location: 1, moduleID: target.id,
                                            paramIndex: 0, morph: morph, range: range, variation: variation)

        print("\n--- MORF Z KOŁA MODULACJI, slot \(letter) ---")
        print("Przypięte: morf 1 (źródło „Wheel\u{201D}) → [voice] moduł \(target.id) \"\(target.label)\", parametr 0")
        print("  wartość \(base), zakres morfu \(range) — przy kole do oporu parametr dojedzie do \(base + range)")
        print("\n👉 GRAJ NA KLAWIATURZE NORDA i KRĘĆ KOŁEM MODULACJI przez \(Int(seconds)) s.")
        print("   Dźwięk jedzie za kołem = `0x43` działa. Koło nic nie robi = nie działa.")
        for remaining in stride(from: Int(seconds), through: 5, by: -5) {
            print("   … \(remaining) s")
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        try await manager.setMorphRangeLive(slot: slot, location: 1, moduleID: target.id,
                                            paramIndex: 0, morph: morph, range: 0, variation: variation)
        try await manager.setPatchSettingLive(slot: slot, moduleID: 1, paramIndex: morph,
                                              value: patch.morphDial(morph, in: variation), variation: variation)
        if settings.activeMuted == 0 {
            try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 1,
                                                  value: settings.activeMuted, variation: variation)
        }
        if settings.patchVolume < 40 {
            try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 0,
                                                  value: settings.patchVolume, variation: variation)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        print("\n--- Posprzątane: przypisanie skasowane, ustawienia slotu oddane. ---")
    } else if let slot = morphEarSlot {
        let letter = slotLabel(Int(slot))
        let patch = patches[Int(slot)]
        let variation = patch.activeVariation
        let morph = args.firstIndex(of: "--morph").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 0
        let note = args.firstIndex(of: "--note").flatMap { $0 + 1 < args.count ? UInt8(args[$0 + 1]) : nil } ?? 60

        // Parametr do morfowania: najchętniej strój oscylatora — zmianę wysokości słychać
        // niezależnie od tego, jak zbudowany jest patch. Gdy oscylatora nie ma, bierzemy
        // pierwszy moduł z parametrami i mówimy o tym wprost.
        let voice = patch.modules(in: .voice)
        let chosen = args.firstIndex(of: "--module").flatMap { index -> G2Module? in
            guard index + 1 < args.count, let id = Int(args[index + 1]) else { return nil }
            return voice.first { $0.id == id }
        } ?? voice.first { $0.label.hasPrefix("Osc") && !$0.parameters.isEmpty }
            ?? voice.first { !$0.parameters.isEmpty }
        guard let target = chosen else {
            print("Slot \(letter) nie ma w obszarze Voice modułu z parametrami — nie ma czego morfować.")
            exit(1)
        }
        let param = args.firstIndex(of: "--param").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 0
        guard target.parameters.indices.contains(param) else {
            print("Moduł \(target.id) nie ma parametru \(param).")
            exit(1)
        }

        // Zakres morfu tak duży, jak pozwala parametr — chodzi o to, żeby BYŁO SŁYCHAĆ.
        let bounds = ParameterRangeDatabase.range(moduleTypeID: target.typeID, codeRef: param) ?? 0 ... 127
        let base = target.parameters[param]
        let up = bounds.upperBound - base
        let down = bounds.lowerBound - base
        let range = abs(up) >= abs(down) ? up : down
        let dialBefore = patch.morphDial(morph, in: variation)

        print("\n--- MORF NA UCHO, slot \(letter) ---")
        print("Patch: \"\(patch.name)\", wariacja \(variation)")
        print("Morfowany parametr: [voice] moduł \(target.id) \"\(target.label)\" (typeID \(target.typeID)), parametr \(param)")
        print("  wartość teraz \(base), zakres parametru \(bounds.lowerBound)…\(bounds.upperBound), zakres morfu \(range)")
        print("Gałka morfu \(morph + 1), nuta \(note). Gałka wróci potem na \(dialBefore).")
        print("\n⚠️ SŁUCHAJ. Dwa przebiegi po ~6 s każdy:")
        print("   1) KONTROLNY — morf NIE jest przypisany, kręcenie gałką nie ma prawa nic zmienić")
        print("   2) WŁAŚCIWY  — po wysłaniu `0x43`; tu dźwięk POWINIEN jechać razem z gałką")

        await manager.setLog { _ in }
        try await manager.selectSlot(slot)

        // Zanim cokolwiek zmierzymy uchem, patch MUSI być słyszalny. Dwa ustawienia
        // potrafią go uciszyć bez śladu w dźwięku: `Active/Muted` i `Patch Volume`
        // (obszar 2, moduł 2, parametry 1 i 0 — droga zweryfikowana na sprzęcie 2026-09-18).
        let settings = patch.variationSettings[variation]
        print("Patch Volume \(settings.patchVolume), Active/Muted \(settings.activeMuted)"
            + (settings.activeMuted == 0 ? "  ← WYCISZONY, włączam na czas testu" : "")
            + (settings.patchVolume < 40 ? "  ← cicho, podkręcam na czas testu" : ""))
        if settings.activeMuted == 0 {
            try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 1,
                                                  value: 1, variation: variation)
        }
        if settings.patchVolume < 40 {
            try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 0,
                                                  value: 100, variation: variation)
        }

        // Pierwsza ramka `0x56` po świeżym połączeniu bywa gubiona — nuta-zapalnik,
        // której nie liczymy (ta sama ostrożność co w `--mutetest`).
        try await manager.playNote(48, on: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        try await manager.playNote(48, on: false)
        try await Task.sleep(nanoseconds: 400_000_000)

        print("\n  ▶ PRÓBA GŁOSU — sama nuta \(note) przez 2 s, bez żadnego morfu.")
        print("     Jeśli TEGO nie słychać, morfu nie ma po co szukać.")
        try await manager.playNote(note, on: true)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await manager.playNote(note, on: false)
        try await Task.sleep(nanoseconds: 800_000_000)

        /// Nuta trzymana, a pod nią gałka morfu jedzie 0 → 127 → 0.
        func sweep(_ label: String) async throws {
            print("\n  ▶ \(label)")
            for count in [3, 2, 1] {
                print("     start za \(count)…")
                try await Task.sleep(nanoseconds: 700_000_000)
            }
            print("     TERAZ: nuta \(note) gra, gałka morfu jedzie 0 → 127 → 0")
            try await manager.playNote(note, on: true)
            for value in stride(from: 0, through: 127, by: 5) + Array(stride(from: 125, through: 0, by: -5)) {
                try await manager.setPatchSettingLive(slot: slot, moduleID: 1, paramIndex: morph,
                                                      value: value, variation: variation)
                try await Task.sleep(nanoseconds: 110_000_000)
            }
            try await manager.playNote(note, on: false)
            print("     koniec przebiegu")
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }

        // Przebieg kontrolny: najpierw upewniamy się, że przypisania NIE MA.
        try await manager.setMorphRangeLive(slot: slot, location: 1, moduleID: target.id,
                                            paramIndex: param, morph: morph, range: 0,
                                            variation: variation)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await sweep("PRZEBIEG 1 (kontrolny, bez przypisania)")

        // Przebieg właściwy: `0x43` z zakresem.
        try await manager.setMorphRangeLive(slot: slot, location: 1, moduleID: target.id,
                                            paramIndex: param, morph: morph, range: range,
                                            variation: variation)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await sweep("PRZEBIEG 2 (po wysłaniu 0x43)")

        // Sprzątanie: kasujemy przypisanie i oddajemy gałkę na miejsce.
        try await manager.setMorphRangeLive(slot: slot, location: 1, moduleID: target.id,
                                            paramIndex: param, morph: morph, range: 0,
                                            variation: variation)
        try await manager.setPatchSettingLive(slot: slot, moduleID: 1, paramIndex: morph,
                                              value: dialBefore, variation: variation)
        if settings.activeMuted == 0 {
            try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 1,
                                                  value: settings.activeMuted, variation: variation)
        }
        if settings.patchVolume < 40 {
            try await manager.setPatchSettingLive(slot: slot, moduleID: 2, paramIndex: 0,
                                                  value: settings.patchVolume, variation: variation)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        print("\n--- Posprzątane: przypisanie skasowane, gałka morfu z powrotem na \(dialBefore). ---")
        print("WERDYKT NALEŻY DO UCHA: dźwięk jechał z gałką TYLKO w przebiegu 2 → `0x43` działa.")
        print("Jechał w obu albo w żadnym → komenda nie zostawia śladu i trzeba szukać dalej.")
    } else if let path = morphFileTest {
        // Dowód wprost: plik z przypisaniem morfu → Nord → odczyt slotu. Jeśli morf
        // wraca, droga odczytu działa i winna jest komenda `0x43`. Jeśli nie wraca,
        // to urządzenie po prostu nie oddaje sekcji morfów i komendy tą drogą
        // sprawdzić się NIE DA — trzeba innego dowodu.
        let slot = slotArgument("--slot") ?? 3
        let letter = slotLabel(Int(slot))
        let original = patches[Int(slot)]
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try PatchParser.parseFile(data: data)
        let filePatches = parsed.patches.map { patch -> G2Patch in
            var patch = patch
            patch.fillMissingParameters()
            return patch
        }
        guard let filePatch = filePatches.first else {
            print("⚠️ Plik nie zawiera patcha. Przerywam.")
            exit(1)
        }
        let rebuilt = try PatchParser.saveAll(originalData: data, patches: filePatches,
                                              performance: parsed.performance)
        let stream = try PatchParser.slotSectionStream(fileData: rebuilt, slot: 0)

        func morphLines(_ patch: G2Patch) -> [String] {
            var lines: [String] = []
            for variation in 0 ..< G2Patch.runtimeVariationCount {
                for entry in patch.morphs(in: variation) {
                    lines.append("    wariacja \(variation): [\(entry.location)] moduł \(entry.moduleID) "
                        + "param \(entry.paramIndex) morf \(entry.morph) zakres \(entry.range)")
                }
            }
            return lines
        }

        print("\n--- MORFY: PLIK → NORD → ODCZYT, slot \(letter) ---")
        let inFile = morphLines(filePatch)
        print("  W pliku \(URL(fileURLWithPath: path).lastPathComponent): \(inFile.isEmpty ? "ani jednego morfu (zły plik do tego testu!)" : "\(inFile.count) przypisań")")
        for line in inFile { print(line) }
        guard !inFile.isEmpty else { exit(1) }

        await manager.setLog { _ in }
        try await manager.sendPatch(filePatch, toSlot: slot, sectionStream: stream)
        await manager.disconnect()
        try await manager.connect()
        let after = await manager.patches[Int(slot)]
        let inDevice = morphLines(after)
        print("  Po odczycie ze slotu: \(inDevice.isEmpty ? "ANI JEDNEGO" : "\(inDevice.count) przypisań")")
        for line in inDevice { print(line) }
        print(inDevice.isEmpty
            ? "\n❌ Nord NIE oddaje przypisań morfów w zrzucie slotu — skutku `0x43` tą drogą nie da się sprawdzić."
            : "\n✅ Droga odczytu działa — jeśli `0x43` nie zostawia śladu, wina jest po stronie komendy.")

        print("\n--- Przywracam slot \(letter) ---")
        try await manager.sendPatch(original, toSlot: slot)
        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)]
        try print(sectionBytes(of: normalized(restored)) == sectionBytes(of: normalized(original))
            ? "✅ Slot \(letter) wrócił do stanu pierwotnego bit w bit."
            : "❌ Slot \(letter) NIE wrócił do stanu pierwotnego.")
    } else if morphInventory {
        print("\n--- SPIS MORFÓW W SLOTACH (tylko odczyt) ---")
        for index in 0 ..< Int(G2UsbProtocol.maxSlots) {
            let patch = patches[index]
            let letter = slotLabel(index)
            var lines: [String] = []
            for variation in 0 ..< G2Patch.runtimeVariationCount {
                let assignments = patch.morphs(in: variation)
                if !assignments.isEmpty {
                    lines.append("    wariacja \(variation): \(assignments.count) przypisań — "
                        + assignments.prefix(3).map { "[\($0.location)] moduł \($0.moduleID) param \($0.paramIndex) morf \($0.morph) zakres \($0.range)" }
                        .joined(separator: ", "))
                }
                let dials = patch.variationSettings.indices.contains(variation)
                    ? patch.variationSettings[variation].morphDials : []
                if dials.contains(where: { $0 != 0 }) {
                    lines.append("    wariacja \(variation): gałki morfu \(dials)")
                }
            }
            let knobs = patch.knobAssignments.enumerated().compactMap { index, assignment in
                assignment.map { "gałka \(index): [\($0.location)] moduł \($0.moduleID) param \($0.paramIndex)" }
            }
            let controllers = patch.midiControllerAssignments.enumerated().compactMap { cc, assignment in
                assignment.map { "CC \(cc): [\($0.location)] moduł \($0.moduleID) param \($0.paramIndex)" }
            }
            print("  Slot \(letter) \"\(patch.name)\" — \(lines.isEmpty ? "ani jednego morfu" : "\(lines.count) wpisów morfu")"
                + ", gałki stron parametrów: \(knobs.isEmpty ? "ANI JEDNEJ" : "\(knobs.count)")"
                + ", kontrolery MIDI: \(controllers.isEmpty ? "ANI JEDNEGO" : "\(controllers.count)")")
            for line in lines { print(line) }
            for line in knobs.prefix(3) { print("    \(line)") }
            for line in controllers.prefix(3) { print("    \(line)") }
        }
    } else if let slot = variationTestSlot {
        // Trzy komendy, jedna sesja: `0x6A` przełącza wariację, `0x44` przepisuje wariację
        // na wariację, `0x43` ustawia zakres morfu. Wszystkie trzy powstały bez sprzętu,
        // więc jedynym dowodem jest ODCZYT slotu po każdej z nich.
        let letter = Character(UnicodeScalar(65 + slot))
        let original = patches[Int(slot)]
        let source = original.activeVariation
        let target = (source + 1) % 8

        // Parametr do zabawy: pierwszy moduł z parametrami, parametr 0.
        guard let area = PatchArea.allCases.first(where: { !original.modules(in: $0).isEmpty }),
              let probe = original.modules(in: area).first(where: { !$0.parameters.isEmpty })
        else {
            print("Slot \(letter) nie ma modułu z parametrami — nie ma czego badać.")
            exit(1)
        }
        let location: UInt8 = area == .voice ? 1 : 0

        func parameter(_ patch: G2Patch, variation: Int) -> Int? {
            guard let module = patch.modules(in: area).first(where: { $0.id == probe.id }),
                  module.parameterVariations.indices.contains(variation),
                  module.parameterVariations[variation].indices.contains(0)
            else { return nil }
            return module.parameterVariations[variation][0]
        }

        await manager.setLog { _ in }
        print("\n--- WARIACJE I MORFY slot \(letter) ---")
        print("Moduł [\(area)] id \(probe.id) \"\(probe.label)\", parametr 0; wariacja \(source) → \(target)")

        // 1. `0x6A` — przełączenie wariacji. Dowodem jest pole „aktywna wariacja"
        //    w opisie patcha (sekcja 0x21), czytane ze slotu na świeżo.
        try await manager.selectSlot(slot)
        try await manager.selectVariation(slot: slot, variation: target)
        await manager.disconnect()
        try await manager.connect()
        let afterSelect = await manager.patches[Int(slot)]
        let selectOK = afterSelect.activeVariation == target
        print("\n  \(selectOK ? "✅" : "❌") `0x6A` wariacja — wysłano \(target), slot pokazuje \(afterSelect.activeVariation)")

        // 2. `0x44` — przepisanie wariacji. Najpierw robimy RÓŻNICĘ w wariacji docelowej,
        //    żeby „skopiowane" nie dało się pomylić z „i tak było takie samo".
        let sourceValue = parameter(afterSelect, variation: source) ?? 0
        let originalTargetValue = parameter(afterSelect, variation: target) ?? 0
        let markerValue = (sourceValue + 40) % 128
        try await manager.selectSlot(slot)
        try await manager.setParameterLive(slot: slot, area: area, moduleID: probe.id,
                                           paramIndex: 0, value: markerValue, variation: target)
        try await Task.sleep(nanoseconds: 300_000_000)
        await manager.disconnect()
        try await manager.connect()
        let marked = await manager.patches[Int(slot)]
        let markerLanded = parameter(marked, variation: target) == markerValue
        print("  \(markerLanded ? "✅" : "❌") znacznik w wariacji \(target): wysłano \(markerValue), odczytano \(parameter(marked, variation: target).map(String.init) ?? "—")")

        try await manager.selectSlot(slot)
        try await manager.copyVariation(slot: slot, from: source, to: target)
        await manager.disconnect()
        try await manager.connect()
        let afterCopy = await manager.patches[Int(slot)]
        let copied = parameter(afterCopy, variation: target)
        let copyOK = markerLanded && copied == sourceValue && sourceValue != markerValue
        print("  \(copyOK ? "✅" : "❌") `0x44` kopia \(source)→\(target) — wariacja \(source) ma \(sourceValue), wariacja \(target) po kopii \(copied.map(String.init) ?? "—")")

        // 3. `0x43` — zakres morfu. Parametr wybieramy taki, który morfu jeszcze nie ma,
        //    więc skasowanie zakresem 0 przywraca stan wyjściowy.
        let morph = 0
        let hadMorph = afterCopy.morphRange(variation: source, location: location,
                                            moduleID: probe.id, paramIndex: 0, morph: morph)
        let morphRange = 25
        // Wariacja MUSI być tą, którą urządzenie gra — przy `SET_PARAM` kosztowało nas to
        // dzień (2026-09-04), więc morf ustawiamy po powrocie na wariację wyjściową.
        try await manager.selectSlot(slot)
        try await manager.selectVariation(slot: slot, variation: source)
        try await manager.setMorphRangeLive(slot: slot, location: location, moduleID: probe.id,
                                            paramIndex: 0, morph: morph, range: morphRange,
                                            variation: source)
        try await Task.sleep(nanoseconds: 300_000_000)
        await manager.disconnect()
        try await manager.connect()
        let afterMorph = await manager.patches[Int(slot)]
        let seenMorph = afterMorph.morphRange(variation: source, location: location,
                                              moduleID: probe.id, paramIndex: 0, morph: morph)
        let morphOK = seenMorph == morphRange
        print("  \(morphOK ? "✅" : "❌") `0x43` morf \(morph) — wysłano zakres \(morphRange), odczytano \(seenMorph) (przed testem \(hadMorph))")

        // `0x44` przepisuje CAŁĄ wariację docelową, więc przywracanie jednego parametru
        // by nie wystarczyło: wgrywamy z powrotem cały patch drogą zapasową (molekuła po
        // molekule z `ParamDump`, czyli z wartościami wszystkich dziewięciu wariacji),
        // kasujemy morf i wracamy na wariację wyjściową.
        print("\n--- Przywracam slot \(letter) ---")
        try await manager.selectSlot(slot)
        try await manager.setMorphRangeLive(slot: slot, location: location, moduleID: probe.id,
                                            paramIndex: 0, morph: morph, range: hadMorph,
                                            variation: source)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await manager.sendPatch(original, toSlot: slot)
        try await manager.selectVariation(slot: slot, variation: source)
        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)]
        let backToSource = restored.activeVariation == source
        let byteIdentical = try sectionBytes(of: normalized(restored)) == sectionBytes(of: normalized(original))
        if backToSource, byteIdentical {
            print("✅ Slot \(letter) wrócił do stanu pierwotnego bit w bit, wariacja \(source).")
        } else {
            print("❌ Slot \(letter) NIE wrócił w całości — wariacja \(restored.activeVariation), bajty \(byteIdentical ? "zgodne" : "różne").")
            if !byteIdentical {
                try printSectionDiff(normalized(original), normalized(restored))
                printModuleDiff(normalized(original), normalized(restored))
            }
        }
    } else if let slot = descriptionTestSlot {
        // `0x21` Patch Header Dump — jedyna droga, którą Voices/Polyphony/Category
        // dojeżdżają do Norda. Czy komenda jest z potwierdzeniem, wypisujemy osobno,
        // a co urządzenie NAPRAWDĘ ma — osobno, z odczytu slotu. Rozstrzyga wyłącznie
        // to drugie (reguła z 2026-09-03).
        let letter = Character(UnicodeScalar(65 + slot))
        let original = patches[Int(slot)]
        let before = original.description

        // Każde pole na WIDOCZNIE inną wartość, w zakresie pola.
        var edited = before
        edited.voices = before.voices == 4 ? 8 : 4
        edited.monopoly = before.monopoly == 0 ? 1 : 0
        edited.category = before.category == 2 ? 5 : 2

        print("\n--- OPIS PATCHA slot \(letter) (0x21) ---")
        print("  Voices     \(before.voices) → \(edited.voices)")
        print("  Mono/Poly  \(before.monopoly) → \(edited.monopoly)")
        print("  Category   \(before.category) → \(edited.category)")
        print("  wariacja \(before.variation) i wysokość \(before.height) zostają bez zmian")

        await manager.setLog { line in print(line) }
        try await manager.selectSlot(slot)
        let acknowledged = try await manager.setPatchDescription(slot: slot, description: edited)
        print(acknowledged
            ? "Urządzenie potwierdziło (OK) — ale to jeszcze niczego nie dowodzi. Czytam slot na świeżo…"
            : "Urządzenie NIE potwierdziło — komenda może być bez ACK. Czytam slot na świeżo…")

        await manager.disconnect()
        try await manager.connect()
        let after = await manager.patches[Int(slot)].description

        print("\n--- Co urządzenie NAPRAWDĘ ma ---")
        var passed = 0
        for (name, sent, seen) in [("Voices", edited.voices, after.voices),
                                   ("Mono/Poly", edited.monopoly, after.monopoly),
                                   ("Category", edited.category, after.category)]
        {
            let ok = sent == seen
            if ok { passed += 1 }
            print("  \(ok ? "✅" : "❌") \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) wysłano \(sent), odczytano \(seen)")
        }
        if after.variation != before.variation {
            print("  ⚠️ wariacja zmieniła się \(before.variation) → \(after.variation) — ciało sekcji ją niesie!")
        }
        print("\nPrzeszło \(passed)/3.")

        print("\n--- Przywracam opis pierwotny ---")
        try await manager.selectSlot(slot)
        _ = try await manager.setPatchDescription(slot: slot, description: before)
        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)].description
        print(restored == before
            ? "✅ Opis slotu \(letter) wrócił do stanu pierwotnego."
            : "❌ Opis slotu \(letter) NIE wrócił — sprawdź Patch Settings ręcznie.")
    } else if let slot = midiTestSlot {
        // `0x22` Ctrl Assign i `0x23` Ctrl Deassign. Obie są komendami Z potwierdzeniem,
        // więc kuszą, żeby uwierzyć w `OK` — ale reguła z 2026-09-03 mówi wprost, że `OK`
        // przychodzi też za rzeczy, które nic nie zrobiły. Czytamy więc slot na świeżo
        // i patrzymy, czy przypisanie naprawdę siedzi w sekcji `0x60`.
        let letter = Character(UnicodeScalar(65 + slot))
        let original = patches[Int(slot)]
        guard let area = PatchArea.allCases.first(where: { !original.modules(in: $0).isEmpty }),
              let target = original.modules(in: area).first(where: { !$0.parameters.isEmpty })
        else {
            print("Slot \(letter) nie ma modułu z parametrami — nie ma czego przypisać.")
            exit(1)
        }
        // Wolny numer kontrolera: taki, który jest dozwolony i nie jest dziś zajęty.
        guard let cc = (0 ..< G2MidiControllers.count).first(where: {
            G2MidiControllers.isValid($0) && original.midiControllerAssignments[$0] == nil
        }) else {
            print("Slot \(letter) ma zajęte wszystkie dozwolone numery kontrolerów.")
            exit(1)
        }

        await manager.setLog { line in print(line) }
        print("\n--- MIDI MAPPING slot \(letter) ---")
        print("Przypisuję CC \(cc) → [\(area)] moduł id \(target.id) \"\(target.label)\", parametr 0")

        try await manager.assignMidiController(slot: slot, cc: cc, location: area.rawValue,
                                               moduleID: target.id, paramIndex: 0)
        print("✅ urządzenie potwierdziło (OK) — czytam slot na świeżo…")
        await manager.disconnect()
        try await manager.connect()
        let afterAssign = await manager.patches[Int(slot)].midiControllerAssignments[cc]
        let expected = G2MidiControllerAssignment(location: area.rawValue, moduleID: target.id, paramIndex: 0)
        if afterAssign == expected {
            print("  ✅ `0x22` DZIAŁA — przypisanie jest w slocie: \(afterAssign!)")
        } else {
            print("  ❌ `0x22` — w slocie jest \(afterAssign.map { "\($0)" } ?? "nic"), oczekiwano \(expected)")
        }

        print("\n--- Kasuję przypisanie (0x23) ---")
        try await manager.deassignMidiController(slot: slot, cc: cc)
        await manager.disconnect()
        try await manager.connect()
        let afterDeassign = await manager.patches[Int(slot)].midiControllerAssignments[cc]
        print(afterDeassign == nil
            ? "  ✅ `0x23` DZIAŁA — przypisania już nie ma."
            : "  ❌ `0x23` — przypisanie ZOSTAŁO: \(afterDeassign!)")

        let restored = await manager.patches[Int(slot)]
        print(restored.midiControllerAssignments == original.midiControllerAssignments
            ? "✅ Mapa kontrolerów slotu \(letter) wróciła do stanu pierwotnego."
            : "❌ Mapa kontrolerów slotu \(letter) NIE wróciła — sprawdź Parameter Overview ręcznie.")
    } else if let slot = metaTestSlot {
        // Cztery komendy „opisowe" w jednym przebiegu: `0x33` nazwa, `0x31` kolor,
        // `0x34` przesunięcie i kolor kabla, który niesie samo `0x50`. Wszystkie
        // powstały bez sprzętu, więc jedyny dowód to ODCZYT slotu po wysyłce —
        // `SUB_RESPONSE_OK` nie dowodzi niczego (reguła z 2026-09-03).
        //
        // Nie wysyłamy tych komend ręcznie: podajemy `syncPatch` zmieniony patch
        // i sprawdzamy dokładnie tę drogę, którą chodzi aplikacja.
        let letter = Character(UnicodeScalar(65 + slot))
        let original = patches[Int(slot)]
        guard let area = PatchArea.allCases.first(where: { !original.modules(in: $0).isEmpty }),
              let target = original.modules(in: area).min(by: { $0.id < $1.id })
        else {
            print("Slot \(letter) jest pusty — wgraj najpierw patch (`--loadfile x.pch2 --slot \(letter)`).")
            exit(1)
        }

        // Każde pole zmieniamy na WIDOCZNIE inne, żeby „bez zmian" nie dało się pomylić
        // z sukcesem. Nazwa mieści się w 16 znakach, kolor i pozycja skaczą o kilka.
        let newLabel = target.label == "ZZprobe" ? "ZZprobe2" : "ZZprobe"
        let newColor: UInt8 = target.color == 3 ? 7 : 3
        let newColumn = target.column
        let newRow = target.row + 2
        let cable = original.cables(in: area).first
        let newCableColor: CableColor = cable?.color == .green ? .purple : .green

        var edited = original
        edited.setLabel(moduleID: target.id, label: newLabel, in: area)
        edited.setModuleColor(moduleID: target.id, color: newColor, in: area)
        edited.moveModule(moduleID: target.id, newColumn: newColumn, newRow: newRow, in: area)
        if let cable {
            var recolored = cable
            recolored.color = newCableColor
            edited.remove(cable: cable)
            edited.add(cable: recolored)
        }

        await manager.setLog { line in print(line) }
        print("\n--- META TEST slot \(letter) — nazwa/kolor/pozycja modułu + kolor kabla ---")
        print("Moduł [\(area)] id \(target.id) typeID \(target.typeID):")
        print("  nazwa    \"\(target.label)\" → \"\(newLabel)\"")
        print("  kolor    \(target.color) → \(newColor)")
        print("  pozycja  \(target.column),\(target.row) → \(newColumn),\(newRow)")
        if let cable {
            print("  kabel    \(cable.fromModule):\(cable.fromConnector) → \(cable.toModule):\(cable.toConnector), kolor \(cable.color) → \(newCableColor)")
        } else {
            print("  kabel    — brak kabli w tym obszarze, koloru kabla nie sprawdzę")
        }

        let started = Date()
        let frames = try await manager.syncPatch(edited, toSlot: slot)
        print("✅ Wysłane w \(String(format: "%.2f", Date().timeIntervalSince(started))) s, ramek: \(frames). Czytam slot na świeżo…")

        await manager.disconnect()
        try await manager.connect()
        let after = await manager.patches[Int(slot)]

        print("\n--- Co urządzenie NAPRAWDĘ ma po wysyłce ---")
        var verdicts: [(String, Bool)] = []
        if let seen = after.modules(in: area).first(where: { $0.id == target.id }) {
            verdicts.append(("nazwa modułu (0x33)", seen.label == newLabel))
            verdicts.append(("kolor modułu (0x31)", seen.color == newColor))
            verdicts.append(("przesunięcie (0x34)", seen.column == newColumn && seen.row == newRow))
            print("  odczyt: nazwa \"\(seen.label)\", kolor \(seen.color), pozycja \(seen.column),\(seen.row)")
        } else {
            print("  ❌ moduł id \(target.id) zniknął ze slotu!")
            verdicts.append(("moduł przetrwał", false))
        }
        if let cable {
            let seenCable = after.cables(in: area).first {
                $0.fromModule == cable.fromModule && $0.fromConnector == cable.fromConnector
                    && $0.toModule == cable.toModule && $0.toConnector == cable.toConnector
            }
            print("  odczyt: kolor kabla \(seenCable.map { "\($0.color)" } ?? "kabla nie ma!")")
            verdicts.append(("kolor kabla w 0x50", seenCable?.color == newCableColor))
        }
        for (name, ok) in verdicts {
            print(ok ? "  ✅ \(name) — DZIAŁA na sprzęcie" : "  ❌ \(name) — urządzenie tego NIE przyjęło")
        }

        print("\n--- Przywracam slot \(letter) ---")
        _ = try await manager.syncPatch(original, toSlot: slot)
        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)]
        if try sectionBytes(of: normalized(restored)) == sectionBytes(of: normalized(original)) {
            print("✅ Slot \(letter) wrócił do stanu pierwotnego bit w bit.")
        } else {
            print("❌ Slot \(letter) NIE wrócił do stanu pierwotnego.")
            try printSectionDiff(normalized(original), normalized(restored))
            printModuleDiff(normalized(original), normalized(restored))
        }
    } else if let slot = morphNameTestSlot {
        // Nazwa morfu na żywo: `0x42` w obszarze 2 (moduł 1 = osiem nazw morfów). Zmieniamy
        // nazwę morfu 1, czytamy slot na świeżo, a na końcu przywracamy poprzednią.
        let letter = Character(UnicodeScalar(65 + slot))
        let original = patches[Int(slot)]
        guard let before = original.morphLabels else {
            print("Slot \(letter): sekcja nazw morfów nieczytelna — nie ma czego zmieniać.")
            exit(1)
        }
        let testName = "ClTest"
        var names = before
        names.setName(testName, morph: 0)
        var changed = original
        changed.moduleCustomData[2] = names.raw
        print("\n--- MORPH NAME TEST slot \(letter): morf 1 „\(before.name(0))” → „\(testName)” ---")

        await manager.setLog { line in print(line) }
        try await manager.selectSlot(slot)
        let frames = try await manager.syncPatch(changed, toSlot: slot)
        print("syncPatch: \(frames) ramek. Odczyt slotu na świeżo…")
        try await Task.sleep(nanoseconds: 300_000_000)
        await manager.disconnect()
        try await manager.connect()
        let readBack = await manager.patches[Int(slot)].morphLabels
        let all = (0 ..< G2Morph.count).map { readBack?.name($0) ?? "?" }
        print("Nazwy morfów po zapisie: \(all)")
        if readBack?.name(0) == testName, (1 ..< G2Morph.count).allSatisfy({ readBack?.name($0) == before.name($0) }) {
            print("✅ 0x42 w obszarze 2 DZIAŁA — Nord oddaje nową nazwę morfu 1, reszta bez zmian.")
        } else {
            print("❌ Nazwa nie wróciła tak, jak wysłana.")
        }

        print("\n--- Przywracam nazwę „\(before.name(0))” ---")
        try await manager.selectSlot(slot)
        _ = try await manager.syncPatch(original, toSlot: slot)
        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)].morphLabels?.name(0)
        print(restored == before.name(0)
            ? "✅ Morf 1 znów „\(before.name(0))”."
            : "⚠️ Morf 1 po przywróceniu: „\(restored ?? "?")”, oczekiwano „\(before.name(0))”.")
    } else if let slot = labelTestSlot {
        // Podpis parametru (`0x42`) na żywo: do slotu trafia nowy moduł z podpisem wziętym
        // z prawdziwego bloku, potem świeży odczyt slotu mówi, czy urządzenie go zapamiętało.
        // Na końcu moduł znika. Jedyny dowód skutku to odczyt — sam brak błędu nic nie znaczy.
        let letter = Character(UnicodeScalar(65 + slot))
        let blocks = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/G2-reference/Ptches pch2 i prf2/NORDD G2 - OK/Bulding Blocks")
        let files = (try? FileManager.default.contentsOfDirectory(at: blocks, includingPropertiesForKeys: nil)) ?? []
        var sample: (module: G2Module, content: [UInt8], file: String)?
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "pch2" {
            guard let block = try? PatchParser.parse(url: file).first,
                  // Podpis z tekstem, nie pusty — inaczej test nie odróżni zapisu od zer.
                  let entry = block.moduleLabels(in: .voice)?.entries.first(where: { $0.content.contains { $0 >= 0x41 } }),
                  let module = block.voiceModules.first(where: { $0.id == entry.moduleID }) else { continue }
            sample = (module, entry.content, file.lastPathComponent)
            break
        }
        guard let sample else {
            print("Brak bloku z podpisem w \(blocks.path) — nie ma czego wysłać.")
            exit(1)
        }
        let original = patches[Int(slot)]
        let newID = (Set(original.voiceModules.map(\.id)).max() ?? 0) + 1
        var module = sample.module
        module.id = newID
        module.column = (original.voiceModules.map(\.column).max() ?? -1) + 1
        module.row = 0
        var changed = original
        changed.voiceModules.append(module)
        changed.addModuleLabels([G2ModuleLabelSection.Entry(moduleID: sample.module.id, content: sample.content)],
                                idMap: [sample.module.id: newID], in: .voice)
        print("\n--- LABEL TEST slot \(letter): moduł typeID \(module.typeID) z „\(sample.file)” jako id \(newID), podpis \(sample.content) ---")

        await manager.setLog { line in print(line) }
        try await manager.selectSlot(slot)
        let frames = try await manager.syncPatch(changed, toSlot: slot)
        print("syncPatch: \(frames) ramek. Odczyt slotu na świeżo…")
        try await Task.sleep(nanoseconds: 300_000_000)
        await manager.disconnect()
        try await manager.connect()
        let after = await manager.patches[Int(slot)]
        let readBack = after.moduleLabels(in: .voice)?.entries.first { $0.moduleID == newID }?.content
        if readBack == sample.content {
            print("✅ 0x42 DZIAŁA — urządzenie oddaje podpis nowego modułu bajt w bajt.")
        } else {
            print("❌ Podpis nie wrócił (odczyt: \(readBack.map { "\($0)" } ?? "brak wpisu"), oczekiwano \(sample.content)).")
        }

        print("\n--- Sprzątanie: moduł testowy znika ---")
        try await manager.selectSlot(slot)
        _ = try await manager.syncPatch(original, toSlot: slot)
        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)]
        print(restored.voiceModules.contains { $0.id == newID }
            ? "⚠️ Moduł testowy nadal w slocie \(letter)."
            : "✅ Slot \(letter) bez modułu testowego.")
    } else if let slot = liveTestSlot {
        // Test skutku SUB_COMMAND_SET_PARAM (0x40) na żywo. To komenda COMMAND_WRITE_NO_RESP —
        // urządzenie jej nie potwierdza (patrz [[Docs/usb/actor]] „Real-time parametry") —
        // więc, tak jak przy DeleteModule (2026-09-03), jedynym dowodem skutku jest ponowny
        // odczyt slotu, nie sam brak błędu przy wysyłce.
        let letter = Character(UnicodeScalar(65 + slot))
        let original = patches[Int(slot)]
        guard let target = PatchArea.allCases.compactMap({ area in
            original.modules(in: area).first { !$0.parameters.isEmpty }
        }).first else {
            print("Slot \(letter) nie ma modułu z parametrami — nie ma czego badać.")
            exit(1)
        }
        let originalValue = target.parameters[0]
        let testValue = (originalValue + 37) % 128
        print("\n--- LIVE PARAM TEST slot \(letter): moduł id \(target.id) typeID \(target.typeID) \"\(target.label)\" [\(target.area)], param 0: \(originalValue) → \(testValue) ---")

        await manager.setLog { line in print(line) }
        try await manager.selectSlot(slot)
        try await manager.setParameterLive(slot: slot, area: target.area, moduleID: target.id, paramIndex: 0, value: testValue)
        print("Wysłano SET_PARAM (bez ACK — komenda go nie wysyła). Czekam 300 ms, potem odczyt slotu na świeżo…")
        try await Task.sleep(nanoseconds: 300_000_000)

        await manager.disconnect()
        try await manager.connect()
        let after = await manager.patches[Int(slot)]
        let afterValue = after.modules(in: target.area).first { $0.id == target.id }?.parameters.first
        print("Odczyt po SET_PARAM: \(afterValue.map(String.init) ?? "moduł/parametr zniknął?!")")
        if afterValue == testValue {
            print("✅ SET_PARAM DZIAŁA — urządzenie przyjęło wysłaną wartość.")
        } else {
            print("❌ SET_PARAM NIE zmienił stanu urządzenia (odczyt: \(afterValue.map(String.init) ?? "?"), oczekiwano \(testValue)).")
        }

        print("\n--- Przywracam pierwotną wartość parametru ---")
        try await manager.selectSlot(slot)
        try await manager.setParameterLive(slot: slot, area: target.area, moduleID: target.id, paramIndex: 0, value: originalValue)
        try await Task.sleep(nanoseconds: 300_000_000)
        await manager.disconnect()
        try await manager.connect()
        let restored = await manager.patches[Int(slot)]
        let restoredValue = restored.modules(in: target.area).first { $0.id == target.id }?.parameters.first
        print(restoredValue == originalValue
            ? "✅ Parametr przywrócony (\(originalValue))."
            : "⚠️ Parametr NIE wrócił do stanu pierwotnego (odczyt: \(restoredValue.map(String.init) ?? "?"), oczekiwano \(originalValue)).")
    } else if args.contains("--synthsettings") || args.contains("--synthsettings-echo")
        || args.contains("--synthsettings-write") || args.contains("--pedalgain-sweep")
    {
        // Ustawienia urządzenia. Sam odczyt (`0x02`) niczego w Nordzie nie zmienia.
        // `--synthsettings-echo` dokłada zapis, ale odsyła **dokładnie te bajty, które
        // przyszły** — jeśli urządzenie go przyjmie, znaczy to, że ramka jest poprawna,
        // a stan Norda zostaje ten sam → [[Docs/usb/synth-settings]].
        await manager.setLog { line in print(line) }
        do {
            if let read = try await manager.readSynthSettings() {
                printSynthSettings(read.settings, raw: read.raw)

                if args.contains("--pedalgain-sweep") {
                    // `Control Pedal Gain` wysłany jako 40 wrócił jako 32 (2026-09-18).
                    // Jedna próbka nie mówi, czy to obcięcie bitów, skok co 8, czy nasz
                    // błąd w układzie bajtów — więc przemiatamy potęgami dwójki i kilkoma
                    // wartościami pośrednimi. Pole nie wpływa na dźwięk; na końcu wraca.
                    print("\n--- SWEEP: Control Pedal Gain, zapis → odczyt ---")
                    var rows: [(sent: Int, read: Int)] = []
                    for value in [0, 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 40, 63, 64, 100, 127] {
                        var probe = read.settings
                        probe.controlPedalGain = value
                        try await manager.setSynthSettings(probe, original: read.raw)
                        guard let back = try await manager.readSynthSettings() else {
                            print("  ⚠️ brak odpowiedzi po zapisie \(value) — przerywam")
                            break
                        }
                        rows.append((value, back.settings.controlPedalGain))
                        print("  wysłano \(String(format: "%3d", value)) → odczytano \(String(format: "%3d", back.settings.controlPedalGain))")
                    }
                    let exact = rows.filter { $0.sent == $0.read }.count
                    print("\nZgodnych \(exact)/\(rows.count).")
                    if exact < rows.count {
                        let steps = Set(rows.map(\.read)).sorted()
                        print("Urządzenie przyjmuje tylko te wartości: \(steps.map(String.init).joined(separator: ", "))")
                    }
                    print("\n--- Przywracam ustawienia pierwotne ---")
                    try await manager.setSynthSettings(read.settings, original: read.raw)
                    if let restored = try await manager.readSynthSettings() {
                        print(restored.raw == read.raw
                            ? "✅ ustawienia urządzenia wróciły bajt w bajt."
                            : "❌ ustawienia NIE wróciły:\n   było: \(hexString(read.raw))\n   jest: \(hexString(restored.raw))")
                    }
                } else if args.contains("--synthsettings-write") {
                    // Echo dowodzi tylko, że ramka jest poprawna. Tu sprawdzamy, czy zapis
                    // NAPRAWDĘ coś w urządzeniu zmienia — bo `OK` tego nie dowodzi.
                    // Ruszamy dwa pola bez wpływu na dźwięk: SysEx ID (adresowanie MIDI)
                    // i wzmocnienie pedału (bez pedału nieodczuwalne). Strojenia, Memory
                    // Protect ani trybu Performance ŚWIADOMIE nie dotykamy.
                    var changed = read.settings
                    let newSysEx = read.settings.sysExID == 5 ? 6 : 5
                    let newGain = read.settings.controlPedalGain == 40 ? 41 : 40
                    changed.sysExID = newSysEx
                    changed.controlPedalGain = newGain
                    print("\n--- Zapis ZMIENIONEGO bloku (0x03) ---")
                    print("  SysEx ID            \(read.settings.sysExID.map(String.init) ?? "All") → \(newSysEx)")
                    print("  Control Pedal Gain  \(read.settings.controlPedalGain) → \(newGain)")
                    try await manager.setSynthSettings(changed, original: read.raw)
                    print("✅ urządzenie przyjęło zapis (OK) — ale to jeszcze nic nie dowodzi, czytam na świeżo…")

                    if let again = try await manager.readSynthSettings() {
                        let sysExOK = again.settings.sysExID == newSysEx
                        let gainOK = again.settings.controlPedalGain == newGain
                        print(sysExOK ? "  ✅ SysEx ID — zmiana WESZŁA na urządzenie"
                            : "  ❌ SysEx ID — urządzenie ma \(again.settings.sysExID.map(String.init) ?? "All")")
                        print(gainOK ? "  ✅ Control Pedal Gain — zmiana WESZŁA na urządzenie"
                            : "  ❌ Control Pedal Gain — urządzenie ma \(again.settings.controlPedalGain)")

                        print("\n--- Przywracam ustawienia pierwotne ---")
                        try await manager.setSynthSettings(read.settings, original: read.raw)
                        if let restored = try await manager.readSynthSettings() {
                            print(restored.raw == read.raw
                                ? "✅ ustawienia urządzenia wróciły bajt w bajt."
                                : "❌ ustawienia NIE wróciły:\n   było: \(hexString(read.raw))\n   jest: \(hexString(restored.raw))")
                        }
                    } else {
                        print("⚠️ po zapisie urządzenie nie odpowiada na 0x02 — TO JEST OBJAW, opisz go")
                    }
                } else if args.contains("--synthsettings-echo") {
                    print("\n--- Odsyłam TEN SAM blok komendą 0x03 ---")
                    try await manager.setSynthSettings(read.settings, original: read.raw)
                    print("✅ urządzenie przyjęło zapis (OK)")
                    if let again = try await manager.readSynthSettings() {
                        print(again.raw == read.raw
                            ? "✅ odczyt po zapisie jest bajt w bajt taki sam — zapis nie popsuł stanu"
                            : "❌ odczyt po zapisie RÓŻNI SIĘ od pierwotnego:\n   było: \(hexString(read.raw))\n   jest: \(hexString(again.raw))")
                    } else {
                        print("⚠️ po zapisie urządzenie nie odpowiada na 0x02 — TO JEST OBJAW, opisz go")
                    }
                }
            } else {
                print("❌ urządzenie nie odpowiedziało na 0x02 albo payload był za krótki")
            }
        } catch {
            print("❌ ustawienia synta: \(error)")
        }
    } else if let folder = storeBanksFolder {
        guard await manager.isEmulator else {
            print("⛔ --storebanks działa tylko z wirtualnym G2 — do Norda zapis do banków jest wyłączony.")
            exit(1)
        }
        struct StoreFailure: Error, CustomStringConvertible { let description: String }
        let root = URL(fileURLWithPath: folder)
        let lists = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "pchList" }
            .sorted { $0.path < $1.path }
        print("\n--- STOREBANKS: \(lists.count) list(y) banków w \(folder) ---")
        let started = Date()
        var stored = 0
        var failures: [String] = []
        for list in lists {
            let data = try Data(contentsOf: list)
            let text = String(decoding: data, as: UTF8.self)
            for line in text.components(separatedBy: .newlines) {
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let bank = Int(parts[0]), let location = Int(parts[1]),
                      bank >= 1, location >= 1 else { continue }
                // Tylko JEDNA spacja po dwukropku należy do formatu — nazwy plików
                // potrafią mieć podwójne spacje w środku („FATBass  NL2").
                let fileName = String(parts[2].hasPrefix(" ") ? parts[2].dropFirst() : parts[2])
                let file = list.deletingLastPathComponent().appendingPathComponent(fileName)
                let label = "\(bank):\(location) \(fileName)"
                do {
                    let fileData = try Data(contentsOf: file)
                    let parsed = try PatchParser.parseFile(data: fileData)
                    let name = String(file.deletingPathExtension().lastPathComponent.prefix(16))
                    let slot: UInt8
                    if file.pathExtension.lowercased() == "prf2" {
                        guard parsed.patches.count == G2UsbProtocol.maxSlots else {
                            throw StoreFailure(description: "performance bez czterech slotów")
                        }
                        let header = try PatchParser.performanceSectionStream(fileData: fileData)
                        let knobs = try PatchParser.performanceKnobMapStream(fileData: fileData)
                        let streams = try (0 ..< G2UsbProtocol.maxSlots).map {
                            try PatchParser.slotSectionStream(fileData: fileData, slot: $0)
                        }
                        try await manager.sendCompletePerformanceDump(
                            name: name, headerSection: header, slotStreams: streams, knobMapSection: knobs,
                            patches: parsed.patches
                        )
                        slot = 4
                    } else {
                        // Tą samą drogą co `--loadfile` (i edytor): brakujące parametry
                        // uzupełnione, strumień z pliku po `saveAll`.
                        let patches = parsed.patches.map { patch in
                            var patch = patch
                            patch.fillMissingParameters()
                            return patch
                        }
                        guard var patch = patches.first else {
                            throw StoreFailure(description: "plik bez patcha")
                        }
                        let current = try PatchParser.saveAll(originalData: fileData, patches: patches,
                                                              performance: parsed.performance)
                        let stream = try PatchParser.slotSectionStream(fileData: current, slot: 0)
                        patch.name = name
                        try await manager.sendPatch(patch, toSlot: 0, sectionStream: stream)
                        slot = 0
                    }
                    let result = try await manager.storeToBank(slot: slot, bank: bank - 1, patch: location - 1)
                    guard G2UsbProtocol.storeSucceeded(result) else {
                        throw StoreFailure(description: result == 3 ? "wynik 3 — Flash memory full"
                            : result == 4 ? "wynik 4 — Memory protect on" : "wynik \(result)")
                    }
                    stored += 1
                    print(String(format: "  ✅ %@  (%.0f s)", label, Date().timeIntervalSince(started)))
                } catch {
                    failures.append("\(label): \(error)")
                    print("  ❌ \(label): \(error)")
                }
            }
        }
        print("\nZapisano \(stored), nie wyszło \(failures.count), czas \(Int(Date().timeIntervalSince(started))) s.")
        for failure in failures { print("  ❌ \(failure)") }

        let entries = try await manager.readBankList()
        let patchCount = entries.filter { $0.kind == .patch }.count
        let perfCount = entries.filter { $0.kind == .performance }.count
        print("Lista banków odczytana na świeżo: \(patchCount) patchy, \(perfCount) performance'ów.")
        if entries.count != stored || !failures.isEmpty { exitStatus = 2 }
    } else if args.contains("--banks") {
        // Pierwszy pomiar listy banków. Odczyt jest nieniszczący — nic nie zapisuje
        // w Nordzie — więc bezpiecznie sprawdzić, czy kursorowa rozmowa `0x14` → `0x16`
        // działa tak, jak ją odczytaliśmy z BVerhue → [[Docs/usb/protocol-map]].
        do {
            // Log protokołu włączony: pierwszy pomiar tej rozmowy skończył się ciszą,
            // a bez surowych podkomend nie da się orzec, czy urządzenie nie odpowiada,
            // czy odpowiada inaczej, niż zakładaliśmy.
            await manager.setLog { line in print(line) }
            let entries = try await manager.readBankList()
            print("odczytano \(entries.count) pozycji z banków")
            var lastKey = ""
            for entry in entries {
                let key = "\(entry.kind == .performance ? "PERF" : "PATCH") bank \(entry.bank + 1)"
                if key != lastKey {
                    print("\n--- \(key) ---")
                    lastKey = key
                }
                print(String(format: "  %-6@ %-16@ kategoria %d",
                             entry.displayLocation as NSString,
                             entry.name as NSString, entry.category))
            }
            print("\nPorównaj z listą na froncie Norda: numeracja tutaj jest taka sama (bank:miejsce).")
        } catch {
            print("❌ odczyt banków nie powiódł się: \(error)")
        }
    } else if args.contains("--dsp") {
        // Pierwszy pomiar obciążenia DSP (`0x71` → `0x72`). Czysty odczyt — prośba o raport
        // niczego w Nordzie nie zmienia. Podejrzanym są tu STAŁE przeliczania na procenty:
        // BVerhue dobrał je empirycznie, a dwa z pięciu pól zostawił bez nazwy. Dlatego
        // wypisujemy i surowe liczby, i procenty → [[Docs/usb/protocol-map]].
        //
        // Odpowiedzi nie zbieramy z `performStep`: `0x72` jest na liście powiadomień, więc
        // przychodzi kanałem `setNotificationHandler` — tym samym, którym Nord nadaje raport
        // sam z siebie po każdej zmianie struktury.
        let notes = NotificationLog()
        await manager.setNotificationHandler { note in notes.append(note) }

        print("\n--- Pytam 0x71 o oba obszary czterech slotów ---")
        for slot in 0 ..< G2UsbProtocol.maxSlots {
            for area in [PatchArea.voice, PatchArea.fx] {
                do {
                    try await manager.requestPatchLoad(slot: UInt8(slot), area: area)
                } catch {
                    print("❌ 0x71 dla slotu \(slot) / \(area) nie wyszło: \(error)")
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        await manager.setNotificationHandler(nil)

        let reports = notes.all().filter { $0.note.subCommand == G2UsbProtocol.subResponsePatchLoad }
        print("\n--- Odpowiedzi 0x72: \(reports.count) ---")
        if reports.isEmpty {
            print("""
            Nic nie przyszło. To jeszcze NIE znaczy, że dekoder jest zły — rozstrzyga
            `--listen 20` z kręceniem gałką na Nordzie: jeśli 0x72 leci tam samo z siebie,
            wadliwa jest prośba 0x71, a nie odczyt.
            """)
        }
        // Ostatni raport dla każdej pary (slot, obszar); starsze to echo tej samej rozmowy.
        var latest: [String: G2PatchLoad] = [:]
        for entry in reports {
            print("slot \(entry.note.slot)  payload \(hexString(entry.note.payload))")
            for reading in G2UsbProtocol.decodePatchLoad(entry.note.payload) {
                latest["\(entry.note.slot)/\(reading.area)"] = reading
            }
        }

        print("\n--- Odczyt w zestawieniu z zawartością slotów ---")
        for (slot, patch) in patches.enumerated() where !fastConnect {
            let letter = Character(UnicodeScalar(UInt8(65 + slot)))
            print("Slot \(letter): \"\(patch.name)\" — voice \(patch.voiceModules.count) modułów, "
                + "fx \(patch.fxModules.count) modułów")
            for area in [PatchArea.voice, PatchArea.fx] {
                guard let reading = latest["\(slot)/\(area)"] else {
                    print("    \(area): brak raportu")
                    continue
                }
                let power = String(format: "%.1f", reading.cyclesPercent)
                let memory = String(format: "%.1f", reading.memoryPercent)
                print("    \(area): cycles \(reading.cyclesRed)/\(reading.cyclesBlue) "
                    + "· Xmem \(reading.xMemory) Ymem \(reading.yMemory) Pmem \(reading.programMemory) "
                    + "ZPmem \(reading.zeroPageMemory) · RAM \(reading.ram) Qmem \(reading.qMemory) "
                    + "Rmem \(reading.rMemory)")
                print("        → moc \(power)%, pamięć \(memory)%")
            }
        }
        print("""

        Co sprawdzić OCZAMI: na froncie Norda przytrzymaj Patch — G2 pokazuje tam własne
        paski obciążenia obszaru. Pusty slot ma dać 0%, a patch pod korek ~100%.
        """)
    } else if let tablePath = dspTablePath {
        guard !fastConnect else {
            print("⛔️ --dsptable nie działa z --fast-connect (patrz --dspcost).")
            await manager.disconnect()
            exit(1)
        }
        let types = ModuleDatabase.all.sorted { $0.id < $1.id }
        print("--- Koszt zasobów \(types.count) typów modułów, slot D / fx ---")
        print("Każdy typ: wgranie jednego modułu + odczyt 0x72. To potrwa kilka minut.\n")

        var rows = ["typeID,shortName,page,cycles_red,cycles_blue,xmem,ymem,pmem,zpmem,ram,qmem,rmem"]
        var failures: [String] = []

        for (index, def) in types.enumerated() {
            var patch = G2Patch()
            patch.name = "DSPCost"
            var mod = G2Module(id: 1, typeID: def.id, area: .fx)
            let defaults = ModuleDefaultsDatabase.defaults(forTypeID: def.id)
            mod.parameters = defaults.isEmpty ? Array(repeating: 0, count: def.paramNames.count) : defaults
            mod.parameterVariations = Array(repeating: mod.parameters, count: 9)
            mod.modes = Array(repeating: 0, count: def.modeNames.count)
            mod.label = def.shortName
            mod.hasParameterEntry = !mod.parameters.isEmpty
            patch.add(module: mod)

            do {
                try await manager.sendPatch(patch, toSlot: 3)
            } catch {
                failures.append("\(def.id) \(def.shortName): wysyłka — \(error)")
                continue
            }

            let notes = NotificationLog()
            await manager.setNotificationHandler { note in notes.append(note) }
            try? await manager.requestPatchLoad(slot: 3, area: .fx)
            try await Task.sleep(nanoseconds: 400_000_000)
            await manager.setNotificationHandler(nil)

            var reading: G2PatchLoad?
            for entry in notes.all() where entry.note.subCommand == G2UsbProtocol.subResponsePatchLoad
                && entry.note.slot == 3
            {
                reading = G2UsbProtocol.decodePatchLoad(entry.note.payload).first { $0.area == .fx } ?? reading
            }
            guard let load = reading else {
                failures.append("\(def.id) \(def.shortName): brak raportu 0x72")
                continue
            }
            rows.append("\(def.id),\(def.shortName),\(def.page),\(load.cyclesRed),\(load.cyclesBlue),"
                + "\(load.xMemory),\(load.yMemory),\(load.programMemory),\(load.zeroPageMemory),"
                + "\(load.ram),\(load.qMemory),\(load.rMemory)")
            print(String(format: "[%3d/%3d] %-12@ cyc %4d/%-4d Xm %-4d Ym %-4d Pm %-4d ZP %-3d Qm %-7d Rm %d",
                         index + 1, types.count, def.shortName as NSString,
                         load.cyclesRed, load.cyclesBlue, load.xMemory, load.yMemory,
                         load.programMemory, load.zeroPageMemory, load.qMemory, load.rMemory))
        }

        // Slot D zostaje pusty — po pomiarze nie ma powodu trzymać tam ostatniego modułu.
        var empty = G2Patch()
        empty.name = "DSPCost"
        try? await manager.sendPatch(empty, toSlot: 3)

        try? rows.joined(separator: "\n").appending("\n").write(toFile: tablePath, atomically: true, encoding: .utf8)
        print("\n--- Zapisane: \(tablePath) (\(rows.count - 1) typów) ---")
        if !failures.isEmpty {
            print("Nie zmierzone (\(failures.count)):")
            for line in failures.prefix(30) {
                print("    \(line)")
            }
        }
        print("Slot D wyczyszczony.")
    } else if let files = loadCheckFiles {
        print("--- Szacunek vs urządzenie: \(files.count) plików, slot D (.prf2: wszystkie cztery) ---")
        func read(_ area: PatchArea, slot: UInt8 = 3) async -> G2PatchLoad? {
            let notes = NotificationLog()
            await manager.setNotificationHandler { note in notes.append(note) }
            try? await manager.requestPatchLoad(slot: slot, area: area)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await manager.setNotificationHandler(nil)
            return notes.all()
                .filter { $0.note.subCommand == G2UsbProtocol.subResponsePatchLoad && $0.note.slot == slot }
                .flatMap { G2UsbProtocol.decodePatchLoad($0.note.payload) }
                .last { $0.area == area }
        }
        /// Najpierw pusty slot i potwierdzone zera — inaczej odczyt bywa liczbami
        /// poprzedniego patcha (DFAM Plus odczytany jako PERfourMER).
        func clear(slot: UInt8) async throws {
            var empty = G2Patch()
            empty.name = "LoadCheck"
            try await manager.sendPatch(empty, toSlot: slot)
            for _ in 0 ..< 60 {
                try await Task.sleep(nanoseconds: 300_000_000)
                if let voice = await read(.voice, slot: slot),
                   voice.cyclesRed + voice.cyclesBlue + voice.zeroPageMemory == 0 { break }
            }
        }
        /// Odczyt ustala się, gdy dwa kolejne są równe (urządzenie buduje patch kilka sekund).
        func stableLoad(of patch: G2Patch, slot: UInt8) async throws -> [PatchArea: G2PatchLoad] {
            var stable: [PatchArea: G2PatchLoad] = [:]
            for area in [PatchArea.voice, .fx] {
                var last: G2PatchLoad?
                for _ in 0 ..< 40 {
                    try await Task.sleep(nanoseconds: 700_000_000)
                    guard let reading = await read(area, slot: slot) else { continue }
                    let empty = reading.cyclesRed + reading.cyclesBlue + reading.zeroPageMemory == 0
                    if reading.sameCost(as: last), !empty || patch.modules(in: area).isEmpty { break }
                    last = reading
                }
                stable[area] = last
            }
            return stable
        }
        func report(_ name: String, _ patch: G2Patch, _ stable: [PatchArea: G2PatchLoad]) {
            for area in [PatchArea.voice, .fx] {
                let estimate = G2PatchLoad.estimate(area: area, patch: patch)
                guard let device = stable[area] else {
                    print("\(name) \(area): brak odczytu")
                    continue
                }
                // Liczba modułów każdego typu — do wyliczenia dopłat z wielu patchy naraz.
                let types = Dictionary(grouping: patch.modules(in: area), by: \.typeID)
                    .sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value.count)" }.joined(separator: " ")
                let raw = [device.cyclesRed, device.cyclesBlue, device.zeroPageMemory, device.xMemory,
                           device.yMemory, device.programMemory, device.ram, device.qMemory, device.rMemory]
                    .map(String.init).joined(separator: ",")
                print(String(format: "%@ | %@ | szacunek %.1f%% / %.1f%% | urządzenie %.1f%% / %.1f%% | różnica %+.1f / %+.1f | ZP %d / %d | typy %@ | surowe %@",
                             name, area == .voice ? "voice" : "fx",
                             estimate.cyclesPercent, estimate.memoryPercent,
                             device.cyclesPercent, device.memoryPercent,
                             estimate.cyclesPercent - device.cyclesPercent,
                             estimate.memoryPercent - device.memoryPercent,
                             estimate.zeroPageMemory, device.zeroPageMemory, types, raw))
            }
        }
        for path in files where path.hasSuffix(".prf2") {
            // Cały performance jednym zrzutem `0x1A`, jak edytor (`sendCompletePerformance`);
            // `--drop 5f` wysyła go bez mapy gałek całego performance'u.
            guard let data = FileManager.default.contents(atPath: path),
                  let parsed = try? PatchParser.parseFile(data: data),
                  parsed.patches.count == G2UsbProtocol.maxSlots
            else {
                print("⚠️ nie czytam \(path)")
                continue
            }
            let slots = parsed.patches.map { slot -> G2Patch in
                var patch = slot
                patch.fillMissingParameters()
                patch.recomputeUprates()
                return patch
            }
            // Bez samej sekcji `0x5F` urządzenie odrzuca zrzut — `--drop 5f` czyści więc
            // przypisania gałek całego performance'u, a sekcję zostawia.
            var performance = parsed.performance
            if loadCheckDrop.contains(where: { $0.type == 0x5F }) {
                performance?.globalKnobAssignments = Array(repeating: nil, count: G2KnobPages.knobCount)
            }
            let current = try PatchParser.saveAll(originalData: data, patches: slots, performance: performance)
            let header = try PatchParser.performanceSectionStream(fileData: current)
            let streams = try (0 ..< G2UsbProtocol.maxSlots).map {
                try droppingSections(loadCheckDrop, from: PatchParser.slotSectionStream(fileData: current, slot: $0))
            }
            let knobs = try PatchParser.performanceKnobMapStream(fileData: current)
            print("    gałki performance'u: \(performance?.globalKnobAssignments.compactMap { $0 }.count ?? 0)")
            for slot in 0 ..< UInt8(G2UsbProtocol.maxSlots) {
                try await clear(slot: slot)
            }
            try await manager.sendCompletePerformanceDump(
                name: "LoadCheck", headerSection: header,
                slotStreams: streams, knobMapSection: knobs, patches: slots
            )
            await manager.disconnect()
            try await manager.connect()
            let name = (path as NSString).lastPathComponent
            for (index, patch) in slots.enumerated() {
                if let slot = parsed.performance?.slots[index] {
                    print("    [\(index)] enabled \(slot.enabled) keyboard \(slot.keyboard) hold \(slot.hold) "
                        + "range \(slot.keyRangeLow)–\(slot.keyRangeHigh) voices \(patch.description.voices) "
                        + "monopoly \(patch.description.monopoly) variation \(patch.description.variation)")
                }
                let stable = try await stableLoad(of: patch, slot: UInt8(index))
                report("\(name) [\("ABCD".map(String.init)[index])]", patch, stable)
            }
        }
        for path in files where path.hasSuffix(".pch2") {
            guard let data = FileManager.default.contents(atPath: path),
                  let parsed = try? PatchParser.parseFile(data: data),
                  var patch = parsed.patches.first
            else {
                print("⚠️ nie czytam \(path)")
                continue
            }
            // Pełny strumień sekcji jak w edytorze (`--loadfile`): bez niego Nord nie dostaje
            // morfów i gałek — PERfourMER pokazał wtedy 66 zamiast 77 jednostek strony zerowej.
            patch.fillMissingParameters()
            patch.recomputeUprates()
            let all = patch.voiceModules + patch.fxModules
            let strip = loadCheckKeepTypes.isEmpty ? loadCheckStripTypes
                : Set(all.map(\.typeID)).subtracting(loadCheckKeepTypes)
            if !strip.isEmpty {
                let kept = Dictionary(grouping: patch.voiceModules.filter { !strip.contains($0.typeID) }, by: \.typeID)
                print("    voice zostaje: " + kept.keys.sorted().map { "\($0)×\(kept[$0]!.count)" }.joined(separator: " "))
            }
            let stripped = Set(all.filter { strip.contains($0.typeID) }.map { "\($0.area)\($0.id)" })
            patch.voiceModules.removeAll { stripped.contains("\($0.area)\($0.id)") }
            patch.fxModules.removeAll { stripped.contains("\($0.area)\($0.id)") }
            patch.voiceCables.removeAll {
                stripped.contains("voice\($0.sourceConnector.moduleID)")
                    || stripped.contains("voice\($0.destinationConnector.moduleID)")
            }
            patch.fxCables.removeAll {
                stripped.contains("fx\($0.sourceConnector.moduleID)")
                    || stripped.contains("fx\($0.destinationConnector.moduleID)")
            }
            let current = try PatchParser.saveAll(originalData: data, patches: [patch],
                                                  performance: parsed.performance)
            var stream = try PatchParser.slotSectionStream(fileData: current, slot: 0)
            stream = droppingSections(loadCheckDrop, from: stream)
            try await clear(slot: 3)
            try await manager.sendPatch(patch, toSlot: 3, sectionStream: stream)
            // Jak `--loadfile`: bez ponownego połączenia `0x72` po pełnym strumieniu zostawał zerowy.
            await manager.disconnect()
            try await manager.connect()
            try await report((path as NSString).lastPathComponent, patch, stableLoad(of: patch, slot: 3))
        }
    } else if let calibration = dspCalibration {
        guard !fastConnect else {
            print("⛔️ --dspcal nie działa z --fast-connect.")
            await manager.disconnect()
            exit(1)
        }
        let types = ModuleDatabase.all
            .filter { calibration.typeIDs.isEmpty || calibration.typeIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
        let constantType = 43
        print("--- Kalibracja kosztów: \(types.count) typów, slot D / fx ---")

        func module(_ def: ModuleDef, id: Int, uprate: Bool = false) -> G2Module {
            var mod = G2Module(id: id, typeID: def.id, area: .fx)
            let defaults = ModuleDefaultsDatabase.defaults(forTypeID: def.id)
            mod.parameters = defaults.isEmpty ? Array(repeating: 0, count: def.paramNames.count) : defaults
            mod.parameterVariations = Array(repeating: mod.parameters, count: 9)
            mod.modes = Array(repeating: 0, count: def.modeNames.count)
            mod.label = def.shortName
            mod.hasParameterEntry = !mod.parameters.isEmpty
            mod.row = (id - 1) * 8
            mod.uprate = uprate
            return mod
        }

        /// Urządzenie oddaje świeży `0x72` dopiero po zbudowaniu patcha w DSP — wcześniejsze
        /// zapytanie zwraca odczyt poprzedniego, czasem przez kilka sekund. Pierwsze podejście
        /// („czekaj, aż odczyt odejdzie od poprzedniego”) przepuściło takie odczyty (Noise = 0,
        /// dwie sztuki = jedna). Dlatego najpierw pusty slot i czekanie na same zera — wtedy
        /// nieaktualny odczyt to zera, a nie liczby podobne do prawdziwych.
        func send(_ patch: G2Patch) async -> Bool {
            for attempt in 0 ..< 2 {
                do {
                    try await manager.sendPatch(patch, toSlot: 3)
                    return true
                } catch {
                    // Pojedyncza nieprzyjęta komenda się zdarza.
                    if attempt == 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                }
            }
            return false
        }
        func read() async -> G2PatchLoad? {
            let notes = NotificationLog()
            await manager.setNotificationHandler { note in notes.append(note) }
            try? await manager.requestPatchLoad(slot: 3, area: .fx)
            try? await Task.sleep(nanoseconds: 250_000_000)
            await manager.setNotificationHandler(nil)
            return notes.all()
                .filter { $0.note.subCommand == G2UsbProtocol.subResponsePatchLoad && $0.note.slot == 3 }
                .flatMap { G2UsbProtocol.decodePatchLoad($0.note.payload) }
                .last { $0.area == .fx }
        }
        var emptySlot = G2Patch()
        emptySlot.name = "DSPCal"
        let zero = G2PatchLoad(area: .fx, cyclesRed: 0, cyclesBlue: 0, zeroPageMemory: 0, xMemory: 0,
                               yMemory: 0, programMemory: 0, ram: 0, qMemory: 0, rMemory: 0)
        /// Próba 2026-10-27 przy obciążonym Macu: 3 z 27 odczytów przepadły, jeden wrócił
        /// samymi zerami (X-Fade z uprate). Zera przyjmujemy dopiero za trzecim razem —
        /// tylko trzy darmowe typy (Name, CtrlSend, PCSend) naprawdę je dają.
        func measure(_ patch: G2Patch) async throws -> G2PatchLoad? {
            for attempt in 0 ..< 3 {
                guard let reading = try await measureOnce(patch) else { continue }
                if !reading.sameCost(as: zero) || attempt == 2 { return reading }
            }
            return nil
        }
        /// Bez potwierdzonych zer nie mierzymy: pełny przebieg 2026-10-27 przy obciążonym Macu
        /// dał X-Fade „z uprate” z liczbami poprzedniego patcha (dwie sztuki), bo 6 s czekania
        /// na pusty slot nie wystarczyło i pomiar poszedł dalej.
        func measureOnce(_ patch: G2Patch) async throws -> G2PatchLoad? {
            guard await send(emptySlot) else { return nil }
            var cleared = false
            for _ in 0 ..< 60 where !cleared {
                try await Task.sleep(nanoseconds: 300_000_000)
                cleared = await read()?.sameCost(as: zero) == true
            }
            guard cleared, await send(patch) else { return nil }
            var last: G2PatchLoad?
            for attempt in 0 ..< 20 {
                try await Task.sleep(nanoseconds: 500_000_000)
                guard let reading = await read() else { continue }
                // Zera po pustym slocie to jeszcze stary odczyt; moduł naprawdę darmowy
                // (Name, CtrlSend…) przepuszczamy dopiero po kilku sekundach.
                let fresh = !reading.sameCost(as: zero) || attempt >= 10
                if fresh, reading.sameCost(as: last) { return reading }
                last = reading
            }
            return last
        }

        var rows = ["kind,typeID,shortName,input,cycles_red,cycles_blue,xmem,ymem,pmem,zpmem,ram,qmem,rmem"]
        func record(_ kind: String, _ def: ModuleDef, _ input: Int, _ load: G2PatchLoad?) {
            guard let load else {
                print("    ⚠️ \(def.shortName) \(kind) \(input): brak odczytu")
                return
            }
            rows.append("\(kind),\(def.id),\(def.shortName),\(input),\(load.cyclesRed),\(load.cyclesBlue),"
                + "\(load.xMemory),\(load.yMemory),\(load.programMemory),\(load.zeroPageMemory),"
                + "\(load.ram),\(load.qMemory),\(load.rMemory)")
            print("    \(kind) \(input): \(load.cyclesRed)/\(load.cyclesBlue) ZP \(load.zeroPageMemory) "
                + "Pm \(load.programMemory) Xm \(load.xMemory) Ym \(load.yMemory)")
        }
        func save() {
            try? rows.joined(separator: "\n").appending("\n")
                .write(toFile: calibration.path, atomically: true, encoding: .utf8)
        }

        guard let constant = ModuleDatabase.module(id: constantType) else { exit(1) }
        var alone = G2Patch()
        alone.name = "DSPCal"
        alone.add(module: module(constant, id: 1))
        try await record("single", constant, -1, measure(alone))

        // Pierwszy przebieg (2026-10-27, 13 typów) potwierdził dwie reguły, więc ich już nie
        // mierzymy: druga sztuka kosztuje tyle co pierwsza, a uprate przenosi cały zegar „blue”
        // na „red” (także dopłaty za wejścia). Zostaje koszt modułu i jego podłączonych wejść —
        // najpierw wszystkie naraz; po jednym tylko wtedy, gdy to cokolwiek zmieniło.
        func wired(_ def: ModuleDef, inputs: [Int]) -> G2Patch {
            var patch = G2Patch()
            patch.name = "DSPCal"
            patch.add(module: module(def, id: 1))
            patch.add(module: module(constant, id: 2))
            for input in inputs {
                patch.add(cable: G2Cable(fromModule: 2, fromConnector: 0, toModule: 1, toConnector: input,
                                         color: .blue, area: .fx))
            }
            return patch
        }
        // `--prefix`: wejścia 0…k podłączone naraz, dla k = 1…n−2. Pełny przebieg 2026-10-28
        // pokazał, że dopłaty się nie sumują (OscB: Pitch +19, PitchVar +19, oba razem +19;
        // Mix4-1B: każde +3, cztery +6) — przyrosty kolejnych wejść mówią, które dzielą koszt.
        // `--uprate`: moduł sam i ze wszystkimi wejściami, oba z flagą uprate — dla typów
        // z wejściem dwukolorowym. Sprawdzenie na 40 patchach (2026-10-28) pokazało, że reguła
        // „cały blue → red” zawyża obwiednie (Bassic FM4: +12 pkt), choć trzyma dla OscB i X-Fade.
        // `--modes plik.csv` (wiersze typeID,mode,value): moduł sam z jednym trybem ustawionym
        // inaczej niż domyślnie. Sprawdzenie na 40 patchach (2026-10-28): Plasma fx — szacunek
        // 12,8 % pamięci, urządzenie 55,4 %, bo DlySingleB z zakresem 1.0s rezerwuje większy bufor.
        // Zapis: `input` = numer trybu × 100 + wartość.
        if let index = args.firstIndex(of: "--modes"), index + 1 < args.count,
           let text = try? String(contentsOfFile: args[index + 1], encoding: .utf8)
        {
            let wanted = text.split(separator: "\n").dropFirst().compactMap { line -> (Int, Int, Int)? in
                let parts = line.split(separator: ",").compactMap { Int($0) }
                return parts.count >= 3 ? (parts[0], parts[1], parts[2]) : nil
            }
            for (typeID, mode, value) in wanted {
                guard let def = ModuleDatabase.module(id: typeID), def.modeNames.indices.contains(mode) else { continue }
                print("\(def.id) \(def.shortName) tryb \(mode) = \(value)")
                var patch = G2Patch()
                patch.name = "DSPCal"
                var mod = module(def, id: 1)
                mod.modes[mode] = value
                patch.add(module: mod)
                try await record("mode", def, mode * 100 + value, measure(patch))
                save()
            }
            var empty = G2Patch()
            empty.name = "DSPCal"
            try? await manager.sendPatch(empty, toSlot: 3)
            print("\n--- Zapisane: \(calibration.path) (\(rows.count - 1) pomiarów) ---")
            await manager.disconnect()
            exit(0)
        }
        if args.contains("--uprate") {
            for (index, def) in types.enumerated() {
                guard def.inputs.contains(where: { $0.color == .pitchOrControl || $0.color == .logicOrControl })
                else { continue }
                print("[\(index + 1)/\(types.count)] \(def.id) \(def.shortName) — uprate")
                var up = G2Patch()
                up.name = "DSPCal"
                up.add(module: module(def, id: 1, uprate: true))
                try await record("uprate", def, -1, measure(up))
                var wiredUp = wired(def, inputs: Array(def.inputs.indices))
                wiredUp.fxModules = wiredUp.fxModules.map { var mod = $0
                    mod.uprate = mod.id == 1
                    return mod
                }
                try await record("allInputsUprate", def, -1, measure(wiredUp))
                save()
            }
            var empty = G2Patch()
            empty.name = "DSPCal"
            try? await manager.sendPatch(empty, toSlot: 3)
            print("\n--- Zapisane: \(calibration.path) (\(rows.count - 1) pomiarów) ---")
            await manager.disconnect()
            exit(0)
        }
        if args.contains("--prefix") {
            for (index, def) in types.enumerated() {
                print("[\(index + 1)/\(types.count)] \(def.id) \(def.shortName) — przyrosty")
                for last in Array(def.inputs.indices).dropFirst().dropLast() {
                    try await record("prefix", def, last, measure(wired(def, inputs: Array(0 ... last))))
                }
                save()
            }
            var empty = G2Patch()
            empty.name = "DSPCal"
            try? await manager.sendPatch(empty, toSlot: 3)
            print("\n--- Zapisane: \(calibration.path) (\(rows.count - 1) pomiarów) ---")
            await manager.disconnect()
            exit(0)
        }
        for (index, def) in types.enumerated() {
            print("[\(index + 1)/\(types.count)] \(def.id) \(def.shortName)")
            var one = G2Patch()
            one.name = "DSPCal"
            one.add(module: module(def, id: 1))
            let single = try await measure(one)
            record("single", def, -1, single)
            guard let single, !def.inputs.isEmpty else {
                save()
                continue
            }
            let all = try await measure(wired(def, inputs: Array(def.inputs.indices)))
            record("allInputs", def, -1, all)
            let constantZP = 1
            let unchanged = all.map {
                $0.zeroPageMemory == single.zeroPageMemory + constantZP
                    && $0.sameCost(as: G2PatchLoad(area: .fx, cyclesRed: single.cyclesRed,
                                                   cyclesBlue: single.cyclesBlue, zeroPageMemory: $0.zeroPageMemory,
                                                   xMemory: single.xMemory, yMemory: single.yMemory,
                                                   programMemory: single.programMemory, ram: single.ram,
                                                   qMemory: single.qMemory, rMemory: single.rMemory))
            } ?? false
            if !unchanged {
                for input in def.inputs.indices {
                    try await record("input", def, input, measure(wired(def, inputs: [input])))
                }
            }
            save()
        }

        var empty = G2Patch()
        empty.name = "DSPCal"
        try? await manager.sendPatch(empty, toSlot: 3)
        save()
        print("\n--- Zapisane: \(calibration.path) (\(rows.count - 1) pomiarów) ---")
    } else if let typeIDs = hiddenTypeIDs {
        guard !fastConnect else {
            print("⛔️ --hidden potrzebuje odczytu slotów — uruchom bez --fast-connect.")
            await manager.disconnect()
            exit(1)
        }
        let slot: UInt8 = 3
        print("\n=== UKRYTE MODUŁY — czy Nord je przyjmie? (slot D, bufor edycji) ===")
        print("Reguła: werdykt wydaje ODCZYT slotu, nie odpowiedź OK.\n")

        var verdicts: [String] = []
        for typeID in typeIDs {
            let known = ModuleDatabase.all.first { $0.id == typeID }
            let label = known.map { "\($0.shortName) (OFICJALNY)" } ?? "nieudokumentowany"
            print("--- typeID \(typeID) — \(label) ---")

            // Czysty slot, żeby wynik nie mieszał się z poprzednim modułem.
            var empty = G2Patch()
            empty.name = "HiddenTest"
            try? await manager.sendPatch(empty, toSlot: slot)

            var probe = G2Module(id: 1, typeID: typeID, area: .fx)
            probe.column = 0
            probe.row = 0
            probe.label = "HID\(typeID)"
            probe.modes = []
            let version = await manager.slotVersion(slot)
            let payload = G2UsbProtocol.addModulePayload(slot: slot, version: version, module: probe)

            var answer = "brak odpowiedzi"
            do {
                let capture = try await manager.diagnoseCommand(
                    name: "AddModule typeID \(typeID)", payload: payload, listenSeconds: 1.0
                )
                for response in capture.responses where !G2UsbProtocol.isUnsolicited(response) {
                    switch response.subCommand {
                    case G2UsbProtocol.subResponseOK: answer = "OK (0x7F)"
                    case G2UsbProtocol.subResponseError: answer = "ERROR (0x7E)"
                    default: break
                    }
                }
            } catch {
                answer = "wysyłka padła — \(error)"
            }

            // Świeże połączenie = świeży odczyt slotu prosto z urządzenia.
            await manager.disconnect()
            do {
                try await manager.connect()
            } catch {
                print("  ⛔️ urządzenie przestało odpowiadać po typeID \(typeID): \(error)")
                verdicts.append("\(typeID): URZĄDZENIE PRZESTAŁO ODPOWIADAĆ")
                break
            }
            let after = await manager.patches[Int(slot)]
            let survivor = after.modules(in: .fx).first { $0.typeID == typeID }

            if let survivor {
                let verdict = "✅ ZOSTAJE — params \(survivor.parameters.count), modes \(survivor.modes.count)"
                print("  odpowiedź: \(answer)")
                print("  \(verdict), etykieta \"\(survivor.label)\"")
                verdicts.append("\(typeID) \(label): \(verdict)")
            } else {
                let others = after.modules(in: .fx).map { String($0.typeID) }.joined(separator: ", ")
                let verdict = others.isEmpty
                    ? "❌ ZNIKA — slot pusty po dodaniu"
                    : "⚠️ ZAMIENIONY — w slocie siedzi typeID \(others)"
                print("  odpowiedź: \(answer)")
                print("  \(verdict)")
                verdicts.append("\(typeID) \(label): \(verdict)")
            }
        }

        var cleanup = G2Patch()
        cleanup.name = "HiddenTest"
        try? await manager.sendPatch(cleanup, toSlot: slot)
        print("\n=== PODSUMOWANIE ===")
        for line in verdicts {
            print("  \(line)")
        }
        print("\nSlot D wyczyszczony. Dźwięku ta sonda NIE sprawdza — to trzeba usłyszeć.")
    } else if let cost = dspCostArgument {
        // Ile zasobów kosztuje JEDEN typ modułu. Patch idzie do slotu D i tylko do bufora
        // edycji — banków we flashu to nie dotyka, więc próba jest odwracalna.
        //
        // ⛔️ Bez `--fast-connect`, i to nie z ostrożności. `sendPatch` czyści slot, kasując
        // to, co ODCZYTAŁ z urządzenia przy handshake; przy `--fast-connect` sloty nie są
        // czytane, więc kasować nie ma czego. Patch wtedy nie zastępuje zawartości, tylko
        // **nadpisuje moduły o tych samych id i zostawia resztę** — a pomiar wychodzi z
        // mieszanki starego i nowego, wyglądając całkiem wiarygodnie (zmierzone 2026-09-08).
        guard !fastConnect else {
            print("""
            ⛔️ --dspcost nie działa z --fast-connect: slot nie zostałby wyczyszczony przed
               wgraniem, a pomiar objąłby resztki poprzedniego patcha. Uruchom bez tej flagi.
            """)
            await manager.disconnect()
            exit(1)
        }
        let matches = ModuleDatabase.all.filter {
            $0.shortName.lowercased().contains(cost.query.lowercased())
                || $0.longName.lowercased().contains(cost.query.lowercased())
                || String($0.id) == cost.query
        }
        guard let def = matches.first(where: { String($0.id) == cost.query }) ?? matches.first else {
            print("Nie znam modułu \(cost.query). Podaj typeID albo fragment nazwy.")
            await manager.disconnect()
            exit(1)
        }
        if matches.count > 1, String(def.id) != cost.query {
            print("Pasuje \(matches.count) typów — biorę pierwszy. Reszta:")
            for other in matches.dropFirst().prefix(12) {
                print("    \(other.id)  \(other.shortName) — \(other.longName) [\(other.page)]")
            }
        }

        var patch = G2Patch()
        patch.name = "DSPCost"
        let defaults = ModuleDefaultsDatabase.defaults(forTypeID: def.id)
        for index in 0 ..< cost.count {
            var mod = G2Module(id: index + 1, typeID: def.id, area: cost.area)
            // Kolumny po pięć modułów — pozycja nie wpływa na zasoby, ale patch, którego
            // nie da się obejrzeć na ekranie Norda, trudniej sprawdzić oczami.
            mod.column = index / 5
            mod.row = (index % 5) * max(def.height, 1)
            mod.parameters = defaults.isEmpty ? Array(repeating: 0, count: def.paramNames.count) : defaults
            mod.parameterVariations = Array(repeating: mod.parameters, count: 9)
            mod.modes = Array(repeating: 0, count: def.modeNames.count)
            mod.label = "\(def.shortName)\(index + 1)"
            mod.hasParameterEntry = !mod.parameters.isEmpty
            patch.add(module: mod)
        }

        print("\n--- \(cost.count) × \(def.shortName) (typeID \(def.id), \(def.page)) → slot D / \(cost.area) ---")
        do {
            try await manager.sendPatch(patch, toSlot: 3)
        } catch {
            print("❌ wysyłka nie doszła: \(error)")
            await manager.disconnect()
            exit(1)
        }

        let notes = NotificationLog()
        await manager.setNotificationHandler { note in notes.append(note) }
        for area in [PatchArea.voice, PatchArea.fx] {
            try? await manager.requestPatchLoad(slot: 3, area: area)
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        await manager.setNotificationHandler(nil)

        var latest: [PatchArea: G2PatchLoad] = [:]
        for entry in notes.all() where entry.note.subCommand == G2UsbProtocol.subResponsePatchLoad
            && entry.note.slot == 3
        {
            for reading in G2UsbProtocol.decodePatchLoad(entry.note.payload) {
                latest[reading.area] = reading
            }
        }
        if latest.isEmpty {
            print("❌ slot D nie odpowiedział raportem 0x72.")
        }
        for area in [PatchArea.voice, PatchArea.fx] {
            guard let load = latest[area] else { continue }
            let critical = load.criticalResource
            print("    \(area): cycles \(load.cyclesRed)/\(load.cyclesBlue) "
                + "· Xmem \(load.xMemory) Ymem \(load.yMemory) Pmem \(load.programMemory) "
                + "ZPmem \(load.zeroPageMemory) · RAM \(load.ram) Qmem \(load.qMemory) Rmem \(load.rMemory)")
            print(String(format: "        → moc %.1f%%, pamięć %.1f%% (%@ %d/%d)",
                         load.cyclesPercent, load.memoryPercent,
                         critical.resource.label, critical.used, critical.limit))
            if cost.count > 0, area == cost.area {
                let per = { (total: Int) in String(format: "%.1f", Double(total) / Double(cost.count)) }
                print("        na moduł: cycles \(per(load.cyclesRed))/\(per(load.cyclesBlue)) "
                    + "· Xmem \(per(load.xMemory)) Ymem \(per(load.yMemory)) Pmem \(per(load.programMemory)) "
                    + "ZPmem \(per(load.zeroPageMemory)) Qmem \(per(load.qMemory)) Rmem \(per(load.rMemory))")
            }
        }
        print("\n⚠️ Slot D trzyma teraz patch testowy. Wyłączenie Norda przywraca zawartość z flasha.")
    } else if let wanted = setPerformanceNameArgument {
        // Nazwa performance'u DO urządzenia (`0x29` Performance Name Dump). Werdykt bierze
        // się z ODCZYTU nagłówka po wysyłce, nie z `OK` → [[Docs/usb/slots]].
        let before = try? await manager.readPerformanceHeader()
        print("przed:  \"\(before?.name ?? "?")\"")
        do {
            try await manager.setPerformanceName(wanted)
        } catch {
            print("❌ komenda 0x29 odrzucona: \(error)")
        }
        let after = try? await manager.readPerformanceHeader()
        let got = after?.name ?? "?"
        let expected = String(wanted.prefix(G2UsbProtocol.performanceNameLength))
        print("po:     \"\(got)\"")
        print(got == expected
            ? "✅ Nord przyjął nazwę. Sprawdź jeszcze wyświetlacz na froncie."
            : "❌ nazwa się NIE zmieniła (oczekiwano \"\(expected)\").")
    } else if args.contains("--perfheadertest") {
        // Zapis CAŁEJ sekcji 0x11 (Performance Header Dump). Jedyne pola, których nie
        // wysyła nic innego, to Hold i zakres klawiszy slotu — na nich mierzymy skutek.
        // Test jest odwracalny: na koniec odsyłamy sekcję dokładnie taką, jaka była.
        guard let before = try? await manager.readPerformanceHeader() else {
            print("❌ nie udało się odczytać nagłówka performance'u — nie ma czego zmieniać")
            await manager.disconnect()
            exit(1)
        }
        let originalLow = before.settings.slots[0].keyRangeLow
        let probeLow = originalLow == 36 ? 48 : 36
        print("slot A: Hold \(before.settings.slots[0].hold ? "TAK" : "nie"), "
            + "zakres klawiszy \(originalLow)…\(before.settings.slots[0].keyRangeHigh)")

        var changed = before.settings
        changed.slots[0].keyRangeLow = probeLow
        guard let section = PatchParser.performanceHeaderSection(originalSection: before.section,
                                                                 performance: changed)
        else {
            print("❌ nie umiem przepisać tej sekcji — układ inny niż opisany")
            await manager.disconnect()
            exit(1)
        }
        do {
            try await manager.setPerformanceHeader(section: section)
        } catch {
            print("❌ komenda 0x11 odrzucona: \(error)")
        }
        let after = try? await manager.readPerformanceHeader()
        let got = after?.settings.slots[0].keyRangeLow
        print("po zapisie: dolny zakres klawiszy slotu A = \(got.map(String.init) ?? "?") "
            + "(wysłano \(probeLow))")
        print(got == probeLow
            ? "✅ Nord przyjął sekcję 0x11."
            : "❌ sekcja 0x11 NIE zadziałała — pole się nie zmieniło.")

        print("\n--- Przywracam pierwotną sekcję ---")
        do {
            try await manager.setPerformanceHeader(section: before.section)
            let restored = try? await manager.readPerformanceHeader()
            print(restored?.settings.slots[0].keyRangeLow == originalLow
                ? "✅ Zakres klawiszy wrócił do \(originalLow)."
                : "⚠️ NIE udało się przywrócić zakresu klawiszy — popraw go w Performance Settings.")
        } catch {
            print("⚠️ przywracanie nie powiodło się: \(error)")
        }
    } else if args.contains("--perfheaderrules") {
        // Czy sama sekcja `0x11` wystarczy, żeby ustawić TO, co dziś wysyłamy dodatkowo
        // przez `0x07`/`0x0F` (sloty) i `0x3F` (zegar)? Oryginał innej drogi przy wgrywaniu
        // performance'u nie ma — nagłówek niesie te pola i nic ich potem nie powtarza.
        // Tu nie wysyłamy NICZEGO poza nagłówkiem, więc każda zmiana widoczna w odczycie
        // jest jego zasługą. Test jest odwracalny: na koniec wraca pierwotna sekcja.
        guard let before = try? await manager.readPerformanceHeader() else {
            print("❌ nie udało się odczytać nagłówka performance'u — nie ma czego zmieniać")
            await manager.disconnect()
            exit(1)
        }
        if let clock = try? await manager.readClockInfo(), clock.external {
            print("⚠️ zegar ZEWNĘTRZNY — tempa Nord i tak nie przyjmie; werdykt dotyczy tylko slotów")
        }
        let wasEnabled = before.settings.slots.map(\.enabled)
        let wasKeyboard = before.settings.slots.map(\.keyboard)
        let wasBPM = before.settings.masterClock
        // Wyciszamy slot, który GRA, zamiast włączać milczący — ciszej i bezpieczniej
        // dla podłączonego wzmacniacza. Gdy nie gra żaden, nie ma wyjścia.
        let target = wasEnabled.firstIndex(of: true) ?? 0
        print("stan przed: slot \(slotLabel(target)) \(wasEnabled[target] ? "GRA" : "cisza"), "
            + "klawiatura \(wasKeyboard[target] ? "TAK" : "nie"), zegar \(wasBPM) BPM")

        var changed = before.settings
        changed.slots[target].enabled = !wasEnabled[target]
        changed.slots[target].keyboard = !wasKeyboard[target]
        changed.masterClock = wasBPM == 100 ? 120 : 100
        guard let section = PatchParser.performanceHeaderSection(originalSection: before.section,
                                                                 performance: changed)
        else {
            print("❌ nie umiem przepisać tej sekcji — układ inny niż opisany")
            await manager.disconnect()
            exit(1)
        }
        do {
            try await manager.setPerformanceHeader(section: section)
        } catch {
            print("❌ komenda 0x11 odrzucona: \(error)")
        }

        let after = try? await manager.readPerformanceHeader()
        func verdict(_ label: String, _ got: String?, _ expected: String) -> Bool {
            let ok = got == expected
            print("    \(ok ? "✅" : "❌") \(label): odczyt \(got ?? "?"), wysłano \(expected)")
            return ok
        }
        print("po zapisie SAMEGO nagłówka:")
        let slotsOK = verdict("slot \(slotLabel(target)) gra",
                              after.map { $0.settings.slots[target].enabled ? "TAK" : "nie" },
                              changed.slots[target].enabled ? "TAK" : "nie")
            && verdict("slot \(slotLabel(target)) klawiatura",
                       after.map { $0.settings.slots[target].keyboard ? "TAK" : "nie" },
                       changed.slots[target].keyboard ? "TAK" : "nie")
        let clockOK = verdict("zegar", after.map { String($0.settings.masterClock) },
                              String(changed.masterClock))
        print(slotsOK && clockOK
            ? "\n✅ Sama sekcja 0x11 ustawia sloty I zegar — 0x07/0x0F/0x3F przy wgrywaniu performance'u są zbędne."
            : "\n⚠️ Nagłówek NIE ustawia wszystkiego — zostawiamy dotychczasową drogę dla tego, co nie przeszło.")
        print("Zerknij na diody slotów na froncie: mają pokazywać to samo co odczyt wyżej.")

        print("\n--- Przywracam pierwotną sekcję ---")
        do {
            try await manager.setPerformanceHeader(section: before.section)
            let restored = try? await manager.readPerformanceHeader()
            print(restored?.settings.slots.map(\.enabled) == wasEnabled
                && restored?.settings.masterClock == wasBPM
                ? "✅ Sloty i zegar wróciły do stanu sprzed testu."
                : "⚠️ NIE udało się przywrócić stanu — popraw sloty i tempo na froncie Norda.")
        } catch {
            print("⚠️ przywracanie nie powiodło się: \(error)")
        }
    } else if let path = uploadRulesPath {
        // Co Nord robi SAM po `0x37`, gdy nikt nie dosyła selekcji slotów (`0x07`/`0x0F`)?
        // Clavia po wgraniu `.pch2` nie wysyła nic poza `0x09` + `0x37` i zapytaniami — my
        // dokładamy selekcję z pamięci podręcznej. Tu: slot docelowy najpierw wyciszony
        // i bez klawiatury, potem samo `0x37` i odczyt nagłówka. Na koniec zapytania Clavii
        // (`0x71` ×2, `0x70`, `0x04`, `0x3B`) z zapisem odpowiedzi. Test odwracalny: kopia
        // slotu wraca tą samą drogą, a selekcja do stanu sprzed testu.
        let slot = slotArgument("--slot") ?? 3
        let letter = slotLabel(Int(slot))
        let mode: Bool? = await (try? manager.readPerformanceMode()) ?? nil
        print("\n--- UPLOADRULES slot \(letter): \(path) ---")
        print(mode.map { $0 ? "tryb: PERFORMANCE" : "tryb: PATCH" } ?? "tryb: nie udało się odczytać")
        guard let before = try? await manager.readPerformanceHeader() else {
            print("❌ nie udało się odczytać nagłówka performance'u")
            await manager.disconnect()
            exit(1)
        }
        let wasEnabled = before.settings.slots.map(\.enabled)
        let wasKeyboard = before.settings.slots.map(\.keyboard)
        func describe(_ enabled: [Bool], _ keyboard: [Bool]) -> String {
            (0 ..< G2UsbProtocol.maxSlots).map {
                "\(slotLabel($0)):\(enabled[$0] ? "gra" : "—")\(keyboard[$0] ? "+kb" : "")"
            }.joined(separator: "  ")
        }
        print("przed testem:      \(describe(wasEnabled, wasKeyboard))")

        let original = patches[Int(slot)]
        let backupData = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [original])
        let backupStream = try PatchParser.slotSectionStream(fileData: backupData, slot: 0)

        // Slot docelowy cichy i bez klawiatury; grać i słuchać klawiatury musi inny slot,
        // bo Nord nie przyjmie selekcji bez żadnego grającego.
        var silent = wasEnabled
        var silentKeys = wasKeyboard
        silent[Int(slot)] = false
        silentKeys[Int(slot)] = false
        let other = Int(slot) == 0 ? 1 : 0
        if !silent.contains(true) { silent[other] = true }
        if !silentKeys.contains(true) { silentKeys[silent.firstIndex(of: true) ?? other] = true }
        try await manager.setSlotSelection(silent, keyboard: silentKeys)
        if let set = try? await manager.readPerformanceHeader() {
            print("slot wyciszony:    \(describe(set.settings.slots.map(\.enabled), set.settings.slots.map(\.keyboard)))")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var patch = try PatchParser.parseFile(data: data).patches.first ?? G2Patch()
        patch.fillMissingParameters()
        let current = try PatchParser.saveAll(originalData: data, patches: [patch])
        let stream = try PatchParser.slotSectionStream(fileData: current, slot: 0)
        if patch.name.isEmpty { patch.name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }

        let notes = NotificationLog()
        await manager.setNotificationHandler { note in notes.append(note) }
        try await manager.sendPatch(patch, toSlot: slot, sectionStream: stream)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let spontaneous = notes.all().filter { $0.note.subCommand == G2UsbProtocol.subResponsePatchLoad }
        print("po samym 0x37: 0x72 samo z siebie × \(spontaneous.count)"
            + spontaneous.map { " [slot \($0.note.slot): \(hexString($0.note.payload))]" }.joined())

        let after = try? await manager.readPerformanceHeader()
        let gotEnabled = after?.settings.slots.map(\.enabled) ?? []
        let gotKeyboard = after?.settings.slots.map(\.keyboard) ?? []
        if gotEnabled.count == G2UsbProtocol.maxSlots, gotKeyboard.count == G2UsbProtocol.maxSlots {
            print("po samym 0x37:     \(describe(gotEnabled, gotKeyboard))")
            print(gotEnabled[Int(slot)]
                ? "    ✅ Nord SAM zapalił slot \(letter)"
                : "    ❌ slot \(letter) dalej wyciszony — selekcję trzeba dosyłać")
            print(gotKeyboard[Int(slot)]
                ? "    ✅ Nord SAM dał slotowi \(letter) klawiaturę"
                : "    ⚠️ slot \(letter) BEZ klawiatury — tego Nord sam nie robi")
            print(gotEnabled.enumerated().allSatisfy { $0.offset == Int(slot) || $0.element == silent[$0.offset] }
                ? "    ✅ pozostałe sloty nietknięte"
                : "    ⚠️ pozostałe sloty zmieniły stan")
        } else {
            print("❌ nie udało się odczytać nagłówka po wgraniu")
        }
        // Nuty `0x56` trafiają tam, gdzie klawisze Norda — do slotów z klawiaturą. Bez
        // klawiatury na slocie docelowym zagra inny slot, i właśnie to ma usłyszeć ucho.
        print("👂 Gram C-E-G (po 1,5 s): słychać patch ze slotu \(letter) czy inny?")
        for note: UInt8 in [60, 64, 67] {
            try await manager.playNote(note, on: true)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try await manager.playNote(note, on: false)
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        print("\n--- Zapytania Clavii po wgraniu ---")
        let version = await manager.slotVersion(slot)
        let queries: [(String, [UInt8])] = [
            ("0x71 voice", G2UsbProtocol.patchLoadRequestPayload(slot: slot, version: version, area: .voice)),
            ("0x71 fx", G2UsbProtocol.patchLoadRequestPayload(slot: slot, version: version, area: .fx)),
            ("0x70 FlushBlink — patrz na diody", [0x01, 0x28 + slot, version, 0x70]),
            ("0x04 NumberOfVoices", [0x01, 0x2C, 0x41, 0x04]),
            ("0x3B ClockInfo", G2UsbProtocol.clockInfoRequestPayload()),
        ]
        for (name, payload) in queries {
            let capture = try await manager.diagnoseCommand(name: name, payload: payload, listenSeconds: 1.5)
            let replies = capture.responses.map { String(format: "0x%02X", $0.subCommand ?? 0) + " " + hexString($0.payload) }
            print("  \(name) [\(hexString(payload))] → \(replies.isEmpty ? "cisza" : replies.joined(separator: " | "))")
        }
        await manager.setNotificationHandler(nil)

        print("\n--- Przywracam slot \(letter) i selekcję ---")
        do {
            // `diagnoseCommand` czyta oba punkty końcowe na surowo i potrafi rozerwać parę
            // zapowiedź/dane — świeże połączenie przed przywracaniem (pierwszy przebieg
            // 2026-10-24 bez niego: „did not acknowledge selecting slot 3").
            await manager.disconnect()
            try await manager.connect(readPatches: false)
            try await manager.sendPatch(original, toSlot: slot, sectionStream: backupStream.isEmpty ? nil : backupStream)
            try await manager.setSlotSelection(wasEnabled, keyboard: wasKeyboard)
            let restored = try? await manager.readPerformanceHeader()
            print(restored?.settings.slots.map(\.enabled) == wasEnabled
                && restored?.settings.slots.map(\.keyboard) == wasKeyboard
                ? "✅ Selekcja wróciła: \(describe(wasEnabled, wasKeyboard)); w slocie \(letter) znów \"\(original.name)\""
                : "⚠️ Selekcja NIE wróciła — popraw sloty na froncie Norda.")
        } catch {
            print("⚠️ przywracanie nie powiodło się: \(error)")
        }
    } else if args.contains("--perf") {
        // Tylko odczyt: co urządzenie mówi o swoim performance. Do porównania z diodami
        // na froncie — stąd bierze się niebieskie tło i czerwona kreska przycisków slotów
        // w edytorze (`DeviceConnection.devicePerformance`) → [[Docs/usb/slots]].
        let mode: Bool? = await (try? manager.readPerformanceMode()) ?? nil
        print(mode.map { $0 ? "tryb: PERFORMANCE" : "tryb: PATCH (gra jeden slot)" }
            ?? "tryb: nie udało się odczytać")
        if let header = try? await manager.readPerformanceHeader() {
            print("performance \"\(header.name)\", focus na slocie \(slotLabel(header.settings.focusedSlot))")
            for (index, slot) in header.settings.slots.enumerated() {
                print("    \(slotLabel(index)): \(slot.enabled ? "GRA  " : "cisza") "
                    + "klawiatura \(slot.keyboard ? "TAK" : "nie") "
                    + "bank \(slot.bank + 1) patch \(slot.patch + 1) \"\(slot.name)\"")
            }
            print("    zegar główny: \(header.settings.masterClock) BPM, "
                + "\(header.settings.masterClockRunning ? "CHODZI" : "stoi")")
            print("\nPorównaj z Nordem: GRA = slot ze świecącą diodą na froncie.")
        } else {
            print("❌ nie udało się odczytać nagłówka performance'u")
        }
        // Stan zegara to OSOBNE pytanie (0x3B → 0x5D): nagłówek niesie tempo własne
        // urządzenia, a nie to, czy akurat idzie za zegarem zewnętrznym.
        if let clock = try? await manager.readClockInfo() {
            print(clock.external
                ? "zegar ZEWNĘTRZNY (MIDI clock), tempo \(clock.bpm) — tempa nie da się zmienić z edytora"
                : "zegar wewnętrzny, tempo z komunikatu \(clock.bpm)")
        } else {
            print("❌ nie udało się odczytać stanu zegara (0x3B)")
        }
    } else if args.contains("--slottest") {
        // Rozstrzyga, czym naprawdę przestawia się slot NA FRONCIE Norda. Stan wiedzy:
        // 0x07 (selekcja) + 0x0F (klawiatura) + 0x09 (focus) dostają `OK` i nie ruszają
        // diod. Kandydaci na przyczynę: zły bajt „wersji" (trzeci w ramce — dla nagłówka
        // performance'u ma znaczenie!) albo tryb Patch zamiast Performance (w trybie Patch
        // gra jeden slot i selekcja nie ma czym sterować) → [[Docs/usb/slots]].
        //
        // Obserwacja należy do CZŁOWIEKA: patrz na diody slotów Norda.
        let notes = NotificationLog()
        await manager.setNotificationHandler { note in notes.append(note) }

        print("\n=== Krok 1: co Nord mówi o sobie ===")
        let mode: Bool? = await (try? manager.readPerformanceMode()) ?? nil
        if let mode {
            print(mode
                ? "    tryb: PERFORMANCE (cztery sloty razem)"
                : "    tryb: PATCH — gra jeden slot, selekcja nie ma czym sterować")
        } else {
            print("    tryb: nie udało się odczytać")
        }
        if let header = try? await manager.readPerformanceHeader() {
            print("    performance \"\(header.name)\", focus na slocie \(Character(UnicodeScalar(UInt8(65 + min(max(header.settings.focusedSlot, 0), 3)))))")
            for (index, slot) in header.settings.slots.enumerated() {
                print("    \(Character(UnicodeScalar(UInt8(65 + index)))): \(slot.enabled ? "GRA  " : "cisza") klawiatura \(slot.keyboard ? "TAK" : "nie") bank \(slot.bank + 1) patch \(slot.patch + 1) \"\(slot.name)\"")
            }
        } else {
            print("    ❌ nie udało się odczytać nagłówka performance'u")
        }

        // Bajt „wersji" ramki. Dla nagłówka performance'u działa tylko 0x41, więc dla
        // komend slotowych też sprawdzamy kilka wartości — w tym tę, którą bierze g2ools
        // (bajt z odpowiedzi na `Start`).
        // ROZSTRZYGNIĘTE na sprzęcie 2026-09-04: bajt wersji `0x00` (ten z G2-Edita) jest
        // martwy — urządzenie kwituje komendę `OK` i nie robi nic. `0x41`, `0x7F` i `0x01`
        // działają. Zostaje więc pełny obchód czterech slotów wersją, której używamy
        // w aplikacji, i jedna próba kontrolna `0x00` jako dowód → [[Docs/usb/slots]].
        let workingVersion: UInt8 = 0x41

        /// Jeden slot: selekcja + focus + flush, potem werdykt odczytany Z URZĄDZENIA.
        @discardableResult
        func selectAndVerify(_ slot: UInt8, version: UInt8) async -> Bool {
            let letter = Character(UnicodeScalar(65 + slot))
            let flags = (0 ..< 4).map { $0 == Int(slot) }
            do {
                try await manager.withPollingPaused {
                    let selection = G2UsbProtocol.slotSelectionPayload(enabled: flags, keyboard: flags, version: version)
                    _ = try await manager.diagnoseCommand(name: "SlotSelection \(letter)", payload: selection, listenSeconds: 0.3)
                    let focus = G2UsbProtocol.selectSlotPayload(slot: slot, version: version)
                    _ = try await manager.diagnoseCommand(name: "SlotFocus \(letter)", payload: focus, listenSeconds: 0.3)
                }
            } catch {
                print("  ❌ \(letter): \(error.localizedDescription)")
                return false
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let header = try? await manager.readPerformanceHeader() else {
                print("  ?  \(letter): nie udało się odczytać stanu z urządzenia")
                return false
            }
            let playing = header.settings.slots.enumerated().filter(\.element.enabled)
                .map { String(Character(UnicodeScalar(UInt8(65 + $0.offset)))) }.joined()
            let focused = Character(UnicodeScalar(UInt8(65 + min(max(header.settings.focusedSlot, 0), 3))))
            let ok = playing == String(letter) && focused == letter
            print("  \(ok ? "✅" : "❌") slot \(letter) → Nord: grają [\(playing.isEmpty ? "—" : playing)], focus \(focused), patch \"\(header.settings.slots[Int(slot)].name)\"")
            return ok
        }

        print("\n=== Krok 2: obchód wszystkich czterech slotów (bajt wersji 0x41) ===")
        var passed = 0
        for slot in UInt8(0) ..< 4 where await selectAndVerify(slot, version: workingVersion) {
            passed += 1
        }
        print("  → przełączenia udane: \(passed)/4")

        print("\n=== Krok 3: próba kontrolna bajtem 0x00 (tym z G2-Edita) ===")
        print("  spodziewany wynik: NIE zadziała — urządzenie kwituje OK i nic nie robi")
        await selectAndVerify(1, version: 0x00)
        await selectAndVerify(0, version: workingVersion) // wróć na slot A

        await manager.setNotificationHandler(nil)
        let echoes = notes.all().filter {
            $0.note.subCommand == G2UsbProtocol.subResponseSelectSlot
                || $0.note.subCommand == G2UsbProtocol.subResponseSlotSelection
        }
        print("\n--- Echo 0x07/0x09 z urządzenia w trakcie testu: \(echoes.count) ---")
        for entry in echoes {
            print(String(format: "    0x%02X payload %@", entry.note.subCommand, hexString(entry.note.payload)))
        }
        print("""

        4/4 w kroku 2 i „nie zadziałało" w kroku 3 = sterowanie slotami z edytora działa,
        a bajt wersji 0x00 (ten z G2-Edita) jest potwierdzony jako martwy.
        """)
    } else if args.contains("--probe-write") {
        // Eksperyment różnicowy dla „pierwsza komenda zapisu po connect() dostaje ciszę":
        // ten sam nieniszczący SelectSlot wysłany dwa razy — raz natychmiast po handshake,
        // raz po kilku sekundach działającego pollingu. Jeśli pierwszy dostaje odpowiedź,
        // a drugi nie, winna jest pętla poll (zatrzaśnięty endpoint 0x81), nie format komendy.
        await manager.setLog { line in print(line) }
        print("\n--- Deskryptory endpointów ---")
        await print(manager.describeEndpoints())

        // Bateria testów rozstrzygająca, CO dokładnie milczy po zakończonym handshake.
        // Wszystkie komendy są nieniszczące: odczyty i przełączenie aktywnego slotu.
        // Kluczowe porównanie to A vs B — jeśli milczy nawet odczyt, który w handshake
        // działa bezbłędnie, to nie „zapis nie działa", tylko „po Start nic nie działa".
        try await manager.withPollingPaused {
            print("\n--- A: GetPatchVersion(D) — ODCZYT, w handshake zawsze działa ---")
            try await manager.diagnoseCommand(name: "GetPatchVersion D", payload: G2UsbProtocol.getPatchVersionPayload(slot: 3))

            print("\n--- B: SelectSlot(A) — DOKŁADNIE bajty z handshake, tylko później ---")
            try await manager.diagnoseCommand(name: "SelectSlot A", payload: G2UsbProtocol.selectSlotPayload(slot: 0))

            print("\n--- C: SelectSlot(D) — to, czego potrzebuje sendPatch ---")
            try await manager.diagnoseCommand(name: "SelectSlot D", payload: G2UsbProtocol.selectSlotPayload(slot: 3))

            print("\n--- D: Stop → SelectSlot(D) → Start (czy komendy wymagają trybu zatrzymanego) ---")
            try await manager.diagnoseCommand(name: "Stop", payload: G2UsbProtocol.stopPayload())
            try await manager.diagnoseCommand(name: "SelectSlot D po Stop", payload: G2UsbProtocol.selectSlotPayload(slot: 3))
            try await manager.diagnoseCommand(name: "Start", payload: G2UsbProtocol.startPayload())
        }
        await print("\nStan po diagnostyce: \(manager.state)")
    } else if let seconds = listenSeconds {
        // Podsłuch kanału PRZYCHODZĄCEGO: co Nord nadaje z własnej inicjatywy.
        // Do 2026-09-04 apka odbierała te pakiety i wyrzucała, więc nie było wiadomo,
        // czy urządzenie w ogóle ogłasza ruch gałki na froncie i zmianę slotu.
        // Aktywna wariacja per slot — `SET_PARAM` musi ją nieść, inaczej zapis trafia
        // do niegrającej wariacji (patrz `G2UsbProtocol.setParameterPayload`).
        for (slot, patch) in patches.enumerated() where !fastConnect {
            print("Slot \(Character(UnicodeScalar(UInt8(65 + slot)))): aktywna wariacja \(patch.description.variation), \"\(patch.name)\"")
        }
        let notes = NotificationLog()
        await manager.setNotificationHandler { note in notes.append(note) }
        print("\n--- NASŁUCH \(seconds)s: pokręć gałką NA NORDZIE, przełącz slot, ZAŁADUJ INNY PATCH, zagraj coś ---")
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await manager.setNotificationHandler(nil)

        let entries = notes.all()
        var histogram: [UInt8: Int] = [:]
        for entry in entries {
            histogram[entry.note.subCommand, default: 0] += 1
        }
        print("\nPowiadomień łącznie: \(entries.count)")
        for (sub, count) in histogram.sorted(by: { $0.key < $1.key }) {
            print(String(format: "    0x%02X × %d  %@", sub, count, subCommandName(sub)))
        }

        // Zegar główny osobno: 0x3F liczy się do strumieni, a 0x5D tonie w powodzi 0x40
        // (lista zdarzeń urywa się na 120 wpisach). Bez tej sekcji w logu nie widać tego,
        // co jest tu najciekawsze — czy Nord sam zgłasza tempo zewnętrznego zegara MIDI.
        let clockNotes = entries.filter {
            $0.note.subCommand == G2UsbProtocol.subResponseMasterClock
                || $0.note.subCommand == G2UsbProtocol.subSysClockInfoResponse
        }
        if !clockNotes.isEmpty {
            let clockStart = entries.first?.time ?? Date()
            print("\n--- Zegar główny (0x3F ustawienie / 0x5D stan) ---")
            for entry in clockNotes {
                let sub = entry.note.subCommand
                let raw = hexString(entry.note.payload)
                var detail = raw
                if sub == G2UsbProtocol.subResponseMasterClock,
                   let change = G2UsbProtocol.decodeMasterClock(entry.note.payload)
                {
                    switch change {
                    case let .running(on): detail = "\(on ? "RUN" : "STOP")  [\(raw)]"
                    case let .bpm(value): detail = "\(value) BPM  [\(raw)]"
                    }
                } else if sub == G2UsbProtocol.subSysClockInfoResponse,
                          let info = G2UsbProtocol.decodeSysClockInfo(entry.note.payload)
                {
                    detail = "\(info.external ? "ZEWNĘTRZNY" : "wewnętrzny") \(info.bpm) BPM  [\(raw)]"
                }
                print(String(format: "  %6.2fs  0x%02X  %@",
                             entry.time.timeIntervalSince(clockStart), sub, detail))
            }
        }

        // Tempo echa gałki. USBProbe nie ma interfejsu, więc to, co widać tutaj, jest
        // CZYSTYM tempem kanału: jeśli seria przychodzi gęsto, a w edytorze odtwarza się
        // „w zwolnionym tempie", wąskim gardłem jest rysowanie, nie transport.
        let knobs = entries.filter { $0.note.subCommand == G2UsbProtocol.subResponseParamChange }
        if let first = knobs.first, let last = knobs.last, knobs.count > 1 {
            let span = last.time.timeIntervalSince(first.time)
            let gaps = zip(knobs, knobs.dropFirst())
                .map { $1.time.timeIntervalSince($0.time) }
                .sorted()
            let median = gaps[gaps.count / 2]
            print("\n--- Tempo PARAM_CHANGE (ruch gałki na froncie) ---")
            print(String(format: "  zdarzeń: %d w %.2fs → %.0f/s", knobs.count, span,
                         span > 0 ? Double(knobs.count) / span : 0))
            print(String(format: "  odstęp: mediana %.0f ms, najkrótszy %.0f ms, najdłuższy %.0f ms",
                         median * 1000, gaps.first! * 1000, gaps.last! * 1000))
        }

        // Podsumowanie PARAM_CHANGE po adresie. Lista zdarzeń niżej urywa się na 120 wpisach,
        // a jeden przejazd gałką to ich setka — bez tej tabelki zdarzenie z INNEGO adresu
        // (obszar ustawień, drugi slot) chowa się za obcięciem i wygląda jak „nic nie przyszło".
        if knobs.isEmpty {
            print("\n--- PARAM_CHANGE: ŻADNYCH przez cały nasłuch ---")
        } else {
            print("\n--- PARAM_CHANGE wg adresu (slot, obszar, moduł, parametr) ---")
            var byAddress: [String: (count: Int, low: Int, high: Int)] = [:]
            for entry in knobs {
                guard let change = G2UsbProtocol.decodeParamChange(entry.note.payload) else { continue }
                let name = switch change.location {
                case 0: "fx"
                case 1: "voice"
                case 2: "USTAWIENIA"
                default: "obszar \(change.location)"
                }
                let key = "slot \(slotLabel(Int(entry.note.slot)))  \(name) moduł \(change.moduleID) param \(change.paramIndex)"
                let old = byAddress[key] ?? (0, change.value, change.value)
                byAddress[key] = (old.count + 1, min(old.low, change.value), max(old.high, change.value))
            }
            for (key, tally) in byAddress.sorted(by: { $0.key < $1.key }) {
                print("    \(key): \(tally.count) × , wartości \(tally.low)…\(tally.high)")
            }
        }

        let start = entries.first?.time ?? Date()
        print("\n--- Zdarzenia sterujące (bez VU/LED/DSP) ---")
        var shown = 0
        for entry in entries where !streamSubCommands.contains(entry.note.subCommand) {
            let sub = entry.note.subCommand
            var detail = hexString(Array(entry.note.payload.prefix(16)))
            if sub == G2UsbProtocol.subResponseParamChange,
               let change = G2UsbProtocol.decodeParamChange(entry.note.payload)
            {
                let areaName = switch change.location {
                case 0: "fx"
                case 1: "voice"
                case 2: "USTAWIENIA"
                default: "obszar \(change.location)"
                }
                detail = "\(areaName) moduł \(change.moduleID) param \(change.paramIndex) = \(change.value) (wariacja \(change.variation))"
            } else if sub == G2UsbProtocol.subResponseSelectSlot, let slot = G2UsbProtocol.decodeSelectSlot(entry.note.payload) {
                detail = "nowy slot \(Character(UnicodeScalar(65 + slot)))"
            } else if sub == G2UsbProtocol.subResponsePatchVersionChange,
                      let changed = G2UsbProtocol.decodePatchVersion(entry.note.payload)
            {
                // To jest sygnał, po którym edytor przeładowuje slot — jeśli po zmianie
                // patcha na froncie Norda go tu NIE MA, urządzenie ogłasza to inaczej.
                detail = "slot \(Character(UnicodeScalar(65 + changed.slot))) → wersja \(changed.version)"
            }
            print(String(format: "  %6.2fs  slot %d  0x%02X %@  %@",
                         entry.time.timeIntervalSince(start), Int(entry.note.slot), sub, subCommandName(sub), detail))
            shown += 1
            if shown >= 120 { print("  … (dalsze pominięte)")
                break
            }
        }
        if shown == 0 { print("  (żadnych — Nord nie zgłosił ani ruchu gałki, ani zmiany slotu)") }

        // Rozkład (podkomenda, slot, długość) — rozstrzyga, czy strumień wskaźników
        // jest per-slot i czy jego długość zależy od zawartości patcha.
        print("\n--- Strumienie: (podkomenda, slot, długość) ---")
        var shape: [String: Int] = [:]
        for entry in entries where streamSubCommands.contains(entry.note.subCommand) {
            shape[String(format: "0x%02X slot %d %dB", entry.note.subCommand, Int(entry.note.slot), entry.note.payload.count), default: 0] += 1
        }
        for (key, count) in shape.sorted(by: { $0.key < $1.key }) {
            print("    \(key) × \(count)")
        }

        for sub in [G2UsbProtocol.subResponseVolumeData, G2UsbProtocol.subResponseLedData] {
            for slot in 0 ..< 4 {
                guard let sample = entries.last(where: { $0.note.subCommand == sub && $0.note.slot == UInt8(slot) }) else { continue }
                print("\nPrzykład 0x\(String(sub, radix: 16)) \(subCommandName(sub)) — slot \(Character(UnicodeScalar(UInt8(65 + slot)))), \(sample.note.payload.count)B:")
                print("    \(hexString(sample.note.payload))")
            }
        }

        // Sprawdzian tabeli wskaźników: przypisanie wartości do modułów wynika WYŁĄCZNIE
        // z zawartości slotu, więc sensowny rozkład jest jedynym dowodem, że tabela typów
        // (`G2VisualStream.visualCount`) zgadza się z urządzeniem.
        print("\n--- Wskaźniki VU odczytane ze strumienia ---")
        for (slot, patch) in patches.enumerated() where !fastConnect {
            let letter = Character(UnicodeScalar(UInt8(65 + slot)))
            guard let sample = entries.last(where: {
                $0.note.subCommand == G2UsbProtocol.subResponseVolumeData && $0.note.slot == UInt8(slot)
            }) else {
                print("  Slot \(letter): brak pakietu 0x3A")
                continue
            }
            let capacity = G2VisualStream.entryCapacity(payloadLength: sample.note.payload.count)
            let needed = G2VisualStream.entryCount(of: patch)
            let overflow = needed > capacity ? "  ⚠️ patch potrzebuje \(needed) wpisów, komunikat mieści \(capacity)" : ""
            print("  Slot \(letter): \(sample.note.payload.count)B = \(capacity) wpisów\(overflow)")
            // Zakres wartości przez CAŁY nasłuch — rozstrzyga skalę wskaźnika (czy bajt
            // dochodzi do 255, czy zatrzymuje się na 15), której nie podaje żadne źródło.
            var extremes: [String: (min: Int, max: Int)] = [:]
            // Grupy diod i pojedyncze diody: zbieramy WSZYSTKIE wartości z nasłuchu.
            // Jedna próbka mówi tylko „ile jest teraz"; dopiero zbiór wartości pokazuje,
            // czy sekwencer chodzi i po jakich krokach.
            var groupValues: [String: [Int]] = [:]
            var ledValues: [String: Set<Int>] = [:]
            for entry in entries where entry.note.subCommand == G2UsbProtocol.subResponseVolumeData
                && entry.note.slot == UInt8(slot)
            {
                let decoded = G2VisualStream.decodeVolumeData(entry.note.payload, patch: patch)
                for reading in decoded.meters {
                    for (channel, value) in reading.values.enumerated() {
                        let key = "\(reading.area) \(reading.moduleID):\(channel)"
                        let old = extremes[key] ?? (min: value, max: value)
                        extremes[key] = (min: Swift.min(old.min, value), max: Swift.max(old.max, value))
                    }
                }
                for group in decoded.ledGroups {
                    let key = "\(group.area) \(group.moduleID)"
                    if groupValues[key]?.last != group.value {
                        groupValues[key, default: []].append(group.value)
                    }
                }
            }
            for entry in entries where entry.note.subCommand == G2UsbProtocol.subResponseLedData
                && entry.note.slot == UInt8(slot)
            {
                for led in G2VisualStream.decodeLedData(entry.note.payload, patch: patch) {
                    ledValues["\(led.area) \(led.moduleID) dioda \(led.codeRef)", default: []].insert(led.value)
                }
            }
            let readings = G2VisualStream.decodeVolumeData(sample.note.payload, patch: patch)
            for reading in readings.meters {
                let name = patch.modules(in: reading.area).first { $0.id == reading.moduleID }?.label ?? "?"
                let ranges = reading.values.indices.map { channel -> String in
                    let key = "\(reading.area) \(reading.moduleID):\(channel)"
                    let range = extremes[key] ?? (min: 0, max: 0)
                    return "\(range.min)–\(range.max)"
                }.joined(separator: ", ")
                print("      [\(reading.area)] \(reading.moduleID) \"\(name)\" → teraz \(reading.values), zakres w nasłuchu: \(ranges)")
            }
            // Grupy diod — dla sekwencera to numer kroku, na którym stoi (patrz
            // `G2LedGroupReading`). Wartość spoza zakresu grupy = nie świeci nic.
            // Pojedyncze diody (0x39): jakie wartości przeszły przez każdą w nasłuchu.
            if ledValues.isEmpty {
                print("      diody 0x39: brak pakietu w nasłuchu")
            } else {
                for (key, values) in ledValues.sorted(by: { $0.key < $1.key }) where values != [0] {
                    print("      dioda 0x39 \(key): wartości \(values.sorted())")
                }
                let dark = ledValues.filter { $0.value == [0] }.count
                print("      diody 0x39: \(ledValues.count) w strumieniu, w tym \(dark) cały czas zgaszonych")
            }
            for group in readings.ledGroups {
                let module = patch.modules(in: group.area).first { $0.id == group.moduleID }
                let name = module?.label ?? "?"
                let leds = module.map { G2VisualStream.groupLeds(typeID: $0.typeID) } ?? []
                let seen = groupValues["\(group.area) \(group.moduleID)"] ?? []
                let trace = seen.count > 24 ? seen.prefix(24).map(String.init).joined(separator: "→") + "→…"
                    : seen.map(String.init).joined(separator: "→")
                let now = G2VisualStream.litLeds(groupValue: group.value, in: leds).map(\.codeRef)
                print("      [\(group.area)] \(group.moduleID) \"\(name)\" grupa \(leds.count) diod: \(trace)  → świecą CodeRef \(now)")
            }
        }

        await print("\nStan po nasłuchu: \(manager.state)")
    } else if !jsonOutput {
        print("Nasłuch przez 5s…")
        try await Task.sleep(nanoseconds: 5_000_000_000)
        await print("Stan po nasłuchu: \(manager.state)")
    }

    if jsonOutput {
        var slots: [SlotReport] = []
        for (slot, patch) in patches.enumerated() where !fastConnect {
            let inputToInput = (patch.fxCables + patch.voiceCables).filter { !$0.sourceIsOutput }
            await slots.append(SlotReport(slot: String(Character(UnicodeScalar(UInt8(65 + slot)))),
                                          name: patch.name,
                                          version: Int(manager.slotVersion(UInt8(slot))),
                                          voiceModules: patch.voiceModules.count,
                                          voiceCables: patch.voiceCables.count,
                                          fxModules: patch.fxModules.count,
                                          fxCables: patch.fxCables.count,
                                          inputToInputCables: inputToInput.count))
        }
        let report = await ProbeReport(state: "\(manager.state)",
                                       fastConnect: fastConnect,
                                       slots: slots,
                                       send: sendReport)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
} catch {
    if jsonOutput {
        print("{\"error\": \"\(error.localizedDescription)\"}")
    } else {
        print("Błąd: \(error.localizedDescription)")
    }
    exitStatus = 1
}

await manager.disconnect()
await say("Rozłączono. Stan: \(manager.state)")
exit(exitStatus)
