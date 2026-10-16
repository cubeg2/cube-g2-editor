// LiveAudioInput.swift
// Drugie źródło dźwięku dla Spectrum i X-Y: dwa wejścia interfejsu audio. Prawdziwy Nord
// dźwięku do edytora nie odsyła — ale jego wyjścia i tak idą zwykle kablem do interfejsu,
// więc wystarczy wskazać, na których wejściach leżą.
//
// Wybór źródła jest jeden dla obu okien (`LiveAudioSource`), a oba okna czytają przez ten
// sam kształt (`LiveAudioReader`) co podsłuch emulatora — analiza nie wie, skąd dźwięk.
//
// Nagrywanie idzie przez AUHAL (sama strona wejścia, bez wyjścia). Mapa kanałów
// (`kAudioOutputUnitProperty_ChannelMap`) wybiera z interfejsu dokładnie dwa wejścia,
// więc przy 18-kanałowej karcie nie kopiujemy szesnastu niepotrzebnych.
//
// ⚠️ macOS pyta o zgodę na mikrofon przy pierwszym nagraniu. Bez zgody system podaje
// ciszę, bez żadnego błędu — okna mówią wtedy, gdzie tę zgodę dać.

import AudioToolbox
import CoreAudio
import Foundation
import os

/// To, czego analiza potrzebuje od źródła dźwięku — podsłuchu emulatora albo wejść interfejsu.
public protocol LiveAudioReader: AnyObject {
    /// Czy dźwięk płynie. `false` = źródło zamknąć i otworzyć na nowo przy następnym tyknięciu.
    var isPlaying: Bool { get }
    var sampleRate: Double { get }
    /// Najświeższe ramki zmiksowane do mona, −1…1.
    func latest(frames wanted: Int) -> [Float]?
    /// Najświeższe ramki osobno dla lewego i prawego kanału, −1…1.
    func latestStereo(frames wanted: Int) -> (left: [Float], right: [Float])?
}

extension LiveAudioTap: LiveAudioReader {}

/// Skąd Spectrum i X-Y biorą dźwięk. Zapisane w `UserDefaults`, wspólne dla obu okien.
public enum LiveAudioSource: Equatable, Sendable {
    case virtualG2
    /// Dwa wejścia urządzenia; kanały liczone od zera (w oknie od jedynki).
    case interface(deviceUID: String, left: Int, right: Int)

    public static let kindKey = "liveAudioSource"
    public static let deviceKey = "liveAudioInputDevice"
    public static let leftKey = "liveAudioInputLeft"
    public static let rightKey = "liveAudioInputRight"
    public static let virtualKind = "virtual"
    public static let interfaceKind = "interface"

    public static var stored: LiveAudioSource {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: kindKey) == interfaceKind,
              let uid = defaults.string(forKey: deviceKey), !uid.isEmpty
        else { return .virtualG2 }
        return .interface(deviceUID: uid,
                          left: defaults.object(forKey: leftKey) as? Int ?? 0,
                          right: defaults.object(forKey: rightKey) as? Int ?? 1)
    }

    public var isInterface: Bool {
        if case .interface = self { return true }
        return false
    }

    /// Otwiera źródło; `nil`, gdy emulator nie gra albo urządzenia nie ma.
    @MainActor
    public func open() -> LiveAudioReader? {
        switch self {
        case .virtualG2:
            LiveAudioTap()
        case let .interface(uid, left, right):
            LiveAudioInput.open(deviceUID: uid, left: left, right: right)
        }
    }
}

/// Dwa wejścia interfejsu audio, nagrywane do pierścienia, z którego czytają okna.
public final class LiveAudioInput: LiveAudioReader {
    /// Urządzenie z wejściami — to, co pokazuje lista w oknach.
    public struct Device: Identifiable, Hashable, Sendable {
        public let uid: String
        public let name: String
        /// Nazwy wejść od sterownika („Analog 1"); puste, gdy ich nie podaje.
        public let channelNames: [String]
        public var id: String { uid }
        public var channels: Int { channelNames.count }
    }

    public let deviceUID: String
    public let left: Int
    public let right: Int
    public let sampleRate: Double

    /// Pierścień: 65 536 ramek stereo, przeplatane L/R. Przy 192 kHz to 0,34 s — okna biorą
    /// z niego najwyżej 8192 ramki, więc piszący nigdy nie dogoni czytanego fragmentu.
    private static let capacity = 1 << 16
    private let ring: UnsafeMutablePointer<Float>
    /// Ramki zapisane od startu i chwila ostatniego wywołania z wątku audio.
    private let progress = OSAllocatedUnfairLock(initialState: (written: UInt64(0), lastCallback: UInt64(0)))
    private let startedAt = DispatchTime.now().uptimeNanoseconds

    private var unit: AudioUnit?
    private let buffers: UnsafeMutableAudioBufferListPointer
    private let maxFrames: Int

    /// Jedno nagranie dla obu okien naraz; znika, gdy oba je puszczą.
    @MainActor private weak static var current: LiveAudioInput?
    /// Nieudana próba — kolejną robimy dopiero po sekundzie, a nie co tyknięcie zegara.
    @MainActor private static var lastFailure: (uid: String, at: Date)?

    @MainActor
    static func open(deviceUID uid: String, left: Int, right: Int) -> LiveAudioInput? {
        if let input = current, input.deviceUID == uid, input.left == left, input.right == right,
           input.isPlaying
        {
            return input
        }
        if let failure = lastFailure, failure.uid == uid, Date().timeIntervalSince(failure.at) < 1 {
            return nil
        }
        guard let device = deviceID(forUID: uid),
              let input = LiveAudioInput(device: device, uid: uid, left: left, right: right)
        else {
            lastFailure = (uid, Date())
            return nil
        }
        lastFailure = nil
        current = input
        return input
    }

    private init?(device: AudioDeviceID, uid: String, left: Int, right: Int) {
        let channels = Self.inputChannelCount(device)
        guard channels > 0, (0 ..< channels).contains(left), (0 ..< channels).contains(right),
              let unit = Self.makeUnit(device: device)
        else { return nil }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &format, &size)
        var maximum: UInt32 = 4096
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                             &maximum, &size)

        deviceUID = uid
        self.left = left
        self.right = right
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48000
        maxFrames = Int(max(maximum, 4096))
        ring = .allocate(capacity: Self.capacity * 2)
        ring.initialize(repeating: 0, count: Self.capacity * 2)
        buffers = AudioBufferList.allocate(maximumBuffers: 2)
        for index in 0 ..< 2 {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            buffers[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maxFrames * 4), mData: data)
        }
        self.unit = unit
        guard start(unit) else { return nil } // `deinit` posprząta
    }

    deinit {
        if let unit {
            AudioOutputUnitStop(unit) // czeka, aż wątek audio wyjdzie z wywołania
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        for buffer in buffers {
            buffer.mData?.assumingMemoryBound(to: Float.self).deallocate()
        }
        free(buffers.unsafeMutablePointer)
        ring.deallocate()
    }

    /// AUHAL z włączonym wejściem i wyłączonym wyjściem, przypięty do urządzenia.
    private static func makeUnit(device: AudioDeviceID) -> AudioUnit? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { return nil }
        var on: UInt32 = 1, off: UInt32 = 0, id = device
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                   &on, flagSize) == noErr,
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                 &off, flagSize) == noErr,
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return unit
    }

    /// Format dla nas (dwa kanały float, osobne bufory), mapa kanałów, wywołanie, start.
    /// AUHAL nie przelicza częstotliwości po stronie wejścia, więc bierzemy tę z urządzenia.
    private func start(_ unit: AudioUnit) -> Bool {
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0
        )
        var map: [Int32] = [Int32(left), Int32(right)]
        var callback = AURenderCallbackStruct(inputProc: Self.inputCallback,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        return AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                    &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                                    &map, UInt32(MemoryLayout<Int32>.size * 2)) == noErr
            && AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                    &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
            && AudioUnitInitialize(unit) == noErr
            && AudioOutputUnitStart(unit) == noErr
    }

    /// Wątek audio: pobierz porcję z AUHAL i dopisz do pierścienia. Bez alokacji.
    private static let inputCallback: AURenderCallback = { refCon, flags, timeStamp, _, frames, _ in
        let input = Unmanaged<LiveAudioInput>.fromOpaque(refCon).takeUnretainedValue()
        return input.capture(flags: flags, timeStamp: timeStamp, frames: frames)
    }

    private func capture(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         timeStamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus
    {
        guard let unit, Int(frames) <= maxFrames else { return noErr }
        for index in 0 ..< 2 {
            buffers[index].mDataByteSize = frames * 4
        }
        let status = AudioUnitRender(unit, flags, timeStamp, 1, frames, buffers.unsafeMutablePointer)
        guard status == noErr,
              let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let rightData = buffers[1].mData?.assumingMemoryBound(to: Float.self)
        else { return status }
        let written = progress.withLock { $0.written }
        let mask = Self.capacity - 1
        for frame in 0 ..< Int(frames) {
            let slot = (Int(truncatingIfNeeded: written) + frame) & mask
            ring[2 * slot] = leftData[frame]
            ring[2 * slot + 1] = rightData[frame]
        }
        let now = DispatchTime.now().uptimeNanoseconds
        progress.withLock {
            $0.written += UInt64(frames)
            $0.lastCallback = now
        }
        return noErr
    }

    /// Dźwięk płynie, jeśli wątek audio odezwał się w ostatniej sekundzie. Świeżo otwarte
    /// nagranie dostaje sekundę na rozruch — inaczej okna otwierałyby je co tyknięcie.
    public var isPlaying: Bool {
        let last = progress.withLock { $0.lastCallback }
        return DispatchTime.now().uptimeNanoseconds - max(last, startedAt) < 1_000_000_000
    }

    public func latestStereo(frames wanted: Int) -> (left: [Float], right: [Float])? {
        let written = progress.withLock { $0.written }
        guard wanted > 0, wanted <= Self.capacity / 2, written >= UInt64(wanted) else { return nil }
        let start = Int(truncatingIfNeeded: written) - wanted
        let mask = Self.capacity - 1
        var left = [Float](repeating: 0, count: wanted)
        var right = [Float](repeating: 0, count: wanted)
        for index in 0 ..< wanted {
            let slot = (start + index) & mask
            left[index] = ring[2 * slot]
            right[index] = ring[2 * slot + 1]
        }
        return (left, right)
    }

    public func latest(frames wanted: Int) -> [Float]? {
        guard let stereo = latestStereo(frames: wanted) else { return nil }
        return zip(stereo.left, stereo.right).map { ($0 + $1) / 2 }
    }

    // MARK: - Urządzenia

    /// Urządzenia, które mają choć jedno wejście, w kolejności systemu.
    public static func devices() -> [Device] {
        allDeviceIDs().compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            let names = (0 ..< channels).map { channelName(id, channel: $0) ?? "" }
            return Device(uid: uid, name: name, channelNames: names)
        }
    }

    /// Wołane na głównym wątku przy każdej zmianie listy urządzeń (wpięcie, odpięcie).
    /// Zwraca obiekt, który trzeba trzymać, dopóki nasłuch ma działać.
    public static func observeDevices(_ onChange: @escaping @Sendable () -> Void) -> AnyObject {
        DeviceListObserver(onChange)
    }

    private final class DeviceListObserver {
        private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
        private let block: AudioObjectPropertyListenerBlock

        init(_ onChange: @escaping @Sendable () -> Void) {
            block = { _, _ in onChange() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }

        deinit {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> String?
    {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty
        else { return nil }
        return string
    }

    /// Nazwa wejścia od sterownika; kanały w Core Audio liczy się od jedynki.
    private static func channelName(_ device: AudioDeviceID, channel: Int) -> String? {
        stringProperty(device, kAudioObjectPropertyElementName, scope: kAudioObjectPropertyScopeInput,
                       element: AudioObjectPropertyElement(channel + 1))
    }
}
