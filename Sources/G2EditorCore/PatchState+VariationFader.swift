// PatchState+VariationFader.swift
// Fader wariacji (życzenie z forum #13, pomysł Kuby) — suwak pod przyciskami wariacji.
//
// Dwa tryby, jeden suwak:
// - zwykły: przystanki 1…8 (wariacje identyczne z poprzednią pominięte), między
//   przystankami mieszają się tylko dwaj sąsiedzi;
// - porównanie (Shift-klik w wariację): dwa przystanki, grająca ↔ porównywana.
//
// Brzmienie „pomiędzy” gra z bufora odsłuchu (zestaw 9, ten sam co Mutatora), więc
// osiem wariacji i plik zostają nietknięte; „Store Fader Sound To” zapisuje je do
// wybranej wariacji. Na przystanku po puszczeniu myszy gra zwykła wariacja.
//
// Do Norda: na początku gestu cały bufor jedną paczką (jak odsłuch Mutatora), w trakcie
// same różnice paczką `0x40` — zmierzone na Nordzie 2026-11-03: czysto do 100 ramek/s
// przy 53 parametrach naraz — a na końcu znów całość, żeby zgubiona ramka nie została
// rozbieżnością → [[Docs/usb/protocol-map]] „Tempo `0x40` dla fadera wariacji”.

import G2Core

/// Położenie fadera wariacji jednego slotu.
public struct VariationFaderState: Equatable {
    /// Wariacje po kolei wzdłuż suwaka (0–7).
    public var stops: [Int]
    /// 0 = pierwszy przystanek, 1 = drugi… Wartość całkowita = dokładnie na przystanku.
    public var position: Double
    /// Para z porównania wariacji (dwa przystanki), a nie droga przez wszystkie.
    public var comparing: Bool
    /// Kierunek ostatniego ruchu: +1 w prawo, −1 w lewo — stąd wiadomo, do którego
    /// przystanku jedziemy, i to jego kanwa porównuje z tym, co gra.
    public var heading = 1
    /// Przystanek, którego przełączniki i fale grają w drodze — ostatni minięty. Skaczą
    /// dopiero po dojściu do następnego, więc środek drogi jest w pełni płynny.
    public var switchStop = 0
    /// Kanwa pokazuje, co się zmienia: zapala ruch suwaka, gasi kliknięcie w kanwę albo Esc
    /// (decyzja Kuby 2026-11-04 — po puszczeniu myszy zmiany zostają do obejrzenia).
    public var showsChanges = false
}

public extension PatchState {
    /// Co ile najwyżej zmiany spod fadera idą do Norda — ruch myszy bywa gęstszy.
    /// 20 ms = 50 ramek/s, czyli tempo sprawdzone uchem na Nordzie.
    internal static let faderSendInterval: Duration = .milliseconds(20)
    /// Tak blisko przystanku suwak sam na niego wskakuje.
    static let faderSnap = 0.08

    /// Fader, który właśnie gra (slot gra bufor odsłuchu z fadera); `nil` poza tym.
    func activeVariationFader(slot: Int) -> VariationFaderState? {
        guard let fader = variationFaders[slot],
              header(slot: slot).activeVariation == G2Patch.mutatorVariation else { return nil }
        return fader
    }

    /// Przystanki suwaka slotu: w trakcie przejścia te, po których jedzie; przy porównaniu
    /// grająca i porównywana; inaczej różne brzmienia spośród wariacji 1–8.
    func variationFaderStops(slot: Int) -> [Int] {
        if let fader = activeVariationFader(slot: slot) { return fader.stops }
        return freshFaderStops(slot: slot)
    }

    /// Położenie gałki suwaka; `nil`, gdy slot gra coś spoza drogi (bufor Mutatora).
    func variationFaderPosition(slot: Int) -> Double? {
        if let fader = activeVariationFader(slot: slot) { return fader.position }
        return G2VariationFade.stopIndex(of: header(slot: slot).activeVariation,
                                         in: freshFaderStops(slot: slot)).map(Double.init)
    }

    /// Jak mocno świeci przycisk wariacji w trakcie przejścia — `nil`, gdy fader nie gra
    /// (wtedy świeci zwykła wariacja).
    func variationFaderWeight(of variation: Int, slot: Int) -> Double? {
        guard let fader = activeVariationFader(slot: slot) else { return nil }
        return G2VariationFade.weight(of: variation, at: fader.position, stops: fader.stops,
                                      pair: fader.comparing)
    }

    /// Wariacja, z którą kanwa porównuje to, co gra (różnice turkusem, reszta przygaszona).
    /// Porównanie Shift-klikiem ma pierwszeństwo; poza nim, w trakcie przejścia przez
    /// wszystkie wariacje — przystanek, do którego suwak jedzie (prośba Kuby 2026-11-03:
    /// „pokazuj, co się zmienia, gdy ruszam faderem”). Na końcu drogi — ten za plecami.
    /// Po puszczeniu myszy zmiany zostają, aż kliknięcie w kanwę albo Esc je zgasi
    /// (`hideVariationFaderChanges`, decyzja Kuby 2026-11-04).
    func canvasComparedVariation(slot: Int) -> Int? {
        if let compared = comparedVariation(slot: slot) { return compared }
        guard let fader = activeVariationFader(slot: slot), fader.showsChanges, !fader.comparing,
              fader.stops.count > 1
        else {
            return nil
        }
        let last = fader.stops.count - 1
        let ahead = fader.heading >= 0 ? Int(fader.position.rounded(.down)) + 1
            : Int(fader.position.rounded(.up)) - 1
        let index = (0 ... last).contains(ahead) ? ahead : (fader.heading >= 0 ? last - 1 : 1)
        return fader.stops[index]
    }

    /// Ruch suwaka. Gałka przesuwa się od razu, dźwięk dogania co `faderSendInterval`.
    func moveVariationFader(to position: Double, slot: Int) {
        guard slots.indices.contains(slot) else { return }
        if faderGestureSlot != slot { beginFaderGesture(slot: slot) }
        guard var fader = variationFaders[slot] else { return }
        if !fader.showsChanges {
            fader.showsChanges = true
            variationFaders[slot] = fader
        }
        var clamped = min(Double(fader.stops.count - 1), max(0, position))
        if abs(clamped - clamped.rounded()) < Self.faderSnap { clamped = clamped.rounded() }
        guard clamped != fader.position || slots[slot].activeVariation != G2Patch.mutatorVariation else { return }
        if clamped != fader.position { fader.heading = clamped > fader.position ? 1 : -1 }
        fader.switchStop = G2VariationFade.switchStop(held: fader.switchStop, from: fader.position, to: clamped)
        fader.position = clamped
        variationFaders[slot] = fader
        guard !faderFlushPending else { return }
        faderFlushPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.faderSendInterval)
            self?.flushVariationFader(slot: slot)
        }
    }

    /// Mysz puszczona. Na przystanku gra zwykła wariacja; pomiędzy — bufor, który Nord
    /// dostaje jeszcze raz w całości.
    func endVariationFaderGesture(slot: Int) {
        guard faderGestureSlot == slot else { return }
        faderGestureSlot = nil
        flushVariationFader(slot: slot)
        guard let fader = variationFaders[slot], fader.stops.indices.contains(Int(fader.position)) else { return }
        if fader.position == fader.position.rounded() {
            selectVariation(fader.stops[Int(fader.position)], slot: slot)
        } else {
            onMutatorAudition?(slot, slots[slot], G2Patch.mutatorVariation)
        }
    }

    /// Esc: kanwa wraca do zwykłego wyglądu — koniec porównania (Shift-klik) i zmian spod
    /// fadera, który dalej gra. `true` = było co zgasić (Esc nie idzie wtedy dalej).
    @discardableResult
    func endCanvasComparison(slot: Int) -> Bool {
        var ended = hideVariationFaderChanges(slot: slot)
        if comparedVariation(slot: slot) != nil {
            endCompare(slot: slot)
            ended = true
        }
        return ended
    }

    /// Kliknięcie w kanwę: gasi tylko zmiany spod fadera. Porównanie Shift-klikiem zostaje,
    /// żeby dało się kręcić gałkami i widzieć różnice (decyzje Kuby 2026-11-04).
    @discardableResult
    func hideVariationFaderChanges(slot: Int) -> Bool {
        guard variationFaders[slot]?.showsChanges == true else { return false }
        variationFaders[slot]?.showsChanges = false
        return true
    }

    /// „Store Fader Sound To” — to, co słychać spod fadera, do wariacji `variation`.
    func storeVariationFaderSound(to variation: Int, slot: Int) {
        guard slot == selectedSlot, activeVariationFader(slot: slot) != nil,
              (0 ..< G2Patch.initVariation).contains(variation) else { return }
        let sound = G2Mutator.individual(from: slots[slot], variation: G2Patch.mutatorVariation,
                                         genome: mutatorGenome)
        writeIndividualToVariation(sound, variation: variation)
        undoManager.setActionName("Store Fader Sound")
    }

    // MARK: - Wnętrze

    /// Czyta nagłówek slotu, nie `slots` — suwak jest widoczny stale, a ruch gałki
    /// w module nie ma go budzić → [[Docs/ui/canvas-performance]].
    private func freshFaderStops(slot: Int) -> [Int] {
        let header = header(slot: slot)
        if let compared = comparedVariation(slot: slot),
           (0 ..< G2Patch.initVariation).contains(header.activeVariation)
        {
            return [header.activeVariation, compared]
        }
        return header.faderStops
    }

    /// Początek gestu: droga i punkt startu. Trwające przejście w tym samym trybie jedzie
    /// dalej z miejsca, w którym stoi; inaczej start z grającej wariacji. Jeden krok undo
    /// na gest — wraca do wariacji sprzed przejścia.
    private func beginFaderGesture(slot: Int) {
        if let previous = faderGestureSlot { endVariationFaderGesture(slot: previous) }
        faderGestureSlot = slot
        let comparing = comparedVariation(slot: slot) != nil
        if let fader = activeVariationFader(slot: slot), fader.comparing == comparing,
           !comparing || fader.stops.last == comparedVariation(slot: slot)
        {
            return
        }
        let active = slots[slot].activeVariation
        // Z bufora (Mutator albo przejście w innym trybie) startujemy od najbliższej wariacji drogi.
        let anchor = (0 ..< G2Patch.initVariation).contains(active) ? active
            : variationFaders[slot].map { $0.stops[Int($0.position.rounded())] } ?? 0
        let stops: [Int] = if comparing, let compared = comparedVariation(slot: slot), compared != anchor {
            [anchor, compared]
        } else {
            header(slot: slot).faderStops
        }
        let start = G2VariationFade.stopIndex(of: anchor, in: stops) ?? 0
        variationFaders[slot] = VariationFaderState(stops: stops, position: Double(start),
                                                    comparing: comparing && stops.count == 2,
                                                    switchStop: start)
        if (0 ..< G2Patch.initVariation).contains(active) {
            undoManager.registerUndo(withTarget: self) { state in
                state.selectVariation(active, slot: slot)
            }
            undoManager.setActionName("Variation Fader")
        }
    }

    /// Dźwięk z obecnego położenia do bufora i do Norda.
    private func flushVariationFader(slot: Int) {
        faderFlushPending = false
        guard let fader = variationFaders[slot], slots.indices.contains(slot) else { return }
        let buffer = G2Patch.mutatorVariation
        let sound = G2VariationFade.sound(at: fader.position, stops: fader.stops, switchStop: fader.switchStop,
                                          patch: slots[slot], genome: mutatorGenome)
        guard slots[slot].activeVariation == buffer else {
            // Pierwszy krok: bufor w całości jedną paczką, potem przełączenie na niego.
            slots[slot].apply(sound, variation: buffer)
            slots[slot].setActiveVariation(buffer)
            if let onMutatorAudition {
                onMutatorAudition(slot, slots[slot], buffer)
            } else {
                onVariationChange?(slot, buffer)
            }
            return
        }
        let changes = slots[slot].apply(sound, variation: buffer)
        if !changes.parameters.isEmpty {
            onLiveParameterBatch?(slot, changes.parameters.map {
                G2ParameterChange(area: $0.area, moduleID: $0.moduleID, paramIndex: $0.paramIndex, value: $0.value)
            }, buffer)
        }
        for setting in changes.settings {
            onPatchSettingChange?(slot, setting.moduleID, setting.paramIndex, setting.value, buffer)
        }
        for morph in changes.morphs {
            onMorphRangeChange?(slot, morph.location, morph.moduleID, morph.paramIndex,
                                morph.morph, morph.range, buffer)
        }
    }
}
