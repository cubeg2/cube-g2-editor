// Mutability.swift
// Jeden mechanizm „czy i jak mocno wolno ruszyć parametr" — zawsze z powodem.
//
// Zamiast sześciu równoległych list blokad jedna odpowiedź na adres: współczynnik
// swobody 0…1 i — gdy parametr stoi — powód. Dzięki temu dymek „czemu to się nie
// rusza" pisze się sam → Docs/mutator/plan-architecture §4.4.
//
// Blokady Standardu też się tu mieszczą: moduł wyłączony z mutacji → `.module`,
// kategoria Quick Lock albo Solo → `.group`, parametr „nie ruszać" → `.critical`.
// Tłumaczy je adapter celu; silnik nie zna ich nazw.

public enum LockReason: String, Codable, Sendable, CaseIterable {
    /// Użytkownik zablokował ten parametr.
    case explicit
    /// Cały moduł wyłączony z mutacji.
    case module
    /// Grupa albo kategoria zablokowana (Quick Lock, Solo, waga grupy 0).
    case group
    /// Parametr, którego ruszanie psuje patch (tryby, przełączniki „nie ruszać").
    case critical
    /// Typ modułu z góry wyłączony (np. wejścia/wyjścia).
    case excludedType
    /// Parametr nic nie robi — nie jest chroniony, tylko niesłyszalny.
    case inaudible
    /// Parametr przypisany do gałki na stronach parametrów.
    case knobAssigned
}

public struct Mutability: Hashable, Sendable {
    /// 0 = nie ruszaj, 1 = pełna swoboda.
    public var factor: Double
    /// Wypełnione tylko przy `factor == 0`.
    public var reason: LockReason?

    public static let free = Mutability(factor: 1, reason: nil)

    public static func locked(_ reason: LockReason) -> Mutability {
        Mutability(factor: 0, reason: reason)
    }

    public var isLocked: Bool {
        factor == 0
    }
}

/// Moduł celu jako klucz blokady (obszar + numer).
public struct ModuleAddress: Hashable, Codable, Sendable {
    public var area: UInt8
    public var module: UInt8

    public init(area: UInt8, module: UInt8) {
        self.area = area
        self.module = module
    }

    public init(_ address: ParameterAddress) {
        self.init(area: address.area, module: address.module)
    }
}

/// Wszystkie blokady i osłabienia naraz. Jedno miejsce odpowiedzi — `mutability(_:)`.
public struct MutabilityMap: Sendable {
    public var parameterLocks: [ParameterAddress: LockReason]
    public var moduleLocks: [ModuleAddress: LockReason]
    /// Częściowa swoboda 0…1 (np. waga grupy). Brak wpisu = 1. Zero bez blokady
    /// traktujemy jak blokadę grupy.
    public var factors: [ParameterAddress: Double]

    public init(parameterLocks: [ParameterAddress: LockReason] = [:],
                moduleLocks: [ModuleAddress: LockReason] = [:],
                factors: [ParameterAddress: Double] = [:])
    {
        self.parameterLocks = parameterLocks
        self.moduleLocks = moduleLocks
        self.factors = factors
    }

    /// Blokada parametru wygrywa z blokadą modułu — jest dokładniejszym powodem.
    public func mutability(_ address: ParameterAddress) -> Mutability {
        if let reason = parameterLocks[address] { return .locked(reason) }
        if let reason = moduleLocks[ModuleAddress(address)] { return .locked(reason) }
        let factor = min(max(factors[address] ?? 1, 0), 1)
        return factor == 0 ? .locked(.group) : Mutability(factor: factor, reason: nil)
    }
}
