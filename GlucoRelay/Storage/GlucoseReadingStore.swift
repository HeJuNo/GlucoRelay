import Foundation
import SwiftData

/// Persistence for received readings.
@MainActor
final class GlucoseReadingStore {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func exists(peripheralUUID: UUID, sequenceNumber: Int) -> Bool {
        var descriptor = FetchDescriptor<GlucoseReading>(predicate: #Predicate {
            $0.peripheralUUID == peripheralUUID && $0.sequenceNumber == sequenceNumber
        })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    func insert(_ reading: GlucoseReading) {
        context.insert(reading)
        save()
    }

    /// Readings still missing in HealthKit, or in Nightscout with retries left – oldest first.
    func pending(maxNightscoutRetries: Int) -> [GlucoseReading] {
        let limit = maxNightscoutRetries
        let descriptor = FetchDescriptor<GlucoseReading>(
            predicate: #Predicate {
                !$0.healthKitSynced || (!$0.nightscoutSynced && $0.nightscoutRetryCount < limit)
            },
            sortBy: [SortDescriptor(\.timestamp)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func resetNightscoutRetries() {
        let descriptor = FetchDescriptor<GlucoseReading>(predicate: #Predicate { !$0.nightscoutSynced })
        for r in (try? context.fetch(descriptor)) ?? [] { r.nightscoutRetryCount = 0 }
        save()
    }

    func deleteAll(peripheralUUID: UUID) {
        try? context.delete(model: GlucoseReading.self, where: #Predicate { $0.peripheralUUID == peripheralUUID })
        save()
    }

    func save() {
        do { try context.save() } catch { print("GlucoseReadingStore save failed: \(error)") }
    }
}
