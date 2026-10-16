// G2ParameterText.swift
// Nazwa i tekst wartości parametru — tak, jak pokazuje je moduł na kanwie.
//
// Jedno miejsce dla okna Parameter Pages, przeglądu parametrów i narzędzi, które opisują
// patch bez okna: wszystkie mają mówić „1.2 kHz" i „Saw" tym samym głosem. Reguły są
// przepisane z panelu modułu: pole tekstowe (`TextField`) formatuje wartość funkcją tekstu
// z zależnościami, gałka — swoją funkcją informacyjną, przycisk — nadrukiem z panelu.

import Foundation

public enum G2ParameterText {
    /// Nazwa parametru tak, jak wpisuje ją oryginalny edytor: krótka etykieta z panelu,
    /// a dopiero w jej braku kodowa nazwa z `ModuleDef`.
    public static func name(moduleTypeID: Int, paramIndex: Int) -> String {
        if let short = ClaviaParameterNames.name(moduleTypeID: moduleTypeID, paramIndex: paramIndex) {
            return short
        }
        guard let definition = ModuleDatabase.module(id: moduleTypeID),
              definition.paramNames.indices.contains(paramIndex)
        else {
            return "Param \(paramIndex)"
        }
        return definition.paramNames[paramIndex]
    }

    /// Tekst wartości parametru w kontekście całego modułu (funkcje tekstu zależą od
    /// sąsiednich parametrów: częstotliwość oscylatora od trybu i strojenia dokładnego).
    ///
    /// Kolejność: własne pole tekstowe parametru → nadruk przycisku → funkcja gałki →
    /// pole, w którym parametr jest tylko zależnością (strojenie dokładne bez własnej
    /// gałki) → sama liczba.
    public static func value(paramIndex: Int, value: Int, module: G2Module) -> String {
        let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID)
        let knob = ui?.knobs.first { $0.codeRef == paramIndex }
        // Funkcja tekstu czyta parametry z modułu — `value` ma wygrać także wtedy, gdy
        // pytamy o inną wartość niż ta, którą moduł ma teraz (zakres w opisie typu).
        var module = module
        if module.parameters.indices.contains(paramIndex) {
            module.parameters[paramIndex] = value
        }
        if let field = ui?.textFields.first(where: { $0.masterRef == paramIndex }) {
            let text = fieldText(field, module: module)
            if !text.isEmpty { return text }
        }
        if let button = buttonOptions(moduleTypeID: module.typeID, paramIndex: paramIndex) {
            return button.text(for: value)
        }
        if let knob {
            let text = g2InfoFunction(knob.infoFunc, val: value)
            if !text.isEmpty { return text }
        }
        // Pole cudzej gałki pokazuje ten parametr tylko wtedy, gdy jest jego pierwszą
        // zależnością; przełącznik typu wyjścia (`OutputType` w EnvMulti) siedzi w polu
        // poziomu jako dalsza zależność i dostałby cudzy napis („+0") zamiast liczby.
        if let field = ui?.textFields.first(where: { $0.dependencies.first == paramIndex }) {
            let text = fieldText(field, module: module)
            if !text.isEmpty { return text }
        }
        return String(value)
    }

    /// Napis na wyświetlaczu modułu (`TextField`) — dokładnie to, co rysuje kanwa.
    ///
    /// Puste `Dependencies` znaczy „czytaj `MasterRef`" (pole pokazuje wartość swojej
    /// gałki); `Text Func: 0` deleguje do funkcji informacyjnej gałki albo pary +/-
    /// o tym samym `CodeRef`. Wartość gałki przycinamy do potwierdzonego zakresu, bo
    /// plik bywa poza nim. Trzy pola mają własny format Clavii: jasność pogłosu,
    /// rezonans filtru Classic i stosunek wysokości Scratcha.
    public static func fieldText(_ field: BVTextField, module: G2Module) -> String {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return "" }
        let current = field.masterRef < module.parameters.count ? module.parameters[field.masterRef] : 0
        if module.typeID == 12, field.masterRef == 1 { return g2ReverbBrightness(current) }
        if module.typeID == 92, field.masterRef == 3 { return g2FltClassicResonanceText(current) }
        if module.typeID == 63, field.masterRef == 0 { return g2ScratchPitchRatio(current) }

        var infoFuncs: [Int: Int] = [:]
        for knob in ui.knobs {
            infoFuncs[knob.codeRef] = knob.infoFunc
        }
        for button in ui.incDecButtons {
            infoFuncs[button.codeRef] = button.infoFunc
        }
        let deps = field.dependencies.isEmpty ? [field.masterRef] : field.dependencies

        var parameters = module.parameters
        if parameters.indices.contains(field.masterRef),
           let range = ParameterRangeDatabase.range(moduleTypeID: module.typeID, codeRef: field.masterRef)
        {
            parameters[field.masterRef] = min(range.upperBound, max(range.lowerBound, parameters[field.masterRef]))
        }
        return g2TextFunction(textFunc: field.textFunc,
                              deps: deps,
                              params: parameters,
                              modes: module.modes,
                              knobInfoFunc: infoFuncs[field.masterRef] ?? 0)
    }

    /// Opcje przycisku albo selektora: liczba stanów i napis każdego z nich.
    public struct ButtonOptions: Equatable {
        public let count: Int
        /// Napisy stanów; pusta lista, gdy przycisk ma ikony zamiast napisów.
        public let labels: [String]
        /// Włącznik z nadrukiem (`Check`): napis jest nazwą, nie stanem — stan niesie kolor.
        public let isSwitch: Bool
        let infoFunc: Int

        init(count: Int, labels: [String], infoFunc: Int, isSwitch: Bool = false) {
            self.count = count
            self.labels = labels
            self.infoFunc = infoFunc
            self.isSwitch = isSwitch
        }

        public func text(for value: Int) -> String {
            let index = max(0, min(value, max(count - 1, 0)))
            if labels.indices.contains(index) { return labels[index] }
            let text = g2InfoFunction(infoFunc, val: value)
            return text.isEmpty ? String(value) : text
        }
    }

    /// Czym przełącza się parametr, jeśli jest przyciskiem: nadruki z panelu
    /// (`Off`/`On`, `Saw`…) albo liczba stanów selektora ikon. `nil` = gałka lub pole.
    public static func buttonOptions(moduleTypeID: Int, paramIndex: Int) -> ButtonOptions? {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: moduleTypeID) else { return nil }
        // 2-Out „Dest": sześć przycisków w trzech parach, a nad parami stoją osobne napisy
        // Out / Fx / Bus — sam nadruk przycisku („1/2") nie mówi, o którą parę chodzi.
        if moduleTypeID == 4, paramIndex == 0 {
            return ButtonOptions(count: 6, labels: ["Out 1/2", "Out 3/4", "Fx 1/2", "Fx 3/4", "Bus 1/2", "Bus 3/4"], infoFunc: 0)
        }
        if let button = ui.buttonsFlat.first(where: { $0.codeRef == paramIndex }),
           !button.options.isEmpty
        {
            return ButtonOptions(count: button.options.count,
                                 labels: button.options.map { $0.trimmingCharacters(in: .whitespaces) },
                                 infoFunc: button.infoFunc)
        }
        if let button = ui.buttonsRadio.first(where: { $0.codeRef == paramIndex }) {
            let count = max(1, button.buttonCount)
            let labels = button.buttonLabels.count >= count ? Array(button.buttonLabels.prefix(count)) : []
            return ButtonOptions(count: count, labels: labels, infoFunc: button.infoFunc)
        }
        if let selector = ui.partSelectors.first(where: { $0.usesParameter && $0.codeRef == paramIndex }) {
            return ButtonOptions(count: max(1, selector.imageCount), labels: [], infoFunc: selector.infoFunc)
        }
        if let button = ui.buttonsText.first(where: { $0.codeRef == paramIndex }) {
            // Przycisk pokazuje to, co jest na nim nadrukowane na panelu modułu
            // (`ParamLabel`, np. „Ch 1"), a stan włączony niesie kolor — tak samo
            // jak na kanwie. Przyciski bez napisu (Evnt w sekwencerach) zostawały
            // po włączeniu puste, więc tam piszemy „On" parą do „Off". Włącznik
            // modułu (`Active`) ma zamiast napisu ikonę zasilania, więc też Off/On.
            let isPower = ModuleDatabase.module(id: moduleTypeID)?.paramNames[safe: paramIndex] == "Active"
            guard !button.text.isEmpty, !isPower else {
                return ButtonOptions(count: 2, labels: ["Off", "On"], infoFunc: 0)
            }
            return ButtonOptions(count: 2, labels: [button.text, button.text], infoFunc: 0, isSwitch: true)
        }
        return nil
    }

    /// Górna granica parametru: potwierdzony zakres z bazy, inaczej 127.
    public static func maxValue(moduleTypeID: Int, paramIndex: Int) -> Int {
        ParameterRangeDatabase.range(moduleTypeID: moduleTypeID, codeRef: paramIndex)?.upperBound ?? 127
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
