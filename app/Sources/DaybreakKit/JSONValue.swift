import Foundation

/// A lossless, Sendable mirror of a JSON document. Used so the app can round-trip
/// configuration keys it does not understand without touching them.
public enum JSONValue: Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public enum ConversionError: Error, Equatable {
        case unsupported(String)
    }

    /// Converts the output of `JSONSerialization` into a `JSONValue`, keeping
    /// booleans, integers and floating-point numbers distinct.
    public init(foundation value: Any) throws {
        switch value {
        case let dict as [String: Any]:
            self = .object(try dict.mapValues { try JSONValue(foundation: $0) })
        case let list as [Any]:
            self = .array(try list.map { try JSONValue(foundation: $0) })
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case is NSNull:
            self = .null
        default:
            throw ConversionError.unsupported(String(describing: type(of: value)))
        }
    }

    /// The equivalent Foundation object for `JSONSerialization`.
    public var foundationValue: Any {
        switch self {
        case .object(let dict): return dict.mapValues(\.foundationValue)
        case .array(let list): return list.map(\.foundationValue)
        case .string(let string): return string
        case .int(let int): return NSNumber(value: int)
        case .double(let double): return NSNumber(value: double)
        case .bool(let bool): return NSNumber(value: bool)
        case .null: return NSNull()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Integer value; floats are not coerced (mirrors the engine's strict `type(x) is int`).
    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}
