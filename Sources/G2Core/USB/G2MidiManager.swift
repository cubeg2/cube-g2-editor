// G2MidiManager.swift
// Actor komunikacji USB z Nord Modular G2 — libusb-1.0, zero zależności od UI.
// Sekwencja handshake (Init → Stop → ustawienia → sloty → Start → Poll) i ramkowanie
// portowane z reference/G2-Edit/src/usbComms.c (GPL, Chris Turner).

import CLibUsb
import Foundation

public enum G2UsbError: LocalizedError {
    case libusbInitFailed
    case deviceNotFound
    case resetFailed
    case claimInterfaceFailed
    case transferFailed(String)
    case badResponse(String)
    /// Urządzenie odpowiedziało odmową `0x7E` — żyje, tylko komendy nie przyjęło.
    case rejected(String)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .libusbInitFailed: "Could not initialize libusb"
        case .deviceNotFound: "G2 not found (VID 0x0FFC, PID 0x0002) — check the USB cable"
        case .resetFailed: "USB device reset failed"
        case .claimInterfaceFailed: "Could not claim USB interface 0"
        case let .transferFailed(reason): "USB transfer failed: \(reason)"
        case let .badResponse(reason): "Unexpected device response: \(reason)"
        case let .rejected(reason): "The device refused \(reason)"
        case .notConnected: "G2 is not connected"
        }
    }
}

/// Jedno powiadomienie nadane przez urządzenie z własnej inicjatywy (po `Start`):
/// ruch gałki na froncie Norda, przełączenie slotu, dane VU/LED, zmiana wersji patcha.
/// Do 2026-09-04 `pollOnce` odbierał je i wyrzucał — cała komunikacja szła w jedną stronę.
public struct G2Notification: Sendable {
    /// Numer slotu z bajtu odpowiedzi (`commandResponse & 0x03`, jak `usbComms.c:397`).
    public let slot: UInt8
    public let subCommand: UInt8
    public let payload: [UInt8]
}

public actor G2MidiManager {
    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case polling
        case error(String)
    }

    public private(set) var state: ConnectionState = .disconnected
    /// Patche odebrane przez `GetPatchSlot` podczas handshake, sparsowane do `G2Patch`.
    /// Pusty `G2Patch()` dla slotu, którego bajtów nie udało się rozpoznać (patrz `runHandshake`).
    public private(set) var patches: [G2Patch] = Array(repeating: G2Patch(), count: G2UsbProtocol.maxSlots)
    /// Czym się przedstawiło urządzenie w pierwszym kroku handshake'u (model, firmware).
    /// `nil`, dopóki nie ma połączenia albo gdy odpowiedź nie miała znacznika `0x0A`.
    public private(set) var identity: G2UsbProtocol.DeviceIdentity?

    /// Strona parametrów, którą urządzenie ma wybraną na swoim panelu — odczytana
    /// w handshake (`0x58` → `0x2D`, `0x59` → `0x1E`). `nil`, gdy Nord nie odpowiedział;
    /// wtedy okno zostaje przy swojej. Oryginał pyta o dokładnie te dwie rzeczy przy
    /// budowie modelu synta (`CPatch::SendParameterPageFocusRequestBubble`).
    public private(set) var parameterPage: Int?
    public private(set) var globalParameterPage: Int?

    /// Kto przenosi bajty: prawdziwy Nord po USB albo emulator po gnieździe
    /// (patrz `G2Transport`). `nil` = brak połączenia — ta sama rola, którą do
    /// 2026-09-09 pełnił uchwyt libusb.
    private var transport: G2Transport? {
        didSet { drainOnlyWhenOrphaned = transport != nil }
    }

    /// Czy w 0x82 może wisieć payload bez swojej zapowiedzi. Opróżniamy 0x82 TYLKO wtedy —
    /// odruchowe czyszczenie przed i po każdej komendzie zabierało dane, których zapowiedź
    /// czekała jeszcze w kolejce 0x81, i od tej chwili każda para była przesunięta o jeden
    /// (135 „rozjazdów" na przebiegu emulatora). Kosztowało też 2 × 100 ms na komendę.
    private var extendedOrphanSuspected = false
    /// Reguła #91, od 2026-09-18 **także dla prawdziwego Norda** — zmierzona na nim,
    /// nie przyjęta na wiarę: siedem przebiegów po 40 obiegów komend z odpowiedzią przy
    /// chodzących powiadomieniach dało przy starym zachowaniu 2/0/4/3/3/0/2 „rozjazdów
    /// strumienia", a przy tej regule **0 w każdym z czterech przebiegów** (i 40–43 ms
    /// na obieg zamiast 43–48). Pomiar: `USBProbe --soak 40 [--orphan-rule]`.
    private var drainOnlyWhenOrphaned = false

    /// Czy przed/po komendzie opróżniać 0x82.
    private var shouldDrainExtended: Bool {
        extendedOrphanSuspected || !drainOnlyWhenOrphaned
    }

    /// Furtka **diagnostyczna** (`USBProbe --soak --orphan-rule`): włącza regułę #91
    /// także dla prawdziwego Norda, żeby dało się ją na nim zmierzyć. Aplikacja tego
    /// nie woła — domyślnie z Nordem obowiązuje zachowanie sprzed 2026-09-14, dopóki
    /// pomiar nie pokaże, że nowa reguła jest co najmniej tak samo dobra
    /// → [[Docs/context/bug-history]] #91.
    public func useOrphanOnlyDrain(_ enabled: Bool) {
        drainOnlyWhenOrphaned = enabled
    }

    /// Furtka **diagnostyczna** (`USBProbe --stress --wait500ms`): krótsze czekanie na dane
    /// z 0x82, jak przed 2026-10-21. Aplikacja tego nie woła (#146).
    public func setExtendedReadTries(_ tries: Int) {
        extendedReadTries = max(1, tries)
    }

    /// Furtka dla testów: podstawia transport bez `connect()`, z regułą emulatora albo Norda.
    func attachTransportForTesting(_ transport: G2Transport, emulatorRules: Bool = true) {
        self.transport = transport
        drainOnlyWhenOrphaned = emulatorRules
    }

    private var slotVersions: [UInt8] = Array(repeating: 0, count: G2UsbProtocol.maxSlots)
    private var pollTask: Task<Void, Never>?
    /// Ile wstrzymań pollingu trwa naraz (patrz `pausePolling`). Bez licznika dwa
    /// zagnieżdżone bloki `withPollingPaused` wznawiały polling dwa razy, zostawiając
    /// DRUGĄ pętlę, której nikt już nie anuluje — od tego momentu dwie pętle podkradają
    /// sobie odpowiedzi i każda kolejna komenda kończy się „brakiem potwierdzenia".
    private var pollPauseDepth = 0
    /// Czy tor komend jest zajęty — patrz `withCommandLane`. Aktor pozwala wejść do
    /// środka każdemu, kto poczeka na `await`, więc bez tego zamka wysyłka patcha
    /// i przełączenie slotu potrafiły biec RÓWNOLEGLE po tym samym endpoincie
    /// i podkradać sobie potwierdzenia (każda komenda czekała wtedy pełne 3 s).
    /// Trzeci bajt ramki komend systemowych. **`0x00` jest martwe** — urządzenie kwituje
    /// taką komendę `SUB_RESPONSE_OK` i nie robi z nią NIC. Zmierzone na żywym Nordzie
    /// 2026-09-04 (`USBProbe --slottest`, werdykt odczytany z urządzenia): przy `0x41`,
    /// `0x7F` i `0x01` przełączenie slotu wchodzi w życie, przy `0x00` nie. Trzymamy
    /// `0x41`, bo tej samej wartości wymaga nagłówek performance'u (0x10)
    /// → [[Docs/usb/slots]]. G2-Edit wpisuje tu `0x00` przy `SelectSlot` — i to jest
    /// powód, dla którego przełączanie slotów z edytora nie działało.
    private let systemVersion: UInt8 = 0x41
    private var commandLaneBusy = false
    private var commandLaneWaiters: [CheckedContinuation<Void, Never>] = []
    private var log: (@Sendable (String) -> Void)?
    private var notify: (@Sendable (G2Notification) -> Void)?
    private var logNotifications = false
    /// Czarna skrzynka (#146): pakiety odebrane po cichu (powiadomienia, ~40/s — w logu by
    /// go zalały) i przerwy między nimi. Do logu trafia tylko przy awarii (`dumpFlightRecorder`),
    /// bo właśnie chwili PRZED ciszą Norda nie było w żadnym logu.
    private var flightRecorder: [String] = []
    /// Ile prób po ~100 ms czekamy na dane zapowiedziane na 0x81: 5 s, jak oryginał
    /// (`CUSBManager::RxData`). Do 2026-10-21 było 0,5 s — porównanie: `USBProbe --stress --wait500ms`.
    private var extendedReadTries = 50
    /// Puste odczyty 0x81 od ostatniego pakietu — jeden to ~100 ms ciszy urządzenia.
    private var quietEmptyPolls = 0
    private static let flightRecorderCapacity = 600
    private let flightStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Czy strumień wizualny (VU 0x3A, diody 0x39) ma w ogóle docierać do aplikacji.
    private var visualStreamEnabled = true
    /// Ostatnia wysyłka do aplikacji, **osobno dla każdego strumienia** (wskaźniki `0x3A`,
    /// diody `0x39`) i slotu. Wspólny znacznik dla obu — tak było do 2026-09-06 — znaczył,
    /// że pakiet diod przychodzący 5 ms po pakiecie wskaźników wpadał w cudze okno i ginął;
    /// krok sekwencera potrafił się wtedy zaciąć na jedną klatkę i „przywiesić".
    private var lastVisualDispatch: [UInt16: Date] = [:]
    /// Pakiet, który nie zmieścił się w oknie — czeka na jego koniec zamiast wylecieć do
    /// kosza. To różnica między odsiewem a **scalaniem**: aplikacja dostaje rzadziej, ale
    /// zawsze NAJŚWIEŻSZĄ wartość, więc żaden krok sekwencera nie znika.
    private var pendingVisual: [UInt16: [UInt8]] = [:]
    private var visualFlushTask: Task<Void, Never>?
    /// Wskaźniki idą ~40×/s na slot, a każde powiadomienie przepuszczone do `@MainActor`
    /// kosztuje przerysowanie warstwy wskaźników. Scalanie robimy TUTAJ, nie w UI: pakiet
    /// zatrzymany w aktorze nie zajmuje miejsca w kolejce, przez którą płyną też zdarzenia
    /// sterujące (ruch gałki, przełączenie slotu) — a to one czekały w niej za wskaźnikami.
    ///
    /// Okno jest KRÓTSZE niż odstęp pakietów urządzenia (25 ms), więc w normalnym ruchu nic
    /// nie jest odkładane; scalanie włącza się dopiero, gdy pakiety przyjdą serią.
    private static let visualDispatchInterval: TimeInterval = 1.0 / 50.0
    /// Podkomendy, które aplikacja rzeczywiście obsługuje. `nil` = przepuszczaj wszystko
    /// (tak działa `USBProbe`, który ma widzieć całą magistralę). Reszta — obciążenie DSP
    /// `0x72`, nuty `0x69`, głosy `0x05`, zaznaczony parametr `0x2F` — leci gęsto i przy
    /// grającym patchu budziła `@MainActor` kilkadziesiąt razy na sekundę po to, żeby
    /// wpaść w `default: break`. Oryginał też nie rozdaje tego, czego nie pokazuje.
    private var notificationFilter: Set<UInt8>?
    /// Ostatnio przepuszczony pakiet wizualny, per (podkomenda, slot). Oryginał robi
    /// dokładnie to samo w `CLedBlinkData::SetMultiLed`: wartość równa poprzedniej =
    /// nic się nie dzieje, GUI nie jest budzone. U nas opłaca się to podwójnie, bo
    /// obudzenie `@MainActor` kosztuje przerysowanie kanwy, a patch w ciszy nadaje
    /// w kółko te same zera → [[Docs/usb/notifications]] „Jak radzi sobie z tym oryginał".
    private var lastVisualPayload: [UInt16: [UInt8]] = [:]
    /// Ile komunikatów pakujemy w jedną ramkę przy wgrywaniu patcha. Ostrożnie: ramka musi
    /// zmieścić się w buforze urządzenia, a przy odrzuceniu tracimy całą paczkę (jest
    /// wtedy powtarzana pojedynczo). 8 × ~30 B ≈ 240 B — z dużym zapasem.
    private static let moleculeBatchSize = 8

    public init() {}

    /// Podpina odbiornik powiadomień urządzenia (patrz `G2Notification`). Wołany
    /// z aktora, więc handler musi sam wrócić na swój wątek/aktor (w apce: `@MainActor`).
    public func setNotificationHandler(_ handler: (@Sendable (G2Notification) -> Void)?) {
        notify = handler
    }

    /// Wyłącza strumień wizualny u źródła. Pakiety są nadal ODBIERANE (nieodebrane
    /// zatkałyby endpoint i zablokowały urządzenie — patrz `drainPendingExtended`),
    /// tylko nie budzą aplikacji.
    public func setVisualStreamEnabled(_ enabled: Bool) {
        visualStreamEnabled = enabled
        if !enabled {
            pendingVisual.removeAll(keepingCapacity: true)
            visualFlushTask?.cancel()
            visualFlushTask = nil
        }
    }

    /// Ogranicza strumień powiadomień do podkomend, które odbiorca obsługuje. `nil` znosi
    /// filtr (diagnostyka — patrz `notificationFilter`).
    public func setNotificationFilter(_ subCommands: Set<UInt8>?) {
        notificationFilter = subCommands
    }

    private func dispatch(_ response: G2UsbProtocol.DecodedResponse) {
        guard notify != nil, let subCommand = response.subCommand else { return }
        if let notificationFilter, !notificationFilter.contains(subCommand) { return }
        let slot = response.slot ?? 0
        if subCommand == G2UsbProtocol.subResponseVolumeData || subCommand == G2UsbProtocol.subResponseLedData {
            guard visualStreamEnabled else { return }
            let key = UInt16(subCommand) << 8 | UInt16(slot)
            // Identyczne bajty znaczą „na ekranie i tak nic by się nie zmieniło" — tak samo
            // odsiewa to oryginał w `CLedBlinkData::SetMultiLed`. Patch w ciszy nadaje
            // w kółko te same zera, więc to ten warunek odcina większość ruchu.
            guard lastVisualPayload[key] != response.payload else { return }
            lastVisualPayload[key] = response.payload
            let now = Date()
            guard now.timeIntervalSince(lastVisualDispatch[key] ?? .distantPast)
                >= Self.visualDispatchInterval
            else {
                pendingVisual[key] = response.payload
                scheduleVisualFlush()
                return
            }
            lastVisualDispatch[key] = now
            pendingVisual[key] = nil
        }
        emit(slot: slot, subCommand: subCommand, payload: response.payload)
    }

    private func emit(slot: UInt8, subCommand: UInt8, payload: [UInt8]) {
        notify?(G2Notification(slot: slot, subCommand: subCommand, payload: payload))
    }

    /// Wypuszcza odłożone pakiety wizualne po zamknięciu okna. Jedno zadanie na wszystkie
    /// strumienie — dopóki coś czeka, kręci się dalej i gaśnie samo, gdy kolejka pustoszeje.
    private func scheduleVisualFlush() {
        guard visualFlushTask == nil else { return }
        visualFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.visualDispatchInterval * 1_000_000_000))
                guard let self else { return }
                let more = await self.flushPendingVisual()
                if !more { break }
            }
            await self?.clearVisualFlushTask()
        }
    }

    private func clearVisualFlushTask() {
        visualFlushTask = nil
    }

    /// Wysyła to, co czeka, i mówi, czy zostało jeszcze coś do zrobienia.
    private func flushPendingVisual() -> Bool {
        guard !pendingVisual.isEmpty else { return false }
        let now = Date()
        for (key, payload) in pendingVisual {
            guard now.timeIntervalSince(lastVisualDispatch[key] ?? .distantPast)
                >= Self.visualDispatchInterval else { continue }
            lastVisualDispatch[key] = now
            pendingVisual[key] = nil
            emit(slot: UInt8(key & 0xFF), subCommand: UInt8(key >> 8), payload: payload)
        }
        return !pendingVisual.isEmpty
    }

    /// Podpina logger surowych bajtów i kodów błędów libusb (diagnostyka na żywym sprzęcie).
    /// Bez niego warstwa transferu milczy — patrz `USBProbe --probe-write`.
    public func setLog(_ log: (@Sendable (String) -> Void)?) {
        self.log = log
    }

    /// Czy logować surowe bajty strumienia powiadomień. Domyślnie NIE: `VOLUME_INDICATOR`
    /// leci ~40×/s, więc log zalewa konsolę i — co gorsza — `print` wykonuje się wtedy
    /// wewnątrz aktora, opóźniając komendy wysyłane z UI. Włączane tylko w diagnostyce.
    public func setLogNotifications(_ enabled: Bool) {
        logNotifications = enabled
    }

    /// Podgląd bajtów do logu — obcięty, bo pojedynczy odczyt patcha potrafi mieć 18 kB.
    private func hex(_ bytes: [UInt8], limit: Int = 32) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > limit ? "\(shown) … (\(bytes.count)B)" : shown
    }

    // MARK: - Połączenie

    /// `readPatches: false` pomija odczyt zawartości slotów (`GetPatchSlot` + `GetPatchName`)
    /// — sam slot A potrafi mieć 18 kB, a narzędziu diagnostycznemu często wystarczy
    /// handshake i numery wersji slotów. `patches` zostają wtedy puste.
    ///
    /// `onDeviceOpened` woła się, gdy urządzenie JEST i zaczyna się handshake — samo
    /// szukanie go w gnieździe (ułamek sekundy, co 2 s bez Norda) nie jest „łączeniem".
    public func connect(readPatches: Bool = true, onDeviceOpened: (@Sendable () -> Void)? = nil) async throws {
        guard transport == nil else { return }
        // Świeże połączenie = zerowy licznik wstrzymań. Blok `withPollingPaused` przerwany
        // zerwanym kablem zostawiłby go podniesiony, a wtedy pierwsze wstrzymanie w nowej
        // sesji byłoby pozorne (2 zamiast 1) i komenda rywalizowałaby z pollingiem.
        pollPauseDepth = 0
        state = .connecting
        do {
            try openDevice()
            onDeviceOpened?()
            try await runHandshake(readPatches: readPatches)
            state = .polling
            startPolling()
        } catch {
            closeDevice()
            state = .error(error.localizedDescription)
            throw error
        }
    }

    public func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        pollPauseDepth = 0
        commandLaneWaiters.forEach { $0.resume() }
        commandLaneWaiters.removeAll()
        commandLaneBusy = false
        closeDevice()
        state = .disconnected
    }

    // MARK: - Wgrywanie patcha

    /// Wgrywa `patch` do `slot`, nadpisując jego bieżącą zawartość na urządzeniu.
    ///
    /// **Z `sectionStream` (droga oryginału): jedna komenda 0x37 z całym patchem.**
    /// Strumień buduje `PatchParser.slotSectionStream(fileData:slot:)`. Urządzenie
    /// przebudowuje się raz, więc wgranie trwa ułamek sekundy i dioda PATCH LOAD mruga
    /// jeden raz — tak samo jak w edytorze Clavii.
    ///
    /// **Bez `sectionStream`: droga zapasowa, molekuła po molekule** — `SelectSlot` →
    /// skasowanie stanu obecnego (kable, potem moduły) → `AddModule`×N → `WriteCable`×N →
    /// `ParamDump` → `NameDump`. Potrzebna tam, gdzie nie ma pliku źródłowego (patch
    /// wczytany z Norda, nowy patch). Jest wolna z natury: Nord przelicza przydział DSP
    /// po KAŻDEJ komendzie strukturalnej i potwierdza ją dopiero po ~200–270 ms.
    ///
    /// **Zweryfikowane na żywym sprzęcie 2026-09-03** — każda komenda potwierdzona
    /// przez `SUB_RESPONSE_OK` (0x7F). Poprzednie sześć prób kończyło się „brakiem
    /// odpowiedzi": urządzenie było zablokowane osieroconym payloadem na 0x82
    /// (patrz `drainPendingExtended`), a `performStep` brał za potwierdzenie pierwszy
    /// pakiet z endpointu — łącznie ze strumieniem powiadomień, więc zapis „przechodził"
    /// niezależnie od tego, co urządzenie z nim zrobiło. Pełna historia → [[Docs/usb/actor]].
    ///
    /// Rzuca, jeśli którakolwiek komenda nie dostała `SUB_RESPONSE_OK` — ale dopiero po
    /// przejściu CAŁEJ sekwencji, żeby nie zostawić slotu wgranego w połowie.
    public func sendPatch(_ patch: G2Patch, toSlot slot: UInt8, sectionStream: [UInt8]? = nil,
                          onStep: (@Sendable (String) -> Void)? = nil) async throws
    {
        guard transport != nil else { throw G2UsbError.notConnected }
        onStep?("sendPatch start: slot \(slot) version \(slotVersions[Int(slot)])")

        await acquireCommandLane()
        await pausePolling()
        // Sprzątanie strumienia zostawiamy najbliższemu `pausePolling` — rozjazd jest od
        // 2026-09-04 odwracalny (patrz `resynchronizeExtended`), więc nie ma po co
        // odsuwać zwolnienia toru w osobne zadanie.
        defer {
            resumePolling()
            releaseCommandLane()
        }

        if let sectionStream {
            try await sendCompletePatchDump(sectionStream, name: patch.name, toSlot: slot, onStep: onStep)
            patches[Int(slot)] = patch
            return
        }

        var accepted = 0
        var refused = 0
        // Numer wersji czytany PRZY KAŻDYM komunikacie, nie raz na całą sekwencję —
        // urządzenie podbija go po każdej zmianie strukturalnej i ogłasza w 0x38
        // (`noteVersionChange`), dokładnie jak `send_write_data` w G2-Edit.
        // Przerywamy po pięciu komendach bez potwierdzenia z rzędu. Każda taka komenda
        // kosztuje 3 s oczekiwania, więc zablokowane urządzenie znaczyłoby kilkanaście
        // minut „wysyłania" i zawieszony na ten czas pasek aplikacji — a i tak z zerowym
        // skutkiem. Pojedyncze potknięcie nie przerywa sekwencji (patrz `refused`).
        var refusedInARow = 0
        var batchingWorks = true
        func write(_ payload: [UInt8], _ label: String) async throws {
            onStep?(label)
            if try await performWrite(payload, label: label) {
                accepted += 1
                refusedInARow = 0
            } else {
                refused += 1
                refusedInARow += 1
                if refusedInARow >= 5 {
                    throw G2UsbError.badResponse("five commands in a row not acknowledged — sending aborted")
                }
            }
        }

        // `systemVersion`, nie domyślne `0x00`: przy zerze Nord kwituje komendę `OK` i jej
        // NIE wykonuje (zmierzone 2026-09-04, `USBProbe --slottest`) — zapis szedłby wtedy
        // do slotu aktywnego z handshake, nie do docelowego. Tak samo robi `selectSlot`.
        try await write(G2UsbProtocol.selectSlotPayload(slot: slot, version: systemVersion), "SelectSlot \(slot)")

        // Czyszczenie slotu przed zapisem. `AddModule` nadpisuje moduł o tym samym id,
        // ale `WriteCable` (Cable Connect) tylko DOKŁADA — bez tego kroku ponowny zapis
        // tego samego patcha podwaja kable (potwierdzone na sprzęcie 5→10). Kasujemy stan
        // ODCZYTANY z urządzenia (`patches[slot]`), nie ten, który wgrywamy. Kolejność
        // kable→moduły jak w `mouseHandle.c` w G2-Edit.
        let current = patches[Int(slot)]
        for area in PatchArea.allCases {
            for cable in current.cables(in: area) {
                let payload = G2UsbProtocol.deleteCablePayload(slot: slot, version: slotVersions[Int(slot)], cable: cable)
                try await write(payload, "DeleteCable \(area) \(cable.fromModule):\(cable.fromConnector) → \(cable.toModule):\(cable.toConnector)")
            }
        }
        for area in PatchArea.allCases {
            for module in current.modules(in: area) {
                let payload = G2UsbProtocol.deleteModulePayload(slot: slot, version: slotVersions[Int(slot)], module: module)
                try await write(payload, "DeleteModule \(area) id \(module.id) \"\(module.label)\"")
            }
        }

        /// Wysyła molekuły paczkami, jak oryginał. Gdy urządzenie paczki nie przyjmie,
        /// **wraca do wysyłania po jednej** — wtedy jest co najwyżej tak wolno jak dawniej,
        /// a patch i tak wjeżdża w całości. Sprawdzamy to na pierwszej paczce i jeśli padnie,
        /// reszta idzie już pojedynczo (nie ma sensu ponawiać eksperymentu setki razy).
        func writeBatched(_ molecules: [(molecule: [UInt8], label: String)], kind: String) async throws {
            guard !molecules.isEmpty else { return }
            var index = 0
            while index < molecules.count {
                let end = min(index + Self.moleculeBatchSize, molecules.count)
                let chunk = Array(molecules[index ..< end])
                if batchingWorks, chunk.count > 1 {
                    let payload = G2UsbProtocol.batchPayload(
                        slot: slot, version: slotVersions[Int(slot)],
                        molecules: chunk.map(\.molecule)
                    )
                    let label = "\(kind) ×\(chunk.count) (\(chunk.first?.label ?? "") …)"
                    onStep?(label)
                    if try await performWrite(payload, label: label) {
                        accepted += 1
                        refusedInARow = 0
                        index = end
                        continue
                    }
                    // Paczka odrzucona — od tej chwili wysyłamy pojedynczo.
                    log?("    ~ device refused the \(kind) batch — switching to single commands")
                    batchingWorks = false
                }
                for item in chunk {
                    try await write(G2UsbProtocol.batchPayload(slot: slot, version: slotVersions[Int(slot)],
                                                               molecules: [item.molecule]), item.label)
                }
                index = end
            }
        }

        var moduleMolecules: [(molecule: [UInt8], label: String)] = []
        for area in PatchArea.allCases {
            for module in patch.modules(in: area) {
                moduleMolecules.append((G2UsbProtocol.addModuleMolecule(module),
                                        "AddModule \(area) id \(module.id) \"\(module.label)\""))
            }
        }
        try await writeBatched(moduleMolecules, kind: "AddModule")

        var cableMolecules: [(molecule: [UInt8], label: String)] = []
        for area in PatchArea.allCases {
            for cable in patch.cables(in: area) {
                cableMolecules.append((G2UsbProtocol.writeCableMolecule(cable),
                                       "WriteCable \(area) \(cable.fromModule):\(cable.fromConnector) → \(cable.toModule):\(cable.toConnector)"))
            }
        }
        try await writeBatched(cableMolecules, kind: "WriteCable")

        var paramBytes: [UInt8] = []
        var nameBytes: [UInt8] = []
        for area in PatchArea.allCases {
            paramBytes += try PatchParser.writeParamList(modules: patch.modules(in: area), area: area)
            nameBytes += try PatchParser.writeModuleNames(modules: patch.modules(in: area), area: area)
        }

        try await write(
            G2UsbProtocol.paramDumpPayload(slot: slot, version: slotVersions[Int(slot)], combinedSectionBytes: paramBytes),
            "ParamDump \(paramBytes.count)B"
        )
        try await write(
            G2UsbProtocol.moduleNameDumpPayload(slot: slot, version: slotVersions[Int(slot)], combinedSectionBytes: nameBytes),
            "NameDump \(nameBytes.count)B"
        )

        onStep?("sendPatch koniec: potwierdzonych \(accepted), bez potwierdzenia/odrzuconych \(refused)")
        guard refused == 0 else {
            throw G2UsbError.badResponse("\(refused) of \(accepted + refused) commands not acknowledged")
        }
        patches[Int(slot)] = patch
    }

    /// Cały patch w jednym komunikacie 0x37 — droga oryginału, patrz
    /// `G2UsbProtocol.setPatchPayload`. Wołane spod zamka toru komend, przez `sendPatch`.
    ///
    /// `SelectSlot` idzie przodem z tego samego powodu, co przy wysyłce molekułami:
    /// komendy strukturalne działają na slocie aktywnym na urządzeniu.
    ///
    /// Czekanie jest dłuższe niż zwykłe 3 s, bo urządzenie przebudowuje przy tej jednej
    /// komendzie cały patch.
    ///
    /// **Odpowiedzią NIE jest `SUB_RESPONSE_OK`, tylko nowy numer sesji slotu (0x36)** —
    /// zgodnie z typem komunikatu w oryginale (`Initialize(0x37, 2, 1)`, typ 2 = zapytanie,
    /// odpowiedzią są dane). Zmierzone na żywym Nordzie 2026-09-05: `36 03 01`, czyli
    /// slot D, wersja 1. Numer trzeba od razu zapamiętać, inaczej kolejna komenda do tego
    /// slotu poleci ze starą wersją.
    private func sendCompletePatchDump(_ sectionBytes: [UInt8], name: String, toSlot slot: UInt8,
                                       onStep: (@Sendable (String) -> Void)?) async throws
    {
        let select = "SelectSlot \(slot)"
        onStep?(select)
        let selectPayload = G2UsbProtocol.selectSlotPayload(slot: slot, version: systemVersion)
        guard try await performWrite(selectPayload, label: select) else {
            throw G2UsbError.badResponse("the device did not acknowledge selecting slot \(slot)")
        }

        let label = "SetPatch slot \(slot) — \(sectionBytes.count)B w jednej ramce"
        onStep?(label)
        let payload = G2UsbProtocol.setPatchPayload(slot: slot, version: slotVersions[Int(slot)],
                                                    patchName: name, sectionBytes: sectionBytes)
        guard let response = try await performWrite(payload, label: label, timeout: 10.0,
                                                    expecting: G2UsbProtocol.subPatchVersionResponse,
                                                    rejection: .rejected("the patch upload to slot \(slot)"))
        else {
            throw G2UsbError.badResponse("the device did not acknowledge the patch upload to slot \(slot)")
        }
        if response.subCommand == G2UsbProtocol.subPatchVersionResponse,
           let decoded = G2UsbProtocol.decodePatchVersion(response.payload),
           decoded.slot < G2UsbProtocol.maxSlots
        {
            slotVersions[Int(decoded.slot)] = decoded.version
        }
        onStep?("sendPatch koniec: slot \(slot) wgrany jedną komendą, wersja \(slotVersions[Int(slot)])")
    }

    /// Ponowny odczyt zawartości JEDNEGO slotu — po powiadomieniu, że patch zmienił się
    /// NA FRONCIE urządzenia. Oba źródła nazywają to wprost przeładowaniem: BVerhue
    /// „Slot patch version changed. Reload slot" (`TG2Perf.ProcessResponseMsg`), G2-Edit
    /// „Got Patch load" i skok całego automatu z powrotem do `eStateStop` (`usbComms.c:1189`).
    public func reloadPatch(slot: UInt8) async throws -> G2Patch {
        guard transport != nil else { throw G2UsbError.notConnected }
        return try await withPollingPaused {
            // Strumień wizualny leci ~40×/s i po zmianie patcha na froncie dokłada do tego
            // całą serię powiadomień. Handshake czyta sloty po `Stop` i dlatego jest
            // niezawodny — przeładowanie robi teraz to samo (jak `readPerformanceHeader`).
            try await withStreamStopped {
                guard let patch = try await readPatchSlot(slot) else {
                    throw G2UsbError.badResponse("could not read slot \(slot) after it changed on the device")
                }
                return patch
            }
        }
    }

    /// Reakcja na Performance Release (0x1F) — urządzenie ogłasza, że wydało performance
    /// na nowo, ale **nie mówi, który slot się zmienił**. Zamiast czytać wszystkie cztery
    /// (4 × do 18 kB przy KAŻDEJ zmianie patcha na froncie) pytamy najpierw o numery sesji
    /// i przeładowujemy tylko sloty, w których numer faktycznie się zmienił.
    ///
    /// Że to wystarczy, widać w surowym pakiecie 0x1F złapanym na sprzęcie:
    /// `1F 12 | 36 00 13 | 36 01 12 | 36 02 12 | 36 03 12` — numer podskoczył wyłącznie
    /// slotowi 0. Wcześniejszy komentarz („wszystkie cztery numery rosną") był nieprawdą.
    /// Objaw nadmiarowego czytania: przy przeskakiwaniu patchy na froncie Nord robi się
    /// zajęty, a dioda PATCH LOAD miga jak oszalała (zgłoszone 2026-09-04).
    ///
    /// Slot, którego nie udało się rozczytać, zostaje z poprzednią zawartością zamiast
    /// wywracać cały odczyt — pozostałe trzy są wtedy i tak świeże.
    public func reloadAllPatches() async throws -> [G2Patch] {
        guard transport != nil else { throw G2UsbError.notConnected }
        return try await withPollingPaused {
            try await withStreamStopped {
                try await reloadAllPatchesNow()
            }
        }
    }

    /// Sam odczyt — zakłada wstrzymany polling i zatrzymany strumień (`reloadAllPatches`).
    private func reloadAllPatchesNow() async throws -> [G2Patch] {
        for slot in UInt8(0) ..< UInt8(G2UsbProtocol.maxSlots) {
            let previous = slotVersions[Int(slot)]
            // Numer sesji czytamy TYLKO z odpowiedzi 0x36 — po zmianie patcha na froncie
            // leci cała seria komunikatów i każdy inny bywał brany za tę odpowiedź.
            // `try?`, bo brak numeru sesji ma znaczyć „przeczytaj slot", a nie „przerwij
            // odczyt wszystkich czterech".
            let response = try? await performStep(G2UsbProtocol.getPatchVersionPayload(slot: slot),
                                                  expectSub: [G2UsbProtocol.subPatchVersionResponse])
            if let payload = response?.payload, let decoded = G2UsbProtocol.decodePatchVersion(payload) {
                slotVersions[Int(decoded.slot)] = decoded.version
                guard decoded.version != previous else {
                    log?("    ~ slot \(slot): session number unchanged (\(previous)) — skipping the read")
                    continue
                }
            }
            _ = try await readPatchSlot(slot, versionIsFresh: true)
        }
        return patches
    }

    /// Wspólny odczyt jednego slotu: świeży numer wersji (bez niego kolejne komendy
    /// lecą ze starym i urządzenie je odrzuca), zawartość, nazwa. Zakłada wstrzymany
    /// polling — sam czeka na odpowiedzi z tego samego endpointu.
    private func readPatchSlot(_ slot: UInt8, versionIsFresh: Bool = false) async throws -> G2Patch? {
        if !versionIsFresh {
            let versionResponse = try? await performStep(G2UsbProtocol.getPatchVersionPayload(slot: slot),
                                                         expectSub: [G2UsbProtocol.subPatchVersionResponse])
            if let payload = versionResponse?.payload, let decoded = G2UsbProtocol.decodePatchVersion(payload) {
                slotVersions[Int(decoded.slot)] = decoded.version
            }
        }

        // `expectSub`: zawartość slotu zaczyna się sekcją 0x21. Bez tego w to oczekiwanie
        // wpadał komunikat z innej komendy, parser nie rozpoznawał w nim ani jednej sekcji
        // i slot podmieniało PUSTYM patchem — na ekranie znikały wszystkie moduły.
        // `try?` + brak wyniku = zostaje poprzednia zawartość slotu, nie pustka.
        let slotResponse = try? await performStep(
            G2UsbProtocol.getPatchSlotPayload(slot: slot, version: slotVersions[Int(slot)]),
            expectSub: [G2UsbProtocol.subPatchDumpResponse]
        )
        // Odpowiedź niesie własny numer slotu — po ponowieniu komendy w kolejce potrafi
        // zostać dump SĄSIEDNIEGO slotu, a ten wolno przyjąć tylko na jego miejsce.
        guard let slotResponse, slotResponse.slot == slot,
              let subCommand = slotResponse.subCommand,
              var patch = try? PatchParser.parseUsbPatchSlot(sectionBytes: [subCommand] + slotResponse.payload)
        else {
            log?("    ! slot \(slot): could not decode the contents after a change on the device")
            return nil
        }

        // Nazwa przychodzi osobną odpowiedzią (0x27) — bez tego kroku przeładowany slot
        // miałby pustą nazwę, choć na urządzeniu widać nową.
        // `try?`: patch jest już odczytany, brak nazwy nie może przekreślić całego slotu.
        let nameResponse = try? await performStep(
            G2UsbProtocol.getPatchNamePayload(slot: slot, version: slotVersions[Int(slot)]),
            expectSub: [G2UsbProtocol.subPatchNameResponse]
        )
        if let nameResponse {
            patch.name = G2UsbProtocol.decodePatchName(nameResponse.payload)
        }

        patches[Int(slot)] = patch
        return patch
    }

    // MARK: - Zmiany na żywo (real-time, poza `sendPatch`)

    /// `SUB_COMMAND_SELECT_SLOT` (0x09) — ustawia slot AKTYWNY na urządzeniu (front panel +
    /// cel edycji strukturalnej i `SET_PARAM`). Bez tego zmiany na żywo lecą do tego slotu,
    /// który był aktywny na koniec `connect()` (zawsze A, patrz `runHandshake`), niezależnie
    /// od tego, który slot pliku edytujesz w aplikacji.
    /// Polling MUSI być na ten czas wstrzymany — inaczej pętla `pollOnce` odbiera
    /// `SUB_RESPONSE_OK` przeznaczone dla tej komendy, `performWrite` czeka 3 s na coś,
    /// co już zostało przechwycone, i zgłasza brak potwierdzenia mimo że urządzenie
    /// slot przełączyło. Tak samo robi każda inna komenda czekająca na odpowiedź
    /// (`sendPatch`, `reloadPatch`) i diagnostyka w `USBProbe`.
    public func selectSlot(_ slot: UInt8) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            let payload = G2UsbProtocol.selectSlotPayload(slot: slot, version: systemVersion)
            guard try await performWrite(payload, label: "SelectSlot \(slot)") else {
                throw G2UsbError.badResponse("SelectSlot \(slot) not acknowledged")
            }
        }
    }

    /// Slot Selection Dump (0x07) + Keyboard Focus Dump (0x0F) w jednej ramce —
    /// ustawia, KTÓRE sloty grają i który dostaje klawiaturę. To co innego niż
    /// `selectSlot` (0x09 = który slot jest EDYTOWANY): oryginalny edytor po kliknięciu
    /// przycisku slotu wysyła oba, my do 2026-09-04 wysyłaliśmy tylko focus
    /// i dlatego na froncie Norda nic się nie zmieniało → [[Docs/usb/slots]].
    public func setSlotSelection(_ enabled: [Bool], keyboard: [Bool]) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            let payload = G2UsbProtocol.slotSelectionPayload(enabled: enabled, keyboard: keyboard,
                                                             version: systemVersion)
            guard try await performWrite(payload, label: "SlotSelection \(enabled) kb \(keyboard)") else {
                throw G2UsbError.badResponse("SlotSelection not acknowledged")
            }
        }
    }

    /// Czy urządzenie jest w trybie **Performance** (cztery sloty razem) czy **Patch**
    /// (gra jeden). Ma to znaczenie dla wszystkiego, co dotyczy slotów: w trybie Patch
    /// selekcja slotów nie ma czym sterować → [[Docs/usb/slots]].
    public func readPerformanceMode() async throws -> Bool? {
        guard let payload = try await readSynthDataDump() else { return nil }
        return G2UsbProtocol.decodePerformanceMode(payload)
    }

    /// Całe ustawienia urządzenia z tego samego komunikatu: nazwa Norda, kanały MIDI
    /// slotów, kanał globalny, SysEx ID, strojenie, zegar, pedał, Memory Protect.
    /// Oddajemy też SUROWY payload — zapis idzie przez przepisanie tych samych bajtów
    /// z podmienionymi polami, żeby nieznane bity zostały nietknięte
    /// → [[Docs/usb/synth-settings]].
    public func readSynthSettings() async throws -> (settings: G2SynthSettings, raw: [UInt8])? {
        guard let payload = try await readSynthDataDump() else { return nil }
        guard let settings = G2UsbProtocol.decodeSynthSettings(payload) else {
            log?("    ? synth settings: payload \(payload.count) B — too short to decode")
            return nil
        }
        return (settings, payload)
    }

    private func readSynthDataDump() async throws -> [UInt8]? {
        guard transport != nil else { throw G2UsbError.notConnected }
        return try await withPollingPaused {
            try await withStreamStopped {
                let response = try await performStep(G2UsbProtocol.synthSettingsRequestPayload(),
                                                     expectSub: [G2UsbProtocol.subSynthSettingsResponse],
                                                     timeout: 2.0)
                return response?.payload
            }
        }
    }

    /// Ustawienia urządzenia W DRUGĄ STRONĘ — ten sam komunikat `0x03`, przepisany
    /// z ostatniego odczytu z podmienionymi polami okna. Oryginał robi dokładnie to samo
    /// przy zamknięciu okna Synth Settings (Synth Settings dialog (TrySendData)
    /// → `CPortManager::TrySendingSynthDataSystemInfo`) i tylko wtedy, gdy coś się zmieniło.
    /// **Niezweryfikowane na żywym sprzęcie.**
    public func setSynthSettings(_ settings: G2SynthSettings, original: [UInt8]) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        guard let body = G2UsbProtocol.synthSettingsPayload(applying: settings, to: original) else {
            throw G2UsbError.badResponse("SynthSettings: response template is too short")
        }
        try await withPollingPaused {
            guard try await performWrite(G2UsbProtocol.setSynthSettingsPayload(body: body),
                                         label: "SynthSettings \(body.count) B")
            else {
                throw G2UsbError.badResponse("SynthSettings not acknowledged")
            }
        }
    }

    /// Przełącza urządzenie w tryb Performance / Patch (Performance Mode Change).
    /// Nord nie odpowiada na to `OK`, tylko `0x1F` z nowymi wersjami czterech slotów —
    /// także gdy tryb już był ten sam (zmierzone 2026-10-15 na G2 37, fw 1.62); bez
    /// uznania go za potwierdzenie każde przełączenie kończyło się błędem po 3 s.
    ///
    /// Nowe wersje slotów z tej odpowiedzi trzeba zapamiętać. Patch wysłany ze starą
    /// wersją Nord potwierdza i zapisuje mu NAZWĘ, ale zawartość wyrzuca: slot A z samą
    /// nazwą „dark-universe_13" i pustym wnętrzem, odpowiedź po 7 ms zamiast 157 ms i bez
    /// raportu zasobów DSP (zmierzone 2026-10-15) → [[Docs/context/bug-history]] #136.
    public func setPerformanceMode(_ performance: Bool) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            guard let response = try await performWrite(G2UsbProtocol.performanceModePayload(performance: performance),
                                                        label: "PerformanceMode \(performance)", timeout: 3.0,
                                                        expecting: G2UsbProtocol.subResponsePerformanceRelease)
            else {
                throw G2UsbError.badResponse("PerformanceMode not acknowledged")
            }
            guard response.subCommand == G2UsbProtocol.subResponsePerformanceRelease else { return }
            for entry in G2UsbProtocol.decodePerformanceReleaseVersions(response.payload)
                where entry.slot < UInt8(G2UsbProtocol.maxSlots)
            {
                slotVersions[Int(entry.slot)] = entry.version
            }
            // `0x1F` to u Clavii „performance zwolniony": `HandlePerformanceRelease`
            // ustawia stan synchronizacji na 1, a `CleanDirtyData` kończy go odblokowaniem
            // synchronizacji edytora, czyli `7D 00`. Bez tego Nord przestawał nadawać diody
            // i wskaźniki aż do wyłączenia (#163, log z 2026-10-27).
            _ = try? await performStep(G2UsbProtocol.startPayload())
        }
    }

    /// Wersja slotu, z którą poleci następna komenda — dla testów.
    func slotVersionForTesting(_ slot: Int) -> UInt8 {
        slotVersions[slot]
    }

    /// Nuta zagrana Z EDYTORA (`0x56` Play Note) — tak, jakby ktoś nacisnął klawisz
    /// na Nordzie. Komunikat systemowy, więc nie zależy od aktywnego slotu.
    ///
    /// Bez czekania na potwierdzenie i bez pauzowania `pollTask`, tak samo jak
    /// `setParameterLive`: klawiatura wysyła zdarzenia gęsto, a czekanie 3 s na ACK przy
    /// każdym naciśnięciu wyglądałoby jak zawieszenie. Ryzyko jest mniejsze niż przy
    /// zmianie struktury — zgubione „note off" naprawia następne naciśnięcie tego
    /// klawisza, a nie rozjeżdża stanu patcha. **Niezweryfikowane na żywym sprzęcie.**
    public func playNote(_ note: UInt8, on: Bool) throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try sendFrame(G2UsbProtocol.playNotePayload(note: note, on: on))
    }

    /// `0x71` Patch Load Request — prośba o raport obciążenia DSP jednego obszaru slotu.
    ///
    /// Bez czekania na odpowiedź, i to nie z pośpiechu: odpowiedzią jest `0x72`, które
    /// jest na liście `unsolicitedSubCommands`, więc `awaitResponse` odda je kanałowi
    /// powiadomień, zanim ktokolwiek uzna je za odpowiedź. Wynik odbiera się przez
    /// `setNotificationHandler`, tam gdzie i tak trafiają raporty nadawane samorzutnie.
    ///
    /// W codziennej pracy niepotrzebna — urządzenie nadaje `0x72` samo po każdej zmianie
    /// struktury. Potrzebna do POMIARU: żeby odczytać obciążenie patcha, którego nikt
    /// przed chwilą nie zmieniał. **Niezweryfikowane na żywym sprzęcie.**
    public func requestPatchLoad(slot: UInt8, area: PatchArea) throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        guard slot < UInt8(G2UsbProtocol.maxSlots) else {
            throw G2UsbError.badResponse("slot number out of range: \(slot)")
        }
        try sendFrame(G2UsbProtocol.patchLoadRequestPayload(
            slot: slot, version: slotVersions[Int(slot)], area: area
        ))
    }

    /// `S_SEL_VARIATION` (0x6A) — przełącza wariację slotu, dokładnie tak, jak zrobiłoby
    /// to naciśnięcie przycisku wariacji na froncie Norda. Komenda dotyczy SLOTU, więc
    /// niesie jego numer i wersję; urządzenie kwituje ją `OK`.
    ///
    /// Polling wstrzymany na czas oczekiwania — ten sam powód co przy `selectSlot`.
    /// **Niezweryfikowane na żywym sprzęcie.**
    public func selectVariation(slot: UInt8, variation: Int) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            let payload = G2UsbProtocol.selectVariationPayload(
                slot: slot, version: slotVersions[Int(slot)], variation: variation
            )
            guard try await performWrite(payload, label: "SelectVariation \(variation) slot \(slot)") else {
                throw G2UsbError.badResponse("SelectVariation \(variation) not acknowledged")
            }
        }
    }

    /// `S_COPY_VARIATION` (0x44) — przepisuje wariację `from` na `to` W URZĄDZENIU.
    /// Edytor robi u siebie to samo (`G2Patch.copyVariation`), więc obie strony zostają
    /// zgodne bez odczytywania slotu z powrotem. **Niezweryfikowane na żywym sprzęcie.**
    public func copyVariation(slot: UInt8, from: Int, to: Int) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            let payload = G2UsbProtocol.copyVariationPayload(
                slot: slot, version: slotVersions[Int(slot)], from: from, to: to
            )
            guard try await performWrite(payload, label: "CopyVariation \(from)→\(to) slot \(slot)") else {
                throw G2UsbError.badResponse("CopyVariation \(from)→\(to) not acknowledged")
            }
        }
    }

    /// `S_SEL_PARAM_PAGE` (0x2D) — przestawia stronę parametrów panelu Norda na tę,
    /// którą użytkownik wybrał w oknie Parameter Pages. Osiem gałek urządzenia zaczyna
    /// wtedy sterować tym samym, co osiem gałek okna — tak samo, jakby stronę wybrano
    /// przyciskiem na froncie. Komenda dotyczy SLOTU, więc niesie jego numer i wersję.
    ///
    /// Polling wstrzymany na czas oczekiwania — ten sam powód co przy `selectVariation`.
    /// **Zweryfikowane na żywym G2 37 (firmware 1.62) 2026-09-09.**
    public func selectParameterPage(slot: UInt8, page: Int) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            let payload = G2UsbProtocol.parameterPageFocusPayload(
                slot: slot, version: slotVersions[Int(slot)], page: page
            )
            guard try await performWrite(payload, label: "ParameterPage \(page) slot \(slot)") else {
                throw G2UsbError.badResponse("ParameterPage \(page) not acknowledged")
            }
        }
        parameterPage = page
    }

    /// `S_SEL_GLOBAL_PAGE` (0x1E) — to samo dla stron globalnych performance'u.
    /// Komunikat systemowy, bo molekuła należy do performance'u, nie do patcha.
    /// ⚠️ **Wciąż niesprawdzone na sprzęcie** — test 2026-09-09 objął sam przełącznik
    /// Global Pages, nie wybór strony przy nim włączonym.
    public func selectGlobalParameterPage(_ page: Int) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            let payload = G2UsbProtocol.globalParameterPageFocusPayload(version: systemVersion,
                                                                        page: page)
            guard try await performWrite(payload, label: "GlobalParameterPage \(page)") else {
                throw G2UsbError.badResponse("GlobalParameterPage \(page) not acknowledged")
            }
        }
        globalParameterPage = page
    }

    /// Przełącznik **Global Pages** — pole nagłówka performance'u o indeksie 2, wysyłane
    /// tą samą komendą `0x3F` co tempo i Run zegara (patrz `sendMasterClock`).
    /// **Zweryfikowane na żywym G2 37 (firmware 1.62) 2026-09-09, w obie strony.**
    public func setGlobalPages(_ enabled: Bool) async throws {
        try await sendMasterClock(G2UsbProtocol.setGlobalPagesPayload(enabled: enabled,
                                                                      version: systemVersion),
                                  label: "GlobalPages \(enabled)")
    }

    /// **Zawartość banków w pamięci Norda** — co jest pod którym numerem.
    ///
    /// Rozmowa jest kursorowa: pytamy „podaj od (typ, bank, miejsce)", urządzenie odsyła
    /// tyle nazw, ile mieści się w ramce, i mówi, od czego pytać dalej (patrz
    /// `G2UsbProtocol.decodeBankNames`). Tak samo czyta to BVerhue, u którego przejrzenie
    /// banków jest krokiem inicjalizacji połączenia.
    ///
    /// Odczyt jest nieniszczący, ale pętla ma **twardy limit obiegów**: gdyby odczyt bajtu
    /// sterującego był błędny, kursor mógłby stać w miejscu i edytor pytałby w kółko.
    ///
    /// **Zmierzone na sprzęcie 2026-09-07**: 723 pozycje (13 banków patchy, 4 banki
    /// performance'ów) w ~40 obiegach, po kilkanaście nazw na ramkę. Limit podniesiony
    /// z 96 na 256, bo pełniejsza pamięć zmieściłaby się w starym limicie ledwo albo
    /// wcale — a przekroczenie go ucina listę po cichu.
    public func readBankList(maxRequests: Int = 256) async throws -> [G2BankEntry] {
        guard transport != nil else { throw G2UsbError.notConnected }
        return try await withPollingPaused {
            try await withStreamStopped {
                var entries: [G2BankEntry] = []
                var cursor = G2BankCursor.start
                for _ in 0 ..< maxRequests {
                    guard !cursor.isFinished else { break }
                    let response = try await performStep(
                        G2UsbProtocol.listBankNamesPayload(cursor: cursor),
                        // Obie postacie odpowiedzi, bo urządzenie potrafi wcisnąć nazwy
                        // za nagłówek 0x13 — nasz dekoder ramki widzi wtedy 0x13, a nie
                        // 0x16, i samo 0x16 w tym zbiorze odrzucało całą odpowiedź.
                        expectSub: [G2UsbProtocol.subResponseBankNames,
                                    G2UsbProtocol.subResponseBankListInfo], timeout: 2.0
                    )
                    guard let response,
                          let body = G2UsbProtocol.bankNamesBody(payload: response.payload,
                                                                 subCommand: response.subCommand ?? 0),
                          let page = G2UsbProtocol.decodeBankNames(body)
                    else {
                        log?("    ? bank list: unrecognised reply to 0x14 — subcommand 0x\(String(response?.subCommand ?? 0, radix: 16)), payload \(hex(response?.payload ?? []))")
                        break
                    }
                    entries += page.entries
                    // Kursor, który nie drgnął, znaczy że urządzenie nie ma nic więcej
                    // do powiedzenia — bez tego warunku pętla kręciłaby się do limitu.
                    guard page.next != cursor else { break }
                    cursor = page.next
                }
                return entries
            }
        }
    }

    /// Załadowanie patcha z banku do slotu (`0x0A`) — to samo, co PATCH LOAD na froncie.
    /// `slot` 0–3 to sloty, **4 znaczy performance**.
    ///
    /// ✅ **Zweryfikowane na żywym Nordzie 2026-09-18** (`USBProbe --banktest-slot D`):
    /// po komendzie w slocie leży patch o nazwie z listy banków.
    ///
    /// ⚠️ **Urządzenie NIE odpowiada `OK`** — odpowiada tym, czym odpowiada na załadowanie
    /// patcha z własnego frontu: powiadomieniem o nowej wersji slotu (`0x38`, zmierzone
    /// `38 03 03` dla slotu D). Do 2026-09-18 metoda czekała na `OK` i rzucała wyjątkiem,
    /// choć patch był już w slocie — czyli dokładnie druga strona reguły „`OK` niczego nie
    /// dowodzi": **brak `OK` też niczego nie dowodzi**. Dlatego wysyłamy i wracamy;
    /// nową wersję slotu i przeładowanie zawartości załatwia zwykła droga powiadomień
    /// (`0x38` → `reloadSlot`), ta sama co przy ładowaniu z frontu → [[Docs/usb/protocol-map]].
    public func loadFromBank(slot: UInt8, bank: Int, patch: Int) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            try sendFrame(G2UsbProtocol.loadFromBankPayload(slot: slot, bank: bank, patch: patch))
        }
    }

    /// Bank Upload: pozycja z banku do slotu (`0x0A`) i od razu jej odczyt, bez oddawania
    /// toru komend. `slot` 0–3 zwraca jeden patch, **4 (performance) — cztery sloty
    /// i nagłówek**.
    ///
    /// Nord ogłasza załadowanie nową wersją slotu (`0x38`), więc czytamy dopiero po niej —
    /// wcześniejszy odczyt oddałby poprzednią zawartość. Gdyby ogłoszenie nie przyszło
    /// (performance mógł ogłosić się inaczej — niezmierzone), czytamy po czasie. Dowodem
    /// jest nazwa: w slocie ma leżeć to, co lista banków podała pod tym miejscem.
    public func retrieveFromBank(slot: UInt8, bank: Int, patch: Int, expectedName: String) async throws
        -> (patches: [G2Patch], performance: (name: String, settings: G2PerformanceSettings, section: [UInt8])?)
    {
        guard transport != nil else { throw G2UsbError.notConnected }
        return try await withPollingPaused {
            try await withStreamStopped {
                let before = slotVersions
                let watched = slot == 4 ? Array(0 ..< G2UsbProtocol.maxSlots) : [Int(slot)]
                try sendFrame(G2UsbProtocol.loadFromBankPayload(slot: slot, bank: bank, patch: patch))
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, !watched.contains(where: { slotVersions[$0] != before[$0] }) {
                    _ = try await awaitResponse(timeout: 0.1, accepting: [])
                }
                let expected = expectedName.trimmingCharacters(in: .whitespaces)
                for _ in 0 ..< 3 {
                    if slot == 4 {
                        var read: [G2Patch] = []
                        for index in UInt8(0) ..< UInt8(G2UsbProtocol.maxSlots) {
                            if let patch = try await readPatchSlot(index) { read.append(patch) }
                        }
                        if read.count == G2UsbProtocol.maxSlots,
                           var header = try await readPerformanceHeaderNow(),
                           header.name.trimmingCharacters(in: .whitespaces) == expected
                        {
                            let knobs = try await readGlobalKnobMapNow()
                            try PatchParser.parseUsbGlobalKnobMap(section: knobs, into: &header.settings)
                            for index in read.indices {
                                read[index].notes = try await readTextpadNow(UInt8(index))
                            }
                            return (read, header)
                        }
                    } else if var read = try await readPatchSlot(slot),
                              read.name.trimmingCharacters(in: .whitespaces) == expected
                    {
                        read.notes = try await readTextpadNow(slot)
                        return ([read], nil)
                    }
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
                throw G2UsbError.badResponse("the G2 did not load “\(expectedName)” from the bank")
            }
        }
    }

    /// Zapis zawartości slotu do banku (`0x0B`) — to samo, co STORE na froncie.
    /// `slot` 0–3 to sloty, **4 znaczy performance**. Zwraca kod wyniku z `R_STORE`
    /// (znaczenie: `G2UsbProtocol.storeResult`).
    ///
    /// ⛔ **Tylko wirtualny G2** (decyzja 2026-09-17): zapis nadpisuje miejsce w banku
    /// bez pytania, a na prawdziwym Nordzie ta komenda nie była jeszcze sprawdzona
    /// → [[Docs/usb/bank-dump]].
    ///
    /// Jedna próba, bez ponawiania: ponowiona komenda zapisałaby to samo miejsce drugi raz.
    /// Czas czekania długi, bo zapis do banku kasuje i programuje pamięć urządzenia.
    public func storeToBank(slot: UInt8, bank: Int, patch: Int) async throws -> UInt8 {
        guard transport != nil else { throw G2UsbError.notConnected }
        guard isEmulator else {
            throw G2UsbError.badResponse("writing to banks is only allowed on the virtual G2")
        }
        return try await withPollingPaused {
            let response = try await performStep(
                G2UsbProtocol.storeToBankPayload(slot: slot, bank: bank, patch: patch),
                expectSub: [G2UsbProtocol.subResponseStore, G2UsbProtocol.subResponseBankListInfo],
                timeout: 15.0, outerRetries: 1
            )
            guard let response,
                  let result = G2UsbProtocol.storeResult(payload: response.payload,
                                                         subCommand: response.subCommand ?? 0)
            else {
                throw G2UsbError.badResponse("no bank store result (0x0D)")
            }
            return result
        }
    }

    /// Nagłówek performance'u z urządzenia — **jedyne znane źródło stanów „slot gra"
    /// i „slot ma klawiaturę"**. Zwraca też nazwę performance'u.
    public func readPerformanceHeader() async throws
        -> (name: String, settings: G2PerformanceSettings, section: [UInt8])?
    {
        guard transport != nil else { throw G2UsbError.notConnected }
        return try await withPollingPaused {
            try await withStreamStopped {
                try await readPerformanceHeaderNow()
            }
        }
    }

    /// Nazwa performance'u **DO urządzenia** (`0x29` Performance Name Dump). Oryginał
    /// wysyła ją jako pierwszą molekułę pełnego zrzutu performance'u
    /// (Complete Performance Dump (WriteStream)), a poza zrzutem — samotnie,
    /// gdy użytkownik zmieni nazwę (`CPerformance::SetPerformanceName`).
    /// BVerhue robi to samo w kroku 1 `USBInitPerfSeq` → [[Docs/usb/slots]].
    /// **Niezweryfikowane na żywym sprzęcie.**
    public func setPerformanceName(_ name: String) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            guard try await performWrite(G2UsbProtocol.setPerformanceNamePayload(name),
                                         label: "PerformanceName \(name)")
            else {
                throw G2UsbError.badResponse("PerformanceName not acknowledged")
            }
        }
    }

    /// **Cały performance jednym komunikatem** (`0x1A` Complete Performance Dump) —
    /// tak wgrywa go oryginał, więc urządzenie nigdy nie widzi stanu pośredniego.
    ///
    /// **Zweryfikowane na żywym G2 37 (firmware 1.62) 2026-09-10, za pierwszym razem:**
    /// 14 345 B w jednej ramce, 0,41 s, a cztery sloty odczytane potem na świeżo zgodne
    /// z plikiem — razem z nazwami slotów, które niesie sekcja `0x11` w środku zrzutu.
    /// Odpowiedzią jest `0x36` z numerami sesji **pięciu** rzeczy naraz (cztery sloty
    /// i performance), nie `OK` → [[Docs/usb/slots]].
    ///
    /// Zwraca te numery; wersje slotów zapisuje po drodze, bo bez nich każda następna
    /// komenda slotu poszłaby ze starym numerem sesji.
    ///
    /// `patches` to modele tych samych czterech slotów — trafiają do lustra `patches[]`
    /// tak samo jak po `sendPatch`. Bez tego lustro zostawało przy poprzedniej zawartości
    /// i pierwsza zmiana „na żywo" (`syncPatch`) liczyła różnicę wobec starego patcha:
    /// kasowała wszystkie jego moduły i dodawała nowe (#129).
    @discardableResult
    public func sendCompletePerformanceDump(name: String, headerSection: [UInt8],
                                            slotStreams: [[UInt8]],
                                            knobMapSection: [UInt8],
                                            patches slotPatches: [G2Patch]) async throws
        -> [(slot: UInt8, version: UInt8)]
    {
        guard transport != nil else { throw G2UsbError.notConnected }
        let payload = G2UsbProtocol.completePerformanceDumpPayload(
            name: name, headerSection: headerSection,
            slotStreams: slotStreams, knobMapSection: knobMapSection
        )
        let label = "CompletePerformanceDump — \(payload.count)B w jednej ramce"
        return try await withPollingPaused {
            try await withStreamStopped {
                guard let response = try await performWrite(
                    payload, label: label, timeout: 10.0,
                    expecting: G2UsbProtocol.subPatchVersionResponse
                ), response.subCommand == G2UsbProtocol.subPatchVersionResponse else {
                    // Odrzucony zrzut i tak podbija numery sesji wszystkich slotów (po odmowie
                    // `0x7E` przychodzi `0x1F` z nowymi). Wysyłka slot po slocie, która rusza
                    // po tym błędzie, poszłaby ze starymi, a takiemu patchowi Nord zapisuje
                    // samą nazwę (#136) — dlatego pytamy o aktualne, zanim oddamy błąd (#165).
                    for slot in UInt8(0) ..< UInt8(G2UsbProtocol.maxSlots) {
                        let reply = try? await performStep(G2UsbProtocol.getPatchVersionPayload(slot: slot),
                                                           expectSub: [G2UsbProtocol.subPatchVersionResponse])
                        if let payload = reply?.payload, let decoded = G2UsbProtocol.decodePatchVersion(payload),
                           decoded.slot < G2UsbProtocol.maxSlots
                        {
                            slotVersions[Int(decoded.slot)] = decoded.version
                        }
                    }
                    throw G2UsbError.badResponse("the device did not acknowledge the performance dump")
                }
                let versions = G2UsbProtocol.decodePatchVersions(response.payload)
                for entry in versions where entry.slot < UInt8(G2UsbProtocol.maxSlots) {
                    slotVersions[Int(entry.slot)] = entry.version
                }
                for (slot, patch) in slotPatches.prefix(G2UsbProtocol.maxSlots).enumerated() {
                    patches[slot] = patch
                }
                return versions
            }
        }
    }

    /// Cała sekcja ustawień performance'u DO urządzenia (`0x11` Performance Header Dump) —
    /// jedno pole, którego nie ma w żadnej innej komendzie: **Hold i zakres klawiszy slotu**.
    /// Oryginał wysyła tę sekcję po zamknięciu okna Performance Settings
    /// (Performance dialog (TrySendData) → `CPerformance::SetPerformanceHeader`) i jako
    /// drugą molekułę pełnego zrzutu performance'u.
    /// **Niezweryfikowane na żywym sprzęcie.**
    public func setPerformanceHeader(section: [UInt8]) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        guard section.first == G2UsbProtocol.subPerformanceHeaderDump else {
            throw G2UsbError.badResponse("PerformanceHeader: not a 0x11 section")
        }
        try await withPollingPaused {
            guard try await performWrite(G2UsbProtocol.setPerformanceHeaderPayload(section: section),
                                         label: "PerformanceHeader \(section.count) B")
            else {
                throw G2UsbError.badResponse("PerformanceHeader not acknowledged")
            }
        }
    }

    /// Strumień powiadomień (VU + diody) leci dziesiątki razy na sekundę i potrafi
    /// zająć cały czas oczekiwania na odpowiedź. Handshake czyta wszystko po `Stop`
    /// i dlatego jest niezawodny — robimy tak samo przy każdym odczycie danych.
    /// U Clavii ta sama komenda nazywa się Synth Unlock Editor Sync.
    private func withStreamStopped<T>(_ body: () async throws -> T) async throws -> T {
        try await performStep(G2UsbProtocol.stopPayload())
        do {
            let result = try await body()
            try await performStep(G2UsbProtocol.startPayload())
            return result
        } catch {
            // `try?` gubi `@discardableResult`, stąd jawne `_ =`. Wynik i tak nie ma
            // znaczenia: lecimy z pierwotnym błędem, a `Start` jest próbą sprzątnięcia.
            _ = try? await performStep(G2UsbProtocol.startPayload())
            throw error
        }
    }

    /// Gałki globalne performance'u z urządzenia (`0x5E` → sekcja `0x5F`), wpisane
    /// w `settings`. Nagłówek `0x10` ich nie niesie, a bez nich kopia performance'u
    /// z Norda miała pustą mapę gałek → [[Docs/usb/bank-dump]].
    public func readGlobalKnobMap(into settings: inout G2PerformanceSettings) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        let section = try await withPollingPaused {
            try await withStreamStopped {
                try await readGlobalKnobMapNow()
            }
        }
        try PatchParser.parseUsbGlobalKnobMap(section: section, into: &settings)
    }

    private func readGlobalKnobMapNow() async throws -> [UInt8] {
        let response = try await performStep(G2UsbProtocol.globalKnobMapRequestPayload(),
                                             expectSub: [G2UsbProtocol.subGlobalKnobMap],
                                             timeout: 2.0, outerRetries: 1)
        guard let response, response.subCommand == G2UsbProtocol.subGlobalKnobMap,
              let section = G2UsbProtocol.globalKnobMapSection(payload: response.payload)
        else {
            throw G2UsbError.badResponse("the G2 did not send its global knob map")
        }
        return section
    }

    /// Notatnik slotu (`0x6E` → `0x6F`). Zrzut `0x3C` go nie niesie, a bez tego kopia
    /// banku gubiła notatki patchy → [[Docs/usb/bank-dump]].
    private func readTextpadNow(_ slot: UInt8) async throws -> String {
        let response = try await performStep(
            G2UsbProtocol.textpadRequestPayload(slot: slot, version: slotVersions[Int(slot)]),
            expectSub: [G2UsbProtocol.subTextpad], timeout: 2.0, outerRetries: 1
        )
        guard let response, response.subCommand == G2UsbProtocol.subTextpad, response.slot == slot,
              let section = G2UsbProtocol.textpadSection(payload: response.payload)
        else {
            throw G2UsbError.badResponse("the G2 did not send the notes of slot \(Character(UnicodeScalar(65 + slot)))")
        }
        return try PatchParser.parseUsbTextpad(section: section)
    }

    private func readPerformanceHeaderNow() async throws
        -> (name: String, settings: G2PerformanceSettings, section: [UInt8])?
    {
        do {
            let response = try await performStep(G2UsbProtocol.performanceHeaderRequestPayload(),
                                                 expectSub: [G2UsbProtocol.subPerformanceNameResponse],
                                                 timeout: 2.0)
            guard let response, response.subCommand == G2UsbProtocol.subPerformanceNameResponse else {
                log?("    ? performance header: reply 0x\(String(response?.subCommand ?? 0, radix: 16)) instead of 0x29")
                return nil
            }
            return PatchParser.parseUsbPerformanceHeader(payload: response.payload)
        } catch {
            log?("    ? performance header: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Zegar główny

    /// Stan zegara: czy tempo daje sam Nord, czy przychodzi z zewnątrz (MIDI clock),
    /// i jakie ono jest. Clock Info Request (0x3B) → Sys Clock Info (0x5D).
    ///
    /// Bez ponowień i z krótkim oczekiwaniem: to informacja pomocnicza (koloruje odczyt
    /// tempa i blokuje strzałki), a pytamy o nią przy łączeniu i po każdej przebudowie
    /// performance'u — trzy ponowienia po 2 s zatrzymywałyby wtedy wszystko inne.
    /// Dopóki odpowiedzi nie ma, zakładamy zegar wewnętrzny — tak samo robi oryginał
    /// (`IsClockExternal` zwraca fałsz, póki flaga „nieaktualne" jest zapalona)
    /// → [[Docs/ui/master-clock]] §6.2.
    public func readClockInfo() async throws -> (external: Bool, bpm: Int)? {
        guard transport != nil else { throw G2UsbError.notConnected }
        return try await withPollingPaused {
            try await withStreamStopped {
                let response = try await performStep(G2UsbProtocol.clockInfoRequestPayload(),
                                                     expectSub: [G2UsbProtocol.subSysClockInfoResponse],
                                                     timeout: 1.5,
                                                     outerRetries: 1)
                guard let payload = response?.payload else { return nil }
                return G2UsbProtocol.decodeSysClockInfo(payload)
            }
        }
    }

    /// Tempo zegara głównego (30…240 BPM) — `S_SET_MASTER_CLOCK` z indeksem 1.
    public func setMasterClock(bpm: Int) async throws {
        try await sendMasterClock(G2UsbProtocol.setMasterClockPayload(bpm: bpm, version: systemVersion),
                                  label: "MasterClock \(G2UsbProtocol.clampedBPM(bpm)) BPM")
    }

    /// Run/Stop zegara głównego — `S_SET_MASTER_CLOCK` z indeksem 0.
    public func setClockRunning(_ running: Bool) async throws {
        try await sendMasterClock(G2UsbProtocol.setClockRunPayload(running: running, version: systemVersion),
                                  label: "ClockRun \(running)")
    }

    /// Odpowiedzią jest `OK`, ale przyjmujemy też echo `0x3F` z ustawioną flagą odpowiedzi:
    /// ta sama podkomenda służy w obie strony i nie wiemy z góry, którą z nich urządzenie
    /// odeśle. Echo nadane z własnej inicjatywy idzie zwykłą drogą powiadomień
    /// (`awaitResponse` rozstrzyga to bitem nagłówka, nie treścią).
    private func sendMasterClock(_ payload: [UInt8], label: String) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            guard try await performWrite(payload, label: label, timeout: 3.0,
                                         expecting: G2UsbProtocol.subResponseMasterClock) != nil
            else {
                throw G2UsbError.badResponse("\(label) not acknowledged")
            }
        }
    }

    /// `SUB_COMMAND_SET_PARAM` (0x40) — zmienia JEDEN parametr na aktywnym slocie
    /// (patrz `selectSlot`), natychmiast, bez oczekiwania na potwierdzenie: to komenda
    /// `COMMAND_WRITE_NO_RESP`, urządzenie jej nie potwierdza (patrz `G2UsbProtocol.setParameterPayload`).
    /// Świadomie bez retry i bez pauzowania `pollTask` — w przeciwieństwie do `sendPatch`
    /// ta funkcja na nic nie czeka na tym samym endpointcie, więc nie ma z czym rywalizować,
    /// a przy ruchu gałki (dziesiątki wywołań/s) czekanie 3 s na nieistniejącą odpowiedź
    /// wyglądałoby jak zawieszenie. **Zweryfikowane na żywym sprzęcie 2026-09-03**
    /// (`USBProbe --livetest-slot D`) — patrz [[Docs/usb/actor]] „Real-time parametry".
    public func setParameterLive(slot: UInt8, area: PatchArea, moduleID: Int, paramIndex: Int, value: Int, variation: Int = 0) throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        let payload = G2UsbProtocol.setParameterPayload(
            slot: slot, version: slotVersions[Int(slot)], area: area,
            moduleID: moduleID, paramIndex: paramIndex, value: value, variation: variation
        )
        try sendFrame(payload)
    }

    /// Kilka `SET_PARAM` jedną ramką — tak Patch Adjuster oryginału wypuszcza wszystkie
    /// parametry jednej gałki naraz (`CPatch::ApplyDistribution` → `RealTimeBubbleOutput`).
    /// Ta sama droga i te same zasady co `setParameterLive`: bez potwierdzenia, bez
    /// czekania, bez pauzowania `pollTask`. Pusta lista nic nie wysyła.
    /// **Niezweryfikowane na żywym sprzęcie.**
    public func setParametersLive(slot: UInt8, changes: [G2ParameterChange], variation: Int) throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        let payload = G2UsbProtocol.setParametersPayload(
            slot: slot, version: slotVersions[Int(slot)], changes: changes, variation: variation
        )
        guard !payload.isEmpty else { return }
        try sendFrame(payload)
    }

    /// `S_ASSIGN_KNOB` (0x25) — przypina parametr do gałki panelu. Komenda dotyczy
    /// slotu i jest potwierdzana `OK`, więc idzie z pauzą pollingu, jak `selectVariation`.
    /// **Niezweryfikowane na żywym sprzęcie.**
    public func assignKnob(slot: UInt8, location: UInt8, moduleID: Int, paramIndex: Int,
                           knob: Int, isLed: Int) async throws
    {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            let payload = G2UsbProtocol.assignKnobPayload(
                slot: slot, version: slotVersions[Int(slot)], location: location,
                moduleID: moduleID, paramIndex: paramIndex, knob: knob, isLed: isLed
            )
            guard try await performWrite(payload, label: "AssignKnob \(knob) slot \(slot)") else {
                throw G2UsbError.badResponse("AssignKnob \(knob) not acknowledged")
            }
        }
    }

    /// `S_DEASSIGN_KNOB` (0x26) — zwalnia gałkę panelu.
    /// **Niezweryfikowane na żywym sprzęcie.**
    public func deassignKnob(slot: UInt8, knob: Int) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            let payload = G2UsbProtocol.deassignKnobPayload(
                slot: slot, version: slotVersions[Int(slot)], knob: knob
            )
            guard try await performWrite(payload, label: "DeassignKnob \(knob) slot \(slot)") else {
                throw G2UsbError.badResponse("DeassignKnob \(knob) not acknowledged")
            }
        }
    }

    /// Patch Header Dump (0x21) — wysyła opis patcha: liczbę głosów, Poly/Mono/Legato,
    /// kategorię i widoczność kolorów kabli. Bez tego suwak `Voices` w pasie slotu
    /// zmieniał tylko obraz na ekranie (usterka z 2026-09-08).
    ///
    /// Zwraca `true`, gdy urządzenie potwierdziło komendę — a potwierdza ją, zmierzone
    /// 2026-09-18. **Samo `true` niczego jednak nie dowodzi** (reguła z 2026-09-03):
    /// dowodem jest odczyt slotu, który robi `USBProbe --descriptiontest-slot`.
    ///
    /// `description` musi pochodzić z bieżącego odczytu slotu — ciało sekcji niesie
    /// także aktywną wariację, więc wysyłka zbudowana z pustego modelu przestawiłaby ją.
    ///
    /// ✅ **Zweryfikowane na żywym Nordzie 2026-09-18**: slot D, trzy pola wysłane,
    /// trzy odczytane z powrotem, opis przywrócony → [[Docs/usb/protocol-map]].
    @discardableResult
    public func setPatchDescription(slot: UInt8, description: G2PatchDescription) async throws -> Bool {
        guard transport != nil else { throw G2UsbError.notConnected }
        let body = try PatchParser.descriptionSectionBody(description)
        return try await withPollingPaused {
            let payload = G2UsbProtocol.setPatchDescriptionPayload(
                slot: slot, version: slotVersions[Int(slot)], sectionBody: body
            )
            return try await performWrite(payload, label: "PatchDescription slot \(slot)")
        }
    }

    /// Assigns one MIDI CC to a parameter and waits for the device acknowledgement.
    public func assignMidiController(slot: UInt8, cc: Int, location: UInt8,
                                     moduleID: Int, paramIndex: Int) async throws
    {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            let payload = G2UsbProtocol.assignMidiControllerPayload(
                slot: slot,
                version: slotVersions[Int(slot)],
                cc: cc,
                location: location,
                moduleID: moduleID,
                paramIndex: paramIndex
            )
            guard try await performWrite(payload, label: "Assign MIDI CC \(cc)") else {
                throw G2UsbError.badResponse("Assign MIDI CC \(cc) without acknowledgement")
            }
        }
    }

    /// Removes one MIDI CC assignment and waits for the device acknowledgement.
    public func deassignMidiController(slot: UInt8, cc: Int) async throws {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            let payload = G2UsbProtocol.deassignMidiControllerPayload(
                slot: slot,
                version: slotVersions[Int(slot)],
                cc: cc
            )
            guard try await performWrite(payload, label: "Deassign MIDI CC \(cc)") else {
                throw G2UsbError.badResponse("Deassign MIDI CC \(cc) without acknowledgement")
            }
        }
    }

    /// `SET_PARAM` dla **ustawień patcha** (obszar 2) — gałka i źródło morfu siedzą
    /// w module 1 tego obszaru. Ta sama komenda i ta sama droga co `setParameterLive`.
    /// **Niezweryfikowane na żywym sprzęcie.**
    public func setPatchSettingLive(slot: UInt8, moduleID: Int, paramIndex: Int,
                                    value: Int, variation: Int) throws
    {
        guard transport != nil else { throw G2UsbError.notConnected }
        let payload = G2UsbProtocol.setParameterPayload(
            slot: slot, version: slotVersions[Int(slot)], location: 2,
            moduleID: moduleID, paramIndex: paramIndex, value: value, variation: variation
        )
        try sendFrame(payload)
    }

    /// `S_SET_MORPH_RANGE` (0x43) — zakres morfu dla jednego parametru. Ta sama droga
    /// co `setParameterLive`: komenda bez potwierdzenia, wysyłana w trakcie gestu
    /// dziesiątki razy na sekundę (BVerhue puszcza obie tym samym wątkiem,
    /// `TSendParamThread.SendTable`). Zakres 0 kasuje przypisanie.
    /// **Niezweryfikowane na żywym sprzęcie.**
    public func setMorphRangeLive(slot: UInt8, location: UInt8, moduleID: Int, paramIndex: Int,
                                  morph: Int, range: Int, variation: Int) throws
    {
        guard transport != nil else { throw G2UsbError.notConnected }
        let payload = G2UsbProtocol.setMorphRangePayload(
            slot: slot, version: slotVersions[Int(slot)], location: location,
            moduleID: moduleID, paramIndex: paramIndex, morph: morph,
            range: range, variation: variation
        )
        try sendFrame(payload)
    }

    /// **Bufor odsłuchu Mutatora jedną paczką** — cztery sekcje (`0x4D` obszaru 2,
    /// `0x4D` Voice, `0x4D` FX, `0x65`) z jednym zestawem parametrów o numerze
    /// `variation`, w jednym komunikacie `0x4D`. Tak robi oryginał: Muta Param Dump
    /// jest jedną molekułą, a MIDI Out Stream pisze ją w całości.
    ///
    /// Zastępuje kilkaset komend `SET_PARAM` (`0x40`), które ten sam bufor przykładały
    /// parametr po parametrze — u użytkownika 393 ramki w jednej milisekundzie
    /// ([[Docs/context/bug-history]] #104), a każda zgubiona zostawała zgubiona,
    /// bo dalsze przesłuchania wysyłały tylko różnice.
    ///
    /// Komenda jest **potwierdzana** (`COMMAND_REQ`), jak każdy dump sekcji — i właśnie
    /// dlatego jest lepsza od zalewu: wiadomo, czy dotarła. Idzie z pauzą pollingu, jak
    /// pozostałe komendy czekające na odpowiedź z endpointu przerwań.
    /// **Na żywym Nordzie jeszcze niesprawdzone**; przebieg sprawdzający i jego wynik
    /// → [[Docs/usb/mutator-dump]] (sonda `USBProbe --mutatordump-slot`).
    public func sendMutatorDump(_ patch: G2Patch, toSlot slot: UInt8, variation: Int) async throws {
        let sections = try PatchParser.writeMutatorParamDump(patch, variation: variation)
        try await sendParamDump(sections, toSlot: slot, label: "MutatorDump → variation \(variation)")
    }

    /// Gotowe sekcje parametrów jednym komunikatem `0x4D`. Wydzielone z `sendMutatorDump`,
    /// żeby sonda mogła tą samą drogą wysłać sekcje z dziewięcioma zestawami — inaczej
    /// „urządzenie nie bierze tej komendy" nie da się odróżnić od „nie bierze sekcji
    /// z jednym zestawem".
    public func sendParamDump(_ combinedSectionBytes: [UInt8], toSlot slot: UInt8,
                              label: String = "ParamDump") async throws
    {
        guard transport != nil else { throw G2UsbError.notConnected }
        try await withPollingPaused {
            let payload = G2UsbProtocol.paramDumpPayload(slot: slot, version: slotVersions[Int(slot)],
                                                         combinedSectionBytes: combinedSectionBytes)
            guard try await performWrite(payload, label: "\(label) \(combinedSectionBytes.count)B") else {
                throw G2UsbError.badResponse("\(label): the device did not acknowledge the dump")
            }
        }
    }

    /// **Zmiany strukturalne na żywo** — moduł albo kabel dodany/skasowany w edytorze
    /// ma wylądować w Nordzie od razu, bez przepisywania całego slotu. Wysyłamy dokładnie
    /// różnicę między tym, co urządzenie w slocie ma (`patches[slot]`), a tym, co widać
    /// na ekranie: `DeleteCable` → `DeleteModule` → `AddModule` → `WriteCable`, w tej
    /// kolejności co oryginał (patrz `G2PatchDiff`).
    ///
    /// Nowe moduły dostają na koniec `ParamDump` **ograniczony do nich samych** — molekuła
    /// `AddModule` niesie typ, pozycję, kolor i tryby, ale nie wartości parametrów, więc
    /// bez tego kroku wklejony moduł grałby z ustawieniami domyślnymi urządzenia zamiast
    /// z tymi ze schowka. Tak samo robi Patch Data (GetNewModulesMolecules). Nazw nie
    /// dosyłamy: molekuła `AddModule` ma je w sobie.
    ///
    /// Zaraz po kablach idzie **uprate** (`0x2A`) modułów, które zmiana kabli przełączyła
    /// między częstotliwością audio i sterowania — to już rusza brzmienie.
    ///
    /// Na końcu idą zmiany, które nie ruszają brzmienia: **nazwa** modułu (`0x33`),
    /// **kolor** (`0x31`) i **pozycja** (`0x34`), każda własną komendą — moduł zostaje
    /// w slocie i gra dalej.
    ///
    /// `SelectSlot` NIE idzie przodem (inaczej niż w `sendPatch`): komendy strukturalne
    /// działają na slocie aktywnym urządzenia, a wołający wysyła tu wyłącznie zmiany
    /// slotu, który już jest aktywny — tak samo pilnuje tego `setParameterLive`.
    ///
    /// Mostek `patches[slot]` aktualizujemy dopiero po całej udanej serii: przerwana
    /// w połowie zostawia stary stan, więc następna zmiana wyśle różnicę jeszcze raz,
    /// razem z tym, co nie doszło.
    ///
    /// Zwraca liczbę wysłanych ramek (0 = różnicy nie było). Rzuca, gdy urządzenie
    /// którejkolwiek nie potwierdziło.
    @discardableResult
    public func syncPatch(_ patch: G2Patch, toSlot slot: UInt8) async throws -> Int {
        guard transport != nil else { throw G2UsbError.notConnected }
        let diff = G2PatchDiff.between(patches[Int(slot)], patch)
        guard !diff.isEmpty else { return 0 }

        return try await withPollingPaused {
            var frames = 0
            /// Molekuły jednego rodzaju lecą paczkami, jak bąbel oryginału: przy skasowaniu
            /// zaznaczenia z kilkunastoma kablami pojedyncze komendy znaczyłyby kilkanaście
            /// × ~250 ms (tyle Nord liczy przydział DSP po każdej zmianie strukturalnej).
            func send(_ molecules: [[UInt8]], _ label: String) async throws {
                for start in stride(from: 0, to: molecules.count, by: Self.moleculeBatchSize) {
                    let end = min(start + Self.moleculeBatchSize, molecules.count)
                    let payload = G2UsbProtocol.batchPayload(
                        slot: slot, version: slotVersions[Int(slot)],
                        molecules: Array(molecules[start ..< end])
                    )
                    guard try await performWrite(payload, label: "\(label) ×\(end - start)") else {
                        throw G2UsbError.badResponse("\(label): the device did not acknowledge the change")
                    }
                    frames += 1
                }
            }

            try await send(diff.cablesToDelete.map(G2UsbProtocol.deleteCableMolecule), "DeleteCable")
            try await send(diff.modulesToDelete.map(G2UsbProtocol.deleteModuleMolecule), "DeleteModule")
            try await send(diff.modulesToAdd.map(G2UsbProtocol.addModuleMolecule), "AddModule")
            try await send(diff.cablesToAdd.map(G2UsbProtocol.writeCableMolecule), "WriteCable")
            try await send(diff.modulesToUprate.map(G2UsbProtocol.setModuleUprateMolecule), "ModuleUprate")
            try await send(diff.modulesToRename.map(G2UsbProtocol.setModuleNameMolecule), "ModuleName")
            try await send(diff.modulesToRecolor.map(G2UsbProtocol.setModuleColorMolecule), "ModuleColor")
            try await send(diff.modulesToMove.map(G2UsbProtocol.setModulePositionMolecule), "ModuleMove")

            if !diff.modulesToAdd.isEmpty {
                var paramBytes: [UInt8] = []
                for area in PatchArea.allCases {
                    let added = diff.modulesToAdd.filter { $0.area == area }
                    paramBytes += try PatchParser.writeParamList(modules: added, area: area)
                }
                let payload = G2UsbProtocol.paramDumpPayload(slot: slot, version: slotVersions[Int(slot)],
                                                             combinedSectionBytes: paramBytes)
                guard try await performWrite(payload, label: "ParamDump \(paramBytes.count)B") else {
                    throw G2UsbError.badResponse("ParamDump: the device did not acknowledge the change")
                }
                frames += 1
            }

            // Podpisy parametrów i nazwy morfów (`0x42`) — po parametrach, jak w oryginale
            // (`GetNewModulesMolecules`: ParamDump → CustomDataDump).
            try await send(diff.labelsToWrite.map {
                G2UsbProtocol.setParamLabelMolecule(location: $0.location, moduleID: $0.moduleID, content: $0.content)
            }, "ParamLabel")

            patches[Int(slot)] = patch
            return frames
        }
    }

    /// Zatrzymuje `pollTask` bez zmiany `state` — używane wewnątrz komend, które same
    /// czekają na odpowiedź z tego samego endpointu przerwań i nie mogą z pollingiem
    /// o nią rywalizować (patrz `sendPatch`). `cancel()` jest tylko kooperacyjne: jeśli
    /// `pollOnce()` jest akurat w trakcie synchronicznego `libusb_bulk_transfer`, ten
    /// odczyt i tak dokończy się i może "ukraść" pierwszą odpowiedź wysyłki — dlatego
    /// czekamy na faktyczne zakończenie zadania (`await task?.value`), nie tylko na
    /// wysłanie żądania anulowania.
    private func pausePolling() async {
        pollPauseDepth += 1
        guard pollPauseDepth == 1 else { return } // już wstrzymany przez blok zewnętrzny
        let task = pollTask
        pollTask = nil
        task?.cancel()
        await task?.value
        if shouldDrainExtended { try? await drainPendingExtended() }
    }

    /// Wznawia polling dopiero, gdy skończy się OSTATNIE wstrzymanie — patrz `pollPauseDepth`.
    private func resumePolling() {
        guard pollPauseDepth > 0 else { return }
        pollPauseDepth -= 1
        guard pollPauseDepth == 0 else { return }
        startPolling()
    }

    /// Zabiera z 0x82 dane osierocone przez przerwany w połowie odbiór komunikatu
    /// „extended": zapowiedź odebrana z 0x81, payload nie. Dopóki taki payload tam wisi,
    /// urządzenie **nie przetwarza już żadnej komendy** — kolejne zapisy giną bez
    /// potwierdzenia, a gdy zapełni się jego bufor wejściowy, nawet wysyłka na 0x03
    /// kończy się `LIBUSB_ERROR_TIMEOUT`. Dokładnie tak wyglądały wszystkie nieudane
    /// próby `sendPatch` (2026-09-02…03) → [[Docs/usb/actor]].
    /// Opróżnia 0x82 do końca — po rozjeździe zapowiedzi z danymi w kolejce zostaje
    /// nieodebrany payload, a każdy kolejny odczyt byłby przesunięty o ten sam pakiet.
    private func resynchronizeExtended() async throws {
        for _ in 0 ..< 8 {
            let leftover = try await bulkRead(
                endpoint: G2UsbProtocol.endpointExtended,
                maxLength: G2UsbProtocol.extendedMessageSize,
                tries: 1,
                pacingSleep: false,
                quiet: true
            )
            if leftover.isEmpty { return }
        }
    }

    // MARK: - Diagnostyka martwego kanału 0x82 (#146)

    private func recordQuiet(_ line: String) {
        flushQuietEmptyPolls()
        flightRecorder.append("\(flightStamp.string(from: Date())) \(line)")
        if flightRecorder.count > Self.flightRecorderCapacity {
            flightRecorder.removeFirst(flightRecorder.count - Self.flightRecorderCapacity)
        }
    }

    private func flushQuietEmptyPolls() {
        guard quietEmptyPolls > 0 else { return }
        flightRecorder.append("\(flightStamp.string(from: Date())) … \(quietEmptyPolls) empty polls "
            + "(~\(quietEmptyPolls * 100) ms of silence)")
        quietEmptyPolls = 0
    }

    /// Przepisuje czarną skrzynkę do logu i ją opróżnia — kolejna awaria w serii pokaże
    /// tylko to, co przyszło od poprzedniej.
    private func dumpFlightRecorder(_ reason: String) {
        flushQuietEmptyPolls()
        guard !flightRecorder.isEmpty else { return }
        log?("    ┌ \(reason) — background traffic before it (\(flightRecorder.count) lines):")
        for line in flightRecorder {
            log?("    │ \(line)")
        }
        log?("    └ end of background traffic")
        flightRecorder.removeAll()
    }

    /// Brak potwierdzenia: czy w 0x82 nie leży payload, którego zapowiedź zginęła? Taki
    /// payload blokuje Norda (pułapka z #53), a od #91 sprzątamy 0x82 tylko po rozjeździe —
    /// więc nikt by go nie zabrał. Jeden odczyt, zapisany w logu: jeśli coś przyjdzie, mamy
    /// przyczynę ciszy; jeśli nie, zgubiona zapowiedź odpada.
    private func probeUnannouncedData() async throws {
        let orphan = try await bulkRead(endpoint: G2UsbProtocol.endpointExtended,
                                        maxLength: G2UsbProtocol.extendedMessageSize,
                                        tries: 1, pacingSleep: false)
        if orphan.isEmpty {
            log?("    ~ probe: nothing waiting on 0x82 without an announcement")
        } else {
            log?("    ~ probe: 0x82 held \(orphan.count)B with no announcement — an orphan was blocking the G2")
            extendedOrphanSuspected = true
        }
    }

    /// Zapowiedź bez danych: wina po stronie Maca (zablokowany kanał odbioru) czy Norda?
    /// `clear_halt` zeruje stan kanału po obu stronach. Jeśli zapowiedziane dane przyjdą
    /// po nim — wystarczy to zamiast resetu; jeśli nie — milczy sam Nord.
    private func probeSilentDataChannel(announcedLength: Int) async throws {
        guard let transport else { return }
        let cleared = transport.clearHalt(endpoint: G2UsbProtocol.endpointExtended)
        log?("    ~ probe: clear_halt 0x82 → \(cleared) (\(Self.libusbErrorName(cleared)))")
        let late = try await bulkRead(endpoint: G2UsbProtocol.endpointExtended,
                                      maxLength: max(announcedLength, G2UsbProtocol.extendedMessageSize),
                                      pacingSleep: false)
        log?("    ~ probe: after clear_halt 0x82 gave \(late.count)B of the announced \(announcedLength)B")
    }

    private func drainPendingExtended() async throws {
        let orphan = try await bulkRead(
            endpoint: G2UsbProtocol.endpointExtended,
            maxLength: G2UsbProtocol.extendedMessageSize,
            tries: 1,
            pacingSleep: false
        )
        if !orphan.isEmpty {
            log?("    ~ received a late 0x82 packet (\(orphan.count)B) — the device was blocked")
        }
    }

    /// Najpierw prawdziwy Nord, a gdy go nie ma — emulator. Kolejność jest regułą, nie
    /// wygodą: sprzęt zawsze wygrywa, więc podłączenie kabla nie może zostać przykryte
    /// przez zapomniany emulator działający w tle.
    ///
    /// Na emulator schodzimy **wyłącznie** przy `deviceNotFound`. Nieudany reset albo
    /// zajęty interfejs znaczą, że Nord JEST, tylko coś z nim nie tak — podstawienie
    /// wtedy atrapy zamieniłoby usterkę sprzętową w cichy sukces.
    private func openDevice() throws {
        // Furtka do testów: z podłączonym Nordem nie da się inaczej sprawdzić drogi
        // emulatora, bo sprzęt zawsze wygrywa. `G2_FORCE_EMULATOR=1` odwraca kolejność
        // tylko dla tego uruchomienia — aplikacja bez tej zmiennej zachowuje się normalnie.
        if ProcessInfo.processInfo.environment["G2_FORCE_EMULATOR"] == "1" {
            let emulator = EmulatorTransport()
            try emulator.open()
            transport = emulator
            log?("    G2_FORCE_EMULATOR=1 — skipping USB, connecting to the emulator")
            return
        }
        let usb = LibUsbTransport()
        do {
            try usb.open()
            transport = usb
            return
        } catch G2UsbError.deviceNotFound {
            let emulator = EmulatorTransport()
            do {
                try emulator.open()
                transport = emulator
                log?("    Nord not connected — connecting to the emulator (\(EmulatorTransport.socketPath))")
            } catch {
                throw G2UsbError.deviceNotFound
            }
        }
    }

    private func closeDevice() {
        identity = nil
        parameterPage = nil
        globalParameterPage = nil
        transport?.close()
        transport = nil
    }

    /// Czy po drugiej stronie stoi atrapa (wirtualny G2), a nie prawdziwy Nord.
    /// Belka musi to powiedzieć wprost, bo model urządzenia (`identity`) tego NIE
    /// zdradza — emulator przedstawia się tym samym numerem co sprzęt
    /// → [[Docs/usb/emulator]].
    public var isEmulator: Bool {
        transport is EmulatorTransport
    }

    // MARK: - Sekwencja inicjalizacji (port stanów eStateInit…eStateStart)

    private func runHandshake(readPatches: Bool = true) async throws {
        let initResponse = try await performStep(G2UsbProtocol.initPingPayload(), expectInit: true)
        identity = G2UsbProtocol.decodeDeviceIdentity(initResponse?.payload ?? [])
        log?("    device: \(identity?.displayName ?? "did not identify itself") \(identity?.firmwareText ?? "")")
        try await performStep(G2UsbProtocol.stopPayload())
        try await performStep(G2UsbProtocol.getSynthSettingsPayload())
        try await performStep(G2UsbProtocol.getMidiCcPayload())
        let globalPage = try await performStep(G2UsbProtocol.globalParameterPageFocusRequestPayload())
        if globalPage?.subCommand == G2UsbProtocol.subResponseGlobalParameterPageFocus {
            globalParameterPage = G2UsbProtocol.decodeParameterPageFocus(globalPage?.payload ?? [])
        }
        try await performStep(G2UsbProtocol.selectSlotPayload(slot: 0))

        for slot in UInt8(0) ..< UInt8(G2UsbProtocol.maxSlots) {
            let response = try await performStep(G2UsbProtocol.getPatchVersionPayload(slot: slot))
            if let payload = response?.payload, let decoded = G2UsbProtocol.decodePatchVersion(payload) {
                slotVersions[Int(decoded.slot)] = decoded.version
            }
        }

        // Strona parametrów slotu, który po `SelectSlot` jest edytowany. `try?`, bo to
        // pytanie niesprawdzone na sprzęcie, a nasz model trzyma jedną stronę na cały
        // edytor: brak odpowiedzi ma zostawić okno na stronie A1, a nie zerwać handshake.
        let page = try? await performStep(G2UsbProtocol.parameterPageFocusRequestPayload(
            slot: 0, version: slotVersions[0]
        ), timeout: 0.4, outerRetries: 1)
        if page?.subCommand == G2UsbProtocol.subResponseParameterPageFocus {
            parameterPage = G2UsbProtocol.decodeParameterPageFocus(page?.payload ?? [])
        }
        guard readPatches else {
            try await performStep(G2UsbProtocol.startPayload())
            return
        }

        // Odczyt patcha per slot: bajty CRC-zweryfikowane i sparsowane do G2Patch.
        // Format identyczny jak sekcje binarne pliku .pch2 (patrz PatchParser.parseUsbPatchSlot) —
        // zweryfikowane na żywym sprzęcie wielokrotnie (roundtrip/paramtest/deletetest w USBProbe
        // porównują bajt po bajcie odczyt po zapisie, patrz [[Docs/usb/actor]]).
        for slot in UInt8(0) ..< UInt8(G2UsbProtocol.maxSlots) {
            let response = try await performStep(G2UsbProtocol.getPatchSlotPayload(slot: slot, version: slotVersions[Int(slot)]))
            if let subCommand = response?.subCommand, let payload = response?.payload {
                let sectionBytes = [subCommand] + payload
                if let parsed = try? PatchParser.parseUsbPatchSlot(sectionBytes: sectionBytes) {
                    patches[Int(slot)] = parsed
                }
            }
        }
        // Nazwa patcha przychodzi osobną odpowiedzią (0x27) — w bajtach `GetPatchSlot`
        // jej nie ma, więc bez tego kroku `G2Patch.name` zostaje pusty we wszystkich slotach.
        // Numer slotu bierzemy z bajtu odpowiedzi (`commandResponse & 0x03`, jak
        // `usbComms.c:397`), nie z licznika pętli — odpowiedź niesie własny.
        for slot in UInt8(0) ..< UInt8(G2UsbProtocol.maxSlots) {
            let response = try await performStep(G2UsbProtocol.getPatchNamePayload(slot: slot, version: slotVersions[Int(slot)]))
            guard let response, response.subCommand == G2UsbProtocol.subPatchNameResponse,
                  let answeredSlot = response.slot
            else {
                log?("    ? slot \(slot) name: reply 0x\(String(response?.subCommand ?? 0, radix: 16)) instead of 0x27")
                continue
            }
            patches[Int(answeredSlot)].name = G2UsbProtocol.decodePatchName(response.payload)
        }
        try await performStep(G2UsbProtocol.startPayload())
    }

    @discardableResult
    private func performStep(
        _ payload: [UInt8],
        expectInit: Bool = false,
        expectSub: Set<UInt8>? = nil,
        timeout: TimeInterval = 0.6,
        outerRetries: Int = 3
    ) async throws -> G2UsbProtocol.DecodedResponse? {
        // Komenda może zmienić to, co wskaźniki pokazują (inny patch, inny slot, ekran
        // wyczyszczony po stronie aplikacji), więc zapamiętane bajty przestają być dowodem
        // „nic się nie zmieniło" — inaczej wskaźniki zostałyby wygaszone do pierwszego
        // drgnięcia dźwięku.
        lastVisualPayload.removeAll(keepingCapacity: true)
        var lastError: Error = G2UsbError.badResponse("no response from the device")
        for _ in 0 ..< outerRetries {
            do {
                try sendFrame(payload)
                if let response = try await awaitResponse(timeout: timeout, accepting: expectSub) {
                    if expectInit, response.responseType != G2UsbProtocol.responseTypeInit {
                        throw G2UsbError.badResponse("expected an init acknowledgement")
                    }
                    return response
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Czeka na odpowiedź NA NASZĄ komendę, pomijając strumień powiadomień, który
    /// urządzenie nadaje samo z siebie po `Start`. Bez tego filtra pierwszy lepszy
    /// `VOLUME_INDICATOR` był brany za potwierdzenie zapisu.
    ///
    /// `expectSub` to **jedyna** podkomenda uznawana wtedy za odpowiedź. Wszystko inne,
    /// co nie jest powiadomieniem, jest spóźnioną odpowiedzią na CUDZĄ komendę — zostaje
    /// odnotowane i pominięte, a czekanie trwa dalej. Do 2026-09-05 taki komunikat był
    /// zwracany jako „ta" odpowiedź: spóźniona nazwa patcha (0x27) potrafiła w ten sposób
    /// udawać numer sesji slotu → [[Docs/context/bug-history]] #63.
    ///
    /// Oryginał rozstrzyga to piętro niżej: `CInputMessage` ma w nagłówku flagi
    /// `IsResponse`/`IsBlink`/`IsVersion`, a Synth Port (HandleReceivedData) rozdziela
    /// ruch na cztery kanały, zanim ktokolwiek spojrzy na treść → [[Docs/usb/actor]].
    private func awaitResponse(timeout: TimeInterval,
                               accepting: Set<UInt8>? = nil) async throws -> G2UsbProtocol.DecodedResponse?
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let response = try await receiveResponse() else { continue }
            noteVersionChange(response)
            // Krok 0 — odpowiedź, na którą czekamy WPROST, choć ta sama podkomenda bywa też
            // powiadomieniem: `0x3E` dostaje w odpowiedzi `0x1F`, które Nord nadaje również
            // po załadowaniu patcha na froncie. Bez tego kroku krok 1 rozdawał je jako
            // powiadomienie i komenda czekała 3 s na potwierdzenie, które już przyszło
            // (zmierzone 2026-10-15). Bajt odpowiedzi musi mieć flagę odpowiedzi.
            if !response.isSynthInitiated, let accepting, let subCommand = response.subCommand,
               accepting.contains(subCommand)
            {
                return response
            }
            // Odmowa przychodzi BEZ flagi odpowiedzi. Zmierzone 2026-10-20 (Virtual G2,
            // fw 1.62): patch z notatką (Textpad) ponad ~1024 znaki, `0x37` do
            // slotu A → `01 00 01 7E 03` (bajt odpowiedzi 0x00 = „synth sam z siebie", slot 0).
            // Rozdane jako powiadomienie przepadało, a wysyłka czekała pełne 10 s na
            // potwierdzenie, które nie mogło już przyjść → [[Docs/context/bug-history]] #143.
            if let accepting, accepting.contains(G2UsbProtocol.subResponseError),
               response.subCommand == G2UsbProtocol.subResponseError
            {
                return response
            }
            // Krok 1 — czy to w ogóle odpowiedź? Rozstrzyga BAJT ODPOWIEDZI, nie treść.
            // Powiadomienie, które trafiło tu w trakcie czekania na ACK, jest tak samo
            // ważne jak to odebrane przez `pollOnce` — bez tego ruch gałki na Nordzie
            // ginął za każdym razem, gdy akurat trwał zapis strukturalny.
            if response.isSynthInitiated || G2UsbProtocol.isUnsolicited(response) {
                dispatch(response)
                continue
            }
            // Krok 2 — czy to odpowiedź na TĘ komendę. Wszystko inne jest spóźnioną
            // odpowiedzią na cudzą i czekamy dalej, zamiast brać ją za swoją.
            guard let accepting else { return response }
            if let subCommand = response.subCommand, accepting.contains(subCommand) { return response }
            log?("    ~ skipping 0x\(String(response.subCommand ?? 0, radix: 16)) — not a reply to this command")
        }
        return nil
    }

    /// `SUB_RESPONSE_PATCH_VERSION_CHANGE` (0x38) — urządzenie samo ogłasza nowy numer
    /// wersji slotu po każdej zmianie strukturalnej. G2-Edit aktualizuje z tego swoją
    /// tablicę `slotVersion` (`usbComms.c:368`) i każda kolejna komenda niesie już nową
    /// wartość; my dotąd trzymaliśmy wersję odczytaną raz podczas handshake.
    private func noteVersionChange(_ response: G2UsbProtocol.DecodedResponse) {
        guard response.subCommand == G2UsbProtocol.subResponsePatchVersionChange,
              let decoded = G2UsbProtocol.decodePatchVersion(response.payload),
              decoded.slot < G2UsbProtocol.maxSlots
        else { return }
        if slotVersions[Int(decoded.slot)] != decoded.version {
            log?("    ~ slot \(decoded.slot) version: \(slotVersions[Int(decoded.slot)]) → \(decoded.version)")
            slotVersions[Int(decoded.slot)] = decoded.version
        }
    }

    /// Zapis strukturalny: wysyła DOKŁADNIE raz i czeka na `SUB_RESPONSE_OK` (0x7F)
    /// lub `SUB_RESPONSE_ERROR` (0x7E). Bez ponowień — `performStep` powtarza wysyłkę
    /// do trzech razy, co przy `AddModule` dodałoby ten sam moduł trzy razy; G2-Edit
    /// też nigdy nie ponawia zapisu (`eStatePoll` wysyła i idzie dalej).
    @discardableResult
    private func performWrite(_ payload: [UInt8], label: String, timeout: TimeInterval = 3.0) async throws -> Bool {
        try await performWrite(payload, label: label, timeout: timeout, expecting: nil) != nil
    }

    /// Wariant zwracający odpowiedź — dla komend, których odpowiedzią są DANE, nie `OK`.
    /// `expecting` to podkomenda uznawana wtedy za poprawną odpowiedź (bez niej każda inna
    /// niż `OK` jest tylko odnotowywana w logu jako podejrzana).
    /// Zwraca `nil`, gdy urządzenie nie odpowiedziało albo odrzuciło komendę (0x7E).
    /// Z `rejection` odmowa rzuca tym błędem — wołający odróżni ją wtedy od milczenia,
    /// które przy wgrywaniu patcha bywa zawieszonym Nordem (#157).
    private func performWrite(_ payload: [UInt8], label: String, timeout: TimeInterval,
                              expecting: UInt8?,
                              rejection: G2UsbError? = nil) async throws -> G2UsbProtocol.DecodedResponse?
    {
        try sendFrame(payload)
        // Odpowiedzią zapisu jest `OK` albo `ERROR` — i nic innego. `expecting` dokłada
        // do tego podkomendę dla komend, których odpowiedzią są DANE (0x37 → 0x36).
        var accepting: Set<UInt8> = [G2UsbProtocol.subResponseOK, G2UsbProtocol.subResponseError]
        if let expecting { accepting.insert(expecting) }
        // 3s, nie 1s: potwierdzenie przychodzi zwykle w ~2ms, ale gdy urządzenie akurat
        // nadaje strumień powiadomień (`RESOURCES_USED` 0x72 to 63B na 0x82), pojedynczy
        // taki komunikat kosztuje setki ms i wypychał OK poza okno.
        guard let response = try await awaitResponse(timeout: timeout, accepting: accepting) else {
            log?("    ! \(label): no acknowledgement within \(timeout)s")
            dumpFlightRecorder("missing acknowledgement")
            try await probeUnannouncedData()
            return nil
        }
        if response.subCommand == G2UsbProtocol.subResponseError {
            log?("    ! \(label): device REJECTED the command (0x7E), payload \(hex(response.payload))")
            if let rejection { throw rejection }
            return nil
        }
        return response
    }

    // MARK: - Poll (heartbeat po zakończonym handshake)

    /// Druga pętla poll na tym samym urządzeniu jest gorsza niż żadna: obie czytają ten
    /// sam endpoint 0x81, więc każda „kradnie" połowę pakietów — także potwierdzenia,
    /// na które ktoś właśnie czeka. Stąd twardy warunek jednej pętli.
    private func startPolling() {
        guard pollTask == nil, transport != nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    try await self.pollOnce()
                } catch is CancellationError {
                    return // disconnect() już posprzątał stan — nie nadpisuj go
                } catch {
                    self.handlePollFailure(error)
                    return
                }
            }
        }
    }

    /// Nasłuch powiadomień urządzenia. `interruptTries: 1` (zamiast 5) i brak pauzy na
    /// końcu: `VOLUME_INDICATOR` leci ~40×/s, więc każde 50 ms uśpienia gubiło co drugi
    /// pakiet VU i opóźniało echo gałki z Norda. Gdy nic nie przychodzi, jedna próba to
    /// i tak 100 ms blokady w libusb — tempo pętli nadaje więc samo urządzenie.
    private func pollOnce() async throws {
        if let response = try await receiveResponse(interruptTries: 1, quiet: !logNotifications) {
            noteVersionChange(response)
            dispatch(response)
        }
        await Task.yield()
    }

    /// `pollTask = nil` jest tu konieczne: zadanie właśnie się kończy, a bez wyzerowania
    /// referencji `startPolling` po ponownym połączeniu uznałby, że pętla wciąż działa.
    private func handlePollFailure(_ error: Error) {
        pollTask = nil
        state = .error(error.localizedDescription)
        closeDevice()
    }

    // MARK: - Transfer niskiego poziomu

    private func sendFrame(_ payload: [UInt8]) throws {
        guard let transport else { throw G2UsbError.notConnected }
        guard payload.count + 4 <= 0xFFFF else {
            throw G2UsbError.transferFailed("frame of \(payload.count + 4) B exceeds the 65535 B limit")
        }
        var frame = G2UsbProtocol.buildFrame(payload: payload)
        // Cały patch to ~18 kB w jednej ramce, a przy Full Speed (12 Mb/s) to kilkadziesiąt
        // milisekund samego transferu — 100 ms wystarcza tylko komendom kilkubajtowym.
        let timeout: UInt32 = frame.count > 1024 ? 2000 : 100
        let (result, actualLength) = transport.write(&frame, endpoint: G2UsbProtocol.endpointOut, timeout: timeout)
        log?("    TX 0x03 code \(result) sent \(actualLength)/\(frame.count)B: \(hex(frame))")
        guard result == 0 else {
            throw G2UsbError.transferFailed("bulk write, code \(result) (\(Self.libusbErrorName(result)))")
        }
    }

    /// Nazwa stałej `LIBUSB_ERROR_*` dla kodu zwróconego przez `libusb_bulk_transfer`.
    /// Bez tego `-9` (zatkany endpoint) jest nie do odróżnienia od `-7` (zwykły timeout,
    /// czyli realny brak danych) — a to jest różnica między „urządzenie milczy" a
    /// „nasz kanał odbiorczy jest martwy".
    static func libusbErrorName(_ code: Int32) -> String {
        switch code {
        case 0: "SUCCESS"
        case LIBUSB_ERROR_IO.rawValue: "IO"
        case LIBUSB_ERROR_INVALID_PARAM.rawValue: "INVALID_PARAM"
        case LIBUSB_ERROR_ACCESS.rawValue: "ACCESS"
        case LIBUSB_ERROR_NO_DEVICE.rawValue: "NO_DEVICE"
        case LIBUSB_ERROR_NOT_FOUND.rawValue: "NOT_FOUND"
        case LIBUSB_ERROR_BUSY.rawValue: "BUSY"
        case LIBUSB_ERROR_TIMEOUT.rawValue: "TIMEOUT"
        case LIBUSB_ERROR_OVERFLOW.rawValue: "OVERFLOW"
        case LIBUSB_ERROR_PIPE.rawValue: "PIPE/STALL"
        case LIBUSB_ERROR_INTERRUPTED.rawValue: "INTERRUPTED"
        case LIBUSB_ERROR_NO_MEM.rawValue: "NO_MEM"
        case LIBUSB_ERROR_NOT_SUPPORTED.rawValue: "NOT_SUPPORTED"
        default: "OTHER(\(code))"
        }
    }

    /// Odczyt jednego pakietu interrupt (0x81); jeśli zapowiada dane rozszerzone,
    /// dociąga je z endpointu bulk (0x82) i weryfikuje CRC.
    private func receiveResponse(interruptTries: Int = 5, quiet: Bool = false) async throws -> G2UsbProtocol.DecodedResponse? {
        let interrupt = try await bulkRead(endpoint: G2UsbProtocol.endpointInterrupt, maxLength: G2UsbProtocol.interruptMessageSize, tries: interruptTries, quiet: quiet)
        guard !interrupt.isEmpty else { return nil }

        switch G2UsbProtocol.decodeInterruptHeader(interrupt) {
        case let .extended(announcedLength):
            // Realne patche bywają większe niż stały bufor 8192B z reference/G2-Edit —
            // odkryte na żywym sprzęcie (18122B dla zajętego slotu A); bufor musi więc
            // mieścić dokładnie zapowiedzianą długość, nie sztywną stałą.
            // `pacingSleep: false` — między zapowiedzią na 0x81 a odbiorem danych z 0x82
            // NIE wolno zostawić punktu anulowania: przerwanie tutaj osierociłoby payload
            // i zablokowało urządzenie (patrz `drainPendingExtended`). Tempo i tak nadaje
            // 100 ms timeout samego libusb, więc pętla nie kręci się w miejscu.
            var extended = try await bulkRead(
                endpoint: G2UsbProtocol.endpointExtended,
                maxLength: max(announcedLength, G2UsbProtocol.extendedMessageSize),
                tries: extendedReadTries,
                pacingSleep: false,
                quiet: quiet
            )
            // Odczyt zamknięty TIMEOUT-em oddaje początek komunikatu — reszta przychodzi
            // w następnym odczycie i należy do tego samego komunikatu.
            while !extended.isEmpty, extended.count < announcedLength {
                let rest = try await bulkRead(
                    endpoint: G2UsbProtocol.endpointExtended,
                    maxLength: max(announcedLength, G2UsbProtocol.extendedMessageSize),
                    tries: extendedReadTries,
                    pacingSleep: false,
                    quiet: quiet
                )
                if rest.isEmpty { break }
                extended += rest
            }
            // Rozjazd zapowiedzi z danymi NIE może zrywać połączenia. Dwa strumienie
            // (LED 0x39 i VU 0x3A) zapowiadają się na 0x81 i płyną przez 0x82, więc gdy
            // ktoś (diagnostyka, przerwany odbiór) zabierze jeden pakiet z pary, kolejne
            // odczyty są przesunięte o jeden. Wcześniej leciał tu błąd, `handlePollFailure`
            // zamykał urządzenie i edytor tracił Norda w środku pracy — objaw zgłoszony
            // jako „po chwili przestaje nadążać". Teraz: opróżniamy 0x82 do końca
            // (resynchronizacja) i traktujemy pakiet jak zgubiony.
            guard extended.count == announcedLength else {
                extendedOrphanSuspected = true
                log?("    ! stream mismatch: \(extended.count)B instead of the announced \(announcedLength)B — packet skipped")
                // Zapowiedź bez ANI BAJTU danych to na Nordzie martwy kanał 0x82, nie zgubiony
                // pakiet: w logu testera (G2 Engine, 2026-10-21 11:23:41) i u nas (G2 37,
                // 07:54:31) od tej chwili żadna odpowiedź z 0x82 już nie przyszła, a każda
                // komenda kończyła się brakiem potwierdzenia — wczytany patch zostawał na
                // ekranie, a Nord grał poprzedni. Zrywamy łącze jak przy wyjętym kablu: `tick`
                // połączy się od nowa (z resetem USB, jak G2-Edit po `gotBadConnectionIndication`)
                // i dośle zawartość ekranu → [[Docs/context/bug-history]] #146. Emulator bywa
                // wolniejszy niż nasze okno odczytu, więc jego to nie dotyczy.
                dumpFlightRecorder("stream mismatch")
                if extended.isEmpty, !isEmulator {
                    try await probeSilentDataChannel(announcedLength: announcedLength)
                    log?("    ! the G2 stopped sending on 0x82 — dropping the link to reconnect")
                    closeDevice()
                    state = .error("The G2 stopped answering — reconnecting")
                    throw G2UsbError.transferFailed("the G2 stopped sending data")
                }
                // Resynchronizacja MUSI być tutaj, a nie tylko w `finishCommandLane`: pętla
                // nasłuchu nie przechodzi przez tor komend, więc przesunięcie o jeden pakiet
                // zostawało w kolejce do najbliższej komendy — a każda komenda po drodze
                // czekała na potwierdzenie, którego już nie dało się sparować. Zgłoszenie
                // 2026-09-23: wczytanie kolejnego patcha kończyło się na „SelectSlot: brak
                // potwierdzenia", patch nie szedł na urządzenie i grał dalej poprzedni.
                try await resynchronizeExtended()
                extendedOrphanSuspected = false
                return nil
            }
            guard let verified = G2UsbProtocol.validateExtendedFrame(extended) else {
                log?("    ! bad CRC in extended data (\(extended.count)B) — packet skipped")
                return nil
            }
            return G2UsbProtocol.decodeResponseBody(verified)

        case let .embedded(dataLength):
            // Zapowiedziana długość OBEJMUJE CRC — tak samo jak w ramce „extended".
            // Zmierzone na sprzęcie 2026-09-05: `SUB_RESPONSE_OK` przychodzi jako
            // `01 0C 00 7F 8C AD`, czyli cztery bajty treści i suma kontrolna.
            guard let body = G2UsbProtocol.embeddedBody(interrupt, dataLength: dataLength) else {
                log?("    ! bad CRC in embedded packet (\(dataLength)B) — packet skipped")
                return nil
            }
            return G2UsbProtocol.decodeResponseBody(body)

        case .unknown:
            // Pakiet PRZYSZEDŁ, tylko go nie rozumiemy — `performStep` widzi to identycznie
            // jak ciszę i ponawia wysyłkę. Bez tego logu pięć prób na sprzęcie nie mogło
            // odróżnić „urządzenie milczy" od „odpowiada czymś nieznanym".
            log?("    ! unrecognised interrupt header (type \(interrupt[0] & 0x0F)) — treated as no reply")
            // Zapowiedź danych rozszerzonych (typ 1) z niezerowym wypełnieniem jest
            // odrzucana wyżej, ale urządzenie i tak wysyła zapowiedziany payload. Zostawiony
            // w kolejce przesuwa KAŻDĄ następną parę o jeden pakiet — tak zaczął się rozjazd
            // zmierzony 2026-09-23 (00:29:41), po którym edytor nie odczytał już nic.
            if interrupt.first.map({ $0 & 0x0F }) == G2UsbProtocol.responseTypeExtended {
                try await resynchronizeExtended()
            }
            return nil
        }
    }

    /// Mirror int_rec()/rcv_extended(): do 5 prób po 100ms; pusty wynik = brak danych
    /// (nie błąd). Rzuca tylko gdy urządzenie zniknęło (LIBUSB_ERROR_NO_DEVICE).
    private func bulkRead(endpoint: UInt8, maxLength: Int, tries: Int = 5, pacingSleep: Bool = true, quiet: Bool = false) async throws -> [UInt8] {
        guard let transport else { throw G2UsbError.notConnected }
        var buffer = [UInt8](repeating: 0, count: maxLength)

        for _ in 0 ..< tries {
            // Jedna próba = 100 ms okna, ale aktor nie może na nim zasnąć w całości: nuta
            // z klawiatury (`playNote`) czeka w kolejce aktora, a „on" i „off" wysłane
            // razem po 100 ms to nuta niesłyszalna. Transport mówi, jak długi plaster
            // jest bezpieczny; między plastrami `Task.yield()` puszcza zakolejkowane zadania.
            let slice = max(1, min(100, transport.readSliceMilliseconds))
            var result: Int32 = LIBUSB_ERROR_TIMEOUT.rawValue
            var actualLength: Int32 = 0
            var waited: UInt32 = 0
            while waited < 100 {
                (result, actualLength) = transport.read(&buffer, endpoint: endpoint, timeout: slice)
                waited += slice
                if result != LIBUSB_ERROR_TIMEOUT.rawValue || waited >= 100 { break }
                await Task.yield()
            }
            // Dane, które przyszły, są nasze — także gdy libusb oddaje je z TIMEOUT-em. Na macOS
            // pakiet potrafi dojść dokładnie w chwili, gdy okno 100 ms się zamyka: wynik to
            // TIMEOUT, a w buforze komplet 16 B. Do 2026-10-21 wyrzucaliśmy je — test na Nordzie
            // (`USBProbe --stress`) złapał tak dwa potwierdzenia w 25 min. Zgubiona tą drogą
            // ZAPOWIEDŹ zostawia dane w 0x82 i Nord przestaje odpowiadać (#146). Oryginał tego
            // nie zna, bo odczytu przerwań nigdy nie przerywa (`CUSBManager::HandleInterrupt`).
            if result == 0 || result == LIBUSB_ERROR_TIMEOUT.rawValue, actualLength > 0 {
                let bytes = Array(buffer.prefix(Int(actualLength)))
                let line = "RX 0x\(String(endpoint, radix: 16)) \(actualLength)B: \(hex(bytes))"
                if quiet { recordQuiet(line) } else { log?("    \(line)") }
                if result != 0 {
                    log?("    ~ RX 0x\(String(endpoint, radix: 16)) \(actualLength)B arrived with TIMEOUT — kept")
                }
                return bytes
            }
            if quiet, result == LIBUSB_ERROR_TIMEOUT.rawValue, endpoint == G2UsbProtocol.endpointInterrupt {
                quietEmptyPolls += 1
            }
            if result == LIBUSB_ERROR_NO_DEVICE.rawValue {
                throw G2UsbError.transferFailed("device disconnected")
            }
            // TIMEOUT to normalny „nic nie przyszło"; PIPE/OVERFLOW to zatrzaśnięty endpoint,
            // który bez `libusb_clear_halt` milczy już do końca sesji — a właśnie tak wygląda
            // obserwowana od trzeciej próby „cisza" przy pierwszym zapisie po `connect()`.
            if result != LIBUSB_ERROR_TIMEOUT.rawValue, result != 0 {
                log?("    RX 0x\(String(endpoint, radix: 16)) ERROR code \(result) (\(Self.libusbErrorName(result)))")
                if result == LIBUSB_ERROR_PIPE.rawValue || result == LIBUSB_ERROR_OVERFLOW.rawValue {
                    let cleared = transport.clearHalt(endpoint: endpoint)
                    log?("    RX 0x\(String(endpoint, radix: 16)) clear_halt → \(cleared) (\(Self.libusbErrorName(cleared)))")
                }
            }
            if pacingSleep { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        return []
    }

    /// Deskryptory endpointów aktywnej konfiguracji — rozstrzyga, czy 16-bajtowy bufor
    /// odczytu 0x81 odpowiada faktycznemu `wMaxPacketSize` urządzenia (za mały bufor =
    /// `LIBUSB_ERROR_OVERFLOW` i zatrzaśnięty endpoint). Treść zależy od transportu,
    /// więc opisuje się on sam (patrz `G2Transport.describeEndpoints`).
    public func describeEndpoints() -> String {
        transport?.describeEndpoints() ?? "brak otwartego urządzenia"
    }

    /// Diagnostyka na żywym sprzęcie: wysyła JEDEN komunikat (bez retry, bez interpretacji
    /// odpowiedzi) i przez `listenSeconds` nasłuchuje na OBU endpointach wejściowych,
    /// logując surowe bajty i kody błędów libusb. Nasłuch obejmuje 0x82 bez wcześniejszej
    /// zapowiedzi na 0x81 — gdyby odpowiedź szła tam bezpośrednio, `receiveResponse`
    /// nigdy by jej nie zobaczył. Zwraca liczbę odebranych pakietów.
    /// Wynik jednej diagnozy: surowe pakiety i to, co dało się z nich rozczytać.
    /// Bez `responses` narzędzie widzi tylko liczbę pakietów i nie umie oddzielić
    /// odpowiedzi na komendę od strumienia powiadomień (0x3A leci ~40×/s).
    /// Odpowiedź potrafi przyjść obiema drogami — krótka „embedded" w pakiecie 0x81,
    /// dłuższa jako ramka na 0x82 — więc obie są tu rozkodowane.
    public struct DiagnosticCapture: Sendable {
        public let interrupt: [[UInt8]]
        public let extended: [[UInt8]]
        public let responses: [G2UsbProtocol.DecodedResponse]
        public var packetCount: Int {
            interrupt.count + extended.count
        }
    }

    @discardableResult
    public func diagnoseCommand(name: String, payload: [UInt8], listenSeconds: Double = 1.5) async throws -> DiagnosticCapture {
        guard transport != nil else { throw G2UsbError.notConnected }
        log?("  — \(name): single send, listening \(listenSeconds)s —")
        // Diagnoza czyta 0x81 i 0x82 niezależnie, więc może rozerwać parę zapowiedź/dane.
        extendedOrphanSuspected = true
        try sendFrame(payload)

        let deadline = Date().addingTimeInterval(listenSeconds)
        var interruptPackets: [[UInt8]] = []
        var extendedPackets: [[UInt8]] = []
        var responses: [G2UsbProtocol.DecodedResponse] = []
        while Date() < deadline {
            let interrupt = try await bulkRead(endpoint: G2UsbProtocol.endpointInterrupt, maxLength: G2UsbProtocol.interruptMessageSize, tries: 1)
            if !interrupt.isEmpty {
                interruptPackets.append(interrupt)
                let kind = G2UsbProtocol.decodeInterruptHeader(interrupt)
                log?("    0x81 classification: \(kind)")
                // Krótka odpowiedź mieści się w samym pakiecie 0x81 — tak przychodzi m.in.
                // PatchVersion (0x36). Bez tego rozkodowania diagnoza „nie widzi" odpowiedzi.
                if case let .embedded(dataLength) = kind,
                   let body = G2UsbProtocol.embeddedBody(interrupt, dataLength: dataLength),
                   let decoded = G2UsbProtocol.decodeResponseBody(body)
                {
                    responses.append(decoded)
                }
            }
            let extended = try await bulkRead(endpoint: G2UsbProtocol.endpointExtended, maxLength: G2UsbProtocol.extendedMessageSize, tries: 1)
            if !extended.isEmpty {
                extendedPackets.append(extended)
                if let verified = G2UsbProtocol.validateExtendedFrame(extended),
                   let decoded = G2UsbProtocol.decodeResponseBody(verified)
                {
                    responses.append(decoded)
                }
            }
        }
        let capture = DiagnosticCapture(interrupt: interruptPackets, extended: extendedPackets, responses: responses)
        log?("  — \(name): \(capture.packetCount) packets in total —")
        return capture
    }

    /// Aktualny numer wersji slotu — potrzebny narzędziom diagnostycznym, które składają
    /// pojedynczą komendę same (`deleteModulePayload` i pokrewne wymagają wersji, a ta
    /// zmienia się po każdej zmianie strukturalnej).
    public func slotVersion(_ slot: UInt8) -> UInt8 {
        slotVersions[Int(slot)]
    }

    /// Wstrzymuje pętlę poll na czas bloku diagnostycznego, żeby nie rywalizowała
    /// o endpoint 0x81 z `diagnoseCommand`.
    public func withPollingPaused<T>(_ body: () async throws -> T) async rethrows -> T {
        try await withCommandLane(body)
    }

    /// Jedna komenda naraz, w kolejności zgłoszeń, ze wstrzymanym pollingiem.
    /// Każda operacja czekająca na odpowiedź MUSI przez to przejść.
    private func withCommandLane<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquireCommandLane()
        await pausePolling()
        do {
            let result = try await body()
            await finishCommandLane()
            return result
        } catch {
            await finishCommandLane()
            throw error
        }
    }

    /// Przed wznowieniem pollingu strumień musi być czysty: komendy czytają 0x81 i 0x82
    /// osobno i potrafią zostawić w kolejce payload bez zapowiedzi.
    private func finishCommandLane() async {
        if shouldDrainExtended {
            try? await resynchronizeExtended()
            extendedOrphanSuspected = false
        }
        resumePolling()
        releaseCommandLane()
    }

    private func acquireCommandLane() async {
        while commandLaneBusy {
            await withCheckedContinuation { commandLaneWaiters.append($0) }
        }
        commandLaneBusy = true
    }

    private func releaseCommandLane() {
        commandLaneBusy = false
        guard !commandLaneWaiters.isEmpty else { return }
        commandLaneWaiters.removeFirst().resume()
    }
}
