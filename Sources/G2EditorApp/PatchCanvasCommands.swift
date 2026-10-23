import G2Core
import G2EditorCore

/// Polecenia menu pod prawym przyciskiem, których kanwa nie umie wykonać sama.
///
/// Kanwa jest `struct`em bez dostępu do `PatchState` — całą resztę interakcji ma
/// w osobnych domknięciach. Tych jest jednak kilkanaście i wszystkie służą jednej
/// rzeczy (menu kontekstowe parametru, kabla i modułu), więc jadą razem w jednej
/// paczce zamiast puchnąć listę parametrów widoku.
///
/// Zakres odpowiada trzem menu z instrukcji Clavii: „Parameter popup" i „Cable popup"
/// (str. 70–71) oraz brakującym pozycjom „Module popup" (str. 69).
struct PatchCanvasCommands {
    // MARK: - Parametr → gałka panelu

    /// „Assign ▸ Page X" — parametr na pierwszą wolną gałkę wskazanej strony.
    var assignKnobToPage: ((_ moduleID: Int, _ paramIndex: Int, _ page: Int) -> Void)?
    /// „Assign ▸ Disable".
    var clearKnob: ((_ moduleID: Int, _ paramIndex: Int) -> Void)?
    /// Numer gałki, na której wisi parametr — do „ptaszka" przy stronie.
    var knobIndexFor: ((_ moduleID: Int, _ paramIndex: Int) -> Int?)?

    /// „Global Assign ▸ Page X" — to samo na wspólnych stronach performance'u.
    var assignGlobalKnobToPage: ((_ moduleID: Int, _ paramIndex: Int, _ page: Int) -> Void)?
    var clearGlobalKnob: ((_ moduleID: Int, _ paramIndex: Int) -> Void)?
    var globalKnobIndexFor: ((_ moduleID: Int, _ paramIndex: Int) -> Int?)?

    /// „Assign ▸ Page X ▸ Multi Column" z menu modułu — wszystkie jego parametry naraz.
    var assignAllModuleParameters: ((_ moduleID: Int, _ page: Int, _ global: Bool) -> Void)?

    // MARK: - Parametr → MIDI CC

    var assignMidiController: ((_ moduleID: Int, _ paramIndex: Int, _ cc: Int) -> Void)?
    var clearMidiController: ((_ moduleID: Int, _ paramIndex: Int) -> Void)?
    var midiControllerFor: ((_ moduleID: Int, _ paramIndex: Int) -> Int?)?

    /// „Assign MIDI to Selection" / „Deassign MIDI from Selection" (instrukcja, str. 130)
    /// — wszystkie parametry zaznaczonych modułów naraz.
    var assignMidiToModules: ((_ moduleIDs: Set<Int>) -> Void)?
    var clearMidiFromModules: ((_ moduleIDs: Set<Int>) -> Void)?

    // MARK: - Kable

    /// „Disconnect" — odpina gniazdo i zszywa łańcuch.
    var disconnectCable: ((G2Cable) -> Void)?
    /// „Break" — przerywa łańcuch bez zszywania.
    var breakCable: ((G2Cable) -> Void)?
    /// „Delete" — cały łańcuch szeregowy.
    var deleteCableChain: ((G2Cable) -> Void)?
    /// „Color ▸" — kolor całego łańcucha.
    var setCableColor: ((G2Cable, CableColor) -> Void)?
    /// „Delete Unused Cables".
    var deleteUnusedCables: (() -> Void)?
    var unusedCableCount: (() -> Int)?
    /// „Disconnect Cables ▸" z menu modułu — kable zaznaczonych modułów.
    var disconnectModuleCables: ((_ moduleIDs: Set<Int>, CableDisconnectScope) -> Void)?
    var moduleCableCount: ((_ moduleIDs: Set<Int>, CableDisconnectScope) -> Int)?
    /// „Disconnect All Cables" z menu tła — cały patch.
    var disconnectAllCables: (() -> Void)?
    var totalCableCount: (() -> Int)?

    // MARK: - Moduły

    /// „Paste Params" — same wartości ze schowka na wskazane moduły.
    var pasteParams: ((_ moduleIDs: Set<Int>) -> Void)?
    /// Sekcja 0x5B obszaru — kopiowanie (⌘C z menu modułu) zabiera podpisy modułów.
    var moduleLabels: (() -> G2ModuleLabelSection?)?
    /// „Save Selection as Block…" — wskazane moduły jako nowy plik w folderze bloków.
    var saveModulesAsBlock: ((_ moduleIDs: Set<Int>) -> Void)?
    /// Wskazane moduły jako blok — wyciągnięte z kanwy na listę Patches ▸ Blocks.
    var blockFromModules: ((_ moduleIDs: Set<Int>) -> G2Patch?)?
    /// „Delete Unused Modules" z menu tła.
    var deleteUnusedModules: (() -> Void)?
    var unusedModuleCount: (() -> Int)?
}
