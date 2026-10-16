import Foundation

/// Serializowalna reprezentacja modułów i kabli kopiowanych między patchami.
public struct G2ClipboardContent: Codable {
    public struct ClipModule: Codable {
        public var typeID: Int
        public var column: Int
        public var row: Int
        public var parameters: [Int]
        public var parameterVariations: [[Int]]
        public var modes: [Int]
        public var label: String
        public var color: UInt8
        /// Oryginalne ID jest potrzebne do remapowania końców kabli przy wklejaniu.
        public var originalID: Int

        public init(typeID: Int, column: Int, row: Int, parameters: [Int],
                    parameterVariations: [[Int]], modes: [Int], label: String,
                    color: UInt8, originalID: Int)
        {
            self.typeID = typeID
            self.column = column
            self.row = row
            self.parameters = parameters
            self.parameterVariations = parameterVariations
            self.modes = modes
            self.label = label
            self.color = color
            self.originalID = originalID
        }
    }

    public struct ClipCable: Codable {
        /// ID modułu źródłowego przed remapowaniem.
        public var fromModule: Int
        public var fromConnector: Int
        /// ID modułu docelowego przed remapowaniem.
        public var toModule: Int
        public var toConnector: Int
        /// Surowa wartość `CableColor` zapisywana w JSON.
        public var cableColor: Int
        /// Kierunek połączenia (`linkType` w formacie G2) — patrz `G2Cable.sourceIsOutput`.
        public var sourceIsOutput: Bool

        public init(fromModule: Int, fromConnector: Int, toModule: Int,
                    toConnector: Int, cableColor: Int, sourceIsOutput: Bool = true)
        {
            self.fromModule = fromModule
            self.fromConnector = fromConnector
            self.toModule = toModule
            self.toConnector = toConnector
            self.cableColor = cableColor
            self.sourceIsOutput = sourceIsOutput
        }

        /// Własny dekoder wyłącznie po to, by schowek zapisany przed dodaniem
        /// `sourceIsOutput` (2026-09-03) nadal dawał się wkleić — syntezowany
        /// `Codable` wymaga obecności klucza i zignorowałby wartość domyślną.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fromModule = try c.decode(Int.self, forKey: .fromModule)
            fromConnector = try c.decode(Int.self, forKey: .fromConnector)
            toModule = try c.decode(Int.self, forKey: .toModule)
            toConnector = try c.decode(Int.self, forKey: .toConnector)
            cableColor = try c.decode(Int.self, forKey: .cableColor)
            sourceIsOutput = try c.decodeIfPresent(Bool.self, forKey: .sourceIsOutput) ?? true
        }
    }

    public var modules: [ClipModule]
    public var cables: [ClipCable]

    public init(modules: [ClipModule], cables: [ClipCable]) {
        self.modules = modules
        self.cables = cables
    }
}
