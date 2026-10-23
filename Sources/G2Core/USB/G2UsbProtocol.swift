// G2UsbProtocol.swift
// Ramkowanie i CRC16 protokołu USB Nord G2 — czyste, testowalne bez sprzętu.
// Format ustalony na podstawie reference/G2-Edit/src/{usbComms.c,utils.c} (GPL, Chris Turner) —
// NIE jest to SysEx (brak F0/F7): ramka TX = [dł.:2B BE][payload][CRC16:2B BE],
// CRC liczone tylko nad payloadem. Odpowiedź "extended" ma tę samą strukturę, ale bez
// prefiksu długości (długość nadchodzi wcześniej, w pakiecie interrupt).

import Foundation

public enum G2UsbProtocol {
    // MARK: - Identyfikacja urządzenia / endpointy

    public static let vendorID: UInt16 = 0x0FFC
    public static let productID: UInt16 = 0x0002
    public static let interfaceNumber: Int32 = 0

    public static let endpointOut: UInt8 = 0x03
    public static let endpointInterrupt: UInt8 = 0x81
    public static let endpointExtended: UInt8 = 0x82

    public static let interruptMessageSize = 16
    public static let extendedMessageSize = 8192
    public static let maxSlots = 4

    // MARK: - Typy odpowiedzi (niski nibble bajtu 0 pakietu interrupt / bajt 0 ramki)

    static let responseTypeExtended: UInt8 = 0x01
    static let responseTypeEmbedded: UInt8 = 0x02
    static let responseTypeInit: UInt8 = 0x80

    // MARK: - Bajty komend (patrz defs.h SUB_COMMAND_*/COMMAND_*)

    // `internal`, a nie `private`, bo `private` w Swift jest zasięgu PLIKU — komendy
    // wydzielone do osobnych plików (`G2BankList`) muszą widzieć te same stałe nagłówka.
    static let commandTag: UInt8 = 0x01 // pierwszy bajt payloadu każdej komendy poza Init
    static let commandReqSys: UInt8 = 0x2C // COMMAND_REQ(0x20) | COMMAND_SYS(0x0C)
    private static func commandReqSlot(_ slot: UInt8) -> UInt8 {
        0x28 | slot
    } // COMMAND_REQ | COMMAND_SLOT | slot

    /// COMMAND_WRITE_NO_RESP(0x30) | COMMAND_SLOT(0x08) | slot — jedyny znany użytkownik
    /// to `SET_PARAM` (patrz `setParameterPayload`): urządzenie tej komendy NIE potwierdza.
    private static func commandNoRespSlot(_ slot: UInt8) -> UInt8 {
        0x38 | slot
    }

    private static let subStartStop: UInt8 = 0x7D
    private static let subSlotSelection: UInt8 = 0x07 // Slot Selection Dump
    private static let subKeyboardFocus: UInt8 = 0x0F // Keyboard Focus Dump
    private static let subPerformanceHeaderRequest: UInt8 = 0x10 // Performance Header Request
    /// Performance Header Dump — **numer jest zarazem bajtem typu sekcji 0x11**,
    /// tej samej co w pliku `.prf2` (patrz `setPerformanceHeaderPayload`).
    public static let subPerformanceHeaderDump: UInt8 = 0x11
    private static let subPerformanceMode: UInt8 = 0x3E // Performance Mode Change
    /// Slot Focus Dump u Clavii — który slot jest EDYTOWANY. Nazwa „SelectSlot" jest
    /// z G2-Edita i myli: to nie jest wybór slotu, który gra (patrz `subSlotSelection`).
    private static let subSelectSlot: UInt8 = 0x09
    private static let subGetSynthSettings: UInt8 = 0x02
    private static let subGetMidiCc: UInt8 = 0x81
    /// Parameter Page Focus Request (0x58) i Global Parameter Page Focus Request (0x59) —
    /// „którą stronę parametrów masz teraz na panelu?". Odpowiedzią są `0x2D` i `0x1E`
    /// (patrz `parameterPageFocusPayload`). Oryginał pyta o obie przy budowie modelu
    /// synta: `CPatch::SendParameterPageFocusRequestBubble` dopóki jego flaga „nie wiem"
    /// jest zapalona. `0x59` chodziło u nas dotąd pod nazwą „unknown2".
    private static let subParameterPageFocusRequest: UInt8 = 0x58
    private static let subGlobalParameterPageFocusRequest: UInt8 = 0x59
    private static let subGetPatchVersion: UInt8 = 0x35
    /// Patch Load Request — pytanie o obciążenie DSP obszaru (patrz `patchLoadRequestPayload`).
    private static let subPatchLoadRequest: UInt8 = 0x71
    /// `Q_LIST_NAMES` / Flash Data Request — podaj zawartość banków (patrz `G2BankList`).
    static let subListBankNames: UInt8 = 0x14
    /// `S_RETREIVE` / Flash Load Command — załaduj patch z banku do slotu.
    static let subLoadFromBank: UInt8 = 0x0A
    /// `S_STORE` / Flash Store Command — zapisz zawartość slotu do banku.
    static let subStoreToBank: UInt8 = 0x0B
    /// Play Note / `S_PLAY_NOTE` — nuta zagrana Z EDYTORA (patrz `playNotePayload`).
    private static let subPlayNote: UInt8 = 0x56
    /// Param Setting Copy / `S_COPY_VARIATION` — przepisanie wariacji na wariację
    /// (patrz `copyVariationPayload`).
    private static let subCopyVariation: UInt8 = 0x44
    private static let subAssignMidiController: UInt8 = 0x22
    private static let subDeassignMidiController: UInt8 = 0x23
    /// Clock Info Request u Clavii, `Q_MASTER_CLOCK` u BVerhue — pytanie o STAN zegara
    /// (wewnętrzny/zewnętrzny + tempo). Odpowiedzią jest `0x5D`, nie `OK`.
    private static let subClockInfoRequest: UInt8 = 0x3B
    /// Perf Knob Map Request u Clavii, `Q_GLOBAL_KNOBS` u BVerhue — pytanie o gałki
    /// globalne performance'u. Odpowiedzią ma być sekcja `0x5F` (patrz `subGlobalKnobMap`).
    private static let subGlobalKnobMapRequest: UInt8 = 0x5E
    /// Performance Knob Map Dump / `C_KNOBS_GLOBAL` — **numer jest zarazem bajtem typu
    /// sekcji `0x5F`** z pliku `.prf2`, tak jak `0x11` przy nagłówku performance'u.
    public static let subGlobalKnobMap: UInt8 = 0x5F
    /// Textpad Request — pytanie o notatnik slotu. Odpowiedzią jest sekcja `0x6F`
    /// (`subTextpad`), w układzie pliku. Pełny zrzut slotu `0x3C` notatnika nie niesie
    /// (zmierzone na Nordzie 2026-10-14), więc kopia banku pyta o niego osobno.
    private static let subTextpadRequest: UInt8 = 0x6E
    public static let subTextpad: UInt8 = 0x6F
    /// Performance Header Param / `S_SET_MASTER_CLOCK` — **ten sam numer w obie strony**:
    /// wysyłamy, żeby zmienić tempo albo Run, i dostajemy z powrotem, gdy zmieni je ktoś
    /// na froncie Norda (patrz `subResponseMasterClock`).
    private static let subMasterClock: UInt8 = 0x3F
    private static let subGetPatchSlot: UInt8 = 0x3C
    private static let subGetPatchName: UInt8 = 0x28
    static let subPatchVersionResponse: UInt8 = 0x36
    /// Synth Data Dump — odpowiedź na Synth Data Request (0x02).
    public static let subSynthSettingsResponse: UInt8 = 0x03
    /// Performance Name Dump — odpowiedź na Performance Header Request; niesie nazwę
    /// performance'u, a zaraz za nią sekcję 0x11 (patrz `PatchParser.parseUsbPerformanceHeader`).
    public static let subPerformanceNameResponse: UInt8 = 0x29
    static let subPatchNameResponse: UInt8 = 0x27

    // Odpowiedzi urządzenia na komendę (`defs.h`): 0x7F = przyjęta, 0x7E = odrzucona.
    // Do 2026-09-03 nigdy nie sprawdzane — `performStep` brał za potwierdzenie pierwszy
    // pakiet z endpointu, a po `Start` leci tam ciągły strumień powiadomień (patrz niżej),
    // więc każdy zapis „przechodził" niezależnie od tego, co urządzenie z nim zrobiło.
    public static let subResponseOK: UInt8 = 0x7F
    public static let subResponseError: UInt8 = 0x7E

    /// Powiadomienia nadawane przez urządzenie z własnej inicjatywy (patrz
    /// `unsolicitedSubCommands`). Numery z `reference/G2-Edit/src/defs.h`, obsługa po
    /// stronie odbiorczej z `parse_command_response` w tym samym pliku.
    public static let subResponseSelectSlot: UInt8 = 0x09
    /// Odpowiedź na `GetPatchSlot` (0x3C) zaczyna się sekcją `PatchDescription` (0x21) —
    /// bajt podkomendy to pierwszy bajt strumienia sekcji, identycznego z plikiem `.pch2`.
    /// Zmierzone na sprzęcie 2026-09-05 dla czterech slotów, w tym prawie pustego.
    public static let subPatchDumpResponse: UInt8 = 0x21
    /// Keyboard Focus Dump przychodzący — który slot dostaje klawiaturę (czerwona
    /// kreska nad przyciskiem). Ten sam układ bitów co `0x07`, więc czyta go
    /// `decodeSlotSelection`.
    public static let subResponseKeyboardFocus: UInt8 = 0x0F
    /// Slot Selection Dump przychodzący — sloty włączone/wyłączone na froncie Norda.
    public static let subResponseSlotSelection: UInt8 = 0x07
    /// Performance Release — urządzenie **zwolniło cały performance** i wydało go na
    /// nowo. To jest sygnał, który Nord wysyła po załadowaniu patcha z jego frontu.
    ///
    /// Numeru nie ma w żadnym z odtworzonych edytorów (G2-Edit `defs.h`, typy BVerhue,
    /// g2ools, g2fx) — ale **używa go oryginalny edytor Clavii**, i to jednoznacznie:
    /// Performance Release ma identyfikator `0x1F`.
    /// Potwierdzone też nasłuchem na sprzęcie 2026-09-04: trzy pakiety na trzy załadowania
    /// patcha, ani jednego poza nimi, i żadnego `0x38`.
    ///
    /// **Payload to JEDEN bajt — numer sesji.** Performance Release (ReadStream) czyta
    /// dokładnie tyle (w odróżnieniu od `0x38`, gdzie przed numerem sesji jest jeszcze
    /// numer slotu 0–3). Bajty widoczne dalej w tej samej ramce USB to **osobne
    /// komunikaty** — cztery `0x36` Session Number Dump, po jednym na slot:
    /// ```
    /// 1F 12 | 36 00 13 | 36 01 12 | 36 02 12 | 36 03 12
    /// ```
    /// ⚠️ Nasz dekoder czyta z ramki tylko PIERWSZY komunikat, reszta ląduje w `payload`
    /// jako nierozpoznane bajty → [[Docs/roadmap]].
    ///
    /// Reakcja oryginału: `CSynth::HandlePerformanceRelease` zapamiętuje numer sesji
    /// i woła `CPerformanceManager::CreateInitialPerformanceForSynth`, czyli **buduje
    /// swój model synta od zera**. Stąd nasze przeczytanie wszystkich czterech slotów.
    public static let subResponsePerformanceRelease: UInt8 = 0x1F
    /// Nowa wersja slotu — urządzenie ogłasza ją po KAŻDEJ zmianie strukturalnej,
    /// w tym po załadowaniu innego patcha z pamięci Norda (G2-Edit loguje to wprost
    /// jako „Got Patch load", `usbComms.c:525`).
    public static let subResponsePatchVersionChange: UInt8 = 0x38
    public static let subResponseLedData: UInt8 = 0x39
    public static let subResponseVolumeData: UInt8 = 0x3A
    public static let subResponseParamChange: UInt8 = 0x40
    /// Patch Load — **obciążenie DSP obszaru**. Urządzenie nadaje je samo po każdej
    /// zmianie struktury patcha; można je też wyprosić przez `0x71`.
    public static let subResponsePatchLoad: UInt8 = 0x72
    /// `R_LIST_NAMES` — nagłówek odpowiedzi na `0x14`; niesie dwa bajty, których znaczenia
    /// nie zna też BVerhue, a za nimi w tej samej ramce potrafi siedzieć `0x16`.
    public static let subResponseBankListInfo: UInt8 = 0x13
    /// `R_ADD_NAMES` — właściwa porcja nazw z banków (patrz `decodeBankNames`).
    public static let subResponseBankNames: UInt8 = 0x16
    /// `R_STORE` / Flash Command Result — wynik zapisu do banku (patrz `storeResult`).
    public static let subResponseStore: UInt8 = 0x0D
    public static let subResponseSelectVariation: UInt8 = 0x6A
    /// Parameter Page Focus (0x2D) i Global Parameter Page Focus (0x1E) — **strona
    /// parametrów wybrana na panelu Norda**. Ten sam numer w obie strony, tak jak przy
    /// gałce (0x40) i zegarze (0x3F): wysyłamy go, gdy stronę wybierze użytkownik
    /// w oknie Parameter Pages, i dostajemy z powrotem, gdy naciśnie przycisk na froncie.
    public static let subResponseParameterPageFocus: UInt8 = 0x2D
    public static let subResponseGlobalParameterPageFocus: UInt8 = 0x1E
    /// Zegar główny zmieniony NA FRONCIE Norda — ten sam numer i ten sam układ bajtów
    /// co komenda wychodząca (`masterClockPayload`), tak jak przy ruchu gałki (0x40).
    public static let subResponseMasterClock: UInt8 = 0x3F
    /// Sys Clock Info / `R_EXT_MASTER_CLOCK` — stan zegara: czy tempo daje sam Nord,
    /// czy przychodzi z zewnątrz (MIDI clock). Odpowiedź na `0x3B`, ale urządzenie
    /// nadaje ją najpewniej także samo z siebie → [[Docs/ui/master-clock]] §6.3.
    public static let subSysClockInfoResponse: UInt8 = 0x5D

    /// Powiadomienia, które urządzenie wysyła samo z siebie po `Start` — nie są odpowiedzią
    /// na żadną naszą komendę i muszą być pomijane przy czekaniu na potwierdzenie.
    /// `SUB_RESPONSE_VOLUME_INDICATOR` (0x3A) leci ~40×/s dla aktywnego slotu.
    ///
    /// ⚠️ **Nie dopisuj tu numeru, który bywa też ODPOWIEDZIĄ na naszą komendę.** Ten zbiór
    /// przykrywa bit odpowiedzi z nagłówka: `awaitResponse` odsiewa nim komunikat, zanim
    /// sprawdzi, czy to odpowiedź na tę komendę. Zmierzone 2026-09-05 na `0x5D`: urządzenie
    /// odpowiada nim na pytanie `0x3B` **z ustawionym bitem odpowiedzi**
    /// (`92 | 01 0C 00 5D | 01 00 78`), więc wpis na tej liście kasował całą odpowiedź
    /// i stan zegara nigdy nie docierał. Powiadomienia nadane z własnej inicjatywy i tak
    /// przechodzą — rozstrzyga je `isSynthInitiated`, a `pollOnce` rozdaje wszystko.
    static let unsolicitedSubCommands: Set<UInt8> = [
        0x05, // ASSIGNED_VOICES
        0x07, // SLOT_SELECTION (Slot Selection Dump) — które sloty grają
        0x0F, // KEYBOARD_FOCUS (Keyboard Focus Dump) — który slot dostaje klawiaturę
        0x09, // SELECT_SLOT — echo zmiany slotu na froncie urządzenia
        0x1F, // PERFORMANCE_RELEASE — patch załadowany na froncie urządzenia
        0x2F, // SELECT_PARAM — zmiana zaznaczonego parametru na froncie
        0x38, // PATCH_VERSION_CHANGE
        0x39, // LED_DATA
        0x3A, // VOLUME_INDICATOR
        0x3F, // MASTER_CLOCK
        0x40, // PARAM_CHANGE — ruch gałki NA URZĄDZENIU (ten sam numer co komenda)
        0x69, // CURRENT_NOTE_2
        0x6A, // SELECT_VARIATION — zmiana wariacji na froncie
        0x72, // RESOURCES_USED
    ]

    /// Publiczne, bo bez tego narzędzia diagnostyczne nie umieją oddzielić odpowiedzi
    /// na wysłaną komendę od strumienia powiadomień (0x3A leci ~40×/s).
    public static func isUnsolicited(_ response: DecodedResponse) -> Bool {
        guard let subCommand = response.subCommand else { return false }
        return unsolicitedSubCommands.contains(subCommand)
    }

    private static let subSet: UInt8 = 0x37
    private static let subSetParam: UInt8 = 0x40
    /// Morph Change u Clavii, `S_SET_MORPH_RANGE` u BVerhue — patrz `setMorphRangePayload`.
    private static let subSetMorphRange: UInt8 = 0x43
    /// Knob Assign / Knob Deassign — gałki stron parametrów (patrz `assignKnobPayload`).
    private static let subAssignKnob: UInt8 = 0x25
    private static let subDeassignKnob: UInt8 = 0x26
    private static let subAddModule: UInt8 = 0x30
    /// Module Recolor — zmiana KOLORU jednego modułu na żywo. Osobna komenda, bo
    /// przesłanie Module New na istniejące id przebudowałoby moduł i urwało dźwięk.
    private static let subModuleColor: UInt8 = 0x31
    /// Module Move — przesunięcie jednego modułu na żywo (patrz `setModulePositionMolecule`).
    private static let subModuleMove: UInt8 = 0x34
    /// Module Name — zmiana NAZWY jednego modułu na żywo. **To nie jest `0x5A`**:
    /// `0x5A` (Module Name Dump) to zbiorczy dump nazw wszystkich modułów, wysyłany
    /// przy wgrywaniu całego patcha. Numer 0x33 pochodzi z dwóch niezależnych źródeł:
    /// Module Name (WriteStream) (`Initialize(0x33, …)`) w oryginalnym edytorze Clavii
    /// i `g2ools/g2ctl.py` (`g2SendSetModuleLabel = 0x33`).
    private static let subModuleName: UInt8 = 0x33
    /// Module AB Code — uprate jednego modułu na żywo (patrz `setModuleUprateMolecule`).
    private static let subModuleUprate: UInt8 = 0x2A
    private static let subWriteCable: UInt8 = 0x50
    private static let subDeleteCable: UInt8 = 0x51
    private static let subDeleteModule: UInt8 = 0x32
    private static let subParamDump: UInt8 = 0x4D
    private static let subModuleNameDump: UInt8 = 0x5A
    /// Custom Data jednego modułu — podpisy parametrów (patrz `setParamLabelMolecule`).
    private static let subParamLabel: UInt8 = 0x42

    // MARK: - CRC16 (port bit-a-bit z utils.c crc_iterator/calc_crc16 — zweryfikowany

    // wobec skompilowanego oryginału: crc("123456789") == 0x31C3, standardowy CRC-16/XMODEM)

    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: Int32 = 0
        for byte in bytes {
            crc = Int32(crcIterator(seed: crc, val: Int32(byte)))
        }
        return UInt16(crc)
    }

    private static func crcIterator(seed: Int32, val: Int32) -> UInt16 {
        var localCrc: Int32 = 0
        var k: Int32 = (((seed >> 8) ^ val) & 255) << 8
        for _ in 0 ..< 8 {
            if (localCrc ^ k) & 0x8000 != 0 {
                localCrc = (localCrc << 1) ^ 0x1021
            } else {
                localCrc <<= 1
            }
            k <<= 1
        }
        return UInt16(((seed << 8) ^ localCrc) & 0xFFFF)
    }

    // MARK: - Budowanie ramek TX

    /// [długość_całkowita:2B BE][payload][CRC16(payload):2B BE]
    public static func buildFrame(payload: [UInt8]) -> [UInt8] {
        let crc = crc16(payload)
        let totalLength = UInt16(payload.count + 4)
        var frame: [UInt8] = [UInt8(totalLength >> 8), UInt8(totalLength & 0xFF)]
        frame.append(contentsOf: payload)
        frame.append(UInt8(crc >> 8))
        frame.append(UInt8(crc & 0xFF))
        return frame
    }

    public static func initPingPayload() -> [UInt8] {
        [0x80]
    }

    // MARK: - Tożsamość urządzenia (odpowiedź na 0x80)

    /// Model zgłoszony przez urządzenie w odpowiedzi na ping inicjujący. Wartości i nazwy
    /// za oryginałem: Synth Port (CheckVersionMessage) mapuje ten bajt na `ESynthModel`,
    /// a Synth Port (GetModelString) przypisuje modelom teksty (nazwy odczytane z zasobów
    /// windowsowego builda, patrz [[Docs/usb/protocol-map]] „Model urządzenia").
    public enum DeviceModel: UInt8, Sendable, CaseIterable {
        case modularG2 = 0
        case modularG2X = 1
        case modularG2Rack = 2
        case modularG2Engine = 3
        case native = 4

        public var displayName: String {
            switch self {
            case .modularG2: "Modular G2"
            case .modularG2X: "Modular G2 61"
            case .modularG2Rack: "Modular G2 Rack"
            case .modularG2Engine: "Modular G2 Engine"
            case .native: "Native"
            }
        }

        /// Dwa dodatkowe koła globalne (w tabeli kontrolerów oryginału „G2X Global Wheel 1/2",
        /// CC 96 i 97) ma **wyłącznie** G2X. Oryginalny edytor pokazuje to wprost:
        /// `CSynth::HasGlobalModulationWheels` zwraca 0, a przesłania ją jedna jedyna klasa —
        /// Modular G2V (czyli ten model) — zwracając 1. Od tego oryginał uzależnia źródło
        /// morfu w świeżym patchu → [[Docs/ui/menu-spec]].
        public var hasGlobalModulationWheels: Bool {
            self == .modularG2X
        }
    }

    /// Co urządzenie powiedziało o sobie w odpowiedzi na `0x80`.
    public struct DeviceIdentity: Sendable, Equatable {
        /// `nil`, gdy urządzenie zgłosiło numer modelu, którego oryginał też nie zna.
        public let model: DeviceModel?
        /// Wersja firmware'u jako `major * 100 + minor` (120 = V1.20) — tak liczy ją
        /// oryginał, formatując komunikat „Version mismatch".
        public let firmware: UInt16?

        public var displayName: String {
            model?.displayName ?? "Unknown model"
        }

        public var firmwareText: String? {
            guard let firmware else { return nil }
            return String(format: "V%d.%02d", firmware / 100, firmware % 100)
        }
    }

    /// Bajty odpowiedzi na ping inicjujący **po** bajcie typu `0x80`:
    /// `[0x0A][model][tryb][…][firmware_hi][firmware_lo]…`.
    ///
    /// Znacznik `0x0A` sprawdzamy tak samo jak oryginał (`CheckVersionMessage` przerywa,
    /// gdy go nie ma) — bez niego byle pakiet zaczynający się od `0x80` udawałby
    /// przedstawienie się urządzenia. Firmware jest opcjonalny, bo model chcemy znać
    /// także wtedy, gdy odpowiedź przyszła krótsza, niż się spodziewamy.
    public static func decodeDeviceIdentity(_ payload: [UInt8]) -> DeviceIdentity? {
        guard payload.count >= 2, payload[0] == 0x0A else { return nil }
        let firmware: UInt16? = payload.count >= 7
            ? (UInt16(payload[5]) << 8) | UInt16(payload[6])
            : nil
        return DeviceIdentity(model: DeviceModel(rawValue: payload[1]), firmware: firmware)
    }

    public static func stopPayload() -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subStartStop, 0x01]
    }

    public static func startPayload() -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subStartStop, 0x00]
    }

    /// SUB_COMMAND_SELECT_SLOT (0x09) — ustawia, który slot jest "aktywny" na urządzeniu
    /// (front panel + cel edycji strukturalnej). W handshake wołane raz z `slot: 0`
    /// (`reference/G2-Edit/src/usbComms.c` `eStateSelectSlot`, zawsze slot A) — to
    /// tylko wejście w tryb edycji, nie wybór slotu do zapisu. Prawdziwy, parametryzowany
    /// wybór to `eMsgCmdSelectSlot` w tym samym pliku, wysyłane w G2-Edit za każdym razem
    /// gdy użytkownik klika przycisk slotu A/B/C/D (`mouseHandle.c`) — bo strukturalne
    /// komendy zapisu (AddModule/WriteCable/…) działają na aktywnym slocie urządzenia,
    /// niezależnie od bitów slotu w nagłówku komendy. `sendPatch` musi więc wysłać to
    /// PRZED sekwencją AddModule, z `slot` docelowego zapisu — inaczej zapis do slotu
    /// innego niż aktualnie aktywny (np. zostawiony na A po handshake) może być cicho
    /// ignorowany przez urządzenie. **Zweryfikowane na żywym sprzęcie 2026-09-03** —
    /// urządzenie odpowiada `SUB_RESPONSE_OK`.
    public static func selectSlotPayload(slot: UInt8, version: UInt8 = 0x00) -> [UInt8] {
        [commandTag, commandReqSys, version, subSelectSlot, slot]
    }

    public static func getSynthSettingsPayload() -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subGetSynthSettings]
    }

    public static func getMidiCcPayload() -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subGetMidiCc]
    }

    public static func globalParameterPageFocusRequestPayload() -> [UInt8] {
        [commandTag, commandReqSys, 0x00, subGlobalParameterPageFocusRequest]
    }

    /// Parameter Page Focus Request (0x58) — to samo pytanie dla strony SLOTU.
    /// **Niezweryfikowane na żywym sprzęcie.**
    public static func parameterPageFocusRequestPayload(slot: UInt8, version: UInt8) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version, subParameterPageFocusRequest]
    }

    /// Slot Selection Dump (0x07) — **które sloty są włączone (grają)**. To NIE to samo,
    /// co `SelectSlot`/focus (0x09): focus mówi, który slot się edytuje, selekcja — które
    /// w ogóle brzmią. Oryginalny edytor po kliknięciu przycisku slotu wysyła OBA
    /// (TB Window → Slot Selection Info (SelectSlot) → `SetSlotSelectionWhenPossible`,
    /// potem `CPortManager::SetFocusedSlot`) → [[Docs/usb/slots]].
    ///
    /// Układ bajtu z Slot Selection Dump (WriteStream): **4 bity zera, potem po jednym
    /// bicie na slot A…D**, bity od najstarszego. Czyli sam slot A = 0b0000_1000 = 0x08.
    /// `keyboard` jedzie **w tej samej ramce** jako drugi komunikat (Keyboard Focus Dump,
    /// 0x0F) — tak robi to `g2ools/g2ctl.py cmd_slot`, jedyne znane działające narzędzie
    /// przełączające slot: `[CMD_SYS, wersja, 0x07, bity, 0x0F, bity]`.
    ///
    /// `version` NIE jest stałą: g2ools bierze ją z odpowiedzi urządzenia. Zmierzone
    /// na sprzęcie: z wersją `0x00` Nord kwituje komendę `OK` i **nie robi nic**.
    public static func slotSelectionPayload(enabled: [Bool], keyboard: [Bool], version: UInt8) -> [UInt8] {
        [commandTag, commandReqSys, version,
         subSlotSelection, slotBits(enabled),
         subKeyboardFocus, slotBits(keyboard)]
    }

    /// Bity slotów: A jest najstarszy z czterech najmłodszych (`0x08 >> slot` w g2ools).
    public static func slotBits(_ flags: [Bool]) -> UInt8 {
        var bits: UInt8 = 0
        for slot in 0 ..< maxSlots where slot < flags.count && flags[slot] {
            bits |= UInt8(1 << (maxSlots - 1 - slot))
        }
        return bits
    }

    /// Lustro `slotSelectionPayload` — urządzenie nadaje ten sam komunikat, gdy sloty
    /// przełączy się na jego froncie (`CPerformance::HandleSlotSelectionDump` przepisuje
    /// z niego pola „slot enabled" nagłówka performance'u).
    public static func decodeSlotSelection(_ payload: [UInt8]) -> [Bool]? {
        guard let bits = payload.first else { return nil }
        return (0 ..< maxSlots).map { bits & UInt8(1 << (maxSlots - 1 - $0)) != 0 }
    }

    /// Performance Mode Change (0x3E) — przełącza urządzenie między trybem **Patch**
    /// (gra jeden slot) a **Performance** (cztery sloty razem, sterowane selekcją 0x07).
    /// Układ bajtów za `g2ools/g2ctl.py cmd_mode`: `[CMD_SYS, 0x41, 0x3E, tryb, 0x00]`.
    public static func performanceModePayload(performance: Bool) -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subPerformanceMode, performance ? 1 : 0, 0x00]
    }

    /// Ustawienia synta (Synth Data Request, 0x02). Odpowiedź: nazwa urządzenia,
    /// a zaraz za nią bitstream, którego **pierwszy bit to tryb** (0 = Patch,
    /// 1 = Performance) — tak czyta to `g2ools cmd_settings`.
    public static func synthSettingsRequestPayload() -> [UInt8] {
        getSynthSettingsPayload()
    }

    /// Tryb urządzenia z payloadu odpowiedzi 0x03 (po nazwie): najstarszy bit bajtu.
    /// Resztę tego samego komunikatu rozbiera `decodeSynthSettings`
    /// (patrz `G2SynthSettings.swift`) — tu chodzi o sam bit trybu.
    public static func decodePerformanceMode(_ payload: [UInt8]) -> Bool? {
        let start = synthSettingsBodyStart(payload)
        guard start < payload.count else { return nil }
        return payload[start] & 0x80 != 0
    }

    /// Performance Header Request (0x10) — nagłówek performance'u z urządzenia.
    /// **Jedyne znane źródło stanów „slot gra" i „slot ma klawiaturę"**; komunikat 0x07
    /// niesie samą selekcję, a 0x06 (Slot Selection Request) odpowiada tylko `OK`.
    ///
    /// Bajt wersji **musi** być 0x41. Zmierzone na żywym Nordzie 2026-09-04: z `0x00`
    /// urządzenie odpowiada gołym `SUB_RESPONSE_OK` i nie robi nic, z `0x41` odsyła
    /// 102-bajtową ramkę z nazwą performance'u i sekcją `0x11` → [[Docs/usb/slots]].
    public static func performanceHeaderRequestPayload() -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subPerformanceHeaderRequest]
    }

    /// Performance Name Dump (0x29) **w drugą stronę** — nazwa performance'u DO urządzenia.
    /// Ten sam numer, co odpowiedź (`subPerformanceNameResponse`): u Clavii to jedna klasa
    /// molekuły, z `WriteStream` i `ReadStream` obok siebie.
    ///
    /// Układ: nagłówek komendy systemowej i nazwa w formacie Clavii — **znaki i jeden
    /// terminator**, a przy pełnych 16 znakach bez terminatora. Ta sama `claviaString`,
    /// co przy nazwie modułu.
    ///
    /// **`WriteString(nazwa, 0x10)` w Performance Name Dump (WriteStream) znaczy „najwyżej
    /// 16", a nie „dopełnij do 16"** — rozstrzygnięte na żywym Nordzie 2026-09-07. Pole
    /// stałej długości urządzenie **odrzuciło**, a potem odpowiadało „Error" na wszystko aż
    /// do ponownego połączenia: po terminatorze czytało bajty dopełnienia jako początek
    /// następnego komunikatu. Zgadza się to z odczytem zmierzonym 2026-09-04 — nazwa
    /// w odpowiedzi `0x10` **jest zmiennej długości**, bo inaczej sekcja `0x11` zaczynałaby
    /// się gdzie indziej → [[Docs/usb/slots]].
    ///
    /// Drugie źródło tej samej formy: BVerhue `TG2MessPerformance.CreateSetPerfNameMessage`
    /// / `SendSetPerfNameMessage` (krok 1 `USBInitPerfSeq`) pisze `WriteClaviaString`.
    ///
    /// Komunikat jest systemowy (dotyczy performance'u, nie slotu) i ma typ 0,
    /// więc urządzenie kwituje go `SUB_RESPONSE_OK`.
    public static func setPerformanceNamePayload(_ name: String) -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subPerformanceNameResponse] + claviaString(name)
    }

    /// Performance Header Dump (0x11) — **cała sekcja ustawień performance'u DO urządzenia**:
    /// tempo i Run zegara, zakres klawiatury, a per slot `enabled`, `keyboard`, `hold`,
    /// bank, numer patcha i zakres klawiszy. Odpowiedź `0x10` niesie dokładnie tę samą
    /// sekcję, więc jedno i drugie czyta i pisze ten sam kod formatu pliku.
    ///
    /// **Payload nie ma osobnego bajtu podkomendy** — Performance Header Dump (WriteStream)
    /// nie woła `Initialize`, tylko oddaje strumień `CPerformanceHeader_11::WriteStream`,
    /// a ten zaczyna od bajtu typu sekcji. `0x11` przychodzi więc razem z sekcją; dopisanie
    /// go tutaj drugi raz zepsułoby ramkę. Sekcję buduje `PatchParser.performanceHeaderSection`
    /// — z pliku albo z tego, co przeczytaliśmy z urządzenia.
    ///
    /// Typ komunikatu 0 → `SUB_RESPONSE_OK`. **Niezweryfikowane na żywym sprzęcie.**
    public static func setPerformanceHeaderPayload(section: [UInt8]) -> [UInt8] {
        [commandTag, commandReqSys, 0x41] + section
    }

    /// `0x1A` Complete Performance Dump — **cały performance jednym komunikatem**: nazwa,
    /// nagłówek, cztery patche i mapa gałek globalnych. Tak wgrywa performance oryginał
    /// (`CSynth::CleanDirtyData` wypuszcza bąbel Dump Bubble Destination + ten zrzut),
    /// więc urządzenie nigdy nie widzi stanu pośredniego — a my, wysyłając cztery osobne
    /// `0x37`, widzieliśmy go aż nadto (usterka #79) → [[Docs/usb/slots]].
    ///
    /// Układ z Complete Performance Dump (WriteStream): `Initialize(0x1a, 0, 0)`, potem
    /// po kolei Performance Name Dump (`0x29` + nazwa), Performance Header Dump
    /// (sekcja `0x11` razem z bajtem typu), molekuły **czterech plików patchy** i
    /// Performance Knob Map Dump (sekcja `0x5F`). Molekuły patcha to dokładnie te sekcje,
    /// które wysyłamy w `0x37` — jedyne, co je rozdziela, to numeracja wystąpień, tak samo
    /// jak w pliku `.prf2`.
    ///
    /// Poprzedza go Dump Bubble Destination w wariancie „cały synt": ta sama molekuła
    /// `0x37` z trzema zerami i nazwą, co przy wgrywaniu do slotu.
    ///
    /// **Zweryfikowane na żywym G2 37 (firmware 1.62) 2026-09-10, za pierwszym razem.**
    /// Adresowanie systemowe okazało się właściwe, a odpowiedzią jest `0x36` z numerami
    /// sesji czterech slotów i performance'u — nie `OK`, jak sugerował typ molekuły.
    public static func completePerformanceDumpPayload(name: String,
                                                      headerSection: [UInt8],
                                                      slotStreams: [[UInt8]],
                                                      knobMapSection: [UInt8]) -> [UInt8]
    {
        var payload: [UInt8] = [commandTag, commandReqSys, 0x41]
        payload += [subSet, 0x00, 0x00, 0x00] + claviaString(name)
        payload += [subCompletePerformanceDump]
        payload += [subPerformanceNameResponse] + claviaString(name)
        payload += headerSection
        for stream in slotStreams {
            payload += stream
        }
        payload += knobMapSection
        return payload
    }

    public static let subCompletePerformanceDump: UInt8 = 0x1A

    /// Ile znaków przyjmuje urządzenie w nazwie performance'u — tyle samo pokazuje okno
    /// „Performance Name" oryginału (`CNameDialog(…, 0x10, …)` w TB Window).
    public static let performanceNameLength = 16

    // MARK: - Zegar główny (Run/Stop + tempo)

    /// Dopuszczalne tempo zegara głównego. Ten sam zakres w oknie głównym
    /// i w oknie Performance oryginału, a u BVerhue `TG2Perf.SetMasterClock` rzuca
    /// wyjątkiem poza 30…240 → [[Docs/ui/master-clock]] §3.
    public static let masterClockRange = 30 ... 240

    /// Indeks pola w komendzie `0x3F` — jedna komenda niesie dokładnie jedno pole
    /// nagłówka performance'u. Zegar to indeksy 0 i 1; indeks 2 to **Global Pages**,
    /// czyli przełącznik nad wyborem A…E w oknie Parameter Pages
    /// (Knob Floater Container (HandleChangeRequests) → Performance Header Param(2, …),
    /// odbiór w `CPerformance::HandlePerformanceHeaderParam`).
    public static let masterClockIndexRun: UInt8 = 0x00
    public static let masterClockIndexBPM: UInt8 = 0x01
    public static let performanceHeaderIndexGlobalPages: UInt8 = 0x02

    public static func clampedBPM(_ bpm: Int) -> Int {
        min(max(bpm, masterClockRange.lowerBound), masterClockRange.upperBound)
    }

    /// Clock Info Request (0x3B) — pytanie o stan zegara. Nagłówek jak przy każdej
    /// komendzie systemowej (`TG2Synth.InitMsg` u BVerhue: `01 2C 41`), odpowiedź `0x5D`.
    /// Pytamy raz na przebudowę modelu synta, tak jak oryginał → [[Docs/ui/master-clock]] §6.2.
    public static func clockInfoRequestPayload() -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subClockInfoRequest]
    }

    /// Perf Knob Map Request (0x5E) — gałki globalne performance'u z urządzenia.
    /// Oryginał pyta o nie przy budowie modelu synta (`CPerfKnobMap::SendRequestBubble`),
    /// BVerhue w 7. kroku inicjalizacji performance'u (`SendGetGlobalKnobsMessage`).
    public static func globalKnobMapRequestPayload() -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subGlobalKnobMapRequest]
    }

    /// Sekcja `0x5F` z odpowiedzi — z nagłówkiem `[typ][długość:2B]`, w układzie
    /// identycznym z plikiem `.prf2`. `payload` to treść po bajcie podkomendy.
    public static func globalKnobMapSection(payload: [UInt8]) -> [UInt8]? {
        fileSection(type: subGlobalKnobMap, payload: payload)
    }

    public static func textpadRequestPayload(slot: UInt8, version: UInt8) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version, subTextpadRequest]
    }

    /// Sekcja `0x6F` z odpowiedzi na `textpadRequestPayload`, z nagłówkiem `[typ][długość:2B]`.
    public static func textpadSection(payload: [UInt8]) -> [UInt8]? {
        fileSection(type: subTextpad, payload: payload)
    }

    /// Odpowiedzi-sekcje mają za bajtem podkomendy `[długość:2B][treść]` — bajt podkomendy
    /// jest zarazem typem sekcji pliku. Ogon ramki za sekcją odcinamy.
    private static func fileSection(type: UInt8, payload: [UInt8]) -> [UInt8]? {
        guard payload.count >= 2 else { return nil }
        let length = Int(payload[0]) << 8 | Int(payload[1])
        guard payload.count >= 2 + length else { return nil }
        return [type] + payload.prefix(2 + length)
    }

    /// `0x3F` — jedno pole zegara głównego. Układ potwierdzony w dwóch źródłach:
    /// `TG2Perf.AddMsgSetMasterClockBPM`/`…Run` u BVerhue i Performance Header Param
    /// u Clavii (trzeci argument konstruktora, dwuargumentowa wersja wpisuje tam `0xFF`
    /// na sztywno — stąd „Unknown" w komentarzu BVerhue). Prawdziwa ramka złapana przez
    /// g2fx: `3f ff 01 79` = 121 BPM.
    ///
    /// `version` to u BVerhue numer sesji performance'u (`TG2Perf.InitMsg`), a nie stała.
    /// Wysyłamy `0x41` jak przy pozostałych komendach systemowych: bit `0x40` znaczy
    /// „bez sesji" i to z nim działa u nas wszystko inne (z `0x00` urządzenie kwituje
    /// `OK` i nie robi nic) → [[Docs/usb/actor]] „Jak Clavia paruje odpowiedź z komendą".
    public static func performanceHeaderParamPayload(index: UInt8, value: UInt8,
                                                     version: UInt8) -> [UInt8]
    {
        [commandTag, commandReqSys, version, subMasterClock, 0xFF, index, value]
    }

    public static func setMasterClockPayload(bpm: Int, version: UInt8) -> [UInt8] {
        performanceHeaderParamPayload(index: masterClockIndexBPM,
                                      value: UInt8(clampedBPM(bpm)), version: version)
    }

    public static func setClockRunPayload(running: Bool, version: UInt8) -> [UInt8] {
        performanceHeaderParamPayload(index: masterClockIndexRun,
                                      value: running ? 1 : 0, version: version)
    }

    /// Global Pages włączone/wyłączone — indeks 2 tej samej komendy `0x3F`.
    /// **Zweryfikowane na żywym G2 37 (firmware 1.62) 2026-09-09, w obie strony.**
    public static func setGlobalPagesPayload(enabled: Bool, version: UInt8) -> [UInt8] {
        performanceHeaderParamPayload(index: performanceHeaderIndexGlobalPages,
                                      value: enabled ? 1 : 0, version: version)
    }

    /// Co niesie komunikat `0x3F` — Run albo tempo, nigdy oba naraz.
    public enum MasterClockChange: Equatable, Sendable {
        case running(Bool)
        case bpm(Int)
    }

    /// Payload `0x3F`: `[0xFF][indeks][wartość]`. Pierwszy bajt jest nieużywany (patrz
    /// `masterClockPayload`), więc go nie sprawdzamy — czyta go tak samo
    /// `TG2Perf.ProcessMsgMasterClock`, które od razu nadpisuje zmienną kolejnym bajtem.
    /// Tempo spoza 30…240 odrzucamy: u BVerhue jest to wyjątek, a nie wartość do pokazania.
    public static func decodeMasterClock(_ payload: [UInt8]) -> MasterClockChange? {
        guard payload.count >= 3 else { return nil }
        switch payload[1] {
        case masterClockIndexRun:
            return .running(payload[2] != 0)
        case masterClockIndexBPM:
            let bpm = Int(payload[2])
            return masterClockRange.contains(bpm) ? .bpm(bpm) : nil
        default:
            return nil
        }
    }

    /// Ten sam komunikat `0x3F` z indeksem 2 — Global Pages przełączone NA FRONCIE Norda.
    /// `nil` znaczy „to nie było o Global Pages" (zegar albo śmieci), więc odczyt zegara
    /// i ten mogą stać obok siebie na tej samej podkomendzie.
    public static func decodeGlobalPages(_ payload: [UInt8]) -> Bool? {
        guard payload.count >= 3, payload[1] == performanceHeaderIndexGlobalPages else { return nil }
        return payload[2] != 0
    }

    /// Payload `0x5D` (Sys Clock Info (ReadStream)): `[flaga][tempo hi][tempo lo]`.
    /// **Flaga ≠ 0 znaczy zegar WEWNĘTRZNY** — domyślne wartości obiektu w oryginale to
    /// `1` i `0x78` (120 BPM). Tempo jest 16-bitowe BE i dokładniejsze niż całe BPM z `0x3F`;
    /// przy zegarze zewnętrznym oryginał bierze tempo właśnie stąd (`CSynth::GetClockRate`).
    /// Układ zgodny w trzech źródłach: Clavia, BVerhue `ProcessMsgExtMasterClock`, g2fx.
    public static func decodeSysClockInfo(_ payload: [UInt8]) -> (external: Bool, bpm: Int)? {
        guard payload.count >= 3 else { return nil }
        return (payload[0] == 0, Int(payload[1]) << 8 | Int(payload[2]))
    }

    public static func getPatchVersionPayload(slot: UInt8) -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subGetPatchVersion, slot]
    }

    /// SUB_COMMAND (0x71, Patch Load Request) — **prośba o raport obciążenia DSP**
    /// jednego obszaru slotu. Odpowiedzią jest `0x72`, nie `OK` (typ 2 = zapytanie).
    ///
    /// Nazwa myli i myliła też nas: Patch Load Request to nie „załaduj patch",
    /// tylko „podaj obciążenie". Rozstrzyga wołający — Patch Load (SendLoadRequest),
    /// a Patch Load liczy `GetCycles`, `GetXmem`, `GetYmem`, `GetPmem`, `GetRAM`
    /// → [[Docs/usb/protocol-map]]. Załadowanie patcha z banku to `0x0A`.
    ///
    /// W praktyce prośba jest rzadko potrzebna: urządzenie nadaje `0x72` samo po każdej
    /// zmianie struktury. Zostaje na wypadek, gdy trzeba odświeżyć odczyt bez zmiany
    /// patcha. **Niezweryfikowane na żywym sprzęcie.**
    public static func patchLoadRequestPayload(slot: UInt8, version: UInt8, area: PatchArea) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version, subPatchLoadRequest, area == .voice ? 1 : 0]
    }

    /// SUB_COMMAND (0x56, Play Note) — **zagranie nuty z edytora**, jakby ktoś nacisnął
    /// klawisz na Nordzie. Komunikat SYSTEMOWY, nie slotowy: BVerhue buduje go przez
    /// `Synth.InitMsg` (`TG2USBConnection.SynthNoteOnOff`), a nie przez ramkę slotu —
    /// nutę dostają wszystkie sloty, które mają klawiaturę.
    ///
    /// Układ: `[0x56][on/off][numer nuty]`, potwierdzony w BVerhue Gen2 i Gen3
    /// (`AddMsgNoteMessage`). ⚠️ **Polaryzacja pierwszego bajtu niepewna:** BVerhue
    /// komentuje go „$00 on $01 off", a Play Note (WriteStream) u Clavii zapisuje tam
    /// `this[0xc] == 1`, co czytane wprost daje odwrotnie. Trzymamy się BVerhue, bo to
    /// jedyne źródło, które podaje sam bajt — do rozstrzygnięcia pierwszym pomiarem.
    public static func playNotePayload(note: UInt8, on: Bool) -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subPlayNote, on ? 0x00 : 0x01, note]
    }

    public static func getPatchSlotPayload(slot: UInt8, version: UInt8) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version, subGetPatchSlot]
    }

    public static func getPatchNamePayload(slot: UInt8, version: UInt8) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version, subGetPatchName]
    }

    /// 0x37 — **wgranie CAŁEGO patcha do slotu jedną komendą**. Tak robi to oryginał
    /// i tylko tak dioda PATCH LOAD mruga raz zamiast przez pół minuty.
    ///
    /// Do 2026-09-04 uważaliśmy tę komendę za pomyłkę autorów g2ools („zrzut na flash,
    /// nie upload") i wgrywaliśmy patch molekuła po molekule. Oryginalny edytor Clavii pokazuje
    /// coś innego — `CSynth::CleanDirtyData` dla slotu czekającego na synchronizację robi:
    ///
    /// ```
    /// CPatch::GetCompletePatchDump(patch, bubble)          // cały patch → lista molekuł
    /// Dump Bubble Destination(CPatch::GetFlashName(patch)) // 0x37, DOKLEJONE NA POCZĄTEK
    /// CSynth::SendUserBubble(bubble)                       // JEDNA ramka
    /// ```
    ///
    /// `CBubblePort::GenerateMessages` skleja molekuły bąbla w jeden ciągły bufor i tnie
    /// go dopiero na 0xFFFF bajtach — patch (~18 kB) idzie więc w jednym komunikacie.
    /// Nazwa „DumpBubble" nie oznaczała flasha, tylko „bąbel niosący zrzut"; pierwsza
    /// molekuła mówi, dokąd ten zrzut trafia.
    ///
    /// Układ bajtów zgadza się co do jednego z Dump Bubble Destination (WriteStream)
    /// (`Initialize(0x37, …)` + flaga + dwa bajty Flash Entry + nazwa) i z
    /// `reference/g2ools/g2ctl.py` `cmd_loadslot` (`0x37, 0x00, 0x00, 0x00`, nazwa, treść).
    /// Trzy zera to „miejsce docelowe = slot, nie pozycja w banku".
    ///
    /// Różnica wobec g2ools: w miejscu numeru wersji slotu g2ctl.py wysyła stałą `0x53`
    /// nigdy nieodczytaną z urządzenia. Wpisujemy tam prawdziwą wersję slotu, jak
    /// `reference/G2-Edit/src/usbComms.c` `send_write_data` we WSZYSTKICH komendach slotu.
    ///
    /// `sectionBytes` → `PatchParser.slotSectionStream(fileData:slot:)`.
    public static func setPatchPayload(slot: UInt8, version: UInt8, patchName: String, sectionBytes: [UInt8]) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version, subSet, 0x00, 0x00, 0x00]
            + claviaString(patchName) + sectionBytes
    }

    /// SUB_COMMAND_ADD_MODULE (0x30) — dodaje JEDEN moduł do patcha w slocie.
    /// To jest prawdziwy mechanizm uploadu nowego patcha: moduły lecą pojedynczo
    /// (ten komunikat, raz na moduł), kable/parametry/nazwy zbiorczo —
    /// `PatchParser.writeCableList`/`writeParamList`/`writeModuleNames` →
    /// [[Docs/usb/actor]] „Jak Clavia faktycznie wgrywa NOWY patch".
    ///
    /// Układ pól potwierdzony **podwójnie, niezależnie**:
    /// `reference/G2-Edit/src/usbComms.c` `eMsgCmdWriteModule` (realny, używany
    /// kod wysyłki — rozstrzyga kolejność `location` przed `index`) oraz
    /// Module New (WriteStream)/`ReadStream` w oryginalnym edytorze Clavii (rozstrzyga,
    /// że wszystkie pola do `isLed` są pojedynczymi bajtami). Nazwa idzie jako
    /// `claviaString`, czyli **zmiennej długości** — patrz tam.
    ///
    /// **Jedna nierozstrzygnięta rozbieżność między źródłami:** ostatni bajt flagowy
    /// przed listą modes — G2-Edit nazywa go `isLed`, oryginalny edytor Clavii w tym
    /// miejscu woła jednoznacznie `CModule::IsLocked`. Piszemy `module.leds`
    /// (mamy tę wartość, dla świeżo dodawanego modułu obie interpretacje dają
    /// zwykle 0) — **do potwierdzenia przy pierwszym teście na żywym sprzęcie**.
    /// Niezweryfikowane na sprzęcie.
    public static func addModulePayload(slot: UInt8, version: UInt8, module: G2Module) -> [UInt8] {
        commandHeader(slot: slot, version: version) + addModuleMolecule(module)
    }

    /// Sam komunikat, bez nagłówka ramki — do pakowania kilku w jedną wysyłkę
    /// (patrz `batchPayload`).
    public static func addModuleMolecule(_ module: G2Module) -> [UInt8] {
        let locationByte: UInt8 = module.area == .voice ? 1 : 0
        var molecule: [UInt8] = [
            subAddModule,
            UInt8(module.typeID), locationByte, UInt8(module.id),
            UInt8(module.column), UInt8(module.row), module.color,
            module.uprate ? 1 : 0, module.leds ? 1 : 0,
        ]
        molecule += module.modes.map { UInt8($0) }
        molecule += claviaString(module.label)
        return molecule
    }

    /// Nazwa w formacie Clavii: do 16 znaków, a gdy jest krótsza — **jeden** bajt zera
    /// na koniec (nie dopełnienie do 16). Tak samo pisze ją BVerhue
    /// (`TG2Message.WriteClaviaString`) i tak samo czyta urządzenie.
    ///
    /// Że to jest forma, której Nord OCZEKUJE, wiadomo od 2026-09-07: nazwa performance'u
    /// wysłana w polu dopełnionym zerami została odrzucona → `setPerformanceNamePayload`.
    ///
    /// **Oryginalny edytor robi dokładnie to samo — trzeba tylko rozróżnić dwa pisarze.**
    /// Bit Stream ma osobno `PutString(tekst, n)` (kopiuje znaki, a gdy tekst się
    /// skończy przed `n`, dopisuje JEDEN zerowy bajt i tam kończy) i osobno
    /// `PutStringFixLength(tekst, n)` (zawsze `n` bajtów, reszta zerami). Molekuły
    /// wołają wyłącznie ten pierwszy — ten sam slot tablicy wirtualnej `+0x5c`
    /// z limitem `0x10` w Performance Name Dump, Module Name (0x33),
    /// Module New (0x30) i Dump Bubble Destination (0x37), a także w sekcjach
    /// pliku Module Name Data 11 (0x5A) i `CPerformanceHeader_11`. `PutStringFixLength`
    /// nie ma w tym kodzie ani jednego wołającego. Czyli **żadna nazwa wysyłana do
    /// Norda nie jest polem stałej szerokości** → [[Docs/usb/protocol-map]].
    /// `internal`, a nie `private` — `private` w Swift sięga tylko do końca pliku,
    /// a nazwę urządzenia zapisuje tą samą funkcją `G2SynthSettings.swift`.
    static func claviaString(_ text: String) -> [UInt8] {
        var bytes = [UInt8](text.utf8.prefix(16))
        if bytes.count < 16 { bytes.append(0) }
        return bytes
    }

    /// Sam komunikat Cable Connect, bez nagłówka ramki.
    ///
    /// **Trzy najmłodsze bity drugiego bajtu to KOLOR kabla** (`ECableColor`, 0–6 —
    /// ta sama liczba co w pliku `.pch2`). Do 2026-09-06 wysyłaliśmy tam zawsze zero,
    /// czyli każdy kabel dodany na żywo lądował w Nordzie jako czerwony niezależnie
    /// od tego, co pokazywał edytor. Rozstrzygnięte dwoma źródłami naraz:
    /// Cable Connect (WriteStream) pisze w tym miejscu 3-bitowe pole `this[0xc]`,
    /// a jedyna różnica Cable Recolor (0x54) wobec Cable Delete to właśnie ono —
    /// przy konstruktorze Cable Recolor(EContext, CConnector, CConnector, ECableColor)
    /// nie zostaje wątpliwość, co to za pole. `reference/G2-Edit/src/usbComms.c` ma tam
    /// wprost `| 0x00` — puste miejsce na tę samą wartość.
    public static func writeCableMolecule(_ cable: G2Cable) -> [UInt8] {
        let locationByte: UInt8 = cable.area == .voice ? 1 : 0
        return [
            subWriteCable,
            0x10 | (locationByte << 3) | (cable.color.rawValue & 0x07),
            UInt8(cable.fromModule),
            linkTypeConnectorByte(cable),
            UInt8(cable.toModule),
            UInt8(cable.toConnector),
        ]
    }

    private static func commandHeader(slot: UInt8, version: UInt8) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version]
    }

    /// **Kilka komunikatów w jednej ramce** — tak wysyła je oryginał (`CBubble`:
    /// Patch Data (GetNewModulesMolecules) buduje listę, `UndoUserBubbleOutput` wypuszcza
    /// ją naraz). Nagłówek ramki jest jeden, molekuły idą jedna za drugą.
    ///
    /// Po co: log ze sprzętu 2026-09-04 pokazał, że Nord przelicza obciążenie DSP po
    /// KAŻDYM module i potwierdza dopiero po ~270 ms. Wysyłka 46 modułów po jednym zajęła
    /// 12,3 s (i tyle samo migała dioda PATCH LOAD) → [[Docs/usb/actor]].
    ///
    /// Że urządzenie przyjmuje kilka komunikatów w ramce, wiemy z dwóch stron: sami tak
    /// wysyłamy `0x07`+`0x0F` (zweryfikowane na sprzęcie), a Nord przysyła nam `0x1F`
    /// z czterema `0x36`.
    public static func batchPayload(slot: UInt8, version: UInt8, molecules: [[UInt8]]) -> [UInt8] {
        commandHeader(slot: slot, version: version) + molecules.flatMap { $0 }
    }

    /// SUB_COMMAND_WRITE_CABLE (0x50) — Cable Connect, dodaje JEDEN kabel do patcha
    /// w slocie. Odpowiednik `addModulePayload` dla kabli: kable lecą pojedynczo,
    /// tak jak moduły — **nie** zbiorczym dumpem. `0x52` (Cable Dump) niesie
    /// dokładnie ten sam kształt bajtów co ta funkcja by sugerowała przy pierwszym
    /// spojrzeniu, ale to WYŁĄCZNIE format odpowiedzi urządzenia przy odczycie —
    /// w oryginalnym edytorze Clavii `CPatch::HandleCableDump` tylko dokleja (`ConnectCable`)
    /// każdy wpis z dumpu, bez czyszczenia istniejącej listy najpierw. Wysłanie go
    /// jako komendy zapisu do slotu, który już ma kable, dubluje je — potwierdzone
    /// na żywym sprzęcie (5→10→20 kabli). Szczegóły → [[Docs/usb/actor]] „Cable Dump
    /// jest append-only z założenia".
    ///
    /// Układ pól z `reference/G2-Edit/src/usbComms.c` `eMsgCmdWriteCable` (realny,
    /// używany kod wysyłki): `linkType` to 1-bitowy kierunek („1 = output→input"),
    /// nie kolor — kolor kabla to osobna komenda `SUB_COMMAND_WRITE_CABLE_COLOUR`
    /// (0x54, Cable Recolor w oryginale), tu celowo pominięta (kolor domyślny
    /// z typu konektora wystarcza dla nowo wgrywanego patcha). **Zweryfikowane na żywym
    /// sprzęcie 2026-09-03** — potwierdzane przez `SUB_RESPONSE_OK`. `linkType` idzie
    /// z `cable.sourceIsOutput` (do 2026-09-03 był tu na sztywno `1`, przez co kable
    /// wejście-wejście wysyłano błędnie i nie dawały się skasować).
    public static func writeCablePayload(slot: UInt8, version: UInt8, cable: G2Cable) -> [UInt8] {
        commandHeader(slot: slot, version: version) + writeCableMolecule(cable)
    }

    /// Bajt `(linkType << 6) | connectorFromIoIndex` — wspólny dla `WriteCable` (0x50)
    /// i `DeleteCable` (0x51), przepisany 1:1 z `reference/G2-Edit/src/usbComms.c`.
    /// Kasowanie musi podać ten sam `linkType`, co zapis, inaczej urządzenie nie
    /// rozpozna kabla i nie skasuje go.
    private static func linkTypeConnectorByte(_ cable: G2Cable) -> UInt8 {
        let linkType: UInt8 = cable.sourceIsOutput ? 1 : 0
        return (linkType << 6) | UInt8(cable.fromConnector)
    }

    /// SUB_COMMAND_DELETE_CABLE (0x51) — usuwa JEDEN kabel. Bajt obszaru koduje się tu
    /// INACZEJ niż w `writeCablePayload` (`0x02 | location`, nie `0x10 | location << 3`) —
    /// przepisane 1:1 z `reference/G2-Edit/src/usbComms.c` `eMsgCmdDeleteCable`.
    public static func deleteCablePayload(slot: UInt8, version: UInt8, cable: G2Cable) -> [UInt8] {
        commandHeader(slot: slot, version: version) + deleteCableMolecule(cable)
    }

    /// Sam komunikat Cable Delete, bez nagłówka ramki — do pakowania kilku w jedną
    /// wysyłkę (patrz `batchPayload`).
    public static func deleteCableMolecule(_ cable: G2Cable) -> [UInt8] {
        let locationByte: UInt8 = cable.area == .voice ? 1 : 0
        return [
            subDeleteCable,
            0x02 | locationByte,
            UInt8(cable.fromModule),
            linkTypeConnectorByte(cable),
            UInt8(cable.toModule),
            UInt8(cable.toConnector),
        ]
    }

    /// SUB_COMMAND_DELETE_MODULE (0x32) — usuwa JEDEN moduł. W G2-Edit (`mouseHandle.c`)
    /// zawsze poprzedzone skasowaniem wszystkich kabli tego modułu — stąd taka sama
    /// kolejność w `G2MidiManager.sendPatch`.
    public static func deleteModulePayload(slot: UInt8, version: UInt8, module: G2Module) -> [UInt8] {
        commandHeader(slot: slot, version: version) + deleteModuleMolecule(module)
    }

    /// SUB_COMMAND (0x33, Module Name) — **zmiana nazwy JEDNEGO modułu na żywo**.
    /// Moduł zostaje na miejscu i gra dalej; zmienia się sama etykieta.
    ///
    /// Układ pól potwierdzony **podwójnie, niezależnie**:
    /// Module Name (WriteStream) w oryginalnym edytorze Clavii (`Initialize(0x33, typ 0)`,
    /// potem obszar, numer modułu i nazwa — **zmiennej długości**, tym samym pisarzem
    /// `PutString` co nazwa performance'u, patrz `claviaString`) oraz BVerhue Gen2/Gen3
    /// (`TG2MessPatch.AddSetModuleLabelMessage` / `TG2Message.AddMessModuleLabel`:
    /// `S_SET_MODULE_LABEL = $33`, location, moduleIndex, `WriteClaviaString`).
    /// Trzecim, słabszym potwierdzeniem samego numeru jest `g2ools/g2ctl.py`
    /// (`g2SendSetModuleLabel = 0x33`) — tam bez treści komunikatu.
    ///
    /// Typ komunikatu to 0, więc urządzenie potwierdza go przez `SUB_RESPONSE_OK`.
    public static func setModuleNamePayload(slot: UInt8, version: UInt8, module: G2Module) -> [UInt8] {
        commandHeader(slot: slot, version: version) + setModuleNameMolecule(module)
    }

    /// Sam komunikat Module Name, bez nagłówka ramki — patrz `batchPayload`.
    public static func setModuleNameMolecule(_ module: G2Module) -> [UInt8] {
        let locationByte: UInt8 = module.area == .voice ? 1 : 0
        return [subModuleName, locationByte, UInt8(module.id)] + claviaString(module.label)
    }

    /// SUB_COMMAND (0x42, Custom Data) — **dodatkowe dane JEDNEGO modułu na żywo**: własne
    /// podpisy parametrów (kanały miksów, przełączniki), widok SeqNote; w obszarze 2 moduł 1
    /// to nazwy ośmiu morfów. `content` to treść wpisu z sekcji 0x5B pliku, bez numeru
    /// i długości (`G2ModuleLabelSection.Entry`).
    ///
    /// Układ z dwóch źródeł: oryginalny edytor (komunikat `0x42`: obszar zapisany tak samo
    /// jak w Module Name, numer modułu, długość, bajty) i BVerhue Gen2
    /// `AddCopyModuleParamLabelsMessage` (`S_SET_PARAM_LABEL = $42`, location, potem
    /// `TParamLabelModuleList.Write`: moduł, długość, wpisy). BVerhue wysyła to dla modułu
    /// odtwarzanego po cofnięciu kasowania — tak jak my dla modułu wstawionego albo wklejonego.
    /// Obszar 2 (nazwy morfów) u BVerhue nie występuje — potwierdza go Clavia i sprzęt (niżej).
    ///
    /// ✅ **Zweryfikowane na żywym G2 37 (firmware 1.62) 2026-10-23**: `USBProbe --labeltest-slot D`,
    /// podpis „Value” przyjęty (`7F`) i oddany przy odczycie slotu bajt w bajt; obszar 2 tak samo
    /// (`--morphnametest-slot D`: morf 1 „Wheel” → „ClTest” i z powrotem, reszta nazw nietknięta).
    public static func setParamLabelMolecule(location: UInt8, moduleID: Int, content: [UInt8]) -> [UInt8] {
        [subParamLabel, location, UInt8(moduleID), UInt8(min(content.count, 255))] + content.prefix(255)
    }

    /// SUB_COMMAND (0x34, Module Move) — **przesunięcie JEDNEGO modułu na żywo**.
    /// Ten sam kształt co `0x33`, tylko zamiast nazwy dwa bajty pozycji w siatce.
    ///
    /// Źródła jak przy nazwie: Module Move (WriteStream) (obszar, numer modułu,
    /// kolumna, wiersz) i BVerhue `TG2Message.AddMessModuleMove` (`S_MOV_MODULE = $34`,
    /// `location, moduleIndex, col, row`); numer także w `g2ools` (`g2SendMoveModule`).
    ///
    /// Uwaga przy przesuwaniu grupy: urządzenie przyjmuje po jednym module, a przesunięcie
    /// w edytorze potrafi zepchnąć sąsiadów — dlatego różnica patcha wyłapuje **każdy**
    /// moduł ze zmienioną pozycją, nie tylko ten chwycony myszą.
    public static func setModulePositionPayload(slot: UInt8, version: UInt8, module: G2Module) -> [UInt8] {
        commandHeader(slot: slot, version: version) + setModulePositionMolecule(module)
    }

    /// Sam komunikat Module Move, bez nagłówka ramki — patrz `batchPayload`.
    public static func setModulePositionMolecule(_ module: G2Module) -> [UInt8] {
        let locationByte: UInt8 = module.area == .voice ? 1 : 0
        return [subModuleMove, locationByte, UInt8(module.id),
                UInt8(module.column), UInt8(module.row)]
    }

    /// SUB_COMMAND (0x31, Module Recolor) — **zmiana koloru JEDNEGO modułu na żywo**.
    /// Ten sam kształt co `0x33`, tylko zamiast nazwy jeden bajt koloru.
    ///
    /// Źródła jak wyżej: Module Recolor (WriteStream) (obszar, numer modułu, kolor)
    /// i BVerhue `TG2MessPatch.AddSetModuleColorMessage` (`S_SET_MODULE_COLOR = $31`),
    /// numer także w `g2ools` (`g2SendSetModuleColor = 0x31`).
    public static func setModuleColorPayload(slot: UInt8, version: UInt8, module: G2Module) -> [UInt8] {
        commandHeader(slot: slot, version: version) + setModuleColorMolecule(module)
    }

    /// Sam komunikat Module Recolor, bez nagłówka ramki — patrz `batchPayload`.
    public static func setModuleColorMolecule(_ module: G2Module) -> [UInt8] {
        let locationByte: UInt8 = module.area == .voice ? 1 : 0
        return [subModuleColor, locationByte, UInt8(module.id), module.color]
    }

    /// SUB_COMMAND (0x2A, Module AB Code) — **uprate jednego modułu na żywo**: obszar,
    /// numer modułu, `1` = częstotliwość audio, `0` = sterowania. Nord sam tego nie liczy;
    /// bez tej komendy moduł dopięty kablem audio grał dalej z częstotliwością sterowania.
    ///
    /// Źródła: oryginalny edytor (Module AB Code (WriteStream): `Initialize(0x2a)`,
    /// obszar, moduł, wartość; wysyłany przez Patch Data (GenerateBandwidthChangeMolecules)),
    /// G2-Edit `eMsgCmdSetModuleUpRate` (`SUB_COMMAND_SET_MODULE_UPRATE = 0x2a`)
    /// i BVerhue `AddSetUprateMessage` (`S_SET_UPRATE = $2A`).
    public static func setModuleUprateMolecule(_ module: G2Module) -> [UInt8] {
        let locationByte: UInt8 = module.area == .voice ? 1 : 0
        return [subModuleUprate, locationByte, UInt8(module.id), module.uprate ? 1 : 0]
    }

    /// SUB_COMMAND (0x21, Patch Header Dump) — **opis patcha na żywo**: liczba głosów,
    /// Poly/Mono/Legato, kategoria, wysokość kanwy i widoczność kolorów kabli. To jedyna
    /// droga, którą `Voices`/`Polyphony`/`Category` z pasa slotu dojeżdżają do Norda —
    /// do 2026-09-18 nie wysyłaliśmy jej wcale, więc suwak `Voices` nic nie robił.
    ///
    /// Układ potwierdzony **podwójnie, niezależnie**:
    /// 1. Oryginalny edytor Clavii: `CPatch::RequestPatchHeaderChange` →
    ///    `CPatch::SendPatchHeaderBubble` → new Patch Header Dump(Patch Header Data 11 const&)
    ///    → `UserBubbleOutput`, czyli ta sama droga co `AddModule`. Numer molekuły pada dwa
    ///    razy niezależnie w TplMoleculeBuilder<Patch Header Dump, (unsigned char)33, …>,
    ///    a Patch Header Dump (WriteStream) woła Patch Header Data 11 (WriteStream) —
    ///    **dokładnie tego samego pisarza, którym zapisywany jest plik `.pch2`**.
    /// 2. `reference/G2-Edit/src/protocol.c` `write_patch_descr`: ten sam układ bitów
    ///    i ta sama długość ciała (15 bajtów), poprzedzona dwubajtową długością.
    ///
    /// **Dlaczego z dwubajtową długością:** molekuła należy do rodziny „dump"
    /// (`EDestination 2` — razem z `0x4a`, `0x4d`, `0x52`, `0x5a`), a te same sekcje
    /// z takim samym nagłówkiem `[typ][długość]` wysyłamy dziś w strumieniu `0x37`,
    /// który Nord przyjmuje (zmierzone 2026-09-05).
    ///
    /// ⚠️ Ciało niesie też **aktywną wariację** — `description` ma więc pochodzić
    /// z bieżącego odczytu slotu, nie z pustego modelu.
    ///
    /// `sectionBody` → `PatchParser.descriptionSectionBody(_:original:)`.
    ///
    /// ✅ **Zweryfikowane na żywym Nordzie 2026-09-18** (`USBProbe --descriptiontest-slot D`):
    /// urządzenie odpowiada `SUB_RESPONSE_OK`, a odczyt slotu pokazuje wszystkie trzy
    /// wysłane pola (`Voices`, Mono/Poly, kategoria). **Zmierzone przy okazji:** Nord
    /// **nie bierze** od nas ani 7 bajtów nieznanych danych, ani `unk2` — po zapisie
    /// zeru wysłanemu w tych miejscach odpowiada nadal własnym `83 FC 00 00 01 00 00`
    /// i `unk2 = 2`. Podkład z zer jest więc bezpieczny, a wariacja i wysokość kanwy
    /// wracają dokładnie takie, jakie im wysłano → [[Docs/usb/protocol-map]].
    public static func setPatchDescriptionPayload(slot: UInt8, version: UInt8,
                                                  sectionBody: [UInt8]) -> [UInt8]
    {
        commandHeader(slot: slot, version: version)
            + [subPatchDumpResponse,
               UInt8((sectionBody.count >> 8) & 0xFF), UInt8(sectionBody.count & 0xFF)]
            + sectionBody
    }

    /// Sam komunikat Module Delete, bez nagłówka ramki — patrz `batchPayload`.
    public static func deleteModuleMolecule(_ module: G2Module) -> [UInt8] {
        let locationByte: UInt8 = module.area == .voice ? 1 : 0
        return [subDeleteModule, locationByte, UInt8(module.id)]
    }

    /// SUB_COMMAND_SET_PARAM (0x40) — zmienia JEDEN parametr na żywo, na aktualnie
    /// aktywnym slocie urządzenia (patrz `selectSlotPayload`). Komenda typu
    /// `COMMAND_WRITE_NO_RESP` (0x30), NIE `COMMAND_REQ` — urządzenie nie odsyła
    /// `SUB_RESPONSE_OK`/`ERROR`. Wywołujący nie może na nic czekać (patrz `commandNoRespSlot`).
    ///
    /// Układ pól potwierdzony podwójnie, niezależnie, bajt po bajcie identyczny:
    /// `reference/G2-Edit/src/usbComms.c` `send_write_data` case `eMsgCmdSetValue`
    /// oraz BVerhue Gen1 `TG2MessSlot.CreateSetParamMessage` (`g2_mess.pas:3657`).
    ///
    /// **`variation` musi być wariacją AKTYWNĄ na urządzeniu, nie zerem** — G2-Edit
    /// wysyła tu `gPatchDescr[gSlot].activeVariation` (`mouseHandle.c:1026/1390`),
    /// czyli pole `activeVariation` z sekcji opisu patcha (`protocol.c:52`, u nas
    /// `G2PatchDescription.variation`). Do 2026-09-04 wpisywaliśmy tu na sztywno `0`:
    /// zapis trafiał wtedy do wariacji 0, a gdy Nord grał inną, zmiana była zapisywana
    /// w pamięci slotu, ale nie słychać jej było na żywo — patrz [[Docs/usb/actor]].
    /// **Zweryfikowane na żywym sprzęcie 2026-09-03** — `USBProbe --livetest-slot D`,
    /// za pierwszym razem, patrz [[Docs/usb/actor]] „Real-time parametry".
    public static func setParameterPayload(slot: UInt8, version: UInt8, area: PatchArea, moduleID: Int, paramIndex: Int, value: Int, variation: Int = 0) -> [UInt8] {
        setParameterPayload(slot: slot, version: version, location: area == .voice ? 1 : 0,
                            moduleID: moduleID, paramIndex: paramIndex, value: value, variation: variation)
    }

    /// Ta sama komenda z **surowym numerem obszaru**. Obszar 2 to ustawienia patcha:
    /// moduł 1 (`PATCH_MORPH`) trzyma osiem gałek morfu (parametry 0–7) i osiem źródeł
    /// (8–15), moduły 2–7 resztę ustawień. Tą drogą oryginał przestawia morf „G Wh 1"
    /// w nowym patchu na G2X (`[2][1][12][2][127]`) → [[Docs/ui/menu-spec]].
    public static func setParameterPayload(slot: UInt8, version: UInt8, location: UInt8, moduleID: Int, paramIndex: Int, value: Int, variation: Int = 0) -> [UInt8] {
        [commandTag, commandNoRespSlot(slot), version]
            + setParameterMolecule(location: location, moduleID: moduleID, paramIndex: paramIndex,
                                   value: value, variation: variation)
    }

    /// Sam komunikat Param Change, bez nagłówka ramki — do pakowania kilku w jedną
    /// wysyłkę (patrz `setParametersPayload`).
    public static func setParameterMolecule(location: UInt8, moduleID: Int, paramIndex: Int,
                                            value: Int, variation: Int) -> [UInt8]
    {
        [subSetParam, location, UInt8(moduleID), UInt8(paramIndex), UInt8(value), UInt8(variation & 0xFF)]
    }

    /// **Kilka zmian parametrów w jednej ramce** — tak Patch Adjuster oryginału wypuszcza
    /// wszystkie ataki albo wszystkie rezonanse naraz: `CPatch::ApplyDistribution` zbiera
    /// po jednej molekule Param Change na parametr, a `RealTimeBubbleOutput` wysyła
    /// całą listę jednym komunikatem. Nagłówek jest ten sam co w `setParameterPayload`
    /// (`COMMAND_WRITE_NO_RESP`, bez potwierdzenia), molekuły idą jedna za drugą.
    /// Pusta lista daje pustą tablicę — nie ma czego wysyłać.
    /// **Niezweryfikowane na żywym sprzęcie** (paczki molekuł strukturalnych — tak).
    public static func setParametersPayload(slot: UInt8, version: UInt8,
                                            changes: [G2ParameterChange], variation: Int) -> [UInt8]
    {
        guard !changes.isEmpty else { return [] }
        return [commandTag, commandNoRespSlot(slot), version] + changes.flatMap { change in
            setParameterMolecule(location: change.area == .voice ? 1 : 0, moduleID: change.moduleID,
                                 paramIndex: change.paramIndex, value: change.value, variation: variation)
        }
    }

    /// `S_ASSIGN_KNOB` (0x25) — **przypina parametr do gałki panelu** (0–119, czyli
    /// 15 stron po 8). Bajt po numerze parametru trzyma obszar w dwóch najstarszych
    /// bitach i `isLed` w kolejnych dwóch, reszta zerami; numer gałki idzie jako słowo
    /// 16-bitowe. Tak samo wychodzi z obu źródeł: Clavia Knob Assign (WriteStream)
    /// (`moduł`, `parametr`, 2 bity obszaru, 2 bity `isLed`, `PutUWord(gałka)`) i BVerhue
    /// `AddMessKnobAssign` (`moduł`, `parametr`, 2 bity obszaru + 6 zer, zero, gałka) —
    /// BVerhue po prostu zawsze wpisuje w miejsce `isLed` zero.
    ///
    /// Komenda **z potwierdzeniem** (u Clavii typ komunikatu 0, nie „real time"),
    /// więc leci jako `COMMAND_REQ | COMMAND_SLOT` z wersją slotu.
    /// **Niezweryfikowane na żywym sprzęcie.**
    public static func assignKnobPayload(slot: UInt8, version: UInt8, location: UInt8,
                                         moduleID: Int, paramIndex: Int,
                                         knob: Int, isLed: Int = 0) -> [UInt8]
    {
        [
            commandTag, commandReqSlot(slot), version, subAssignKnob,
            UInt8(moduleID & 0xFF), UInt8(paramIndex & 0x7F),
            (location & 0x03) << 6 | UInt8(isLed & 0x03) << 4,
            UInt8((knob >> 8) & 0xFF), UInt8(knob & 0xFF),
        ]
    }

    /// `S_DEASSIGN_KNOB` (0x26) — zwalnia gałkę panelu. Payload to sam numer gałki
    /// jako słowo 16-bitowe (Clavia Knob Deassign (WriteStream) → `PutUWord`,
    /// BVerhue `AddMessKnobDeassign` → bajt zera i bajt numeru).
    /// **Niezweryfikowane na żywym sprzęcie.**
    public static func deassignKnobPayload(slot: UInt8, version: UInt8, knob: Int) -> [UInt8] {
        [
            commandTag, commandReqSlot(slot), version, subDeassignKnob,
            UInt8((knob >> 8) & 0xFF), UInt8(knob & 0xFF),
        ]
    }

    // MARK: - Strona parametrów z focusem (0x2D / 0x1E)

    /// `S_SEL_PARAM_PAGE` (0x2D) — **która z piętnastu stron parametrów jest wybrana**
    /// na panelu urządzenia. Payload to jeden bajt 0…14; grupa A…E to `strona / 3`,
    /// numer 1…3 to `strona % 3 + 1` (`CParameterPages::SetFocusedParameterPage`).
    ///
    /// Komenda **z potwierdzeniem**: Parameter Page Focus (WriteStream) woła
    /// `Initialize(0x2d, 0, 1)`, a typ 0 znaczy „zwykły zapis" — czyli `COMMAND_REQ |
    /// COMMAND_SLOT` z wersją slotu, jak przy wyborze wariacji. Molekuła należy do
    /// kontekstu patcha (`CMolecule::CMolecule(this, 0)`), stąd numer slotu w nagłówku.
    ///
    /// **Zweryfikowane na żywym G2 37 (firmware 1.62) 2026-09-09, W OBIE STRONY:** wybór
    /// strony w oknie przestawia panel Norda, a przycisk na froncie przestawia okno.
    public static func parameterPageFocusPayload(slot: UInt8, version: UInt8, page: Int) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version, subResponseParameterPageFocus,
         UInt8(page & 0x7F)]
    }

    /// `S_SEL_GLOBAL_PAGE` (0x1E) — to samo dla stron GLOBALNYCH performance'u.
    /// Global Parameter Page Focus siedzi w kontekście performance'u
    /// (`CMolecule::CMolecule(this, 3)`), więc idzie jako komenda systemowa z wersją
    /// systemu — tak samo jak zegar główny (0x3F), który dzieli ten kontekst.
    ///
    /// ⚠️ **Wciąż niesprawdzone na sprzęcie.** Test 2026-09-09 potwierdził SAM PRZEŁĄCZNIK
    /// Global Pages (`0x3F` pole 2) — nie wybór strony przy włączonym Global Pages, bo
    /// wtedy trzeba jeszcze kliknąć A…E albo 1…3.
    public static func globalParameterPageFocusPayload(version: UInt8, page: Int) -> [UInt8] {
        [commandTag, commandReqSys, version, subResponseGlobalParameterPageFocus,
         UInt8(page & 0x7F)]
    }

    /// Payload obu komunikatów to jeden bajt numeru strony. Odrzucamy numery spoza
    /// 0…14 — piętnaście stron to twarda granica i u Clavii (`SetFocusedParameterPage`
    /// sprawdza `strona / 3 < 5`), i w naszym modelu 120 gałek.
    public static func decodeParameterPageFocus(_ payload: [UInt8]) -> Int? {
        guard let page = payload.first, page < 15 else { return nil }
        return Int(page)
    }

    /// Assigns one MIDI CC to a patch parameter (Ctrl Assign (WriteStream)).
    public static func assignMidiControllerPayload(slot: UInt8, version: UInt8, cc: Int,
                                                   location: UInt8, moduleID: Int,
                                                   paramIndex: Int) -> [UInt8]
    {
        [
            commandTag, commandReqSlot(slot), version, subAssignMidiController,
            location & 0x03, UInt8(moduleID & 0xFF), UInt8(paramIndex & 0x7F),
            UInt8(cc & 0x7F),
        ]
    }

    /// Removes one MIDI CC assignment (Ctrl Deassign (WriteStream)).
    public static func deassignMidiControllerPayload(slot: UInt8, version: UInt8,
                                                     cc: Int) -> [UInt8]
    {
        [commandTag, commandReqSlot(slot), version, subDeassignMidiController, UInt8(cc & 0x7F)]
    }

    /// `S_SET_MORPH_RANGE` (0x43) — **zakres morfu dla jednego parametru** w jednej
    /// wariacji. Zakres jest liczbą ze znakiem, ale w komunikacie idzie jako wartość
    /// bezwzględna plus osobny bajt znaku — dokładnie tak rozkłada ją Clavia
    /// (Morph Change (WriteStream): zapisuje `|delta|`, potem `delta < 0`) i BVerhue
    /// (`AddMessMorphSet(…, aAbsRange, aNegative, …)`). Zakres 0 kasuje przypisanie
    /// (BVerhue `AddMessClearMorph` nie ma osobnej komendy — wysyła zero).
    ///
    /// Komenda **bez potwierdzenia**, jak `SET_PARAM`: BVerhue wysyła ją tą samą drogą
    /// (`TSendParamThread.SendTable`, `CMD_NO_RESP + CMD_SLOT + slot`, wersja slotu
    /// w nagłówku), a u Clavii typ komunikatu jest argumentem — z menu parametru leci
    /// jako „real time". **Niezweryfikowane na żywym sprzęcie.**
    ///
    /// `location`: 0 = FX, 1 = Voice, 2 = ustawienia patcha (morfowane bywają i one).
    public static func setMorphRangePayload(slot: UInt8, version: UInt8, location: UInt8,
                                            moduleID: Int, paramIndex: Int,
                                            morph: Int, range: Int, variation: Int) -> [UInt8]
    {
        let clamped = max(-128, min(127, range))
        return [
            commandTag, commandNoRespSlot(slot), version, subSetMorphRange,
            location, UInt8(moduleID & 0xFF), UInt8(paramIndex & 0x7F), UInt8(morph & 0x0F),
            UInt8(abs(clamped) & 0xFF), clamped < 0 ? 1 : 0, UInt8(variation & 0xFF),
        ]
    }

    /// `S_SEL_VARIATION` (0x6A) — **wybór wariacji slotu**, czyli tego zestawu wartości
    /// parametrów, który patch faktycznie gra. U Clavii wariacja nazywa się „param setting"
    /// i przełącza ją `CPatch::InternalSetFocusedParamSetting` → molekuła
    /// Param Setting Focus (`WriteStream` → `Initialize(0x6a, …)`, jeden bajt numeru).
    ///
    /// Komenda **z potwierdzeniem** (`COMMAND_REQ | COMMAND_SLOT`, wersja slotu w nagłówku)
    /// — tak wysyła ją BVerhue (`TG2Slot.InitMsg` + `AddMsgSelectVariation`), w odróżnieniu
    /// od `SET_PARAM`, które potwierdzenia nie ma. Ten sam numer przychodzi z powrotem,
    /// gdy wariację przełączy ktoś na froncie Norda (patrz `subResponseSelectVariation`).
    /// **Niezweryfikowane na żywym sprzęcie.**
    public static func selectVariationPayload(slot: UInt8, version: UInt8, variation: Int) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version, subResponseSelectVariation, UInt8(variation & 0x0F)]
    }

    /// `S_COPY_VARIATION` (0x44) — **przepisuje jedną wariację na drugą**: `from` → `to`.
    /// Urządzenie kopiuje u siebie parametry wszystkich modułów obu obszarów oraz
    /// ustawienia patcha; u Clavii robi to `CPatch::HandleParamSettingCopy` (trzy obszary
    /// + mapy morfów), u BVerhue `TG2Patch.CopyVariation`.
    ///
    /// Tą samą komendą oryginał obsługuje przycisk **Init** w pasku patcha (dymek „recall
    /// variation init"): wysyła kopię z wariacji 8 (init) do bieżącej. Kolejność bajtów
    /// jest w obu źródłach identyczna: najpierw źródło, potem cel.
    /// **Niezweryfikowane na żywym sprzęcie.**
    public static func copyVariationPayload(slot: UInt8, version: UInt8, from: Int, to: Int) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version, subCopyVariation, UInt8(from & 0x0F), UInt8(to & 0x0F)]
    }

    /// SUB_COMMAND (0x4D) — Module Param Dump, zbiorczy dump WSZYSTKICH parametrów
    /// (obu obszarów, wszystkich wariacji). Ta sama zasada odrzucania wiodącego bajtu typu
    /// co `cableDumpPayload` — patrz tam.  **Niezweryfikowane na żywym sprzęcie.**
    public static func paramDumpPayload(slot: UInt8, version: UInt8, combinedSectionBytes: [UInt8]) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version, subParamDump] + Array(combinedSectionBytes.dropFirst())
    }

    /// SUB_COMMAND (0x5A) — Module Name Dump, zbiorczy dump nazw wszystkich modułów
    /// (obu obszarów). Ta sama zasada odrzucania wiodącego bajtu typu co
    /// `cableDumpPayload` — patrz tam. **Niezweryfikowane na żywym sprzęcie.**
    public static func moduleNameDumpPayload(slot: UInt8, version: UInt8, combinedSectionBytes: [UInt8]) -> [UInt8] {
        [commandTag, commandReqSlot(slot), version, subModuleNameDump] + Array(combinedSectionBytes.dropFirst())
    }

    // MARK: - Dekodowanie pakietu interrupt (endpoint 0x81, 16B)

    enum InterruptKind: Equatable {
        case extended(dataLength: Int), embedded(dataLength: Int), unknown
    }

    /// Bajt 0: [dataLength:4b (embedded)][type:4b]. Dla `extended` bajty 1-2 (BE) niosą
    /// prawdziwą długość danych do dociągnięcia z endpointu 0x82; bajty 3+ muszą być
    /// zerowym paddingiem (jak w int_rec()), inaczej pakiet jest odrzucany.
    static func decodeInterruptHeader(_ bytes: [UInt8]) -> InterruptKind {
        guard let first = bytes.first else { return .unknown }
        let embeddedLength = Int((first >> 4) & 0x0F)
        let type = first & 0x0F

        switch type {
        case responseTypeExtended:
            guard bytes.count >= 3 else { return .unknown }
            let paddingOK = bytes.dropFirst(3).allSatisfy { $0 == 0 }
            guard paddingOK else { return .unknown }
            let dataLength = (Int(bytes[1]) << 8) | Int(bytes[2])
            return .extended(dataLength: dataLength)

        case responseTypeEmbedded:
            return .embedded(dataLength: embeddedLength)

        default:
            return .unknown
        }
    }

    // MARK: - Walidacja ramki "extended" (endpoint 0x82)

    /// Ostatnie 2 bajty to CRC16 nad resztą. Zwraca dane bez CRC gdy się zgadza.
    public static func validateExtendedFrame(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 2 else { return nil }
        let dataBytes = Array(bytes[0 ..< (bytes.count - 2)])
        let expectedCrc = (UInt16(bytes[bytes.count - 2]) << 8) | UInt16(bytes[bytes.count - 1])
        guard crc16(dataBytes) == expectedCrc else { return nil }
        return dataBytes
    }

    /// Ciało komunikatu „embedded" (całość w jednym pakiecie z 0x81) — bez bajtu nagłówka
    /// i bez CRC. **Zapowiedziana długość OBEJMUJE CRC**, dokładnie jak w ramce „extended":
    /// zmierzone 2026-09-05 na ramkach zegara, gdzie `0x5D` z trzema bajtami danych
    /// przychodzi jako dziewięć bajtów ciała (`01 04 00 5D` + `01 00 78` + CRC). Dowód nie
    /// wymagał znajomości nagłówka: dla każdej z pięciu zmierzonych ramek istnieje dokładnie
    /// JEDEN nagłówek, przy którym suma się zgadza — i we wszystkich pięciu ten sam
    /// → [[Docs/usb/protocol-map]] „Ramka PRZYCHODZĄCA embedded niesie CRC".
    ///
    /// Bez tego CRC zostawał doklejony do payloadu: dekodery czytające stałe pozycje od
    /// początku nic sobie z tego nie robiły, ale każdy liczący cokolwiek z `payload.count`
    /// dostawał o dwa bajty za dużo — i to bajty wyglądające jak zwykłe dane.
    public static func embeddedBody(_ interrupt: [UInt8], dataLength: Int) -> [UInt8]? {
        guard interrupt.count > 1 else { return nil }
        return validateExtendedFrame(Array(interrupt.dropFirst().prefix(dataLength)))
    }

    // MARK: - Dekodowanie treści odpowiedzi (po zdjęciu ew. prefiksu/CRC)

    /// Bit 3 bajtu `commandResponse`: **1 = to jest odpowiedź na NASZĄ komendę**,
    /// 0 = urządzenie odezwało się z własnej inicjatywy. Nie zgadujemy tego z treści —
    /// tak liczy to oryginał: Synth Port USB (BuildHeaderAndData) robi `param_1[1] >> 3 & 1`
    /// i wkłada wynik do `CInputMessage::IsResponse`, na którym
    /// Synth Port (HandleReceivedData) rozdziela CAŁY ruch przychodzący
    /// → [[Docs/usb/actor]] „Jak Clavia paruje odpowiedź z komendą".
    public static let responseFlag: UInt8 = 0x08
    /// Bity 0–2 tego samego bajtu to numer slotu (`param_1[1] & 7` w oryginale).
    /// Dla komunikatów systemowych wychodzi 4 — wtedy pole nic nie znaczy.
    public static let slotMask: UInt8 = 0x07

    public struct DecodedResponse: Sendable {
        public let responseType: UInt8
        public let commandResponse: UInt8?
        public let version: UInt8?
        public let subCommand: UInt8?
        public let payload: [UInt8]

        /// Urządzenie odezwało się samo (ruch gałki, przełączony slot, strumień wskaźników,
        /// załadowany patch) — to nie jest odpowiedź na nic, co wysłaliśmy.
        public var isSynthInitiated: Bool {
            guard responseType != G2UsbProtocol.responseTypeInit, let commandResponse else { return false }
            return commandResponse & G2UsbProtocol.responseFlag == 0
        }

        /// Numer slotu, którego dotyczy komunikat — z bajtu odpowiedzi, nie z licznika pętli.
        /// `nil` dla komunikatów systemowych (pole wychodzi wtedy poza zakres 0–3).
        public var slot: UInt8? {
            guard let commandResponse else { return nil }
            let slot = commandResponse & G2UsbProtocol.slotMask
            return slot < UInt8(G2UsbProtocol.maxSlots) ? slot : nil
        }
    }

    /// bytes[0] = responseType. Dla 0x80 (Init) nie ma pól nagłówka — reszta bajtów to
    /// przedstawienie się urządzenia (`decodeDeviceIdentity`), więc trafia do `payload`
    /// zamiast być wyrzucana.
    /// W przeciwnym razie: [commandResponse][version][subCommand][payload...].
    public static func decodeResponseBody(_ bytes: [UInt8]) -> DecodedResponse? {
        guard let responseType = bytes.first else { return nil }
        if responseType == responseTypeInit {
            return DecodedResponse(responseType: responseType, commandResponse: nil, version: nil,
                                   subCommand: nil, payload: Array(bytes.dropFirst()))
        }
        guard bytes.count >= 4 else { return nil }
        return DecodedResponse(
            responseType: responseType,
            commandResponse: bytes[1],
            version: bytes[2],
            subCommand: bytes[3],
            payload: Array(bytes[4...])
        )
    }

    /// Odpowiedź `0x1F` na zmianę trybu (`0x3E`): jeden bajt (znaczenie niepotwierdzone,
    /// zapewne numer performance'u), potem rekordy `[0x36][slot][wersja]` czterech slotów.
    /// Zmierzone na G2 37, firmware 1.62, 2026-10-15: `05 · 36 00 10 · 36 01 18 · 36 02 12
    /// · 36 03 0C` — każdy slot o jeden wyżej niż przed przełączeniem.
    public static func decodePerformanceReleaseVersions(_ payload: [UInt8]) -> [(slot: UInt8, version: UInt8)] {
        guard payload.count >= 2, payload[1] == subPatchVersionResponse else { return [] }
        return decodePatchVersions(Array(payload.dropFirst(2)))
    }

    /// Payload odpowiedzi SUB_RESPONSE_PATCH_VERSION (0x36): [slot][version].
    ///
    /// Numer slotu **musi** mieścić się w czterech slotach — tak samo jak w
    /// `decodeSelectSlot`. Bajt spoza zakresu znaczy, że to nie jest ten komunikat
    /// (np. odpowiedź `0x27` z nazwą patcha, która wpadła w cudze oczekiwanie: pierwsze
    /// dwa znaki nazwy dawały wtedy „slot 87"). Bez tego warunku wynik szedł prosto
    /// w `slotVersions[…]` i aplikacja padała na `Index out of range`
    /// → [[Docs/context/bug-history]] #63.
    public static func decodePatchVersion(_ payload: [UInt8]) -> (slot: UInt8, version: UInt8)? {
        guard payload.count >= 2, payload[0] < UInt8(maxSlots) else { return nil }
        return (payload[0], payload[1])
    }

    /// Odpowiedź na zrzut CAŁEGO performance'u (`0x1A`): urządzenie oddaje nowe numery
    /// sesji **wszystkich pięciu** rzeczy naraz — czterech slotów i samego performance'u
    /// (numer 4, ten sam co w `LoadFromBank`). Rekordy `[0x36][slot][wersja]` idą jeden
    /// za drugim, przy czym pierwszy bajt `0x36` zjada nagłówek komunikatu.
    ///
    /// Zmierzone na **G2 37, firmware 1.62, 2026-09-10**:
    /// `36 00 0E · 36 01 09 · 36 02 09 · 36 03 09 · 36 04 01` — a cztery późniejsze
    /// zapytania `0x35` oddały dokładnie te same numery slotów.
    public static func decodePatchVersions(_ payload: [UInt8]) -> [(slot: UInt8, version: UInt8)] {
        var result: [(slot: UInt8, version: UInt8)] = []
        var index = 0
        while index + 1 < payload.count {
            result.append((payload[index], payload[index + 1]))
            index += 2
            guard index < payload.count, payload[index] == subPatchVersionResponse else { break }
            index += 1
        }
        return result
    }

    /// Payload odpowiedzi SUB_RESPONSE_PATCH_NAME (0x27): sama nazwa, do 16 znaków.
    /// Dwa niezależne źródła zgodne co do treści: BVerhue `TG2Slot.ProcessMsgPatchName`
    /// (`BVE.NMG2Slot.pas:671`) czyta znak po znaku do 16, przerywając na bajcie 0,
    /// a G2-Edit (`usbComms.c` `SUB_RESPONSE_PATCH_NAME`) drukuje bajty ≤ 0x7F.
    /// Nazwa krótsza niż 16 znaków ma terminator, dokładnie 16-znakowa go nie ma —
    /// tak samo jak przy zapisie w `setPatchPayload`.
    public static func decodePatchName(_ payload: [UInt8]) -> String {
        let nameBytes = payload.prefix(16).prefix { $0 != 0 && $0 <= 0x7F }
        return String(decoding: nameBytes, as: UTF8.self)
    }

    /// Payload powiadomienia `SUB_RESPONSE_PARAM_CHANGE` (0x40) — urządzenie ogłasza
    /// zmianę parametru dokonaną NA FRONCIE Norda (gałka, przycisk). Ten sam numer
    /// i ten sam układ pięciu bajtów co komenda wychodząca `setParameterPayload`
    /// (`defs.h` komentuje to wprost: „used for response and set command"), odczyt
    /// przepisany z `parse_param_change` w `reference/G2-Edit/src/usbComms.c`.
    /// Numer obszaru USTAWIEŃ patcha w protokole — trzeci obok fx (0) i voice (1).
    /// Nie ma go w `PatchArea`, bo nie trzymamy tam modułów, tylko `G2VariationSettings`.
    public static let settingsLocation = 2

    ///
    /// `location` zostaje **surowym numerem obszaru**, bo Nord nadaje tu także **2 —
    /// ustawienia patcha** (gałki i źródła morfów to moduł 1 tego obszaru, Glide/Bend/
    /// Vibrato moduły 3–7). `PatchArea` zna tylko voice i fx, więc sprowadzenie bajtu do
    /// niego wpisywałoby ustawienie patcha do modułu FX o tym samym numerze
    /// → [[Docs/usb/notifications]].
    public static func decodeParamChange(_ payload: [UInt8])
        -> (location: Int, moduleID: Int, paramIndex: Int, value: Int, variation: Int)?
    {
        guard payload.count >= 5 else { return nil }
        return (Int(payload[0]), Int(payload[1]), Int(payload[2]), Int(payload[3]), Int(payload[4]))
    }

    /// Payload powiadomienia `SUB_COMMAND_SELECT_SLOT` (0x09) odebranego od urządzenia:
    /// jeden bajt z nowym numerem slotu. Urządzenie nadaje to, gdy użytkownik przełączy
    /// slot na froncie — `parse_command_response` w G2-Edit ustawia z tego `gSlot`.
    public static func decodeSelectSlot(_ payload: [UInt8]) -> UInt8? {
        guard let slot = payload.first, slot < UInt8(maxSlots) else { return nil }
        return slot
    }
}

/// Jedna zmiana wartości parametru — element listy dla `setParametersPayload`,
/// czyli tego, co oryginał trzyma w bąblu jako Param Change.
public struct G2ParameterChange: Hashable, Sendable {
    public let area: PatchArea
    public let moduleID: Int
    public let paramIndex: Int
    public let value: Int

    public init(area: PatchArea, moduleID: Int, paramIndex: Int, value: Int) {
        self.area = area
        self.moduleID = moduleID
        self.paramIndex = paramIndex
        self.value = value
    }
}
