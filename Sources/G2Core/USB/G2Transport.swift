// G2Transport.swift
// Szew transportowy aktora USB: kto realnie przenosi bajty do urządzenia.
//
// Dwie implementacje: `LibUsbTransport` (prawdziwy Nord przez libusb) i
// `EmulatorTransport` (wirtualny G2 po gnieździe uniksowym). Cała logika ponowień,
// odblokowywania zatrzaśniętego endpointu i nazywania błędów zostaje w `G2MidiManager` —
// dlatego obie implementacje zwracają kody w konwencji libusb, a nie własne wyjątki.
//
// Emulator jest osobnym programem w osobnym repozytorium (`Emulator_G2`), a nie
// biblioteką linkowaną do edytora. Powód nie jest estetyczny: rdzeń DSP56300, który
// kiedyś może do niego dojść, jest na GPL-3, a linkowanie GPL-3 do edytora narzuciłoby
// tę licencję całemu edytorowi. Osobny proces gadający po gnieździe nie tworzy
// utworu zależnego → [[Docs/usb/emulator]].

import CLibUsb
import Darwin
import Foundation

/// Kanał bajtowy do urządzenia G2. Metody są synchroniczne i blokujące dokładnie tak
/// samo jak `libusb_bulk_transfer` — aktor już dziś blokuje się na nich przez 100 ms.
protocol G2Transport: AnyObject {
    func open() throws
    func close()
    /// Zwraca `(kod libusb, liczba przeniesionych bajtów)`.
    func write(_ frame: inout [UInt8], endpoint: UInt8, timeout: UInt32) -> (code: Int32, length: Int32)
    func read(_ buffer: inout [UInt8], endpoint: UInt8, timeout: UInt32) -> (code: Int32, length: Int32)
    func clearHalt(endpoint: UInt8) -> Int32
    func describeEndpoints() -> String
    /// Najdłuższy JEDEN odczyt, na jaki aktor USB ma prawo zasnąć bez oddania głosu innym
    /// zadaniom (nuta z klawiatury, gałka). `read` z dłuższym `timeout` aktor tnie na takie
    /// plastry i między nimi robi `Task.yield()`.
    var readSliceMilliseconds: UInt32 { get }
}

extension G2Transport {
    /// libusb: jeden odczyt = pełne okno. Zmiana tego dla Norda wymaga testu na sprzęcie.
    var readSliceMilliseconds: UInt32 {
        100
    }
}

// MARK: - Prawdziwy Nord (libusb)

/// Czy Nord jest w gnieździe USB — **tylko lista urządzeń**, bez otwierania i bez resetu,
/// więc nie przeszkadza połączeniu, które go właśnie używa. Pyta o to samoczynny wirtualny
/// G2: ustępuje miejsca Nordowi, gdy ten się pojawi.
public enum G2HardwareProbe {
    public static func isNordPluggedIn() -> Bool {
        var context: OpaquePointer?
        guard libusb_init(&context) == 0, let context else { return false }
        defer { libusb_exit(context) }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        guard count > 0, let list else { return false }
        defer { libusb_free_device_list(list, 1) }
        for index in 0 ..< count {
            guard let device = list[index] else { continue }
            var descriptor = libusb_device_descriptor()
            guard libusb_get_device_descriptor(device, &descriptor) == 0 else { continue }
            if descriptor.idVendor == G2UsbProtocol.vendorID, descriptor.idProduct == G2UsbProtocol.productID {
                return true
            }
        }
        return false
    }
}

final class LibUsbTransport: G2Transport {
    private var context: OpaquePointer?
    private var handle: OpaquePointer?

    func open() throws {
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == 0, let ctx else { throw G2UsbError.libusbInitFailed }
        context = ctx

        guard let device = libusb_open_device_with_vid_pid(ctx, G2UsbProtocol.vendorID, G2UsbProtocol.productID) else {
            libusb_exit(ctx)
            context = nil
            throw G2UsbError.deviceNotFound
        }
        guard libusb_reset_device(device) == 0 else {
            libusb_close(device)
            libusb_exit(ctx)
            context = nil
            throw G2UsbError.resetFailed
        }
        guard libusb_claim_interface(device, G2UsbProtocol.interfaceNumber) == 0 else {
            libusb_close(device)
            libusb_exit(ctx)
            context = nil
            throw G2UsbError.claimInterfaceFailed
        }
        handle = device
    }

    func close() {
        if let handle {
            libusb_release_interface(handle, G2UsbProtocol.interfaceNumber)
            libusb_close(handle)
            self.handle = nil
        }
        if let context {
            libusb_exit(context)
            self.context = nil
        }
    }

    func write(_ frame: inout [UInt8], endpoint: UInt8, timeout: UInt32) -> (code: Int32, length: Int32) {
        guard let handle else { return (LIBUSB_ERROR_NO_DEVICE.rawValue, 0) }
        var actualLength: Int32 = 0
        let code = frame.withUnsafeMutableBufferPointer { buf in
            libusb_bulk_transfer(handle, endpoint, buf.baseAddress, Int32(buf.count), &actualLength, timeout)
        }
        return (code, actualLength)
    }

    func read(_ buffer: inout [UInt8], endpoint: UInt8, timeout: UInt32) -> (code: Int32, length: Int32) {
        guard let handle else { return (LIBUSB_ERROR_NO_DEVICE.rawValue, 0) }
        var actualLength: Int32 = 0
        let code = buffer.withUnsafeMutableBufferPointer { buf in
            libusb_bulk_transfer(handle, endpoint, buf.baseAddress, Int32(buf.count), &actualLength, timeout)
        }
        return (code, actualLength)
    }

    func clearHalt(endpoint: UInt8) -> Int32 {
        guard let handle else { return LIBUSB_ERROR_NO_DEVICE.rawValue }
        return libusb_clear_halt(handle, endpoint)
    }

    /// Deskryptory endpointów aktywnej konfiguracji — rozstrzyga, czy 16-bajtowy bufor
    /// odczytu 0x81 odpowiada faktycznemu `wMaxPacketSize` urządzenia (za mały bufor =
    /// `LIBUSB_ERROR_OVERFLOW` i zatrzaśnięty endpoint).
    func describeEndpoints() -> String {
        guard let handle, let device = libusb_get_device(handle) else {
            return "brak otwartego urządzenia"
        }
        var configPtr: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(device, &configPtr) == 0, let config = configPtr else {
            return "brak deskryptora aktywnej konfiguracji"
        }
        defer { libusb_free_config_descriptor(config) }

        var lines: [String] = []
        guard let interfaces = config.pointee.interface else { return "konfiguracja bez interfejsów" }
        for index in 0 ..< Int(config.pointee.bNumInterfaces) {
            let interface = interfaces[index]
            guard let altSettings = interface.altsetting else { continue }
            for alt in 0 ..< Int(interface.num_altsetting) {
                let descriptor = altSettings[alt]
                lines.append("interface \(descriptor.bInterfaceNumber) alt \(descriptor.bAlternateSetting) class 0x\(String(descriptor.bInterfaceClass, radix: 16)) endpointów \(descriptor.bNumEndpoints)")
                guard let endpoints = descriptor.endpoint else { continue }
                for slot in 0 ..< Int(descriptor.bNumEndpoints) {
                    let endpoint = endpoints[slot]
                    let kinds = ["control", "isochronous", "bulk", "interrupt"]
                    let kind = kinds[Int(endpoint.bmAttributes & 0x03)]
                    lines.append("  ep 0x\(String(endpoint.bEndpointAddress, radix: 16)) \(kind) wMaxPacketSize \(endpoint.wMaxPacketSize) bInterval \(endpoint.bInterval)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Wirtualny G2 (gniazdo uniksowe)

/// Rozmowa z emulatorem. Po gnieździe idą DOKŁADNIE te same ramki co po USB, opakowane
/// w trzybajtową kopertę `[endpoint][długość:2B BE]` — bo USB ma trzy endpointy, a
/// strumień bajtów jeden, więc odbiorca musi wiedzieć, z którego „drutu" pakiet przyszedł.
///
/// Dzięki temu obie strony używają niezmienionego `G2UsbProtocol`: emulator nie jest
/// osobnym protokołem do utrzymania, tylko innym kablem.
final class EmulatorTransport: G2Transport {
    /// Domyślna ścieżka gniazda. `G2_EMULATOR_SOCKET` ma pierwszeństwo — tym samym
    /// przełącznikiem posługuje się emulator, więc obie strony da się przenieść naraz.
    static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["G2_EMULATOR_SOCKET"], !override.isEmpty {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("G2Editor/emulator.sock").path
            ?? "/tmp/g2-emulator.sock"
    }

    private var fd: Int32 = -1
    /// Pakiety odebrane „nie w swojej kolejce" — przyszły z endpointu, na który akurat
    /// nikt nie czekał. Wyrzucenie ich znaczyłoby gubienie powiadomień, bo `receiveResponse`
    /// czyta 0x81 i 0x82 naprzemiennie.
    private var queues: [UInt8: [[UInt8]]] = [:]

    func open() throws {
        let path = Self.socketPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw G2UsbError.deviceNotFound
        }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw G2UsbError.deviceNotFound }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(socketFD)
            throw G2UsbError.transferFailed("emulator socket path longer than \(capacity - 1) characters")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
                for (index, byte) in pathBytes.enumerated() {
                    dest[index] = CChar(bitPattern: byte)
                }
                dest[pathBytes.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.connect(socketFD, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(socketFD)
            throw G2UsbError.deviceNotFound
        }
        // Krótki timeout odczytu + pętla do terminu: bez tego `read` z zadanym czasem
        // czekania blokowałby aktor na pełne 100 ms nawet wtedy, gdy dane już są.
        var window = timeval(tv_sec: 0, tv_usec: 20000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        fd = socketFD
        queues.removeAll()
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        queues.removeAll()
    }

    func write(_ frame: inout [UInt8], endpoint: UInt8, timeout _: UInt32) -> (code: Int32, length: Int32) {
        guard fd >= 0 else { return (LIBUSB_ERROR_NO_DEVICE.rawValue, 0) }
        let length = frame.count
        guard length <= 0xFFFF else { return (LIBUSB_ERROR_INVALID_PARAM.rawValue, 0) }
        var packet: [UInt8] = [endpoint, UInt8(length >> 8), UInt8(length & 0xFF)]
        packet.append(contentsOf: frame)
        return writeAll(packet) ? (0, Int32(length)) : (LIBUSB_ERROR_NO_DEVICE.rawValue, 0)
    }

    /// Gniazdo odpowiada w mikrosekundach, więc aktor nie musi na nim wisieć: 5 ms plastry
    /// dają nucie z klawiatury szansę wyjść zaraz po naciśnięciu, a nie po 100 ms okna poll.
    /// Zmierzone 2026-09-16 (`USBProbe --notetest`): przy 100 ms „on" i „off" krótkiego
    /// klawisza wychodziły w jednej chwili (0,3 ms odstępu) i nuta była niesłyszalna.
    var readSliceMilliseconds: UInt32 {
        5
    }

    func read(_ buffer: inout [UInt8], endpoint: UInt8, timeout: UInt32) -> (code: Int32, length: Int32) {
        guard fd >= 0 else { return (LIBUSB_ERROR_NO_DEVICE.rawValue, 0) }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout) / 1000.0)

        repeat {
            if let packet = dequeue(endpoint) {
                // Za mały bufor po stronie USB kończy się `LIBUSB_ERROR_OVERFLOW`
                // i zatrzaśniętym endpointem — emulator zgłasza to samo, żeby ta gałąź
                // `bulkRead` dała się w ogóle sprawdzić bez sprzętu.
                guard packet.count <= buffer.count else { return (LIBUSB_ERROR_OVERFLOW.rawValue, 0) }
                for (index, byte) in packet.enumerated() {
                    buffer[index] = byte
                }
                return (0, Int32(packet.count))
            }
            switch receivePacket() {
            case let .packet(endpoint: source, bytes: bytes):
                queues[source, default: []].append(bytes)
            case .empty:
                // Nic w gnieździe: czekamy na dane w jądrze zamiast kręcić się w kółko
                // (do 2026-09-16 ta pętla paliła cały rdzeń przez każde 100 ms ciszy).
                waitReadable(until: deadline)
            case .closed:
                return (LIBUSB_ERROR_NO_DEVICE.rawValue, 0)
            }
        } while Date() < deadline

        if let packet = dequeue(endpoint) {
            guard packet.count <= buffer.count else { return (LIBUSB_ERROR_OVERFLOW.rawValue, 0) }
            for (index, byte) in packet.enumerated() {
                buffer[index] = byte
            }
            return (0, Int32(packet.count))
        }
        return (LIBUSB_ERROR_TIMEOUT.rawValue, 0)
    }

    /// Emulator nie ma czego odblokowywać — endpoint programowy się nie zatrzaskuje.
    func clearHalt(endpoint _: UInt8) -> Int32 {
        0
    }

    func describeEndpoints() -> String {
        """
        emulator G2 (gniazdo \(Self.socketPath))
          ep 0x3 bulk (wyjście)
          ep 0x81 interrupt wMaxPacketSize \(G2UsbProtocol.interruptMessageSize)
          ep 0x82 bulk (dane rozszerzone)
        """
    }

    // MARK: Warstwa gniazda

    private enum Incoming {
        case packet(endpoint: UInt8, bytes: [UInt8])
        case empty
        case closed
    }

    private func dequeue(_ endpoint: UInt8) -> [UInt8]? {
        guard var pending = queues[endpoint], !pending.isEmpty else { return nil }
        let first = pending.removeFirst()
        queues[endpoint] = pending
        return first
    }

    private func writeAll(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                Darwin.send(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EAGAIN || errno == EINTR { continue }
            return false
        }
        return true
    }

    /// Jeden pakiet z koperty. `.empty` znaczy „jeszcze nic nie przyszło" (timeout gniazda),
    /// a nie błąd — dokładnie jak `LIBUSB_ERROR_TIMEOUT` przy pustym endpoincie.
    private func receivePacket() -> Incoming {
        switch readExactly(3) {
        case let .bytes(header):
            let endpoint = header[0]
            let length = Int(header[1]) << 8 | Int(header[2])
            guard length > 0 else { return .packet(endpoint: endpoint, bytes: []) }
            // Nagłówek już zszedł z gniazda, więc na treść czekamy do skutku — inaczej
            // strumień rozjechałby się o kilka bajtów i każdy następny pakiet byłby śmieciem.
            switch readExactly(length, blocking: true) {
            case let .bytes(body): return .packet(endpoint: endpoint, bytes: body)
            default: return .closed
            }
        case .empty:
            return .empty
        case .closed:
            return .closed
        }
    }

    private enum ReadResult {
        case bytes([UInt8])
        case empty
        case closed
    }

    /// `poll(2)` na gnieździe do `deadline` (najwyżej 100 ms na raz, żeby zamknięcie
    /// nie czekało w nieskończoność). Sam powrót nic nie znaczy — pętla i tak czyta ponownie.
    private func waitReadable(until deadline: Date) {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 100)))
    }

    private func readExactly(_ count: Int, blocking: Bool = false) -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received > 0 {
                offset += received
                continue
            }
            if received == 0 { return .closed }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if blocking { continue }
                return offset == 0 ? .empty : .closed
            }
            return .closed
        }
        return .bytes(buffer)
    }
}
