import Foundation
@testable import G2Core
import XCTest

/// Zbiorcze niezmienniki WSZYSTKICH modułów — jeden przebieg przez całą bazę.
///
/// Te testy celowo NIE porównują nas ze źródłami zewnętrznymi (g2ools, BVerhue,
/// oryginalny edytor, korpus patchy): tamte pliki leżą w `reference/`, którego nie ma
/// w repozytorium, więc `swift test` nie miałby ich na świeżej maszynie. Od
/// porównań ze źródłami są skrypty `.codex/scripts/audit-param-ranges.py`
/// i `audit-module-defs.py`, uruchamiane na żądanie.
///
/// Tutaj sprawdzamy spójność WEWNĘTRZNĄ trzech baz, które muszą się zgadzać
/// same ze sobą: `ModuleDatabase` (parametry i gniazda), `ModuleUIDatabase`
/// (widżety z paneli Gen1) oraz `ModuleDefaultsDatabase` + `ParameterRangeDatabase`.
/// Taki test łapie regresje, których nie widać na obrazku: widżet sterujący
/// nieistniejącym parametrem, parametr bez żadnej kontrolki, wartość domyślna
/// poza zakresem, rozjechaną liczbę gniazd.
final class ModuleInvariantTests: XCTestCase {
    /// Moduł „Name" to sama etykieta — nie ma panelu Gen1 ani parametrów.
    private let modulesWithoutPanel: Set<Int> = [126]

    private func eachModule(_ body: (ModuleDef, ModuleUIDef) -> Void) {
        for def in ModuleDatabase.all where !modulesWithoutPanel.contains(def.id) {
            guard let ui = ModuleUIDatabase.shared.uiDef(forID: def.id) else {
                XCTFail("brak panelu Gen1 dla \(def.shortName) (\(def.id))")
                continue
            }
            body(def, ui)
        }
    }

    /// Każdy moduł z bazy ma swój panel — inaczej nie dałoby się go narysować.
    func testEveryModuleHasPanel() {
        eachModule { _, _ in }
    }

    /// Migawka kompletnych danych wejściowych aktywnego renderera. Powstała przed
    /// przeniesieniem paneli Gen1 z katalogu `reference/` do zasobów pakietu i ma
    /// wykryć zmianę współrzędnych, indeksów, tekstów albo typów kontrolek.
    func testPanelGeometryMatchesApprovedSnapshot() {
        XCTAssertEqual(panelGeometryFingerprint(), "d8ebf39bdfad35b4")
    }

    private func panelGeometryFingerprint() -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        func number(_ value: CGFloat) -> String {
            String(format: "%.6f", locale: locale, Double(value))
        }
        func flag(_ value: Bool) -> String {
            value ? "1" : "0"
        }
        func row(_ values: [String]) -> String {
            values.joined(separator: "|")
        }

        var rows: [String] = []
        for def in ModuleDatabase.all where !modulesWithoutPanel.contains(def.id) {
            guard let ui = ModuleUIDatabase.shared.uiDef(forID: def.id) else {
                rows.append(row(["MISSING", String(def.id)]))
                continue
            }

            rows.append(row(["M", String(def.id), ui.name, ui.fileName, String(ui.height)]))
            rows += ui.knobs.map {
                row(["K", String($0.id), number($0.xPt), number($0.yPt),
                     String($0.codeRef), $0.type.rawValue, String($0.infoFunc)])
            }
            rows += ui.inputs.map {
                row(["I", String($0.id), number($0.xPt), number($0.yPt),
                     String($0.codeRef), $0.signalType.rawValue, flag($0.isOutput)])
            }
            rows += ui.outputs.map {
                row(["O", String($0.id), number($0.xPt), number($0.yPt),
                     String($0.codeRef), $0.signalType.rawValue, flag($0.isOutput)])
            }
            rows += ui.buttonsFlat.map {
                row(["BF", String($0.id), number($0.xPt), number($0.yPt),
                     String($0.codeRef), $0.options.joined(separator: ","),
                     number($0.widthPt), String($0.infoFunc), String($0.imageCount)])
            }
            rows += ui.buttonsText.map {
                row(["BT", String($0.id), number($0.xPt), number($0.yPt),
                     String($0.codeRef), $0.text, $0.type, number($0.widthPt)])
            }
            rows += ui.buttonsRadio.map {
                row(["BR", String($0.id), number($0.xPt), number($0.yPt),
                     String($0.codeRef), String($0.buttonCount), number($0.buttonWidthPt),
                     String($0.infoFunc), $0.orientation, String($0.columns), String($0.rows),
                     $0.buttonLabels.joined(separator: ","), String($0.iconWidth),
                     $0.iconPixels.joined(separator: ",")])
            }
            rows += ui.leds.map {
                row(["LED", String($0.id), number($0.xPt), number($0.yPt),
                     String($0.codeRef), $0.type.rawValue])
            }
            rows += ui.levelShifts.map {
                row(["LS", String($0.id), number($0.xPt), number($0.yPt), String($0.codeRef)])
            }
            rows += ui.textFields.map {
                row(["TF", String($0.id), number($0.xPt), number($0.yPt),
                     String($0.masterRef), number($0.widthPt), String($0.textFunc),
                     $0.dependencies.map(String.init).joined(separator: ",")])
            }
            rows += ui.incDecButtons.map {
                row(["ID", String($0.id), number($0.xPt), number($0.yPt),
                     String($0.codeRef), String($0.infoFunc), flag($0.isVertical)])
            }
            rows += ui.textLabels.map {
                row(["TL", String($0.id), number($0.xPt), number($0.yPt),
                     $0.text, number($0.fontSize)])
            }
            rows += ui.graphs.map {
                row(["G", String($0.id), number($0.xPt), number($0.yPt),
                     number($0.widthPt), number($0.heightPt), String($0.graphFunc),
                     $0.dependencies.map(String.init).joined(separator: ",")])
            }
            rows += ui.partSelectors.map {
                row(["PS", String($0.id), number($0.xPt), number($0.yPt),
                     String($0.codeRef), String($0.infoFunc), number($0.widthPt),
                     number($0.heightPt), String($0.imageCount), String($0.imageWidth),
                     flag($0.usesParameter), $0.iconPixels.joined(separator: ",")])
            }
            rows += ui.lines.map {
                row(["L", String($0.id), number($0.xPt), number($0.yPt),
                     number($0.lengthPt), flag($0.isHorizontal), flag($0.isThick)])
            }
            rows += ui.symbols.map {
                row(["S", String($0.id), number($0.xPt), number($0.yPt),
                     number($0.widthPt), number($0.heightPt), $0.type])
            }
            rows += ui.bitmaps.map {
                row(["BM", String($0.id), number($0.xPt), number($0.yPt),
                     String($0.widthPx), String($0.heightPx)])
            }
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in rows.joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", locale: locale, hash)
    }

    /// Żaden widżet nie steruje parametrem, którego moduł nie ma. Taki widżet
    /// przy kliknięciu zapisywałby wartość poza tablicą parametrów.
    func testEveryControlPointsAtExistingParameter() {
        eachModule { def, ui in
            let count = def.paramNames.count
            func check(_ codeRef: Int, _ what: String) {
                XCTAssertTrue((0 ..< count).contains(codeRef),
                              "\(def.shortName) (\(def.id)): \(what) steruje parametrem "
                                  + "\(codeRef), a moduł ma ich \(count)")
            }
            for k in ui.knobs {
                check(k.codeRef, "gałka/suwak")
            }
            for b in ui.buttonsFlat {
                check(b.codeRef, "ButtonFlat \(b.options)")
            }
            for b in ui.buttonsText {
                check(b.codeRef, "ButtonText „\(b.text)”")
            }
            for b in ui.buttonsRadio {
                check(b.codeRef, "ButtonRadio")
            }
            for b in ui.incDecButtons {
                check(b.codeRef, "para −/+")
            }
            for l in ui.levelShifts {
                check(l.codeRef, "LevelShift")
            }
        }
    }

    /// PartSelector indeksuje TRYBY modułu, nie parametry (`usesParameter == false`).
    /// Pomylenie tych dwóch przestrzeni to klasyczny błąd — patrz komentarz
    /// w `audit-param-ranges.py` o LfoC (8 kształtów fali kontra gałka „Rate").
    func testPartSelectorsPointAtExistingModes() {
        eachModule { def, ui in
            for sel in ui.partSelectors where !sel.usesParameter {
                XCTAssertTrue((0 ..< def.modeNames.count).contains(sel.codeRef),
                              "\(def.shortName) (\(def.id)): PartSelector wskazuje tryb "
                                  + "\(sel.codeRef), a moduł ma ich \(def.modeNames.count)")
            }
        }
    }

    /// Każdy parametr da się ustawić — ma przynajmniej jedną kontrolkę na panelu.
    /// Parametr bez widżetu jest niewidoczny dla użytkownika i zostaje na wartości
    /// domyślnej na zawsze.
    func testEveryParameterHasAControl() {
        eachModule { def, ui in
            var covered = Set<Int>()
            covered.formUnion(ui.knobs.map(\.codeRef))
            covered.formUnion(ui.buttonsFlat.map(\.codeRef))
            covered.formUnion(ui.buttonsText.map(\.codeRef))
            covered.formUnion(ui.buttonsRadio.map(\.codeRef))
            covered.formUnion(ui.incDecButtons.map(\.codeRef))
            covered.formUnion(ui.levelShifts.map(\.codeRef))
            covered.formUnion(ui.partSelectors.filter(\.usesParameter).map(\.codeRef))

            let missing = (0 ..< def.paramNames.count).filter { !covered.contains($0) }
            XCTAssertTrue(missing.isEmpty,
                          "\(def.shortName) (\(def.id)): parametry bez kontrolki — "
                              + missing.map { "\($0) \(def.paramNames[$0])" }.joined(separator: ", "))
        }
    }

    /// Długa nazwa to podpis modułu w bibliotece i w menu „Replace with…” — dwa moduły
    /// o tej samej nazwie są tam nie do odróżnienia. Mix2-1B nazywał się „Scratch”
    /// (pomyłka przejęta z g2ools); oryginalny edytor podaje „Mixer 2-1 B”.
    func testLongNamesAreUnique() {
        let byName = Dictionary(grouping: ModuleDatabase.all, by: \.longName)
        let duplicates = byName.filter { $0.value.count > 1 }
            .map { "\($0.key): " + $0.value.map(\.shortName).joined(separator: ", ") }
        XCTAssertTrue(duplicates.isEmpty, "powtórzone długie nazwy — \(duplicates)")
        XCTAssertEqual(ModuleDatabase.module(id: 66)?.longName, "Mixer 2-1 B")
    }

    /// Długa nazwa jest podpisem z panelu modułu (`Tooltip:`), jak w oryginalnym edytorze.
    /// Baza powstała z g2ools, który miał własne warianty („Envelop ADSR”, „Fade 1-2”,
    /// „PM Driver”); panele trzymają nazwy oryginału.
    func testLongNamesMatchPanelTooltips() throws {
        let folder = try XCTUnwrap(Bundle.g2Core.url(forResource: "Modules", withExtension: nil))
        var tooltips: [String: String] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where url.pathExtension == "txt"
        {
            let text = try String(contentsOf: url, encoding: .utf8)
            func field(_ name: String) -> String? {
                guard let range = text.range(of: "\(name):\"[^\"]*\"", options: .regularExpression) else {
                    return nil
                }
                return String(text[range].dropFirst(name.count + 2).dropLast())
            }
            // Klucz to FileName — dwa panele mogą mieć tę samą Name (Delay: logiczny i audio).
            if let fileName = field("FileName"), let tooltip = field("Tooltip") {
                tooltips[fileName] = tooltip
            }
        }
        eachModule { def, ui in
            XCTAssertEqual(def.longName, tooltips[ui.fileName], "\(def.shortName) (\(def.id))")
        }
    }

    /// Wartości domyślne opisują dokładnie tyle parametrów, ile moduł ma.
    func testDefaultsCoverEveryParameter() {
        for def in ModuleDatabase.all {
            let defaults = ModuleDefaultsDatabase.defaults(forTypeID: def.id)
            XCTAssertEqual(defaults.count, def.paramNames.count,
                           "\(def.shortName) (\(def.id)): \(defaults.count) wartości domyślnych "
                               + "wobec \(def.paramNames.count) parametrów")
        }
    }

    /// Wartość domyślna mieści się w zakresie, który aplikacja pozwala ustawić.
    /// Gdyby wypadła poza, moduł startowałby w stanie nieosiągalnym z panelu.
    func testDefaultsFallWithinTheirRange() {
        for def in ModuleDatabase.all {
            let defaults = ModuleDefaultsDatabase.defaults(forTypeID: def.id)
            for (codeRef, value) in defaults.enumerated() {
                let range = ParameterRangeDatabase.range(moduleTypeID: def.id, codeRef: codeRef)
                    ?? 0 ... 127
                XCTAssertTrue(range.contains(value),
                              "\(def.shortName) (\(def.id)): domyślna \(value) parametru "
                                  + "\(codeRef) \(def.paramNames[codeRef]) poza \(range)")
            }
        }
    }

    /// Zawężenia zakresów opisują istniejące parametry i mieszczą się w 0…127.
    func testParameterRangesAreWellFormed() {
        for def in ModuleDatabase.all {
            for codeRef in 0 ..< max(def.paramNames.count, 32) {
                guard let range = ParameterRangeDatabase.range(moduleTypeID: def.id,
                                                               codeRef: codeRef)
                else { continue }
                XCTAssertLessThan(codeRef, def.paramNames.count,
                                  "\(def.shortName) (\(def.id)): zakres dla nieistniejącego "
                                      + "parametru \(codeRef)")
                XCTAssertGreaterThanOrEqual(range.lowerBound, 0, "\(def.shortName) p\(codeRef)")
                XCTAssertLessThanOrEqual(range.upperBound, 127, "\(def.shortName) p\(codeRef)")
                XCTAssertLessThan(range.lowerBound, range.upperBound,
                                  "\(def.shortName) p\(codeRef): zakres pusty lub odwrócony")
            }
        }
    }

    /// Panel Gen1 i baza modułów muszą widzieć tyle samo gniazd — indeksy `CodeRef`
    /// gniazd są kluczem do kabli w patchu, więc rozjazd zrywa połączenia.
    func testConnectorCountsAgreeBetweenDatabases() {
        eachModule { def, ui in
            XCTAssertEqual(ui.inputs.count, def.inputs.count,
                           "\(def.shortName) (\(def.id)): wejścia panel \(ui.inputs.count) "
                               + "vs baza \(def.inputs.count)")
            XCTAssertEqual(ui.outputs.count, def.outputs.count,
                           "\(def.shortName) (\(def.id)): wyjścia panel \(ui.outputs.count) "
                               + "vs baza \(def.outputs.count)")
        }
    }

    /// Kolor gniazda na panelu jest ZGODNY z typem sygnału w bazie modułów.
    ///
    /// Nie „identyczny": to dwa różne słowniki. Pliki Gen1 znają tylko trzy typy
    /// (`Audio`/`Control`/`Logic`), a `ModuleDatabase` niesie bogatsze typy protokołu
    /// G2 z gniazdami dwukolorowymi. `pitchOrControl` może więc wystąpić na panelu
    /// jako audio albo control, a `logicOrControl` jako logic albo control. Test łapie
    /// realny rozjazd (audio ↔ logic), nie tę znaną różnicę słowników.
    func testConnectorColoursAgreeBetweenDatabases() {
        func allowed(_ color: ConnectorColor) -> Set<BVSignalType> {
            switch color {
            case .audio: [.audio]
            case .control: [.control]
            case .logic: [.logic]
            case .pitchOrControl: [.pitchOrControl, .audio, .control]
            case .logicOrControl: [.logicOrControl, .logic, .control]
            }
        }
        eachModule { def, ui in
            func check(_ conns: [BVConnector], _ defs: [ConnectorDef], _ what: String) {
                for (index, conn) in conns.enumerated() where index < defs.count {
                    XCTAssertTrue(allowed(defs[index].color).contains(conn.signalType),
                                  "\(def.shortName) (\(def.id)): \(what) \(index) "
                                      + "\(defs[index].name) — panel \(conn.signalType), "
                                      + "baza \(defs[index].color)")
                }
            }
            check(ui.inputs, def.inputs, "wejście")
            check(ui.outputs, def.outputs, "wyjście")
        }
    }
}
