import CoreGraphics

// Źródło: BVE.NMG2Data.pas, MiniVUDefs array[0..28]
// 29 wpisów, 18 modułów — wszystkie Orientation:otVertical.
// Pozycje XPos/YPos są w przestrzeni BVerhue 256-coord → przeliczone na screen pt (× 140/256).

private let s: CGFloat = 140.0 / 256.0

public enum MiniVUDatabase {
    public static let defs: [BVMiniVUDef] = [
        // 4-Out (ModuleID 3) — 4 VU
        .init(moduleID: 3, id: 12, xPt: 153 * s, yPt: 10 * s, groupID: 0),
        .init(moduleID: 3, id: 13, xPt: 179 * s, yPt: 10 * s, groupID: 1),
        .init(moduleID: 3, id: 14, xPt: 205 * s, yPt: 10 * s, groupID: 2),
        .init(moduleID: 3, id: 15, xPt: 231 * s, yPt: 10 * s, groupID: 3),
        // 2-Out (ModuleID 4) — 2 VU
        .init(moduleID: 4, id: 9, xPt: 205 * s, yPt: 10 * s, groupID: 0),
        .init(moduleID: 4, id: 11, xPt: 231 * s, yPt: 10 * s, groupID: 1),
        // Mix4-1B (ModuleID 19) — 1 VU
        .init(moduleID: 19, id: 14, xPt: 231 * s, yPt: 10 * s, groupID: 0),
        // Eq2Band (ModuleID 32) — 1 VU
        .init(moduleID: 32, id: 16, xPt: 227 * s, yPt: 25 * s, groupID: 0),
        // Eq3band (ModuleID 33) — 1 VU
        .init(moduleID: 33, id: 16, xPt: 227 * s, yPt: 40 * s, groupID: 0),
        // Mix8-1B (ModuleID 40) — 1 VU
        .init(moduleID: 40, id: 22, xPt: 242 * s, yPt: 27 * s, groupID: 0),
        // FltVoice (ModuleID 45) — 1 VU
        .init(moduleID: 45, id: 26, xPt: 230 * s, yPt: 40 * s, groupID: 0),
        // MixStereo (ModuleID 48) — 2 VU
        .init(moduleID: 48, id: 2, xPt: 207 * s, yPt: 55 * s, groupID: 0),
        .init(moduleID: 48, id: 7, xPt: 231 * s, yPt: 55 * s, groupID: 1),
        // FltPhase (ModuleID 102) — 1 VU
        .init(moduleID: 102, id: 31, xPt: 227 * s, yPt: 55 * s, groupID: 0),
        // EqPeak (ModuleID 103) — 1 VU
        .init(moduleID: 103, id: 16, xPt: 227 * s, yPt: 40 * s, groupID: 0),
        // Mix8-1A (ModuleID 116) — 1 VU
        .init(moduleID: 116, id: 19, xPt: 231 * s, yPt: 10 * s, groupID: 0),
        // Mix4-1C (ModuleID 123) — 1 VU
        .init(moduleID: 123, id: 13, xPt: 242 * s, yPt: 27 * s, groupID: 0),
        // Fx-In (ModuleID 127) — 2 VU
        .init(moduleID: 127, id: 4, xPt: 205 * s, yPt: 10 * s, groupID: 0),
        .init(moduleID: 127, id: 1, xPt: 231 * s, yPt: 10 * s, groupID: 1),
        // Mix4-1S (ModuleID 140) — 2 VU
        .init(moduleID: 140, id: 29, xPt: 225 * s, yPt: 27 * s, groupID: 0),
        .init(moduleID: 140, id: 12, xPt: 242 * s, yPt: 27 * s, groupID: 1),
        // MixFader (ModuleID 161) — 1 VU
        .init(moduleID: 161, id: 45, xPt: 242 * s, yPt: 102 * s, groupID: 0),
        // FltComb (ModuleID 162) — 1 VU
        .init(moduleID: 162, id: 12, xPt: 227 * s, yPt: 40 * s, groupID: 0),
        // 2-In (ModuleID 170) — 2 VU (GroupID: 0=L at 205, 1=R at 231)
        .init(moduleID: 170, id: 3, xPt: 205 * s, yPt: 10 * s, groupID: 0),
        .init(moduleID: 170, id: 2, xPt: 231 * s, yPt: 10 * s, groupID: 1),
        // 4-In (ModuleID 171) — 4 VU
        .init(moduleID: 171, id: 7, xPt: 153 * s, yPt: 10 * s, groupID: 0),
        .init(moduleID: 171, id: 5, xPt: 179 * s, yPt: 10 * s, groupID: 1),
        .init(moduleID: 171, id: 3, xPt: 205 * s, yPt: 10 * s, groupID: 2),
        .init(moduleID: 171, id: 2, xPt: 231 * s, yPt: 10 * s, groupID: 3),
    ]

    public static func defs(forModuleID moduleID: Int) -> [BVMiniVUDef] {
        defs.filter { $0.moduleID == moduleID }
    }
}
