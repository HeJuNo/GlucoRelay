import Foundation
import SwiftData

/// A paired Accu-Chek Guide meter.
@Model
final class DeviceRecord {
    /// CoreBluetooth peripheral identifier.
    @Attribute(.unique) var id: UUID
    var serialNumber: String
    var nickname: String?
    /// Highest glucose record sequence number already processed (-1 = none yet).
    var lastSequenceNumber: Int
    var addedAt: Date

    init(id: UUID, serialNumber: String, nickname: String? = nil,
         lastSequenceNumber: Int = -1, addedAt: Date = .now) {
        self.id = id
        self.serialNumber = serialNumber
        self.nickname = nickname
        self.lastSequenceNumber = lastSequenceNumber
        self.addedAt = addedAt
    }

    var displayName: String {
        if let nickname, !nickname.trimmingCharacters(in: .whitespaces).isEmpty { return nickname }
        return "Accu-Chek Guide"
    }
}
