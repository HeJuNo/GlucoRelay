import Foundation

/// Display unit for blood glucose. Readings are always *stored* in mg/dL;
/// Nightscout always receives mg/dL. This only affects presentation.
enum GlucoseUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case mgdL
    case mmolL

    static let storageKey = "displayUnit"
    /// mg/dL per mmol/L (molar mass of glucose 180.16 g/mol / 10).
    static let mgdLPerMmolL = 18.0182

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mgdL: "mg/dL"
        case .mmolL: "mmol/L"
        }
    }

    /// Converts a value stored in mg/dL to this unit.
    func convert(fromMgdL mgdL: Double) -> Double {
        switch self {
        case .mgdL: mgdL
        case .mmolL: mgdL / Self.mgdLPerMmolL
        }
    }

    /// Formats a value stored in mg/dL in this unit (no unit label).
    func format(mgdL: Double) -> String {
        let value = convert(fromMgdL: mgdL)
        switch self {
        case .mgdL: return String(Int(value.rounded()))
        case .mmolL: return value.formatted(.number.precision(.fractionLength(1)))
        }
    }

    /// The user's current display preference.
    static var current: GlucoseUnit {
        UserDefaults.standard.string(forKey: storageKey).flatMap(GlucoseUnit.init(rawValue:)) ?? .mmolL
    }
}
