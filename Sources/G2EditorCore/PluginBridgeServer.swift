// PluginBridgeServer.swift
// Gniazdo mostu dla wtyczek DAW (plan: Docs/Plan projektu/05-wtyczka-daw.md §2).
//
// W przeciwieństwie do mostu Claude'a połączenia są STAŁE: wtyczka łączy się raz, na cały
// czas życia w projekcie, i edytor sam wysyła jej zmiany slotu. Stąd wątek na połączenie
// i osobna kolejka zapisu, żeby główny wątek nigdy nie czekał na klienta.
//
// Protokół: JSON, jeden obiekt na linię, w obie strony. Treść poleceń zna `PluginBridge`;
// ten plik zna tylko linie i połączenia.

import Foundation

public final class PluginBridgeServer: @unchecked Sendable {
    public typealias ConnectionID = Int

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Najdłuższa linia od klienta: patch `.pch2` w base64 mieści się z dużym zapasem.
    static let maximumLine = 16 * 1024 * 1024

    let path: String
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "PluginBridge.write")
    private var listener: Int32 = -1
    private var clients: [ConnectionID: Int32] = [:]
    private var nextID = 1
    private var stopping = false

    /// Wołane z wątku połączenia — odbiorca sam przeskakuje na główny.
    public var onLine: (@Sendable (ConnectionID, String) -> Void)?
    public var onDisconnect: (@Sendable (ConnectionID) -> Void)?

    public init(path: String) {
        self.path = path
    }

    /// Czy ktoś już słucha na tej ścieżce — drugi edytor albo ten sam po awarii? Martwy plik
    /// gniazda (proces zginął) odmawia połączenia, więc wynik jest wiarygodny.
    public static func isListening(at path: String) -> Bool {
        guard let fd = connectSocket(path) else { return false }
        close(fd)
        return true
    }

    public func start() throws {
        unlink(path)
        let fd = Foundation.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket() failed: \(errno)") }
        guard var address = Self.address(path) else {
            close(fd)
            throw Failure(description: "the socket path is too long: \(path)")
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            close(fd)
            throw Failure(description: "bind(\(path)) failed: \(errno)")
        }
        // Tylko właściciel — nikt inny na tym Macu nie wejdzie w gniazdo.
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            throw Failure(description: "listen() failed: \(errno)")
        }
        lock.withLock { listener = fd }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "PluginBridge.accept"
        thread.start()
    }

    public func stop() {
        let (fd, open) = lock.withLock { () -> (Int32, [Int32]) in
            stopping = true
            let fd = listener
            listener = -1
            return (fd, Array(clients.values))
        }
        if fd >= 0 { close(fd) }
        // `shutdown` budzi wątki czytające; zamyka je dopiero każdy wątek u siebie.
        for client in open {
            shutdown(client, SHUT_RDWR)
        }
        unlink(path)
    }

    /// Wysyła jedną linię. Nie blokuje: zapis idzie kolejką, a klient, który nie odbiera
    /// przez 2 s, zostaje rozłączony (limit `SO_SNDTIMEO`), zamiast wstrzymać pozostałych.
    public func send(_ line: String, to id: ConnectionID) {
        var data = Data(line.utf8)
        data.append(0x0A)
        writeQueue.async { [weak self] in
            guard let self, let fd = lock.withLock({ self.clients[id] }) else { return }
            let complete = data.withUnsafeBytes { bytes -> Bool in
                var sent = 0
                while sent < bytes.count {
                    let wrote = Foundation.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                    if wrote <= 0 { return false }
                    sent += wrote
                }
                return true
            }
            if !complete { shutdown(fd, SHUT_RDWR) }
        }
    }

    // MARK: - Wątki

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if lock.withLock({ stopping }) { return }
                usleep(50000)
                continue
            }
            var yes: Int32 = 1
            // Bez tego zapis do klienta, który właśnie zniknął, zabiłby CAŁY edytor sygnałem.
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let id = lock.withLock { () -> ConnectionID? in
                guard !stopping else { return nil }
                let id = nextID
                nextID += 1
                clients[id] = client
                return id
            }
            guard let id else {
                close(client)
                return
            }
            let thread = Thread { [weak self] in self?.readLoop(client, id) }
            thread.name = "PluginBridge.client\(id)"
            thread.start()
        }
    }

    private func readLoop(_ fd: Int32, _ id: ConnectionID) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        reading: while true {
            let got = Foundation.read(fd, &buffer, buffer.count)
            if got <= 0 { break }
            pending.append(contentsOf: buffer[0 ..< got])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex ..< newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex ... newline)
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { onLine?(id, line) }
            }
            // Linia dłuższa niż jakikolwiek patch — to nie jest nasz klient.
            if pending.count > Self.maximumLine { break reading }
        }
        // Zamknięcie w kolejce zapisu: wysyłka, która już tam czeka, nie trafi w cudzy
        // deskryptor, gdyby system zdążył ponownie wydać ten numer.
        writeQueue.async { [weak self] in
            self?.lock.withLock { _ = self?.clients.removeValue(forKey: id) }
            close(fd)
        }
        onDisconnect?(id)
    }

    // MARK: - Adres

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maximum = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= maximum else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let bytes = pointer.withMemoryRebound(to: CChar.self, capacity: maximum + 1) { $0 }
            for (index, byte) in path.utf8.enumerated() {
                bytes[index] = CChar(bitPattern: byte)
            }
            bytes[path.utf8.count] = 0
        }
        return address
    }

    /// Połączenie klienta — do sprawdzenia, czy ktoś słucha, i do testów.
    public static func connectSocket(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = Foundation.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.connect(fd, $0, size) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}
