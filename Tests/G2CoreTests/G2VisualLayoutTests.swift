@testable import G2Core
import XCTest

/// Rozkład strumienia wizualnego liczymy raz na układ patcha, a nie przy każdym pakiecie
/// (patrz `G2VisualLayout`). Te testy pilnują dwóch rzeczy: że plan opisuje ten sam
/// strumień co dawne liczenie „w locie", i że odcisk struktury zmienia się dokładnie wtedy,
/// kiedy trzeba — inaczej wskaźniki albo przestałyby nadążać za edycją, albo przeliczałyby
/// się bez powodu.
final class G2VisualLayoutTests: XCTestCase {
    private func patch(voice: [(id: Int, typeID: Int)], fx: [(id: Int, typeID: Int)] = []) -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = voice.map { G2Module(id: $0.id, typeID: $0.typeID, area: .voice) }
        patch.fxModules = fx.map { G2Module(id: $0.id, typeID: $0.typeID, area: .fx) }
        return patch
    }

    /// 2-Out (typ 4) = 2 wskaźniki, SeqCtr (154) = grupa diod, Mix4-1C (123) = 1 wskaźnik.
    func testLayoutPlacesEveryModuleWhereTheStreamExpectsIt() {
        let layout = G2VisualLayout(patch: patch(voice: [(1, 4), (2, 154), (3, 123)], fx: [(1, 4)]))
        XCTAssertEqual(layout.meters.map(\.firstEntry), [0, 3, 4])
        XCTAssertEqual(layout.meters.map(\.count), [2, 1, 2])
        XCTAssertEqual(layout.groups.map(\.entry), [2])
        XCTAssertEqual(layout.groups.map(\.moduleID), [2])
        XCTAssertEqual(layout.entryCount, 6)
    }

    /// Diody `0x39` numerowane są przez CAŁY patch, a moduł z grupą nie wnosi do nich nic.
    func testSingleLedIndicesSkipModulesThatHaveAGroup() {
        // EnvADSR (typ 20) ma jedną diodę; SeqCtr ma grupę, więc w `0x39` nie ma go wcale.
        let layout = G2VisualLayout(patch: patch(voice: [(1, 20), (2, 154), (3, 20)]))
        XCTAssertEqual(layout.leds.map(\.moduleID), [1, 3])
        XCTAssertEqual(layout.leds.map(\.index), [0, 1])
    }

    /// Plan liczony z góry musi dawać dokładnie ten sam wynik, co dekodowanie prosto
    /// z patcha — to ta sama droga, tylko wykonana raz zamiast czterdzieści razy na sekundę.
    func testDecodingThroughTheLayoutMatchesDecodingFromThePatch() {
        let patch = patch(voice: [(1, 4), (2, 154), (3, 123)], fx: [(1, 4)])
        let payload: [UInt8] = [
            0x00,
            0x0A, 0x00,
            0x14, 0x00,
            0x05, 0x00,
            0x1E, 0x00,
            0x28, 0x00,
            0x32, 0x00,
        ]
        let viaLayout = G2VisualStream.decodeVolumeData(payload, layout: G2VisualLayout(patch: patch))
        XCTAssertEqual(viaLayout, G2VisualStream.decodeVolumeData(payload, patch: patch))
        XCTAssertEqual(viaLayout.meters.map(\.values), [[10, 20], [30], [40, 50]])
        XCTAssertEqual(viaLayout.ledGroups.map(\.value), [5])
    }

    /// Odcisk zmienia się przy zmianie STRUKTURY — bo wtedy przesuwa się cały strumień.
    func testSignatureFollowsStructuralChanges() {
        let base = patch(voice: [(1, 4), (2, 154)])
        var added = base
        added.voiceModules.append(G2Module(id: 3, typeID: 123, area: .voice))
        XCTAssertNotEqual(G2VisualLayout.signature(of: base), G2VisualLayout.signature(of: added))

        var retyped = base
        retyped.voiceModules[1].typeID = 121
        XCTAssertNotEqual(G2VisualLayout.signature(of: base), G2VisualLayout.signature(of: retyped))
    }

    /// …i NIE zmienia się przy obrocie gałki ani zmianie nazwy: pozycja modułu w strumieniu
    /// od nich nie zależy, więc plan zostaje ten sam.
    func testSignatureIgnoresParameterAndLabelChanges() {
        let base = patch(voice: [(1, 4), (2, 154)])
        var edited = base
        edited.voiceModules[0].parameters = [42]
        edited.voiceModules[0].label = "Main out"
        edited.voiceModules[1].column = 7
        XCTAssertEqual(G2VisualLayout.signature(of: base), G2VisualLayout.signature(of: edited))
    }
}
