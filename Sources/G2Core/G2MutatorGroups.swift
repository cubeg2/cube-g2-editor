// G2MutatorGroups.swift
// „Profile & Groups" w panelu Mutation settings: grupa brzmieniowa każdego parametru,
// suwak „ile ruszać" na grupę i gotowe profile (ustawienia wszystkich suwaków naraz).
//
// Waga grupy to „ile", nie „czy": Quick Lock dalej jest twardym stopem i wygrywa,
// waga 0 % po prostu zostawia grupę w spokoju → Docs/mutator/plan-ui „Dwie reguły".

import MutatorCore

/// Grupa brzmieniowa w panelu — pięć grup silnika i „Other" dla parametrów bez grupy.
public enum G2MutatorGroup: String, CaseIterable, Sendable {
    case pitch = "Pitch"
    case timbre = "Timbre"
    case envelope = "Envelope"
    case motion = "Motion"
    case space = "Space"
    case other = "Other"

    public init(_ group: SemanticGroup?) {
        switch group {
        case .pitch: self = .pitch
        case .timbre: self = .timbre
        case .envelope: self = .envelope
        case .motion: self = .motion
        case .space: self = .space
        case nil: self = .other
        }
    }

    /// Grupa parametru. Najpierw ręczny opis klasy (`G2ParamSemantics`), potem to,
    /// co o parametrze wiedzą już Quick Locks i Patch Adjuster — dzięki temu strój
    /// oscylatora czy czas obwiedni w module bez ręcznego opisu też trafiają do swojej grupy.
    public static func of(paramClass: G2ParamClass?, category: G2MutatorCategory?) -> G2MutatorGroup {
        if let described = paramClass?.describedGroup { return G2MutatorGroup(described) }
        switch category {
        case .oscFreq, .oscFine: return .pitch
        case .envelope: return .envelope
        case .delays, .effects: return .space
        default: break
        }
        switch paramClass?.adjusterKnob {
        case .attack, .decay, .sustain, .release: return .envelope
        case .modRate: return .motion
        case .timbre, .resonance: return .timbre
        case .effects: return .space
        case nil: return .other
        }
    }
}

/// Suwaki „ile ruszać" — 0…1 na grupę; pełne = zachowanie bez panelu.
public struct G2MutatorGroupWeights: Equatable, Sendable {
    private var values: [G2MutatorGroup: Double]

    /// Brakujące grupy dostają 1.
    public init(_ values: [G2MutatorGroup: Double] = [:]) {
        self.values = [:]
        for group in G2MutatorGroup.allCases {
            self[group] = values[group] ?? 1
        }
    }

    public static let full = G2MutatorGroupWeights()

    public subscript(group: G2MutatorGroup) -> Double {
        get { values[group] ?? 1 }
        set { values[group] = min(1, max(0, newValue)) }
    }
}

/// Gotowe ustawienia wszystkich suwaków. Profil nie jest osobnym stanem — przycisk
/// świeci, gdy suwaki stoją dokładnie tak jak w profilu.
public enum G2MutatorProfile: String, CaseIterable, Sendable {
    case all = "All"
    case timbre = "Timbre"
    case keepPitch = "Keep pitch"
    case motion = "Motion"
    case space = "Space"
    case subtle = "Subtle"

    public var weights: G2MutatorGroupWeights {
        switch self {
        case .all: .full
        case .timbre: Self.only(.timbre)
        case .keepPitch: G2MutatorGroupWeights([.pitch: 0])
        case .motion: Self.only(.motion)
        case .space: Self.only(.space)
        case .subtle: G2MutatorGroupWeights(Dictionary(uniqueKeysWithValues:
                G2MutatorGroup.allCases.map { ($0, 0.3) }))
        }
    }

    public var help: String {
        switch self {
        case .all: "Every group moves fully"
        case .timbre: "Only the colour of the sound: waveforms, filters, mixer levels"
        case .keepPitch: "Everything except tuning"
        case .motion: "Only LFOs and other movement"
        case .space: "Only delays, effects and panning"
        case .subtle: "Every group moves, but only a little"
        }
    }

    private static func only(_ group: G2MutatorGroup) -> G2MutatorGroupWeights {
        G2MutatorGroupWeights(Dictionary(uniqueKeysWithValues: G2MutatorGroup.allCases.map {
            ($0, $0 == group ? 1 : 0)
        }))
    }
}
