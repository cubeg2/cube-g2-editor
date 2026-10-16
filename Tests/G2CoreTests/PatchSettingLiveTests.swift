// PatchSettingLiveTests.swift
// Ustawienia patcha z arkusza Patch Settings (Glide, Bend, Vibrato, Arpeggiator…)
// jako zmiana NA ŻYWO. Do 2026-09-09 suwaki tego arkusza były podpięte wprost do
// modelu i nie wysyłały niczego — Nord grał dalej po staremu.
//
// Adresowanie: numer grupy sekcji 0x4d obszaru 2 jest numerem modułu, pozycja
// w grupie numerem parametru. Ta sama droga co gałka morfu (moduł 1), sprawdzona
// na Nordzie → [[Docs/ui/morphs]].
// ⚠️ Te testy sprawdzają, co edytor WYSYŁA. Że Nord to przyjmuje, potwierdzi
// dopiero sesja na sprzęcie → [[Docs/roadmap]].

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class PatchSettingLiveTests: XCTestCase {
    private struct Sent: Equatable {
        let slot: Int
        let moduleID: Int
        let paramIndex: Int
        let value: Int
        let variation: Int
    }

    private func makeState() -> (PatchState, () -> [Sent]) {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        var patch = G2Patch()
        patch.ensureRuntimeVariations()
        state.slots = [patch]
        let box = SentBox()
        state.onPatchSettingChange = { slot, moduleID, paramIndex, value, variation in
            box.entries.append(Sent(slot: slot, moduleID: moduleID, paramIndex: paramIndex,
                                    value: value, variation: variation))
        }
        return (state, { box.entries })
    }

    private final class SentBox {
        var entries: [Sent] = []
    }

    /// `groupsByEvent = false` znaczy, że grupę trzeba otworzyć samemu — inaczej
    /// `NSUndoManager` rzuca wyjątkiem przy pierwszej rejestracji.
    private func undoStep(on state: PatchState, _ action: () -> Void) {
        state.undoManager.beginUndoGrouping()
        action()
        state.undoManager.endUndoGrouping()
    }

    // MARK: - Adresy

    /// Każde ustawienie ma inny adres (moduł, parametr) — gdyby dwa się pokrywały,
    /// jedno nadpisywałoby drugie na urządzeniu.
    func testEverySettingHasItsOwnAddress() {
        var seen = Set<String>()
        for setting in G2PatchSetting.allCases {
            let key = "\(setting.module).\(setting.param)"
            XCTAssertTrue(seen.insert(key).inserted, "adres \(key) powtarza się przy \(setting.label)")
        }
        XCTAssertEqual(G2PatchSetting.allCases.count, 15)
    }

    /// Układ grup musi zgadzać się z tym, czego oczekuje parser sekcji 0x4d:
    /// grupy 2–7, wpisy 2/2/2/3/4/2 (grupa 1 to morfy, modelowane osobno).
    func testGroupLayoutMatchesTheSectionFormat() {
        XCTAssertNil(G2PatchSetting.fields(inModule: 0))
        XCTAssertNil(G2PatchSetting.fields(inModule: 1), "grupa 1 to morfy, nie zwykłe ustawienia")
        XCTAssertEqual(G2PatchSetting.fields(inModule: 2)?.count, 2)
        XCTAssertEqual(G2PatchSetting.fields(inModule: 3)?.count, 2)
        XCTAssertEqual(G2PatchSetting.fields(inModule: 4)?.count, 2)
        XCTAssertEqual(G2PatchSetting.fields(inModule: 5)?.count, 3)
        XCTAssertEqual(G2PatchSetting.fields(inModule: 6)?.count, 4)
        XCTAssertEqual(G2PatchSetting.fields(inModule: 7)?.count, 2)
        XCTAssertNil(G2PatchSetting.fields(inModule: 8))
    }

    // MARK: - Wysyłka

    func testChangingASettingSendsItToTheDevice() {
        let (state, sent) = makeState()
        undoStep(on: state) { state.setPatchSetting(.glideTime, value: 42) }

        XCTAssertEqual(sent(), [Sent(slot: 0, moduleID: 3, paramIndex: 1, value: 42, variation: 0)])
        XCTAssertEqual(state.patchSetting(.glideTime), 42)
    }

    /// Wysyłka idzie do wariacji, którą edytuje reszta programu — nie do zerowej.
    func testSettingGoesToTheActiveVariation() {
        let (state, sent) = makeState()
        state.slots[0].setActiveVariation(3)
        undoStep(on: state) { state.setPatchSetting(.bend, value: 1) }

        XCTAssertEqual(sent(), [Sent(slot: 0, moduleID: 4, paramIndex: 0, value: 1, variation: 3)])
        XCTAssertEqual(state.slots[0].variationSettings[3].bend, 1)
        XCTAssertEqual(state.slots[0].variationSettings[0].bend, 0, "inne wariacje zostają nietknięte")
    }

    /// Wartość bez zmiany nie generuje ruchu na magistrali — przeciągnięcie suwaka
    /// w tę i z powrotem nie ma zasypywać urządzenia powtórkami.
    func testUnchangedValueSendsNothing() {
        let (state, sent) = makeState()
        undoStep(on: state) { state.setPatchSetting(.sustain, value: 0) }
        XCTAssertTrue(sent().isEmpty)
    }

    /// Glide ma w G2 trzy wartości (Auto, Normal, Off). Do 2026-10-15 arkusz miał na nim
    /// suwak 0–127 i można było wysłać do Norda np. 87 — wartość, której urządzenie nie zna.
    func testValueIsClampedToTheSettingsOwnRange() {
        let (state, sent) = makeState()
        undoStep(on: state) { state.setPatchSetting(.glide, value: 87) }
        XCTAssertEqual(state.patchSetting(.glide), 2)
        XCTAssertEqual(sent().last?.value, 2)
    }

    /// Zakresy i nazwy jak w oryginale (tabela ustawień patcha w edytorze BVerhue).
    func testRangesAndValueNamesFollowTheOriginal() {
        XCTAssertEqual(G2PatchSetting.patchVolume.range, 0 ... 127)
        XCTAssertNil(G2PatchSetting.patchVolume.valueNames)
        XCTAssertEqual(G2PatchSetting.activeMuted.valueNames, ["Off", "On"])
        XCTAssertEqual(G2PatchSetting.glide.valueNames, ["Auto", "Normal", "Off"])
        XCTAssertEqual(G2PatchSetting.semitone.range, 0 ... 23)
        XCTAssertEqual(G2PatchSetting.semitone.valueText(0), "1 semi")
        XCTAssertEqual(G2PatchSetting.semitone.valueText(23), "24 semi")
        XCTAssertEqual(G2PatchSetting.arpTime.valueNames, ["1/8", "1/8T", "1/16", "1/16T"])
        XCTAssertEqual(G2PatchSetting.arpOctaves.valueText(0), "1")
        XCTAssertEqual(G2PatchSetting.octaveShift.range, 0 ... 4)
        XCTAssertEqual(G2PatchSetting.octaveShift.valueText(2), "0")
        XCTAssertEqual(G2PatchSetting.vibratoRate.valueText(64), "64")
        for setting in G2PatchSetting.allCases {
            if let names = setting.valueNames {
                XCTAssertEqual(names.count, setting.range.count, setting.label)
            }
        }
    }

    /// `patchVolume` startuje z 127, więc próba wpisania większej wartości niczego
    /// nie zmienia — i nic nie leci do urządzenia.
    func testClampedValueEqualToCurrentSendsNothing() {
        let (state, sent) = makeState()
        undoStep(on: state) { state.setPatchSetting(.patchVolume, value: 500) }
        XCTAssertEqual(state.patchSetting(.patchVolume), 127)
        XCTAssertTrue(sent().isEmpty)
    }

    // MARK: - Cofanie

    func testChangeIsUndoable() {
        let (state, _) = makeState()
        undoStep(on: state) { state.setPatchSetting(.arpTime, value: 3) }
        XCTAssertEqual(state.patchSetting(.arpTime), 3)

        state.undoManager.undo()
        XCTAssertEqual(state.patchSetting(.arpTime), 0)
    }

    /// Przeciągnięcie suwaka to jedna pozycja w historii, nie setka: w obrębie gestu
    /// rejestruje się tylko pierwsza wartość, tak samo jak przy gałce modułu.
    func testOneGestureIsOneUndoStep() {
        let (state, sent) = makeState()
        undoStep(on: state) {
            state.beginParameterGesture()
            for value in 1 ... 20 {
                state.setPatchSetting(.vibratoRate, value: value)
            }
            state.endParameterGesture()
        }
        XCTAssertEqual(state.patchSetting(.vibratoRate), 20)
        XCTAssertEqual(sent().count, 20, "każda wartość leci osobno — urządzenie ma nadążać za suwakiem")

        state.undoManager.undo()
        XCTAssertEqual(state.patchSetting(.vibratoRate), 0, "cały gest cofa się raz")
        XCTAssertFalse(state.undoManager.canUndo)
    }
}
