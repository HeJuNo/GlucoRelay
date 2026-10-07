import Foundation
import SwiftData

/// Paired meters: serial number cache + last processed sequence number per peripheral.
@MainActor
final class DeviceStore {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func all() -> [DeviceRecord] {
        (try? context.fetch(FetchDescriptor<DeviceRecord>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
    }

    var savedIdentifiers: [UUID] { all().map(\.id) }

    func device(id: UUID) -> DeviceRecord? {
        var descriptor = FetchDescriptor<DeviceRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    func add(id: UUID, serialNumber: String, nickname: String?) -> DeviceRecord {
        if let existing = device(id: id) {
            existing.serialNumber = serialNumber
            existing.nickname = nickname
            save()
            return existing
        }
        let record = DeviceRecord(id: id, serialNumber: serialNumber, nickname: nickname)
        context.insert(record)
        save()
        return record
    }

    func updateSerial(id: UUID, serialNumber: String) {
        guard let d = device(id: id), d.serialNumber != serialNumber else { return }
        d.serialNumber = serialNumber
        save()
    }

    func updateLastSequence(id: UUID, sequence: Int) {
        guard let d = device(id: id), sequence > d.lastSequenceNumber else { return }
        d.lastSequenceNumber = sequence
        save()
    }

    func remove(id: UUID) {
        guard let d = device(id: id) else { return }
        context.delete(d)
        save()
    }

    func save() {
        do { try context.save() } catch { print("DeviceStore save failed: \(error)") }
    }
}
