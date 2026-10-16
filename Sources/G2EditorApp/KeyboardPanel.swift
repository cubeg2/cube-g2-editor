// KeyboardPanel.swift
// Zawartość okna „Virtual Keyboard” — zagranie nuty z edytora, bez sięgania po klawisze Norda.
//
// Nuta idzie komendą `0x56` Play Note (patrz `G2UsbProtocol.playNotePayload`), czyli tą
// samą, której używa oryginalny edytor. To nie MIDI: komunikat jest systemowy, więc nutę
// dostają wszystkie sloty, które mają klawiaturę.
//
// Układ za instrukcją Clavii (str. 128, „Virtual Keyboard”): cztery przyciski
// przesuwania z lewej — o oktawę (podwójna strzałka) i o półton (pojedyncza) —
// „Drone” i „Repeat”, a na ostatnio zagranym klawiszu kropka („the selected note will be
// indicated by a black dot”). Od 2026-09-21 do tego: przewijanie widoku przeciągnięciem
// klawiszy w bok, litery klawiatury komputera przy włączonym Caps Locku (`MusicalTyping`),
// nazwy oktaw na klawiszach C i klamra nad zakresem 37 klawiszy Norda. Od 2026-09-25
// wybór akordu: klik myszą gra cały akord od klikniętego klawisza (`KeyboardChord`).
//
// Geometria klawiszy i mapa liter → `KeyboardLayout` (G2EditorCore).

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

struct KeyboardPanel: View {
    let device: DeviceConnection
    let state: PatchState
    let typing: MusicalTyping

    /// Najniższy widoczny klawisz jako numer MIDI. Nord ma 37 klawiszy od C2 (36),
    /// więc od tego zaczynamy. Pokazujemy **pięć oktaw** — mieszczą cały zakres
    /// sprzętu i jeszcze trochę zapasu, a okno ma stałą szerokość, więc klawisze
    /// nie pływają. Instrukcja pozwala przesuwać widok i o oktawę, i o pojedynczą
    /// nutę, dlatego trzymamy tu półtony, a nie numer oktawy.
    @AppStorage("g2_keyboard_low_note") private var lowestNote: Int = 36
    private static let octaveCount = 5
    /// Wysokość klawiszy — oryginał ma ok. 35 pt, u nas było 104; 64 mieści literę i kropkę.
    static let keyHeight: CGFloat = 64
    /// Pasek nad klawiszami na klamrę zakresu Norda.
    static let rangeStripHeight: CGFloat = 12
    static let headerHeight: CGFloat = 22

    /// Nuty trzymane myszą (jedna albo cały akord, pryma pierwsza). Puszczenie przycisku
    /// musi wysłać „note off” dokładnie tym nutom, które wcześniej włączyło — inaczej Nord
    /// zostaje z wiszącym dźwiękiem.
    @State private var heldNotes: [UInt8] = []
    /// Co gra jedno kliknięcie: pojedyncza nuta albo akord od klikniętego klawisza.
    @AppStorage("g2_keyboard_chord") private var chordRaw = KeyboardChord.single.rawValue
    /// „Drone” — następna zagrana nuta (albo akord) zostaje włączona po puszczeniu myszy
    /// („start sounding infinitely”). Ponowny klik przycisku ją gasi.
    @State private var droneEnabled = false
    @State private var droningNotes: [UInt8] = []
    /// „Repeat” — ostatnia nuta gra w kółko. Instrukcja nie podaje tempa (oryginalny
    /// edytor ma sztywne 1 s dźwięku / 1 s ciszy), więc bierzemy je z zegara głównego:
    /// jedno uderzenie na ćwierćnutę. `repeatSounding` zapala klawisz w rytm.
    @State private var repeatEnabled = false
    @State private var repeatTask: Task<Void, Never>?
    @State private var repeatSounding = false
    /// Ostatnio zagrana pryma — na niej stoi kropka.
    @State private var lastNote: UInt8?
    /// Ostatnio zagrane nuty razem — tyle powtarza „Repeat”.
    @State private var lastNotes: [UInt8] = []
    /// Przeciąganie w bok: start widoku w chwili, gdy ruch przestał być kliknięciem.
    @State private var dragOrigin: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                scrollControls
                chordPicker
                droneAndRepeat
                Text(noteLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if device.status != .connected {
                    Text("No G2 connected — keys will not sound.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                typingBadge
            }
            .frame(height: Self.headerHeight)
            keyboard
                .frame(height: Self.rangeStripHeight + Self.keyHeight)
        }
        .padding(10)
        .onAppear { typing.releaseHook = takeOverReleasedNote }
        .onDisappear { stopEverything() }
        // Z/X przesunęło oktawę liter — litery mają zostać w polu widzenia.
        .onChange(of: typing.base) { _, base in revealTypingOctave(base) }
    }

    // MARK: - Przesuwanie widoku

    /// „The four buttons to the left are used to scroll up and down the keyboard,
    /// either one octave (the double-arrow buttons) or one note (the single-arrow
    /// buttons) at a time.” (instrukcja, str. 128)
    private var scrollControls: some View {
        HStack(spacing: 3) {
            scrollButton("chevron.left.2", by: -12, hint: "Down one octave")
            scrollButton("chevron.left", by: -1, hint: "Down one note")
            Text(Self.noteName(UInt8(lowestNote)))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 34)
            scrollButton("chevron.right", by: 1, hint: "Up one note")
            scrollButton("chevron.right.2", by: 12, hint: "Up one octave")
        }
    }

    /// Najwyższy dopuszczalny start widoku — pięć oktaw musi się jeszcze zmieścić
    /// w zakresie MIDI.
    private static let highestStart = 127 - octaveCount * 12

    private static func clampedStart(_ note: Int) -> Int {
        max(0, min(highestStart, note))
    }

    private func scrollButton(_ symbol: String, by semitones: Int, hint: String) -> some View {
        let target = lowestNote + semitones
        return Button {
            lowestNote = Self.clampedStart(target)
            // Przycisk oktawy przesuwa też litery — inaczej widok jedzie, a litery grają
            // dalej starą oktawę.
            if abs(semitones) == 12 { typing.shiftOctave(semitones) }
        } label: {
            Image(systemName: symbol).font(.system(size: 9))
        }
        .buttonStyle(.borderless)
        .disabled(target < 0 || target > Self.highestStart)
        .help(hint)
    }

    /// Litery zaczynają się na C bazowej oktawy; gdy nie mieszczą się w widoku, widok
    /// jedzie tak, żeby stały w środku.
    private func revealTypingOctave(_ base: Int) {
        let visible = lowestNote ... lowestNote + Self.octaveCount * 12 - 1
        guard !(visible.contains(base) && visible.contains(base + typing.span - 1)) else { return }
        lowestNote = Self.clampedStart(base - 12)
    }

    // MARK: - Akord

    private var chord: KeyboardChord {
        KeyboardChord(rawValue: chordRaw) ?? .single
    }

    private var chordPicker: some View {
        Picker("Chord", selection: $chordRaw) {
            ForEach(KeyboardChord.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("What one mouse click plays: a single note, or a chord built on the clicked key. "
            + "With Caps Lock on, hold several letter keys to play any chord.")
    }

    // MARK: - Drone i Repeat

    private var droneAndRepeat: some View {
        HStack(spacing: 4) {
            toggleButton("Drone", on: droneEnabled) {
                droneEnabled.toggle()
                if !droneEnabled { stopDrone() }
            }
            .help("The next key you play keeps sounding until Drone is switched off")

            toggleButton("Repeat", on: repeatEnabled) {
                repeatEnabled.toggle()
                if repeatEnabled { startRepeat() } else { stopRepeat() }
            }
            .help("Repeat the last played note at the master clock tempo")
        }
    }

    private func toggleButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: on ? .semibold : .regular))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(on ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var typingBadge: some View {
        if typing.isOn {
            Text("Typing ON · \(Self.noteName(UInt8(typing.base)))–\(Self.noteName(UInt8(typing.base + typing.span - 1))) · Z/X octave")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .help("Caps Lock is on: A–' play white keys, W–P black keys, Z/X move the octave")
        } else {
            Text("Caps Lock: play with computer keys")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// Ćwierćnuta zegara głównego — bez podłączonego Norda bierzemy tempo
    /// z otwartego performance'u, a w ostateczności 120 BPM.
    private var repeatInterval: Double {
        let bpm = device.status == .connected
            ? device.clockBPM
            : (state.hasPerformanceSettings ? state.performance.masterClock : nil)
        return 60.0 / Double(max(30, min(240, bpm ?? 120)))
    }

    private func startRepeat() {
        stopRepeat()
        repeatTask = Task { @MainActor in
            while !Task.isCancelled {
                let notes = lastNotes
                if !notes.isEmpty, heldNotes.isEmpty, droningNotes.isEmpty, typing.notes.isEmpty {
                    repeatSounding = true
                    for note in notes { device.playNote(note, on: true) }
                    try? await Task.sleep(nanoseconds: UInt64(repeatInterval * 0.4 * 1_000_000_000))
                    for note in notes { device.playNote(note, on: false) }
                    repeatSounding = false
                    try? await Task.sleep(nanoseconds: UInt64(repeatInterval * 0.6 * 1_000_000_000))
                } else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
        repeatSounding = false
        for note in lastNotes { device.playNote(note, on: false) }
    }

    private func stopDrone() {
        for note in droningNotes { device.playNote(note, on: false) }
        droningNotes = []
    }

    /// Zamknięcie okna nie może zostawić Norda z wiszącym dźwiękiem. Litery grają dalej —
    /// to sprawa `MusicalTyping`, nie okna — ale bez okna nie ma już Drone'a, który by je
    /// przejmował.
    private func stopEverything() {
        stopRepeat()
        stopDrone()
        release()
        repeatEnabled = false
        dragOrigin = nil
        typing.releaseHook = nil
    }

    // MARK: - Klawisze

    private var keyboard: some View {
        GeometryReader { geo in
            let keys = KeyboardLayout.keys(lowest: lowestNote, octaves: Self.octaveCount,
                                           width: geo.size.width, height: Self.keyHeight)
            let whiteWidth = geo.size.width / CGFloat(Self.octaveCount * 7)
            ZStack(alignment: .topLeading) {
                rangeBracket(keys: keys)
                ForEach(keys.filter { !$0.isBlack }) { keyView($0) }
                ForEach(keys.filter(\.isBlack)) { keyView($0) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            // Jeden gest na całą klawiaturę, nie na klawisz: przy przewijaniu klawisze
            // przebudowują się pod myszą, a gest na kontenerze to przeżyje.
            // `minimumDistance: 0` — dźwięk ma iść od naciśnięcia, nie od przeciągnięcia.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragChanged(value, keys: keys, whiteWidth: whiteWidth) }
                    .onEnded { _ in dragEnded() }
            )
        }
    }

    /// Cienka klamra nad klawiszami, które istnieją na Nordzie (37 klawiszy, C2–C5).
    /// Ząbki tylko na prawdziwych końcach — gdy widok ucina zakres, klamra też jest ucięta.
    @ViewBuilder private func rangeBracket(keys: [KeyboardLayout.Key]) -> some View {
        let range = KeyboardLayout.g2KeyRange
        let visible = keys.filter { !$0.isBlack && range.contains(Int($0.note)) }
        if let first = visible.first, let last = visible.last {
            let x0 = first.rect.minX + 1
            let x1 = last.rect.maxX
            Path { path in
                path.move(to: CGPoint(x: x0, y: Int(first.note) == range.lowerBound ? 6 : 10))
                path.addLine(to: CGPoint(x: x0, y: 10))
                path.addLine(to: CGPoint(x: x1, y: 10))
                path.addLine(to: CGPoint(x: x1, y: Int(last.note) == range.upperBound ? 6 : 10))
            }
            .stroke(Color.secondary.opacity(0.7), lineWidth: 1)
            Text("G2 keys C2–C5")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
                .offset(x: x0 + 4, y: 0)
        }
    }

    private func keyView(_ key: KeyboardLayout.Key) -> some View {
        let sounding = isSounding(key.note)
        let letter = typing.label(for: key.note)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2)
                .fill(fill(black: key.isBlack, sounding: sounding))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.5), lineWidth: 0.5))
            VStack(spacing: 2) {
                if lastNote == key.note || typing.lastNote == key.note {
                    Circle()
                        .fill(key.isBlack || sounding ? Color.white : Color.black)
                        .frame(width: 4, height: 4)
                }
                if let letter {
                    // Litera zastępuje nazwę oktawy — bazowe C liter jest zawsze widoczne w belce.
                    Text(letter)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(key.isBlack || sounding ? Color.white : Color.black)
                } else if key.note % 12 == 0 {
                    Text(Self.noteName(key.note))
                        .font(.system(size: 7))
                        .foregroundStyle(sounding ? Color.white : Color.secondary)
                }
            }
            .padding(.bottom, 3)
        }
        .frame(width: key.rect.width, height: key.rect.height)
        .offset(x: key.rect.minX, y: key.rect.minY + Self.rangeStripHeight)
    }

    private func isSounding(_ note: UInt8) -> Bool {
        heldNotes.contains(note) || droningNotes.contains(note) || typing.notes.contains(note)
            || (repeatSounding && lastNotes.contains(note))
    }

    private func fill(black: Bool, sounding: Bool) -> Color {
        if sounding { return Color.accentColor }
        return black ? Color(white: 0.12) : Color(white: 0.92)
    }

    // MARK: - Mysz: naciśnięcie, przeciągnięcie w bok, puszczenie

    private func dragChanged(_ value: DragGesture.Value, keys: [KeyboardLayout.Key], whiteWidth: CGFloat) {
        if let dragOrigin {
            // Tryb przewijania: rysunek jedzie za myszą, jeden biały klawisz na szerokość klawisza.
            let shift = Int((value.translation.width / whiteWidth).rounded())
            lowestNote = Self.clampedStart(KeyboardLayout.shifted(dragOrigin, byWhiteKeys: -shift))
            return
        }
        if heldNotes.isEmpty {
            let point = CGPoint(x: value.startLocation.x, y: value.startLocation.y - Self.rangeStripHeight)
            if let note = KeyboardLayout.note(at: point, in: keys) { press(note) }
        }
        // Kilka punktów w bok to już nie kliknięcie: nuta gaśnie (bez robienia z niej
        // dronu), a dalszy ruch przewija klawiaturę.
        if abs(value.translation.width) > 6 {
            cancelHeld()
            dragOrigin = lowestNote
        }
    }

    private func dragEnded() {
        release()
        dragOrigin = nil
    }

    private func press(_ root: UInt8) {
        guard heldNotes.first != root else { return }
        release()
        let notes = chord.notes(root: root)
        heldNotes = notes
        lastNote = root
        lastNotes = notes
        for note in notes { device.playNote(note, on: true) }
    }

    /// Puszczenie klawisza. Przy włączonym „Drone” nuty zostają włączone i przejmują
    /// rolę dronu — poprzedni dron gaśnie, bo instrukcja mówi o JEDNEJ trzymanej nucie
    /// (u nas: jednym trzymanym kliknięciu, czyli także całym akordzie).
    private func release() {
        guard !heldNotes.isEmpty else { return }
        let notes = heldNotes
        heldNotes = []
        if !holdAsDrone(notes) { for note in notes { device.playNote(note, on: false) } }
    }

    /// Nuta puszczona literą przy włączonym Drone brzmi dalej tak samo jak puszczona myszą.
    private func takeOverReleasedNote(_ note: UInt8) -> Bool {
        lastNote = note
        lastNotes = [note]
        return holdAsDrone([note])
    }

    private func holdAsDrone(_ notes: [UInt8]) -> Bool {
        guard droneEnabled else { return false }
        for note in droningNotes where !notes.contains(note) { device.playNote(note, on: false) }
        droningNotes = notes
        return true
    }

    private func cancelHeld() {
        for note in heldNotes { device.playNote(note, on: false) }
        heldNotes = []
    }

    private static func noteName(_ note: UInt8) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 1)"
    }

    private var noteLabel: String {
        if !typing.notes.isEmpty {
            return typing.notes.sorted().map(Self.noteName).joined(separator: " ")
        }
        if let root = heldNotes.first {
            return heldNotes.count == 1
                ? "\(Self.noteName(root))  ·  MIDI \(root)"
                : "\(Self.noteName(root)) \(chord.title)  ·  " + heldNotes.map(Self.noteName).joined(separator: " ")
        }
        if !droningNotes.isEmpty {
            return "Drone " + droningNotes.map(Self.noteName).joined(separator: " ")
        }
        return "\(Self.octaveCount) octaves"
    }
}
