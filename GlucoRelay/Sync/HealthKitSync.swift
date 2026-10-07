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
            try await store.requestAuthorization(toShare: [glucoseType], read: [glucoseType])
        } catch {
            logger.error("Authorization failed: \(error.localizedDescription)")
        }
        refreshStatus()
        await enableBackgroundDelivery()
    }

    /// Requested per spec; only effective once read access has been granted.
    func enableBackgroundDelivery() async {
        guard isAvailable else { return }
        do {
            try await store.enableBackgroundDelivery(for: glucoseType, frequency: .immediate)
        } catch {
            logger.notice("Background delivery not enabled: \(error.localizedDescription)")
        }
    }

    enum SaveError: Error { case notAuthorized, databaseLocked }

    /// Saves one reading. The sync identifier "<serial>-<sequence>" makes re-saves idempotent.
    func save(mgdL: Double, date: Date, serialNumber: String, sequenceNumber: Int) async throws {
        refreshStatus()
        guard status == .authorized else { throw SaveError.notAuthorized }

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
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            // Phone is locked – retried when protected data becomes available.
            throw SaveError.databaseLocked
        }
    }
}
