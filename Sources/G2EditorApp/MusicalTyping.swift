// MusicalTyping.swift
// Caps Lock zamienia klawiaturę komputera w klawiaturę do grania — jak „Musical Typing”
// w Logic. Nasłuch żyje na poziomie aplikacji, nie w oknie Virtual Keyboard: użytkownik
// chce grać także przy zamkniętym oknie. Okno, gdy jest otwarte, czyta stąd, które nuty
// brzmią i pod którymi literami, i rysuje to na klawiszach.
//
// Układ liter i kody klawiszy → `KeyboardLayout` (G2EditorCore, sprawdzane testem).
// Każda litera idzie osobno; czy akord zabrzmi, zależy od drogi do syntezatora
// (`DeviceConnection.playNote`: wirtualny G2 gra akordy, Nord przez USB jedną nutę).

import AppKit
import G2EditorCore
import Observation

@MainActor
@Observable
final class MusicalTyping {
    /// Caps Lock włączony — litery grają nuty, a skróty jednoliterowe czekają.
    private(set) var isOn = false
    /// Nuty trzymane literami (może być kilka naraz).
    private(set) var notes: Set<UInt8> = []
    /// Ostatnia nuta z liter — okno stawia na niej kropkę, tak jak po myszy.
    private(set) var lastNote: UInt8?
    /// Najniższa nuta pod literami (zawsze C). Z/X przesuwa o oktawę; pamiętane między
    /// uruchomieniami, bo to ta sama „pozycja rąk” co przesunięcie widoku klawiatury.
    private(set) var base: Int

    /// Okno Virtual Keyboard z włączonym Drone przejmuje puszczaną nutę: `true` = nuta ma
    /// brzmieć dalej, więc „note off” nie idzie.
    var releaseHook: ((UInt8) -> Bool)?

    private var device: DeviceConnection?
    private var monitor: Any?
    private static let baseKey = "g2_keyboard_typing_base"

    init() {
        base = UserDefaults.standard.object(forKey: Self.baseKey) as? Int ?? 48
    }

    /// Ile półtonów od `base` pokrywają litery — do rysowania i do sprawdzania, czy klawisz
    /// ma literę.
    var span: Int {
        KeyboardLayout.typingSpan
    }

    func label(for note: UInt8) -> String? {
        guard isOn else { return nil }
        return KeyboardLayout.typingLabel(offset: Int(note) - base)
    }

    /// Czy ten kod klawisza należy do klawiatury muzycznej (litery nut oraz Z/X). Monitory
    /// skrótów pytają o to, żeby przy włączonym Caps Locku nie przechwycić „A” jako slotu A.
    static func claims(keyCode: UInt16) -> Bool {
        keyCode == KeyboardLayout.typingOctaveDownKeyCode
            || keyCode == KeyboardLayout.typingOctaveUpKeyCode
            || KeyboardLayout.typingKey(forCode: keyCode) != nil
    }

    func start(device: DeviceConnection) {
        self.device = device
        guard monitor == nil else { return }
        isOn = NSEvent.modifierFlags.contains(.capsLock)
        let events: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            let on = event.modifierFlags.contains(.capsLock)
            if on != isOn {
                isOn = on
                if !on { releaseAll() }
            }
            return event
        }
        // ⌘S ma dalej zapisywać, a litera wpisywana w pole nazwy ma się wpisać.
        guard isOn, event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
              !isEditingText(event.window ?? NSApp.keyWindow)
        else { return event }

        if event.keyCode == KeyboardLayout.typingOctaveDownKeyCode
            || event.keyCode == KeyboardLayout.typingOctaveUpKeyCode
        {
            if event.type == .keyDown, !event.isARepeat {
                shiftOctave(event.keyCode == KeyboardLayout.typingOctaveUpKeyCode ? 12 : -12)
            }
            return nil
        }
        guard let key = KeyboardLayout.typingKey(forCode: event.keyCode) else { return event }
        let note = base + key.offset
        guard (0 ... 127).contains(note) else { return nil }
        switch event.type {
        case .keyDown where !event.isARepeat:
            press(UInt8(note))
        case .keyUp:
            release(UInt8(note))
        default:
            break
        }
        return nil
    }

    private func isEditingText(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSText || responder is NSTextView || responder is NSTextField
    }

    private func press(_ note: UInt8) {
        guard !notes.contains(note) else { return }
        notes.insert(note)
        lastNote = note
        device?.playNote(note, on: true)
    }

    private func release(_ note: UInt8) {
        guard notes.remove(note) != nil else { return }
        if releaseHook?(note) == true { return }
        device?.playNote(note, on: false)
    }

    /// Caps Lock zgaszony w trakcie akordu albo zamknięcie aplikacji — Nord nie może
    /// zostać z wiszącymi nutami.
    func releaseAll() {
        for note in notes { device?.playNote(note, on: false) }
        notes = []
    }

    /// Z/X, a także przyciski oktawy w oknie Virtual Keyboard.
    func shiftOctave(_ delta: Int) {
        releaseAll()
        base = max(0, min(108, base + delta))
        UserDefaults.standard.set(base, forKey: Self.baseKey)
    }
}
