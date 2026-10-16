// DeviceConnection.swift
// Most między UI (PatchState/ContentView) a `G2MidiManager` (actor USB w G2Core).
// Nie zawiera logiki protokołu — tylko stan połączenia widoczny w SwiftUI, samoczynne
// łączenie z urządzeniem i rozdzielanie powiadomień, które Nord nadaje sam z siebie.
//
// Model połączenia jest taki jak w oryginalnym edytorze Clavii (sprawdzone na El Capitan,
// 2026-09-03): **nie ma przycisku Connect**. Edytor sam znajduje urządzenie, sam pokazuje
// to, co na nim jest, i na bieżąco śledzi zmiany robione na froncie Norda.

import Foundation
import G2Core
import Observation

@MainActor
@Observable
public final class DeviceConnection {
    public enum Status: Equatable {
        /// Szukamy urządzenia — nie jest podłączone albo właśnie zniknęło.
        /// To NIE jest błąd: brak Norda w gnieździe to normalny stan pracy z plikami.
        case searching
        case connecting
        case connected
        case error(String)
    }

    public private(set) var status: Status = .searching

    /// Slot AKTYWNY na urządzeniu. Zmienia się w obie strony: gdy użytkownik przełączy
    /// slot w edytorze (`selectTargetSlot`) i gdy przełączy go na froncie Norda
    /// (powiadomienie `SUB_COMMAND_SELECT_SLOT`).
    public private(set) var activeSlot: Int = 0

    /// Czym przedstawiło się urządzenie (model + firmware). `nil` bez połączenia.
    /// Oryginał pyta o to samo pierwszą komendą po otwarciu portu i dopiero wtedy wie,
    /// czym steruje — my dotąd tę odpowiedź wyrzucaliśmy → [[Docs/usb/protocol-map]].
    public private(set) var deviceIdentity: G2UsbProtocol.DeviceIdentity?

    /// Po drugiej stronie stoi wirtualny G2 (atrapa), a nie sprzęt. Belka pisze wtedy
    /// „Virtual G2" i świeci innym kolorem: bez tego emulator zapomniany w tle wygląda
    /// dokładnie jak podłączony Nord, bo przedstawia się tym samym modelem
    /// i firmware'em → [[Docs/usb/emulator]].
    public private(set) var isVirtualDevice = false

    /// Nagłówek performance'u odczytany Z URZĄDZENIA — stąd wiadomo, **które sloty grają
    /// i który dostaje klawiaturę**. `nil`, dopóki Nord tego nie powie; wtedy przyciski
    /// slotów pokazują tylko to, co wie otwarty plik → [[Docs/usb/slots]].
    public private(set) var devicePerformance: G2PerformanceSettings?

    /// Nazwa performance'u, którą urządzenie podało w tej samej odpowiedzi, co nagłówek
    /// (podkomenda `0x29`). Trzymamy ją, żeby nie wysyłać nazwy, którą Nord już ma —
    /// oryginał pilnuje tego samego (Performance dialog (TrySendData) porównuje przed
    /// wysłaniem) → [[Docs/usb/slots]].
    public private(set) var devicePerformanceName: String?

    /// Surowe bajty sekcji `0x11`, tak jak przyszły z urządzenia. To jedyny szkielet
    /// nagłówka, jaki mamy dla performance'u **bez pliku** (nowa performance, zawartość
    /// odczytana z Norda) — zapis idzie przez przepisanie gotowych bajtów, żeby pola,
    /// których nie rozumiemy, zostały takie, jakie urządzenie samo miało.
    public private(set) var devicePerformanceSection: [UInt8]?

    /// Czy Nord stoi w trybie **Performance** (cztery sloty razem), czy **Patch**
    /// (gra jeden). `nil`, dopóki urządzenie nie odpowie. Czytane przy łączeniu
    /// (`0x02` → bit trybu), przestawiane komendą `0x3E`.
    public private(set) var performanceMode: Bool?

    /// Ustawienia samego urządzenia (okno Synth Settings): nazwa Norda, kanały MIDI,
    /// strojenie, pedał, Memory Protect. `nil` bez połączenia — tych danych nie ma
    /// w żadnym pliku, więc bez Norda okno nie ma czego pokazać
    /// → [[Docs/usb/synth-settings]].
    public private(set) var synthSettings: G2SynthSettings?

    /// Surowy payload odpowiedzi `0x03`, tak jak przyszedł. Zapis przepisuje te bajty
    /// z podmienionymi polami — jak przy nagłówku performance'u, żeby pola, których
    /// nie rozumiemy, zostały takie, jakie urządzenie samo miało.
    private var synthSettingsRaw: [UInt8]?

    /// Które sloty grają (`slot enabled` nagłówka, aktualizowane powiadomieniem 0x07).
    /// Puste, gdy urządzenie jeszcze nic nie powiedziało.
    public var playingSlots: [Bool] {
        devicePerformance?.slots.map(\.enabled) ?? []
    }

    /// Które sloty dostają klawiaturę (czerwona kreska nad przyciskiem w oryginale).
    public var keyboardSlots: [Bool] {
        devicePerformance?.slots.map(\.keyboard) ?? []
    }

    // MARK: - Zegar główny

    /// Tempo zegara głównego zgłoszone przez urządzenie. `nil`, dopóki Nord nic nie
    /// powiedział — wtedy pasek pokazuje `---`, tak jak oryginał bez patcha.
    ///
    /// Dwa źródła, bo urządzenie ma dwa zegary: własny (nagłówek performance'u, potem
    /// powiadomienia `0x3F`) i zewnętrzny (`0x5D`, 16-bitowy). Oryginał wybiera między
    /// nimi tak samo, w `CSynth::GetClockRate` → [[Docs/ui/master-clock]] §6.1.
    public var clockBPM: Int? {
        clockIsExternal ? externalClockBPM ?? internalClockBPM : internalClockBPM
    }

    private var internalClockBPM: Int?
    private var externalClockBPM: Int?
    public private(set) var clockRunning = false
    /// Tempo przychodzi z zewnątrz (MIDI clock) — odczyt na czerwono, strzałki martwe.
    /// Fałsz, dopóki urządzenie nie odpowie na pytanie o zegar: tak samo zakłada oryginał
    /// → [[Docs/ui/master-clock]] §6.2.
    public private(set) var clockIsExternal = false

    /// Trwa wysyłka zawartości edytora do Norda — tekst do pokazania użytkownikowi
    /// (`nil`, gdy nic nie wysyłamy). Wysyłka jednego slotu to kilkaset komend, więc
    /// bez tego wygląda jak zawieszenie aplikacji.
    public private(set) var sendProgress: String?
    /// Ułamek wysyłki slot po slocie (0…1) dla paska nad kanwą; `nil` = postęp nieznany
    /// (cały performance jedną komendą, odczyt z Norda) — pasek jedzie wtedy bez procentów.
    public private(set) var transferFraction: Double?
    public var isSending: Bool {
        sendProgress != nil
    }

    /// Trwa odczyt Z Norda — patch załadowany na froncie urządzenia, przełączony slot,
    /// zwolniony performance. Cztery sloty to ~72 kB czytane przy zatrzymanym strumieniu,
    /// więc bez sygnału edytor przez tę chwilę wygląda na zawieszony.
    public private(set) var loadProgress: String?
    public var isLoading: Bool {
        loadProgress != nil
    }

    /// Czy urządzenie robi coś, na co użytkownik czeka: wysyłka, odczyt albo pierwsze
    /// czytanie slotów po podłączeniu. Stąd kręcące się kółko w pasku narzędzi.
    public var isBusy: Bool {
        isSending || isLoading || status == .connecting || bankUpload != nil
    }

    /// Patch z banku Norda w drodze: od `0x0A` do końca odczytu slotu, który Nord po nim
    /// ogłasza — a gdy odczyt nie przyjdzie, najwyżej `bankLoadHold`. Między nimi nic się
    /// nie dzieje, więc `isBusy` tej przerwy nie widział i dało się kliknąć następny patch.
    public private(set) var isLoadingFromBank = false
    @ObservationIgnored private var bankLoadRelease: Task<Void, Never>?
    private static let bankLoadHold: UInt64 = 4_000_000_000

    /// Czy wolno teraz zmienić patch (przeglądarka wyszarza listy, gdy nie — prośba
    /// użytkownika 2026-10-15). Bez Norda zawsze wolno.
    public var acceptsPatchChange: Bool {
        !isBusy && !isLoadingFromBank
    }

    /// Poziomy wskaźników VU odczytane ze strumienia urządzenia dla slotu `meterSlot`.
    /// Puste, dopóki nie ma połączenia — wtedy wskaźniki na panelach są wygaszone.
    public private(set) var meters: [G2MeterReading] = []
    /// Grupy diod z tego samego strumienia: który krok sekwencera (albo które wyjście
    /// multipleksera) świeci w tej chwili — patrz `G2LedGroupReading`.
    public private(set) var ledGroups: [G2LedGroupReading] = []
    /// Pojedyncze diody (obwiednie, LFO, „Link" sekwencera) — osobny komunikat `0x39`.
    public private(set) var leds: [G2LedReading] = []
    public private(set) var meterSlot: Int = 0

    /// Obciążenie DSP każdego slotu, po jednym odczycie na obszar (`0x72`). Urządzenie
    /// nadaje je samo po każdej zmianie struktury patcha, więc panel pokazuje stan
    /// aktualny bez odpytywania. Puste, dopóki nie ma połączenia.
    public private(set) var patchLoad: [Int: [PatchArea: G2PatchLoad]] = [:]

    /// Obciążenie jednego obszaru slotu, o ile urządzenie już je podało.
    public func patchLoad(slot: Int, area: PatchArea) -> G2PatchLoad? {
        patchLoad[slot]?[area]
    }

    /// Zawartość banków w pamięci Norda. Czytana sama na końcu każdego połączenia
    /// (`readBanksAfterConnect`), potem na żądanie z panelu (`refreshBankList()`).
    public private(set) var bankEntries: [G2BankEntry] = []
    public private(set) var isReadingBanks = false

    /// Co panel Banks ostatnio załadował i dokąd: slot (0–3, performance = 4) → `G2BankEntry.id`.
    /// Panel podświetla te wiersze literą slotu. Znacznik gaśnie, gdy edytor wyśle do slotu
    /// własną zawartość (`send`) — wtedy w slocie nie leży już to, co w banku.
    /// Ładowania z frontu Norda tu nie widać: urządzenie nie mówi, skąd wziął patch.
    public private(set) var bankLoads: [Int: String] = [:]

    /// Dlaczego ostatnie ładowanie z banku się nie udało — panel pokazuje to nad listą.
    /// Nieudane ładowanie to nie zerwane połączenie: do 2026-10-14 przestawiało cały
    /// `status` na `.error`, a panel chował wtedy listę za mylącym „No G2 connected”.
    public private(set) var bankLoadError: String?

    /// Log surowych bajtów USB na konsolę. Domyślnie WYŁĄCZONY: `print` wykonuje się
    /// wewnątrz aktora USB, więc przy ruchu gałki (dziesiątki ramek/s) kosztuje na tym
    /// samym torze, którym lecą komendy. Włączany ręcznie, gdy trzeba zobaczyć transport.
    public var usbLogEnabled = false {
        didSet {
            guard usbLogEnabled != oldValue else { return }
            let enabled = usbLogEnabled
            Task { [weak self] in await self?.setLogging(enabled) }
        }
    }

    // MARK: - Wejścia z aplikacji (ustawia `RootView`)

    /// Zawartość slotów ściągnięta z urządzenia po połączeniu.
    public var onPatchesDownloaded: (([G2Patch]) -> Void)?
    /// Ruch gałki NA NORDZIE — parametr zmieniony na froncie urządzenia.
    public var onDeviceParameterChange: ((_ slot: Int, _ area: PatchArea, _ moduleID: Int, _ paramIndex: Int, _ value: Int, _ variation: Int) -> Void)?
    /// To samo dla obszaru USTAWIEŃ patcha (2): gałki i źródła morfów (moduł 1) oraz
    /// Glide/Bend/Vibrato/Arp (moduły 3–7).
    public var onDeviceSettingChange: ((_ slot: Int, _ moduleID: Int, _ paramIndex: Int, _ value: Int, _ variation: Int) -> Void)?
    /// Przełączenie slotu na froncie urządzenia.
    public var onDeviceSlotChange: ((Int) -> Void)?
    /// Przełączenie wariacji na froncie urządzenia.
    public var onDeviceVariationChange: ((_ slot: Int, _ variation: Int) -> Void)?
    /// Strona parametrów wybrana NA PANELU Norda (przyciski A…E / 1…3). `global`
    /// rozróżnia stronę slotu (`0x2D`) od strony performance'u (`0x1E`); `slot` jest
    /// `nil` dla tej drugiej, bo dotyczy całego performance'u.
    public var onDeviceParameterPageChange: ((_ slot: Int?, _ page: Int, _ global: Bool) -> Void)?
    /// Przełącznik Global Pages przestawiony na urządzeniu (`0x3F`, pole 2).
    public var onDeviceGlobalPagesChange: ((Bool) -> Void)?
    /// Slot odczytany na nowo, bo patch zmienił się NA URZĄDZENIU (użytkownik załadował
    /// inny patch z pamięci Norda).
    public var onDevicePatchReloaded: ((_ slot: Int, _ patch: G2Patch) -> Void)?
    /// Wszystkie cztery sloty odczytane na nowo — Nord ogłosił zmianę, ale nie powiedział
    /// którego slotu dotyczy (patrz `G2UsbProtocol.subResponsePerformanceRelease`).
    public var onDevicePatchesReloaded: (([G2Patch]) -> Void)?
    /// Patch, który edytor trzyma dla danego slotu — potrzebny, żeby rozłożyć strumień
    /// VU na moduły (komunikat nie niesie żadnej adresacji, patrz `G2VisualStream`).
    public var patchForSlot: ((Int) -> G2Patch?)?
    /// Czy wolno nadpisać zawartość edytora tym, co jest na urządzeniu. `RootView`
    /// odmawia, gdy użytkownik ma otwarty własny plik — połączenie samo w sobie nie
    /// może kasować czyjejś pracy.
    public var mayReplaceEditorContent: (() -> Bool)?
    /// Urządzenie wstało, a w edytorze już jest patch użytkownika (`mayReplaceEditorContent`
    /// = fałsz). Argument: czy to wirtualny G2 — ten dostaje patch zawsze, przy Nordzie
    /// decyduje opcja `ConnectContentMode`.
    public var onEditorContentAtConnect: ((_ virtualDevice: Bool) async -> Void)?
    /// Połączenie się urwało (kabel, wyłączony Nord) — od tej chwili zmiany w edytorze
    /// do Norda nie docierają.
    public var onDeviceLost: (() -> Void)?

    private let manager = G2MidiManager()
    private var autoConnectTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    /// Ruch gałki na froncie Norda, jeszcze nieoddany aplikacji — patrz `queueParameter`.
    private var pendingParameters: [ParameterKey: (value: Int, variation: Int)] = [:]
    private var parameterFlushTask: Task<Void, Never>?
    /// Odłożone przeładowania slotów (klucz = numer slotu) — patrz `scheduleReload`.
    private var reloadTasks: [Int: Task<Void, Never>] = [:]
    private var reloadAllTask: Task<Void, Never>?
    /// Ile odczytów jest w locie. Przeładowania potrafią się nałożyć (powiadomienie
    /// o slocie w trakcie odczytu całości) — ten, który skończy pierwszy, nie może
    /// zgasić wskaźnika drugiemu.
    private var loadCount = 0
    /// Nord ogłasza nową wersję slotu (0x38) po NASZYM zapisie tak samo, jak po patchu
    /// załadowanym z jego frontu — a ogłoszenie potrafi dojść chwilę po tym, jak wysyłka
    /// się u nas skończyła. Bez tej karencji edytor zaraz po otwarciu pliku odczytywałby
    /// z powrotem to, co przed sekundą sam tam wpisał (przy `.prf2` cztery razy).
    private var ignoreDeviceReloadsUntil = Date.distantPast
    /// Ostatnia zgłoszona zmiana strukturalna — następna czeka na nią (patrz `syncStructure`).
    private var structureSyncTask: Task<Void, Never>?
    /// Przesłuchanie zgłoszone w trakcie innego — wygrywa najnowsze (patrz `sendMutatorAudition`).
    private var pendingAudition: (slot: Int, patch: G2Patch, variation: Int)?
    private var auditionTask: Task<Void, Never>?
    /// Ostatni zapis z Mutatora do wariacji — następny czeka na niego (`sendVariationDump`).
    private var variationDumpTask: Task<Void, Never>?
    /// Wysyłka zgłoszona w trakcie innej wysyłki — jedno miejsce, wygrywa najnowsza.
    private var pendingUpload: (patches: [G2Patch], activeSlot: Int, performance: G2PerformanceSettings?,
                                fileData: Data?, slotFiles: [Data?], fileName: String, firstSlot: Int,
                                headerSent: Bool)?

    public init() {}

    // MARK: - Samoczynne łączenie

    /// Uruchamia pętlę, która pilnuje połączenia: łączy, gdy Nord się pojawi, i wraca
    /// do szukania, gdy zniknie (odłączony kabel kończy `pollTask` błędem). Wołane raz,
    /// przy starcie aplikacji.
    public func startAutoConnect() {
        guard autoConnectTask == nil else { return }
        autoConnectTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    public func stopAutoConnect() {
        autoConnectTask?.cancel()
        autoConnectTask = nil
    }

    private func tick() async {
        let deviceState = await manager.state
        switch deviceState {
        case .polling:
            if status != .connected { status = .connected }
        case .connecting:
            return
        case .disconnected, .error:
            // `.error` po zerwanym kablu: aktor sam zamknął urządzenie, więc kolejne
            // `connect()` zacznie od zera. Nie pokazujemy tego jako błędu aplikacji —
            // z punktu widzenia użytkownika Nord po prostu zniknął.
            if status == .connected {
                clearVisuals()
                patchLoad = [:]
                bankEntries = []
                devicePerformance = nil
                devicePerformanceName = nil
                devicePerformanceSection = nil
                deviceIdentity = nil
                isVirtualDevice = false
                resetClock()
                status = .searching
                onDeviceLost?()
            }
            await attemptConnect()
        }
    }

    private func attemptConnect() async {
        // „Connecting…" dopiero, gdy Nord jest w gnieździe. Bez niego pętla co 2 s
        // otwiera port na ułamek sekundy — pokazywane wtedy „Connecting…" (dłuższe niż
        // „No G2") przesuwało co chwilę wszystko na prawo od wskaźnika w pasku.
        do {
            await setLogging(usbLogEnabled)
            // Wskaźniki chodzą ZAWSZE. Przełącznik „Live Meters" zniknął z belki
            // 2026-09-11: wyłączenie ich nic nie przyspieszało, a odbierało edytorowi
            // jedyny podgląd tego, co naprawdę gra. Zawór u źródła
            // (`setVisualStreamEnabled`) zostaje — przyda się przy transferach hurtem.
            await manager.setVisualStreamEnabled(true)
            try await manager.connect(readPatches: true) {
                Task { @MainActor [weak self] in self?.status = .connecting }
            }
            deviceIdentity = await manager.identity
            isVirtualDevice = await manager.isEmulator
            try await startNotifications()
            try await manager.selectSlot(UInt8(activeSlot))
            // Nagłówek performance'u — bez niego przyciski slotów po podłączeniu
            // pokazywałyby stan z pliku (albo nic), a nie stan urządzenia.
            let header = try await readDevicePerformanceHeader()
            devicePerformance = header?.settings
            devicePerformanceName = header?.name
            devicePerformanceSection = header?.section
            applyClock(from: devicePerformance)
            // Ustawienia samego urządzenia — jedna komenda (`0x02`), a w odpowiedzi
            // zarówno tryb Performance/Patch (w trybie Patch gra dokładnie jeden slot
            // i selekcja slotów nie ma czym sterować → [[Docs/usb/slots]]), jak i cała
            // zawartość okna Synth Settings → [[Docs/usb/synth-settings]].
            let synth = try await manager.readSynthSettings()
            synthSettings = synth?.settings
            synthSettingsRaw = synth?.raw
            performanceMode = synth?.settings.performanceMode
            await refreshClockInfo()
            status = .connected
            if mayReplaceEditorContent?() ?? true {
                await onPatchesDownloaded?(manager.patches)
            } else {
                // Edytor ma własny patch. Wirtualny G2 startuje pusty, więc dostaje go od razu
                // (#121). Przy Nordzie do 2026-10-15 nie robiliśmy nic — ekran pokazywał
                // patch z edytora, a Nord grał swoje; teraz rozstrzyga `ConnectContentMode`.
                await onEditorContentAtConnect?(isVirtualDevice)
            }
            // Strona parametrów, którą Nord ma na panelu — okno ma po podłączeniu
            // pokazywać jego stronę, nie własne A1 (handshake pyta o nią `0x58`/`0x59`).
            //
            // **Po pobraniu slotów, nie przed.** Wczytanie zawartości urządzenia ustawia
            // stronę po swojemu (`focusFirstAssignedParameterPage` — pierwsza z przypisaniem
            // albo A1), więc odczyt postawiony wcześniej był natychmiast nadpisywany
            // i okno startowało zawsze na A1 → [[Docs/context/bug-history]] #77.
            if let page = await manager.parameterPage {
                onDeviceParameterPageChange?(activeSlot, page, false)
            }
            if let page = await manager.globalParameterPage {
                onDeviceParameterPageChange?(nil, page, true)
            }
            // `Global Pages` niesie nagłówek performance'u (sekcja 0x11) — stąd wiadomo,
            // czy panel Norda pokazuje wspólną mapę, czy mapę patcha.
            if let globalPages = header?.settings.globalPagesEnabled {
                onDeviceGlobalPagesChange?(globalPages)
            }
            // Banki od razu, na końcu połączenia — prośba użytkownika 2026-09-26 („po co
            // Read banks?"). Odczyt wstrzymuje wskaźniki na chwilę (Nord: 723 pozycje
            // w ~40 wymianach), a przy podłączaniu i tak nic jeszcze nie gra na ekranie.
            await readBanksAfterConnect()
        } catch G2UsbError.deviceNotFound {
            status = .searching // Nord nie jest podłączony — czekamy dalej, bez alarmu
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    public func disconnect() async {
        stopAutoConnect()
        notificationTask?.cancel()
        notificationTask = nil
        reloadTasks.values.forEach { $0.cancel() }
        reloadTasks.removeAll()
        reloadAllTask?.cancel()
        reloadAllTask = nil
        structureSyncTask?.cancel()
        structureSyncTask = nil
        auditionTask?.cancel()
        auditionTask = nil
        pendingAudition = nil
        await manager.disconnect()
        onDeviceLost?()
        clearVisuals()
        patchLoad = [:]
        bankEntries = []
        devicePerformance = nil
        devicePerformanceName = nil
        devicePerformanceSection = nil
        deviceIdentity = nil
        isVirtualDevice = false
        performanceMode = nil
        synthSettings = nil
        synthSettingsRaw = nil
        resetClock()
        status = .searching
    }

    // MARK: - Powiadomienia z urządzenia

    /// Strumień zamiast `Task { @MainActor in … }` przy każdym pakiecie: kolejność
    /// powiadomień musi być zachowana (dwie zmiany tej samej gałki w złej kolejności
    /// zostawiłyby złą wartość), a przy ~80 pakietach/s osobne zadania byłyby marnotrawstwem.
    /// Co `handle(_:)` niżej faktycznie obsługuje. Wszystko poza tą listą — obciążenie DSP
    /// (`0x72`), nuty (`0x69`), głosy (`0x05`), zaznaczony parametr (`0x2F`) — urządzenie
    /// nadaje gęsto, a u nas wpadało prosto w `default: break`. Przy grającym patchu były
    /// to dziesiątki przeskoków na `@MainActor` na sekundę, każdy w kolejce przed ruchem
    /// gałki. Oryginał też nie rozdaje po GUI tego, czego nie pokazuje.
    private static let handledSubCommands: Set<UInt8> = [
        G2UsbProtocol.subResponseParamChange,
        G2UsbProtocol.subResponseSelectSlot,
        G2UsbProtocol.subResponseSlotSelection,
        G2UsbProtocol.subResponseKeyboardFocus,
        G2UsbProtocol.subResponseSelectVariation,
        G2UsbProtocol.subResponseVolumeData,
        G2UsbProtocol.subResponseLedData,
        G2UsbProtocol.subResponseMasterClock,
        G2UsbProtocol.subSysClockInfoResponse,
        G2UsbProtocol.subResponsePatchVersionChange,
        G2UsbProtocol.subResponsePerformanceRelease,
        G2UsbProtocol.subPerformanceNameResponse,
        G2UsbProtocol.subResponsePatchLoad,
        G2UsbProtocol.subResponseParameterPageFocus,
        G2UsbProtocol.subResponseGlobalParameterPageFocus,
    ]

    private func startNotifications() async throws {
        notificationTask?.cancel()
        await manager.setNotificationFilter(Self.handledSubCommands)
        // Bufor celowo płytki: to kolejka OPÓŹNIENIA. Gdy UI nie nadąża, głęboki bufor
        // nie gubi zdarzeń, tylko odsuwa je w czasie — przy 256 pozycjach ruch gałki
        // z Norda mógł dojechać na ekran kilka sekund później. Wolimy zgubić zdarzenie
        // pośrednie niż pokazywać stan sprzed sekund; wartość i tak jest „ostatnia wygrywa".
        let (stream, continuation) = AsyncStream<G2Notification>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        await manager.setNotificationHandler { note in continuation.yield(note) }
        notificationTask = Task { @MainActor [weak self] in
            for await note in stream {
                guard let self else { break }
                self.handle(note)
            }
        }
    }

    private func handle(_ note: G2Notification) {
        let slot = Int(note.slot)
        switch note.subCommand {
        case G2UsbProtocol.subResponseParamChange:
            guard let change = G2UsbProtocol.decodeParamChange(note.payload) else { return }
            queueParameter(slot: slot, location: change.location, moduleID: change.moduleID,
                           paramIndex: change.paramIndex, value: change.value,
                           variation: change.variation)

        // Obciążenie DSP. Urządzenie liczy je po każdej zmianie struktury i nadaje samo,
        // więc panel jest aktualny bez odpytywania (`0x71` zostaje na wymuszony odczyt).
        case G2UsbProtocol.subResponsePatchLoad:
            for reading in G2UsbProtocol.decodePatchLoad(note.payload) {
                patchLoad[slot, default: [:]][reading.area] = reading
            }

        case G2UsbProtocol.subResponseSelectSlot:
            guard let newSlot = G2UsbProtocol.decodeSelectSlot(note.payload) else { return }
            activeSlot = Int(newSlot)
            // Focus przeniesiony na froncie Norda na slot, którego edytor w ogóle nie ma
            // (otwarty `.pch2` to jeden slot, a urządzenie ma cztery): użytkownik prosi
            // o coś, czego nie pokazujemy — czytamy synta w całości i dopiero wtedy
            // przełączamy widok (`scheduleReloadAll` na końcu powtarza to powiadomienie).
            if !isSending, !isEchoOfOwnUpload, let editorHas = patchForSlot, editorHas(Int(newSlot)) == nil {
                scheduleReloadAll()
            }
            onDeviceSlotChange?(Int(newSlot))

        // Nord **sam** wysyła cały nagłówek performance'u — nazwę i sekcję `0x11` — za
        // każdym razem, gdy zmieni się coś, co ta sekcja opisuje. Grających slotów nie
        // zgłasza żadną osobną komendą: w pomiarze `--listen` (2026-09-10, G2 37 firmware
        // 1.62) przez cały nasłuch z przełączaniem slotów na froncie nie przyszło ani jedno
        // `0x07` czy `0x0F` — za to `0x29` leciało po każdej zmianie, z pełną sekcją za
        // nazwą. Ten sam komunikat jest odpowiedzią na `0x10`, więc czyta go ten sam
        // parser → [[Docs/usb/slots]].
        case G2UsbProtocol.subPerformanceNameResponse:
            guard !isSending, !isEchoOfOwnUpload,
                  let header = PatchParser.parseUsbPerformanceHeader(payload: note.payload)
            else { return }
            devicePerformance = header.settings
            devicePerformanceName = header.name
            devicePerformanceSection = header.section
            applyClock(from: header.settings)
            onDeviceGlobalPagesChange?(header.settings.globalPagesEnabled)

        case G2UsbProtocol.subResponseSlotSelection:
            guard let enabled = G2UsbProtocol.decodeSlotSelection(note.payload) else { return }
            applyPlayingSlots(enabled)

        case G2UsbProtocol.subResponseKeyboardFocus:
            guard let keyboard = G2UsbProtocol.decodeSlotSelection(note.payload) else { return }
            applyKeyboardSlots(keyboard)

        case G2UsbProtocol.subResponseSelectVariation:
            guard let variation = note.payload.first else { return }
            onDeviceVariationChange?(slot, Int(variation))

        case G2UsbProtocol.subResponseVolumeData:
            updateMeters(slot: slot, payload: note.payload)

        case G2UsbProtocol.subResponseLedData:
            updateLeds(slot: slot, payload: note.payload)

        // Strona parametrów wybrana przyciskiem na froncie Norda. Strona slotu dotyczy
        // slotu z nagłówka, globalna — całego performance'u.
        case G2UsbProtocol.subResponseParameterPageFocus:
            guard let page = G2UsbProtocol.decodeParameterPageFocus(note.payload) else { return }
            onDeviceParameterPageChange?(slot, page, false)

        case G2UsbProtocol.subResponseGlobalParameterPageFocus:
            guard let page = G2UsbProtocol.decodeParameterPageFocus(note.payload) else { return }
            onDeviceParameterPageChange?(nil, page, true)

        case G2UsbProtocol.subResponseMasterClock:
            // Ta sama podkomenda niesie trzy pola nagłówka performance'u; Global Pages
            // (indeks 2) nie jest zegarem, więc rozstrzygamy je przed odczytem tempa.
            if let globalPages = G2UsbProtocol.decodeGlobalPages(note.payload) {
                onDeviceGlobalPagesChange?(globalPages)
                return
            }
            switch G2UsbProtocol.decodeMasterClock(note.payload) {
            case let .bpm(bpm): applyClockBPM(bpm)
            case let .running(running): applyClockRunning(running)
            case nil: return
            }

        case G2UsbProtocol.subSysClockInfoResponse:
            guard let info = G2UsbProtocol.decodeSysClockInfo(note.payload) else { return }
            applyClockInfo(info)

        // Obie zapowiedzi zmiany ignorujemy w trakcie WŁASNEJ wysyłki i chwilę po niej
        // (`isEchoOfOwnUpload`): odczytywalibyśmy z powrotem dokładnie to, co przed chwilą
        // sami tam wpisaliśmy (18 kB na slot).
        case G2UsbProtocol.subResponsePatchVersionChange:
            guard !isSending, !isEchoOfOwnUpload,
                  let changed = G2UsbProtocol.decodePatchVersion(note.payload) else { return }
            scheduleReload(slot: Int(changed.slot))

        case G2UsbProtocol.subResponsePerformanceRelease:
            guard !isSending, !isEchoOfOwnUpload else { return }
            scheduleReloadAll()

        default:
            break
        }
    }

    /// Czy to, co właśnie przyszło, jest jeszcze echem naszej własnej wysyłki
    /// (patrz `ignoreDeviceReloadsUntil`).
    private var isEchoOfOwnUpload: Bool {
        Date() < ignoreDeviceReloadsUntil
    }

    /// Wskaźniki rozkładamy tylko dla slotu, który jest na ekranie — dla pozostałych
    /// i tak nie ma czego rysować. Tempo (20×/s) ustawia `G2MidiManager`, jeszcze zanim
    /// pakiet dotrze na `@MainActor`.
    /// Gasi wszystko, co pokazuje strumień wizualny. Wołane wszędzie tam, gdzie stare
    /// odczyty przestają cokolwiek znaczyć: brak połączenia, inny slot, inny patch.
    /// Same wskaźniki nie wystarczą — zapalony krok sekwencera zostałby wtedy na ekranie.
    private func clearVisuals() {
        if !meters.isEmpty { meters = [] }
        if !ledGroups.isEmpty { ledGroups = [] }
        if !leds.isEmpty { leds = [] }
    }

    /// Rozkład strumienia wizualnego dla zawartości oglądanego slotu — patrz
    /// `G2VisualLayout`. Liczony przy zmianie struktury patcha, nie przy każdym pakiecie.
    private var visualLayout: G2VisualLayout?

    private func layout(for patch: G2Patch) -> G2VisualLayout {
        let signature = G2VisualLayout.signature(of: patch)
        if let visualLayout, visualLayout.signature == signature { return visualLayout }
        let fresh = G2VisualLayout(patch: patch)
        visualLayout = fresh
        return fresh
    }

    private func updateMeters(slot: Int, payload: [UInt8]) {
        guard slot == activeSlot, let patch = patchForSlot?(slot) else { return }
        let readings = G2VisualStream.decodeVolumeData(payload, layout: layout(for: patch))
        // Bez tego porównania canvas przerysowywałby się 20×/s także wtedy, gdy nic nie
        // gra i wszystkie wskaźniki stoją na zerze.
        guard readings.meters != meters || readings.ledGroups != ledGroups || slot != meterSlot
        else { return }
        meterSlot = slot
        meters = readings.meters
        ledGroups = readings.ledGroups
    }

    /// Pojedyncze diody (`0x39`) — obwiednie, LFO, „Link" sekwencera. Ten sam odsiew co
    /// przy wskaźnikach: bez zmiany nie budzimy widoku.
    private func updateLeds(slot: Int, payload: [UInt8]) {
        guard slot == activeSlot, let patch = patchForSlot?(slot) else { return }
        let readings = G2VisualStream.decodeLedData(payload, layout: layout(for: patch))
        guard readings != leds || slot != meterSlot else { return }
        meterSlot = slot
        leds = readings
    }

    // MARK: - Zegar główny

    /// Pyta urządzenie o stan zegara (`0x3B` → `0x5D`). Cicho odpuszcza, gdy odpowiedzi
    /// nie ma: to informacja pomocnicza, a nie warunek pracy edytora.
    private func refreshClockInfo() async {
        guard let info = try? await manager.readClockInfo() else { return }
        applyClockInfo(info)
    }

    /// BPM i Run z nagłówka performance'u (sekcja 0x11) — stan po podłączeniu i po każdej
    /// przebudowie performance'u, zanim jeszcze przyjdzie jakiekolwiek powiadomienie.
    private func applyClock(from settings: G2PerformanceSettings?) {
        guard let settings else { return }
        applyClockBPM(settings.masterClock)
        applyClockRunning(settings.masterClockRunning)
    }

    /// Każde przypisanie budzi obserwatorów SwiftUI niezależnie od tego, czy wartość się
    /// zmieniła, a `0x5D` przy zewnętrznym zegarze potrafi sypać gęsto. Porównanie robi to
    /// samo, co oryginał w TB Window (SetupState) (pisze do widoku tylko przy zmianie).
    private func applyClockBPM(_ bpm: Int) {
        guard internalClockBPM != bpm else { return }
        internalClockBPM = bpm
    }

    private func applyClockRunning(_ running: Bool) {
        guard clockRunning != running else { return }
        clockRunning = running
    }

    /// Nord zniknął — pasek wraca do `---` zamiast pokazywać tempo urządzenia,
    /// którego już nie ma.
    private func resetClock() {
        internalClockBPM = nil
        externalClockBPM = nil
        clockRunning = false
        clockIsExternal = false
    }

    private func applyClockInfo(_ info: (external: Bool, bpm: Int)) {
        if clockIsExternal != info.external { clockIsExternal = info.external }
        if info.external, externalClockBPM != info.bpm { externalClockBPM = info.bpm }
    }

    /// Tempo z paska narzędzi. Zewnętrzny zegar blokuje zmianę — oryginał wychodzi
    /// z `ChangeClockRate` bez wysłania czegokolwiek, gdy `IsClockExternal()`.
    public func setMasterClock(_ bpm: Int) async {
        guard status == .connected, !clockIsExternal else { return }
        let clamped = G2UsbProtocol.clampedBPM(bpm)
        applyClockBPM(clamped)
        do {
            try await manager.setMasterClock(bpm: clamped)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Run/Stop z paska narzędzi. Zegar zewnętrzny tego nie blokuje: blokada w oryginale
    /// dotyczy wyłącznie tempa.
    public func setClockRunning(_ running: Bool) async {
        guard status == .connected else { return }
        applyClockRunning(running)
        do {
            try await manager.setClockRunning(running)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Ruch gałki z urządzenia

    private struct ParameterKey: Hashable {
        let slot: Int
        /// Surowy numer obszaru z powiadomienia: 0 fx, 1 voice, **2 ustawienia patcha**.
        let location: Int
        let moduleID: Int
        let paramIndex: Int
    }

    /// Gałka kręcona na froncie nadaje **~200 zdarzeń na sekundę** w szczycie ruchu
    /// (zmierzone `USBProbe --listen` 2026-09-05: 408 zdarzeń w 5,3 s, mediana odstępu
    /// 5 ms, najkrótszy 1 ms), a każde z nich przerysowuje kanwę. Transport dowozi je
    /// natychmiast — nie nadążało rysowanie, więc obrót trwający ułamek sekundy
    /// odtwarzał się na ekranie „w zwolnionym tempie".
    ///
    /// Robimy to jak oryginał: zdarzenie ląduje w tablicy stanu (**ostatnia wartość
    /// wygrywa**), a aplikacja dostaje ją raz na klatkę. Wartość końcowa dociera zawsze,
    /// giną tylko przebiegi pośrednie — których i tak nie da się zobaczyć
    /// → [[Docs/usb/notifications]] „Jak radzi sobie z tym oryginał".
    private func queueParameter(slot: Int, location: Int, moduleID: Int, paramIndex: Int,
                                value: Int, variation: Int)
    {
        let key = ParameterKey(slot: slot, location: location, moduleID: moduleID, paramIndex: paramIndex)
        pendingParameters[key] = (value, variation)
        guard parameterFlushTask == nil else { return }
        parameterFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self else { return }
            self.parameterFlushTask = nil
            self.flushParameters()
        }
    }

    private func flushParameters() {
        let batch = pendingParameters
        pendingParameters.removeAll(keepingCapacity: true)
        for (key, change) in batch {
            if key.location == G2UsbProtocol.settingsLocation {
                onDeviceSettingChange?(key.slot, key.moduleID, key.paramIndex,
                                       change.value, change.variation)
            } else {
                onDeviceParameterChange?(key.slot, key.location == 1 ? .voice : .fx,
                                         key.moduleID, key.paramIndex,
                                         change.value, change.variation)
            }
        }
    }

    // MARK: - Przeładowanie slotu zmienionego na urządzeniu

    /// Pokazuje `message` na wskaźniku połączenia na czas odczytu i gasi go, gdy skończy
    /// się OSTATNI trwający odczyt.
    private func withLoadProgress(_ message: String, _ body: () async -> Void) async {
        loadCount += 1
        loadProgress = message
        defer {
            loadCount -= 1
            if loadCount == 0 {
                loadProgress = nil
                finishBankLoad()
            }
        }
        await body()
    }

    /// Ładowanie patcha na froncie Norda potrafi ogłosić zmianę wersji kilka razy pod rząd,
    /// a nasz własny `sendPatch` — raz na każdą z kilkuset komend. Bez odczekania na ciszę
    /// odczytalibyśmy ten slot kilkanaście razy, za każdym razem po ~18 kB.
    private func scheduleReload(slot: Int) {
        reloadTasks[slot]?.cancel()
        reloadTasks[slot] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.reloadTasks[slot] = nil
            await self.reloadPatch(slot: slot)
        }
    }

    /// Nord po załadowaniu patcha z frontu ogłasza Performance Release (0x1F) — zwolnił
    /// CAŁY performance, nie pojedynczy slot, i komunikat nie niesie numeru slotu. Oryginał
    /// odpowiada na to zbudowaniem swojego modelu synta od zera
    /// (`CSynth::HandlePerformanceRelease` → `CreateInitialPerformanceForSynth`), więc
    /// czytamy wszystkie cztery sloty.
    private func scheduleReloadAll() {
        reloadAllTask?.cancel()
        // Odczyt całości zawiera w sobie odczyt pojedynczych slotów. Gdyby oba biegły
        // naraz, dwie komendy czekałyby na odpowiedź z tego samego endpointu i podkradały
        // ją sobie nawzajem.
        reloadTasks.values.forEach { $0.cancel() }
        reloadTasks.removeAll()
        reloadAllTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.reloadAllTask = nil
            guard self.status == .connected else { return }
            // Nagłówek performance'u to stan URZĄDZENIA (które sloty grają, który ma
            // klawiaturę), a nie zawartość edytora — czytamy go nawet wtedy, gdy patchy
            // podmienić nie wolno. Bez tego przyciski slotów pokazywały selekcję sprzed
            // załadowania performance'u na Nordzie: cztery niebieskie, gdy na froncie
            // świeciły dwie diody. Powiadomienie 0x07 tu nie wystarcza — burzę
            // komunikatów po `0x1F` odbieramy w trakcie własnych komend, a te potrafią
            // wyrzucić zaległy pakiet razem ze śmieciami (`resynchronizeExtended`).
            await self.withLoadProgress("Loading from the G2…") {
                if let header = try? await self.readDevicePerformanceHeader() {
                    self.devicePerformance = header.settings
                    self.devicePerformanceName = header.name
                    self.devicePerformanceSection = header.section
                    self.applyClock(from: header.settings)
                    self.onDeviceGlobalPagesChange?(header.settings.globalPagesEnabled)
                    // Nowy performance = nowy stan zegara. Oryginał pyta o niego dokładnie
                    // w tym momencie: `CSynth` zapala flagę „informacja o zegarze
                    // nieaktualna" przy odtwarzaniu modelu synta, a `CleanDirtyData`
                    // wysyła wtedy `SendClockInfoRequests` → [[Docs/ui/master-clock]] §6.2.
                    await self.refreshClockInfo()
                    // Focus też jest w nagłówku (bity 3–2 drugiego bajtu sekcji 0x11)
                    // i oryginał bierze go WŁAŚNIE STĄD: `HandlePerformanceHeaderDump`
                    // zgłasza `FocusedSlotChangedFromSynth` i robi `PatchViewSelect`
                    // tym samym bajtem, którym robi to obsługa 0x09. Performance
                    // załadowany na froncie przestawia focus BEZ osobnego 0x09, więc
                    // bez tego ramka zostawała na slocie sprzed zmiany.
                    self.activeSlot = header.settings.focusedSlot
                }
                guard self.mayReplaceEditorContent?() ?? true else { return }
                do {
                    let patches = try await self.manager.reloadAllPatches()
                    self.clearVisuals()
                    self.onDevicePatchesReloaded?(patches)
                    // Widok idzie na slot, który ma focus NA URZĄDZENIU. Bez tego edytor po
                    // przejęciu zawartości Norda zostawałby na slocie A, choć na froncie
                    // świeci już inny — a to właśnie przełączenie focusu bywa powodem odczytu.
                    self.onDeviceSlotChange?(self.activeSlot)
                } catch {
                    self.status = .error(error.localizedDescription)
                }
            }
        }
    }

    private func reloadPatch(slot: Int) async {
        guard status == .connected, mayReplaceEditorContent?() ?? true else { return }
        await withLoadProgress("Loading slot \(Self.slotLabels[slot])…") {
            do {
                let patch = try await manager.reloadPatch(slot: UInt8(slot))
                // Nowy patch to inny zestaw modułów, więc dotychczasowe odczyty wskaźników
                // wskazują już na cudze moduły — do czasu następnego pakietu lepiej nic.
                if slot == meterSlot { clearVisuals() }
                onDevicePatchReloaded?(slot, patch)
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Wyjścia do urządzenia

    private static let slotLabels = ["A", "B", "C", "D"]

    /// Wgrywa zawartość edytora do Norda. Tak działa oryginał Clavii: slot urządzenia jest
    /// buforem roboczym edytora, więc otwarcie pliku od razu w nim ląduje (pamięć banków
    /// zostaje nietknięta — do niej trafia dopiero Store na froncie).
    ///
    /// Edytor ma zawsze cztery sloty i każdy idzie do swojego: cały most (gałki na żywo,
    /// wskaźniki, echo z frontu) zakłada, że numer slotu edytora i urządzenia to ta sama liczba.
    ///
    /// Cicho odmawia, gdy nie ma połączenia — otwieranie plików bez Norda to normalna praca.
    /// Otwarcie kolejnego pliku w trakcie wysyłki **nie może zginąć po cichu** — inaczej
    /// edytor pokazuje plik B, a w Nordzie ląduje A (zgłoszone 2026-09-04: „ładowałem jeden
    /// za drugim zanim się pierwszy załadował"). Nowe żądanie czeka w kolejce na jedno
    /// miejsce: liczy się najnowsze, bo to ono odpowiada temu, co widać na ekranie.
    /// `fileData` to bajty otwartego `.pch2`/`.prf2`. Gdy są, każdy slot idzie do Norda
    /// **jedną komendą** z całym patchem, tak jak robi to oryginał — patrz
    /// `G2UsbProtocol.setPatchPayload`. Bez nich (patch wczytany z urządzenia, nowy patch)
    /// zostaje wysyłka molekułami, wielokrotnie wolniejsza. `slotFiles` to bajty `.pch2`
    /// kolejnych patchy z tablicy — baza, gdy wspólnego pliku `.prf2` nie ma.
    ///
    /// `firstSlot` mówi, do którego slotu trafia pierwszy patch z tablicy. Domyślne zero
    /// obsługuje otwarcie pliku (cały dokument od slotu A); File → New Patch czyści tylko
    /// slot z focusem i wysyła jeden pusty patch pod jego numer.
    /// `headerSent` mówi, że sekcja `0x11` z tymi samymi ustawieniami **już leży
    /// w urządzeniu** (wysłał ją `send(_:)` przed slotami). Wtedy sloty grające,
    /// klawiatura i zegar są nią opisane i nie powtarzamy ich osobnymi komendami.
    public func upload(patches: [G2Patch], activeSlot: Int, performance: G2PerformanceSettings? = nil,
                       fileData: Data? = nil, slotFiles: [Data?] = [], fileName: String = "",
                       firstSlot: Int = 0, headerSent: Bool = false) async
    {
        guard status == .connected, !patches.isEmpty else { return }
        if isSending {
            pendingUpload = (patches, activeSlot, performance, fileData, slotFiles, fileName, firstSlot,
                             headerSent)
            return
        }
        await performUpload(patches: patches, activeSlot: activeSlot, performance: performance,
                            fileData: fileData, slotFiles: slotFiles, fileName: fileName,
                            firstSlot: firstSlot, headerSent: headerSent)
        while let next = pendingUpload {
            pendingUpload = nil
            await performUpload(patches: next.patches, activeSlot: next.activeSlot,
                                performance: next.performance,
                                fileData: next.fileData, slotFiles: next.slotFiles, fileName: next.fileName,
                                firstSlot: next.firstSlot, headerSent: next.headerSent)
        }
    }

    /// Strumienie sekcji per slot — treść komendy 0x37. Budujemy je z tych samych bajtów,
    /// które trafiłyby do pliku przy `Save` (`saveAll` nanosi na oryginał bieżące zmiany
    /// z edytora), więc do Norda idzie dokładnie to, co użytkownik widzi na ekranie.
    ///
    /// **Bez wspólnego pliku** każdy slot budujemy osobno — na bajtach jego `.pch2`, a bez
    /// nich (nowy patch, zawartość odczytana z Norda) na szkielecie `PatchParser.emptyPatchFile`. Do 2026-09-05
    /// wracaliśmy w tym miejscu do molekuł, a te zaczynają od skasowania slotu **modułu po
    /// module** — log ze sprzętu: `DeleteModule` co ~290 ms, kilkadziesiąt sekund ruchu na
    /// magistrali i migotanie diody „Load Patch" po każdym New Patch. Oryginał tej drogi nie
    /// zna: `CPatch::GetCompletePatchDump` buduje plik i wysyła go jedną komendą.
    ///
    /// Pusta tablica = nierozpoznany format → dopiero wtedy molekuły.
    private func sectionStreams(fileData: Data?, slotFiles: [Data?], patches: [G2Patch],
                                performance: G2PerformanceSettings?) -> [[UInt8]]
    {
        do {
            guard let fileData else {
                return try patches.indices.map { index in
                    let base = slotFiles.indices.contains(index) ? slotFiles[index] : nil
                    let file = try PatchParser.saveAll(originalData: base ?? PatchParser.emptyPatchFile,
                                                       patches: [patches[index]])
                    return try PatchParser.slotSectionStream(fileData: file, slot: 0)
                }
            }
            let current = try PatchParser.saveAll(originalData: fileData, patches: patches,
                                                  performance: performance)
            return try patches.indices.map {
                try PatchParser.slotSectionStream(fileData: current, slot: $0)
            }
        } catch {
            return []
        }
    }

    private func performUpload(patches: [G2Patch], activeSlot: Int, performance: G2PerformanceSettings?,
                               fileData: Data?, slotFiles: [Data?], fileName: String, firstSlot: Int,
                               headerSent: Bool) async
    {
        guard status == .connected, !patches.isEmpty else { return }
        let base = min(max(firstSlot, 0), G2UsbProtocol.maxSlots - 1)
        let targets = Array(patches.prefix(G2UsbProtocol.maxSlots - base))
        let streams = sectionStreams(fileData: fileData, slotFiles: slotFiles, patches: patches,
                                     performance: performance)
        // `.pch2` nie ma w sobie nazwy patcha — oryginał nazywa slot tak, jak nazywa się
        // plik. Nazwy slotów `.prf2` niesie sekcja 0x11 i te są już w `patch.name`.
        let fallbackName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        clearVisuals()
        defer {
            sendProgress = nil
            transferFraction = nil
        }
        for (offset, patch) in targets.enumerated() {
            let slot = base + offset
            sendProgress = targets.count > 1
                ? "Sending slot \(Self.slotLabels[slot]) (\(offset + 1) of \(targets.count))…"
                : "Sending to the G2…"
            transferFraction = targets.count > 1 ? Double(offset) / Double(targets.count) : nil
            do {
                // `sendPatch` sam zaczyna od `SelectSlot`, więc urządzenie zostaje na
                // ostatnim zapisanym slocie — stąd korekta na końcu pętli.
                var named = patch
                if named.name.isEmpty { named.name = fallbackName }
                // Pusty strumień znaczy „nie umiem zbudować tego slotu z pliku", nie
                // „wgraj pusty patch" — wtedy wracamy do wysyłki molekułami.
                let stream = streams.indices.contains(offset) ? streams[offset] : []
                try await manager.sendPatch(named, toSlot: UInt8(slot),
                                            sectionStream: stream.isEmpty ? nil : stream)
                self.activeSlot = slot
            } catch {
                status = .error(error.localizedDescription)
                return
            }
        }
        let target = min(max(activeSlot, base), base + targets.count - 1)
        self.activeSlot = target
        // **Performance opisuje się sam** — sekcja `0x11` niesie komplet: sloty grające,
        // klawiaturę, focus, Hold, zakresy klawiszy i zegar (zmierzone 2026-09-07,
        // `USBProbe --perfheaderrules`). Ale idzie PRZED slotami, a każdy wgrany slot Nord
        // zapala sam (`CSynth::DownloadPatch`: pobrany patch ma zagrać), więc po czterech
        // wgraniach grają wszystkie cztery — nagłówek mówił jedno, wysyłka slotów drugie.
        // Dlatego selekcję powtarzamy tu, ZA slotami, dokładnie w wersji z pliku.
        //
        // Czego tu nie ma i być nie może: `enabled[target] = true`. To ono sprawiało, że
        // performance z wyciszonym slotem A wchodził do Norda z A grającym, bo focus
        // edytora to nie to samo, co selekcja zapisana w pliku.
        if headerSent, let performance, targets.count > 1 {
            let enabled = performance.slots.map(\.enabled)
            var keyboard = zip(performance.slots.map(\.keyboard), enabled).map { $0 && $1 }
            if !keyboard.contains(true), let first = enabled.firstIndex(of: true) {
                keyboard[first] = true
            }
            applyPlayingSlots(enabled)
            applyKeyboardSlots(keyboard)
            do {
                // Performance bez jednego grającego slotu nie istnieje — takiego pliku nie ma
                // w kolekcji i urządzenie by go nie przyjęło, więc wtedy zostaje sam `0x09`.
                if enabled.contains(true) {
                    try await manager.setSlotSelection(enabled, keyboard: keyboard)
                }
                try await manager.selectSlot(UInt8(target))
            } catch {
                status = .error(error.localizedDescription)
            }
            ignoreDeviceReloadsUntil = Date().addingTimeInterval(1.0)
            return
        }
        // Pojedynczy patch: `CSynth::DownloadPatch` w oryginale WŁĄCZA slot docelowy
        // i daje mu focus — nie gasi pozostałych.
        var enabled: [Bool]
        var keyboard: [Bool]
        if let performance, targets.count > 1 {
            enabled = performance.slots.map(\.enabled)
            keyboard = performance.slots.map(\.keyboard)
            enabled[target] = true
            if !keyboard.contains(true) { keyboard[target] = true }
        } else {
            let empty = targets.indices
                .filter { targets[$0].voiceModules.isEmpty && targets[$0].fxModules.isEmpty }
                .map { base + $0 }
            (enabled, keyboard) = Self.slotSelectionAfterPatchUpload(playing: playingSlots, keyboard: keyboardSlots,
                                                                     target: target, emptySlots: empty)
        }
        do {
            try await manager.setSlotSelection(enabled, keyboard: keyboard)
            applyPlayingSlots(enabled)
            applyKeyboardSlots(keyboard)
            try await manager.selectSlot(UInt8(target))
        } catch {
            status = .error(error.localizedDescription)
        }
        // Bez nagłówka tempo trzeba dołożyć osobno — inaczej po New Performance edytor
        // pokazywał 120 BPM, a Nord grał w swoim starym tempie. `setMasterClock` sam
        // odmawia, gdy zegar jest zewnętrzny.
        if let performance, targets.count > 1 {
            await setMasterClock(performance.masterClock)
            await setClockRunning(performance.masterClockRunning)
        }
        ignoreDeviceReloadsUntil = Date().addingTimeInterval(1.0)
    }

    /// **Cały performance jednym komunikatem** (`0x1A` Complete Performance Dump) — dokładnie
    /// tak, jak robi to oryginał (`CSynth::CleanDirtyData`). Zrzut niesie nazwę, nagłówek
    /// `0x11`, cztery bloki patchy i mapę gałek globalnych, więc urządzenie nie widzi stanu
    /// pośredniego: to on kasuje usterkę **#79** u źródła, zamiast ją nadrabiać kolejnością.
    /// Zweryfikowane na żywym G2 37 (firmware 1.62) 2026-09-10 → [[Docs/usb/slots]].
    ///
    /// `false` = tego dokumentu nie da się tak wysłać (nie ma pliku `.prf2` albo sekcji `0x11`) **albo zrzut się nie powiódł**. W obu razach wraca
    /// droga slot po slocie: nowa jest ulepszeniem, stara — gwarancją.
    private func sendCompletePerformance(_ state: PatchState) async -> Bool {
        guard status == .connected,
              state.hasPerformanceSettings,
              state.slots.count == G2UsbProtocol.maxSlots,
              let original = state.performanceFileData
        else { return false }
        do {
            // Te same bajty, które trafiłyby do pliku przy `Save` — czyli to, co widać
            // na ekranie, a nie to, co leżało w pliku przed edycją.
            let current = try PatchParser.saveAll(originalData: original, patches: state.slots,
                                                  performance: state.performance)
            let header = try PatchParser.performanceSectionStream(fileData: current)
            let streams = try (0 ..< G2UsbProtocol.maxSlots).map {
                try PatchParser.slotSectionStream(fileData: current, slot: $0)
            }
            guard !header.isEmpty, !streams.contains(where: \.isEmpty) else { return false }
            let knobs = try PatchParser.performanceKnobMapStream(fileData: current)

            clearVisuals()
            sendProgress = "Sending the performance…"
            defer { sendProgress = nil }
            try await manager.sendCompletePerformanceDump(
                name: state.performanceName, headerSection: header,
                slotStreams: streams, knobMapSection: knobs, patches: state.slots
            )

            devicePerformance = state.performance
            devicePerformanceSection = header
            devicePerformanceName = state.performanceName
            applyClock(from: state.performance)
            let target = min(max(state.selectedSlot, 0), G2UsbProtocol.maxSlots - 1)
            activeSlot = target
            try await manager.selectSlot(UInt8(target))
            ignoreDeviceReloadsUntil = Date().addingTimeInterval(1.0)
            return true
        } catch {
            // Świadomie bez `status = .error`: zrzut jest ulepszeniem, a nie jedyną drogą.
            // Gdy nie przejdzie, sprawdzona wysyłka slot po slocie ma prawo spróbować.
            print("CompletePerformanceDump: \(error) — wracam do wysyłki slot po slocie")
            return false
        }
    }

    /// Wołane, gdy użytkownik przełączy slot w edytorze — Nord ma wejść w tryb edycji
    /// tego samego slotu (`SUB_COMMAND_SELECT_SLOT`), tak jak robi to oryginalny edytor.
    public func selectTargetSlot(_ slot: Int) async {
        let slotChanged = activeSlot != slot
        activeSlot = slot
        if slotChanged { clearVisuals() }
        guard status == .connected else { return }
        do {
            // Jak Slot Selection Info (SelectSlot) w oryginale: slot, który JUŻ GRA, zostaje
            // tylko przejęty do edycji — selekcji nikt nie rusza. Co zrobić z MILCZĄCYM,
            // wybiera użytkownik (`SilentSlotClick`): oryginał czyni go jedynym grającym,
            // domyślnie dokładamy go do grających.
            let alreadyPlaying = playingSlots.indices.contains(slot) && playingSlots[slot]
            if !alreadyPlaying,
               let selection = SilentSlotClick.stored.selection(
                   clicking: slot, playing: playingSlots, keyboard: keyboardSlots,
                   slotCount: G2UsbProtocol.maxSlots
               )
            {
                try await manager.setSlotSelection(selection.enabled, keyboard: selection.keyboard)
                applyPlayingSlots(selection.enabled)
                applyKeyboardSlots(selection.keyboard)
            }
            if slotChanged { try await manager.selectSlot(UInt8(slot)) }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Klawiatura po zmianie zestawu grających slotów: slot, który przestał grać, nie może
    /// zostać z klawiaturą, a przynajmniej jeden grający musi ją mieć — tak samo pilnuje
    /// tego oryginał (`CPerformance::SetSlotSelection`).
    private func keyboardAfter(_ enabled: [Bool]) -> [Bool] {
        var keyboard = keyboardSlots.count == enabled.count
            ? zip(keyboardSlots, enabled).map { $0 && $1 }
            : enabled
        if !keyboard.contains(true), let first = enabled.firstIndex(of: true) {
            keyboard[first] = true
        }
        return keyboard
    }

    /// Sloty grające po wgraniu patchy bez ustawień performance'u: docelowy gra, a sloty,
    /// które właśnie dostały PUSTY patch, gasną — inaczej po opcji „jak oryginał” (patch
    /// w A, B–D puste) świeciły sloty grające w poprzednim performansie (2026-10-15).
    /// Pozostałe zostają jak były, tak jak w oryginale (`CSynth::DownloadPatch` nie gasi).
    nonisolated static func slotSelectionAfterPatchUpload(playing: [Bool], keyboard: [Bool], target: Int,
                                                          emptySlots: [Int]) -> (enabled: [Bool], keyboard: [Bool])
    {
        let count = G2UsbProtocol.maxSlots
        var enabled = playing.count == count ? playing : [Bool](repeating: false, count: count)
        var keys = keyboard.count == count ? keyboard : [Bool](repeating: false, count: count)
        for slot in emptySlots where slot != target && enabled.indices.contains(slot) {
            enabled[slot] = false
            keys[slot] = false
        }
        enabled[target] = true
        if !keys.contains(true) { keys[target] = true }
        return (enabled, keys)
    }

    /// Bez nagłówka z urządzenia zaczynamy od domyślnego — powiadomienie o selekcji jest
    /// pełnym stanem czterech slotów, więc nie ma czego z czym scalać, a wyrzucenie go
    /// (tak było do 2026-09-05) znaczyło, że przyciski slotów milczą do końca sesji.
    private func applyPlayingSlots(_ enabled: [Bool]) {
        var performance = devicePerformance ?? G2PerformanceSettings()
        for (index, value) in enabled.enumerated() where performance.slots.indices.contains(index) {
            performance.slots[index].enabled = value
        }
        devicePerformance = performance
    }

    /// CTRL+kliknięcie w oryginale: przypisanie klawiatury do slotu. Instrukcja, str. 59:
    /// „All slot buttons that have a red line on top of them will follow the keyboard,
    /// activated slot buttons that do not have a red line will only follow MIDI."
    /// Ostatniej klawiatury nie da się zabrać — tak samo pilnuje tego oryginał.
    public func toggleKeyboardSlot(_ slot: Int) async {
        guard status == .connected, playingSlots.indices.contains(slot) else { return }
        var keyboard = keyboardSlots
        guard keyboard.indices.contains(slot) else { return }
        keyboard[slot].toggle()
        guard keyboard.contains(true) else { return }
        let enabled = playingSlots
        do {
            try await manager.setSlotSelection(enabled, keyboard: keyboard)
            applyKeyboardSlots(keyboard)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func applyKeyboardSlots(_ keyboard: [Bool]) {
        var performance = devicePerformance ?? G2PerformanceSettings()
        for (index, value) in keyboard.enumerated() where performance.slots.indices.contains(index) {
            performance.slots[index].keyboard = value
        }
        devicePerformance = performance
    }

    /// Przestawia Norda w tryb Performance / Patch (`0x3E` Performance Mode Change).
    /// W trybie Patch gra dokładnie jeden slot, więc selekcja slotów przestaje mieć
    /// znaczenie — dlatego przyciski slotów pytają o ten stan → [[Docs/usb/slots]].
    public func setPerformanceMode(_ performance: Bool) async {
        guard status == .connected, performanceMode != performance else { return }
        do {
            try await manager.setPerformanceMode(performance)
            performanceMode = performance
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Tryb Norda idzie za otwieranym dokumentem (decyzja użytkownika 2026-09-21,
    /// `PatchOpenMode`). Oryginał przełącza pełnym `0x03`, my `0x3E` — i **tylko przy
    /// faktycznej zmianie**: `0x3E` w trybie, który już jest, rozjeżdżał strumień (Nord
    /// zapowiadał dwie odpowiedzi i żadnej nie dostarczał, zmierzone 2026-10-15).
    /// Ograniczenie: przełączenie przyciskiem na froncie Norda nie przychodzi kablem
    /// (nasłuch 2026-10-15), a pytać o tryb (`0x02`) w trakcie sesji nie wolno — też
    /// rozjeżdżało strumień. Zapamiętany tryb to więc ten z podłączenia i z naszych zmian.
    /// Brak potwierdzenia nie zatrzymuje wysyłki dokumentu — bez niej ekran i Nord
    /// rozjeżdżały się (pusty slot na ekranie, w Nordzie stary patch).
    private func followDocumentMode(_ performance: Bool) async {
        guard status == .connected, performanceMode != performance else { return }
        sendProgress = performance ? "Switching the G2 to Performance mode…" : "Switching the G2 to Patch mode…"
        defer { sendProgress = nil }
        do {
            try await manager.setPerformanceMode(performance)
            performanceMode = performance
        } catch {
            // Tryb nieznany — następny dokument spróbuje znowu.
            performanceMode = nil
        }
    }

    /// Ustawienia performance'u zmienione W EDYTORZE (sheet Performance Settings):
    /// które sloty grają i który dostaje klawiaturę. Reszta pól sekcji `0x11`
    /// (Hold, zakres klawiatury) nie ma jeszcze własnej komendy — zostaje w pliku.
    public func sendSlotSelection(enabled: [Bool], keyboard: [Bool]) async {
        guard status == .connected,
              enabled.count == G2UsbProtocol.maxSlots,
              keyboard.count == G2UsbProtocol.maxSlots,
              enabled.contains(true)
        else { return }
        // Slot bez dźwięku nie może trzymać klawiatury, a ktoś ją trzymać musi —
        // ten sam warunek co przy klikaniu przycisków slotów.
        var fixed = zip(keyboard, enabled).map { $0 && $1 }
        if !fixed.contains(true), let first = enabled.firstIndex(of: true) { fixed[first] = true }
        do {
            try await manager.setSlotSelection(enabled, keyboard: fixed)
            applyPlayingSlots(enabled)
            applyKeyboardSlots(fixed)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Nazwa performance'u DO urządzenia (`0x29`) — to ona stoi na wyświetlaczu Norda.
    /// Oryginał wysyła ją w dwóch sytuacjach i obie mamy: jako pierwszą molekułę pełnego
    /// zrzutu performance'u (Complete Performance Dump — u nas `send(_:)`) i samotnie,
    /// gdy użytkownik zmieni nazwę w oknie ustawień (`CPerformance::SetPerformanceName`).
    ///
    /// Pustej nazwy nie wysyłamy — Nord pokazałby wtedy puste pole, a żadna droga
    /// oryginału do tego nie prowadzi (nowa performance nazywa się „Empty perf",
    /// wczytana z pliku — jak plik). Nazwy, którą urządzenie już ma, też nie:
    /// oryginał porównuje ją przed wysłaniem (Performance dialog (TrySendData)).
    public func sendPerformanceName(_ name: String) async {
        let trimmed = String(name.prefix(G2UsbProtocol.performanceNameLength))
        guard status == .connected, !trimmed.isEmpty, trimmed != devicePerformanceName else { return }
        do {
            try await manager.setPerformanceName(trimmed)
            devicePerformanceName = trimmed
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Cała sekcja ustawień performance'u DO urządzenia (`0x11`) — **jedyna komenda
    /// potrzebna, żeby opisać Nordowi cały performance**: Hold i zakresy klawiszy (których
    /// nie umie wysłać nic innego), a do tego sloty grające, klawiatura, focus i zegar.
    /// Zmierzone 2026-09-07 (`USBProbe --perfheaderrules`): sam nagłówek przestawia
    /// wszystkie te pola, więc `0x07`/`0x0F`/`0x3F` po nim się nie powtarza — tak samo
    /// jak Complete Performance Dump w oryginale → [[Docs/usb/slots]].
    ///
    /// Szkielet sekcji bierzemy z pliku, a gdy dokument pliku nie ma — z tego, co
    /// przeczytaliśmy z urządzenia. Bez żadnego z nich nie wysyłamy nic: zgadywane bajty
    /// w polach, których nie rozumiemy, byłyby gorsze niż brak komendy.
    ///
    /// Zwraca, czy urządzenie **ma teraz ten nagłówek** — wysłany przed chwilą albo
    /// identyczny z tym, który już w nim leżał. Od tego zależy, czy sloty i zegar
    /// wymagają jeszcze osobnych komend (patrz `performUpload`).
    @discardableResult
    public func sendPerformanceHeader(_ performance: G2PerformanceSettings, fileData: Data?) async -> Bool {
        guard status == .connected,
              let section = performanceHeaderSection(performance, fileData: fileData)
        else { return false }
        if section == devicePerformanceSection { return true } // urządzenie ma już to samo
        do {
            try await manager.setPerformanceHeader(section: section)
            devicePerformance = performance
            devicePerformanceSection = section
            return true
        } catch {
            status = .error(error.localizedDescription)
            return false
        }
    }

    private func performanceHeaderSection(_ performance: G2PerformanceSettings, fileData: Data?) -> [UInt8]? {
        let fromFile = fileData.flatMap { try? PatchParser.performanceSectionStream(fileData: $0) }
        guard let original = (fromFile?.isEmpty == false ? fromFile : nil) ?? devicePerformanceSection
        else { return nil }
        return PatchParser.performanceHeaderSection(originalSection: original, performance: performance)
    }

    /// Czy w zakładce Performance są zmiany, których Nord jeszcze nie ma — te same
    /// porównania, którymi `sendPerformanceName` i `sendPerformanceHeader` odsiewają
    /// zbędną wysyłkę. Od tego świeci przycisk „Send to G2” (prośba użytkownika 2026-10-15).
    public func performanceDiffersFromDevice(_ performance: G2PerformanceSettings, name: String,
                                             fileData: Data?) -> Bool
    {
        guard status == .connected else { return false }
        let trimmed = String(name.prefix(G2UsbProtocol.performanceNameLength))
        if !trimmed.isEmpty, trimmed != devicePerformanceName { return true }
        guard let section = performanceHeaderSection(performance, fileData: fileData) else { return false }
        return section != devicePerformanceSection
    }

    /// Ustawienia urządzenia z okna Synth Settings (`0x03`). Wysyłamy **tylko przy
    /// faktycznej zmianie** i zawsze w całości: oryginał robi to samo przy zamknięciu
    /// okna (Synth Settings dialog (TrySendData) porównuje kopię z tym, co Nord ma,
    /// i milczy, gdy są równe). Po wysłaniu zapamiętujemy nowy stan jako stan urządzenia
    /// — kolejne otwarcie okna ma pokazać to, co przed chwilą poszło w kabel.
    public func sendSynthSettings(_ settings: G2SynthSettings) async {
        guard status == .connected, let original = synthSettingsRaw,
              settings != synthSettings else { return }
        do {
            try await manager.setSynthSettings(settings, original: original)
            synthSettingsRaw = G2UsbProtocol.synthSettingsPayload(applying: settings, to: original)
            synthSettings = settings
            performanceMode = settings.performanceMode
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Dokłada/zabiera slot do grających, nie ruszając tego, co jest edytowane —
    /// odpowiednik SHIFT+kliknięcia w oryginale (Slot Selection Info (ToggleSlot)).
    /// Ostatni grający slot zostaje włączony: urządzenie bez żadnego grającego slotu
    /// milczy, a oryginał na to nie pozwala.
    public func togglePlayingSlot(_ slot: Int) async {
        guard status == .connected else { return }
        var enabled = playingSlots.count == G2UsbProtocol.maxSlots
            ? playingSlots
            : (0 ..< G2UsbProtocol.maxSlots).map { $0 == activeSlot }
        enabled[slot].toggle()
        guard enabled.contains(true) else { return }
        do {
            try await manager.setSlotSelection(enabled, keyboard: keyboardAfter(enabled))
            applyPlayingSlots(enabled)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Ponowny odczyt zawartości banków Norda — przycisk w panelu Banks. Trwa kilkanaście
    /// wymian z urządzeniem i zatrzymuje na ten czas strumień wskaźników. Pierwszy odczyt
    /// robi samo połączenie (`readBanksAfterConnect`).
    public func refreshBankList() async {
        guard status == .connected, !isReadingBanks, !isBusy else { return }
        isReadingBanks = true
        defer { isReadingBanks = false }
        do {
            bankEntries = try await manager.readBankList()
            bankLoads = [:]
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Nieudany odczyt banków przy podłączeniu nie jest awarią połączenia — panel pokaże
    /// wtedy przycisk „Read banks", a status zostaje „connected".
    private func readBanksAfterConnect() async {
        guard status == .connected, !isReadingBanks else { return }
        isReadingBanks = true
        defer { isReadingBanks = false }
        bankEntries = await (try? manager.readBankList()) ?? []
        bankLoads = [:]
    }

    /// Załadowanie patcha z banku Norda do slotu (`0x0A`). Urządzenie ogłosi zmianę samo,
    /// więc edytor podąży za nim zwykłą drogą powiadomień — tu nie przepisujemy niczego.
    public func loadFromBank(_ entry: G2BankEntry, intoSlot slot: Int) async {
        guard status == .connected, acceptsPatchChange else { return }
        let targetSlot: UInt8 = entry.kind == .performance ? 4 : UInt8(slot)
        bankLoadError = nil
        isLoadingFromBank = true
        bankLoadRelease?.cancel()
        bankLoadRelease = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.bankLoadHold)
            guard !Task.isCancelled else { return }
            self?.finishBankLoad()
        }
        do {
            try await manager.loadFromBank(slot: targetSlot, bank: entry.bank, patch: entry.patch)
            // Performance zastępuje wszystkie cztery sloty, patch rozbija performance.
            if targetSlot == 4 { bankLoads = [4: entry.id] } else {
                bankLoads[4] = nil
                bankLoads[slot] = entry.id
            }
        } catch {
            // Zerwany kabel i tak wykryje pętla `tick` — tu zostaje tylko powód dla panelu.
            bankLoadError = "Could not load “\(entry.name)”: \(error.localizedDescription)"
            finishBankLoad()
        }
    }

    private func finishBankLoad() {
        bankLoadRelease?.cancel()
        bankLoadRelease = nil
        isLoadingFromBank = false
    }

    public func dismissBankLoadError() {
        bankLoadError = nil
    }

    // MARK: - Bank Upload (kopia banków na dysk)

    /// Postęp kopii banków — z tego okno Bank Upload rysuje pasek. `nil`, gdy nic nie trwa.
    public struct BankUploadProgress: Equatable, Sendable {
        public var bankTitle: String
        /// Który bank (od 1) z ilu wybranych.
        public var bankNumber: Int
        public var bankCount: Int
        /// Pozycje gotowe / wszystkie — w całej kopii, nie w banku.
        public var done: Int
        public var total: Int
        public var current: String
    }

    public struct BankUploadResult: Sendable {
        public var saved = 0
        /// `bank:miejsce nazwa — powód` dla pozycji, których nie udało się zapisać.
        public var failures: [String] = []
        public var cancelled = false
        /// Nie udało się oddać Nordowi stanu sprzed kopii — opis dla użytkownika.
        public var restoreProblem: String?
    }

    public private(set) var bankUpload: BankUploadProgress?

    /// „Synth ▸ Bank Upload (From Modular)” Clavii: wybrane banki na dysk, każdy do
    /// własnego folderu (`PatchBank3/` z plikami i `PatchBank3.pchList`) → [[Docs/usb/bank-dump]].
    ///
    /// Nord nie wysyła pozycji z banku wprost, więc każda idzie przez slot: patche przez
    /// slot D, performance'y przez cały performance. Przed kopią zapamiętujemy, co tam było,
    /// a na końcu (także po Stop, czyli anulowaniu zadania) oddajemy — kopia ma niczego
    /// na Nordzie nie zmienić. Nord przez cały czas tylko czyta swoją pamięć.
    ///
    /// Echa `0x38`/`0x1F` po każdym załadowaniu są ignorowane (`ignoreDeviceReloadsUntil`),
    /// więc kanwa edytora stoi; ekran i Nord wracają razem do stanu sprzed kopii.
    public func uploadBanks(_ banks: [(kind: G2BankEntry.Kind, bank: Int)], to folder: URL) async -> BankUploadResult {
        var result = BankUploadResult()
        guard status == .connected, !isBusy, bankUpload == nil else { return result }
        let selected = banks.map { key in
            (key, bankEntries.filter { $0.kind == key.kind && $0.bank == key.bank }.sorted { $0.patch < $1.patch })
        }.filter { !$0.1.isEmpty }
        let total = selected.reduce(0) { $0 + $1.1.count }
        guard total > 0 else { return result }
        let hasPerformances = selected.contains { $0.0.kind == .performance }

        bankUpload = BankUploadProgress(bankTitle: "", bankNumber: 0, bankCount: selected.count,
                                        done: 0, total: total, current: "Reading the current state…")
        ignoreDeviceReloadsUntil = .distantFuture
        defer {
            bankUpload = nil
            ignoreDeviceReloadsUntil = Date().addingTimeInterval(1.5)
        }

        // Stan sprzed kopii. Patche zmieniają tylko slot D, performance'y — wszystkie
        // cztery sloty, nagłówek i tryb Performance/Patch.
        var original: [G2Patch] = []
        var originalHeader: (name: String, settings: G2PerformanceSettings, section: [UInt8])?
        var originalMode: Bool?
        do {
            for slot in UInt8(0) ..< UInt8(G2UsbProtocol.maxSlots) where hasPerformances || slot == 3 {
                try await original.append(manager.reloadPatch(slot: slot))
            }
            if hasPerformances {
                originalHeader = try await manager.readPerformanceHeader()
                originalMode = try await manager.readPerformanceMode()
                guard originalHeader != nil else {
                    throw G2UsbError.badResponse("the performance header could not be read")
                }
                // Bez tego przywrócenie wysłałoby pustą mapę i skasowało gałki globalne.
                try await manager.readGlobalKnobMap(into: &originalHeader!.settings)
            }
        } catch {
            result.restoreProblem = "Nothing was copied — the current state of the G2 could not be read "
                + "(\(error.localizedDescription))."
            return result
        }

        var done = 0
        banks: for (index, (key, entries)) in selected.enumerated() {
            let name = G2BankDump.bankName(kind: key.kind, bank: key.bank)
            let bankFolder = folder.appendingPathComponent(name, isDirectory: true)
            let fileNames = G2BankDump.fileNames(for: entries)
            var listed: [(G2BankEntry, String)] = []
            do {
                try FileManager.default.createDirectory(at: bankFolder, withIntermediateDirectories: true)
            } catch {
                result.failures.append("\(name): \(error.localizedDescription)")
                continue
            }
            for (entry, fileName) in zip(entries, fileNames) {
                if Task.isCancelled {
                    result.cancelled = true
                }
                if !result.cancelled {
                    bankUpload = BankUploadProgress(
                        bankTitle: (key.kind == .patch ? "Patch" : "Performance") + " Bank \(key.bank + 1)",
                        bankNumber: index + 1, bankCount: selected.count,
                        done: done, total: total, current: entry.name
                    )
                    do {
                        let read = try await manager.retrieveFromBank(
                            slot: entry.kind == .performance ? 4 : 3,
                            bank: entry.bank, patch: entry.patch, expectedName: entry.name
                        )
                        let data = try PatchParser.saveAll(
                            originalData: entry.kind == .performance
                                ? PatchParser.emptyPerformanceFile : PatchParser.emptyPatchFile,
                            patches: read.patches, performance: read.performance?.settings
                        )
                        try data.write(to: bankFolder.appendingPathComponent(fileName))
                        listed.append((entry, fileName))
                        result.saved += 1
                    } catch is CancellationError {
                        // Stop w trakcie pozycji — to przerwanie, nie błąd tej pozycji.
                        result.cancelled = true
                    } catch {
                        result.failures.append("\(entry.displayLocation) \(entry.name) — \(error.localizedDescription)")
                        // Nord zniknął — dalsze próby skończyłyby się tym samym.
                        if case .notConnected? = error as? G2UsbError { result.cancelled = true }
                    }
                    done += 1
                }
            }
            // Lista także po przerwaniu: to, co zdążyło się zapisać, da się wgrać z powrotem.
            if !listed.isEmpty {
                let list = G2BankDump.listFile(entries: listed.map(\.0), fileNames: listed.map(\.1))
                do {
                    try list.write(to: bankFolder.appendingPathComponent("\(name).pchList"))
                } catch {
                    result.failures.append("\(name).pchList — \(error.localizedDescription)")
                }
            }
            if result.cancelled { break banks }
        }

        bankUpload?.current = "Restoring the G2…"
        // Osobne zadanie nie dziedziczy Stop: przywrócenie ma się wykonać zawsze. Do
        // 2026-10-14 Stop w trakcie pozycji przerywał także je i Nord zostawał z kopią.
        let restore = Task { @MainActor in
            try await self.restoreAfterUpload(original: original, header: originalHeader, mode: originalMode)
        }
        do {
            try await restore.value
        } catch {
            result.restoreProblem = "The G2 could not be put back as it was (\(error.localizedDescription)). "
                + "Reload the patch you were working on."
        }
        return result
    }

    private func restoreAfterUpload(original: [G2Patch],
                                    header originalHeader: (name: String, settings: G2PerformanceSettings,
                                                            section: [UInt8])?,
                                    mode originalMode: Bool?) async throws
    {
        if let header = originalHeader, original.count == G2UsbProtocol.maxSlots {
            let data = try PatchParser.saveAll(originalData: PatchParser.emptyPerformanceFile,
                                               patches: original, performance: header.settings)
            try await manager.sendCompletePerformanceDump(
                name: header.name,
                headerSection: PatchParser.performanceSectionStream(fileData: data),
                slotStreams: (0 ..< G2UsbProtocol.maxSlots).map {
                    try PatchParser.slotSectionStream(fileData: data, slot: $0)
                },
                knobMapSection: PatchParser.performanceKnobMapStream(fileData: data),
                patches: original
            )
            if let originalMode, try await manager.readPerformanceMode() != originalMode {
                try await manager.setPerformanceMode(originalMode)
            }
        } else if let slotD = original.last {
            let data = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [slotD])
            try await manager.sendPatch(slotD, toSlot: 3,
                                        sectionStream: PatchParser.slotSectionStream(fileData: data, slot: 0))
        }
        // Powiadomienia o slotach grających i klawiaturze z czasu kopii przestawiły
        // przyciski slotów — nagłówek na świeżo stawia je tam, gdzie są naprawdę.
        if let header = try await readDevicePerformanceHeader() {
            devicePerformance = header.settings
            devicePerformanceName = header.name
            devicePerformanceSection = header.section
            applyClock(from: header.settings)
        }
    }

    /// Nagłówek performance'u (`0x10`) razem z gałkami globalnymi (`0x5E`) — nagłówek
    /// ich nie niesie, a bez nich Save Performance zawartości Norda zapisywał pustą mapę.
    /// `try?` przy gałkach: ich brak nie może przekreślić samego nagłówka.
    private func readDevicePerformanceHeader() async throws
        -> (name: String, settings: G2PerformanceSettings, section: [UInt8])?
    {
        guard var header = try await manager.readPerformanceHeader() else { return nil }
        try? await manager.readGlobalKnobMap(into: &header.settings)
        return header
    }

    /// Nuta z klawiatury w edytorze (Virtual Keyboard, litery z Caps Lockiem, most Claude'a).
    ///
    /// `0x56` jest jednogłosowe w samym firmware: Nord pamięta JEDEN numer nuty i jeden
    /// znacznik „wciśnięta”, a „puszczona” gasi to, co pod tym numerem leży. Druga nuta
    /// wysłana przy trzymanej pierwszej tylko nadpisuje numer — nie zabrzmi, a puszczenie
    /// zgasi złą nutę i pierwsza zawiśnie. Stąd dwie drogi:
    /// - wirtualny G2 z kanałem globalnym: zwykłe MIDI na ten kanał. Instrukcja (MIDI Global
    ///   Channel): nuta na nim działa „jak klawisz klawiatury”, czyli gra te same sloty co
    ///   `0x56`, ale akordy brzmią;
    /// - inaczej `0x56` z pierwszeństwem pierwszej nuty: dopóki ona trzyma, kolejne milczą.
    public func playNote(_ note: UInt8, on: Bool) {
        guard status == .connected else {
            usbHeldNote = nil
            return
        }
        if isVirtualDevice, let channel = synthSettings?.globalChannel,
           noteOutput.send([MidiNoteOutput.Note(key: note, velocity: 127, on: on)],
                           channel: channel, to: MidiNoteOutput.virtualG2)
        {
            return
        }
        if on {
            guard usbHeldNote == nil else { return }
            usbHeldNote = note
        } else {
            guard usbHeldNote == note else { return }
            usbHeldNote = nil
        }
        // W kolejce za poprzednimi nutami — osobne `Task` mogłyby zamienić kolejność.
        noteTask = Task { [previous = noteTask, manager] in
            await previous?.value
            try? await manager.playNote(note, on: on)
        }
    }

    /// Nuta, którą Nord trzyma z `0x56` (patrz `playNote`).
    private var usbHeldNote: UInt8?

    /// Paczka nut z wtyczki DAW dla slotu `slot` (0 = A).
    ///
    /// Wirtualny G2: MIDI na jego wejście „Virtual G2", na kanale slotu z Synth Settings
    /// i z dynamiką — gra tylko ten slot (`MidiNoteOutput`). Inaczej, a także gdy slot
    /// nie słucha MIDI albo wejścia nie ma: `0x56` bez dynamiki, grają sloty z klawiaturą.
    /// Nord przejdzie na MIDI przez kabel, gdy będzie wybór portu (plan wtyczki §2.7).
    ///
    /// `0x56` idzie **w kolejności** — także między paczkami, dlatego każda czeka na
    /// poprzednią. Osobne `Task` na nutę mogłyby zamienić wciśnięcie z puszczeniem
    /// i zostawić wiszącą nutę.
    public func playNotes(_ notes: [(key: UInt8, velocity: UInt8, on: Bool)], slot: Int) {
        guard status == .connected, !notes.isEmpty else { return }
        showDawNotes(notes, slot: slot)
        if isVirtualDevice, let slots = synthSettings?.slots, slots.indices.contains(slot), slots[slot].active,
           noteOutput.send(notes.map { MidiNoteOutput.Note(key: $0.key, velocity: $0.velocity, on: $0.on) },
                           channel: slots[slot].channel, to: MidiNoteOutput.virtualG2)
        {
            return
        }
        noteTask = Task { [previous = noteTask, manager] in
            await previous?.value
            for note in notes {
                try? await manager.playNote(note.key, on: note.on)
            }
        }
    }

    private var noteTask: Task<Void, Never>?
    private let noteOutput = MidiNoteOutput()

    /// Które sloty dostają właśnie nuty z wtyczki DAW — zielona kreska nad przyciskiem slotu.
    /// Świeci, dopóki trzymana jest nuta, i co najmniej chwilę po każdym wciśnięciu, żeby
    /// krótkie nuty też mignęły. Nut spoza edytora (klawiatura Norda, kabel MIDI wprost do
    /// Norda) tu nie ma — Nord nie zgłasza edytorowi, co gra.
    public private(set) var dawNoteSlots = Array(repeating: false, count: G2UsbProtocol.maxSlots)
    private var dawHeldNotes = Array(repeating: Set<UInt8>(), count: G2UsbProtocol.maxSlots)
    private var dawFlashes = Array(repeating: 0, count: G2UsbProtocol.maxSlots)

    private func showDawNotes(_ notes: [(key: UInt8, velocity: UInt8, on: Bool)], slot: Int) {
        guard dawHeldNotes.indices.contains(slot) else { return }
        for note in notes {
            if note.on { dawHeldNotes[slot].insert(note.key) } else { dawHeldNotes[slot].remove(note.key) }
        }
        if notes.contains(where: \.on) {
            dawFlashes[slot] += 1
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                self?.dawFlashes[slot] -= 1
                self?.updateDawNoteSlot(slot)
            }
        }
        updateDawNoteSlot(slot)
    }

    /// Panic z wtyczki DAW: „puść" dla wszystkich 128 klawiszy slotu — tą samą drogą co nuty
    /// z DAW-a (Virtual G2: MIDI na kanale slotu, inaczej `0x56` po kolei). Zawieszona nuta,
    /// której puszczenie zgubił DAW, gaśnie; puszczenie nietrzymanego klawisza nic nie robi.
    public func panic(slot: Int) {
        playNotes((0 ... 127).map { (key: UInt8($0), velocity: UInt8(0), on: false) }, slot: slot)
    }

    /// Wtyczka oddała sloty albo zniknęła — jej trzymane nuty nie mogą zostawić zielonej kreski.
    public func clearDawNotes(slots: [Int]) {
        for slot in slots where dawHeldNotes.indices.contains(slot) {
            dawHeldNotes[slot] = []
            updateDawNoteSlot(slot)
        }
    }

    private func updateDawNoteSlot(_ slot: Int) {
        let lit = !dawHeldNotes[slot].isEmpty || dawFlashes[slot] > 0
        if dawNoteSlots[slot] != lit { dawNoteSlots[slot] = lit }
    }

    /// Fire-and-forget: gest gałki emituje dziesiątki wywołań/s, `SET_PARAM` i tak nie ma
    /// potwierdzenia (patrz `G2MidiManager.setParameterLive`) — nie ma na co czekać ani czego
    /// pokazywać przy pojedynczej zgubionej ramce. `slot` musi się zgadzać z aktywnym slotem
    /// urządzenia — inaczej to zmiana w pliku poza aktualnie widocznym/aktywnym slotem
    /// (np. undo cofające edycję innego slotu .prf2), której hardware nie powinien dostać.
    ///
    /// `variation` to wariacja AKTYWNA patcha, nie zero — bez tego komenda dociera do
    /// urządzenia (i zostaje zapisana), ale nie słychać jej, bo Nord gra inną wariację.
    public func sendParameterLive(slot: Int, area: PatchArea, moduleID: Int, paramIndex: Int, value: Int, variation: Int) {
        guard status == .connected, slot == activeSlot else { return }
        let targetSlot = UInt8(slot)
        Task {
            do {
                try await manager.setParameterLive(
                    slot: targetSlot, area: area, moduleID: moduleID,
                    paramIndex: paramIndex, value: value, variation: variation
                )
            } catch {
                // Wcześniej `try?` cicho gubił każdy błąd — przy braku reakcji urządzenia
                // nie było jak odróżnić „komenda nie dotarła" od „dotarła, ale G2 ją zignorował".
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Wszystkie parametry jednej gałki Patch Adjustera — jedną ramką, jak w oryginale.
    public func sendParametersLive(slot: Int, changes: [G2ParameterChange], variation: Int) {
        guard status == .connected, slot == activeSlot, !changes.isEmpty else { return }
        let targetSlot = UInt8(slot)
        Task {
            do {
                try await manager.setParametersLive(slot: targetSlot, changes: changes, variation: variation)
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Gałka strony parametrów przypięta w edytorze (`0x25`) albo zwolniona (`0x26`).
    /// `assignment == nil` = zwolnienie. Komendy są potwierdzane, więc idą po kolei.
    public func sendKnobAssignment(slot: Int, knob: Int, assignment: G2KnobAssignment?) {
        guard status == .connected, slot == activeSlot else { return }
        Task {
            do {
                if let assignment {
                    try await manager.assignKnob(slot: UInt8(slot), location: assignment.location,
                                                 moduleID: assignment.moduleID,
                                                 paramIndex: assignment.paramIndex,
                                                 knob: knob, isLed: assignment.isLed)
                } else {
                    try await manager.deassignKnob(slot: UInt8(slot), knob: knob)
                }
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Sends one MIDI controller-map change to the active device slot.
    public func sendMidiControllerAssignment(slot: Int, cc: Int,
                                             assignment: G2MidiControllerAssignment?)
    {
        guard status == .connected, slot == activeSlot else { return }
        Task {
            do {
                if let assignment {
                    try await manager.assignMidiController(
                        slot: UInt8(slot),
                        cc: cc,
                        location: assignment.location,
                        moduleID: assignment.moduleID,
                        paramIndex: assignment.paramIndex
                    )
                } else {
                    try await manager.deassignMidiController(slot: UInt8(slot), cc: cc)
                }
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Opis patcha zmieniony w edytorze: `Voices`, Poly/Mono/Legato, kategoria (`0x21`).
    /// Nord nie przyjmuje tych pól osobno — leci cała sekcja opisu.
    /// ✅ **Zweryfikowane na żywym sprzęcie 2026-09-18** (`USBProbe --descriptiontest-slot D`:
    /// wysłane 3/3 pola odczytane z powrotem ze slotu). Mierzone przy slocie wybranym
    /// na urządzeniu — stąd ten sam warunek `slot == activeSlot` co u sąsiadów.
    public func sendPatchDescription(slot: Int, description: G2PatchDescription) {
        guard status == .connected, slot == activeSlot else { return }
        Task {
            do {
                try await manager.setPatchDescription(slot: UInt8(slot), description: description)
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Ustawienie patcha (obszar 2) zmienione w edytorze — dziś tą drogą idą gałki
    /// i źródła morfów (moduł 1). Fire-and-forget jak przy gałce modułu.
    public func sendPatchSetting(slot: Int, moduleID: Int, paramIndex: Int, value: Int, variation: Int) {
        guard status == .connected, slot == activeSlot else { return }
        Task {
            do {
                try await manager.setPatchSettingLive(
                    slot: UInt8(slot), moduleID: moduleID,
                    paramIndex: paramIndex, value: value, variation: variation
                )
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Zakres morfu zmieniony w edytorze (`0x43`). Fire-and-forget tą samą drogą co gałka:
    /// komenda nie ma potwierdzenia, a przy przeciąganiu leci gęsto. Zakres 0 = kasowanie
    /// przypisania. `location` to surowy numer obszaru (2 = ustawienia patcha), bo morfować
    /// można także Glide czy Bend.
    public func sendMorphRange(slot: Int, location: UInt8, moduleID: Int, paramIndex: Int,
                               morph: Int, range: Int, variation: Int)
    {
        guard status == .connected, slot == activeSlot else { return }
        Task {
            do {
                try await manager.setMorphRangeLive(
                    slot: UInt8(slot), location: location, moduleID: moduleID,
                    paramIndex: paramIndex, morph: morph, range: range, variation: variation
                )
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Wariacja przełączona W EDYTORZE (okno Variations) — Nord ma zagrać tę samą, tak
    /// jakby ktoś nacisnął przycisk wariacji na jego froncie. Ten sam warunek co przy
    /// gałce: tylko slot aktywny na urządzeniu, bo komenda dotyczy slotu edytowanego.
    public func sendVariation(slot: Int, variation: Int) {
        guard status == .connected, slot == activeSlot else { return }
        Task {
            do {
                try await manager.selectVariation(slot: UInt8(slot), variation: variation)
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    /// **Przesłuchanie z Mutatora** — bufor odsłuchu (zestaw 9) jedną paczką, a zaraz po
    /// niej przełączenie patcha na ten zestaw (`0x6A`). Kolejność jest ta sama co
    /// w oryginale (`GetFocusIndividMolecules`: zrzut, potem Param Setting Focus)
    /// i dlatego obie komendy idą **jednym zadaniem** — dwa osobne `Task` mogłyby
    /// dobiec do aktora w dowolnej kolejności i patch zagrałby to, co w buforze
    /// zostało po poprzednim dźwięku.
    ///
    /// Zgłoszenie w trakcie wysyłki nie czeka w kolejce, tylko **zastępuje** poprzednie:
    /// pod faderem Amount liczy się wyłącznie ostatnie położenie, a zrzut niesie cały
    /// bufor, więc pominięty krok pośredni niczego nie gubi.
    public func sendMutatorAudition(slot: Int, patch: G2Patch, variation: Int) {
        guard status == .connected, slot == activeSlot else { return }
        pendingAudition = (slot, patch, variation)
        guard auditionTask == nil else { return }
        auditionTask = Task { [weak self] in
            while let request = self?.pendingAudition {
                self?.pendingAudition = nil
                guard let self, self.status == .connected else { break }
                do {
                    try await self.manager.sendMutatorDump(request.patch, toSlot: UInt8(request.slot),
                                                           variation: request.variation)
                    try await self.manager.selectVariation(slot: UInt8(request.slot),
                                                           variation: request.variation)
                } catch {
                    self.status = .error(error.localizedDescription)
                }
            }
            self?.auditionTask = nil
        }
    }

    /// Dźwięk z Mutatora zapisany do wariacji (albo to cofnięte) — dla każdej z `variations`
    /// ten sam zrzut co przy odsłuchu, z numerem jej zestawu. Wariacji na urządzeniu nie
    /// przełączamy: oryginał też tego nie robi (`GetCopyIndividMolecules`).
    ///
    /// Zgłoszenia idą po kolei, jak `syncStructure` — dwa szybkie upuszczenia na tę samą
    /// wariację w dowolnej kolejności mogłyby zostawić w Nordzie starszy dźwięk.
    public func sendVariationDump(slot: Int, patch: G2Patch, variations: [Int]) {
        guard status == .connected, !isSending, slot == activeSlot else { return }
        let previous = variationDumpTask
        variationDumpTask = Task { [weak self] in
            await previous?.value
            guard let self, self.status == .connected else { return }
            do {
                for variation in variations {
                    try await self.manager.sendMutatorDump(patch, toSlot: UInt8(slot), variation: variation)
                }
            } catch {
                self.status = .error(error.localizedDescription)
            }
        }
    }

    /// Przepisanie wariacji na wariację (przycisk Init i „Copy to" w oknie Variations).
    /// Urządzenie kopiuje u siebie, edytor u siebie — patrz `G2MidiManager.copyVariation`.
    public func sendVariationCopy(slot: Int, from: Int, to: Int) {
        guard status == .connected, slot == activeSlot else { return }
        Task {
            do {
                try await manager.copyVariation(slot: UInt8(slot), from: from, to: to)
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Strona parametrów wybrana W EDYTORZE (przyciski A…E / 1…3 okna Parameter Pages).
    /// Panel Norda ma pokazać to samo, co osiem gałek okna — tak działa oryginał, który
    /// przy każdym kliknięciu wysyła Parameter Page Focus albo, w trybie Global Pages,
    /// Global Parameter Page Focus (Knob Floater Container (HandleChangeRequests)).
    ///
    /// Strona globalna dotyczy całego performance'u, więc nie zależy od slotu; strona
    /// slotu — jak gałka — tylko od slotu aktywnego na urządzeniu.
    public func sendParameterPage(slot: Int, page: Int, global: Bool) {
        guard status == .connected, global || slot == activeSlot else { return }
        Task {
            do {
                if global {
                    try await manager.selectGlobalParameterPage(page)
                } else {
                    try await manager.selectParameterPage(slot: UInt8(slot), page: page)
                }
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Przełącznik Global Pages w oknie Parameter Pages — pole 2 nagłówka performance'u.
    public func sendGlobalPages(_ enabled: Bool) {
        guard status == .connected else { return }
        Task {
            do {
                try await manager.setGlobalPages(enabled)
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    /// Zmiana STRUKTURY patcha w edytorze — dodany albo skasowany moduł/kabel, także
    /// przez undo/redo, wklejenie i podmianę modułu. Do 2026-09-05 taka zmiana nie
    /// docierała do urządzenia w ogóle: skasowanie wszystkich modułów zostawiało Norda
    /// grającego dalej, bo na żywo szły wyłącznie parametry (`sendParameterLive`).
    ///
    /// Wysyłką jest różnica, nie cały slot (patrz `G2MidiManager.syncPatch`) — dzięki temu
    /// reszta patcha gra nieprzerwanie, tak jak w oryginale. Ten sam warunek co przy
    /// gałce: tylko slot aktywny na urządzeniu, bo komendy strukturalne działają właśnie
    /// na nim. Wysyłka całego slotu (otwarcie pliku) ma pierwszeństwo — niesie tę samą
    /// zawartość, więc dokładanie do niej różnicy byłoby pracą podwójną.
    ///
    /// Zmiany idą w kolejności zgłoszeń, jedna po drugiej: dwa zadania naraz liczyłyby
    /// różnicę wobec tego samego stanu urządzenia i drugie wysłałoby ją po raz drugi.
    public func syncStructure(slot: Int, patch: G2Patch) {
        guard status == .connected, !isSending, slot == activeSlot else { return }
        // Po każdej komendzie strukturalnej Nord ogłasza nowy numer sesji slotu (0x38).
        // To echo NASZEJ zmiany — bez karencji edytor odczytałby z powrotem patch, który
        // sam przed chwilą zmienił, i skasował przy tym historię undo.
        ignoreDeviceReloadsUntil = Date().addingTimeInterval(1.0)
        let previous = structureSyncTask
        structureSyncTask = Task { [weak self] in
            await previous?.value
            guard let self, self.status == .connected else { return }
            do {
                try await self.manager.syncPatch(patch, toSlot: UInt8(slot))
                self.ignoreDeviceReloadsUntil = Date().addingTimeInterval(1.0)
            } catch {
                self.status = .error(error.localizedDescription)
            }
        }
    }

    /// Diagnostyka: surowe bajty TX/RX. `notifications` włącza też strumień VU/LED —
    /// domyślnie wyłączony, bo to ~80 linii na sekundę.
    ///
    /// Zbieranie do pamięci chodzi ZAWSZE — przełącznik decyduje tylko o zapisie do pliku
    /// i echu na konsolę. Zawieszkę zgłasza się po fakcie, a log włączony po fakcie łapał
    /// dopiero to, co działo się PO awarii (2026-09-19). Teraz `start()` przepisuje do
    /// pliku także historię sprzed włączenia → [[Docs/usb/emulator]].
    public func setLogging(_ enabled: Bool, includeNotifications: Bool = false) async {
        let sink: @Sendable (String) -> Void = { line in
            USBLogFile.shared.append(line)
        }
        await manager.setLog(sink)
        await manager.setLogNotifications(includeNotifications)
        if enabled {
            USBLogFile.shared.start()
            print("[G2] log USB zapisuje się do \(USBLogFile.url.path)")
        } else {
            USBLogFile.shared.stop()
        }
    }

    /// Ścieżka pliku z logiem — do pokazania w interfejsie, żeby dało się go komuś wysłać.
    public var usbLogPath: String {
        USBLogFile.url.path
    }

    /// Wgrywa do Norda to, co właśnie stanęło na ekranie: otwarty plik, nowy patch albo
    /// nową performance. Slot urządzenia jest buforem roboczym edytora, więc każda z tych
    /// akcji ma tam wylądować od razu — u BVerhue tak samo kończą się `Init patch`
    /// (`SendSetPatchMessage`) i `Init performance` (`USBStartInitPerf`).
    ///
    /// `onlyFocusedSlot` obsługuje New Patch: czyścimy jeden slot, więc tylko on jedzie do
    /// urządzenia — trzy pozostałe grają dalej i nie ma po co ich przepisywać.
    ///
    /// Po udanej wysyłce ekran i Nord pokazują to samo, więc patch załadowany na jego
    /// froncie znów ma prawo wejść na ekran (`markSentToDevice`).
    ///
    /// `followDocument` — otwarcie pliku albo New Patch/Performance: najpierw tryb Norda
    /// dobrany do dokumentu (`PatchOpenMode`). Open To, Init i ⌘Z trybu nie ruszają.
    /// „Load the G2's patch" przy podłączeniu (`ConnectContentMode`): edytor bierze sloty
    /// odczytane właśnie w tym połączeniu, tak jak przy starcie z pustym dokumentem.
    public func loadDeviceContentIntoEditor() async {
        guard status == .connected else { return }
        await onPatchesDownloaded?(manager.patches)
    }

    public func send(_ state: PatchState, onlyFocusedSlot: Bool = false, followDocument: Bool = false) async {
        guard status == .connected, !state.slots.isEmpty else { return }
        let slot = min(max(state.selectedSlot, 0), state.slots.count - 1)
        if followDocument,
           let mode = PatchOpenMode.targetMode(performanceDocument: !onlyFocusedSlot && state.hasPerformanceSettings)
        {
            await followDocumentMode(mode)
        }
        if onlyFocusedSlot {
            bankLoads[slot] = nil
            bankLoads[4] = nil
        } else {
            bankLoads = [:]
        }
        if onlyFocusedSlot {
            await upload(patches: [state.slots[slot]], activeSlot: slot,
                         slotFiles: [state.slotFileData[slot]], firstSlot: slot)
        } else {
            // Nazwa performance'u idzie PRZED slotami: u Clavii jest pierwszą molekułą
            // pełnego zrzutu (Complete Performance Dump (WriteStream) — nazwa, nagłówek,
            // cztery patche), u BVerhue pierwszym krokiem `USBInitPerfSeq`. Wysyłamy ją
            // tylko wtedy, gdy edytor ma ustawienia performance'u (New Performance, otwarty
            // `.prf2`) — sloty z pojedynczych `.pch2` nie mają nazwy performance'u, a nadanie
            // jej w Nordzie byłoby podpisaniem cudzej zawartości → [[Docs/usb/slots]].
            // Cały performance JEDNĄ komendą, jak oryginał — gdy dokument da się tak wysłać.
            if await sendCompletePerformance(state) {
                if status == .connected { state.markSentToDevice() }
                return
            }
            var headerSent = false
            if state.hasPerformanceSettings {
                await sendPerformanceName(state.performanceName)
                // Druga molekuła zrzutu: cała sekcja 0x11. Po niej Nord ma komplet —
                // Hold i zakresy klawiszy, ale też sloty grające, klawiaturę i zegar,
                // więc `upload` nie powtarza ich osobnymi komendami.
                headerSent = await sendPerformanceHeader(state.performance,
                                                         fileData: state.performanceFileData)
            }
            // Bajty pliku włączają szybką drogę: jeden komunikat na slot zamiast setek
            // komend strukturalnych — patrz `performUpload`.
            await upload(patches: state.slots, activeSlot: slot,
                         performance: state.hasPerformanceSettings ? state.performance : nil,
                         fileData: state.performanceFileData, slotFiles: state.slotFileData,
                         fileName: state.fileName, headerSent: headerSent)
        }
        if status == .connected { state.markSentToDevice() }
    }
}
