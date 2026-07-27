import Foundation

public struct ReadingFontSize: CaseIterable, Hashable, Identifiable, Sendable {
    public static let allCases = stride(from: 16, through: 40, by: 2).map {
        ReadingFontSize(points: $0)
    }
    public static let defaultValue = ReadingFontSize(points: 28)

    public let points: Int

    public var id: Int {
        points
    }

    public var rawValue: String {
        String(points)
    }

    public var canDecrease: Bool {
        self != Self.allCases.first
    }

    public var canIncrease: Bool {
        self != Self.allCases.last
    }

    public var decreased: ReadingFontSize {
        adjusted(by: -1)
    }

    public var increased: ReadingFontSize {
        adjusted(by: 1)
    }

    public static func resolved(_ rawValue: String) -> ReadingFontSize {
        let migratedPoints: Int?

        switch rawValue {
        case "regular":
            migratedPoints = 22
        case "large":
            migratedPoints = 28
        case "extraLarge":
            migratedPoints = 34
        default:
            migratedPoints = Int(rawValue)
        }

        guard let migratedPoints else {
            return .defaultValue
        }

        return allCases.min {
            abs($0.points - migratedPoints) < abs($1.points - migratedPoints)
        } ?? .defaultValue
    }

    private init(points: Int) {
        self.points = points
    }

    private func adjusted(by offset: Int) -> ReadingFontSize {
        guard let currentIndex = Self.allCases.firstIndex(of: self) else {
            return .defaultValue
        }

        let newIndex = min(
            max(Self.allCases.startIndex, currentIndex + offset),
            Self.allCases.index(before: Self.allCases.endIndex)
        )
        return Self.allCases[newIndex]
    }
}
