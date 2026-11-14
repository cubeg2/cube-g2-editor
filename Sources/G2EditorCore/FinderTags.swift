import Foundation

/// Tagi Findera (kolorowe kropki i ich nazwy) mieszkają w atrybucie rozszerzonym pliku,
/// nie w jego treści. Zapis atomowy pisze nowy plik obok i podmienia stary, więc razem
/// ze starym plikiem przepadają jego tagi. Zdejmujemy je przed zapisem i nakładamy po nim.
///
/// Kopiujemy surowe bajty atrybutu, bo `URLResourceValues.tagNames` ma setter dopiero
/// od macOS 26, a edytor celuje w 14.
public enum FinderTags {
    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// Tagi pliku, albo `nil` gdy pliku jeszcze nie ma lub nie jest otagowany.
    public static func read(at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = Data(count: size)
            let copied = buffer.withUnsafeMutableBytes {
                getxattr(path, attribute, $0.baseAddress, size, 0, 0)
            }
            return copied == size ? buffer : nil
        }
    }

    /// Nakłada zdjęte wcześniej tagi na zapisany plik. Bez tagów nic nie robi — nie chcemy
    /// kasować tych, które użytkownik nadał plikowi w międzyczasie.
    public static func restore(_ tags: Data?, at url: URL) {
        guard let tags else { return }
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = tags.withUnsafeBytes {
                setxattr(path, attribute, $0.baseAddress, tags.count, 0, 0)
            }
        }
    }
}
