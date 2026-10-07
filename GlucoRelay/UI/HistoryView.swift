import SwiftUI
import SwiftData

struct HistoryView: View {
    @AppStorage(GlucoseUnit.storageKey) private var unitRaw = GlucoseUnit.mmolL.rawValue
    @Query(sort: \GlucoseReading.timestamp, order: .reverse) private var readings: [GlucoseReading]
    @Query private var devices: [DeviceRecord]

    private var unit: GlucoseUnit { GlucoseUnit(rawValue: unitRaw) ?? .mmolL }

    private func deviceName(for id: UUID) -> String? {
        devices.first { $0.id == id }?.displayName
    }

    private var hasFailedUploads: Bool {
        readings.contains { !$0.nightscoutSynced && $0.nightscoutRetryCount >= SyncQueue.maxNightscoutRetries }
    }

    /// Readings grouped by calendar day, newest first.
    private var sections: [(day: Date, items: [GlucoseReading])] {
        let cal = Calendar.current
        var result: [(day: Date, items: [GlucoseReading])] = []
        for r in readings {
            let day = cal.startOfDay(for: r.timestamp)
            if let last = result.last, last.day == day {
                result[result.count - 1].items.append(r)
            } else {
                result.append((day, [r]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if readings.isEmpty {
                    ContentUnavailableView("No readings yet", systemImage: "drop",
                                           description: Text("Readings from your meter appear here."))
                } else {
                    List {
                        ForEach(sections, id: \.day) { section in
                            Section {
                                ForEach(section.items) { reading in
                                    HistoryRow(reading: reading, unit: unit,
                                               deviceName: deviceName(for: reading.peripheralUUID))
                                        .listRowBackground(Theme.card)
                                }
                            } header: {
                                Text(section.day, format: .dateTime.weekday(.wide).day().month(.wide))
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("History")
            .toolbar {
                if hasFailedUploads {
                    Button {
                        AppServices.shared.syncQueue.resetFailedAndRetry()
                    } label: {
                        Label("Retry uploads", systemImage: "arrow.clockwise.icloud")
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let reading: GlucoseReading
    let unit: GlucoseUnit
    let deviceName: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reading.timestamp, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(.headline.monospacedDigit())
                if let deviceName {
                    Text(deviceName)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 12) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(unit.format(mgdL: reading.value))
                        .font(.title.bold().monospacedDigit())
                        .foregroundStyle(.white)
                    Text(unit.label)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                }
                SyncIcons(healthKit: reading.healthKitSynced, nightscout: reading.nightscoutSynced,
                          nightscoutFailed: reading.nightscoutRetryCount >= SyncQueue.maxNightscoutRetries)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
