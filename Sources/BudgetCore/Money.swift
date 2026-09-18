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

    /// Exact order-independent accumulation, including cancellation across Int64 boundaries.
    /// Only the final published amount must fit the minor-unit storage representation.
    public static func sumMinorUnits<S: Sequence>(_ amounts: S) throws -> Int64 where S.Element == Int64 {
        var total = ExactMinorUnitSum()
        for amount in amounts { try total.add(amount) }
        return try total.value()
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

struct ExactMinorUnitSum {
    var high: Int64 = 0
    var low: UInt64 = 0
    mutating func add(_ value: Int64) throws {
        let addition = low.addingReportingOverflow(UInt64(bitPattern: value))
        let highDelta: Int64 = (value < 0 ? -1 : 0) + (addition.overflow ? 1 : 0)
        let upper = high.addingReportingOverflow(highDelta)
        guard !upper.overflow else { throw MoneyError.arithmeticOverflow }
        low = addition.partialValue; high = upper.partialValue
    }
    func value() throws -> Int64 {
        if high == 0, low <= UInt64(Int64.max) { return Int64(low) }
        if high == -1, low >= UInt64(1) << 63 { return Int64(bitPattern: low) }
        throw MoneyError.arithmeticOverflow
    }
}
