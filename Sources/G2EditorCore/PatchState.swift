import Combine
import Foundation
import G2Core
import Observation

@MainActor
@Observable
public final class PatchState {
    @ObservationIgnored public let undoManager = UndoManager()

    /// Liczba slotów — zawsze cztery, jak pasek slotów Clavii (TB Window): edytor pokazuje
    /// syntezator, a nie plik, więc `.pch2` wchodzi do slotu z focusem, a nie zastępuje
    /// dokumentu (decyzja użytkownika 2026-09-25).
    public static let slotTotal = G2UsbProtocol.maxSlots

    /// Cztery sloty A–D. Każdy ma własny plik `.pch2` (`slotFileURLs`), performance — swój `.prf2`.
    public var slots: [G2Patch] = Array(repeating: G2Patch(), count: PatchState.slotTotal) {
        didSet { refreshSlotSummaries() }
    }

    /// Liczba slotów i nagłówki pasów jako OSOBNE właściwości: kto potrzebuje tylko
    /// ich (okna slotów, pasy slotów), nie może czytać `slots` — pod `@Observable`
    /// każdy ruch gałki to zapis do `slots` i unieważnienie wszystkich, którzy je
    /// przeczytali, choćby po `.count`. Podmieniane wyłącznie przy realnej zmianie,
    /// bo sam zapis tej samej wartości też budzi obserwatorów → `SlotHeader`.
    public private(set) var slotCount = PatchState.slotTotal
    public private(set) var slotHeaders: [SlotHeader] = Array(repeating: .empty, count: PatchState.slotTotal)

    private func refreshSlotSummaries() {
        if slots.count != slotCount { slotCount = slots.count }
        let headers = slots.map(SlotHeader.init)
        if headers != slotHeaders { slotHeaders = headers }
    }

    /// Nagłówek pasa slotu — pusty, gdy slotu (jeszcze) nie ma, żeby pas nie miał
    /// prawa wywrócić aplikacji, bo dokument zmienił liczbę slotów.
    public func header(slot: Int) -> SlotHeader {
        slotHeaders.indices.contains(slot) ? slotHeaders[slot] : .empty
    }

    /// Index of the currently selected slot (0 = A, 1 = B, …).
    public var selectedSlot: Int = 0 {
        didSet { refreshShownFile() }
    }

    /// Nazwa zawartości edytora bez własnego pliku: `.prf2`, „Nord G2", „Empty perf",
    /// „No name". Pusta = nic jeszcze nie wczytano (ekran powitalny). Tytuł okna → `title`.
    public var fileName: String = ""
    public var errorMessage: String?

    // MARK: - Sheets (Patch/Performance/Synth menu)

    public var showPatchSettings: Bool = false
    public var showPatchNotes: Bool = false
    public var showPerformanceSettings: Bool = false
    /// Ustawienia samego urządzenia — okno żyje danymi z Norda (`DeviceConnection`),
    /// a nie patchem; tu jest tylko przełącznik, żeby menu miało co zapalić.
    public var showSynthSettings: Bool = false
    /// Okno Synth ▸ Bank Upload… — tak samo tylko przełącznik, dane bierze z Norda.
    public var showBankUpload: Bool = false

    /// Ustawienia performance'u z sekcji 0x11 pliku `.prf2` (BPM, zegar, zakres
    /// klawiatury, cztery sloty). `hasPerformanceSettings` mówi, czy plik faktycznie
    /// tę sekcję miał — bez tego zapis wpisałby wartości domyślne do pliku,
    /// którego sekcji nie udało się rozczytać.
    public var performance = G2PerformanceSettings()
    public private(set) var hasPerformanceSettings = false

    /// Nazwa performance'u — **to samo pole, które Nord pokazuje na wyświetlaczu**.
    /// Plik jej nie ma (nie zapisuje jej ani BVerhue `SaveToFile`, ani g2ools), więc
    /// bierze się z nazwy pliku: tak samo robi oryginał, gdzie `CPerformance::LoadFromFile`
    /// woła `Utils::MakePerformanceNameFromFileName`. Nowa performance dostaje
    /// „Empty perf" (`CPerformanceManager::CreateNewPerformance`), a użytkownik może ją
    /// zmienić — u Clavii w oknie Performance Settings (Performance dialog (TrySendData))
    /// albo klikając nazwę w pasku (TB Window → dialog „Performance Name").
    ///
    /// Urządzenie przyjmuje 16 znaków i tyle samo przyjmuje okno oryginału, więc dłuższe
    /// przycinamy w miejscu — inaczej ekran obiecywałby coś, czego Nord nie pokaże.
    /// Przycinanie siedzi w akcesorze, a nie w `didSet`: pod makrem `@Observable`
    /// przypisanie z `didSet` wraca do tego samego settera i pętli się bez końca.
    public var performanceName: String {
        get { storedPerformanceName }
        set { storedPerformanceName = String(newValue.prefix(G2UsbProtocol.performanceNameLength)) }
    }

    private var storedPerformanceName = ""

    /// Plik `.pch2` każdego slotu — jak u Clavii, gdzie każdy patch ma własny plik,
    /// a Save zapisuje patch slotu z focusem (`CPatch::SavePatch`).
    /// `nil` = slot bez pliku: nowy patch, zawartość z Norda, slot z otwartego `.prf2`.
    public private(set) var slotFileURLs: [URL?] = Array(repeating: nil, count: PatchState.slotTotal) {
        didSet { refreshShownFile() }
    }

    /// Oryginalne bajty pliku slotu — zapis i wysyłka idą patch-in-place, więc sekcje,
    /// których model nie zna, przeżywają. Zostają też po szablonie Init bez pliku.
    @ObservationIgnored public private(set) var slotFileData: [Data?] =
        Array(repeating: nil, count: PatchState.slotTotal)

    /// Plik `.prf2` otwartego performance'u (File ▸ Save Performance).
    public private(set) var performanceFileURL: URL? {
        didSet { refreshShownFile() }
    }

    /// Oryginalne bajty `.prf2` — potrzebne do zapisu patch-in-place i pełnego zrzutu.
    public private(set) var performanceFileData: Data?

    /// Plik tego, na co patrzy użytkownik: `.pch2` slotu z focusem, a bez niego `.prf2`.
    ///
    /// `didSet` dopisuje nagłówek do logu USB. Ustawia go wyłącznie `refreshShownFile()`,
    /// więc jedno miejsce wystarcza za wszystkie drogi zmiany pliku albo slotu.
    public private(set) var fileURL: URL? {
        didSet {
            USBLogFile.shared.setPatch(name: title, path: fileURL?.path)
            fileURLChanges.send(fileURL)
        }
    }

    /// `fileURL` na bieżąco — przeglądarka patchy podświetla otwarty plik. Osobny kanał,
    /// bo `@Published` z `private(set)` i `didSet` nie kompiluje się w Swift 5.9.
    public let fileURLChanges = CurrentValueSubject<URL?, Never>(nil)

    private func refreshShownFile() {
        let slotFile = slotFileURLs.indices.contains(selectedSlot) ? slotFileURLs[selectedSlot] : nil
        let shown = slotFile ?? performanceFileURL
        if shown != fileURL { fileURL = shown }
    }

    /// Tytuł okna: plik oglądanego slotu albo performance'u, inaczej nazwa zawartości.
    public var title: String {
        fileURL?.lastPathComponent ?? fileName
    }

    public var isLoaded: Bool {
        !fileName.isEmpty
    }

    /// Czy `save()` ma co nadpisać: slot z focusem ma własny `.pch2`. Bez niego Save pyta
    /// o plik, tak jak `CPatch::SavePatch` otwiera `SaveAsPatchDialog`.
    public var canSave: Bool {
        canSave(slot: selectedSlot)
    }

    public func canSave(slot: Int) -> Bool {
        slotFileURLs.indices.contains(slot) && slotFileURLs[slot] != nil
    }

    /// Czy Save Performance ma plik `.prf2` do nadpisania.
    public var canSavePerformance: Bool {
        performanceFileURL != nil
    }

    /// Nazwy, którymi oryginał chrzci świeżo utworzone rzeczy — u nas służą też za tytuł
    /// dokumentu bez pliku na dysku:
    /// • patch — BVerhue `TG2FileSlot.Init` (`FPatchName := 'No name'`), tę samą nazwę
    ///   wysyła po Init patch do urządzenia;
    /// • performance — Clavia `CPerformanceManager::CreateNewPerformance` woła
    ///   `SetName("Empty perf")`, a BVerhue tym samym stringiem odpowiada w
    ///   `USBInitPerfSeq` (`SendSetPerformanceMessage('Empty perf')`).
    static let emptyPatchName = "No name"
    static let emptyPerformanceName = "Empty perf"

    /// Convenience accessor for the currently visible patch (read/write).
    public var patch: G2Patch {
        get { slots[selectedSlot] }
        set { slots[selectedSlot] = newValue }
    }

    /// Slot z focusem — ten, który edytuje Nord (`0x09`) i na który idą operacje bez
    /// jawnego slotu. Focus idzie za OSTATNIM KLIKNIĘCIEM (decyzja użytkownika
    /// 2026-09-10): pas slotu B i okno slotu B wołają to przed każdą swoją akcją,
    /// więc gałka w cudzym pasie najpierw przenosi focus, a dopiero potem kręci.
    /// Poza zakresem i bez zmiany nic nie robi — przełączenie slotu ma skutki uboczne
    /// (komenda do urządzenia, czyszczenie wskaźników), więc nie wolno go powtarzać.
    public func focusSlot(_ slot: Int) {
        guard slots.indices.contains(slot), slot != selectedSlot else { return }
        selectedSlot = slot
    }

    public init() {
        watchUndoManagerForChanges()
    }

    // MARK: - Niezapisane zmiany

    /// Każdy slot ma własny plik, więc i „niezapisane zmiany" liczymy per slot: slot różni się
    /// od zdjęcia z chwili wczytania albo zapisu. Cofnięcie zmian do tego stanu znów daje
    /// „czysty", a cofnięcie za zapis — „zmieniony", jak w `NSDocument`. Zmiany przychodzące
    /// z Norda nie brudzą czystego slotu (`followingDevice`) — nie ma w nich pracy do zapisania.
    @ObservationIgnored private var savedSlots: [G2Patch] = Array(repeating: G2Patch(), count: PatchState.slotTotal)

    /// Zdjęcie tego, co leży w `.prf2`: cztery sloty, nagłówek i nazwa.
    private struct SavedPerformance {
        var slots: [G2Patch]
        var settings: G2PerformanceSettings
        var name: String
    }

    @ObservationIgnored private var savedPerformance = SavedPerformance(
        slots: Array(repeating: G2Patch(), count: PatchState.slotTotal),
        settings: G2PerformanceSettings(), name: ""
    )

    public func slotHasUnsavedChanges(_ slot: Int) -> Bool {
        slots.indices.contains(slot) && savedSlots.indices.contains(slot) && slots[slot] != savedSlots[slot]
    }

    /// `.prf2` na dysku różni się od tego, co w edytorze. Bez pliku performance'u nie ma
    /// czego pilnować — sloty pilnują wtedy własnych plików.
    public var performanceHasUnsavedChanges: Bool {
        guard performanceFileURL != nil else { return false }
        return slots != savedPerformance.slots || performance != savedPerformance.settings
            || performanceName != savedPerformance.name
    }

    /// Sloty, o które trzeba zapytać przed ich podmianą. Slot bez własnego pliku przy
    /// otwartym `.prf2` pomijamy — jego zmiany obejmuje pytanie o performance.
    public func unsavedSlots(among candidates: [Int]) -> [Int] {
        candidates.filter { slot in
            slotHasUnsavedChanges(slot) && !(slotFileURLs[slot] == nil && performanceFileURL != nil)
        }
    }

    /// Cokolwiek do zapisania — pytanie przy ⌘Q i zamknięciu okna.
    public var hasUnsavedChanges: Bool {
        !unsavedSlots(among: Array(slots.indices)).isEmpty || performanceHasUnsavedChanges
    }

    /// Zmiana z Norda (gałka, wariacja, strona) to nie praca użytkownika: slot, który był
    /// czysty wobec pliku albo `.prf2`, zostaje czysty.
    private func followingDevice(slot: Int, _ change: () -> Void) {
        guard slots.indices.contains(slot) else { return }
        let wasClean = savedSlots[slot] == slots[slot]
        let performanceWasClean = savedPerformance.slots[slot] == slots[slot]
        change()
        if wasClean { savedSlots[slot] = slots[slot] }
        if performanceWasClean { savedPerformance.slots[slot] = slots[slot] }
    }

    /// Zmiana z automatyki DAW-a (wtyczka, Etap 4): idzie do Norda jak ruch gałki w edytorze,
    /// ale nie jest edycją patcha — bez undo i bez „Save changes?" przy zamykaniu, tak samo
    /// jak ruch gałki na Nordzie (decyzja użytkownika 2026-09-25).
    public func automate(slot: Int, _ change: () -> Void) {
        undoManager.disableUndoRegistration()
        defer { undoManager.enableUndoRegistration() }
        followingDevice(slot: slot, change)
    }

    /// Zawartość slotu to teraz jego „zapisany" stan (wczytanie, zapis, zawartość z Norda).
    private func markSlotSaved(_ slot: Int) {
        guard slots.indices.contains(slot) else { return }
        savedSlots[slot] = slots[slot]
    }

    private func markPerformanceSaved() {
        savedPerformance = SavedPerformance(slots: slots, settings: performance, name: performanceName)
    }

    /// Nowa zawartość wszystkich slotów bez plików — nic w niej nie jest „niezapisane".
    private func forgetFiles() {
        slotFileURLs = Array(repeating: nil, count: Self.slotTotal)
        slotFileData = Array(repeating: nil, count: Self.slotTotal)
        performanceFileURL = nil
        performanceFileData = nil
        savedSlots = slots
        markPerformanceSaved()
    }

    @ObservationIgnored private var undoObservers: [NSObjectProtocol] = []

    /// Licznik zmian w historii undo — jedyne, co menu Edit może obserwować. `UndoManager`
    /// nie jest obserwowalny, więc pozycje „Undo …/Redo …" czytane wprost z niego stały na
    /// stanie sprzed kilku operacji, a wyszarzone po cofnięciu Redo połykało ⇧⌘Z
    /// (zgłoszenie użytkownika 2026-09-24). Widok czyta go w `body` i odświeża się z nim.
    public private(set) var undoRevision = 0

    private func watchUndoManagerForChanges() {
        let center = NotificationCenter.default
        let manager = undoManager
        // `queue: nil` = synchronicznie na wątku nadawcy, a `PatchState` żyje na głównym,
        // więc `assumeIsolated` jest bezpieczne.
        undoObservers = [
            center.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: manager, queue: nil) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.undoRevision += 1
                }
            },
            center.addObserver(forName: .NSUndoManagerDidUndoChange, object: manager, queue: nil) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.undoRevision += 1
                }
            },
            center.addObserver(forName: .NSUndoManagerDidRedoChange, object: manager, queue: nil) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.undoRevision += 1
                }
            },
        ]
    }

    // MARK: - Parametry i tryby

    /// Klucz pojedynczej edytowanej wartości — służy tylko do sklejania zmian w obrębie gestu.
    private struct ParameterKey: Hashable {
        let slot: Int
        let moduleID: Int
        let index: Int
        let isMode: Bool
        let isVoice: Bool
    }

    /// Klucz jednego zakresu morfu — do sklejania zmian w obrębie gestu, jak wyżej.
    private struct MorphKey: Hashable {
        let slot: Int
        let location: UInt8
        let moduleID: Int
        let paramIndex: Int
        let morph: Int
    }

    /// Sloty z włączonym „Edit all": ruch gałki trafia do wszystkich ośmiu wariacji naraz,
    /// nie tylko do grającej. Przycisk z edytora BVerhue (`EditAllVariations`) — Clavia
    /// go nie ma. Nie idzie do pliku; świeci na pomarańczowo, póki jest włączony.
    public private(set) var editAllVariationSlots: Set<Int> = []

    public func toggleEditAllVariations(slot: Int) {
        if !editAllVariationSlots.insert(slot).inserted { editAllVariationSlots.remove(slot) }
    }

    /// Czy trwa gest ciągły (przeciąganie gałki/fadera, przytrzymany +/−).
    private var gestureActive = false
    /// Wartości, dla których w tym geście zarejestrowano już undo.
    private var gestureRegistered: Set<ParameterKey> = []
    private var morphGestureRegistered: Set<MorphKey> = []
    /// Cofnięcia zebrane w trakcie gestu — trafiają do historii RAZEM, przy jego końcu.
    /// `UndoManager` skleja w jeden krok tylko to, co przyszło w jednym obiegu pętli
    /// zdarzeń, a pociągnięcie ołówkiem z wtyczki przychodzi w kilku wiadomościach:
    /// każda nowa kratka była osobnym ⌘Z (wykrył to test na CI GitHuba, 2026-10-16).
    private var gestureUndos: [(PatchState) -> Void] = []
    private var gestureActionName = ""

    /// Wywoływane po każdej ZMIENIONEJ wartości parametru (nie trybu) — bezpośrednia edycja
    /// I undo/redo, bo oba przechodzą przez `applyParameter`. `PatchState` nic nie wie o
    /// USB/G2Core — most do warstwy sprzętu podłącza ktoś z zewnątrz (`RootView`).
    public var onLiveParameterChange: ((_ slot: Int, _ area: PatchArea, _ moduleID: Int, _ paramIndex: Int, _ value: Int, _ variation: Int) -> Void)?
    /// Wszystkie parametry jednej gałki Patch Adjustera naraz — jedną ramką, jak
    /// `RealTimeBubbleOutput` oryginału; osobno od `onLiveParameterChange`, bo tamta
    /// droga to jedna komenda na parametr.
    public var onLiveParameterBatch: ((_ slot: Int, _ changes: [G2ParameterChange], _ variation: Int) -> Void)?

    /// Wywoływane po każdej zmianie STRUKTURY patcha — dodaniu/skasowaniu modułu albo
    /// kabla, wklejeniu, podmianie modułu i po każdym cofnięciu takiej zmiany. Most do
    /// urządzenia podłącza `RootView`, tak samo jak przy parametrach; `PatchState` nadal
    /// nic nie wie o USB.
    ///
    /// Przekazujemy cały patch, a nie opis zmiany: różnicę wobec stanu, który urządzenie
    /// naprawdę ma w slocie, liczy dopiero warstwa USB (`G2PatchDiff`). Dzięki temu jedno
    /// zgłoszenie obsługuje wszystkie drogi edycji — łącznie z undo/redo, które przywraca
    /// cały patch ze zdjęcia stanu i nie wie, co się w nim zmieniło.
    public var onLiveStructureChange: ((_ slot: Int, _ patch: G2Patch) -> Void)?

    /// Przesłuchanie z Mutatora — CAŁY bufor odsłuchu naraz, a po nim przełączenie
    /// patcha na zestaw `variation`. Osobno od `onLiveParameterChange` i od
    /// `onVariationChange`, bo to jedna molekuła oryginału (Muta Param Dump)
    /// i jej kolejność względem `0x6A` musi być pewna → [[Docs/usb/mutator-dump]].
    public var onMutatorAudition: ((_ slot: Int, _ patch: G2Patch, _ variation: Int) -> Void)?

    /// Dźwięk z Mutatora zapisany do wariacji (albo cofnięty) — urządzenie dostaje ten sam
    /// zrzut co przy odsłuchu, tylko z numerem zestawu `variations` zamiast 9, i BEZ
    /// przełączenia wariacji. Tak robi oryginał: Muta Synth Data (GetCopyIndividMolecules)
    /// dla celu „wariacja" pcha `CreateDumpMolecule` z nowymi wartościami (redo) i z dawnymi
    /// (undo). Do 2026-09-28 szło to `onLiveStructureChange`, które wartości nie niesie —
    /// wariacja zmieniała się tylko na ekranie (#129).
    public var onVariationDump: ((_ slot: Int, _ patch: G2Patch, _ variations: [Int]) -> Void)?

    /// Wariacja przełączona w edytorze — Nord ma grać tę samą (`0x6A`). Most, jak wyżej,
    /// podłącza `RootView`.
    public var onVariationChange: ((_ slot: Int, _ variation: Int) -> Void)?

    /// Wariacja przepisana na inną (`0x44`) — urządzenie kopiuje u siebie tak samo, jak
    /// edytor u siebie, więc nie ma potrzeby odsyłania wartości parametr po parametrze.
    public var onVariationCopy: ((_ slot: Int, _ from: Int, _ to: Int) -> Void)?

    /// Prawda, gdy to, co widać w edytorze, jest też w Nordzie — bo stamtąd przyszło
    /// albo bo właśnie tam poleciało (`markSentToDevice`). Tylko taką zawartość wolno
    /// urządzeniu podmienić; plik otwarty przy odłączonym Nordzie zostaje nietknięty.
    ///
    /// Do 2026-09-05 nazywało się to `isFromDevice` i zapalało się WYŁĄCZNIE przy
    /// odczycie z urządzenia. Odkąd otwarcie pliku od razu go do Norda wgrywa, flaga
    /// zostawała na `false` i edytor po otwarciu pliku głuchł na wszystko ze sprzętu:
    /// patch załadowany z frontu Norda nie miał jak wejść na ekran.
    public private(set) var mirrorsDevice = false {
        didSet {
            isUntouchedStart = false
            contentAtDeviceLoss = nil
        }
    }

    /// Zawartość z chwili, gdy Nord zniknął (`deviceLost`). Zmiana zrobiona potem do niego
    /// nie doszła, więc `mirrorsDevice` przestaje być prawdą — bez tego ponowne podłączenie
    /// kabla po cichu zastępowało ją zawartością Norda (znalezione 2026-10-15).
    private var contentAtDeviceLoss: (slots: [G2Patch], performance: G2PerformanceSettings)?

    /// Połączenie z urządzeniem się urwało.
    public func deviceLost() {
        guard mirrorsDevice else { return }
        contentAtDeviceLoss = (slots, performance)
    }

    /// Pusty dokument, od którego startuje aplikacja (`startEmpty`), jeszcze nietknięty.
    /// Nie ma w nim niczyjej pracy, więc podłączony Nord może go zastąpić swoją
    /// zawartością — tak jak dawniej ekran powitalny, który ten dokument zastąpił
    /// (decyzja użytkownika 2026-09-26). Gaśnie przy każdym otwarciu pliku, odczycie
    /// z urządzenia i wysyłce do niego (każde przypisanie `mirrorsDevice`).
    public private(set) var isUntouchedStart = false

    /// Czy urządzenie może podmienić to, co widać w edytorze — patrz `mirrorsDevice`
    /// i `isUntouchedStart`. Pierwsza zmiana w pustym dokumencie (moduł, nazwa, gałka)
    /// robi z niego pracę użytkownika i tej już nie oddajemy.
    public var mayBeReplacedByDevice: Bool {
        let unchangedOffline = contentAtDeviceLoss.map { $0.slots == slots && $0.performance == performance } ?? true
        return (mirrorsDevice && unchangedOffline) || (isUntouchedStart && !hasUnsavedChanges)
    }

    /// Start aplikacji: od razu pusta kanwa i cztery puste sloty zamiast ekranu powitalnego.
    public func startEmpty() {
        newPerformance()
        isUntouchedStart = true
    }

    /// Zawartość edytora właśnie poleciała do Norda (otwarcie pliku wgrywa go od razu),
    /// więc ekran i urządzenie pokazują to samo — od tej chwili ruch na froncie Norda
    /// znów może przejąć widok.
    public func markSentToDevice() {
        mirrorsDevice = true
    }

    /// Otwiera serię zmian jednego gestu: wszystkie zmiany tej samej wartości skleją się
    /// w JEDEN wpis undo. Bez tego cofnięcie jednego ruchu gałką wymagałoby setek ⌘Z.
    public func beginParameterGesture() {
        flushGestureUndos()
        gestureActive = true
        gestureRegistered.removeAll()
        morphGestureRegistered.removeAll()
    }

    /// Zamyka serię — następna zmiana będzie znów osobnym wpisem undo.
    public func endParameterGesture() {
        flushGestureUndos()
        gestureActive = false
        gestureRegistered.removeAll()
        morphGestureRegistered.removeAll()
    }

    /// Wpis undo dla jednej zmiany. W trakcie gestu liczy się tylko pierwsza zmiana danej
    /// wartości (`first`) i czeka na koniec gestu; poza gestem idzie od razu.
    private func registerUndo(_ actionName: String, first: Bool, _ undo: @escaping (PatchState) -> Void) {
        guard gestureActive else {
            undoManager.registerUndo(withTarget: self, handler: undo)
            undoManager.setActionName(actionName)
            return
        }
        guard first else { return }
        gestureUndos.append(undo)
        gestureActionName = actionName
    }

    /// Cały gest jako JEDEN wpis: cofnięcie przywraca wartości w odwrotnej kolejności.
    private func flushGestureUndos() {
        guard !gestureUndos.isEmpty else { return }
        let undos = gestureUndos
        gestureUndos.removeAll()
        undoManager.registerUndo(withTarget: self) { target in
            for undo in undos.reversed() { undo(target) }
        }
        undoManager.setActionName(gestureActionName)
    }

    /// Aktualizuje wartość parametru modułu i publikuje zmianę (odświeża canvas).
    public func setParameter(moduleID: Int, paramIndex: Int, value: Int, area: PatchArea) {
        applyParameter(slot: selectedSlot, moduleID: moduleID, index: paramIndex,
                       value: value, area: area, isMode: false, undoable: true)
    }

    /// Aktualizuje parametr w jawnie wskazanym slocie. Używa tego panel globalnych
    /// stron, ponieważ jego osiem kontrolek może wskazywać różne sloty performance'u.
    public func setParameter(slot: Int, moduleID: Int, paramIndex: Int, value: Int, area: PatchArea) {
        applyParameter(slot: slot, moduleID: moduleID, index: paramIndex,
                       value: value, area: area, isMode: false, undoable: true)
    }

    /// Zmiana chwilowa (przycisk Push Clavii: 1 na czas kliknięcia, zaraz potem z powrotem 0).
    /// Patch wraca po niej do stanu wyjściowego, więc nie ma czego cofać — pomijamy undo.
    public func setMomentaryParameter(moduleID: Int, paramIndex: Int, value: Int, area: PatchArea) {
        applyParameter(slot: selectedSlot, moduleID: moduleID, index: paramIndex,
                       value: value, area: area, isMode: false, undoable: false)
    }

    /// Aktualizuje tryb modułu (mode — np. DelayRange, Waveform) i publikuje zmianę.
    public func setMode(moduleID: Int, modeIndex: Int, value: Int, area: PatchArea) {
        applyParameter(slot: selectedSlot, moduleID: moduleID, index: modeIndex,
                       value: value, area: area, isMode: true, undoable: true)
    }

    /// Wspólna ścieżka zapisu parametru i trybu wraz z rejestracją undo.
    /// `slot` jest zapamiętany w akcji undo, żeby cofnięcie po przełączeniu slotu
    /// wróciło do tego samego patcha, w którym zmiana powstała.
    ///
    /// `fromAdjuster` = zmiana policzona przez gałkę Patch Adjustera: nie idzie do
    /// urządzenia pojedynczo (gałka wysyła całą paczkę sama) i nie rusza zdjęcia
    /// odniesienia. Każda inna zmiana parametru przy odkręconej gałce zdjęcie
    /// **przelicza** (`updateAdjusterBaseline`). Zwraca `true`, gdy wartość się zmieniła.
    @discardableResult
    private func applyParameter(slot: Int, moduleID: Int, index: Int, value: Int,
                                area: PatchArea, isMode: Bool, undoable: Bool,
                                fromAdjuster: Bool = false) -> Bool
    {
        guard slots.indices.contains(slot) else { return false }
        // Ten sam clamp co w G2Patch — inaczej ruch gałki na krańcu zakresu
        // rejestrowałby undo, które niczego nie zmienia.
        let clamped = max(0, min(127, value))
        guard let old = currentValue(slot: slot, moduleID: moduleID, index: index,
                                     area: area, isMode: isMode),
            old != clamped else { return false }

        // Chwilowe przyciski i gałki Patch Adjustera zostają przy grającej wariacji.
        if !isMode, undoable, !fromAdjuster, editAllVariationSlots.contains(slot) {
            setParameterInVariations(slot: slot, moduleID: moduleID, index: index, area: area,
                                     values: Array(repeating: clamped, count: G2Patch.initVariation))
            return true
        }

        if undoable {
            let key = ParameterKey(slot: slot, moduleID: moduleID, index: index,
                                   isMode: isMode, isVoice: area == .voice)
            // W trakcie gestu rejestrujemy tylko pierwszą zmianę danej wartości —
            // undo wraca wtedy do stanu sprzed całego ruchu.
            registerUndo(isMode ? "Change Mode" : "Change Parameter",
                         first: !gestureActive || gestureRegistered.insert(key).inserted)
            { target in
                target.applyParameter(slot: slot, moduleID: moduleID, index: index,
                                      value: old, area: area, isMode: isMode, undoable: true)
            }
        }

        if isMode {
            slots[slot].setMode(moduleID: moduleID, modeIndex: index, value: clamped, in: area)
        } else {
            slots[slot].setParameter(moduleID: moduleID, paramIndex: index, value: clamped, in: area)
            if !fromAdjuster {
                updateAdjusterBaseline(slot: slot, area: area, moduleID: moduleID, paramIndex: index,
                                       value: clamped, variation: slots[slot].activeVariation)
                onLiveParameterChange?(slot, area, moduleID, index, clamped, slots[slot].activeVariation)
            }
        }
        return true
    }

    /// Zapis parametru do wariacji 1–8 naraz (`values[wariacja]`) — „Edit all" i jego undo.
    /// Undo pamięta wartości każdej wariacji osobno, bo przed ruchem mogły się różnić.
    /// Do urządzenia idzie osobny `SET_PARAM` na każdą wariację: Nord zapisuje zmianę także
    /// w wariacji, której nie gra (sprawdzone na sprzęcie 2026-09-04, [[Docs/usb/actor]]).
    private func setParameterInVariations(slot: Int, moduleID: Int, index: Int,
                                          area: PatchArea, values: [Int])
    {
        guard let module = slots[slot].modules(in: area).first(where: { $0.id == moduleID })
        else { return }
        let before = values.indices.map { variation in
            module.parameterVariations.indices.contains(variation)
                && module.parameterVariations[variation].indices.contains(index)
                ? module.parameterVariations[variation][index] : values[variation]
        }
        let key = ParameterKey(slot: slot, moduleID: moduleID, index: index,
                               isMode: false, isVoice: area == .voice)
        registerUndo("Change Parameter", first: !gestureActive || gestureRegistered.insert(key).inserted) { target in
            target.setParameterInVariations(slot: slot, moduleID: moduleID, index: index,
                                            area: area, values: before)
        }
        for variation in values.indices where before[variation] != values[variation] {
            slots[slot].setParameter(moduleID: moduleID, paramIndex: index, value: values[variation],
                                     in: area, variation: variation)
            onLiveParameterChange?(slot, area, moduleID, index, values[variation], variation)
        }
        let active = slots[slot].activeVariation
        if values.indices.contains(active) {
            updateAdjusterBaseline(slot: slot, area: area, moduleID: moduleID, paramIndex: index,
                                   value: values[active], variation: active)
        }
    }

    private func currentValue(slot: Int, moduleID: Int, index: Int,
                              area: PatchArea, isMode: Bool) -> Int?
    {
        guard let module = slots[slot].modules(in: area).first(where: { $0.id == moduleID })
        else { return nil }
        let values = isMode ? module.modes : module.parameters
        return values.indices.contains(index) ? values[index] : nil
    }

    // MARK: - Patch Adjuster

    //
    // Osiem gałek, które ruszają wszystkimi parametrami jednej kategorii naraz
    // (instrukcja, str. 113). Gałki NIE są parametrami patcha: nie idą do pliku, nie
    // mają przypisań MIDI i nie zapisują się w wariacji — liczą tylko nowe wartości
    // parametrów względem ZDJĘCIA sprzed pierwszego ruchu, dokładnie jak
    // Module Param Data 11 u Clavii. Powrót gałki na środek przywraca patch co do bajtu.

    private struct AdjusterKey: Hashable {
        let area: PatchArea
        let moduleID: Int
        let paramIndex: Int
    }

    /// Jeden wpis zdjęcia: baza plus to, czego trzeba do przeliczenia jej w obie strony.
    private struct AdjusterBaseline {
        var base: Int
        let maxValue: Int
        let knob: G2AdjusterKnob
    }

    /// Położenia ośmiu gałek, −50…50. Brak wpisu = środek.
    public private(set) var adjuster: [G2AdjusterKnob: Int] = [:]
    /// Wartości parametrów sprzed ruszenia gałki — punkt odniesienia wszystkich przeliczeń.
    private var adjusterBaseline: [AdjusterKey: AdjusterBaseline] = [:]
    /// Patch, dla którego zdjęcie powstało.
    private var adjusterContext: String?

    /// Co unieważnia zdjęcie odniesienia: inny slot, inna wariacja, inny zestaw modułów.
    /// Instrukcja mówi to samo: „gdy przejdziesz do innej wariacji albo dodasz lub
    /// usuniesz moduł, zmiany zostają utrwalone, a gałki wracają na środek".
    public var adjusterContextID: String {
        guard slots.indices.contains(selectedSlot) else { return "-" }
        let patch = slots[selectedSlot]
        let modules = patch.modules(in: .voice).count + patch.modules(in: .fx).count
        return "\(selectedSlot)/\(patch.activeVariation)/\(modules)"
    }

    public func adjusterValue(_ knob: G2AdjusterKnob) -> Int {
        adjuster[knob] ?? 0
    }

    /// Ustawia gałkę i przelicza wszystkie parametry jej kategorii.
    public func setAdjuster(_ knob: G2AdjusterKnob, to value: Int) {
        guard slots.indices.contains(selectedSlot) else { return }
        if adjusterContext != adjusterContextID { commitAdjuster() }
        let clamped = max(G2PatchAdjuster.range.lowerBound,
                          min(G2PatchAdjuster.range.upperBound, value))
        guard adjusterValue(knob) != clamped else { return }

        let targets = G2PatchAdjuster.targets(in: slots[selectedSlot]).filter { $0.knob == knob }
        for target in targets {
            let key = AdjusterKey(area: target.area, moduleID: target.moduleID,
                                  paramIndex: target.paramIndex)
            if adjusterBaseline[key] == nil,
               let value = currentValue(slot: selectedSlot, moduleID: target.moduleID,
                                        index: target.paramIndex, area: target.area, isMode: false)
            {
                adjusterBaseline[key] = AdjusterBaseline(base: value, maxValue: target.maxValue, knob: knob)
            }
        }
        adjusterContext = adjusterContextID
        adjuster[knob] = clamped

        // Wszystkie zmiany jednej gałki lecą do Norda jedną ramką — jak bąbel oryginału.
        var changes: [G2ParameterChange] = []
        for target in targets {
            let key = AdjusterKey(area: target.area, moduleID: target.moduleID,
                                  paramIndex: target.paramIndex)
            guard let entry = adjusterBaseline[key] else { continue }
            let value = G2PatchAdjuster.adjusted(base: entry.base, maxValue: target.maxValue,
                                                 modifier: clamped)
            if applyParameter(slot: selectedSlot, moduleID: target.moduleID, index: target.paramIndex,
                              value: value, area: target.area, isMode: false, undoable: true,
                              fromAdjuster: true)
            {
                changes.append(G2ParameterChange(area: target.area, moduleID: target.moduleID,
                                                 paramIndex: target.paramIndex, value: value))
            }
        }
        if !changes.isEmpty {
            onLiveParameterBatch?(selectedSlot, changes, slots[selectedSlot].activeVariation)
        }
    }

    /// Ręczna zmiana parametru przy odkręconej gałce — z kanwy, ze strony parametrów,
    /// z frontu Norda albo przez undo. Oryginał (`CPatch::HandleParamChange`) nie nadpisuje
    /// wtedy wartości przy następnym ruchu gałki, tylko liczy **wstecz** nową bazę, tak
    /// żeby obecne położenie gałki dawało dokładnie to, co użytkownik ustawił.
    private func updateAdjusterBaseline(slot: Int, area: PatchArea, moduleID: Int, paramIndex: Int,
                                        value: Int, variation: Int)
    {
        guard slot == selectedSlot, adjusterContext == adjusterContextID,
              variation == slots[slot].activeVariation else { return }
        let key = AdjusterKey(area: area, moduleID: moduleID, paramIndex: paramIndex)
        guard let entry = adjusterBaseline[key] else { return }
        adjusterBaseline[key]?.base = G2PatchAdjuster.base(value: value, maxValue: entry.maxValue,
                                                           modifier: adjusterValue(entry.knob))
    }

    /// Utrwala to, co gałki zdążyły zrobić: zdjęcie odniesienia przepada, a gałki wracają
    /// na środek. Sam patch zostaje taki, jaki jest — nic tu nie zapisujemy.
    public func commitAdjuster() {
        guard !adjuster.isEmpty || adjusterContext != nil else { return }
        adjuster.removeAll()
        adjusterBaseline.removeAll()
        adjusterContext = nil
    }

    // MARK: - Nagłówek patcha: nazwa, kategoria, tryb głosów (pasek narzędzi)

    /// Nazwa patcha widocznego slotu. Instrukcja przycina ją do szesnastu znaków
    /// i zamienia „nielegalne" na spacje (str. 61) — robi to `G2PatchName.sanitized`.
    ///
    /// W performance nazwa należy do slotu (sekcja `0x11`), więc idzie w oba miejsca
    /// naraz; instrukcja opisuje to jako „Renaming single patches in Performances"
    /// (str. 97). Do urządzenia nie leci — komendy nagłówka patcha (`0x21`) jeszcze
    /// nie wysyłamy → [[Docs/usb/protocol-map]].
    public func setPatchName(_ raw: String, slot: Int? = nil) {
        let target = slot ?? selectedSlot
        guard slots.indices.contains(target) else { return }
        let name = G2PatchName.sanitized(raw)
        let old = slots[target].name
        guard old != name else { return }
        slots[target].name = name
        if performance.slots.indices.contains(target) {
            performance.slots[target].name = name
        }
        undoManager.registerUndo(withTarget: self) { [old] state in
            state.setPatchName(old, slot: target)
        }
        undoManager.setActionName("Rename Patch")
    }

    /// Opis patcha zmieniony w edytorze — liczba głosów, Poly/Mono/Legato i kategoria.
    /// Do urządzenia idzie całą sekcją `0x21`, bo Nord nie przyjmuje tych pól osobno.
    /// Most podłącza `ContentView`.
    public var onPatchDescriptionChange: ((_ slot: Int, _ description: G2PatchDescription) -> Void)?

    /// Kategoria dźwięku z rozwijanej listy w pasku (`G2PatchCategory`).
    public func setCategory(_ category: Int, slot: Int? = nil) {
        let target = slot ?? selectedSlot
        guard slots.indices.contains(target),
              G2PatchCategory.names.indices.contains(category) else { return }
        let old = slots[target].description.category
        guard old != category else { return }
        slots[target].description.category = category
        onPatchDescriptionChange?(target, slots[target].description)
        undoManager.registerUndo(withTarget: self) { [old] state in
            state.setCategory(old, slot: target)
        }
        undoManager.setActionName("Change Category")
    }

    /// Pozycja pokrętła Voice Mode — jedna liczba opisuje `voices` i `monopoly`
    /// naraz, patrz `G2VoiceMode`.
    public var voiceModeIndex: Int {
        voiceModeIndex(slot: selectedSlot)
    }

    /// Jak wyżej, ze wskazanego slotu — pas slotu B pokazuje głosy slotu B, nie tego
    /// z focusem.
    public func voiceModeIndex(slot: Int) -> Int {
        guard slots.indices.contains(slot) else { return 1 }
        let description = slots[slot].description
        return G2VoiceMode.index(voices: description.voices, monopoly: description.monopoly)
    }

    public func setVoiceMode(index: Int, slot: Int? = nil) {
        let target = slot ?? selectedSlot
        guard slots.indices.contains(target),
              (G2VoiceMode.minIndex ... G2VoiceMode.maxIndex).contains(index) else { return }
        let old = G2VoiceMode.index(voices: slots[target].description.voices,
                                    monopoly: slots[target].description.monopoly)
        guard old != index else { return }
        let fields = G2VoiceMode.fields(index: index)
        slots[target].description.voices = fields.voices
        slots[target].description.monopoly = fields.monopoly
        onPatchDescriptionChange?(target, slots[target].description)
        undoManager.registerUndo(withTarget: self) { [old] state in
            state.setVoiceMode(index: old, slot: target)
        }
        undoManager.setActionName("Change Voice Mode")
    }

    // MARK: - Wariacje

    /// Wariacja przełączona W EDYTORZE (okno Variations). Zmienia to, co pokazują gałki
    /// i dokąd trafiają kolejne zmiany parametrów, więc jest **cofalna** — tak samo robi
    /// oryginał, który przy każdym przełączeniu buduje parę undo/redo z molekuł
    /// Param Setting Focus (`CPatch::InternalSetFocusedParamSetting`).
    ///
    /// Wariacja init (8) nie jest wyborem użytkownika — do niej się kopiuje, na niej
    /// się nie gra, więc zakres kończy się na 7.
    public func selectVariation(_ variation: Int, slot: Int? = nil) {
        let target = slot ?? selectedSlot
        guard slots.indices.contains(target), (0 ... 7).contains(variation) else { return }
        let previous = slots[target].activeVariation
        guard previous != variation else { return }
        slots[target].setActiveVariation(variation)
        // Wybór wariacji kończy przesłuchiwanie w buforze mutatora — znacznik focusu
        // przenosi się na kratkę wariacji, tak jak w Muta Background dialog (SetupState).
        if target == selectedSlot { mutatorFocus = G2MutatorBox(.variations, variation) }
        // Z bufora mutatora (zestaw 9) nie ma powrotu tą drogą — taki krok cofania nic
        // by nie zrobił i zjadał jedno ⌘Z (#135).
        if (0 ... 7).contains(previous) {
            undoManager.registerUndo(withTarget: self) { state in
                state.selectVariation(previous, slot: target)
            }
            undoManager.setActionName("Select Variation")
        }
        onVariationChange?(target, variation)
    }

    /// Przepisanie jednej wariacji na drugą — przycisk „Init" (kopia z wariacji 8) i
    /// „Copy to" w oknie Variations. Kopia leci do urządzenia jedną komendą (`0x44`).
    /// Oryginał jej nie cofa, bo protokół nie ma komendy odwrotnej; u nas ⌘Z przywraca
    /// slot sprzed kopii i odsyła go do Norda w całości (`onSlotRestore`).
    public func copyVariation(from source: Int, to destination: Int, slot: Int? = nil) {
        let target = slot ?? selectedSlot
        let range = 0 ... 8
        guard slots.indices.contains(target), range.contains(source), range.contains(destination),
              source != destination else { return }
        let before = slotContents(target)
        slots[target].copyVariation(from: source, to: destination)
        onVariationCopy?(target, source, destination)
        registerSlotRestore(before, slot: target,
                            actionName: source == 8 ? "Init Variation" : "Copy Variation")
    }

    // MARK: - Morfy

    /// Morf „z focusem" — ten, którego dotyczą gesty na gałkach modułów i przyciski
    /// paska morfów. Oryginał trzyma dokładnie jedną taką wartość na cały edytor
    /// (Patch Manager (SetFocusedMorphGroup), ustawiana z paska morfów w TB Window).
    public var focusedMorph: Int = 0

    /// Zmieniony zakres morfu — do urządzenia idzie `0x43`. Most podłącza `RootView`.
    public var onMorphRangeChange: ((_ slot: Int, _ location: UInt8, _ moduleID: Int,
                                     _ paramIndex: Int, _ morph: Int, _ range: Int,
                                     _ variation: Int) -> Void)?

    /// Zmienione ustawienie patcha (obszar 2) — dziś gałka albo źródło morfu.
    public var onPatchSettingChange: ((_ slot: Int, _ moduleID: Int, _ paramIndex: Int,
                                       _ value: Int, _ variation: Int) -> Void)?

    /// Moduł ustawień patcha, w którym siedzą morfy (BVerhue `PATCH_MORPH`).
    /// Parametry 0–7 to gałki, 8–15 źródła.
    private static let morphSettingsModule = 1

    /// Ustawia zakres morfu dla parametru w bieżącej wariacji. Zakres 0 kasuje
    /// przypisanie — tak samo jak w oryginale, jedną i tą samą komendą.
    /// Cofalne i sklejane w obrębie gestu, jak zwykła gałka.
    public func setMorphRange(location: UInt8, moduleID: Int, paramIndex: Int,
                              morph: Int, range: Int)
    {
        let slot = selectedSlot
        guard slots.indices.contains(slot) else { return }
        let variation = slots[slot].activeVariation
        let old = slots[slot].morphRange(variation: variation, location: location,
                                         moduleID: moduleID, paramIndex: paramIndex, morph: morph)
        let clamped = max(-128, min(127, range))
        guard old != clamped else { return }
        guard slots[slot].setMorphRange(variation: variation, location: location,
                                        moduleID: moduleID, paramIndex: paramIndex,
                                        morph: morph, range: clamped) else { return }

        let key = MorphKey(slot: slot, location: location, moduleID: moduleID,
                           paramIndex: paramIndex, morph: morph)
        registerUndo("Change Morph Range", first: !gestureActive || morphGestureRegistered.insert(key).inserted) { target in
            target.setMorphRange(location: location, moduleID: moduleID,
                                 paramIndex: paramIndex, morph: morph, range: old)
        }
        onMorphRangeChange?(slot, location, moduleID, paramIndex, morph, clamped, variation)
    }

    /// Zdejmuje wszystkie przypisania jednego morfu w bieżącej wariacji
    /// (Clavia: „Clear Group"). Każde zdjęte przypisanie jedzie do urządzenia osobno —
    /// zbiorczej komendy protokół nie ma.
    public func clearMorph(_ morph: Int, slot: Int? = nil) {
        let slot = slot ?? selectedSlot
        guard slots.indices.contains(slot) else { return }
        let variation = slots[slot].activeVariation
        let removed = slots[slot].clearMorph(morph, in: variation)
        guard !removed.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreMorphs(removed, morph: morph, variation: variation, slot: slot)
        }
        undoManager.setActionName("Clear Morph")
        for entry in removed {
            onMorphRangeChange?(slot, entry.location, entry.moduleID, entry.paramIndex,
                                entry.morph, 0, variation)
        }
    }

    /// Przenosi przypisania jednego morfu na inny (Clavia: „Copy To ▸ Group N").
    /// Do urządzenia idzie kasowanie starego przypisania i założenie nowego.
    public func copyMorph(from source: Int, to destination: Int, slot: Int? = nil) {
        let slot = slot ?? selectedSlot
        guard slots.indices.contains(slot) else { return }
        let variation = slots[slot].activeVariation
        let before = slots[slot].morphs(in: variation).filter { $0.morph == source }
        let moved = slots[slot].copyMorph(from: source, to: destination, in: variation)
        guard !moved.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.copyMorph(from: destination, to: source, slot: slot)
        }
        undoManager.setActionName("Copy Morph")
        for entry in before {
            onMorphRangeChange?(slot, entry.location, entry.moduleID, entry.paramIndex,
                                source, 0, variation)
        }
        for entry in moved {
            onMorphRangeChange?(slot, entry.location, entry.moduleID, entry.paramIndex,
                                entry.morph, entry.range, variation)
        }
    }

    /// Wartość gałki morfu w bieżącej wariacji.
    public func setMorphDial(_ morph: Int, value: Int) {
        setMorphDial(morph, value: value, slot: selectedSlot)
    }

    /// Jak wyżej, ale w jawnie wskazanym slocie — tak jak `setParameter(slot:…)`.
    /// Potrzebne stronom parametrów: gałka może wskazywać morf w innym slocie
    /// performance'u (Global Pages).
    public func setMorphDial(_ morph: Int, value: Int, slot: Int) {
        guard slots.indices.contains(slot), (0 ..< G2Morph.count).contains(morph) else { return }
        let variation = slots[slot].activeVariation
        let old = slots[slot].morphDial(morph, in: variation)
        let clamped = max(0, min(127, value))
        guard old != clamped else { return }
        slots[slot].setMorphDial(morph, in: variation, value: clamped)
        let key = MorphKey(slot: slot, location: 2, moduleID: Self.morphSettingsModule,
                           paramIndex: morph, morph: morph)
        registerUndo("Change Morph", first: !gestureActive || morphGestureRegistered.insert(key).inserted) { target in
            target.setMorphDial(morph, value: old, slot: slot)
        }
        onPatchSettingChange?(slot, Self.morphSettingsModule, morph, clamped, variation)
    }

    /// Źródło morfu (0 = tylko gałka, 1 = nazwane źródło, 2 = „G Wh 1" dla morfu 5).
    public func setMorphMode(_ morph: Int, value: Int) {
        setMorphMode(morph, value: value, slot: selectedSlot)
    }

    /// Jak wyżej, we wskazanym slocie.
    public func setMorphMode(_ morph: Int, value: Int, slot: Int) {
        guard slots.indices.contains(slot), (0 ..< G2Morph.count).contains(morph) else { return }
        let variation = slots[slot].activeVariation
        let old = slots[slot].morphMode(morph, in: variation)
        guard old != value else { return }
        slots[slot].setMorphMode(morph, in: variation, value: value)
        let new = slots[slot].morphMode(morph, in: variation)
        undoManager.registerUndo(withTarget: self) { target in
            target.setMorphMode(morph, value: old, slot: slot)
        }
        undoManager.setActionName("Change Morph Source")
        onPatchSettingChange?(slot, Self.morphSettingsModule, morph + G2Morph.count, new, variation)
    }

    /// Ustawienie patcha z arkusza Patch Settings (Glide, Bend, Vibrato, Arpeggiator…)
    /// w bieżącej wariacji.
    ///
    /// Do 2026-09-09 suwaki tego arkusza były podpięte wprost do modelu i **nie wysyłały
    /// niczego** — Nord grał dalej po staremu. Idą tą samą drogą co gałka morfu, bo to
    /// ten sam obszar 2 i ten sam sposób adresowania: numer grupy sekcji `0x4d` jest
    /// numerem modułu, pozycja w grupie numerem parametru (`G2PatchSetting`).
    ///
    /// Cofalne i sklejane w obrębie gestu — przeciągnięcie suwaka ma być jedną pozycją
    /// w historii, nie setką.
    public func setPatchSetting(_ setting: G2PatchSetting, value: Int) {
        setPatchSetting(setting, value: value, slot: selectedSlot)
    }

    /// Jak wyżej, we wskazanym slocie — dla stron parametrów, których gałka może
    /// wskazywać ustawienie w innym slocie performance'u.
    public func setPatchSetting(_ setting: G2PatchSetting, value: Int, slot: Int) {
        guard slots.indices.contains(slot) else { return }
        let variation = slots[slot].activeVariation
        guard slots[slot].variationSettings.indices.contains(variation) else { return }

        let clamped = max(setting.range.lowerBound, min(setting.range.upperBound, value))
        let old = slots[slot].variationSettings[variation][keyPath: setting.keyPath]
        guard old != clamped else { return }
        slots[slot].variationSettings[variation][keyPath: setting.keyPath] = clamped

        let key = MorphKey(slot: slot, location: 2, moduleID: setting.module,
                           paramIndex: setting.param, morph: -1)
        registerUndo("Change \(setting.label)",
                     first: !gestureActive || morphGestureRegistered.insert(key).inserted)
        { target in
            target.setPatchSetting(setting, value: old, slot: slot)
        }
        onPatchSettingChange?(slot, setting.module, setting.param, clamped, variation)
    }

    /// Bieżąca wartość ustawienia patcha — arkusz czyta przez to, żeby nie sięgać
    /// do modelu z pominięciem `setPatchSetting`.
    public func patchSetting(_ setting: G2PatchSetting) -> Int {
        patchSetting(setting, slot: selectedSlot)
    }

    /// Jak wyżej, ze wskazanego slotu.
    public func patchSetting(_ setting: G2PatchSetting, slot: Int) -> Int {
        guard slots.indices.contains(slot) else { return 0 }
        let variation = slots[slot].activeVariation
        guard slots[slot].variationSettings.indices.contains(variation) else { return 0 }
        return slots[slot].variationSettings[variation][keyPath: setting.keyPath]
    }

    /// Odtworzenie zdjętych przypisań (undo dla `clearMorph`).
    private func restoreMorphs(_ entries: [G2MorphAssignment], morph: Int,
                               variation: Int, slot: Int)
    {
        guard slots.indices.contains(slot) else { return }
        for entry in entries {
            slots[slot].setMorphRange(variation: variation, location: entry.location,
                                      moduleID: entry.moduleID, paramIndex: entry.paramIndex,
                                      morph: entry.morph, range: entry.range)
            onMorphRangeChange?(slot, entry.location, entry.moduleID, entry.paramIndex,
                                entry.morph, entry.range, variation)
        }
        undoManager.registerUndo(withTarget: self) { target in
            target.clearMorph(morph, slot: slot)
        }
        undoManager.setActionName("Clear Morph")
    }

    // MARK: - Mutator

    /// Prawdopodobieństwo, zasięg, prawdopodobieństwo krzyżowania i `Link`.
    public var mutatorSettings = G2MutatorSettings()
    /// Rząd `Quick Locks` pod oknem — siedem kategorii i solo pod każdą.
    public var mutatorLocks = G2MutatorLocks()
    /// Ustawienia panelu „Mutation settings", które obowiązują TERAZ — okno podaje tu
    /// `PanelController.effectiveMutatorSettings`, więc przy zwiniętym panelu to Standard.
    public var mutatorPanel = G2MutatorPanelSettings.standard

    /// Osiem kratek górnego rzędu: 0…5 to dzieci, 6 Mother, 7 Father.
    public private(set) var mutatorParents: [G2Individual?] =
        Array(repeating: nil, count: G2Mutator.parentBoxCount)
    /// Temporary Storage — trzy rzędy po osiem kratek.
    public private(set) var mutatorStorage: [G2Individual?] =
        Array(repeating: nil, count: G2Mutator.storageCount)
    /// Kratka, której dźwięk jest w tej chwili w patchu.
    public private(set) var mutatorFocus: G2MutatorBox?
    /// Ilu rodziców zrobiło obecne dzieci — 1 albo 2. Oryginał tym maluje kratki
    /// dzieci: granatowo po `Mutate`/`Randomize`, oliwkowo po `Interpolate`/`Cross`.
    public private(set) var mutatorParentCount = 1
    /// Drzewo ewolucji — każdy dźwięk, który tu powstał, z rodzicami i przyciskiem.
    /// Tylko rośnie: undo cofa kratki, nie historię; czyści je dopiero inny patch.
    public private(set) var mutatorTree = G2MutatorTree()

    /// Genom bieżącego slotu. Przeliczany, gdy zmieni się układ modułów — sam
    /// spis parametrów jest drogi, a kratki odświeżają się przy każdym rysowaniu.
    public var mutatorGenome: G2MutatorGenome {
        let signature = mutatorGenomeSignature
        if let cached = cachedGenome, cached.signature == signature { return cached.genome }
        let genome = G2MutatorGenome(patch: patch)
        cachedGenome = (signature, genome)
        return genome
    }

    @ObservationIgnored private var cachedGenome: (signature: Int, genome: G2MutatorGenome)?

    private var mutatorGenomeSignature: Int {
        var hasher = Hasher()
        hasher.combine(selectedSlot)
        for area in [PatchArea.voice, PatchArea.fx] {
            for module in patch.modules(in: area) {
                hasher.combine(module.id)
                hasher.combine(module.typeID)
                hasher.combine(module.parameters.count)
                hasher.combine(module.excludedFromMutation)
            }
        }
        return hasher.finalize()
    }

    /// Zawartość kratki. Wariacje czytamy wprost z patcha — to one są prawdą.
    public func mutatorIndividual(at box: G2MutatorBox) -> G2Individual? {
        switch box.kind {
        case .parents:
            return mutatorParents.indices.contains(box.index) ? mutatorParents[box.index] : nil
        case .storage:
            return mutatorStorage.indices.contains(box.index) ? mutatorStorage[box.index] : nil
        case .variations:
            guard box.index < 8 else { return nil }
            return G2Mutator.individual(from: patch, variation: box.index, genome: mutatorGenome)
        }
    }

    public func mutatorHasData(at box: G2MutatorBox) -> Bool {
        box.kind == .variations ? box.index < 8 : mutatorIndividual(at: box) != nil
    }

    // MARK: Operacje

    /// `Mutate` — sześcioro dzieci z Mother. Kratka w argumencie (podwójny klik,
    /// klawisz `E`) wędruje najpierw na miejsce Mother.
    public func mutatorMutate(from source: G2MutatorBox? = nil) {
        mutatorMutate(seed: source.flatMap { mutatorIndividual(at: $0) })
    }

    /// Podwójny klik w kratkę drzewa: ten dźwięk zostaje Mother i od razu ma dzieci.
    public func mutatorMutate(from node: G2MutatorTree.NodeID) {
        guard mutatorTree.contains(node) else { return }
        mutatorMutate(seed: mutatorTree.sound(of: node))
    }

    private func mutatorMutate(seed: G2Individual?) {
        beginMutatorEdit("Mutate")
        if let seed {
            mutatorParents[G2Mutator.motherIndex] = seed
        } else if mutatorParents[G2Mutator.motherIndex] == nil {
            mutatorParents[G2Mutator.motherIndex] = currentIndividual()
        }
        guard let mother = mutatorParents[G2Mutator.motherIndex] else { return }
        var generator = SystemRandomNumberGenerator()
        let audibility = mutatorAudibility(of: mother)
        let anchoring = mutatorAnchoring()
        let children = pooled(.mutate, parents: [mother], audibility: audibility) {
            anchoring.apply(G2Mutator.mutate(parent: mother, genome: mutatorGenome, settings: mutatorSettings,
                                             locks: mutatorLocks, audibility: audibility,
                                             groups: mutatorPanel.groupWeights, using: &generator),
                            mother: mother)
        }
        finishBreeding(keepAudible(children, parents: [mother]) {
            anchoring.apply(G2Mutator.mutateOnce(parent: mother, genome: mutatorGenome, settings: mutatorSettings,
                                                 locks: mutatorLocks, audibility: audibility,
                                                 groups: mutatorPanel.groupWeights, using: &generator),
                            mother: mother)
        }, parents: [mother], origin: .mutate)
    }

    /// `Randomize` — sześcioro dzieci o wartościach losowanych od zera. Parametry
    /// zablokowane przepisujemy z dźwięku, który ma focus (tak jak `CopyRandomizeContext`).
    public func mutatorRandomize() {
        beginMutatorEdit("Randomize")
        let base = mutatorFocus.flatMap { mutatorIndividual(at: $0) } ?? currentIndividual()
        mutatorParents[G2Mutator.motherIndex] = base
        var generator = SystemRandomNumberGenerator()
        let audibility = mutatorAudibility(of: base)
        let anchoring = mutatorAnchoring()
        let children = pooled(.randomize, parents: [base], audibility: audibility) {
            anchoring.apply(G2Mutator.randomize(base: base, genome: mutatorGenome, locks: mutatorLocks,
                                                audibility: audibility, groups: mutatorPanel.groupWeights,
                                                using: &generator),
                            mother: base)
        }
        finishBreeding(keepAudible(children, parents: [base]) {
            anchoring.apply(G2Mutator.randomize(base: base, genome: mutatorGenome, locks: mutatorLocks,
                                                audibility: audibility, groups: mutatorPanel.groupWeights,
                                                using: &generator)[0],
                            mother: base)
        }, parents: [base], origin: .randomize)
    }

    /// `Interpolate` — sześcioro dzieci po drodze z Mother do Father.
    public func mutatorInterpolate(_ first: G2MutatorBox? = nil, _ second: G2MutatorBox? = nil) {
        mutatorInterpolate(first.flatMap { mutatorIndividual(at: $0) }, second.flatMap { mutatorIndividual(at: $0) })
    }

    /// ⇧-przeciągnięcie kratki drzewa na kratkę okna: dźwięk z drzewa jako Mother.
    public func mutatorInterpolate(node: G2MutatorTree.NodeID, with box: G2MutatorBox) {
        guard mutatorTree.contains(node) else { return }
        mutatorInterpolate(mutatorTree.sound(of: node), mutatorIndividual(at: box))
    }

    private func mutatorInterpolate(_ first: G2Individual?, _ second: G2Individual?) {
        beginMutatorEdit("Interpolate")
        guard placeParents(first, second),
              let mother = mutatorParents[G2Mutator.motherIndex],
              let father = mutatorParents[G2Mutator.fatherIndex] else { return }
        finishBreeding(mutatorAnchoring().apply(G2Mutator.interpolate(mother: mother, father: father,
                                                                      genome: mutatorGenome),
                                                mother: mother),
                       parents: [mother, father], origin: .interpolate)
    }

    /// `Cross` — sześcioro dzieci ze skrzyżowania Mother i Father.
    public func mutatorCross(_ first: G2MutatorBox? = nil, _ second: G2MutatorBox? = nil) {
        mutatorCross(first.flatMap { mutatorIndividual(at: $0) }, second.flatMap { mutatorIndividual(at: $0) })
    }

    /// ⌥-przeciągnięcie kratki drzewa na kratkę okna: dźwięk z drzewa jako Mother.
    public func mutatorCross(node: G2MutatorTree.NodeID, with box: G2MutatorBox) {
        guard mutatorTree.contains(node) else { return }
        mutatorCross(mutatorTree.sound(of: node), mutatorIndividual(at: box))
    }

    private func mutatorCross(_ first: G2Individual?, _ second: G2Individual?) {
        beginMutatorEdit("Cross")
        guard placeParents(first, second),
              let mother = mutatorParents[G2Mutator.motherIndex],
              let father = mutatorParents[G2Mutator.fatherIndex] else { return }
        var generator = SystemRandomNumberGenerator()
        let anchoring = mutatorAnchoring()
        let children = pooled(.cross, parents: [mother, father], audibility: nil) {
            anchoring.apply(G2Mutator.cross(mother: mother, father: father, genome: mutatorGenome,
                                            settings: mutatorSettings, using: &generator),
                            mother: mother)
        }
        finishBreeding(keepAudible(children, parents: [mother, father]) {
            anchoring.apply(G2Mutator.cross(mother: mother, father: father, genome: mutatorGenome,
                                            settings: mutatorSettings, using: &generator)[0],
                            mother: mother)
        }, parents: [mother, father], origin: .cross)
    }

    /// „Anchors" z panelu dla bieżącego patcha — przy zwiniętym panelu nic nie poprawiają.
    func mutatorAnchoring() -> G2MutatorAnchoring {
        G2MutatorAnchoring(patch: patch, genome: mutatorGenome, anchors: mutatorPanel.anchors)
    }

    /// Mapa słyszalności dla „Only audible" — `nil`, gdy ustawienie nie obowiązuje.
    /// `Active` bierzemy z rodzica, bo to jego dzieci powstają.
    func mutatorAudibility(of parent: G2Individual) -> G2AudibilityMap? {
        mutatorPanel.onlyAudible ? G2AudibilityMap(patch: patch, sound: parent) : nil
    }

    /// „Pool & Diversity": zamiast sześciorga dzieci losujemy całą pulę (`batch` daje po
    /// sześcioro) i zostawiamy sześcioro najbardziej różnych od rodziców i od siebie.
    /// Przy „Not silent" ciche odpadają przed wyborem, jeśli zostaje ich dość — wtedy
    /// sześcioro najbardziej różnych nie jest przypadkiem sześciorgiem głuchych.
    func pooled(_ operation: G2MutatorPanelSettings.PoolOperation, parents: [G2Individual],
                audibility: G2AudibilityMap?, batch: () -> [G2Individual]) -> [G2Individual]
    {
        guard let size = mutatorPanel.pool(for: operation) else { return batch() }
        var pool: [G2Individual] = []
        while pool.count < size {
            pool += batch()
        }
        pool.removeLast(pool.count - size)
        if mutatorSettings.notSilent {
            let silence = silenceGuard()
            let loud = pool.filter { !silence.isSilent($0) }
            if parents.contains(where: { !silence.isSilent($0) }), loud.count >= G2Mutator.childCount {
                pool = loud
            }
        }
        return G2EngineSpace(patch: patch, genome: mutatorGenome)
            .mostDifferent(G2Mutator.childCount, from: pool, parents: parents, audibility: audibility)
    }

    public var mutatorHasBothParents: Bool {
        mutatorParents[G2Mutator.motherIndex] != nil && mutatorParents[G2Mutator.fatherIndex] != nil
    }

    private func placeParents(_ first: G2Individual?, _ second: G2Individual?) -> Bool {
        if let first { mutatorParents[G2Mutator.motherIndex] = first }
        if let second { mutatorParents[G2Mutator.fatherIndex] = second }
        return mutatorHasBothParents
    }

    /// Przycisk „Not silent": ciche dziecko losujemy od nowa, najwyżej `silentRetries` razy
    /// (potem zostaje ostatnie — lepiej ciche dziecko niż zawieszony przycisk). Działa tylko,
    /// gdy któryś rodzic gra wg `G2SilenceGuard`; Interpolate nie ma czego losować.
    func keepAudible(_ children: [G2Individual], parents: [G2Individual],
                     retry: () -> G2Individual) -> [G2Individual]
    {
        guard mutatorSettings.notSilent else { return children }
        let silence = silenceGuard()
        guard parents.contains(where: { !silence.isSilent($0) }) else { return children }
        return children.map { child in
            var candidate = child
            var attempts = 0
            while silence.isSilent(candidate), attempts < Self.silentRetries {
                candidate = retry()
                attempts += 1
            }
            return candidate
        }
    }

    static let silentRetries = 24

    /// Strażnik ciszy z progiem spod gałki „Not silent sensitivity".
    func silenceGuard() -> G2SilenceGuard {
        G2SilenceGuard(patch: patch,
                       strictness: .init(sensitivity: mutatorSettings.silenceSensitivity))
    }

    /// Wspólny ogon każdej operacji: dzieci na miejsca, do drzewa ewolucji pod rodziców
    /// (rodzic, którego drzewo jeszcze nie zna, zostaje korzeniem), focus na pierwsze
    /// i od razu je słychać — tak samo kończy każda `Get…ChildrenMolecules` oryginału
    /// (`GetFocusIndividMolecules(…, {0, 0})`).
    private func finishBreeding(_ children: [G2Individual], parents: [G2Individual],
                                origin: G2MutatorTree.Origin)
    {
        for (index, child) in children.enumerated() where index < G2Mutator.childCount {
            mutatorParents[index] = child
        }
        mutatorParentCount = parents.count
        recordBreeding(children, parents: parents, origin: origin)
        mutatorSetFocus(.child(0))
    }

    /// Dopisuje hodowlę do drzewa ewolucji.
    private func recordBreeding(_ children: [G2Individual], parents: [G2Individual],
                                origin: G2MutatorTree.Origin)
    {
        let ids = parents.map { mutatorTree.root($0) }
        mutatorTree.breed(children, parents: ids, origin: origin)
    }

    /// Kopiuje dźwięk na miejsce rodzica — klawisze `O` (Mother) i `T` (Father).
    public func mutatorCopyToParent(_ source: G2MutatorBox, mother: Bool) {
        guard let individual = mutatorIndividual(at: source) else { return }
        beginMutatorEdit(mother ? "Copy To Mother" : "Copy To Father")
        mutatorParents[mother ? G2Mutator.motherIndex : G2Mutator.fatherIndex] = individual
    }

    // MARK: Amount axis

    /// Droga fadera Amount; `nil`, dopóki fader nie ruszył. Cel losuje się raz — fader
    /// już nie losuje, tylko przesuwa się po tej samej drodze.
    public private(set) var mutatorAxis: G2MutationAxis?
    /// Położenie fadera, 0…1.
    public private(set) var mutatorAxisAmount = 0.0

    /// Co ile najwyżej dźwięk spod fadera idzie do Norda — ruch myszy jest dużo gęstszy.
    static let axisSendInterval: Duration = .milliseconds(40)
    @ObservationIgnored private var axisFlushPending = false
    /// Czy bieżący gest fadera zapisał już swój krok undo.
    @ObservationIgnored private var axisGestureUndone = false

    /// W trybie Focus: czy jest kratka, do której można jechać (inna niż Mother).
    public var mutatorAxisHasTarget: Bool {
        mutatorPanel.axisTarget != .focus || focusTarget() != nil
    }

    /// Ruch fadera. Model i napis zmieniają się od razu, dźwięk dogania co `axisSendInterval`.
    public func mutatorAxisSetAmount(_ amount: Double) {
        mutatorAxisAmount = min(1, max(0, amount))
        guard !axisFlushPending else { return }
        axisFlushPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.axisSendInterval)
            self?.mutatorAxisFlush()
        }
    }

    /// Koniec gestu: ostatnie położenie słychać od razu, następny gest to nowy krok undo.
    public func mutatorAxisEndGesture() {
        mutatorAxisFlush()
        axisGestureUndone = false
    }

    /// „New target" — nowy cel, fader zostaje, gdzie był.
    public func mutatorAxisNewTarget() {
        mutatorAxis = nil
        mutatorAxisFlush()
        axisGestureUndone = false
    }

    /// „Latch" — dźwięk spod fadera zostaje nową Mother, fader wraca na 0 %, cel ten sam.
    public func mutatorAxisLatch() {
        guard let axis = mutatorAxis, mutatorAxisAmount > 0 else { return }
        let point = axis.point(at: mutatorAxisAmount, genome: mutatorGenome, anchoring: mutatorAnchoring())
        beginMutatorEdit("Latch")
        recordBreeding([point], parents: [axis.origin], origin: .amount)
        mutatorParents[G2Mutator.motherIndex] = point
        mutatorAxis = G2MutationAxis(origin: point, target: axis.target, kind: axis.kind)
        mutatorAxisAmount = 0
    }

    /// „Store" — dźwięk spod fadera do pierwszej wolnej kratki magazynu.
    public func mutatorAxisStore() {
        guard let axis = mutatorAxis, mutatorAxisAmount > 0,
              let free = mutatorStorage.firstIndex(where: { $0 == nil }) else { return }
        beginMutatorEdit("Store Sound")
        let point = axis.point(at: mutatorAxisAmount, genome: mutatorGenome, anchoring: mutatorAnchoring())
        recordBreeding([point], parents: [axis.origin], origin: .amount)
        mutatorStorage[free] = point
    }

    /// Przykłada dźwięk z bieżącego położenia fadera do bufora odsłuchu.
    func mutatorAxisFlush() {
        axisFlushPending = false
        guard let axis = preparedAxis() else { return }
        let point = axis.point(at: mutatorAxisAmount, genome: mutatorGenome, anchoring: mutatorAnchoring())
        audition(point, registerUndo: !axisGestureUndone)
        axisGestureUndone = true
    }

    /// Oś dla obecnej Mother i obecnego trybu celu — stara, jeśli dalej pasuje, inaczej nowa.
    private func preparedAxis() -> G2MutationAxis? {
        if mutatorParents[G2Mutator.motherIndex] == nil {
            beginMutatorEdit("Amount")
            mutatorParents[G2Mutator.motherIndex] = currentIndividual()
        }
        guard let mother = mutatorParents[G2Mutator.motherIndex] else { return nil }
        let kind = mutatorPanel.axisTarget
        let smooth = mutatorPanel.smoothAxis
        if kind == .focus {
            guard let picked = focusTarget() else { return nil }
            let target = smooth.hold(picked, at: mother, genome: mutatorGenome)
            if mutatorAxis?.origin != mother || mutatorAxis?.target != target
                || mutatorAxis?.kind != kind || mutatorAxis?.smooth != smooth
            {
                mutatorAxis = G2MutationAxis(origin: mother, target: target, kind: kind, smooth: smooth)
            }
            return mutatorAxis
        }
        if let axis = mutatorAxis, axis.origin == mother, axis.kind == kind, axis.smooth == smooth {
            return axis
        }
        var generator = SystemRandomNumberGenerator()
        let audibility = mutatorAudibility(of: mother)
        let target = kind == .random
            ? G2Mutator.randomize(base: mother, genome: mutatorGenome, locks: mutatorLocks, audibility: audibility,
                                  groups: mutatorPanel.groupWeights, using: &generator)[0]
            : G2Mutator.mutateOnce(parent: mother, genome: mutatorGenome, settings: mutatorSettings,
                                   locks: mutatorLocks, audibility: audibility, groups: mutatorPanel.groupWeights,
                                   using: &generator)
        mutatorAxis = G2MutationAxis(origin: mother, target: smooth.hold(target, at: mother,
                                                                         genome: mutatorGenome),
                                     kind: kind, smooth: smooth)
        return mutatorAxis
    }

    private func focusTarget() -> G2Individual? {
        guard let focus = mutatorFocus, focus != .mother else { return nil }
        return mutatorIndividual(at: focus)
    }

    // MARK: Family → Variations

    /// Rząd magazynu, do którego pójdzie rodzina — pierwszy całkiem pusty; `nil`, gdy
    /// każdy ma coś w środku (wtedy najpierw „x").
    public var mutatorFamilyRow: Int? {
        (0 ..< G2Mutator.storageCount / G2VariationFamily.count).first { row in
            (0 ..< G2VariationFamily.count).allSatisfy { mutatorStorage[row * G2VariationFamily.count + $0] == nil }
        }
    }

    /// „Make family" — osiem dźwięków od Mother do celu fadera Amount w pustym rzędzie
    /// magazynu. Do V1–V8 idą dopiero przyciskiem `v` przy rzędzie (reguła 2 w
    /// Docs/mutator/plan-ui): same wariacje, Init i bufor odsłuchu nic o tym nie wiedzą.
    ///
    /// Pierwsza rodzina jedzie po drodze, którą właśnie słychać pod faderem; potem cel
    /// jest zużyty — następne kliknięcie (i następny ruch fadera) losuje nowy, inaczej
    /// trzy kliknięcia dałyby trzy takie same rzędy. W trybie Focus cel to kratka, więc
    /// rodzina jest z natury powtarzalna.
    public func mutatorMakeFamily() {
        guard let row = mutatorFamilyRow, let axis = preparedAxis() else { return }
        let space = G2EngineSpace(patch: patch, genome: mutatorGenome)
        let audibility = mutatorAudibility(of: axis.origin)
        let sounds = G2VariationFamily.sounds(axis: axis, spacing: mutatorPanel.familySpacing,
                                              genome: mutatorGenome, anchoring: mutatorAnchoring())
        { space.distance($0, $1, audibility: audibility) }
        beginMutatorEdit("Make Family")
        recordBreeding(sounds, parents: [axis.origin], origin: .family)
        for (column, sound) in sounds.enumerated() {
            mutatorStorage[row * G2VariationFamily.count + column] = sound
        }
        if axis.kind != .focus { mutatorAxis = nil }
    }

    // MARK: Compare (A/B)

    /// Strona porównania A/B: A to Mother (albo Father), B kratka wybrana ⌘-klikiem.
    public enum CompareSide: Sendable {
        case a, b
    }

    private var compareBox: G2MutatorBox?
    /// Przełącznik „A = Father" z panelu; liczy się tylko, gdy Father ma dźwięk.
    public var mutatorCompareAgainstFather = false

    /// Kratka „A": Mother, albo Father, gdy tak ustawiono i Father nie jest pusty.
    public var mutatorCompareA: G2MutatorBox {
        mutatorCompareAgainstFather && mutatorHasData(at: .father) ? .father : .mother
    }

    /// Kratka „B". Zostaje, gdy zwykłe kliknięcia wędrują po innych kratkach; znika, gdy
    /// kratka opustoszeje (Delete, przeniesienie, „x", undo) albo stanie się stroną A.
    public var mutatorCompare: G2MutatorBox? {
        guard let box = compareBox, box != mutatorCompareA, mutatorHasData(at: box) else { return nil }
        return box
    }

    /// Co gra w tej chwili: A, B albo `nil`, gdy słychać coś innego.
    public var mutatorComparePlaying: CompareSide? {
        guard let compare = mutatorCompare else { return nil }
        if mutatorFocus == compare { return .b }
        return mutatorFocus == mutatorCompareA ? .a : nil
    }

    /// ⌘-klik w kratkę: zostaje „B" i od razu ją słychać. Pusta Mother bierze bieżący
    /// dźwięk, żeby „A" zawsze było czym grać.
    public func mutatorSetCompare(_ box: G2MutatorBox) {
        guard box != .mother, mutatorHasData(at: box) else { return }
        if mutatorParents[G2Mutator.motherIndex] == nil {
            beginMutatorEdit("Compare")
            mutatorParents[G2Mutator.motherIndex] = currentIndividual()
        }
        compareBox = box
        mutatorSetFocus(box)
    }

    /// Przyciski A / B w panelu.
    public func mutatorComparePlay(_ side: CompareSide) {
        guard let compare = mutatorCompare else { return }
        mutatorSetFocus(side == .a ? mutatorCompareA : compare)
    }

    /// Przycisk A: gra stronę A, a gdy Father ma dźwięk, najpierw przełącza A na drugiego
    /// rodzica — klikanie w kółko daje Mother, Father, Mother…
    public func mutatorCompareSwitchA() {
        guard mutatorCompare != nil else { return }
        if mutatorHasData(at: .father) { mutatorCompareAgainstFather.toggle() }
        mutatorComparePlay(.a)
    }

    /// Spacja: druga strona niż ta, która gra; gdy gra coś innego — najpierw B.
    public func mutatorCompareToggle() {
        guard mutatorCompare != nil else { return }
        mutatorComparePlay(mutatorComparePlaying == .b ? .a : .b)
    }

    // MARK: Tree

    /// Węzeł drzewa, który gra spoza kratek okna (klik w drzewo); kratka z focusem
    /// ma pierwszeństwo, więc gaśnie przy każdej zmianie focusu.
    private var treePlayingNode: G2MutatorTree.NodeID?

    /// Który węzeł drzewa słychać: dźwięk kratki z focusem, a bez focusu — węzeł
    /// kliknięty w drzewie. `nil`, gdy gra coś, czego drzewo nie zna (fader w pół drogi).
    public var mutatorTreePlaying: G2MutatorTree.NodeID? {
        if let focus = mutatorFocus {
            return mutatorIndividual(at: focus).flatMap { mutatorTree.node(of: $0) }
        }
        return treePlayingNode
    }

    /// Kierunek ⌥ + strzałki: chodzenie po drzewie uchem.
    public enum TreeStep: Sendable {
        case up, down, left, right
    }

    /// Klik w kratkę drzewa. Gdy dźwięk siedzi w którejś kratce okna, to ona dostaje
    /// focus (żeby siatka pokazywała to samo); inaczej gra wprost z drzewa, a siatka
    /// nie świeci niczym.
    public func mutatorPlay(node: G2MutatorTree.NodeID) {
        guard mutatorTree.contains(node) else { return }
        if let box = mutatorBoxes(of: node).first {
            mutatorSetFocus(box)
            return
        }
        mutatorFocus = nil
        treePlayingNode = node
        audition(mutatorTree.sound(of: node))
    }

    /// ⌥↑ rodzic, ⌥↓ pierwsze dziecko najnowszej miotki, ⌥←/→ rodzeństwo.
    public func mutatorTreeStep(_ step: TreeStep) {
        guard let current = mutatorTreePlaying ?? mutatorTree.roots.last else { return }
        let target: G2MutatorTree.NodeID?
        switch step {
        case .up: target = mutatorTree.parent(of: current)
        case .down: target = mutatorTree.latestChild(of: current)
        case .left, .right:
            let siblings = mutatorTree.siblings(of: current)
            guard let index = siblings.firstIndex(of: current) else { return }
            let next = index + (step == .right ? 1 : -1)
            target = siblings.indices.contains(next) ? siblings[next] : nil
        }
        if let target { mutatorPlay(node: target) }
    }

    /// Dźwięk z drzewa do kratki okna: Mother, Father, magazyn albo wariacja (jak
    /// przeciągnięcie kratki na kratkę, ale z drzewa zawsze kopiuje).
    public func mutatorCopy(node: G2MutatorTree.NodeID, to box: G2MutatorBox) {
        guard mutatorTree.contains(node) else { return }
        let sound = mutatorTree.sound(of: node)
        if box.kind == .variations {
            guard box.index < 8 else { return }
            beginMutatorEdit("Copy To Variation")
            writeIndividualToVariation(sound, variation: box.index)
            return
        }
        beginMutatorEdit("Copy Sound")
        setBox(box, to: sound)
    }

    /// Menu kratki drzewa: do pierwszej wolnej kratki magazynu.
    public func mutatorStore(node: G2MutatorTree.NodeID) {
        guard let free = mutatorStorage.firstIndex(where: { $0 == nil }) else { return }
        mutatorCopy(node: node, to: G2MutatorBox(.storage, free))
    }

    /// Kratki okna, w których siedzi dźwięk węzła — znaczki `M`, `F`, `1`…`6`, `S`
    /// na kratkach drzewa. Wariacji nie sprawdzamy: drzewo trzyma ułamki, patch bajty.
    public func mutatorBoxes(of node: G2MutatorTree.NodeID) -> [G2MutatorBox] {
        guard mutatorTree.contains(node) else { return [] }
        var boxes: [G2MutatorBox] = []
        for index in mutatorParents.indices where mutatorParents[index].map({ mutatorTree.node(of: $0) }) == node {
            boxes.append(G2MutatorBox(.parents, index))
        }
        for index in mutatorStorage.indices where mutatorStorage[index].map({ mutatorTree.node(of: $0) }) == node {
            boxes.append(G2MutatorBox(.storage, index))
        }
        return boxes
    }

    // MARK: Focus

    /// Klik w kratkę. Kratka wariacji przełącza wariację patcha (jak przycisk
    /// wariacji na Nordzie); każda inna trafia do **bufora mutatora** i od razu ją
    /// słychać — żadna z ośmiu zapisanych wariacji się przy tym nie rusza.
    public func mutatorSetFocus(_ box: G2MutatorBox?) {
        treePlayingNode = nil
        guard let box else {
            mutatorFocus = nil
            return
        }
        if box.kind == .variations {
            mutatorFocus = box
            selectVariation(box.index)
            return
        }
        guard let individual = mutatorIndividual(at: box) else { return }
        mutatorFocus = box
        audition(individual)
    }

    /// Kratka zapalona w oknie mutatora. Dopóki nikt w nie nie kliknął, gra ta wariacja,
    /// którą pokazuje górny pasek — świeżo otwarte okno ma więc zapaloną tę samą kratkę
    /// co belka, bez czekania na pierwsze przełączenie wariacji.
    public var mutatorHighlight: G2MutatorBox? {
        if let mutatorFocus { return mutatorFocus }
        let variation = patch.activeVariation
        return (0 ... 7).contains(variation) ? G2MutatorBox(.variations, variation) : nil
    }

    /// Czy patch gra w tej chwili z bufora mutatora — wtedy żaden przycisk wariacji
    /// nie jest zapalony, tak samo jak w oryginale.
    public var isAuditioningMutation: Bool {
        patch.activeVariation == G2Patch.mutatorVariation
    }

    /// Wkłada dźwięk do **dziesiątego zestawu parametrów** (`G2Patch.mutatorVariation`)
    /// i przełącza na niego patch. Tak robi oryginał: `GetFocusIndividMolecules` zrzuca
    /// wartości do zestawu 9 i wysyła Param Setting Focus(9), czyli `0x6A` z numerem 9
    /// — dlatego przesłuchiwanie dzieci nie niszczy ośmiu zapisanych wariacji, a Init
    /// (zestaw 8) zostaje Initem.
    ///
    /// Bufor nie idzie do pliku: zapis wysyła dziewięć zestawów, a numer aktywnej
    /// wariacji przycina do 0…7.
    ///
    /// Fader „Amount axis" woła to wiele razy w jednym geście: undo zapisuje tylko
    /// pierwszy krok.
    func audition(_ individual: G2Individual, registerUndo: Bool = true) {
        let slot = selectedSlot
        guard slots.indices.contains(slot) else { return }
        let buffer = G2Patch.mutatorVariation
        let previousVariation = slots[slot].description.variation
        let previousSound = G2Mutator.individual(from: slots[slot], variation: buffer,
                                                 genome: mutatorGenome)

        slots[slot].apply(individual, variation: buffer)
        slots[slot].setActiveVariation(buffer)

        if registerUndo {
            undoManager.registerUndo(withTarget: self) { target in
                target.restoreAudition(previousSound, variation: previousVariation, slot: slot)
            }
            undoManager.setActionName("Mutator")
        }

        sendMutatorBuffer(slot: slot, variation: buffer)
    }

    private func restoreAudition(_ sound: G2Individual, variation: Int, slot: Int) {
        guard slots.indices.contains(slot) else { return }
        let buffer = G2Patch.mutatorVariation
        let redoSound = G2Mutator.individual(from: slots[slot], variation: buffer,
                                             genome: mutatorGenome)
        let redoVariation = slots[slot].description.variation
        slots[slot].apply(sound, variation: buffer)
        slots[slot].setActiveVariation(variation)
        if variation != buffer { mutatorFocus = nil }
        treePlayingNode = nil
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreAudition(redoSound, variation: redoVariation, slot: slot)
        }
        undoManager.setActionName("Mutator")
        sendMutatorBuffer(slot: slot, variation: variation)
    }

    /// Bufor odsłuchu do urządzenia — **zawsze w całości, jedną paczką**, jak molekuła
    /// Muta Param Dump oryginału: wartości obu obszarów, ustawienia patcha i mapa
    /// morfów zestawu 9, a po nich `0x6A` z jego numerem.
    ///
    /// Do 2026-09-22 szło to parametr po parametrze: pierwsze przesłuchanie wysyłało
    /// kilkaset komend `0x40`, a każde następne **tylko różnice** — więc jedna zgubiona
    /// ramka zostawała rozbieżnością do końca sesji (zgłoszenie „Mother brzmi inaczej
    /// niż ta sama wariacja") → [[Docs/usb/mutator-dump]], [[Docs/context/bug-history]] #109.
    /// Zrzut naprawia się sam: każde przesłuchanie niesie komplet.
    ///
    /// Gdy mostu przesłuchania nikt nie podłączył (testy, brak urządzenia), zostaje samo
    /// przełączenie zestawu — tak samo jak przy kliknięciu w kratkę wariacji.
    private func sendMutatorBuffer(slot: Int, variation: Int) {
        if let onMutatorAudition {
            onMutatorAudition(slot, slots[slot], variation)
        } else {
            onVariationChange?(slot, variation)
        }
    }

    /// Wartości bieżącej wariacji jako osobnik — punkt wyjścia, gdy Mother jest pusta.
    public func currentIndividual() -> G2Individual {
        G2Mutator.individual(from: patch, variation: patch.activeVariation, genome: mutatorGenome)
    }

    // MARK: Przenoszenie między kratkami

    /// Przeciągnięcie kratki na kratkę. W magazynie tymczasowym dźwięk się
    /// PRZENOSI, wszędzie indziej KOPIUJE — jak Muta Background dialog (EndDrag).
    public func mutatorDrag(from source: G2MutatorBox, to destination: G2MutatorBox) {
        guard source != destination, let individual = mutatorIndividual(at: source) else { return }
        if destination.kind == .variations {
            guard destination.index < 8 else { return }
            beginMutatorEdit("Copy To Variation")
            writeIndividualToVariation(individual, variation: destination.index)
            return
        }
        beginMutatorEdit("Move Sound")
        setBox(destination, to: individual)
        if source.kind == .storage, destination.kind == .storage {
            setBox(source, to: nil)
        }
    }

    /// Kratka → pierwsza wolna kratka magazynu (klawisz `S`).
    public func mutatorStore(_ source: G2MutatorBox) {
        guard let individual = mutatorIndividual(at: source),
              let free = mutatorStorage.firstIndex(where: { $0 == nil }) else { return }
        beginMutatorEdit("Store Sound")
        mutatorStorage[free] = individual
    }

    public func mutatorDelete(_ box: G2MutatorBox) {
        guard box.kind != .variations else { return }
        beginMutatorEdit("Delete Sound")
        setBox(box, to: nil)
    }

    /// Przycisk „x" z prawej strony rzędu magazynu.
    public func mutatorClearStorageRow(_ row: Int) {
        beginMutatorEdit("Clear Row")
        for column in 0 ..< 8 {
            let index = row * 8 + column
            if mutatorStorage.indices.contains(index) { mutatorStorage[index] = nil }
        }
    }

    /// Przycisk „v" z prawej strony rzędu magazynu — rząd ląduje w ośmiu wariacjach.
    public func mutatorCopyStorageRowToVariations(_ row: Int) {
        let slot = selectedSlot
        guard slots.indices.contains(slot) else { return }
        let before = slots[slot]
        var written: [Int] = []
        for column in 0 ..< 8 {
            let index = row * 8 + column
            guard mutatorStorage.indices.contains(index),
                  let individual = mutatorStorage[index] else { continue }
            slots[slot].apply(individual, variation: column)
            written.append(column)
        }
        guard !written.isEmpty else { return }
        slots[slot].syncParametersToActiveVariation()
        registerVariationsUndo(before, slot: slot, variations: written)
        undoManager.setActionName("Copy Row To Variations")
        onVariationDump?(slot, slots[slot], written)
    }

    func writeIndividualToVariation(_ individual: G2Individual, variation: Int) {
        let slot = selectedSlot
        guard slots.indices.contains(slot) else { return }
        let before = slots[slot]
        slots[slot].apply(individual, variation: variation)
        slots[slot].syncParametersToActiveVariation()
        registerVariationsUndo(before, slot: slot, variations: [variation])
        undoManager.setActionName("Copy To Variation")
        onVariationDump?(slot, slots[slot], [variation])
    }

    /// Cofnięcie zapisu do wariacji: patch wraca ze zdjęcia, a urządzenie dostaje dawne
    /// wartości tych samych zestawów — `restorePatch` wysłałby tylko różnicę struktury,
    /// czyli nic. Grająca wariacja zostaje ta sama — zapis jej nie przełączał, a do
    /// urządzenia idą same wartości (#135).
    private func registerVariationsUndo(_ snapshot: G2Patch, slot: Int, variations: [Int]) {
        undoManager.registerUndo(withTarget: self) { target in
            guard target.slots.indices.contains(slot) else { return }
            let current = target.slots[slot]
            var restored = snapshot
            restored.setActiveVariation(current.activeVariation)
            target.slots[slot] = restored
            target.registerVariationsUndo(current, slot: slot, variations: variations)
            target.onVariationDump?(slot, restored, variations)
        }
    }

    private func setBox(_ box: G2MutatorBox, to individual: G2Individual?) {
        switch box.kind {
        case .parents:
            if mutatorParents.indices.contains(box.index) { mutatorParents[box.index] = individual }
        case .storage:
            if mutatorStorage.indices.contains(box.index) { mutatorStorage[box.index] = individual }
        case .variations:
            break
        }
    }

    // MARK: Wyłączanie modułów z mutacji

    /// `Exclude From Mutations` z menu pod prawym przyciskiem na module.
    public func setModulesExcludedFromMutation(_ ids: Set<Int>, excluded: Bool) {
        let slot = selectedSlot
        guard slots.indices.contains(slot), !ids.isEmpty else { return }
        let before = slots[slot]
        for index in slots[slot].voiceModules.indices where ids.contains(slots[slot].voiceModules[index].id) {
            slots[slot].voiceModules[index].excludedFromMutation = excluded
        }
        for index in slots[slot].fxModules.indices where ids.contains(slots[slot].fxModules[index].id) {
            slots[slot].fxModules[index].excludedFromMutation = excluded
        }
        undoManager.registerUndo(withTarget: self) { target in
            target.restorePatch(before, slot: slot)
        }
        undoManager.setActionName("Exclude From Mutations")
    }

    public func isModuleExcludedFromMutation(_ id: Int) -> Bool {
        patch.voiceModules.first { $0.id == id }?.excludedFromMutation
            ?? patch.fxModules.first { $0.id == id }?.excludedFromMutation
            ?? false
    }

    // MARK: Undo zawartości kratek

    /// Kratki mutatora są stanem sesji, nie patcha — cofamy je własnym zapisem.
    private func beginMutatorEdit(_ name: String) {
        let parents = mutatorParents
        let storage = mutatorStorage
        let focus = mutatorFocus
        let parentCount = mutatorParentCount
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreMutatorBoxes(parents: parents, storage: storage,
                                       focus: focus, parentCount: parentCount, name: name)
        }
        undoManager.setActionName(name)
    }

    private func restoreMutatorBoxes(parents: [G2Individual?], storage: [G2Individual?],
                                     focus: G2MutatorBox?, parentCount: Int, name: String)
    {
        beginMutatorEdit(name)
        mutatorParents = parents
        mutatorStorage = storage
        mutatorFocus = focus
        mutatorParentCount = parentCount
    }

    /// Wczytanie innego patcha unieważnia hodowlę — dotyczyła tamtych modułów.
    public func clearMutations() {
        mutatorParents = Array(repeating: nil, count: G2Mutator.parentBoxCount)
        mutatorStorage = Array(repeating: nil, count: G2Mutator.storageCount)
        mutatorFocus = nil
        treePlayingNode = nil
        mutatorTree = G2MutatorTree()
        compareBox = nil
        mutatorCompareAgainstFather = false
        mutatorParentCount = 1
        mutatorAxis = nil
        mutatorAxisAmount = 0
        cachedGenome = nil
    }

    // MARK: - Strony parametrów (gałki panelu)

    /// Strona parametrów „z focusem" — ta, na którą trafia ⌘-klik gałki w patchu
    /// i którą pokazuje panel stron. Oryginał trzyma to samo pojedynczo
    /// (`CParameterPages::SetFocusedParameterPage`, 15 stron = 5 grup × 3).
    ///
    /// Wybór strony jest **dwustronny**: idzie do Norda (`0x2D`/`0x1E`), żeby osiem gałek
    /// panelu sterowało tym samym, co osiem gałek okna, i wraca stamtąd, gdy stronę
    /// wybierze się przyciskiem na froncie → [[Docs/ui/parameter-pages]].
    ///
    /// Strony są **dwie i niezależne** — tak jak u Clavii, gdzie własne `CParameterPages`
    /// ma `CPatch` i osobne `CPerformance`. Widoczna jest ta, którą wskazuje
    /// `showsGlobalParameterPages`; druga czeka nietknięta na powrót.
    public var focusedParameterPage: Int {
        get { showsGlobalParameterPages ? storedGlobalParameterPage : storedParameterPage }
        set {
            if showsGlobalParameterPages {
                guard storedGlobalParameterPage != newValue else { return }
                storedGlobalParameterPage = newValue
            } else {
                guard storedParameterPage != newValue else { return }
                storedParameterPage = newValue
            }
            notifyParameterPage()
        }
    }

    /// Strona patcha i strona performance'u. Przypisanie z `didSet` wracałoby pod makrem
    /// `@Observable` do tego samego settera, stąd magazyn obok akcesora — ten sam układ
    /// co przy `performanceName`.
    private var storedParameterPage = 0
    private var storedGlobalParameterPage = 0

    /// Strona patcha — także wtedy, gdy na ekranie są Global Pages. Według niej wtyczka DAW-a
    /// liczy „gałki bieżącej strony" (`PluginAutomation`).
    public var patchParameterPage: Int {
        storedParameterPage
    }

    /// `Global Pages` przełącza zestaw 0x62 bieżącego patcha na wspólną mapę 0x5F
    /// performance'u. Dla pojedynczego patcha globalna mapa jest pusta, ale sam
    /// przełącznik nadal zachowuje się jak w oryginalnym oknie.
    ///
    /// U Clavii to pole nagłówka performance'u (Performance Header Param z indeksem 2),
    /// więc przełącznik też jedzie do urządzenia i wraca z niego — a że nagłówek trafia
    /// do pliku, **`.prf2` pamięta wciśnięty przycisk** i przywraca go po otwarciu.
    /// Dlatego stanem jest tu wprost pole performance'u, a nie osobna kopia w oknie.
    public var showsGlobalParameterPages: Bool {
        get { performance.globalPagesEnabled }
        set {
            guard performance.globalPagesEnabled != newValue else { return }
            performance.globalPagesEnabled = newValue
            guard !applyingDeviceParameterPage else { return }
            onGlobalParameterPagesChange?(newValue)
        }
    }

    /// Zmiana strony parametrów zrobiona W EDYTORZE — `global` mówi, czy dotyczy stron
    /// performance'u (`0x1E`), czy stron slotu (`0x2D`).
    public var onParameterPageChange: ((_ slot: Int, _ page: Int, _ global: Bool) -> Void)?
    /// Przełącznik `Global Pages` przestawiony w edytorze.
    public var onGlobalParameterPagesChange: ((Bool) -> Void)?

    /// Trwa przepisywanie stanu Z URZĄDZENIA — wtedy nic nie wraca do Norda, bo to on
    /// jest źródłem tej zmiany. Bez tego jedno naciśnięcie przycisku na froncie odbijało
    /// się z powrotem tą samą komendą.
    private var applyingDeviceParameterPage = false

    private func notifyParameterPage() {
        guard !applyingDeviceParameterPage else { return }
        onParameterPageChange?(selectedSlot, focusedParameterPage, showsGlobalParameterPages)
    }

    /// Strona parametrów wybrana NA PANELU Norda. Urządzenie trzyma osobno stronę slotu
    /// i stronę performance'u — i my tak samo, więc każdy z dwóch odczytów ląduje na
    /// swoim miejscu niezależnie od tego, który jest akurat widoczny. Strona slotu liczy
    /// się tylko dla slotu na ekranie: pozostałe trzy mają w oknie własne, nieoglądane strony.
    public func applyDeviceParameterPage(_ page: Int, slot: Int?, global: Bool) {
        guard (0 ..< G2KnobPages.pageCount).contains(page) else { return }
        if global {
            storedGlobalParameterPage = page
        } else if slot == selectedSlot {
            storedParameterPage = page
        }
    }

    /// Przełącznik `Global Pages` przestawiony na urządzeniu.
    public func applyDeviceGlobalParameterPages(_ enabled: Bool) {
        withoutParameterPageEcho { showsGlobalParameterPages = enabled }
    }

    /// Zmiana stanu stron parametrów, która **nie ma wracać do Norda** — bo to on ją
    /// zgłosił, albo bo cała zawartość edytora właśnie została z niego przepisana.
    func withoutParameterPageEcho(_ body: () -> Void) {
        let previous = applyingDeviceParameterPage
        applyingDeviceParameterPage = true
        defer { applyingDeviceParameterPage = previous }
        body()
    }

    /// Zmiana przypisania gałki panelu — `nil` znaczy „zwolniona".
    public var onKnobAssignmentChange: ((_ slot: Int, _ knob: Int,
                                         _ assignment: G2KnobAssignment?) -> Void)?

    /// Called after one MIDI CC assignment changes. A nil assignment means deassignment.
    public var onMidiControllerAssignmentChange: ((_ slot: Int, _ cc: Int,
                                                   _ assignment: G2MidiControllerAssignment?) -> Void)?

    /// Przypina parametr do gałki panelu. Zwolnione przy okazji gałki (bo parametr
    /// wisiał już gdzie indziej albo gałka była zajęta) jadą do urządzenia osobno —
    /// tak samo robi oryginał, wysyłając najpierw odpięcie.
    public func assignKnob(index: Int, location: UInt8, moduleID: Int, paramIndex: Int) {
        let slot = selectedSlot
        guard slots.indices.contains(slot),
              (0 ..< G2KnobPages.knobCount).contains(index) else { return }
        let before = slots[slot].knobAssignments
        let freed = slots[slot].assignKnob(index: index, location: location,
                                           moduleID: moduleID, paramIndex: paramIndex)
        guard slots[slot].knobAssignments != before else { return }
        registerKnobUndo(before, slot: slot, actionName: "Assign Knob")
        for knob in freed where knob != index {
            onKnobAssignmentChange?(slot, knob, nil)
        }
        onKnobAssignmentChange?(slot, index, slots[slot].knobAssignment(at: index))
    }

    /// Assigns a patch parameter to the requested overview display in local or global mode.
    public func assignParameterPageKnob(index: Int, location: UInt8,
                                        moduleID: Int, paramIndex: Int)
    {
        guard (0 ..< G2KnobPages.knobCount).contains(index) else { return }
        if showsGlobalParameterPages {
            let before = performance.globalKnobAssignments
            performance.assignGlobalKnob(
                index: index,
                slot: selectedSlot,
                location: location,
                moduleID: moduleID,
                paramIndex: paramIndex
            )
            guard performance.globalKnobAssignments != before else { return }
            registerGlobalKnobUndo(before, actionName: "Assign Global Knob")
        } else {
            assignKnob(index: index, location: location, moduleID: moduleID, paramIndex: paramIndex)
        }
    }

    /// Moves an assignment between overview displays, matching Clavia's display-to-display drop.
    public func moveParameterPageKnob(from source: Int, to target: Int) {
        guard source != target,
              (0 ..< G2KnobPages.knobCount).contains(source),
              (0 ..< G2KnobPages.knobCount).contains(target) else { return }
        if showsGlobalParameterPages {
            guard let assignment = performance.globalKnobAssignments[source] else { return }
            let before = performance.globalKnobAssignments
            performance.globalKnobAssignments[source] = nil
            performance.assignGlobalKnob(
                index: target,
                slot: assignment.slot,
                location: assignment.location,
                moduleID: assignment.moduleID,
                paramIndex: assignment.paramIndex,
                isLed: assignment.isLed
            )
            registerGlobalKnobUndo(before, actionName: "Move Global Knob")
        } else {
            let slot = selectedSlot
            guard slots.indices.contains(slot),
                  let assignment = slots[slot].knobAssignment(at: source) else { return }
            let before = slots[slot].knobAssignments
            slots[slot].knobAssignments[source] = nil
            slots[slot].assignKnob(
                index: target,
                location: assignment.location,
                moduleID: assignment.moduleID,
                paramIndex: assignment.paramIndex,
                isLed: assignment.isLed
            )
            registerKnobUndo(before, slot: slot, actionName: "Move Knob")
            publishKnobChanges(from: before, slot: slot)
        }
    }

    /// Przypina parametr do pierwszej wolnej gałki strony z focusem — to nasz
    /// odpowiednik ⌘-przeciągnięcia gałki na okno stron w oryginale
    /// (Control (TryKnobAssign)) → [[Docs/ui/parameter-pages]].
    /// Zwraca numer gałki albo `nil`, gdy strona jest pełna.
    @discardableResult
    public func assignKnobToFocusedPage(location: UInt8, moduleID: Int, paramIndex: Int) -> Int? {
        assignKnob(toPage: focusedParameterPage, location: location,
                   moduleID: moduleID, paramIndex: paramIndex)
    }

    /// To samo na WSKAZANEJ stronie — tak działa „Assign ▸ Page A ▸ Column 2" oryginału
    /// (Knob Assign Menu (CreateKnobAssignMenu): pięć liter, w każdej trzy wiersze).
    /// Parametr ląduje na pierwszej wolnej gałce tego wiersza.
    @discardableResult
    public func assignKnob(toPage page: Int, location: UInt8, moduleID: Int,
                           paramIndex: Int) -> Int?
    {
        let slot = selectedSlot
        guard slots.indices.contains(slot),
              (0 ..< G2KnobPages.pageCount).contains(page) else { return nil }
        // Parametr już przypięty na tej stronie → nic nie rób (drugi ⌘-klik nie
        // ma zajmować kolejnej gałki tym samym parametrem).
        if let existing = slots[slot].knobIndex(location: location, moduleID: moduleID,
                                                paramIndex: paramIndex),
            existing / G2KnobPages.knobsPerPage == page
        {
            return existing
        }
        guard let index = slots[slot].firstFreeKnob(onPage: page) else { return nil }
        assignKnob(index: index, location: location, moduleID: moduleID, paramIndex: paramIndex)
        return index
    }

    public func clearKnob(index: Int) {
        let slot = selectedSlot
        guard slots.indices.contains(slot),
              slots[slot].knobAssignment(at: index) != nil else { return }
        let before = slots[slot].knobAssignments
        slots[slot].clearKnob(index: index)
        registerKnobUndo(before, slot: slot, actionName: "Clear Knob")
        onKnobAssignmentChange?(slot, index, nil)
    }

    /// Gałka panelu, na której wisi ten parametr — `nil`, gdy na żadnej.
    public func knobIndex(location: UInt8, moduleID: Int, paramIndex: Int) -> Int? {
        guard slots.indices.contains(selectedSlot) else { return nil }
        return slots[selectedSlot].knobIndex(location: location, moduleID: moduleID,
                                             paramIndex: paramIndex)
    }

    /// „Assign ▸ Disable" z menu nad parametrem — zdejmuje go z gałki panelu.
    public func clearKnob(location: UInt8, moduleID: Int, paramIndex: Int) {
        guard let index = knobIndex(location: location, moduleID: moduleID,
                                    paramIndex: paramIndex) else { return }
        clearKnob(index: index)
    }

    /// Gałka globalna performance'u, na której wisi ten parametr bieżącego slotu.
    public func globalKnobIndex(location: UInt8, moduleID: Int, paramIndex: Int) -> Int? {
        performance.globalKnobIndex(slot: selectedSlot, location: location,
                                    moduleID: moduleID, paramIndex: paramIndex)
    }

    /// „Global Assign ▸ Page X" — to samo co `assignKnob(toPage:)`, tylko na wspólnej
    /// mapie performance'u (sekcja `0x5F`), gdzie każdy wpis niesie jeszcze numer slotu.
    @discardableResult
    public func assignGlobalKnob(toPage page: Int, location: UInt8, moduleID: Int,
                                 paramIndex: Int) -> Int?
    {
        guard (0 ..< G2KnobPages.pageCount).contains(page) else { return nil }
        if let existing = globalKnobIndex(location: location, moduleID: moduleID,
                                          paramIndex: paramIndex),
            existing / G2KnobPages.knobsPerPage == page
        {
            return existing
        }
        guard let index = (0 ..< G2KnobPages.knobsPerPage)
            .map({ G2KnobPages.knobIndex(page: page, slot: $0) })
            .first(where: { performance.globalKnobAssignments[$0] == nil })
        else { return nil }
        let before = performance.globalKnobAssignments
        performance.assignGlobalKnob(index: index, slot: selectedSlot, location: location,
                                     moduleID: moduleID, paramIndex: paramIndex)
        guard performance.globalKnobAssignments != before else { return nil }
        registerGlobalKnobUndo(before, actionName: "Assign Global Knob")
        return index
    }

    /// „Global Assign ▸ Disable".
    public func clearGlobalKnob(location: UInt8, moduleID: Int, paramIndex: Int) {
        guard let index = globalKnobIndex(location: location, moduleID: moduleID,
                                          paramIndex: paramIndex) else { return }
        let before = performance.globalKnobAssignments
        performance.clearGlobalKnob(index: index)
        registerGlobalKnobUndo(before, actionName: "Clear Global Knob")
    }

    /// „Assign ▸ Page X ▸ Multi Column" z menu nad tłem modułu: wszystkie parametry
    /// modułu lądują na kolejnych gałkach, zaczynając od wskazanej strony i wchodząc
    /// na następne, gdy jedna nie starcza (instrukcja, str. 91).
    ///
    /// Zwraca liczbę faktycznie przypiętych parametrów.
    @discardableResult
    public func assignAllParameters(ofModule moduleID: Int, area: PatchArea,
                                    toPage page: Int, global: Bool) -> Int
    {
        let slot = selectedSlot
        guard slots.indices.contains(slot),
              let module = slots[slot].modules(in: area).first(where: { $0.id == moduleID })
        else { return 0 }
        let location = area.rawValue
        var assigned = 0
        var candidatePage = page
        for paramIndex in module.parameters.indices {
            var placed = false
            while candidatePage < G2KnobPages.pageCount, !placed {
                let index = global
                    ? assignGlobalKnob(toPage: candidatePage, location: location,
                                       moduleID: moduleID, paramIndex: paramIndex)
                    : assignKnob(toPage: candidatePage, location: location,
                                 moduleID: moduleID, paramIndex: paramIndex)
                if index != nil {
                    placed = true
                    assigned += 1
                } else {
                    candidatePage += 1
                }
            }
            if !placed { break } // strony się skończyły
        }
        return assigned
    }

    /// Undo dla stron parametrów działa na zdjęciu całej tablicy 120 gałek — jedno
    /// przypisanie potrafi zwolnić dwie inne, więc odtwarzanie po jednym byłoby
    /// łatwe do pomylenia. Po przywróceniu wysyłamy do urządzenia tylko to, co się
    /// faktycznie różni.
    private func registerKnobUndo(_ before: [G2KnobAssignment?], slot: Int, actionName: String) {
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreKnobAssignments(before, slot: slot, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func restoreKnobAssignments(_ snapshot: [G2KnobAssignment?], slot: Int, actionName: String) {
        guard slots.indices.contains(slot) else { return }
        let current = slots[slot].knobAssignments
        registerKnobUndo(current, slot: slot, actionName: actionName)
        slots[slot].knobAssignments = snapshot
        for index in 0 ..< min(current.count, snapshot.count) where current[index] != snapshot[index] {
            onKnobAssignmentChange?(slot, index, snapshot[index])
        }
    }

    private func publishKnobChanges(from previous: [G2KnobAssignment?], slot: Int) {
        guard slots.indices.contains(slot) else { return }
        let current = slots[slot].knobAssignments
        for index in 0 ..< min(previous.count, current.count) where previous[index] != current[index] {
            onKnobAssignmentChange?(slot, index, current[index])
        }
    }

    private func registerGlobalKnobUndo(_ before: [G2GlobalKnobAssignment?], actionName: String) {
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreGlobalKnobAssignments(before, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func restoreGlobalKnobAssignments(_ snapshot: [G2GlobalKnobAssignment?],
                                              actionName: String)
    {
        let current = performance.globalKnobAssignments
        registerGlobalKnobUndo(current, actionName: actionName)
        performance.globalKnobAssignments = snapshot
    }

    private struct MidiParameterTarget: Hashable {
        let location: UInt8
        let moduleID: Int
        let paramIndex: Int
    }

    /// Returns the main parameters and implicit linked buttons represented by the knob map.
    private func midiTargets(for slot: Int) -> [MidiParameterTarget] {
        guard slots.indices.contains(slot) else { return [] }
        let patch = slots[slot]
        var targets: [MidiParameterTarget] = []
        var seen: Set<MidiParameterTarget> = []
        for assignment in patch.knobAssignments.compactMap(\.self) {
            let main = MidiParameterTarget(
                location: assignment.location,
                moduleID: assignment.moduleID,
                paramIndex: assignment.paramIndex
            )
            if seen.insert(main).inserted { targets.append(main) }

            guard let area = PatchArea(rawValue: assignment.location),
                  let module = patch.modules(in: area).first(where: { $0.id == assignment.moduleID }),
                  let button = ModuleParameterLinks.buttonParameter(
                      moduleTypeID: module.typeID,
                      knobParameter: assignment.paramIndex
                  ),
                  patch.knobIndex(location: assignment.location,
                                  moduleID: assignment.moduleID,
                                  paramIndex: button) == nil else { continue }
            let linked = MidiParameterTarget(
                location: assignment.location,
                moduleID: assignment.moduleID,
                paramIndex: button
            )
            if seen.insert(linked).inserted { targets.append(linked) }
        }
        return targets
    }

    /// Assigns the first available non-reserved CCs in knob order, as Clavia does.
    public func autoAssignMidiControllersFromParameterPages() {
        guard !showsGlobalParameterPages, slots.indices.contains(selectedSlot) else { return }
        let slot = selectedSlot
        let before = slots[slot].midiControllerAssignments
        var nextCC = 0
        for target in midiTargets(for: slot) {
            if slots[slot].midiController(
                for: target.location,
                moduleID: target.moduleID,
                paramIndex: target.paramIndex
            ) != nil { continue }
            while nextCC < G2MidiControllers.count,
                  !G2MidiControllers.isAutoAssignable(nextCC)
                  || slots[slot].midiControllerAssignments[nextCC] != nil
            {
                nextCC += 1
            }
            guard nextCC < G2MidiControllers.count else { break }
            slots[slot].assignMidiController(
                cc: nextCC,
                location: target.location,
                moduleID: target.moduleID,
                paramIndex: target.paramIndex
            )
            nextCC += 1
        }
        guard slots[slot].midiControllerAssignments != before else { return }
        registerMidiControllerUndo(before, slot: slot, actionName: "Assign MIDI Controllers")
        publishMidiControllerChanges(from: before, slot: slot)
    }

    /// Clears automatically assignable CCs represented by the current knob map.
    public func clearMidiControllersFromParameterPages() {
        guard !showsGlobalParameterPages, slots.indices.contains(selectedSlot) else { return }
        let slot = selectedSlot
        let before = slots[slot].midiControllerAssignments
        for target in midiTargets(for: slot) {
            guard let cc = slots[slot].midiController(
                for: target.location,
                moduleID: target.moduleID,
                paramIndex: target.paramIndex
            ), !G2MidiControllers.isPreassigned(cc) else { continue }
            slots[slot].clearMidiController(cc: cc)
        }
        guard slots[slot].midiControllerAssignments != before else { return }
        registerMidiControllerUndo(before, slot: slot, actionName: "Clear MIDI Controllers")
        publishMidiControllerChanges(from: before, slot: slot)
    }

    /// Numer CC przypisany do parametru — `nil`, gdy żaden.
    public func midiController(location: UInt8, moduleID: Int, paramIndex: Int) -> Int? {
        guard slots.indices.contains(selectedSlot) else { return nil }
        return slots[selectedSlot].midiController(for: location, moduleID: moduleID,
                                                  paramIndex: paramIndex)
    }

    /// „MIDI Controller ▸ Assign" z menu pod prawym przyciskiem nad parametrem.
    /// Parametr może wisieć tylko na jednym CC i jedno CC tylko na jednym parametrze —
    /// pilnuje tego `G2Patch.assignMidiController`, które zwalnia poprzednie.
    public func assignMidiController(cc: Int, location: UInt8, moduleID: Int, paramIndex: Int) {
        let slot = selectedSlot
        guard slots.indices.contains(slot), G2MidiControllers.isValid(cc) else { return }
        let before = slots[slot].midiControllerAssignments
        slots[slot].assignMidiController(cc: cc, location: location,
                                         moduleID: moduleID, paramIndex: paramIndex)
        guard slots[slot].midiControllerAssignments != before else { return }
        registerMidiControllerUndo(before, slot: slot, actionName: "Assign MIDI Controller")
        publishMidiControllerChanges(from: before, slot: slot)
    }

    /// „MIDI Controller ▸ Remove" — zdejmuje CC z tego parametru.
    public func clearMidiController(location: UInt8, moduleID: Int, paramIndex: Int) {
        let slot = selectedSlot
        guard slots.indices.contains(slot),
              let cc = slots[slot].midiController(for: location, moduleID: moduleID,
                                                  paramIndex: paramIndex) else { return }
        let before = slots[slot].midiControllerAssignments
        slots[slot].clearMidiController(cc: cc)
        registerMidiControllerUndo(before, slot: slot, actionName: "Remove MIDI Controller")
        publishMidiControllerChanges(from: before, slot: slot)
    }

    /// „Assign MIDI to Selection" z menu Tools — wszystkie parametry wskazanych modułów
    /// dostają kolejne wolne numery CC, w kolejności modułów i parametrów.
    public func assignMidiControllers(toModules moduleIDs: Set<Int>, area: PatchArea) {
        let slot = selectedSlot
        guard slots.indices.contains(slot), !moduleIDs.isEmpty else { return }
        let before = slots[slot].midiControllerAssignments
        let location = area.rawValue
        var nextCC = 0
        for module in slots[slot].modules(in: area) where moduleIDs.contains(module.id) {
            for paramIndex in module.parameters.indices {
                if slots[slot].midiController(for: location, moduleID: module.id,
                                              paramIndex: paramIndex) != nil { continue }
                while nextCC < G2MidiControllers.count,
                      !G2MidiControllers.isAutoAssignable(nextCC)
                      || slots[slot].midiControllerAssignments[nextCC] != nil
                {
                    nextCC += 1
                }
                guard nextCC < G2MidiControllers.count else { break }
                slots[slot].assignMidiController(cc: nextCC, location: location,
                                                 moduleID: module.id, paramIndex: paramIndex)
                nextCC += 1
            }
        }
        guard slots[slot].midiControllerAssignments != before else { return }
        registerMidiControllerUndo(before, slot: slot, actionName: "Assign MIDI Controllers")
        publishMidiControllerChanges(from: before, slot: slot)
    }

    /// „Deassign MIDI from Selection" — zdejmuje CC ze wszystkich parametrów tych modułów.
    public func clearMidiControllers(forModules moduleIDs: Set<Int>, area: PatchArea) {
        let slot = selectedSlot
        guard slots.indices.contains(slot), !moduleIDs.isEmpty else { return }
        let before = slots[slot].midiControllerAssignments
        let location = area.rawValue
        for cc in slots[slot].midiControllerAssignments.indices {
            guard let assignment = slots[slot].midiControllerAssignments[cc],
                  assignment.location == location,
                  moduleIDs.contains(assignment.moduleID) else { continue }
            slots[slot].clearMidiController(cc: cc)
        }
        guard slots[slot].midiControllerAssignments != before else { return }
        registerMidiControllerUndo(before, slot: slot, actionName: "Remove MIDI Controllers")
        publishMidiControllerChanges(from: before, slot: slot)
    }

    /// „Deassign All MIDI" z menu Tools — czyści całą mapę CC patcha.
    public func clearAllMidiControllers() {
        let slot = selectedSlot
        guard slots.indices.contains(slot) else { return }
        let before = slots[slot].midiControllerAssignments
        guard before.contains(where: { $0 != nil }) else { return }
        slots[slot].midiControllerAssignments = Array(repeating: nil,
                                                      count: G2MidiControllers.count)
        registerMidiControllerUndo(before, slot: slot, actionName: "Remove All MIDI Controllers")
        publishMidiControllerChanges(from: before, slot: slot)
    }

    private func registerMidiControllerUndo(_ before: [G2MidiControllerAssignment?],
                                            slot: Int, actionName: String)
    {
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreMidiControllerAssignments(before, slot: slot, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func restoreMidiControllerAssignments(_ snapshot: [G2MidiControllerAssignment?],
                                                  slot: Int, actionName: String)
    {
        guard slots.indices.contains(slot) else { return }
        let current = slots[slot].midiControllerAssignments
        registerMidiControllerUndo(current, slot: slot, actionName: actionName)
        slots[slot].midiControllerAssignments = snapshot
        publishMidiControllerChanges(from: current, slot: slot)
    }

    private func publishMidiControllerChanges(from previous: [G2MidiControllerAssignment?],
                                              slot: Int)
    {
        guard slots.indices.contains(slot) else { return }
        let current = slots[slot].midiControllerAssignments
        for cc in 0 ..< min(previous.count, current.count) where previous[cc] != current[cc] {
            onMidiControllerAssignmentChange?(slot, cc, current[cc])
        }
    }

    /// Jedno miejsce, z którego struktura widocznego slotu jedzie do urządzenia.
    /// Wołane na końcu każdej operacji zmieniającej moduły albo kable — po zapisie
    /// do modelu, żeby most dostał stan już zmieniony.
    private func structureChanged(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        onLiveStructureChange?(slot, slots[slot])
    }

    private func structureChanged() {
        structureChanged(slot: selectedSlot)
    }

    /// Przepięcie kabla to dla modelu dwa ruchy — wyrwanie starego i wpięcie nowego —
    /// a dla użytkownika jeden. Widok otwiera serię przed wyrwaniem i zamyka po wpięciu;
    /// w środku `addCable`/`removeCable` niczego nie rejestrują, a na koniec idzie JEDEN
    /// wpis ze zdjęciem sprzed całego gestu. Bez tego ⌘Z cofało samo wpięcie i zostawiało
    /// kabel wyrwany — wyglądało to jak zepsute cofanie → [[Docs/ui/gestures]].
    private var structureGesture: (slot: Int, snapshot: G2Patch, actionName: String)?

    public func beginStructureGesture(_ actionName: String) {
        guard structureGesture == nil, slots.indices.contains(selectedSlot) else { return }
        structureGesture = (selectedSlot, slots[selectedSlot], actionName)
    }

    /// Zamyka serię. Gest, który niczego nie zmienił (upuszczenie kabla tam, skąd go
    /// wzięliśmy), nie zostawia wpisu — inaczej ⌘Z nie robiłoby nic widocznego.
    public func endStructureGesture() {
        guard let gesture = structureGesture else { return }
        structureGesture = nil
        guard slots.indices.contains(gesture.slot), slots[gesture.slot] != gesture.snapshot else { return }
        undoManager.registerUndo(withTarget: self) { [snapshot = gesture.snapshot] target in
            target.restorePatch(snapshot, slot: gesture.slot)
        }
        undoManager.setActionName(gesture.actionName)
    }

    public func addCable(_ cable: G2Cable, slot: Int? = nil) {
        let slot = slot ?? selectedSlot
        guard slots.indices.contains(slot) else { return }
        let snapshot = slots[slot]
        slots[slot].add(cable: cable)
        // Kabel z wyjścia ożywia cały łańcuch, w który wpadł — a „kable jednego
        // łańcucha mają zawsze ten sam kolor" (instrukcja, str. 71). Bez tego
        // szereg wejść zostawał biały mimo podłączonego źródła.
        if cable.sourceIsOutput {
            slots[slot].setCableColor(cable.color, forChainContaining: cable,
                                      in: cable.area)
        } else if let fed = slots[slot].cableChain(containing: cable, in: cable.area)
            .first(where: \.sourceIsOutput)
        {
            // Kabel wejście→wejście dopięty do łańcucha, który już ma źródło.
            slots[slot].setCableColor(fed.color, forChainContaining: cable, in: cable.area)
        }
        if structureGesture == nil {
            undoManager.registerUndo(withTarget: self) { [snapshot] target in
                target.restorePatch(snapshot, slot: slot)
            }
            undoManager.setActionName("Add Cable")
        }
        structureChanged(slot: slot)
    }

    public func removeCable(_ cable: G2Cable) {
        let slot = selectedSlot
        guard slots.indices.contains(slot) else { return }
        slots[slot].remove(cable: cable)
        if structureGesture == nil {
            undoManager.registerUndo(withTarget: self) { target in
                target.addCable(cable, slot: slot)
            }
            undoManager.setActionName("Remove Cable")
        }
        structureChanged(slot: slot)
    }

    // MARK: - Menu pod prawym przyciskiem nad kablem (instrukcja, str. 70–71)

    /// „Disconnect" — odpina gniazdo docelowe i zszywa łańcuch, żeby to, co szło
    /// dalej, dostało sygnał prosto ze źródła.
    public func disconnectCable(_ cable: G2Cable, area: PatchArea) {
        mutateCables("Disconnect Cable") { $0.disconnectCable(cable, in: area) }
    }

    /// „Break" — usuwa sam kabel; reszta łańcucha zostaje wpięta, ale bez sygnału.
    public func breakCable(_ cable: G2Cable, area: PatchArea) {
        mutateCables("Break Cable") { patch in
            patch.breakCable(cable)
            patch.recolorUnusedChains(in: area)
        }
    }

    /// „Delete" — cały łańcuch szeregowy, którego częścią jest ten kabel.
    public func deleteCableChain(_ cable: G2Cable, area: PatchArea) {
        mutateCables("Delete Cables") { $0.deleteCableChain(containing: cable, in: area) }
    }

    /// „Color" — kolor całego łańcucha, bo w jednym łańcuchu jest zawsze jeden kolor.
    public func setCableColor(_ color: CableColor, forChainContaining cable: G2Cable,
                              area: PatchArea)
    {
        mutateCables("Change Cable Color") {
            $0.setCableColor(color, forChainContaining: cable, in: area)
        }
    }

    /// „Delete Unused Cables" — wszystkie łańcuchy wejście→wejście, do których
    /// nie dochodzi żadne wyjście.
    public func deleteUnusedCables(area: PatchArea) {
        guard !slots[selectedSlot].unusedCables(in: area).isEmpty else { return }
        mutateCables("Delete Unused Cables") { patch in
            for cable in patch.unusedCables(in: area) {
                patch.remove(cable: cable)
            }
        }
    }

    /// Ile martwych kabli ma obszar — menu wyszarza pozycję, gdy nie ma czego kasować.
    public func unusedCableCount(area: PatchArea) -> Int {
        slots[selectedSlot].unusedCables(in: area).count
    }

    /// Wspólna oprawa operacji na kablach: zdjęcie stanu na undo + zgłoszenie zmiany.
    private func mutateCables(_ actionName: String, _ body: (inout G2Patch) -> Void) {
        let slot = selectedSlot
        let snapshot = slots[slot]
        body(&slots[slot])
        guard slots[slot].cablesDiffer(from: snapshot) else { return }
        undoManager.registerUndo(withTarget: self) { [snapshot] target in
            target.restorePatch(snapshot, slot: slot)
        }
        undoManager.setActionName(actionName)
        structureChanged(slot: slot)
    }

    public func deleteModule(moduleID: Int, area: PatchArea) {
        deleteModules(moduleIDs: [moduleID], area: area)
    }

    public func deleteModules(moduleIDs: Set<Int>, area: PatchArea) {
        let slot = selectedSlot
        let existingIDs = moduleIDs.intersection(Set(slots[slot].modules(in: area).map(\.id)))
        guard !existingIDs.isEmpty else { return }
        let snapshot = slots[slot]
        slots[slot].deleteModules(moduleIDs: existingIDs, in: area)
        undoManager.registerUndo(withTarget: self) { [snapshot] target in
            target.restorePatch(snapshot, slot: slot)
        }
        undoManager.setActionName(existingIDs.count == 1 ? "Delete Module" : "Delete Modules")
        structureChanged()
    }

    /// „Delete Unused Modules" z menu Patch — moduły, do których nie dochodzi ani nie
    /// wychodzi żaden kabel. Moduły, które gniazd w ogóle nie mają (Name, część MIDI),
    /// zostają: nie da się ich podłączyć, więc „nieużywany" nic by o nich nie mówiło.
    public func deleteUnusedModules(area: PatchArea) {
        let ids = unusedModuleIDs(area: area)
        guard !ids.isEmpty else { return }
        deleteModules(moduleIDs: ids, area: area)
        undoManager.setActionName("Delete Unused Modules")
    }

    /// Moduły bez jednego kabla — do wyszarzenia pozycji menu i do samego kasowania.
    public func unusedModuleIDs(area: PatchArea) -> Set<Int> {
        guard slots.indices.contains(selectedSlot) else { return [] }
        let patch = slots[selectedSlot]
        var connected: Set<Int> = []
        for cable in patch.cables(in: area) {
            connected.insert(cable.fromModule)
            connected.insert(cable.toModule)
        }
        return Set(patch.modules(in: area).filter { module in
            guard !connected.contains(module.id) else { return false }
            guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return false }
            return !ui.inputs.isEmpty || !ui.outputs.isEmpty
        }.map(\.id))
    }

    /// „Paste Params" — same wartości parametrów ze schowka, bez tworzenia modułów.
    /// Instrukcja (str. 69): wartości lecą na inne moduły **tego samego typu**, albo na
    /// te same moduły w innej wariacji. Cele bierzemy w kolejności patcha, źródła
    /// w kolejności schowka; gdy źródeł danego typu jest mniej niż celów, lista się zapętla
    /// — dzięki temu jeden skopiowany moduł obsadza całą zaznaczoną grupę.
    ///
    /// Zwraca liczbę modułów, które faktycznie dostały wartości.
    @discardableResult
    public func pasteParameters(_ content: G2ClipboardContent, into moduleIDs: Set<Int>,
                                area: PatchArea) -> Int
    {
        let slot = selectedSlot
        guard slots.indices.contains(slot), !moduleIDs.isEmpty else { return 0 }
        var sourcesByType: [Int: [G2ClipboardContent.ClipModule]] = [:]
        for module in content.modules {
            sourcesByType[module.typeID, default: []].append(module)
        }
        guard !sourcesByType.isEmpty else { return 0 }

        let snapshot = slots[slot]
        var nextIndex: [Int: Int] = [:]
        var pasted = 0
        let variation = slots[slot].activeVariation

        for module in slots[slot].modules(in: area) where moduleIDs.contains(module.id) {
            guard let sources = sourcesByType[module.typeID], !sources.isEmpty else { continue }
            let cursor = nextIndex[module.typeID, default: 0]
            let source = sources[cursor % sources.count]
            nextIndex[module.typeID] = cursor + 1

            for index in module.parameters.indices where source.parameters.indices.contains(index) {
                let value = max(0, min(127, source.parameters[index]))
                guard module.parameters[index] != value else { continue }
                slots[slot].setParameter(moduleID: module.id, paramIndex: index,
                                         value: value, in: area, variation: variation)
                // Diff strukturalny nie niesie wartości parametrów istniejących modułów,
                // więc każdą zmienioną trzeba podać urządzeniu osobno — tak jak przy gałce.
                onLiveParameterChange?(slot, area, module.id, index, value, variation)
            }
            for index in module.modes.indices where source.modes.indices.contains(index) {
                slots[slot].setMode(moduleID: module.id, modeIndex: index,
                                    value: source.modes[index], in: area)
            }
            pasted += 1
        }

        guard pasted > 0 else { return 0 }
        undoManager.registerUndo(withTarget: self) { [snapshot] target in
            target.restorePatch(snapshot, slot: slot)
        }
        undoManager.setActionName("Paste Params")
        structureChanged(slot: slot)
        return pasted
    }

    public func replaceModule(moduleID: Int, targetTypeID: Int, area: PatchArea) {
        let slot = selectedSlot
        let snapshot = slots[slot]
        guard slots[slot].replaceModule(
            moduleID: moduleID,
            with: targetTypeID,
            in: area
        ) else { return }
        undoManager.registerUndo(withTarget: self) { [snapshot] target in
            target.restorePatch(snapshot, slot: slot)
        }
        undoManager.setActionName("Replace Module")
        structureChanged()
    }

    public func setModuleColor(moduleID: Int, color: UInt8, area: PatchArea, slot: Int? = nil) {
        let slot = slot ?? selectedSlot
        guard slots.indices.contains(slot) else { return }
        let old = slots[slot].modules(in: area).first { $0.id == moduleID }?.color ?? 0
        slots[slot].setModuleColor(moduleID: moduleID, color: color, in: area)
        undoManager.registerUndo(withTarget: self) { [old] target in
            target.setModuleColor(moduleID: moduleID, color: old, area: area, slot: slot)
        }
        undoManager.setActionName("Change Module Color")
        structureChanged(slot: slot)
    }

    /// Przywraca zdjęcie CAŁEGO patcha we wskazanym slocie — wspólny krok undo operacji
    /// strukturalnych. Slot jest argumentem, nie `selectedSlot`: cofnięcie ma wracać do
    /// slotu, w którym zmiana powstała, także gdy użytkownik zdążył przełączyć się na
    /// inny — przy czterech pasach albo oknach slotów to codzienność. Do 2026-09-11
    /// zdjęcie lądowało w slocie z focusem, czyli ⌘Z po zmianie slotu podmieniało
    /// cudzy patch.
    private func restorePatch(_ snapshot: G2Patch, slot: Int) {
        guard slots.indices.contains(slot) else { return }
        let current = slots[slot]
        slots[slot] = snapshot
        undoManager.registerUndo(withTarget: self) { [current] target in
            target.restorePatch(current, slot: slot)
        }
        structureChanged(slot: slot)
    }

    /// Podmienia CAŁY patch w slocie jako **jeden** krok Undo o własnej nazwie — tego
    /// potrzebują mosty z zewnątrz (wtyczka DAW, Claude). Cofnięcie idzie tą samą drogą co
    /// operacje strukturalne kanwy, więc ⌘Z i ⇧⌘Z zachowują się tak, jakby patch zbudowała
    /// ręka użytkownika, a Nord dostaje zmianę przez `onLiveStructureChange`.
    public func replaceSlot(slot: Int, patch: G2Patch, actionName: String) {
        guard slots.indices.contains(slot) else { return }
        let before = slots[slot]
        var incoming = patch
        incoming.ensureRuntimeVariations()
        slots[slot] = incoming
        slots[slot].syncParametersToActiveVariation()
        undoManager.registerUndo(withTarget: self) { target in
            target.restorePatch(before, slot: slot)
        }
        undoManager.setActionName(actionName)
        structureChanged(slot: slot)
    }


    public func renameModule(moduleID: Int, label: String, area: PatchArea, slot: Int? = nil) {
        let slot = slot ?? selectedSlot
        guard slots.indices.contains(slot) else { return }
        let old = slots[slot].modules(in: area).first(where: { $0.id == moduleID })?.label ?? ""
        slots[slot].setLabel(moduleID: moduleID, label: label, in: area)
        undoManager.registerUndo(withTarget: self) { [old] target in
            target.renameModule(moduleID: moduleID, label: old, area: area, slot: slot)
        }
        undoManager.setActionName("Rename Module")
        structureChanged(slot: slot)
    }

    /// Dodaje nowy moduł do patcha z domyślnymi parametrami i zwraca jego numer.
    /// Gdy column/row == nil → auto-pozycja (kolumna 0, za ostatnim modułem).
    ///
    /// Numer (`G2Module.id`) jest jedynym stałym i niepowtarzalnym kluczem modułu: kable
    /// w pliku i komendy do urządzenia wskazują moduł numerem, a etykietę użytkownik może
    /// zmienić na dowolną, także powtarzającą się. Kto po dodaniu musi coś z modułem zrobić
    /// (połączyć, ustawić), bierze numer stąd, zamiast szukać „nowego" modułu w patchu.
    /// `nil`, gdy typ modułu jest nieznany albo slot nie istnieje — wtedy nic nie dodano.
    @discardableResult
    public func addModule(typeID: Int, area: PatchArea, column: Int? = nil, row: Int? = nil) -> Int? {
        guard let def = ModuleDatabase.module(id: typeID) else { return nil }
        let slot = selectedSlot
        guard slots.indices.contains(slot) else { return nil }
        let snapshot = slots[slot]

        // Unikalny ID — najmniejsza wolna liczba całkowita ≥ 1
        let usedIDs = Set((slots[slot].voiceModules + slots[slot].fxModules).map(\.id))
        var newID = 1
        while usedIDs.contains(newID) {
            newID += 1
        }

        // Pozycja: jawna (drag & drop) lub auto (kolumna 0, za ostatnim modułem)
        let mods = slots[slot].modules(in: area)
        let targetColumn: Int
        let targetRow: Int
        if let col = column, let r = row {
            targetColumn = max(0, col)
            targetRow = max(0, r)
        } else {
            targetColumn = 0
            let col0 = mods.filter { $0.column == 0 }
            if let last = col0.max(by: { $0.row < $1.row }) {
                targetRow = last.row + (ModuleDatabase.module(id: last.typeID)?.height ?? 2)
            } else {
                targetRow = 0
            }
        }

        var mod = G2Module(id: newID, typeID: typeID, area: area)
        mod.column = targetColumn
        mod.row = targetRow
        // Domyślna etykieta z numerem rosnącym osobno dla każdego typu (OscB1, OscB2…)
        mod.label = ModuleAutoLabel.next(
            shortName: def.shortName,
            existingLabels: mods.filter { $0.typeID == typeID }.map(\.label)
        )
        // Domyślne parametry z ModuleDef.xml + wszystkie 9 wariacji
        let defaults = ModuleDefaultsDatabase.defaults(forTypeID: typeID)
        mod.parameters = defaults.isEmpty ? Array(repeating: 0, count: def.paramNames.count) : defaults
        mod.parameterVariations = Array(repeating: mod.parameters, count: 9)
        mod.modes = Array(repeating: 0, count: def.modeNames.count)

        slots[slot].insert(module: mod)
        undoManager.registerUndo(withTarget: self) { [snapshot] target in
            target.restorePatch(snapshot, slot: slot)
        }
        undoManager.setActionName("Add Module")
        structureChanged(slot: slot)
        return newID
    }

    /// Wkleja moduły ze schowka do patcha.
    /// Zwraca zestaw nowo dodanych ID modułów (żeby canvas mógł je zaznaczyć).
    @discardableResult
    public func pasteModules(_ content: G2ClipboardContent, area: PatchArea) -> Set<Int> {
        let slot = selectedSlot
        guard slots.indices.contains(slot) else { return [] }
        let snapshot = slots[slot]
        var usedIDs = Set((slots[slot].voiceModules + slots[slot].fxModules).map(\.id))

        // Remapuj originalID → newID
        var idMap: [Int: Int] = [:]
        for clip in content.modules {
            var newID = 1
            while usedIDs.contains(newID) {
                newID += 1
            }
            idMap[clip.originalID] = newID
            usedIDs.insert(newID)
        }

        // Dodaj moduły z nowymi ID
        for clip in content.modules {
            guard let newID = idMap[clip.originalID],
                  let def = ModuleDatabase.module(id: clip.typeID) else { continue }
            var mod = G2Module(id: newID, typeID: clip.typeID, area: area)
            mod.column = clip.column
            mod.row = clip.row
            mod.color = clip.color
            mod.label = clip.label
            mod.parameters = clip.parameters.isEmpty
                ? Array(repeating: 0, count: def.paramNames.count)
                : clip.parameters
            mod.parameterVariations = clip.parameterVariations.isEmpty
                ? Array(repeating: mod.parameters, count: 9)
                : clip.parameterVariations
            mod.modes = clip.modes.isEmpty
                ? Array(repeating: 0, count: def.modeNames.count)
                : clip.modes
            slots[slot].add(module: mod)
        }

        // Dodaj kable (tylko te których oba końce są w clipboardzie)
        for clip in content.cables {
            guard let fromID = idMap[clip.fromModule],
                  let toID = idMap[clip.toModule],
                  let color = CableColor(rawValue: UInt8(clip.cableColor))
            else { continue }
            let cable = G2Cable(
                fromModule: fromID, fromConnector: clip.fromConnector,
                toModule: toID, toConnector: clip.toConnector,
                color: color, area: area,
                sourceIsOutput: clip.sourceIsOutput
            )
            slots[slot].add(cable: cable)
        }

        undoManager.registerUndo(withTarget: self) { [snapshot] target in
            target.restorePatch(snapshot, slot: slot)
        }
        undoManager.setActionName("Paste Modules")
        structureChanged(slot: slot)

        return Set(idMap.values)
    }

    public func moveModule(moduleID: Int, newColumn: Int, newRow: Int,
                           area: PatchArea, push: G2Patch.PushDirection = .down)
    {
        let slot = selectedSlot
        guard slots.indices.contains(slot) else { return }
        let snapshot = slots[slot].modules(in: area)
        slots[slot].moveModule(moduleID: moduleID, newColumn: newColumn,
                               newRow: newRow, in: area, push: push)
        undoManager.registerUndo(withTarget: self) { [snapshot] target in
            target.restoreModulePositions(snapshot, area: area, slot: slot)
        }
        undoManager.setActionName("Move Module")
        structureChanged(slot: slot)
    }

    private func restoreModulePositions(_ snapshot: [G2Module], area: PatchArea, slot: Int) {
        guard slots.indices.contains(slot) else { return }
        let current = slots[slot].modules(in: area)
        undoManager.registerUndo(withTarget: self) { [current] target in
            target.restoreModulePositions(current, area: area, slot: slot)
        }
        if area == .voice {
            slots[slot].voiceModules = snapshot
        } else {
            slots[slot].fxModules = snapshot
        }
        structureChanged(slot: slot)
    }

    /// File → New Patch. U Clavii `CEditorApp::HandleMenuFileNew(false)` rozgałęzia się na
    /// `DoesSlotFocusExist`: bez focusu na slocie robi wolny patch (`CreateEmptyLocalPatch`),
    /// a z focusem — `CreateEmptyDownloadPatch(port, focusedSlot)`, czyli pusty patch
    /// **wyłącznie w slocie z focusem**, od razu wepchnięty do urządzenia. BVerhue robi to
    /// samo krócej: `G2.SelectedPatch.Init` + `SendSetPatchMessage('No name', …)`.
    ///
    /// U nas focus na slocie jest zawsze, więc czyści się jeden slot, a pozostałe trzy grają
    /// dalej. Slot traci swój plik — inaczej ⌘S zaraz po ⌘N nadpisałby czyjś patch pustką.
    public func newPatch() {
        newPatch(inSlot: selectedSlot)
    }

    /// File → New To ▸ Slot X. U Clavii `CEditorApp::HandleMenuFileNewTo(slot)` sprowadza się
    /// do `CreateEmptyPerformancePatch(topPerformance, slot)`: pusty patch ląduje we
    /// **wskazanym** slocie, a przy podłączonym syncie od razu tam jedzie
    /// (`ConnectSynth(patch, synth, slot, 1)`).
    ///
    /// Focus przenosimy na ten slot, czego oryginał nie robi: tam nowy patch dostaje własne
    /// okno i sam staje przed oczami. W jednym oknie nie ma innego sposobu, żeby pokazać, co
    /// wybór z menu zrobił.
    public func newPatch(inSlot slot: Int) {
        guard slots.indices.contains(slot) else { return }
        let before = slotContents(slot)
        slots[slot] = emptyPatch()
        slotFileURLs[slot] = nil
        slotFileData[slot] = nil
        markSlotSaved(slot)
        if hasPerformanceSettings, performance.slots.indices.contains(slot) {
            performance.slots[slot].name = Self.emptyPatchName
        }
        if !isLoaded { fileName = Self.emptyPatchName }
        selectedSlot = slot
        errorMessage = nil
        resetUndoHistory()
        registerSlotRestore(before, slot: slot, actionName: "New Patch")
    }

    /// File → New Performance (i start aplikacji). Za `CPerformanceManager::CreateNewPerformance`
    /// u Clavii: nazwa „Empty perf", pusty patch w każdym z czterech slotów, `EnableKeyboard(kOne)`,
    /// pole wybranego slotu = `kOne` i `PatchViewSelect` na jego patchu — klawiatura i focus
    /// lądują na A. BVerhue `TG2FilePerformance.Init` dokłada zegar: `FMasterClock := $78`
    /// (120 BPM), `FMasterClockRun := 0`.
    ///
    /// ⚠️ **Świadome odstępstwo od oryginału (decyzja użytkownika 2026-09-26):** Clavia i BVerhue
    /// włączają (`EnableSlot`) wszystkie cztery sloty, u nas **gra tylko A**. Cztery puste,
    /// a grające sloty nie dawały nic poza ryzykiem: patch otwarty potem do B–D grał od razu
    /// razem z A.
    public func newPerformance() {
        slots = Array(repeating: emptyPatch(), count: Self.slotTotal)
        selectedSlot = 0
        fileName = Self.emptyPerformanceName
        mirrorsDevice = false
        errorMessage = nil
        resetUndoHistory()
        resetPerformanceSettings()
        performance = Self.emptyPerformanceSettings()
        hasPerformanceSettings = true
        performanceName = Self.emptyPerformanceName
        forgetFiles()
    }

    /// Pusty patch pod nazwą, którą urządzenie pokazuje po Init — patrz `emptyPatchName`.
    private func emptyPatch() -> G2Patch {
        var patch = G2Patch()
        patch.name = Self.emptyPatchName
        return patch
    }

    private static func emptyPerformanceSettings() -> G2PerformanceSettings {
        var settings = G2PerformanceSettings()
        settings.focusedSlot = 0
        for index in settings.slots.indices {
            settings.slots[index].name = emptyPatchName
            settings.slots[index].enabled = index == 0
            settings.slots[index].keyboard = index == 0
        }
        return settings
    }

    /// Wczytuje 4 sloty właśnie odczytane z podłączonego urządzenia (`DeviceConnection.connect`).
    /// Bez plików — to nie jest nic z dysku, więc Save pyta najpierw o miejsce.
    ///
    /// `performanceName` przychodzi z urządzenia (odpowiedź `0x29`) — tu na ekranie stoi
    /// zawartość Norda, więc i nazwa ma być jego, a nie zastępcza nazwa dokumentu.
    public func loadFromDevice(patches: [G2Patch], performanceName: String = "",
                               performance: G2PerformanceSettings? = nil)
    {
        slots = fourSlots(patches)
        mirrorsDevice = true
        selectedSlot = 0
        fileName = "Nord G2"
        errorMessage = nil
        resetUndoHistory()
        withoutParameterPageEcho {
            resetPerformanceSettings()
            adoptDevicePerformance(performance)
            focusFirstAssignedParameterPage()
        }
        self.performanceName = performanceName
        forgetFiles()
    }

    /// Ustawienia performance'u odczytane z Norda (nagłówek `0x10` + gałki globalne `0x5E`).
    /// Bez tego dokument z zawartością Norda miał ustawienia domyślne, a Save Performance
    /// zapisywał je zamiast prawdziwych: sloty, zakresy klawiatury, tempo i gałki globalne.
    private func adoptDevicePerformance(_ device: G2PerformanceSettings?) {
        guard let device else { return }
        performance = device
        hasPerformanceSettings = true
    }

    /// Dokładnie cztery sloty — brakujące dopełnia pusty patch.
    private func fourSlots(_ patches: [G2Patch]) -> [G2Patch] {
        let count = min(patches.count, Self.slotTotal)
        return Array(patches.prefix(count))
            + Array(repeating: emptyPatch(), count: Self.slotTotal - count)
    }

    /// Sheety i ustawienia performance'u nie powinny przetrwać wczytania innego pliku.
    private func resetPerformanceSettings() {
        let globalPages = performance.globalPagesEnabled
        showPatchSettings = false
        showPatchNotes = false
        showPerformanceSettings = false
        performance = G2PerformanceSettings()
        hasPerformanceSettings = false
        performanceName = ""
        // `Global Pages` przeżywa wczytanie zawartości: u Clavii to stan performance'u,
        // a wczytanie patcha (`CPatch::LoadFromFile`) w ogóle go nie dotyka. Plik `.prf2`
        // ma ten przycisk zapisany i nadpisze go zaraz potem swoją wartością.
        performance.globalPagesEnabled = globalPages
    }

    /// Historia undo należy do konkretnego patcha — po podmianie zawartości slotów
    /// akcje z poprzedniego są bezużyteczne, a snapshotowe (usunięcie, wklejenie)
    /// wręcz nadpisałyby świeżo wczytany patch. Stąd czyszczenie przy każdym resecie.
    private func resetUndoHistory() {
        undoManager.removeAllActions()
        endParameterGesture()
        undoRevision += 1
    }

    /// Wszystko, co New, Init 1/2 i Init wariacji podmieniają w slocie — do ⌘Z. Oryginał
    /// tych operacji nie cofa; jeden zły klik kasował patch (prośba użytkownika G2 z FB,
    /// 2026-09-25). Historia sprzed podmiany i tak przepada (`resetUndoHistory`), więc ⌘Z
    /// wraca do patcha takiego, jaki był w chwili kliknięcia.
    private struct SlotContents {
        var patch: G2Patch
        var fileURL: URL?
        var fileData: Data?
        var saved: G2Patch
        var performanceSlotName: String?
    }

    /// Cofnięta albo ponowiona podmiana slotu — Nord ma dostać z powrotem cały slot, bo różnica
    /// może obejmować wszystko naraz. Most do urządzenia podłącza `RootView`.
    public var onSlotRestore: ((_ slot: Int) -> Void)?

    private func slotContents(_ slot: Int) -> SlotContents {
        SlotContents(
            patch: slots[slot],
            fileURL: slotFileURLs[slot],
            fileData: slotFileData[slot],
            saved: savedSlots[slot],
            performanceSlotName: performance.slots.indices.contains(slot) ? performance.slots[slot].name : nil
        )
    }

    /// Para undo/redo dla podmiany slotu: każdy krok zapamiętuje stan, który zastępuje.
    /// Grupa własna, gdy żadna nie jest otwarta — `resetUndoHistory` (New, Init 1/2)
    /// zamyka `removeAllActions` także grupę bieżącego zdarzenia.
    private func registerSlotRestore(_ contents: SlotContents, slot: Int, actionName: String) {
        let ownGroup = undoManager.groupingLevel == 0
        if ownGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { state in
            let replaced = state.slotContents(slot)
            state.restoreSlot(contents, slot: slot)
            state.registerSlotRestore(replaced, slot: slot, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        if ownGroup { undoManager.endUndoGrouping() }
    }

    private func restoreSlot(_ contents: SlotContents, slot: Int) {
        endParameterGesture()
        clearMutations()
        slots[slot] = contents.patch
        slotFileURLs[slot] = contents.fileURL
        slotFileData[slot] = contents.fileData
        savedSlots[slot] = contents.saved
        if let name = contents.performanceSlotName, performance.slots.indices.contains(slot) {
            performance.slots[slot].name = name
        }
        selectedSlot = slot
        onSlotRestore?(slot)
    }

    // MARK: - Zmiany przychodzące Z URZĄDZENIA

    /// Parametr zmieniony NA FRONCIE Norda. Zapisujemy do modelu, ale **nie** odsyłamy
    /// z powrotem (`onLiveParameterChange` pominięty) — inaczej powstałaby pętla echa —
    /// i **nie** rejestrujemy undo: to lustro stanu sprzętu, a nie edycja użytkownika,
    /// więc ⌘Z cofałoby coś, czego na urządzeniu i tak już nie ma.
    public func applyDeviceParameter(slot: Int, area: PatchArea, moduleID: Int,
                                     paramIndex: Int, value: Int, variation: Int)
    {
        guard slots.indices.contains(slot) else { return }
        followingDevice(slot: slot) {
            slots[slot].setParameter(moduleID: moduleID, paramIndex: paramIndex,
                                     value: value, in: area, variation: variation)
        }
        updateAdjusterBaseline(slot: slot, area: area, moduleID: moduleID, paramIndex: paramIndex,
                               value: max(0, min(127, value)), variation: variation)
    }

    /// Ustawienie patcha (obszar 2) zmienione NA FRONCIE Norda: gałka albo źródło morfu
    /// (moduł 1) oraz Glide/Bend/Vibrato/Arp (moduły 3–7). Te same zasady co przy
    /// `applyDeviceParameter` — bez odsyłania z powrotem i bez undo.
    ///
    /// Do 2026-09-09 obszar 2 w ogóle tu nie docierał: dekoder sprowadzał numer obszaru
    /// do `PatchArea`, więc ustawienie patcha przebierało się za moduł FX o tym samym
    /// numerze → [[Docs/usb/notifications]].
    public func applyDeviceSetting(slot: Int, moduleID: Int, paramIndex: Int,
                                   value: Int, variation: Int)
    {
        guard slots.indices.contains(slot),
              slots[slot].variationSettings.indices.contains(variation) else { return }
        let clamped = max(0, min(127, value))
        if moduleID == Self.morphSettingsModule {
            followingDevice(slot: slot) {
                if paramIndex < G2Morph.count {
                    slots[slot].setMorphDial(paramIndex, in: variation, value: clamped)
                } else if paramIndex < G2Morph.count * 2 {
                    slots[slot].setMorphMode(paramIndex - G2Morph.count, in: variation, value: clamped)
                }
            }
            return
        }
        guard let setting = G2PatchSetting.allCases.first(where: {
            $0.module == moduleID && $0.param == paramIndex
        }) else { return }
        followingDevice(slot: slot) {
            slots[slot].variationSettings[variation][keyPath: setting.keyPath] = clamped
        }
    }

    /// Inny patch załadowany NA URZĄDZENIU — podmieniamy zawartość tego slotu.
    /// Tylko gdy w edytorze jest widok urządzenia: otwarty plik użytkownika ma
    /// pierwszeństwo i nie może zostać skasowany przez ruch na froncie Norda.
    ///
    /// Undo czyścimy w całości, bo akcje snapshotowe (usunięcie, wklejenie) cofnęłyby
    /// się na świeżo wczytany patch — ten sam powód co przy `loadFromDevice`. Slot traci
    /// swój plik: jego zawartość przyszła z Norda, nie z dysku.
    public func replaceSlotFromDevice(slot: Int, patch: G2Patch) {
        guard mirrorsDevice, slots.indices.contains(slot) else { return }
        slots[slot] = patch
        slotFileURLs[slot] = nil
        slotFileData[slot] = nil
        markSlotSaved(slot)
        resetUndoHistory()
        if slot == selectedSlot {
            withoutParameterPageEcho { focusFirstAssignedParameterPage() }
        }
    }

    /// Wszystkie sloty odczytane na nowo po zmianie na urządzeniu. W odróżnieniu od
    /// `loadFromDevice` **nie ruszamy wybranego slotu** — użytkownik patrzy na konkretny
    /// i przeskok na A po każdym załadowaniu patcha byłby dla niego zmianą widoku,
    /// o którą nie prosił.
    ///
    /// Na ekranie ląduje wtedy zawartość Norda, a nie plik: żadnego pliku do zapisania.
    /// Trzymanie starych plików znaczyłoby, że Save wpisuje do pliku użytkownika patche,
    /// które przyszły z urządzenia.
    public func replaceSlotsFromDevice(patches: [G2Patch], performanceName: String = "",
                                       performance: G2PerformanceSettings? = nil)
    {
        guard mirrorsDevice, !patches.isEmpty else { return }
        slots = fourSlots(patches)
        fileName = "Nord G2"
        resetUndoHistory()
        withoutParameterPageEcho {
            resetPerformanceSettings()
            adoptDevicePerformance(performance)
            focusFirstAssignedParameterPage()
        }
        self.performanceName = performanceName
        forgetFiles()
    }

    /// Wariacja przełączona na froncie Norda — gałki mają pokazać wartości tej wariacji.
    public func applyDeviceVariation(slot: Int, variation: Int) {
        guard slots.indices.contains(slot), slots[slot].activeVariation != variation else { return }
        followingDevice(slot: slot) { slots[slot].setActiveVariation(variation) }
    }

    /// File ▸ Open Patch, Open Recent, biblioteka plików i most Claude'a. `.pch2` wchodzi do
    /// slotu z focusem — jak u Clavii przy Nordzie w trybie Patch
    /// (`CreateDownloadPatchFromFile(slot z focusem)`), a sloty są u nas zawsze. `.prf2`
    /// zastępuje wszystkie cztery sloty.
    ///
    /// Zwraca `true`, gdy zmienił się tylko slot z focusem — wtedy do Norda jedzie sam on.
    @discardableResult
    public func load(url: URL, patchOpenMode: PatchOpenMode = .stored) -> Bool {
        if url.pathExtension.lowercased() == "prf2" {
            loadPerformance(url: url)
            return false
        }
        if patchOpenMode == .likeOriginal {
            loadAsOnlyPatch(url: url)
            return false
        }
        load(url: url, intoSlot: selectedSlot)
        return true
    }

    /// Opcja „jak oryginał” (`CreateDownloadPerformanceFromPatch`): plik do slotu A, B–D
    /// puste, ustawienia performance'u porzucone — do Norda jadą wszystkie cztery sloty.
    /// Pliku, którego nie da się odczytać, nie ma czym zastąpić, więc wtedy nic nie znika.
    private func loadAsOnlyPatch(url: URL) {
        load(url: url, intoSlot: 0)
        guard errorMessage == nil else { return }
        let patch = slots[0]
        let data = slotFileData[0]
        resetPerformanceSettings()
        slots = fourSlots([patch])
        forgetFiles()
        slotFileURLs[0] = url
        slotFileData[0] = data
        fileName = url.lastPathComponent
        selectedSlot = 0
    }

    /// Wczytanie innego patcha unieważnia potomstwo mutatora — dotyczyło tamtych modułów.
    private func loadPerformance(url: URL) {
        clearMutations()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try PatchParser.parseFile(data: data)
            slots = fourSlots(parsed.patches.map { patch in
                var patch = patch
                patch.fillMissingParameters()
                return patch
            })
            selectedSlot = 0
            fileName = url.lastPathComponent
            mirrorsDevice = false
            errorMessage = nil
            resetUndoHistory()
            resetPerformanceSettings()
            // Nazwą performance'u jest nazwa pliku bez rozszerzenia — pola na nią plik nie
            // ma, a oryginał robi dokładnie to samo (`MakePerformanceNameFromFileName`).
            performanceName = url.deletingPathExtension().lastPathComponent
            if let loaded = parsed.performance {
                performance = loaded
                hasPerformanceSettings = true
                // Pole `focus` mówi, na którym slocie performance ma się otworzyć.
                selectedSlot = min(max(loaded.focusedSlot, 0), slots.count - 1)
            }
            forgetFiles()
            performanceFileURL = url
            performanceFileData = data
            focusFirstAssignedParameterPage()
            RecentFiles.remember(url)
        } catch {
            errorMessage = "[\(url.lastPathComponent)]\n\(error.localizedDescription)\n\nTechnical: \(error)"
            print("Parse error for \(url.path): \(error)")
            if let data = try? Data(contentsOf: url) {
                let preview = data.prefix(100).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("First 100 bytes: \(preview)")
            }
        }
    }

    /// File → Open To ▸ Slot X. Clavia `HandleMenuFileOpenTo(slot)`: okno wyboru pliku,
    /// sprawdzenie File Data (GetFileType)() == 1 (**tylko patch**, performance odpada) i
    /// `CreatePerformancePatchFromFile(topPerformance, slot, …)` — wczytany patch wchodzi do
    /// wskazanego slotu, a pozostałe trzy grają dalej.
    ///
    /// Plik staje się plikiem tego slotu (Save pisze do niego), a `.prf2`, jeśli jest otwarty,
    /// zostaje plikiem performance'u — Save Performance zapisze go już z nowym slotem.
    /// Focus przenosimy na slot z tego samego powodu co w `newPatch(inSlot:)`.
    public func load(url: URL, intoSlot slot: Int) {
        guard slots.indices.contains(slot) else { return }
        guard url.pathExtension.lowercased() == "pch2" else {
            errorMessage = "Open To takes a single patch (.pch2).\nSelected: \(url.lastPathComponent)"
            return
        }
        clearMutations()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard var patch = try PatchParser.parseFile(data: data).patches.first else { return }
            patch.fillMissingParameters()
            // `.pch2` nie niesie nazwy patcha — u oryginału slot nazywa się jak plik. To samo
            // robi już wysyłka do Norda (`performUpload`), a w `.prf2` nazwę trzyma sekcja 0x11.
            if patch.name.isEmpty {
                patch.name = String(url.deletingPathExtension().lastPathComponent.prefix(16))
            }
            slots[slot] = patch
            slotFileData[slot] = data
            slotFileURLs[slot] = url
            markSlotSaved(slot)
            if hasPerformanceSettings, performance.slots.indices.contains(slot) {
                performance.slots[slot].name = patch.name
            }
            if !isLoaded { fileName = url.lastPathComponent }
            mirrorsDevice = false
            selectedSlot = slot
            errorMessage = nil
            resetUndoHistory()
            focusFirstAssignedParameterPage()
            RecentFiles.remember(url)
        } catch {
            errorMessage = "[\(url.lastPathComponent)]\n\(error.localizedDescription)\n\nTechnical: \(error)"
        }
    }

    /// File ▸ Save — patch slotu z focusem do jego `.pch2` (`CPatch::SavePatch`). Bez pliku
    /// menu pyta najpierw o miejsce (`save(as:)`).
    public func save() {
        save(slot: selectedSlot)
    }

    public func save(slot: Int) {
        guard slotFileURLs.indices.contains(slot), let url = slotFileURLs[slot] else {
            errorMessage = "There is no file to save into. Use Save As instead."
            return
        }
        writeSlot(slot, to: url)
    }

    /// „Save As" — patch slotu z focusem do wskazanego `.pch2`, który od tej chwili jest
    /// plikiem tego slotu. Slot bez pliku (nowy patch, zawartość z Norda) dostaje szkielet
    /// z `PatchParser`, więc zapisać da się wszystko, co widać na ekranie.
    public func save(as url: URL) {
        save(slot: selectedSlot, as: url)
    }

    public func save(slot: Int, as url: URL) {
        guard writeSlot(slot, to: url) else { return }
        slotFileURLs[slot] = url
        RecentFiles.remember(url)
    }

    /// File ▸ Save Performance — cztery sloty i nagłówek do otwartego `.prf2`
    /// (`CPerformanceManager::SavePerformance`). Bez pliku menu pyta o miejsce.
    public func savePerformance() {
        guard let url = performanceFileURL else {
            errorMessage = "There is no performance file to save into. Use Save Performance As instead."
            return
        }
        writePerformance(to: url)
    }

    /// Save Performance do wskazanego `.prf2`, który od tej chwili jest plikiem performance'u.
    /// Nazwa performance'u idzie za nazwą pliku, jak u Clavii (`SetPerformanceNameWhenPossible`).
    public func savePerformance(as url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let previousName = performanceName
        performanceName = name
        guard writePerformance(to: url) else {
            performanceName = previousName
            return
        }
        // Nazwa przed URL-em: nagłówek logu USB powstaje w `fileURL.didSet`.
        fileName = url.lastPathComponent
        performanceFileURL = url
        RecentFiles.remember(url)
    }

    /// „Save From ▸ Slot X" (instrukcja, str. 116) — jeden slot jako osobny plik `.pch2`.
    /// Plik slotu zostaje przy swoim: instrukcja mówi wprost „leaving any original Patch
    /// intact on the disk".
    public func saveSlot(_ slot: Int, to url: URL) {
        guard slots.indices.contains(slot) else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try PatchParser.saveAll(originalData: slotFileData[slot] ?? PatchParser.emptyPatchFile,
                                               patches: [slots[slot]])
            try data.write(to: url, options: .atomic)
            RecentFiles.remember(url)
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    /// „Save InitPatch1 & 2" (instrukcja, str. 116) — bieżący patch jako szablon,
    /// który przyciski „Init 1"/„Init 2" wczytują jednym kliknięciem.
    public func saveInitPatch(slot: Int) {
        do {
            let data = try PatchParser.saveAll(
                originalData: slotFileData[selectedSlot] ?? PatchParser.emptyPatchFile,
                patches: [patch]
            )
            if !InitPatchLibrary.store(data, slot: slot) {
                errorMessage = "Could not write Init Patch \(slot)."
            }
        } catch {
            errorMessage = "Could not build Init Patch \(slot): \(error.localizedDescription)"
        }
    }

    /// Przycisk „Init 1"/„Init 2" — szablon wchodzi do slotu z focusem, tak jak
    /// otwarcie pliku „Open To ▸". Bez zapisanego szablonu nic się nie dzieje. Szablon nie
    /// zostaje plikiem slotu — inaczej ⌘S nadpisałby go edytowanym patchem.
    public func recallInitPatch(slot: Int) {
        guard let url = InitPatchLibrary.url(slot),
              FileManager.default.fileExists(atPath: url.path)
        else {
            errorMessage = "Init Patch \(slot) has not been saved yet."
            return
        }
        let target = selectedSlot
        let before = slotContents(target)
        load(url: url, intoSlot: target)
        guard slotFileURLs[target] == url else { return } // szablonu nie dało się wczytać
        slotFileURLs[target] = nil
        registerSlotRestore(before, slot: target, actionName: "Init Patch \(slot)")
    }

    /// Nazwa proponowana w oknie zapisu slotu.
    public var suggestedFileName: String {
        suggestedFileName(slot: selectedSlot)
    }

    public func suggestedFileName(slot: Int) -> String {
        let name = slots.indices.contains(slot) ? slots[slot].name : ""
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.emptyPatchName : trimmed
    }

    /// Nazwa proponowana w oknie zapisu performance'u.
    public var suggestedPerformanceFileName: String {
        let trimmed = performanceName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.emptyPerformanceName : trimmed
    }

    /// Zapis jednego slotu jako `.pch2`: na bajtach jego pliku, a bez niego na szkielecie.
    @discardableResult
    private func writeSlot(_ slot: Int, to url: URL) -> Bool {
        guard slots.indices.contains(slot) else { return false }
        let original = slotFileData[slot] ?? PatchParser.emptyPatchFile
        guard !original.isEmpty else {
            errorMessage = "The empty-file template is missing, so there is nothing to save into."
            return false
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let newData = try PatchParser.saveAll(originalData: original, patches: [slots[slot]])
            try newData.write(to: url, options: .atomic)
            slotFileData[slot] = newData
            markSlotSaved(slot)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    /// Zapis `.prf2`. Bez pliku źródłowego bierzemy pusty szkielet, a `saveAll` wpisuje w niego
    /// to, co jest w modelu — łącznie z ustawieniami performance'u, nawet gdy nie przyszły
    /// z pliku (zawartość odczytana z Norda): sekcja `0x11` szkieletu jest pusta, więc bez
    /// tego nowy plik nie miałby ani nazw slotów, ani zegara.
    @discardableResult
    private func writePerformance(to url: URL) -> Bool {
        let original = performanceFileData ?? PatchParser.emptyPerformanceFile
        guard !original.isEmpty else {
            errorMessage = "The empty-file template is missing, so there is nothing to save into."
            return false
        }
        let settings = (hasPerformanceSettings || performanceFileData == nil) ? performance : nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let newData = try PatchParser.saveAll(originalData: original, patches: slots,
                                                  performance: settings)
            try newData.write(to: url, options: .atomic)
            performanceFileData = newData
            markPerformanceSaved()
            // Sloty bez własnego pliku mieszkają teraz w `.prf2` — są zapisane.
            for slot in slots.indices where slotFileURLs[slot] == nil {
                markSlotSaved(slot)
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    /// Plik nie przechowuje aktywnej strony. Po otwarciu wybieramy pierwszą stronę,
    /// która rzeczywiście ma przypisanie, żeby użytkownik nie dostał pustego A1 przy
    /// poprawnie wczytanej mapie zaczynającej się np. od B2.
    public func focusFirstAssignedParameterPage() {
        let index = slots.indices.contains(selectedSlot)
            ? slots[selectedSlot].knobAssignments.firstIndex(where: { $0 != nil })
            : nil
        let page = (index ?? 0) / G2KnobPages.knobsPerPage
        guard storedParameterPage != page else { return }
        // Dotyczy zawsze strony PATCHA — mapa globalna należy do performance'u i wczytanie
        // patcha jej nie rusza. Gdy okno pokazuje właśnie ją, Nord nie ma się o czym dowiadywać.
        storedParameterPage = page
        guard !applyingDeviceParameterPage, !showsGlobalParameterPages else { return }
        onParameterPageChange?(selectedSlot, page, false)
    }
}
