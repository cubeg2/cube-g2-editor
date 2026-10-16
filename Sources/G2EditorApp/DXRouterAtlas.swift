// DXRouterAtlas.swift
//
// The 32 DX7 algorithm diagrams are reproduced faithfully on purpose.
//
// This is a deliberate usability decision, reviewed and confirmed 2026-09-02, not
// an incidental similarity. Many musicians identify an FM algorithm by its picture
// rather than by its number: the diagram *is* the information. Redrawing the same
// topology in a different visual style would therefore destroy recognition instead
// of aiding it, the way sketching a sine wave as a square would. Users coming from
// the original Nord Modular G2 Editor must be able to see at a glance which
// algorithm they are on.
//
// Contents: modulation routes for algorithms 7-32 and feedback paths for
// algorithms 1-6, stored as scalable polylines and stroked by Canvas.
// Runtime status: ACTIVE for the DXRouter graph.
//
// The geometry follows the diagram layout of the original editor.

import CoreGraphics

/// Punkt siatki oryginalnego atlasu DXRoutera (137×65 px).
struct DXAtlasPoint {
    let x: CGFloat
    let y: CGFloat
}

/// Wektorowe ścieżki jednego algorytmu DXRoutera.
struct DXAtlasAlgorithm {
    let modulation: [[DXAtlasPoint]]
    let feedback: [[DXAtlasPoint]]
    let arrowX: CGFloat
}

/// Dokładne ścieżki algorytmów 7–32, rysowane jako skalowalne krzywe Canvasu.
enum DXRouterAtlas {
    private static func dxPath(_ coordinates: Int...) -> [DXAtlasPoint] {
        precondition(coordinates.count.isMultiple(of: 2))
        return stride(from: 0, to: coordinates.count, by: 2).map {
            DXAtlasPoint(x: CGFloat(coordinates[$0]), y: CGFloat(coordinates[$0 + 1]))
        }
    }

    /// Wektorowe boxy Canvasu są o włos głębsze niż zielone prostokąty w atlasie.
    /// Dolne szyny feedbacku z Y=26 (górny rząd) i Y=51 (dolny rząd) wyglądały przez to
    /// jak przyklejone do boxu, a ich pionowe powroty ginęły pod jego wypełnieniem.
    /// Przesunięcie o 1 px atlasu zachowuje wszystkie końce połączeń, ale daje taki sam
    /// oddech jak pozostałe pętle.
    static func displayFeedbackPoint(_ point: DXAtlasPoint) -> DXAtlasPoint {
        switch point.y {
        case 26, 51: DXAtlasPoint(x: point.x, y: point.y + 1)
        default: point
        }
    }

    /// Wybrane klatki atlasu prowadzą dolną zieloną szynę na pomocniczym Y=51, zamiast na
    /// poziomie magistrali przy strzałce (`Y=56`). Po powiększeniu różnica jest wyraźna,
    /// więc te poziome odcinki rysujemy na wspólnej dolnej szynie. Nie zmienia to ich
    /// źródła, celu ani kolejności połączeń.
    static func displayModulationPoint(_ point: DXAtlasPoint, algorithm: Int) -> DXAtlasPoint {
        guard point.y == 51 else { return point }
        switch algorithm {
        case 9 ... 15, 18, 20, 27:
            return DXAtlasPoint(x: point.x, y: 56)
        default:
            return point
        }
    }

    /// Sprzężenie algorytmów 1–6 odczytane z tych samych klatek atlasu co ścieżki 7–32.
    /// Dzięki temu pętla ma identyczny kształt i rozmiar w całym zestawie 32 ekranów:
    /// wyjście górą gniazda, obejście bokiem, powrót do dolnej krawędzi celu.
    /// Algorytmy 4 i 6 mają sprzężenie obejmujące kilka operatorów (6→4 oraz 6→5),
    /// więc ich obejście biegnie dalej — resztę kształtu zachowują wspólną.
    static let firstSixFeedback: [[DXAtlasPoint]] = [
        /* 1 */ dxPath(117, 10, 117, 6, 130, 6, 130, 26, 121, 26, 121, 23),
        /* 2 */ dxPath(19, 10, 19, 6, 33, 6, 33, 27, 23, 27, 23, 23),
        /* 3 */ dxPath(117, 10, 117, 6, 130, 6, 130, 26, 121, 26, 121, 23),
        /* 4 */ dxPath(117, 10, 117, 2, 55, 2, 55, 27, 65, 27, 65, 23),
        /* 5 */ dxPath(117, 10, 117, 6, 130, 6, 130, 26, 121, 26, 121, 23),
        /* 6 */ dxPath(117, 10, 117, 6, 130, 6, 130, 52, 121, 52, 121, 48),
    ]

    static let algorithms: [DXAtlasAlgorithm] = [
        /*  7 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 23, 19, 35),
                dxPath(68, 23, 68, 35),
                dxPath(117, 23, 117, 35),
                dxPath(72, 35, 72, 30, 93, 30, 93, 56, 117, 56, 117, 48),
                dxPath(19, 48, 19, 56, 48, 56),
                dxPath(68, 48, 68, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(117, 10, 117, 6, 130, 6, 130, 26, 121, 26, 121, 23),
            ],
            arrowX: 48
        ),
        /*  8 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 23, 19, 35),
                dxPath(68, 23, 68, 35),
                dxPath(117, 23, 117, 35),
                dxPath(72, 35, 72, 30, 93, 30, 93, 56, 117, 56, 117, 48),
                dxPath(19, 48, 19, 56, 48, 56),
                dxPath(68, 48, 68, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(69, 10, 69, 7, 81, 7, 81, 26, 71, 26, 71, 23),
            ],
            arrowX: 48
        ),
        /*  9 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 23, 19, 35),
                dxPath(68, 23, 68, 35),
                dxPath(117, 23, 117, 35),
                dxPath(72, 35, 72, 31, 97, 31, 97, 51, 117, 51, 117, 48),
                dxPath(19, 48, 19, 56, 48, 56),
                dxPath(68, 48, 68, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(19, 10, 19, 6, 34, 6, 34, 26, 23, 26, 23, 23),
            ],
            arrowX: 48
        ),
        /* 10 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 10, 19, 6, 44, 6, 44, 51, 68, 51, 68, 48),
                dxPath(68, 10, 68, 3, 104, 3, 104, 26, 117, 26, 117, 23),
                dxPath(71, 10, 71, 7, 97, 7, 97, 51, 117, 51, 117, 48),
                dxPath(19, 23, 19, 35),
                dxPath(68, 23, 68, 26, 89, 26, 89, 56, 48, 56),
                dxPath(19, 48, 19, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(68, 35, 68, 32, 81, 32, 81, 51, 71, 51, 71, 48),
            ],
            arrowX: 48
        ),
        /* 11 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 10, 19, 6, 44, 6, 44, 51, 68, 51, 68, 48),
                dxPath(68, 10, 68, 3, 104, 3, 104, 26, 116, 26, 116, 23),
                dxPath(71, 10, 71, 7, 97, 7, 97, 51, 117, 51, 117, 48),
                dxPath(19, 23, 19, 35),
                dxPath(68, 23, 68, 26, 89, 26, 89, 56, 48, 56),
                dxPath(19, 48, 19, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(117, 10, 117, 6, 130, 6, 130, 26, 119, 26, 119, 23),
            ],
            arrowX: 48
        ),
        /* 12 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 23, 19, 35),
                dxPath(64, 23, 64, 35),
                dxPath(117, 23, 117, 27, 68, 27, 68, 35),
                dxPath(72, 35, 72, 31, 97, 31, 97, 51, 117, 51, 117, 48),
                dxPath(19, 48, 19, 56, 48, 56),
                dxPath(68, 48, 68, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(19, 10, 19, 6, 34, 6, 34, 26, 23, 26, 23, 23),
            ],
            arrowX: 48
        ),
        /* 13 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 23, 19, 35),
                dxPath(64, 23, 64, 35),
                dxPath(117, 23, 117, 27, 68, 27, 68, 35),
                dxPath(72, 35, 72, 31, 97, 31, 97, 51, 117, 51, 117, 48),
                dxPath(19, 48, 19, 56, 48, 56),
                dxPath(68, 48, 68, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(19, 10, 19, 6, 34, 6, 34, 26, 23, 26, 23, 23),
                dxPath(117, 10, 117, 5, 130, 5, 130, 27, 121, 27, 121, 23),
            ],
            arrowX: 48
        ),
        /* 14 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(68, 10, 68, 3, 104, 3, 104, 26, 116, 26, 116, 23),
                dxPath(71, 10, 71, 7, 97, 7, 97, 51, 117, 51, 117, 48),
                dxPath(19, 23, 19, 35),
                dxPath(68, 23, 68, 35),
                dxPath(19, 48, 19, 56, 48, 56),
                dxPath(68, 48, 68, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(117, 10, 117, 6, 130, 6, 130, 26, 119, 26, 119, 23),
            ],
            arrowX: 48
        ),
        /* 15 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(68, 10, 68, 3, 104, 3, 104, 26, 116, 26, 116, 23),
                dxPath(71, 10, 71, 7, 97, 7, 97, 51, 117, 51, 117, 48),
                dxPath(19, 23, 19, 35),
                dxPath(68, 23, 68, 35),
                dxPath(19, 48, 19, 56, 48, 56),
                dxPath(68, 48, 68, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(19, 10, 19, 6, 34, 6, 34, 26, 23, 26, 23, 23),
            ],
            arrowX: 48
        ),
        /* 16 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(17, 23, 17, 35),
                dxPath(68, 23, 68, 35),
                dxPath(117, 23, 117, 35),
                dxPath(21, 35, 21, 28, 45, 28, 45, 51, 68, 51, 68, 48),
                dxPath(25, 35, 25, 32, 38, 32, 38, 56, 117, 56, 117, 48),
                dxPath(19, 48, 19, 59),
            ],
            feedback: [
                dxPath(117, 10, 117, 6, 130, 6, 130, 26, 121, 26, 121, 23),
            ],
            arrowX: 19
        ),
        /* 17 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(17, 23, 17, 35),
                dxPath(68, 23, 68, 35),
                dxPath(117, 23, 117, 35),
                dxPath(21, 35, 21, 29, 45, 29, 45, 51, 68, 51, 68, 48),
                dxPath(25, 35, 25, 32, 38, 32, 38, 56, 117, 56, 117, 48),
                dxPath(19, 48, 19, 59),
            ],
            feedback: [
                dxPath(19, 10, 19, 6, 34, 6, 34, 26, 21, 26, 21, 23),
            ],
            arrowX: 19
        ),
        /* 18 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(68, 10, 68, 6, 92, 6, 92, 56, 117, 56, 117, 48),
                dxPath(17, 23, 17, 35),
                dxPath(68, 23, 68, 27, 21, 27, 21, 35),
                dxPath(117, 23, 117, 35),
                dxPath(25, 35, 25, 32, 45, 32, 45, 51, 68, 51, 68, 48),
                dxPath(19, 48, 19, 59),
            ],
            feedback: [
                dxPath(68, 35, 68, 32, 83, 32, 83, 51, 72, 51, 72, 48),
            ],
            arrowX: 19
        ),
        /* 19 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 10, 19, 6, 44, 6, 44, 51, 68, 51, 68, 48),
                dxPath(68, 10, 68, 3, 99, 3, 99, 26, 112, 26, 112, 23),
                dxPath(19, 23, 19, 35),
                dxPath(68, 23, 68, 26, 84, 26, 84, 56),
                dxPath(117, 23, 117, 35),
                dxPath(19, 48, 19, 56, 48, 56),
                dxPath(117, 48, 117, 56, 84, 56),
                dxPath(48, 56, 84, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(117, 10, 117, 5, 131, 5, 131, 26, 121, 26, 121, 23),
            ],
            arrowX: 48
        ),
        /* 20 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 10, 19, 6, 44, 6, 44, 32),
                dxPath(68, 10, 68, 3, 104, 3, 104, 26, 117, 26, 117, 23),
                dxPath(71, 10, 71, 7, 97, 7, 97, 51, 117, 51, 117, 48),
                dxPath(19, 23, 19, 26, 4, 26, 4, 56, 19, 56),
                dxPath(68, 23, 68, 26, 89, 26, 89, 56, 48, 56),
                dxPath(44, 32, 19, 32, 19, 35),
                dxPath(44, 32, 44, 51, 68, 51, 68, 48),
                dxPath(19, 48, 19, 56),
                dxPath(19, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(68, 35, 68, 32, 81, 32, 81, 51, 71, 51, 71, 48),
            ],
            arrowX: 48
        ),
        /* 21 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 10, 19, 6, 44, 6, 44, 32),
                dxPath(68, 10, 68, 6, 104, 6, 104, 26, 115, 26, 115, 23),
                dxPath(19, 23, 19, 26, 4, 26, 4, 56, 19, 56),
                dxPath(68, 23, 68, 26, 89, 26, 89, 56),
                dxPath(118, 23, 118, 35),
                dxPath(44, 32, 19, 32, 19, 35),
                dxPath(44, 32, 44, 51, 68, 51, 68, 48),
                dxPath(19, 48, 19, 56),
                dxPath(117, 48, 117, 56, 89, 56),
                dxPath(19, 56, 48, 56),
                dxPath(48, 56, 89, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(68, 35, 68, 32, 81, 32, 81, 51, 71, 51, 71, 48),
            ],
            arrowX: 48
        ),
        /* 22 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(68, 10, 68, 6, 96, 6, 96, 26, 112, 26, 112, 23),
                dxPath(19, 23, 19, 35),
                dxPath(68, 23, 68, 26, 44, 26, 44, 56),
                dxPath(115, 23, 115, 31, 68, 31, 68, 35),
                dxPath(118, 23, 118, 35),
                dxPath(19, 48, 19, 56, 44, 56),
                dxPath(68, 48, 68, 56),
                dxPath(117, 48, 117, 56, 68, 56),
                dxPath(44, 56, 68, 56),
                dxPath(68, 56, 68, 59),
            ],
            feedback: [
                dxPath(117, 10, 117, 6, 130, 6, 130, 26, 122, 26, 122, 23),
            ],
            arrowX: 68
        ),
        /* 23 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 10, 19, 6, 49, 6, 49, 51, 68, 51, 68, 48),
                dxPath(68, 10, 68, 6, 96, 6, 96, 27, 113, 27, 113, 23),
                dxPath(19, 23, 19, 30, 36, 30, 36, 56),
                dxPath(68, 23, 68, 27, 86, 27, 86, 56),
                dxPath(118, 23, 118, 35),
                dxPath(19, 48, 19, 56, 36, 56),
                dxPath(117, 48, 117, 56, 86, 56),
                dxPath(36, 56, 68, 56),
                dxPath(68, 56, 86, 56),
                dxPath(68, 56, 68, 59),
            ],
            feedback: [
                dxPath(117, 10, 117, 6, 130, 6, 130, 26, 122, 26, 122, 23),
            ],
            arrowX: 68
        ),
        /* 24 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(68, 10, 68, 6, 96, 6, 96, 26, 112, 26, 112, 23),
                dxPath(19, 23, 19, 30, 36, 30, 36, 56),
                dxPath(68, 23, 68, 26, 44, 26, 44, 56),
                dxPath(115, 23, 115, 31, 68, 31, 68, 35),
                dxPath(118, 23, 118, 35),
                dxPath(19, 48, 19, 56, 36, 56),
                dxPath(68, 48, 68, 56),
                dxPath(117, 48, 117, 56, 68, 56),
                dxPath(36, 56, 44, 56),
                dxPath(44, 56, 68, 56),
                dxPath(68, 56, 68, 59),
            ],
            feedback: [
                dxPath(117, 10, 117, 6, 130, 6, 130, 26, 122, 26, 122, 23),
            ],
            arrowX: 68
        ),
        /* 25 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(68, 10, 68, 3, 94, 3, 94, 27, 113, 27, 113, 23),
                dxPath(19, 23, 19, 28, 36, 28, 36, 56),
                dxPath(68, 23, 68, 28, 51, 28, 51, 56),
                dxPath(117, 23, 117, 35),
                dxPath(19, 48, 19, 56, 36, 56),
                dxPath(68, 48, 68, 56),
                dxPath(117, 48, 117, 56, 68, 56),
                dxPath(36, 56, 51, 56),
                dxPath(51, 56, 68, 56),
                dxPath(68, 56, 68, 59),
            ],
            feedback: [
                dxPath(116, 10, 116, 6, 129, 6, 129, 27, 121, 27, 121, 23),
            ],
            arrowX: 68
        ),
        /* 26 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 10, 19, 6, 44, 6, 44, 51, 68, 51, 68, 48),
                dxPath(68, 10, 68, 3, 104, 3, 104, 27, 116, 27, 116, 23),
                dxPath(71, 10, 71, 7, 97, 7, 97, 51, 117, 51, 117, 48),
                dxPath(19, 23, 19, 27, 36, 27, 36, 56),
                dxPath(68, 23, 68, 26, 89, 26, 89, 56, 48, 56),
                dxPath(19, 48, 19, 56, 36, 56),
                dxPath(36, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(116, 10, 116, 6, 129, 6, 129, 27, 119, 27, 119, 23),
            ],
            arrowX: 48
        ),
        /* 27 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 10, 19, 6, 44, 6, 44, 51, 68, 51, 68, 48),
                dxPath(68, 10, 68, 3, 104, 3, 104, 26, 117, 26, 117, 23),
                dxPath(71, 10, 71, 7, 97, 7, 97, 51, 117, 51, 117, 48),
                dxPath(19, 23, 19, 27, 36, 27, 36, 56),
                dxPath(68, 23, 68, 26, 89, 26, 89, 56, 48, 56),
                dxPath(19, 48, 19, 56, 36, 56),
                dxPath(36, 56, 48, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(68, 35, 68, 32, 81, 32, 81, 51, 71, 51, 71, 48),
            ],
            arrowX: 48
        ),
        /* 28 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(68, 10, 68, 6, 91, 6, 91, 51, 113, 51, 113, 48),
                dxPath(19, 23, 19, 35),
                dxPath(68, 23, 68, 35),
                dxPath(117, 23, 117, 26, 133, 26, 133, 56, 68, 56),
                dxPath(19, 48, 19, 56, 48, 56),
                dxPath(68, 48, 68, 56),
                dxPath(48, 56, 68, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(117, 35, 117, 31, 129, 31, 129, 51, 121, 51, 121, 48),
            ],
            arrowX: 48
        ),
        /* 29 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 23, 19, 27, 36, 27, 36, 56),
                dxPath(68, 23, 68, 35),
                dxPath(117, 23, 117, 35),
                dxPath(19, 48, 19, 56, 36, 56),
                dxPath(68, 48, 68, 56),
                dxPath(117, 48, 117, 56, 68, 56),
                dxPath(36, 56, 48, 56),
                dxPath(48, 56, 68, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(117, 10, 117, 7, 130, 7, 130, 27, 121, 27, 121, 23),
            ],
            arrowX: 48
        ),
        /* 30 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(68, 10, 68, 6, 91, 6, 91, 51, 113, 51, 113, 48),
                dxPath(19, 23, 19, 27, 36, 27, 36, 56),
                dxPath(68, 23, 68, 35),
                dxPath(117, 23, 117, 26, 133, 26, 133, 56, 68, 56),
                dxPath(19, 48, 19, 56, 36, 56),
                dxPath(68, 48, 68, 56),
                dxPath(36, 56, 48, 56),
                dxPath(48, 56, 68, 56),
                dxPath(48, 56, 48, 59),
            ],
            feedback: [
                dxPath(117, 35, 117, 31, 129, 31, 129, 51, 121, 51, 121, 48),
            ],
            arrowX: 48
        ),
        /* 31 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 23, 19, 27, 36, 27, 36, 56),
                dxPath(68, 23, 68, 27, 90, 27, 90, 56),
                dxPath(117, 23, 117, 35),
                dxPath(19, 48, 19, 56, 36, 56),
                dxPath(68, 48, 68, 56),
                dxPath(117, 48, 117, 56, 90, 56),
                dxPath(36, 56, 48, 56),
                dxPath(48, 56, 68, 56),
                dxPath(48, 56, 48, 59),
                dxPath(68, 56, 90, 56),
            ],
            feedback: [
                dxPath(117, 10, 117, 7, 130, 7, 130, 27, 121, 27, 121, 23),
            ],
            arrowX: 48
        ),
        /* 32 */ DXAtlasAlgorithm(
            modulation: [
                dxPath(19, 23, 19, 27, 36, 27, 36, 56),
                dxPath(68, 23, 68, 27, 90, 27, 90, 56),
                dxPath(117, 23, 117, 27, 100, 27, 100, 56),
                dxPath(19, 48, 19, 56, 36, 56),
                dxPath(68, 48, 68, 56),
                dxPath(117, 48, 117, 56, 100, 56),
                dxPath(36, 56, 48, 56),
                dxPath(48, 56, 68, 56),
                dxPath(48, 56, 48, 59),
                dxPath(68, 56, 90, 56),
                dxPath(90, 56, 100, 56),
            ],
            feedback: [
                dxPath(117, 10, 117, 7, 130, 7, 130, 27, 121, 27, 121, 23),
            ],
            arrowX: 48
        ),
    ]
}
