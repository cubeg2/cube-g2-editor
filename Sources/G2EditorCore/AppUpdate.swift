import Foundation

// Sprawdzanie aktualizacji (ustalone z użytkownikiem 2026-10-15): edytor tylko PATRZY,
// czy na GitHubie jest nowsze wydanie — nic sam nie pobiera ani nie instaluje.
// Źródłem jest lista wydań publicznego repo; opublikowanie wydania z DMG = ogłoszenie
// aktualizacji. Okienko i zakładka Settings ▸ Updates są w `G2EditorApp`.

/// Numer wersji „0.1.2” — porównywany liczba po liczbie, więc 0.10 jest nowsze od 0.9.
/// Przyjmuje też nazwy wydań z GitHuba: „v0.1.2”, „v0.2.0-beta” (dopisek po „-” pomija).
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let core = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    /// Brakujące liczby to zera: 0.1 == 0.1.0.
    private static func padded(_ lhs: AppVersion, _ rhs: AppVersion) -> [(Int, Int)] {
        let count = max(lhs.parts.count, rhs.parts.count)
        return (0 ..< count).map { index in
            (index < lhs.parts.count ? lhs.parts[index] : 0, index < rhs.parts.count ? rhs.parts[index] : 0)
        }
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for (left, right) in padded(lhs, rhs) where left != right {
            return left < right
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        padded(lhs, rhs).allSatisfy { $0 == $1 }
    }
}

/// Jedno wydanie z GitHuba: numer, lista zmian z opisu, strona wydania i sam plik DMG.
public struct AppRelease: Equatable, Sendable {
    public let version: AppVersion
    public let notes: String
    public let pageURL: URL
    /// Bezpośredni link do DMG — Download pobiera plik, zamiast otwierać stronę, na której
    /// DMG ginie pod „Assets” (zgłoszenie użytkownika 2026-10-22). Bez DMG: strona wydania.
    public let downloadURL: URL

    public init(version: AppVersion, notes: String, pageURL: URL, downloadURL: URL? = nil) {
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.downloadURL = downloadURL ?? pageURL
    }
}

public enum UpdateCheck {
    /// Lista wydań, nie „latest”: GitHub w „latest” pomija wydania oznaczone jako
    /// beta (prerelease), a nasze pierwsze wydania nimi będą.
    public static let releasesURL = URL(string: "https://api.github.com/repos/cubeg2/cube-g2-editor/releases?per_page=20")!
    /// Przy starcie najwyżej raz na dobę.
    public static let interval: TimeInterval = 24 * 60 * 60

    public enum Result: Equatable, Sendable {
        case found(AppRelease)
        /// Repo odpowiedziało, ale nie ma w nim żadnego wydania.
        case noReleases
        /// Brak sieci, błąd serwera albo repo jeszcze nie istnieje.
        case failed
    }

    public static func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }

    /// Wydanie do pokazania przy starcie: nowsze od obecnego i nie to, które użytkownik
    /// pominął (Skip This Version). Jeszcze nowsze od pominiętego znów się pokazuje.
    public static func offer(_ release: AppRelease, current: AppVersion, skipped: AppVersion?) -> AppRelease? {
        guard release.version > current else { return nil }
        if let skipped, release.version <= skipped { return nil }
        return release
    }

    /// Najnowsze wydanie z odpowiedzi GitHuba; szkice i nazwy, które nie są numerem, pomija.
    public static func newest(fromReleasesJSON data: Data) -> Result {
        guard let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else { return .failed }
        let candidates = releases.compactMap { release -> AppRelease? in
            guard release.draft != true, let version = AppVersion(release.tag) else { return nil }
            let dmg = release.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }
            return AppRelease(version: version, notes: release.body ?? "", pageURL: release.page,
                              downloadURL: dmg?.url)
        }
        guard let newest = candidates.max(by: { $0.version < $1.version }) else { return .noReleases }
        return .found(newest)
    }

    public static func fetchNewest(session: URLSession = .shared) async -> Result {
        var request = URLRequest(url: releasesURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
        return newest(fromReleasesJSON: data)
    }
}

/// Pola z odpowiedzi GitHuba, których używamy.
private struct GitHubRelease: Decodable {
    let tag: String
    let body: String?
    let page: URL
    let draft: Bool?
    let assets: [GitHubAsset]?

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", body, page = "html_url", draft, assets
    }
}

/// Plik dołączony do wydania (u nas DMG).
private struct GitHubAsset: Decodable {
    let name: String
    let url: URL

    enum CodingKeys: String, CodingKey {
        case name, url = "browser_download_url"
    }
}
