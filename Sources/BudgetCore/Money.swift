import Foundation

public enum MoneyError: Error, Equatable, Sendable {
    case currencyMismatch(expected: String, actual: String)
    case arithmeticOverflow
}

/// An exact monetary value stored in the currency's minor unit (for example,
/// cents for USD). Floating-point values never enter budget calculations.
public struct Money: Hashable, Codable, Sendable {
    public let minorUnits: Int64
    public let currencyCode: String

    public init(minorUnits: Int64, currencyCode: String) {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode.uppercased()
    }

    public static func zero(currencyCode: String) -> Money {
        Money(minorUnits: 0, currencyCode: currencyCode)
    }

    public func adding(_ other: Money) throws -> Money {
        try requireSameCurrency(as: other)
        let result = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !result.overflow else { throw MoneyError.arithmeticOverflow }
        return Money(minorUnits: result.partialValue, currencyCode: currencyCode)
    }

    public func subtracting(_ other: Money) throws -> Money {
        try requireSameCurrency(as: other)
        let result = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !result.overflow else { throw MoneyError.arithmeticOverflow }
        return Money(minorUnits: result.partialValue, currencyCode: currencyCode)
    }

    public func negated() throws -> Money {
        guard minorUnits != .min else { throw MoneyError.arithmeticOverflow }
        return Money(minorUnits: -minorUnits, currencyCode: currencyCode)
    }

    private func requireSameCurrency(as other: Money) throws {
        guard currencyCode == other.currencyCode else {
            throw MoneyError.currencyMismatch(
                expected: currencyCode,
                actual: other.currencyCode
            )
        }
    }
}

