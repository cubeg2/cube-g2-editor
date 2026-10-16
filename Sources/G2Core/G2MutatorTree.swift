// G2MutatorTree.swift
// Drzewo ewolucji — każdy dźwięk, który kiedykolwiek powstał w Mutatorze, zostaje.
//
// Kratki okna to tylko podręczne miejsca: następne kliknięcie Mutate nadpisuje sześcioro
// dzieci, a dźwięk, którego nikt nie przeciągnął do magazynu, znika. Drzewo pamięta wszystko:
// z czego powstał każdy dźwięk (Mother, a przy Cross i Interpolate także Father), którym
// przyciskiem i kiedy. Dzięki temu można wrócić do dźwięku sprzed dziesięciu pokoleń, posłuchać
// jego rodzeństwa i pociągnąć od niego nową gałąź → Docs/mutator/plan-stages 4.10.
//
// Węzeł to dźwięk, nie kratka: ten sam dźwięk zapisany w dwóch kratkach jest jednym węzłem,
// a dziecko identyczne z rodzicem nie zakłada nowego (tak trafia do drzewa kratka 1 rodziny,
// która jest Mother bit w bit). Drzewo tylko rośnie — cofnięcie hodowli w oknie nie usuwa
// z niego niczego, bo to historia, a nie stan kratek.

import Foundation

public struct G2MutatorTree: Sendable {
    public struct NodeID: Hashable, Sendable {
        public let raw: Int

        public init(raw: Int) {
            self.raw = raw
        }
    }

    /// Którym przyciskiem dźwięk powstał. `rawValue` to napis w rzędzie drzewa — krótki,
    /// bo kolumna etykiet ma 46 pt.
    public enum Origin: String, Sendable, CaseIterable {
        /// Dźwięk wzięty z patcha — korzeń.
        case patch = "Patch"
        case mutate = "Mutate"
        case randomize = "Random"
        case interpolate = "Interp"
        case cross = "Cross"
        /// Latch albo Store spod fadera Amount.
        case amount = "Amount"
        /// Osiem kratek „Make family".
        case family = "Family"

        /// Pełna nazwa do dymków.
        public var title: String {
            switch self {
            case .patch: "taken from the patch"
            case .mutate: "Mutate"
            case .randomize: "Randomize"
            case .interpolate: "Interpolate"
            case .cross: "Cross"
            case .amount: "Amount axis"
            case .family: "Make family"
            }
        }
    }

    public struct Node: Equatable, Sendable {
        public let id: NodeID
        public let origin: Origin
        /// Pusty dla korzenia; `parents[0]` to Mother, `parents[1]` (Cross, Interpolate) Father.
        public let parents: [NodeID]
        /// Korzeń ma 0; dziecko o jeden więcej niż najstarszy z rodziców.
        public let generation: Int
        /// Numer hodowli (kliknięcia przycisku), którą dźwięk powstał; korzeń ma 0.
        /// Dzieci jednej hodowli tworzą miotkę.
        public let breed: Int
        /// Miejsce w miocie: dziecko 0…5, kratka rodziny 0…7.
        public let ordinal: Int
        public let createdAt: Date
        /// Dzieci w kolejności powstania — najpierw starsze miotki.
        public fileprivate(set) var children: [NodeID] = []
    }

    /// Jedna hodowla widziana od strony rodzica: rząd drzewa.
    public struct Batch: Equatable, Sendable {
        public let breed: Int
        public let origin: Origin
        public let parent: NodeID
        /// Drugi rodzic przy Cross i Interpolate.
        public let otherParent: NodeID?
        public let members: [NodeID]
        public let createdAt: Date
    }

    public private(set) var nodes: [Node] = []
    public private(set) var roots: [NodeID] = []
    /// Ile hodowli już było — numer następnej miotki.
    public private(set) var breeds = 0

    // Zwarty magazyn dźwięków. Osobnik jako słownik waży ~50 KB, a drzewo po godzinie hodowli
    // ma tysiące węzłów — dlatego wartości leżą w tablicy w porządku wspólnej tabeli kluczy
    // (~6 KB na węzeł). Tabela tylko rośnie; dźwięk bez któregoś klucza ma tam NaN.
    private var keys: [G2Individual.Key] = []
    private var keyIndex: [G2Individual.Key: Int] = [:]
    private var values: [[Double]] = []
    private var morphs: [[G2Individual.Key: [Int: Int]]] = []
    /// Skrót dźwięku → węzły o tym skrócie; równość sprawdza się dopiero na kandydatach.
    private var lookup: [Int: [NodeID]] = [:]

    public init() {}

    public var count: Int {
        nodes.count
    }

    public var isEmpty: Bool {
        nodes.isEmpty
    }

    /// Ile pokoleń liczy drzewo — korzeń to pokolenie 0, więc puste drzewo ma 0.
    public var generations: Int {
        nodes.map(\.generation).max().map { $0 + 1 } ?? 0
    }

    public subscript(id: NodeID) -> Node {
        nodes[id.raw]
    }

    public func contains(_ id: NodeID) -> Bool {
        nodes.indices.contains(id.raw)
    }

    // MARK: Dźwięki

    /// Dźwięk węzła odtworzony z tabeli — kompletny, z ułamkami i morfami.
    public func sound(of id: NodeID) -> G2Individual {
        let row = values[id.raw]
        var sound: [G2Individual.Key: Double] = [:]
        sound.reserveCapacity(row.count)
        for (column, value) in row.enumerated() where !value.isNaN {
            sound[keys[column]] = value
        }
        return G2Individual(values: sound, morphs: morphs[id.raw])
    }

    /// Węzeł tego dźwięku, jeśli już jest w drzewie — bit w bit, łącznie z morfami.
    public func node(of sound: G2Individual) -> NodeID? {
        lookup[sound.hashValue]?.first { matches($0, sound) }
    }

    /// Porównanie bez odtwarzania słownika: każdy klucz dźwięku musi mieć tę samą wartość
    /// w tabeli, a węzeł nie może mieć żadnego klucza ponad to.
    private func matches(_ id: NodeID, _ sound: G2Individual) -> Bool {
        let row = values[id.raw]
        var found = 0
        for (key, value) in sound.values {
            guard let column = keyIndex[key], column < row.count, row[column] == value else { return false }
            found += 1
        }
        return found == row.lazy.filter { !$0.isNaN }.count && morphs[id.raw] == sound.morphs
    }

    private mutating func store(_ sound: G2Individual) {
        var row = [Double](repeating: .nan, count: keys.count)
        for (key, value) in sound.values {
            if let column = keyIndex[key] {
                row[column] = value
            } else {
                keyIndex[key] = keys.count
                keys.append(key)
                row.append(value)
            }
        }
        values.append(row)
        morphs.append(sound.morphs)
    }

    // MARK: Dokładanie

    /// Węzeł dźwięku wziętego z patcha — istniejący, jeśli dźwięk już jest w drzewie
    /// (na przykład jako czyjeś dziecko), inaczej nowy korzeń.
    @discardableResult
    public mutating func root(_ sound: G2Individual, at date: Date = Date()) -> NodeID {
        if let existing = node(of: sound) { return existing }
        let id = append(sound, origin: .patch, parents: [], breed: 0, ordinal: roots.count, at: date)
        roots.append(id)
        return id
    }

    /// Jedna hodowla: dzieci pod rodziców. Dziecko, którego dźwięk już jest w drzewie,
    /// nie zakłada nowego węzła — wraca jego dotychczasowy identyfikator.
    @discardableResult
    public mutating func breed(_ children: [G2Individual], parents: [NodeID], origin: Origin,
                               at date: Date = Date()) -> [NodeID]
    {
        breeds += 1
        return children.enumerated().map { ordinal, child in
            if let existing = node(of: child) { return existing }
            return append(child, origin: origin, parents: parents, breed: breeds, ordinal: ordinal, at: date)
        }
    }

    private mutating func append(_ sound: G2Individual, origin: Origin, parents: [NodeID], breed: Int,
                                 ordinal: Int, at date: Date) -> NodeID
    {
        let id = NodeID(raw: nodes.count)
        let generation = parents.map { nodes[$0.raw].generation }.max().map { $0 + 1 } ?? 0
        nodes.append(Node(id: id, origin: origin, parents: parents, generation: generation, breed: breed,
                          ordinal: ordinal, createdAt: date))
        for parent in parents where !nodes[parent.raw].children.contains(id) {
            nodes[parent.raw].children.append(id)
        }
        store(sound)
        lookup[sound.hashValue, default: []].append(id)
        return id
    }

    // MARK: Chodzenie po drzewie

    /// Mother węzła — pierwszy rodzic.
    public func parent(of id: NodeID) -> NodeID? {
        nodes[id.raw].parents.first
    }

    /// Droga od korzenia do węzła po Mother: korzeń pierwszy, `id` ostatni.
    public func ancestors(of id: NodeID) -> [NodeID] {
        var path = [id]
        var current = id
        while let parent = parent(of: current) {
            path.append(parent)
            current = parent
        }
        return path.reversed()
    }

    /// Miotki rodzica w kolejności hodowli — tylko te, w których był Mother
    /// (dzieci z Cross, gdzie był Father, należą do rzędu Mother).
    public func batches(of parent: NodeID) -> [Batch] {
        var batches: [Batch] = []
        for child in nodes[parent.raw].children.map({ nodes[$0.raw] }) where child.parents.first == parent {
            if let last = batches.indices.last, batches[last].breed == child.breed {
                batches[last] = Batch(breed: child.breed, origin: child.origin, parent: parent,
                                      otherParent: batches[last].otherParent,
                                      members: batches[last].members + [child.id],
                                      createdAt: batches[last].createdAt)
            } else {
                batches.append(Batch(breed: child.breed, origin: child.origin, parent: parent,
                                     otherParent: child.parents.dropFirst().first, members: [child.id],
                                     createdAt: child.createdAt))
            }
        }
        return batches
    }

    /// Rodzeństwo z tej samej miotki (łącznie z samym węzłem); dla korzenia — wszystkie korzenie.
    public func siblings(of id: NodeID) -> [NodeID] {
        let node = nodes[id.raw]
        guard let parent = node.parents.first else { return roots }
        return batches(of: parent).first { $0.breed == node.breed }?.members ?? [id]
    }

    /// Pierwsze dziecko najnowszej miotki węzła — tam prowadzi ⌥↓.
    public func latestChild(of id: NodeID) -> NodeID? {
        batches(of: id).last?.members.first
    }

    /// Ilu potomków ma węzeł we wszystkich gałęziach.
    public func descendantCount(of id: NodeID) -> Int {
        var seen: Set<NodeID> = []
        var stack = nodes[id.raw].children
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            stack += nodes[next.raw].children
        }
        return seen.count
    }

    // MARK: Chromosom

    /// Rysunek kratki wprost z tabeli — bez odtwarzania słownika, bo drzewo rysuje
    /// dziesiątki kratek naraz. Te same bajty co `G2Mutator.chromosome(of:genome:)`.
    public func chromosome(of id: NodeID, genome: G2MutatorGenome) -> [G2Mutator.ChromosomePoint] {
        let row = values[id.raw]
        var bytes: [Int] = []
        bytes.reserveCapacity(genome.genes.count + 2)
        var lastArea: PatchArea?
        for gene in genome.genes {
            if gene.area != lastArea {
                bytes.append(0)
                lastArea = gene.area
            }
            guard let column = keyIndex[gene.key], column < row.count, !row[column].isNaN else { continue }
            bytes.append(Int(row[column] + 1.0))
        }
        return G2Mutator.walk(bytes)
    }
}
