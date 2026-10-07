import Foundation
@preconcurrency import HealthKit
import Observation
import os.log

private let logger = Logger(subsystem: "glucorelay", category: "HealthKit")

/// Writes meter readings to Apple Health as `HKQuantityTypeIdentifierBloodGlucose`.
@MainActor
@Observable
final class HealthKitSync {
    enum Status: Equatable {
        case unavailable, notDetermined, denied, authorized
    }

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private let glucoseType = HKQuantityType(.bloodGlucose)
    private(set) var status: Status = .notDetermined

    static let mgdLUnit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))

    init() { refreshStatus() }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func refreshStatus() {
        guard isAvailable else { status = .unavailable; return }
        switch store.authorizationStatus(for: glucoseType) {
        case .sharingAuthorized: status = .authorized
        case .sharingDenied: status = .denied
        case .notDetermined: status = .notDetermined
        @unknown default: status = .notDetermined
        }
    }

    func requestAuthorization() async {
        guard isAvailable else { status = .unavailable; return }
        do {
            // toShare: we write BG readings from the meter.
            // read: [] — we never read other sources; requesting read access for blood glucose
            // without Apple's special entitlement silently blocks the entire auth sheet.
            try await store.requestAuthorization(toShare: [glucoseType], read: [])
            logger.info("HealthKit authorization request completed")
        } catch {
            logger.error("Authorization failed: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    enum SaveError: Error { case notAuthorized, databaseLocked }

    /// Saves one reading. The sync identifier "<serial>-<sequence>" makes re-saves idempotent.
    func save(mgdL: Double, date: Date, serialNumber: String, sequenceNumber: Int) async throws {
        // No status pre-check: HealthKit hides denied access behind .notDetermined (privacy),
        // so the store itself decides whether the write is allowed.
        guard isAvailable else { throw SaveError.notAuthorized }

        let device = HKDevice(name: "Accu-Chek Guide", manufacturer: "Roche", model: "Guide",
                              hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                              localIdentifier: serialNumber, udiDeviceIdentifier: nil)
        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: "\(serialNumber)-\(sequenceNumber)",
            HKMetadataKeySyncVersion: 1,
            HKMetadataKeyWasUserEntered: false
        ]
        let sample = HKQuantitySample(type: glucoseType,
                                      quantity: HKQuantity(unit: Self.mgdLUnit, doubleValue: mgdL),
                                      start: date, end: date, device: device, metadata: metadata)
        do {
            try await store.save(sample)
            logger.info("Saved \(mgdL) mg/dL SN \(serialNumber) #\(sequenceNumber)")
        } catch let error as HKError {
            switch error.code {
            case .errorDatabaseInaccessible:
                // Phone is locked – retried when protected data becomes available.
                throw SaveError.databaseLocked
            case .errorAuthorizationDenied, .errorAuthorizationNotDetermined:
                logger.warning("HealthKit save rejected – not authorized (\(error.code.rawValue))")
                throw SaveError.notAuthorized
            default:
                throw error
            }
        }
    }
}
