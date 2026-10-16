// SplitMix64.swift
// Generator liczb losowych z ziarnem — ten sam ciąg na każdym Macu i w każdym uruchomieniu.
//
// `SystemRandomNumberGenerator` nie przyjmuje ziarna, więc testy operatorów byłyby
// losowo czerwone. SplitMix64 (Steele, Lea, Flood 2014) to 64 bity stanu i trzy
// mnożenia — wystarcza do mutacji i jest odtwarzalny co do bitu.

public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
