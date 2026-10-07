import Foundation
import SwiftData

/// One blood glucose measurement received from a meter.
@Model
final class GlucoseReading {
    @Attribute(.unique) var id: UUID
    var peripheralUUID: UUID
    var serialNumber: String
    var sequenceNumber: Int
    /// Always mg/dL.
    var value: Double
    /// Raw value of `GlucoseUnit` – the user's display preference at the time of the reading.
    var unitRaw: String
    var timestamp: Date
    var receivedAt: Date
    var healthKitSynced: Bool
    var nightscoutSynced: Bool
    var nightscoutRetryCount: Int
    var lastSyncError: String?

    init(peripheralUUID: UUID, serialNumber: String, sequenceNumber: Int,
         valueMgdL: Double, unit: GlucoseUnit, timestamp: Date) {
        self.id = UUID()
        self.peripheralUUID = peripheralUUID
        self.serialNumber = serialNumber
        self.sequenceNumber = sequenceNumber
        self.value = valueMgdL
        self.unitRaw = unit.rawValue
        self.timestamp = timestamp
        self.receivedAt = .now
        self.healthKitSynced = false
        self.nightscoutSynced = false
        self.nightscoutRetryCount = 0
        self.lastSyncError = nil
    }

    var unit: GlucoseUnit {
        get { GlucoseUnit(rawValue: unitRaw) ?? .mgdL }
        set { unitRaw = newValue.rawValue }
    }

    /// Stable identifier shared by HealthKit (sync identifier) and Nightscout de-duplication.
    var syncIdentifier: String { "\(serialNumber)-\(sequenceNumber)" }
}
