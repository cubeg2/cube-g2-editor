// USBLogFile.swift
// Log transportu USB. Sam `print` trafia tam, skąd aplikacja została uruchomiona (konsola
// Xcode albo terminal) — czyli w praktyce donikąd, gdy trzeba komuś pokazać, co się
// wydarzyło. Plik jest zawsze w tym samym miejscu i można go po prostu wysłać:
// ~/Library/Logs/G2Editor/usb.log
//
// Zbieranie chodzi CAŁY CZAS, zapisywanie do pliku nie. Zawieszki zgłasza się z natury
// rzeczy po fakcie („kliknąłem i stanęło"), a przełącznik „USB Log" włączony po fakcie
// zapisywał dopiero to, co działo się PO nim — czyli już nie to, co zawiesiło urządzenie
// (2026-09-19). Dlatego każda linia ląduje w pierścieniu w pamięci, a włączenie logu
// przepisuje pierścień do pliku razem z oryginalnymi godzinami.

import Foundation

/// `@unchecked Sendable` + zamek: linie przychodzą z aktora USB, a plik jest jeden.
public final class USBLogFile: @unchecked Sendable {
    public static let shared = USBLogFile()

    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/G2Editor/usb.log")

    /// Ile linii trzyma pierścień. 20 000 to przy typowym ruchu kilkanaście minut sesji
    /// i ok. 2 MB — tanio jak na jedyny sposób, żeby zobaczyć chwilę PRZED awarią.
    /// Strumienia wskaźników (VU/LED, ~40 linii/s) tu nie ma: włącza go osobno
    /// `setLogNotifications` i tylko on potrafi ten pierścień zalać.
    public static let ringCapacity = 20000

    /// Ścieżka tej instancji. `shared` pisze pod `USBLogFile.url`; test podstawia własną,
    /// bo inaczej sprawdzenie nagłówka skasowałoby log użytkownika.
    private let file: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var ring: [String] = []
    private var ringStart = 0
    private let capacity: Int
    /// `print` kosztuje na tym samym torze, którym lecą komendy USB, więc echo na konsolę
    /// idzie tylko przy włączonym logu. Zbieranie do pamięci jest od tego niezależne.
    private var echoToConsole = false
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init(file: URL = USBLogFile.url, capacity: Int = USBLogFile.ringCapacity) {
        self.file = file
        self.capacity = max(1, capacity)
    }

    /// Otwiera plik od nowa (poprzedni zostaje jako `usb-previous.log`) i przepisuje do
    /// niego wszystko, co zdążyło się nazbierać. Wołane przy WŁĄCZENIU logu, żeby jeden
    /// zapis odpowiadał jednej sesji diagnostycznej.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        echoToConsole = true
        // Ponowne wywołanie przy każdej próbie połączenia (pętla co 2 s, gdy Norda nie ma
        // w gnieździe) nie może obracać pliku od nowa — inaczej log żyje dwie sekundy.
        guard handle == nil else { return }
        let manager = FileManager.default
        let directory = file.deletingLastPathComponent()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if manager.fileExists(atPath: file.path) {
            let previous = directory.appendingPathComponent("usb-previous.log")
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: file, to: previous)
        }
        manager.createFile(atPath: file.path, contents: nil)
        handle = try? FileHandle(forWritingTo: file)
        emit(stamped("=== G2Editor USB log, start \(Date()) ==="))
        emit(stamped("=== \(patchLine) ==="))
        flushRepeats()
        let history = snapshot()
        if history.isEmpty {
            emit(stamped("=== nothing went over USB before the log was switched on ==="))
        } else {
            emit(stamped("=== \(history.count) lines from before the log was switched on, with their times ==="))
            for line in history { emit(line) }
            emit(stamped("=== end of history, live from here ==="))
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        flushRepeats()
        emit(stamped("=== end of log \(Date()) ==="))
        echoToConsole = false
        try? handle?.close()
        handle = nil
    }

    /// Który dokument stoi w edytorze — nagłówek logu i osobna linia przy każdej zmianie.
    ///
    /// Bez tego log mówi, CO poszło po kablu, ale nie NA CZYM: przy zawieszce urządzenia
    /// (albo emulatora) pierwsze pytanie brzmi „na którym patchu", a odpowiedzi nie było
    /// nigdzie — nazwa pliku żyła tylko w tytule okna (2026-09-19). Ścieżka jest pełna,
    /// żeby dało się ten sam plik otworzyć ponownie i powtórzyć przebieg — ale katalog
    /// domowy skrócony do `~`: testerzy wysyłają log publicznie, a pełna ścieżka zdradza
    /// nazwę użytkownika macOS (2026-10-15).
    public func setPatch(name: String, path: String?) {
        lock.lock()
        defer { lock.unlock() }
        let shownName = name.isEmpty ? "(untitled)" : name
        let shownPath = path.map { ($0 as NSString).abbreviatingWithTildeInPath }
            ?? "no file on disk (new patch or read from the G2)"
        patchLine = "PATCH: \(shownName) — \(shownPath)"
        flushRepeats()
        let line = stamped("=== \(patchLine) ===")
        remember(line)
        emit(line)
    }

    /// Zapamiętane, bo log można włączyć długo po otwarciu pliku — wtedy nagłówek
    /// i tak ma powiedzieć, co jest wczytane.
    private var patchLine = "PATCH: nothing loaded"

    public func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        // Zepsuty strumień potrafi nadawać jedną i tę samą skargę kilkadziesiąt razy na
        // sekundę: w zgłoszeniu z 2026-09-23 osiem i pół tysiąca z trzynastu tysięcy linii
        // było identycznych. Zjadały pierścień (więc chwilę PRZED awarią, po którą on w ogóle
        // jest) i robiły z pliku ścianę nie do przeczytania. Powtórzenia zliczamy.
        if line == lastLine {
            repeats += 1
            return
        }
        flushRepeats()
        lastLine = line
        let stampedLine = stamped(line)
        remember(stampedLine)
        emit(stampedLine)
    }

    /// Pierścień od najstarszej linii — co edytor widział na USB w tej sesji.
    public func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        flushRepeats()
        return snapshot()
    }

    // MARK: - Prywatne (zakładają trzymany zamek)

    /// Ostatnia linia bez godziny i ile razy powtórzyła się od tamtej pory.
    private var lastLine: String?
    private var repeats = 0

    /// Zamyka serię powtórzeń jedną linią z licznikiem. Wołane przed każdą nową linią
    /// i przed każdym odczytem logu, żeby trwająca seria nie zniknęła z raportu.
    private func flushRepeats() {
        guard repeats > 0 else { return }
        let summary = stamped("    … previous line repeated \(repeats) more times")
        repeats = 0
        remember(summary)
        emit(summary)
    }

    private func snapshot() -> [String] {
        Array(ring[ringStart...] + ring[..<ringStart])
    }

    private func stamped(_ line: String) -> String {
        "\(stamp.string(from: Date())) \(line)"
    }

    private func remember(_ stampedLine: String) {
        if ring.count < capacity {
            ring.append(stampedLine)
        } else {
            ring[ringStart] = stampedLine
            ringStart = (ringStart + 1) % capacity
        }
    }

    private func emit(_ stampedLine: String) {
        if echoToConsole { print("[G2] \(stampedLine)") }
        guard let handle else { return }
        try? handle.write(contentsOf: Data("\(stampedLine)\n".utf8))
    }
}
