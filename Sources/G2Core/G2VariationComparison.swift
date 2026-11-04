// G2VariationComparison.swift
// Porównanie dwóch wariacji — co się zmieni po przełączeniu z grającej na inną.
// Życzenie z forum (wątek 11302); parę wybiera użytkownik Shift-klikiem w pasku wariacji.
// Tylko parametry: tryby modułu (`modes`) są wspólne dla wszystkich wariacji.

public extension G2Module {
    /// Wartość parametru w danej wariacji. Bez zapisanej wariacji — wartość bieżąca.
    func parameterValue(_ index: Int, inVariation variation: Int) -> Int? {
        guard parameters.indices.contains(index) else { return nil }
        guard parameterVariations.indices.contains(variation),
              parameterVariations[variation].indices.contains(index)
        else { return parameters[index] }
        return parameterVariations[variation][index]
    }

    /// Wszystkie wartości parametrów w danej wariacji — dla napisów zależnych od kilku
    /// parametrów naraz (np. strojenie z dostrojeniem).
    func parameterValues(inVariation variation: Int) -> [Int] {
        parameters.indices.map { parameterValue($0, inVariation: variation) ?? 0 }
    }

    /// Parametry, które w `variation` mają inną wartość niż teraz (w grającej wariacji).
    func parametersDiffering(fromVariation variation: Int) -> Set<Int> {
        Set(parameters.indices.filter { parameterValue($0, inVariation: variation) != parameters[$0] })
    }
}
