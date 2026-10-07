import Foundation
import SwiftData
import UIKit
import os.log

private let logger = Logger(subsystem: "glucorelay", category: "SyncQueue")

/// Pushes stored readings to HealthKit and Nightscout. Readings are persisted first, so nothing
/// is lost when the phone is locked (HealthKit unavailable) or offline (Nightscout unreachable).
@MainActor
final class SyncQueue {
    static let maxNightscoutRetries = 3

    private let readings: GlucoseReadingStore
    private let healthKit: HealthKitSync
    private var isRunning = false
    private var needsRerun = false

    init(readings: GlucoseReadingStore, healthKit: HealthKitSync) {
        self.readings = readings
        self.healthKit = healthKit

        // HealthKit is locked while the device is locked – retry once it is unlocked.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trigger() }
        }
    }

    /// Fire-and-forget processing of everything pending.
    func trigger() {
        Task { await processPending() }
    }

    /// Gives failed Nightscout uploads another set of retries (manual "Retry" in History).
    func resetFailedAndRetry() {
        readings.resetNightscoutRetries()
        trigger()
    }

    func processPending() async {
        if isRunning { needsRerun = true; return }
        isRunning = true
        // Keep running for a few extra seconds when woken in the background by a BLE event.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GlucoRelaySync") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        repeat {
            needsRerun = false
            await runOnce()
        } while needsRerun
        endBackgroundTask()
        isRunning = false
    }

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func runOnce() async {
        let pending = readings.pending(maxNightscoutRetries: Self.maxNightscoutRetries)
        guard !pending.isEmpty else { return }
        logger.info("Processing \(pending.count) pending reading(s)")

        var healthKitBlocked = false
        let nightscoutConfigured = NightscoutSync.isConfigured

        for reading in pending {
            let mgdL = reading.value
            let date = reading.timestamp
            let serial = reading.serialNumber
            let sequence = reading.sequenceNumber

            if !reading.healthKitSynced && !healthKitBlocked {
                do {
                    try await healthKit.save(mgdL: mgdL, date: date, serialNumber: serial, sequenceNumber: sequence)
                    reading.healthKitSynced = true
                } catch {
                    // Not authorised or locked: keep pending, don't hammer HealthKit for the rest.
                    healthKitBlocked = true
                    logger.notice("HealthKit save deferred: \(String(describing: error))")
                }
            }

            if !reading.nightscoutSynced && nightscoutConfigured
                && reading.nightscoutRetryCount < Self.maxNightscoutRetries {
                do {
                    try await NightscoutSync.post(NightscoutEntry(mgdL: mgdL, date: date, serialNumber: serial))
                    reading.nightscoutSynced = true
                    reading.lastSyncError = nil
                } catch {
                    reading.nightscoutRetryCount += 1
                    reading.lastSyncError = error.localizedDescription
                    logger.error("Nightscout upload failed (\(reading.nightscoutRetryCount)/\(Self.maxNightscoutRetries)): \(error.localizedDescription)")
                }
            }
            readings.save()
        }
    }
}
