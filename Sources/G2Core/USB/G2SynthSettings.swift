// G2SynthSettings.swift
// Ustawienia SAMEGO URZĄDZENIA — to, co oryginał pokazuje w oknie „Synth Settings"
// (Synth Settings dialog): nazwa Norda, kanały MIDI slotów, kanał globalny, SysEx ID,
// strojenie, zegar, pedał, Memory Protect. W pliku patcha ani performance'u tego NIE MA;
// jedynym źródłem jest urządzenie (Synth Data Request 0x02 → Synth Data Dump 0x03).
//
// Układ bajtów pochodzi z Synth Map (WriteStream)/`ReadStream` oryginalnego edytora Clavii
// i zgadza się bajt w bajt z `TG2Synth.ProcessMsgSynthSettings` u BVerhue oraz
// z `parse_synth_settings` w G2-Edit (ten ostatni gubi jeden bajt wypełniacza,
// bo czyta nazwę jako 11 znaków stałej długości) → [[Docs/usb/synth-settings]].

import Foundation

/// Ustawienia urządzenia odczytane komendą `0x02`. Wszystkie pola są takie, jak
/// POKAZUJE je oryginalne okno — numery kanałów liczone od 1, strojenie ze znakiem —
/// a nie takie, jak leżą w bajtach; przeliczenie siedzi w koderze.
public struct G2SynthSettings: Equatable, Sendable {
    /// Kanał MIDI jednego slotu. `active == false` to bajt 0x10 w strumieniu: slot nie
    /// słucha MIDI. Numer kanału zostaje wtedy w oknie (jest co zaznaczyć z powrotem),
    /// ale do urządzenia nie jedzie — dokładnie jak w Synth Map (WriteStream).
    public struct SlotMidi: Equatable, Sendable {
        public var channel: Int // 1…16
        public var active: Bool

        public init(channel: Int, active: Bool) {
            self.channel = channel
            self.active = active
        }
    }

    public var name: String = ""
    public var slots: [SlotMidi] = (0 ..< 4).map { SlotMidi(channel: $0 + 1, active: true) }
    /// 1…16, `nil` = „Off" (bajt 0x10).
    public var globalChannel: Int?
    /// 1…16, `nil` = „All" (bajt 0x10).
    public var sysExID: Int?
    public var localOn: Bool = true
    public var programChangeReceive: Bool = true
    public var programChangeSend: Bool = true
    public var controllersReceive: Bool = true
    public var controllersSend: Bool = true
    public var sendClock: Bool = false
    public var ignoreExternalClock: Bool = false
    /// Strojenie: półtony −6…+6 i centy −100…+100 (zakresy z Synth Settings dialog (SetMasterTune)).
    public var tuneSemi: Int = 0
    public var tuneCent: Int = 0
    public var globalOctaveShiftEnabled: Bool = false
    /// −2…+2 (w oryginale grupa pięciu przycisków, `SetPos(wartość + 2)`).
    public var globalOctaveShift: Int = 0
    /// 0…32 — wyżej Nord przycina do 32 (zmierzone `--pedalgain-sweep`, 2026-09-18);
    /// okno pokazuje mnożnik `x1.00`…`x1.50` (patrz `controlPedalGainLabel`).
    public var controlPedalGain: Int = 0
    /// Pedał sustain: fałsz = „Open", prawda = „Closed".
    public var pedalPolarityClosed: Bool = false
    public var memoryProtect: Bool = false
    /// Czy urządzenie stoi w trybie Performance. Okna nie ma — tryb przestawia się
    /// komendą `0x3E` — ale bit siedzi w tym samym komunikacie i stąd go czytamy.
    public var performanceMode: Bool = false

    public init() {}

    /// Częstotliwość A z półtonów i centów — ten sam wzór co Synth Settings dialog (SetMasterTune)
    /// (`440 · 2^(semi/12) · 2^(cent/1200)`).
    public var masterTuneHz: Double {
        440 * pow(2, Double(tuneSemi) / 12) * pow(2, Double(tuneCent) / 1200)
    }

    /// Etykieta wzmocnienia pedału — ControlPedalGain: `x%2.2f` z `1 + wartość/64`.
    public var controlPedalGainLabel: String {
        String(format: "x%.2f", 1 + Double(controlPedalGain) / 64)
    }
}

public extension G2UsbProtocol {
    /// Najdłuższa nazwa urządzenia — tyle samo, co nazwa performance'u i modułu.
    static let synthNameLength = 16

    // MARK: - Odczyt

    /// Gdzie w payloadzie odpowiedzi `0x03` kończy się nazwa urządzenia. Nazwa jest
    /// **zmiennej długości** (znaki + terminator, przy pełnych 16 znakach bez terminatora)
    /// — ta sama forma, którą przy nazwie performance'u rozstrzygnął sprzęt (#71).
    static func synthSettingsBodyStart(_ payload: [UInt8]) -> Int {
        synthNameSplit(payload).bodyStart
    }

    /// Nazwa i miejsce, w którym zaczyna się reszta komunikatu. Terminator jest w strumieniu
    /// tylko wtedy, gdy nazwa nie zajęła pełnych 16 znaków.
    private static func synthNameSplit(_ payload: [UInt8]) -> (name: String, bodyStart: Int) {
        var end = 0
        while end < payload.count, end < synthNameLength, payload[end] != 0 {
            end += 1
        }
        return (String(decoding: payload[0 ..< end], as: UTF8.self),
                end < synthNameLength ? end + 1 : end)
    }

    /// Pola ustawień, liczone od pierwszego bajtu za nazwą.
    private enum SynthField {
        static let mode = 0 // bit 7; reszta bajtu i cały bajt 1 — nieznane
        static let memoryProtect = 4 // bit 7
        static let slotChannel = 5 // 4 bajty, A…D; 0x10 = slot nie słucha MIDI
        static let globalChannel = 9
        static let sysExID = 10
        static let localOn = 11 // bit 7
        static let programChange = 12 // bit 1 = Receive, bit 0 = Send
        static let controllers = 13 // jak wyżej
        static let clock = 14 // bit 6 = Send Clock, bit 5 = Ignore External Clock
        static let tuneCent = 15 // ze znakiem
        static let octaveShiftEnabled = 16 // bit 7
        static let octaveShift = 17 // ze znakiem
        static let tuneSemi = 18 // ze znakiem
        static let pedalPolarity = 20 // bit 7
        static let controlPedalGain = 21
        /// Tyle bajtów musi być za nazwą, żeby komunikat dał się rozczytać.
        static let count = 22
    }

    /// Bajt 0x10 w polu kanału znaczy „ten slot nie słucha MIDI".
    private static let midiChannelOff: UInt8 = 0x10

    static func decodeSynthSettings(_ payload: [UInt8]) -> G2SynthSettings? {
        let (name, start) = synthNameSplit(payload)
        guard payload.count >= start + SynthField.count else { return nil }
        let body = Array(payload[start...])

        var settings = G2SynthSettings()
        settings.name = name
        settings.performanceMode = body[SynthField.mode] & 0x80 != 0
        settings.memoryProtect = body[SynthField.memoryProtect] & 0x80 != 0
        settings.slots = (0 ..< maxSlots).map { slot in
            let raw = body[SynthField.slotChannel + slot]
            return G2SynthSettings.SlotMidi(channel: raw < midiChannelOff ? Int(raw) + 1 : slot + 1,
                                            active: raw < midiChannelOff)
        }
        settings.globalChannel = channelOrNil(body[SynthField.globalChannel])
        settings.sysExID = channelOrNil(body[SynthField.sysExID])
        settings.localOn = body[SynthField.localOn] & 0x80 != 0
        settings.programChangeReceive = body[SynthField.programChange] & 0x02 != 0
        settings.programChangeSend = body[SynthField.programChange] & 0x01 != 0
        settings.controllersReceive = body[SynthField.controllers] & 0x02 != 0
        settings.controllersSend = body[SynthField.controllers] & 0x01 != 0
        settings.sendClock = body[SynthField.clock] & 0x40 != 0
        settings.ignoreExternalClock = body[SynthField.clock] & 0x20 != 0
        settings.tuneCent = Int(Int8(bitPattern: body[SynthField.tuneCent]))
        settings.globalOctaveShiftEnabled = body[SynthField.octaveShiftEnabled] & 0x80 != 0
        settings.globalOctaveShift = Int(Int8(bitPattern: body[SynthField.octaveShift]))
        settings.tuneSemi = Int(Int8(bitPattern: body[SynthField.tuneSemi]))
        settings.pedalPolarityClosed = body[SynthField.pedalPolarity] & 0x80 != 0
        settings.controlPedalGain = Int(body[SynthField.controlPedalGain])
        return settings
    }

    private static func channelOrNil(_ raw: UInt8) -> Int? {
        raw < midiChannelOff ? Int(raw) + 1 : nil
    }

    // MARK: - Zapis

    /// Nowy payload komunikatu `0x03` — **przepisany z tego, co przyszło z urządzenia**,
    /// z podmienionymi polami okna. Tak samo robi oryginał: Synth Settings dialog (TrySendData)
    /// bierze ostatni znany Synth Map, nakłada na kopię wartości z okna i wysyła całość
    /// (a gdy nic się nie zmieniło — nie wysyła nic). Dzięki temu bajty, których nie
    /// rozumiemy — nieznane bity trybu, bank i numer bieżącego performance'u, wypełniacz —
    /// zostają dokładnie takie, jakie urządzenie samo o sobie powiedziało.
    ///
    /// Zwraca `nil`, gdy wzorzec jest za krótki, żeby był ustawieniami synta.
    static func synthSettingsPayload(applying settings: G2SynthSettings,
                                     to original: [UInt8]) -> [UInt8]?
    {
        let start = synthSettingsBodyStart(original)
        guard original.count >= start + SynthField.count else { return nil }
        var body = Array(original[start...])

        setBit7(&body[SynthField.memoryProtect], settings.memoryProtect)
        for slot in 0 ..< maxSlots where slot < settings.slots.count {
            let midi = settings.slots[slot]
            body[SynthField.slotChannel + slot] = midi.active
                ? UInt8(clamping: midi.channel - 1)
                : midiChannelOff
        }
        body[SynthField.globalChannel] = channelByte(settings.globalChannel)
        body[SynthField.sysExID] = channelByte(settings.sysExID)
        setBit7(&body[SynthField.localOn], settings.localOn)
        body[SynthField.programChange] = modeByte(receive: settings.programChangeReceive,
                                                  send: settings.programChangeSend)
        body[SynthField.controllers] = modeByte(receive: settings.controllersReceive,
                                                send: settings.controllersSend)
        setBit(&body[SynthField.clock], 0x40, settings.sendClock)
        setBit(&body[SynthField.clock], 0x20, settings.ignoreExternalClock)
        body[SynthField.tuneCent] = UInt8(bitPattern: Int8(clamping: settings.tuneCent))
        setBit7(&body[SynthField.octaveShiftEnabled], settings.globalOctaveShiftEnabled)
        body[SynthField.octaveShift] = UInt8(bitPattern: Int8(clamping: settings.globalOctaveShift))
        body[SynthField.tuneSemi] = UInt8(bitPattern: Int8(clamping: settings.tuneSemi))
        setBit7(&body[SynthField.pedalPolarity], settings.pedalPolarityClosed)
        body[SynthField.controlPedalGain] = UInt8(clamping: settings.controlPedalGain)

        return claviaString(settings.name) + body
    }

    private static func channelByte(_ channel: Int?) -> UInt8 {
        guard let channel else { return midiChannelOff }
        return UInt8(clamping: channel - 1)
    }

    /// Tryb odbioru kontrolerów / Program Change: Synth Settings dialog (GetValues) składa
    /// go z dwóch checkboxów jako `Receive · 2 + Send`.
    private static func modeByte(receive: Bool, send: Bool) -> UInt8 {
        (receive ? 0x02 : 0) | (send ? 0x01 : 0)
    }

    private static func setBit7(_ byte: inout UInt8, _ value: Bool) {
        setBit(&byte, 0x80, value)
    }

    private static func setBit(_ byte: inout UInt8, _ mask: UInt8, _ value: Bool) {
        byte = value ? byte | mask : byte & ~mask
    }

    /// Cała ramka „ustaw ustawienia synta". Payload nie ma osobnego bajtu podkomendy
    /// dopisywanego przez nas — Synth Map (WriteStream) sam zaczyna od bajtu typu `0x03`,
    /// tak samo jak nagłówek performance'u zaczyna od `0x11` (patrz `setPerformanceHeaderPayload`).
    ///
    /// Typ komunikatu 0 → urządzenie kwituje `SUB_RESPONSE_OK`.
    /// **Niezweryfikowane na żywym sprzęcie.**
    static func setSynthSettingsPayload(body: [UInt8]) -> [UInt8] {
        [commandTag, commandReqSys, 0x41, subSynthSettingsResponse] + body
    }
}
