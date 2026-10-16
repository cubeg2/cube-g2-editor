/// Potwierdzone zakresy parametrów, których nie da się bezpiecznie wywnioskować
/// z samego typu kontrolki BVerhue.
public enum ParameterRangeDatabase {
    /// Zwraca sprzętowy zakres parametru modułu albo `nil`, gdy baza nie ma wpisu.
    public static func range(moduleTypeID: Int, codeRef: Int) -> ClosedRange<Int>? {
        switch moduleTypeID {
        case 3, 4:
            // 4-Out/2-Out Pad (`prtPad_1`): panel ma cztery napisy, ale oryginalny
            // parametr sprzętowy dopuszcza tylko 0 dB i +6 dB. Potwierdzone przez
            // BVerhue Gen2, g2ools oraz korpus patchy (wartość maksymalna 1).
            // Gen3 błędnie rozszerzyło zakres do liczby napisów z panelu.
            codeRef == 2 ? 0 ... 1 : nil
        case 17, 105:
            // ValSw1-2/ValSw2-1 „Value”: typ sprzętowy ma 64 wartości (0...63),
            // pokazywane jako 1...64 przez InfoFunc 114. Pełne 0...127 pozwalało
            // ustawić stany, których oryginalny moduł nie obsługuje.
            codeRef == 0 ? 0 ... 63 : nil
        case 165:
            switch codeRef {
            case 0: 0 ... 31 // DXRouter Algorithm
            case 1: 0 ... 7 // DXRouter Feedback
            default: nil
            }
        case 180:
            // Operator: wartości R/L, poziomu wyjściowego oraz głębokości są zwykłymi
            // liczbami 0...99. Wąskie pola AMod, Vel i RateScale mają skalę 0...7.
            // Bez tych wpisów ogólny zakres 0...127 dawał nieprawidłowe kroki +/-.
            switch codeRef {
            case 3: 0 ... 31 // Freq Coarse — mnożnik częstotliwości 0...31
            case 5: 0 ... 14 // Detune
            case 6, 7, 16: 0 ... 7 // Vel, RateScale, AMod
            case 4, 8 ... 15, 17, 19, 21, 22: 0 ... 99 // Fine, R/L, BrPoint, depths, OutLev
            default: nil
            }
        // ── Kanały MIDI ────────────────────────────────────────────────────────
        // Numer kanału to NIE jest zwykła dana 0...127. `ParamDef.xml` daje mu trzy
        // osobne typy, zależne od tego, co poza szesnastoma kanałami wolno wybrać:
        //   92 `MidiCh_16` 0...16 — kanał albo „Any" (wysyłka na stały kanał);
        //   93 `MidiCh_17` 0...17 — dochodzi wariant odbioru z całego slotu;
        //   94 `MidiCh_20` 0...20 — dochodzą kanały wewnętrzne slotów A-D.
        // Bez tych wpisów +/- chodziło po całym 0...127, czyli po numerach kanałów,
        // których sprzęt nie zna.
        case 142, 147:
            codeRef == 1 ? 0 ... 16 : nil // PCSend, CtrlRcv — ParamDef 92
        case 148:
            codeRef == 1 ? 0 ... 17 : nil // NoteRcv — ParamDef 93
        case 57, 141, 143:
            codeRef == 2 ? 0 ... 20 : nil // Automate, CtrlSend, NoteSend — ParamDef 94
        case 149:
            switch codeRef {
            case 0: 0 ... 17 // NoteZone RcvCh — ParamDef 93
            case 4: 0 ... 20 // NoteZone SendCh — ParamDef 94
            default: nil
            }
        case 24:
            // LfoC „Range": panel ma pięć napisów (Rate Sub/Lo/Hi/BPM/Clk), ale LFO C
            // zna tylko cztery zakresy — Clk ma dopiero LfoB i LfoShpA. Potwierdzone
            // w g2ools, BVerhue (prtLfoRange_3) i na 8222 modułach z prawdziwych patchy.
            codeRef == 3 ? 0 ... 3 : nil
        case 45:
            // FltVoice: trzy pola Vowel navigator wybierają jedną z dziewięciu
            // samogłosek (A, E, I, O, U, Y, Å, Ä, Ö), czyli indeksy 0...8.
            switch codeRef {
            case 0 ... 2: 0 ... 8
            default: nil
            }
        case 26:
            // LfoA „Range" — ta sama różnica napisów co w LfoC, tu pod CodeRef 7.
            codeRef == 7 ? 0 ... 3 : nil
        case 68:
            // ClkGen „Sync every N beats": sześć wartości 1, 2, 4, 8, 16, 32.
            // Bez wpisu +/- chodziły po całym 0...127 zamiast po sześciu krokach.
            codeRef == 3 ? 0 ... 5 : nil
        case 200:
            // RandomA „Range": ta sama różnica napisów co LfoA/LfoC — panel ma pięć
            // (Sub/Lo/Hi/BPM/Clk), sprzęt zna tylko cztery (bez „Clk").
            codeRef == 3 ? 0 ... 3 : nil
        case 202:
            // RandomB „Range" — ten sam przypadek, tu pod CodeRef 7.
            codeRef == 7 ? 0 ... 3 : nil
        case 208:
            // RndPattern „Loop": ten sam przypadek co ClkDiv niżej — InfoFunc:2 dawało
            // 16 kroków, a g2ools (Range_128) i patche pokazują pełne 1...128.
            codeRef == 3 ? 0 ... 127 : nil
        case 69:
            // ClkDiv "Divider": InfoFunc:2 sugeruje domyślnie 16 wartości (0...15,
            // jak SeqLen/DlyClk), ale to ten sam param co g2ools "Range_128"
            // (low=0, high=127, "0~1, 127~128" — mapowanie origin-zero→origin-one).
            // Bez wpisu +/- ograniczały dzielnik do 1...16 zamiast 1...128.
            codeRef == 0 ? 0 ... 127 : nil
        case 102:
            // FltPhase NotchCount: wyświetlane 1...6, zapisane jako indeks 0...5.
            codeRef == 4 ? 0 ... 5 : nil
        case 108:
            // Vocoder: każde z 16 pasm wybiera wejście Analysis 1...16 albo Off=0.
            // Bez wpisu pary +/- przechodziły po ogólnym zakresie 0...127.
            (0 ... 15).contains(codeRef) ? 0 ... 16 : nil
        case 118:
            // Digitizer „Bits”: parametr ma trzynaście stanów 0...12, przy czym
            // ostatni oznacza „Off”. Pełne 0...127 przesuwało wskaźnik gałki poza
            // zakres sprzętowego modułu.
            codeRef == 0 ? 0 ... 12 : nil
        case 150:
            // Compress: trzy gałki mają własne, krótsze typy parametrów Clavii.
            // Wartości poza nimi były wprawdzie widoczne w UI, ale nie istnieją
            // w sprzętowym module.
            switch codeRef {
            case 0, 4: 0 ... 42 // Threshold / Ref Level
            case 1: 0 ... 66 // Ratio
            default: nil
            }
        // LevelShift (Output type P+/P-/N+/N-/B+/B-, InfoFunc:46): domyślny zakres
        // 0...5 (Pos/PosInv/Neg/NegInv/Bip/BipInv, BVerhue prtPosNegInvBipInv) jest
        // poprawny tylko dla EnvADSR/ModADSR/EnvADDSR. Pozostałe moduły obwiedni mają
        // węższy sprzętowy typ parametru — potwierdzone w BVE.NMG2Data.pas (ParamID
        // 135 prtPosNegInv LowValue:0 HighValue:3, 136 prtPosNegInvBip HighValue:4):
        // audyt (`module-completeness-audit.md`) wyłapał to jako "OutputType cykluje
        // 6 stanów, sprzęt ma 4/5" dla sześciu modułów.
        case 41: codeRef == 1 ? 0 ... 3 : nil // EnvH
        case 46: codeRef == 5 ? 0 ... 3 : nil // EnvAHD
        case 52: codeRef == 10 ? 0 ... 4 : nil // EnvMulti (prtPosNegInvBip — 5 stanów)
        case 55: codeRef == 1 ? 0 ... 3 : nil // EnvD
        case 84: codeRef == 5 ? 0 ... 3 : nil // EnvADR
        case 169: codeRef == 6 ? 0 ... 3 : nil // ModAHD
        default: nil
        }
    }
}
