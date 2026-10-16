// G2PatchDiff.swift
// Różnica dwóch stanów slotu, wyrażona komendami strukturalnymi protokołu.
// Czysta funkcja — bez USB, bez UI, testowalna bez sprzętu.

import Foundation

/// Co trzeba wysłać do urządzenia, żeby slot przestał pokazywać `old`, a zaczął `new`.
///
/// Kolejność pól JEST kolejnością wysyłki i pochodzi z oryginału:
/// • kasowanie — Patch Data (GenerateDeleteSelectionMolecules) wypuszcza Cable Delete
///   przed Module Delete (tak samo `mouseHandle.c` w G2-Edit);
/// • dodawanie — Patch Data (GetNewModulesMolecules) daje Module New na moduł, potem
///   kable, potem Module Param Dump **ograniczony do nowych modułów**.
///
/// Zmiany, które nie ruszają brzmienia — **nazwa** (`0x33` Module Name), **kolor**
/// (`0x31` Module Recolor) i **pozycja** modułu (`0x34` Module Move) — mają własne pola
/// i własne komendy. Nie wolno ich załatwiać przez Module New na istniejące id:
/// to przebudowałoby moduł i urwało dźwięk. Dlatego moduł liczy się jako „ten sam",
/// dopóki zgadza się para (id, typ); nazwa, kolor i pozycja idą osobno.
///
/// Koloru kabla nie ma tu osobno, bo niesie go już sama komenda `WriteCable` (`0x50`)
/// → [[Docs/usb/protocol-map]].
public struct G2PatchDiff {
    public var cablesToDelete: [G2Cable] = []
    public var modulesToDelete: [G2Module] = []
    public var modulesToAdd: [G2Module] = []
    public var cablesToAdd: [G2Cable] = []
    /// Moduły, które zostają, ale zmieniły etykietę — do wysłania `0x33`.
    public var modulesToRename: [G2Module] = []
    /// Moduły, które zostają, ale zmieniły kolor — do wysłania `0x31`.
    public var modulesToRecolor: [G2Module] = []
    /// Moduły, które zostają, ale przesunęły się w siatce — do wysłania `0x34`.
    /// Przesunięcie jednego modułu spycha sąsiadów, więc lista bywa dłuższa niż jeden.
    public var modulesToMove: [G2Module] = []

    public var isEmpty: Bool {
        cablesToDelete.isEmpty && modulesToDelete.isEmpty
            && modulesToAdd.isEmpty && cablesToAdd.isEmpty
            && modulesToRename.isEmpty && modulesToRecolor.isEmpty && modulesToMove.isEmpty
    }

    /// Tożsamością modułu jest para (obszar, id) **wraz z typem**: podmiana modułu
    /// zostawia to samo id, ale inny `typeID`, i dla urządzenia jest skasowaniem
    /// i dodaniem od nowa.
    ///
    /// Kable liczą się w całości (`G2Cable: Equatable`) — kabel przepięty to dla
    /// urządzenia inny kabel. Kabel dotykający modułu, który znika albo powstaje
    /// na nowo, trafia na obie listy: urządzenie kasuje go razem z modułem, więc
    /// po dodaniu modułu trzeba go wpiąć jeszcze raz.
    public static func between(_ old: G2Patch, _ new: G2Patch) -> G2PatchDiff {
        var diff = G2PatchDiff()
        for area in PatchArea.allCases {
            let oldModules = old.modules(in: area)
            let newModules = new.modules(in: area)
            let oldTypes = Dictionary(oldModules.map { ($0.id, $0.typeID) }, uniquingKeysWith: { first, _ in first })
            let newTypes = Dictionary(newModules.map { ($0.id, $0.typeID) }, uniquingKeysWith: { first, _ in first })

            let removed = oldModules.filter { newTypes[$0.id] != $0.typeID }
            let added = newModules.filter { oldTypes[$0.id] != $0.typeID }
            let rebuilt = Set(removed.map(\.id)).union(added.map(\.id))

            let oldCables = old.cables(in: area)
            let newCables = new.cables(in: area)
            diff.cablesToDelete += oldCables.filter { cable in
                rebuilt.contains(cable.fromModule) || rebuilt.contains(cable.toModule)
                    || !newCables.contains(cable)
            }
            diff.modulesToDelete += removed
            diff.modulesToAdd += added

            // Moduł, który przetrwał (to samo id i typ), ale ma inną etykietę, kolor albo
            // pozycję. Moduł dopiero co dodany pomijamy — Module New niesie wszystkie
            // trzy rzeczy w sobie.
            let oldByID = Dictionary(oldModules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for module in newModules where !rebuilt.contains(module.id) {
                guard let before = oldByID[module.id] else { continue }
                if before.label != module.label { diff.modulesToRename.append(module) }
                if before.color != module.color { diff.modulesToRecolor.append(module) }
                if before.column != module.column || before.row != module.row {
                    diff.modulesToMove.append(module)
                }
            }
            diff.cablesToAdd += newCables.filter { cable in
                rebuilt.contains(cable.fromModule) || rebuilt.contains(cable.toModule)
                    || !oldCables.contains(cable)
            }
        }
        return diff
    }
}
